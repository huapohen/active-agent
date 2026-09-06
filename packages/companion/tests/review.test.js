'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const crypto = require('node:crypto');
const {createCompanion} = require('../server');
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
async function fixture(t) {
  const held = []; let pageReceivedControllerToken = false;
  const token = crypto.randomBytes(32).toString('base64url');
  const pages = http.createServer((request, response) => {
    pageReceivedControllerToken ||= Object.values(request.headers).some(value => String(value).includes(token)) || request.url.includes(token);
    if (request.url === '/hold') { held.push(response); return; }
    response.writeHead(200, {'content-type':'text/html'});
    response.end(`<!doctype html><title>${'T'.repeat(3000)}</title><body><input id="${'i'.repeat(2000)}" name="${'n'.repeat(2000)}" aria-label="${'L'.repeat(4000)}" placeholder="${'P'.repeat(4000)}"><p>${'B'.repeat(40000)}</p></body>`);
  });
  await new Promise(resolve => pages.listen(0, '127.0.0.1', resolve));
  const pageOrigin = `http://127.0.0.1:${pages.address().port}`;
  const service = await createCompanion({port:0, token, allowedOrigins:[pageOrigin], jobTimeoutMs:5000});
  t.after(async () => { await service.close(); pages.closeAllConnections(); await new Promise(resolve=>pages.close(resolve)); });
  const api = async (route, method='GET', data) => {
    const result = await fetch(service.origin+route, {method, headers:{authorization:`Bearer ${token}`, 'content-type':'application/json'}, ...(data===undefined?{}:{body:JSON.stringify(data)})});
    return {status:result.status, ...await result.json()};
  };
  function delayedPost(route, data) {
    const text = JSON.stringify(data), prefix = text.slice(0, 12);
    let request;
    const response = new Promise((resolve,reject) => {
      request = http.request(service.origin+route, {method:'POST', headers:{authorization:`Bearer ${token}`, 'content-type':'application/json', 'content-length':Buffer.byteLength(text)}}, result => {
        const chunks=[];result.on('data',chunk=>chunks.push(chunk));result.on('end',()=>resolve({status:result.statusCode,...JSON.parse(Buffer.concat(chunks).toString())}));
      });
      request.on('error',reject);request.write(prefix);
    });
    return {finish:()=>request.end(text.slice(prefix.length)),response};
  }
  async function finished(job) {
    for(let n=0;n<100;n++) { const result=await api(`/jobs/${job.id}`);if(result.job&&!['queued','running'].includes(result.job.status))return result.job;await wait(30); }
    assert.fail('Synthetic job did not terminate');
  }
  return {api,pageOrigin,held,delayedPost,finished,leaked:()=>pageReceivedControllerToken};
}

test('an in-flight submit cannot create an orphan job after its session is deleted', {timeout:15000}, async t=>{
  const f=await fixture(t),{session}=await f.api('/sessions','POST',{});
  const pending=f.delayedPost(`/sessions/${session.id}/jobs`,{actions:[{type:'navigate',url:f.pageOrigin+'/hold'}]});
  await wait(60);assert.equal((await f.api('/health')).ok,true);
  assert.equal((await f.api(`/sessions/${session.id}`,'DELETE')).status,200);
  pending.finish();const response=await pending.response;
  assert.equal(response.status,404);assert.equal(response.error.code,'session_not_found');assert.equal(f.held.length,0);
});

test('concurrent parsed request bodies recheck the queue capacity before acceptance', {timeout:15000}, async t=>{
  const f=await fixture(t),{session}=await f.api('/sessions','POST',{});
  await f.api(`/sessions/${session.id}/jobs`,'POST',{actions:[{type:'navigate',url:f.pageOrigin+'/hold'}]});
  for(let n=0;n<50&&!f.held.length;n++)await wait(20);assert.equal(f.held.length,1);
  const pending=Array.from({length:22},()=>f.delayedPost(`/sessions/${session.id}/jobs`,{actions:[{type:'inspect'}]}));
  await wait(80);for(const request of pending)request.finish();
  const replies=await Promise.all(pending.map(request=>request.response));
  assert.equal(replies.filter(reply=>reply.status===202).length,20);assert.equal(replies.filter(reply=>reply.status===429).length,2);
  await f.api(`/sessions/${session.id}`,'DELETE');
});

test('inspection bounds visible text and control attributes before returning them from the browser', {timeout:15000}, async t=>{
  const f=await fixture(t),{session}=await f.api('/sessions','POST',{});
  const {job}=await f.api(`/sessions/${session.id}/jobs`,'POST',{actions:[{type:'navigate',url:f.pageOrigin},{type:'inspect'}]});
  const result=await f.finished(job);assert.equal(result.status,'succeeded');
  const view=result.results[1];assert.equal(view.text.length,20000);assert.equal(view.truncated,true);assert.ok(view.title.length<=500);
  assert.equal(view.controls[0].id,null);assert.equal(view.controls[0].name,null);assert.equal(view.controls[0].truncated,true);
  assert.ok(view.controls[0].label.length<=160);assert.ok(view.controls[0].placeholder.length<=160);
  assert.equal(f.leaked(),false,'The controller credential must never be injected into page requests');
});
