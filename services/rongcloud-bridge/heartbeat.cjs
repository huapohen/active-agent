'use strict';
const fs=require('node:fs');
const path=require('node:path');
const {requireStateScope}=require('./state.cjs');
function nextSequence(directory,fingerprint,now=Date.now){
 const file=path.join(directory,'heartbeat-sequence.json');let prior=0;
 if(fs.existsSync(file)){const record=JSON.parse(fs.readFileSync(file,'utf8'));requireStateScope(record,fingerprint);if(!Number.isSafeInteger(record.sequence)||record.sequence<1)throw new Error('heartbeat_sequence_invalid');prior=record.sequence;}
 const sequence=Math.max(prior+1,now()*1000);
 if(!Number.isSafeInteger(sequence)||sequence<1)throw new Error('heartbeat_sequence_invalid');
 const temp=`${file}.tmp`,fd=fs.openSync(temp,'w',0o600);
 try{fs.writeFileSync(fd,JSON.stringify({scope_fingerprint:fingerprint,sequence}));fs.fsyncSync(fd);}finally{fs.closeSync(fd);}
 fs.renameSync(temp,file);const parent=fs.openSync(directory,'r');try{fs.fsyncSync(parent);}finally{fs.closeSync(parent);}
 return sequence;
}
function serializedHeartbeat(next,send){
 let queue=Promise.resolve();
 return state=>{
  // Capture state at enqueue time. Later disconnect must remain later even if
  // an earlier HTTP request fails or completes after a timeout at the server.
  queue=queue.catch(()=>{}).then(()=>send({state,sequence:next()}));
  return queue;
 };
}
module.exports={nextSequence,serializedHeartbeat};
