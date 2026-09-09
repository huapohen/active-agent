'use strict';
const {test}=require('node:test');const assert=require('node:assert/strict');
const fs=require('node:fs');const os=require('node:os');const path=require('node:path');
const {nextSequence,serializedHeartbeat}=require('./heartbeat.cjs');
test('heartbeat state transitions serialize even after request failure',async()=>{
 let seq=0,release;const sent=[];const send=serializedHeartbeat(()=>++seq,body=>{sent.push(body);if(body.sequence===1)return new Promise((resolve,reject)=>{release=()=>reject(new Error('timeout'));});return Promise.resolve();});
 const first=send('connected');const last=send('disconnected');await Promise.resolve();await Promise.resolve();assert.deepEqual(sent,[{state:'connected',sequence:1}]);release();await first.catch(()=>{});await last;assert.deepEqual(sent,[{state:'connected',sequence:1},{state:'disconnected',sequence:2}]);
});
test('sequence survives restart and local clock rollback without reusing an ID',t=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'renji-heartbeat-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
 assert.equal(nextSequence(dir,'scope',()=>100),100000);assert.equal(nextSequence(dir,'scope',()=>99),100001);assert.throws(()=>nextSequence(dir,'other',()=>101));
});
