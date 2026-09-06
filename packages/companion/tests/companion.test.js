'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const {createCompanion} = require('../server');
const {createPolicy, actions} = require('../policy');

const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
async function listen(server) {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  assert.notEqual(server.address().port, 3218);
  return `http://127.0.0.1:${server.address().port}`;
}
async function close(server) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }

test('URL and fixed-action policy denies other origins, local files, browser pages and evaluation', () => {
  const local = createPolicy();
  assert.equal(local.authorize('http://127.0.0.1:4567/example').hostname, '127.0.0.1');
  assert.equal(local.authorize('http://[::1]:4567/').hostname, '[::1]');
  for (const url of ['https://example.com/', 'http://192.168.1.10/', 'http://169.254.169.254/', 'file:///tmp/test', 'javascript:alert(1)', 'chrome://settings', 'data:text/html,hello', 'http://localhost.example.com/', 'http://user:password@localhost:4567/'])
    assert.throws(() => local.authorize(url));
  const exact = createPolicy(['http://127.0.0.1:4567']);
  assert.throws(() => exact.authorize('http://127.0.0.1:4568/'), {code: 'origin_denied'});
  assert.throws(() => actions({actions: [{type: 'evaluate', source: 'process.exit()'}]}, local), {code: 'action_denied'});
  assert.throws(() => actions({actions: [{type: 'constructor'}]}, local), {code: 'action_denied'});
  assert.throws(() => local.authorize('http://localhost/'+ 'x'.repeat(8192)), {code: 'invalid_url'});
  assert.throws(() => actions({actions: [{type: 'click', selector: '#one >> iframe'}]}, local), {code: 'invalid_selector'});
  assert.throws(() => actions({actions: [{type: 'inspect', script: 'hidden'}]}, local), {code: 'invalid_request'});
});

