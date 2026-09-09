'use strict';
// Operator-owned development receive bridge. No user HTML, no public RPC, no
// token response and no send/recall/reaction API are exposed to commercial UI.
const {app,BrowserWindow,ipcMain,protocol,net,session}=require('electron');
const fs=require('node:fs');
const path=require('node:path');
const {pathToFileURL}=require('node:url');
const {createHash}=require('node:crypto');
const {validateConfig,projectMessage}=require('./security.cjs');
const {bindStateDirectory,requireStateScope}=require('./state.cjs');
const {nextSequence,serializedHeartbeat}=require('./heartbeat.cjs');
let config,scopeFingerprint;
try {
 const file=process.argv[2];const stat=fs.statSync(file);
 if(!stat.isFile() || (stat.mode&0o077) || stat.size>65536)throw new Error();
 config=validateConfig(JSON.parse(fs.readFileSync(file,'utf8')));
 fs.mkdirSync(config.state_dir,{recursive:true,mode:0o700});
 if((fs.statSync(config.state_dir).mode&0o077)!==0)throw new Error();
 scopeFingerprint=bindStateDirectory(config);
}catch{console.error('bridge_configuration_unavailable');app.exit(1);}
if(!config)return;
app.setName(`renji-trusted-bridge-${config.bridge_id}`);
app.setPath('userData',path.join(config.state_dir,'sdk-profile'));
protocol.registerSchemesAsPrivileged([{scheme:'renjibridge',privileges:{standard:true,secure:true,supportFetchAPI:true,corsEnabled:true}}]);
const origin='renjibridge://receiver/index.html';
const queuePath=path.join(config.state_dir,'queue.json');
let queue=[],worker,service,verified=false,state='disconnected',draining=false,closing=false,failureCode=null,providerCode=null;
function save(name,value){const dest=path.join(config.state_dir,name),tmp=`${dest}.tmp`;const fd=fs.openSync(tmp,'w',0o600);try{fs.writeFileSync(fd,JSON.stringify(value));fs.fsyncSync(fd);}finally{fs.closeSync(fd);}fs.renameSync(tmp,dest);const dir=fs.openSync(config.state_dir,'r');try{fs.fsyncSync(dir);}finally{fs.closeSync(dir);}}
try{
 if(fs.existsSync(queuePath)){queue=JSON.parse(fs.readFileSync(queuePath,'utf8'));if(!Array.isArray(queue)||queue.length>256)throw new Error();}
 for(const item of queue){
  requireStateScope(item,scopeFingerprint);
  const e=item.envelope;
  if(!e || e.target_id!==config.room_id || !['pending','accepted','rejected'].includes(item.status))throw new Error();
  const observed=projectMessage({conversationType:e.conversation_type,targetId:e.target_id,senderUserId:e.sender_id,messageUId:e.message_uid,messageType:e.message_type,content:e.content,receivedTime:e.received_time},config);
  if(!observed)throw new Error();
 }
 // Recover a receipt fsynced immediately before a crash that prevented the
 // atomic queue rename. This replays only our local real SDK receive journal;
 // it neither calls provider send nor changes the configured receiver scope.
 const journal=path.join(config.state_dir,'sdk-observations.jsonl');
 if(fs.existsSync(journal)){
  const stat=fs.statSync(journal);if(stat.size>16*1024*1024)throw new Error();
  for(const line of fs.readFileSync(journal,'utf8').split('\n').filter(Boolean)){
   const entry=JSON.parse(line);requireStateScope(entry,scopeFingerprint);const envelope=projectMessage(entry.message,config);
   if(!envelope || queue.some(item=>item.envelope.message_uid===envelope.message_uid))continue;
   if(queue.length>=256)throw new Error();
   queue.push({scope_fingerprint:scopeFingerprint,envelope,status:'pending',observed_at:entry.at,sdk_sha256:createHash('sha256').update(JSON.stringify(entry.message)).digest('hex')});
  }
  save('queue.json',queue);
 }
}catch{console.error('bridge_queue_requires_review');app.exit(1);}
function checkpoint(){save('state.json',{schema:'renji.trusted-bridge.state.v1',scope_fingerprint:scopeFingerprint,bridge_id:config.bridge_id,receiver_id:config.receiver_id,room_id:config.room_id,state:verified?state:'unavailable',at:new Date().toISOString(),queued:queue.filter(x=>x.status!=='accepted').length,actual_sdk_receipts:queue.length,failure_code:failureCode,provider_code:providerCode});}
async function post(suffix,body){const response=await fetch(`${config.ingress_url}/${suffix}`,{method:'POST',headers:{Authorization:`Bearer ${config.bridge_secret}`,'Content-Type':'application/json'},body:JSON.stringify(body),redirect:'error',signal:AbortSignal.timeout(5000)});const text=await response.text();if(text.length>65536)throw new Error('ingress_response_invalid');return {status:response.status,body:JSON.parse(text)};}
async function drain(){if(draining||closing||!verified)return;draining=true;try{for(const item of queue){requireStateScope(item,scopeFingerprint);if(item.status==='accepted'||item.status==='rejected')continue;try{const result=await post('received',item.envelope);if(result.status===200){const a=result.body?.arrival;if(a?.provider_uid!==item.envelope.message_uid||a?.room_id!==config.room_id||typeof a?.cursor!=='number')throw new Error('receipt_mismatch');item.status='accepted';item.receipt=result.body;}else if(result.status!==425&&result.status<500){item.status='rejected';item.error=result.body?.error||'ingress_rejected';}save('queue.json',queue);checkpoint();}catch{break;}}}finally{draining=false;}}
const enqueueHeartbeat=serializedHeartbeat(()=>nextSequence(config.state_dir,scopeFingerprint),body=>post('heartbeat',body));
async function heartbeat(){if(!verified||closing)return;try{await enqueueHeartbeat(state);}catch{/* A failed HTTP request is not provider connection evidence. */}}
function trusted(event){return worker && event.sender===worker.webContents && event.senderFrame?.url===origin;}
if(!app.requestSingleInstanceLock()){app.exit(1);}else app.whenReady().then(async()=>{
 const serve=request=>{const url=new URL(request.url);const allowed={'/index.html':'index.html','/worker.js':'worker.js'};if(url.hostname!=='receiver'||!allowed[url.pathname]||url.search)return new Response('Not found',{status:404});return net.fetch(pathToFileURL(path.join(__dirname,'dist',allowed[url.pathname])).href);};
 protocol.handle('renjibridge',serve);
 const ses=session.fromPartition('trusted-rongcloud-receiver');ses.protocol.handle('renjibridge',serve);ses.setPermissionRequestHandler((_w,_p,cb)=>cb(false));ses.setPermissionCheckHandler(()=>false);
 if(config.sdk_mode !== 'web')service=require('@rongcloud/electron')({appkey:config.app_key,dbpath:app.getPath('userData'),logOutputLevel:1,disableLogReport:true});
 worker=new BrowserWindow({show:false,webPreferences:{contextIsolation:true,nodeIntegration:false,sandbox:true,webSecurity:true,allowRunningInsecureContent:false,preload:path.join(__dirname,config.sdk_mode==='web'?'dist/preload-web.cjs':'dist/preload.cjs'),partition:'trusted-rongcloud-receiver'}});
 worker.webContents.setWindowOpenHandler(()=>({action:'deny'}));worker.webContents.on('will-navigate',(event,url)=>{if(url!==origin)event.preventDefault();});worker.webContents.on('will-attach-webview',event=>event.preventDefault());
 ipcMain.on('bridge:ready',event=>{if(trusted(event))worker.webContents.send('bridge:start',{app_key:config.app_key,provider_token:config.provider_token,receiver_id:config.receiver_id});});
 ipcMain.on('bridge:report',(event,notice)=>{
  if(!trusted(event)||!notice||closing)return;
  if(notice.kind==='identity'){if(notice.receiver_id!==config.receiver_id){app.exit(1);return;}verified=true;checkpoint();return;}
  if(notice.kind==='state'){if(verified && ['connected','disconnected'].includes(notice.state)){state=notice.state;checkpoint();void heartbeat();}return;}
  if(notice.kind==='failure'){failureCode=/^[a-z_]{1,80}$/.test(notice.code)?notice.code:'provider_failure';providerCode=Number.isSafeInteger(notice.provider_code)?notice.provider_code:null;state='disconnected';checkpoint();void heartbeat();return;}
  if(notice.kind!=='received'||!verified)return;
  const envelope=projectMessage(notice.message,config);if(!envelope)return;
  const existing=queue.find(x=>x.envelope?.message_uid===envelope.message_uid);
  if(existing){void drain();return;}
  if(queue.length>=256){state='disconnected';checkpoint();return;}
  const sdkRaw=JSON.stringify(notice.message);
  queue.push({scope_fingerprint:scopeFingerprint,envelope,status:'pending',observed_at:new Date().toISOString(),sdk_sha256:createHash('sha256').update(sdkRaw).digest('hex')});
  // Persist the actual receive observation before acknowledging it to Go.
  const fd=fs.openSync(path.join(config.state_dir,'sdk-observations.jsonl'),'a',0o600);try{fs.writeSync(fd,JSON.stringify({scope_fingerprint:scopeFingerprint,at:new Date().toISOString(),message:notice.message})+'\n');fs.fsyncSync(fd);}finally{fs.closeSync(fd);}
  save('queue.json',queue);checkpoint();void drain();
 });
 await worker.loadURL(origin);
 setInterval(()=>{void heartbeat();void drain();},5000);
 setTimeout(()=>{if(!verified){checkpoint();app.exit(1);}},30000);
}).catch(()=>{console.error('bridge_start_failed');app.exit(1);});
async function stop(){if(closing)return;state='disconnected';const finalHeartbeat=heartbeat();closing=true;await finalHeartbeat;checkpoint();if(service)service.destroy();app.quit();}
process.on('SIGTERM',()=>void stop());process.on('SIGINT',()=>void stop());
app.on('before-quit',()=>{closing=true;if(service){service.destroy();service=undefined;}});
