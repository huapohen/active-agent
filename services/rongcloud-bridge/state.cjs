'use strict';
const fs=require('node:fs');
const path=require('node:path');
const {createHash}=require('node:crypto');
function scopeIdentity(config){
 return {schema:'renji.rongcloud.bridge-state-scope.v1',bridge_id:config.bridge_id,receiver_id:config.receiver_id,room_id:config.room_id,app_key_sha256:createHash('sha256').update(config.app_key).digest('hex'),ingress_url:config.ingress_url,sdk_mode:config.sdk_mode||'native',message_ids:[...config.message_ids].sort()};
}
function bindStateDirectory(config){
 const scope=scopeIdentity(config),fingerprint=createHash('sha256').update(JSON.stringify(scope)).digest('hex');
 const filename=path.join(config.state_dir,'scope-manifest.json');
 if(fs.existsSync(filename)){
  const stat=fs.lstatSync(filename);if(!stat.isFile()||(stat.mode&0o077)||stat.size>65536)throw new Error('bridge_state_scope_invalid');
  const manifest=JSON.parse(fs.readFileSync(filename,'utf8'));
  if(manifest.scope_fingerprint!==fingerprint||JSON.stringify(manifest.scope)!==JSON.stringify(scope))throw new Error('bridge_state_scope_mismatch');
 }else{
  // Existing evidence has no proof of who originally received it. Never label
  // a legacy queue/journal with today's identity as an automatic migration.
  if(fs.readdirSync(config.state_dir).length!==0)throw new Error('bridge_state_scope_missing');
  const fd=fs.openSync(filename,'wx',0o600);
  try{fs.writeFileSync(fd,JSON.stringify({scope,scope_fingerprint:fingerprint}));fs.fsyncSync(fd);}finally{fs.closeSync(fd);}
  const dir=fs.openSync(config.state_dir,'r');try{fs.fsyncSync(dir);}finally{fs.closeSync(dir);}
 }
 return fingerprint;
}
function requireStateScope(record,fingerprint){
 if(!record || record.scope_fingerprint!==fingerprint)throw new Error('bridge_record_scope_mismatch');
}
module.exports={scopeIdentity,bindStateDirectory,requireStateScope};
