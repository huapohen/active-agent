'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {validateConfig,projectMessage}=require('./security.cjs');
const room='11111111-1111-4111-8111-111111111111',receiver='22222222-2222-4222-8222-222222222222',message='33333333-3333-4333-8333-333333333333';
const config={schema:'renji.rongcloud.trusted-bridge.v1',bridge_id:'fixture',receiver_id:receiver,room_id:room,app_key:'synthetic',provider_token:'secret',bridge_secret:'a'.repeat(32),ingress_url:'http://127.0.0.1:8090/internal/transport/rongcloud/fixture',state_dir:'/tmp/isolated',message_ids:[message]};
test('bridge configuration is loopback, scoped and never an arbitrary RPC destination',()=>{
 assert.equal(validateConfig(config),config);
 for(const patch of [{ingress_url:'https://example.com'},{ingress_url:config.ingress_url+'?secret=x'},{ingress_url:config.ingress_url.replace('127.0.0.1','localhost')},{message_ids:[]},{message_ids:[message,message]},{receiver_id:'human'},{bridge_secret:'short'}]) assert.throws(()=>validateConfig({...config,...patch}));
});
test('only actual scoped SDK messages with allowed canonical pointers can enqueue',()=>{
 const m={conversationType:3,targetId:room,senderUserId:receiver,messageUId:'SDK-RECEIVE-UID',messageType:'RC:TxtMsg',receivedTime:123,content:{content:'中文消息',extra:JSON.stringify({schema:'renji.message.v1',room_id:room,message_id:message,seq:1}),user:null}};
 const value=projectMessage(m,config);assert.equal(value.content.content,'中文消息');assert.equal(value.message_uid,m.messageUId);assert.equal(value.received_time,123);assert.equal('user' in value.content,false);
 for(const patch of [{targetId:receiver},{conversationType:1},{messageType:'RC:RcCmd'},{messageUId:''},{content:{content:'x',extra:'{}'}}])assert.equal(projectMessage({...m,...patch},config),null);
 assert.equal(projectMessage(m,{...config,message_ids:[receiver]}),null);
});