test('real headless Chrome contexts run concurrently, queue locally and keep captures authenticated', {timeout: 30000}, async t => {
  let blockedRequests = 0, awaiting = [], concurrentNavigations = 0, queuedResponse;
  const denied = http.createServer((request, response) => { blockedRequests++; response.end('outside allowlist'); });
  denied.on('upgrade', (_request, socket) => { blockedRequests++; socket.destroy(); });
  const deniedOrigin = await listen(denied);
  const html = label => `<!doctype html><html><head><title>Companion synthetic ${label}</title></head><body style="font:20px system-ui;padding:70px;background:#f5f2ff"><h1>Isolated synthetic workspace ${label}</h1><label for="entry">Work note</label><input id="entry" style="margin:20px;padding:12px"/><button id="apply" style="padding:12px">Apply note</button><p id="result">Initial</p><p id="storage"></p><a id="outside" href="${deniedOrigin}/outside">Outside boundary</a><a id="bad-scheme" href="javascript:void(0)">Invalid navigation</a><button id="disabled" disabled>Unavailable action</button><script>document.getElementById('storage').textContent='Stored: '+(localStorage.getItem('note')||'empty');document.getElementById('apply').onclick=()=>{const value=document.getElementById('entry').value;localStorage.setItem('note',value);document.getElementById('result').textContent='Saved: '+value;document.getElementById('storage').textContent='Stored: '+value;};</script></body></html>`;
  const pages = http.createServer((request, response) => {
    if (request.url === '/network-boundary') {
      response.writeHead(200, {'content-type': 'text/html'});
      response.end(`<!doctype html><body><p>Network boundary synthetic page</p><img src="${deniedOrigin}/image"><script src="${deniedOrigin}/script"></script><iframe src="${deniedOrigin}/frame"></iframe><script>fetch('${deniedOrigin}/fetch').catch(()=>{});new WebSocket('${deniedOrigin.replace('http:', 'ws:')}/socket');</script></body>`); return;
    }
    if (request.url === '/cookies') {
      response.writeHead(200, {'content-type': 'text/html', 'content-encoding': 'gzip', 'set-cookie': ['first=synthetic; Path=/; SameSite=Lax', 'second=isolated; Path=/; SameSite=Lax']});
      response.end(zlib.gzipSync('<!doctype html><body><p>Compressed synthetic page</p></body>')); return;
    }
    if (request.url === '/cookie-check') { response.writeHead(200, {'content-type': 'text/html'}); response.end(`<!doctype html><body><p>${request.headers.cookie || 'no cookie'}</p></body>`); return; }
    if (request.url === '/redirect') { response.writeHead(302, {location: `${deniedOrigin}/redirect-target`}); response.end(); return; }
    if (request.url === '/queued-hold') { queuedResponse = response; return; }
    if (request.url === '/a' || request.url === '/b') {
      awaiting.push({response, label: request.url.slice(1)});
      concurrentNavigations = Math.max(concurrentNavigations, awaiting.length);
      // A global queue would deadlock here: both independent contexts must reach
      // this server before either initial page can finish navigating.
      if (awaiting.length === 2) {
        for (const pending of awaiting) { pending.response.writeHead(200, {'content-type': 'text/html'}); pending.response.end(html(pending.label)); }
        awaiting = [];
      }
      return;
    }
    response.writeHead(200, {'content-type': 'text/html'}); response.end(html('continuation'));
  });
  const pageOrigin = await listen(pages);
  const token = crypto.randomBytes(32).toString('base64url');
  const service = await createCompanion({port: 0, token, allowedOrigins: [pageOrigin], jobTimeoutMs: 8000});
  t.after(async () => { await service.close(); await close(pages); await close(denied); });
  let requests = 0;
  async function api(route, {method = 'GET', data, status = 200, authorized = true, headers = {}} = {}) {
    requests++;
    const result = await fetch(service.origin + route, {method, headers: {'content-type': 'application/json', ...(authorized ? {authorization: `Bearer ${token}`} : {}), ...headers}, ...(data === undefined ? {} : {body: JSON.stringify(data)})});
    assert.equal(result.status, status, `${method} ${route} status`);
    assert.equal(result.headers.get('cache-control'), 'no-store');
    return result;
  }
  async function submit(session, definitions) {
    return (await (await api(`/sessions/${session.id}/jobs`, {method: 'POST', data: {actions: definitions}, status: 202})).json()).job;
  }
  async function finished(job) {
    for (let i = 0; i < 120; i++) {
      const value = (await (await api(`/jobs/${job.id}`)).json()).job;
      if (!['running', 'queued'].includes(value.status)) return value;
      await wait(50);
    }
    assert.fail('synthetic companion job did not finish');
  }
  await api('/health', {authorized: false, status: 401});
  await api('/health', {headers: {origin: 'https://untrusted.example'}, status: 403});
  const caps = await (await api('/capabilities')).json();
  assert.equal(caps.limits.max_contexts, 2); assert.ok(caps.unsupported.includes('iOS cross-app control'));
  const first = (await (await api('/sessions', {method: 'POST', data: {}, status: 201})).json()).session;
  const second = (await (await api('/sessions', {method: 'POST', data: {}, status: 201})).json()).session;
  await api('/sessions', {method: 'POST', data: {}, status: 429});
  const initialJobs = await Promise.all([submit(first, [{type: 'navigate', url: `${pageOrigin}/a`}, {type: 'inspect'}]), submit(second, [{type: 'navigate', url: `${pageOrigin}/b`}, {type: 'inspect'}])]);
  const initial = await Promise.all(initialJobs.map(finished));
  assert.equal(concurrentNavigations, 2);
  for (const result of initial) { assert.equal(result.status, 'succeeded'); assert.match(result.results[1].text, /Stored: empty/); }
  // Use selectors from the preceding actual DOM inspection, not an external
  // browser or a guessed selector in someone else's logged-in session.
  const selectors = initial.map(result => {
    const controls = result.results[1].controls;
    return {input: '#' + controls.find(control => control.tag === 'input').id, button: '#' + controls.find(control => control.tag === 'button' && control.label === 'Apply note').id};
  });
  const editJobs = await Promise.all([first, second].map((session, index) => submit(session, [
    {type: 'type', selector: selectors[index].input, text: `synthetic-${index}`},
    {type: 'click', selector: selectors[index].button}, {type: 'inspect'}, {type: 'screenshot'},
  ])));
  const edits = await Promise.all(editJobs.map(finished));
  for (let index = 0; index < 2; index++) {
    assert.equal(edits[index].status, 'succeeded');
    assert.match(edits[index].results[2].text, new RegExp(`Saved: synthetic-${index}`));
    assert.ok(!edits[index].results[2].text.includes(`synthetic-${1 - index}`));
  }
  const image = edits[0].results[3];
  await api(image.path, {authorized: false, status: 401});
  const picture = await api(image.path);
  assert.equal(picture.headers.get('content-type'), 'image/png');
  const png = Buffer.from(await picture.arrayBuffer());
  assert.equal(png.subarray(1, 4).toString(), 'PNG');
  assert.equal(crypto.createHash('sha256').update(png).digest('hex'), image.sha256);
  const artifactDir = path.resolve(__dirname, '../../..', 'output/companion');
  fs.mkdirSync(artifactDir, {recursive: true});
  fs.writeFileSync(path.join(artifactDir, 'synthetic-virtual-pointer.png'), png);
  const reloads = await Promise.all([first, second].map(session => submit(session, [{type: 'navigate', url: `${pageOrigin}/storage-check`}, {type: 'inspect'}])));
  const storage = await Promise.all(reloads.map(finished));
  for (let index = 0; index < 2; index++) assert.match(storage[index].results[1].text, new RegExp(`Stored: synthetic-${index}`), 'storage leaked between BrowserContexts');
  const queuedFirst = await submit(first, [{type: 'navigate', url: `${pageOrigin}/queued-hold`}, {type: 'type', selector: selectors[0].input, text: 'queued-first'}, {type: 'click', selector: selectors[0].button}]);
  for (let attempt = 0; attempt < 40 && !queuedResponse; attempt++) await wait(25);
  assert.ok(queuedResponse, 'first queued job did not reach its held page');
  const queuedSecond = await submit(first, [{type: 'type', selector: selectors[0].input, text: 'queued-second'}, {type: 'click', selector: selectors[0].button}, {type: 'inspect'}]);
  assert.equal((await (await api(`/jobs/${queuedSecond.id}`)).json()).job.status, 'queued');
  queuedResponse.writeHead(200, {'content-type': 'text/html'}); queuedResponse.end(html('serial queue'));
  const queueResults = await Promise.all([finished(queuedFirst), finished(queuedSecond)]);
  assert.ok(Date.parse(queueResults[1].started_at) >= Date.parse(queueResults[0].finished_at));
  assert.match(queueResults[1].results[2].text, /Saved: queued-second/);
  await api(`/sessions/${first.id}/jobs`, {method: 'POST', data: {actions: [{type: 'navigate', url: 'file:///tmp/fixture'}]}, status: 422});
  await api(`/sessions/${first.id}/jobs`, {method: 'POST', data: {actions: [{type: 'navigate', url: `${deniedOrigin}/denied`}]}, status: 403});
  const deniedClick = await finished(await submit(first, [{type: 'click', selector: '#outside'}]));
  assert.equal(deniedClick.status, 'failed'); assert.equal(deniedClick.error.code, 'origin_denied');
  const deniedScheme = await finished(await submit(first, [{type: 'click', selector: '#bad-scheme'}]));
  assert.equal(deniedScheme.status, 'failed'); assert.equal(deniedScheme.error.code, 'scheme_denied');
  const networkBoundary = await finished(await submit(first, [{type: 'navigate', url: `${pageOrigin}/network-boundary`}, {type: 'inspect'}]));
  assert.equal(networkBoundary.status, 'succeeded');
  assert.match(networkBoundary.results[1].text, /Network boundary synthetic page/);
  const cookieWrite = await finished(await submit(first, [{type: 'navigate', url: `${pageOrigin}/cookies`}, {type: 'inspect'}]));
  assert.equal(cookieWrite.status, 'succeeded'); assert.match(cookieWrite.results[1].text, /Compressed synthetic page/);
  const cookieReads = await Promise.all([first, second].map(async session => finished(await submit(session, [{type: 'navigate', url: `${pageOrigin}/cookie-check`}, {type: 'inspect'}]))));
  assert.equal(cookieReads[0].status, 'succeeded'); assert.match(cookieReads[0].results[1].text, /first=synthetic/); assert.match(cookieReads[0].results[1].text, /second=isolated/);
  assert.equal(cookieReads[1].status, 'succeeded'); assert.match(cookieReads[1].results[1].text, /no cookie/);
  const deniedRedirect = await finished(await submit(second, [{type: 'navigate', url: `${pageOrigin}/redirect`}]));
  assert.equal(deniedRedirect.status, 'failed');
  assert.equal(blockedRequests, 0, 'an out-of-policy navigation or redirect reached the forbidden server');
  await api(`/sessions/${first.id}`, {method: 'DELETE'});
  await api(image.path, {status: 404}); await api(`/jobs/${queuedFirst.id}`, {status: 404});
  assert.equal((await (await api('/health')).json()).ok, true);
  t.diagnostic(`${requests} authenticated/denied HTTP checks; two real headless Chrome contexts; concurrent navigation gate, independent storage, pointer PNG, serial queue and zero denied-origin requests`);
});

