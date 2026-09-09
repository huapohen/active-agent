'use strict';
const {test}=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs');const os=require('node:os');const path=require('node:path');
const {bindStateDirectory,requireStateScope}=require('./state.cjs');
function config(t){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'renji-scope-test-'));fs.chmodSync(dir,0o700);t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));return {state_dir:dir,bridge_id:'bridge-a',receiver_id:'receiver-a',room_id:'room',app_key:'app-a',ingress_url:'http://127.0.0.1:1/internal/a',sdk_mode:'web',message_ids:['message']};}
test('same scope can reopen; token renewal does not relabel the receiver',t=>{const c=config(t),fp=bindStateDirectory(c);assert.equal(bindStateDirectory({...c,provider_token:'renewed'}),fp);requireStateScope({scope_fingerprint:fp},fp);});
test('A queue cannot be rebound to B, another app, room, bridge or endpoint',t=>{const c=config(t);bindStateDirectory(c);for(const patch of [{receiver_id:'receiver-b'},{bridge_id:'bridge-b'},{app_key:'app-b'},{room_id:'other'},{ingress_url:'http://127.0.0.1:2/internal/a'},{sdk_mode:'native'},{message_ids:['other']}])assert.throws(()=>bindStateDirectory({...c,...patch}),/scope_mismatch/);});
test('legacy nonempty state must not receive a new identity manifest',t=>{const c=config(t);fs.writeFileSync(path.join(c.state_dir,'queue.json'),'[]');assert.throws(()=>bindStateDirectory(c),/scope_missing/);assert.equal(fs.existsSync(path.join(c.state_dir,'scope-manifest.json')),false);});
test('copied or unbound queue and journal records fail closed',t=>{const c=config(t),fp=bindStateDirectory(c);assert.throws(()=>requireStateScope({},fp));assert.throws(()=>requireStateScope({scope_fingerprint:'other-receiver'},fp));});