test('job deadline closes its context, cancels queued work and keeps the service alive', {timeout: 15000}, async t => {
  const pages = http.createServer((request, response) => { response.writeHead(200, {'content-type': 'text/html'}); response.end('<!doctype html><body><button id="never" disabled>Never actionable</button></body>'); });
  const pageOrigin = await listen(pages), token = crypto.randomBytes(32).toString('base64url');
  const service = await createCompanion({port: 0, token, allowedOrigins: [pageOrigin], jobTimeoutMs: 700});
  t.after(async () => { await service.close(); await close(pages); });
  async function api(route, method = 'GET', data) {
    const response = await fetch(service.origin + route, {method, headers: {authorization: `Bearer ${token}`, 'content-type': 'application/json'}, ...(data === undefined ? {} : {body: JSON.stringify(data)})});
    return {status: response.status, ...await response.json()};
  }
  const {session} = await api('/sessions', 'POST', {});
  const first = await api(`/sessions/${session.id}/jobs`, 'POST', {actions: [{type: 'navigate', url: pageOrigin}, {type: 'click', selector: '#never'}]});
  const next = await api(`/sessions/${session.id}/jobs`, 'POST', {actions: [{type: 'inspect'}]});
  let result;
  for (let index = 0; index < 70; index++) { result = await api(`/jobs/${first.job.id}`); if (result.job.status === 'failed') break; await wait(50); }
  assert.equal(result.job.status, 'failed'); assert.equal(result.job.error.code, 'job_timeout');
  const terminal = JSON.stringify(result.job);
  await wait(150);
  assert.equal(JSON.stringify((await api(`/jobs/${first.job.id}`)).job), terminal, 'Late browser completion must not mutate the terminal receipt');
  assert.equal((await api(`/jobs/${next.job.id}`)).job.status, 'cancelled');
  assert.equal((await api(`/sessions/${session.id}/jobs`, 'POST', {actions: [{type: 'inspect'}]})).status, 404);
  assert.equal((await api('/health')).ok, true);
});
