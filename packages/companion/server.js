#!/usr/bin/env node
'use strict';

const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const {setMaxListeners} = require('node:events');
const {CompanionError, problem, createPolicy, object, actions} = require('./policy');
const {installPointer} = require('./pointer');
const {pinnedRequest} = require('./network');

function chromium() { return require('playwright-core').chromium; }
function chromePath() {
  if (process.env.COMPANION_CHROME_PATH) return process.env.COMPANION_CHROME_PATH;
  const candidates = process.platform === 'darwin'
    ? ['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome']
    : process.platform === 'win32'
      ? [`${process.env.PROGRAMFILES || ''}/Google/Chrome/Application/chrome.exe`, `${process.env['PROGRAMFILES(X86)'] || ''}/Google/Chrome/Application/chrome.exe`]
      : ['/usr/bin/google-chrome', '/usr/bin/google-chrome-stable', '/usr/bin/chromium'];
  const found = candidates.find(candidate => fs.existsSync(candidate));
  if (!found) throw problem(503, 'chrome_unavailable', 'Set COMPANION_CHROME_PATH to an installed Chrome executable');
  return found;
}
const id = prefix => `${prefix}_${crypto.randomUUID()}`;
const iso = () => new Date().toISOString();
const safeError = error => error instanceof CompanionError
  ? {code: error.code, message: error.message}
  : {code: 'action_failed', message: 'Browser action failed; inspect the allowed page and selector before retrying'};

async function createCompanion(options = {}) {
  const token = options.token ?? process.env.COMPANION_TOKEN;
  if (typeof token !== 'string' || token.length < 32) throw problem(422, 'token_required', 'Provide a random COMPANION_TOKEN of at least 32 characters');
  const expectedToken = crypto.createHash('sha256').update(token).digest();
  const origins = options.allowedOrigins ?? (process.env.COMPANION_ALLOWED_ORIGINS === undefined ? undefined : process.env.COMPANION_ALLOWED_ORIGINS.split(',').map(s => s.trim()).filter(Boolean));
  const policy = createPolicy(origins);
  const maxContexts = Math.max(1, Math.min(2, Math.floor(Number(options.maxContexts) || 2)));
  const jobTimeout = Math.max(100, Math.min(30000, Number(options.jobTimeoutMs) || 30000));
  const idleMs = 15 * 60 * 1000, maxJobs = 200, maxScreenshots = 20;
  const sessions = new Map(), jobs = new Map(), screenshots = new Map(), closingContexts = new Set();
  let browserPromise, creating = 0, shuttingDown = false, origin;
  const browser = () => browserPromise ||= chromium().launch({
    executablePath: options.chromePath ?? chromePath(), headless: options.headless !== false, chromiumSandbox: true,
    args: ['--disable-background-networking', '--disable-component-update', '--disable-sync', '--no-first-run', '--disable-quic', '--force-webrtc-ip-handling-policy=disable_non_proxied_udp'],
  });
  const viewJob = job => ({id: job.id, session_id: job.session_id, status: job.status, submitted_at: job.submitted_at,
    started_at: job.started_at ?? null, finished_at: job.finished_at ?? null, results: job.results, error: job.error ?? null});
  async function retire(session, erase = false) {
    session.closed = true;
    closingContexts.add(session);
    session.network.abort();
    sessions.delete(session.id);
    for (const job of jobs.values()) if (job.session_id === session.id) {
      if (erase) jobs.delete(job.id);
      else if (job.status === 'queued') { job.status = 'cancelled'; delete job.actions; job.finished_at = iso(); job.error = {code: 'session_closed', message: 'The session is closed'}; }
    }
    session.queue.length = 0;
    for (const [key, image] of screenshots) if (image.session_id === session.id) screenshots.delete(key);
    session.closePromise ||= session.context.close().catch(() => {});
    try { await session.closePromise; } finally { closingContexts.delete(session); }
  }
  function current(raw) { return policy.authorize(raw); }
  async function addSession(input) {
    if (shuttingDown) throw problem(503, 'shutting_down', 'The companion is stopping');
    object(input, ['viewport']);
    const viewport = input.viewport ?? {width: 1100, height: 760};
    object(viewport, ['width', 'height']);
    if (![viewport.width, viewport.height].every(Number.isInteger) || viewport.width < 320 || viewport.height < 240 || viewport.width > 1920 || viewport.height > 1080)
      throw problem(422, 'invalid_viewport', 'Viewport must be 320–1920 by 240–1080 pixels');
    if (sessions.size + creating + closingContexts.size >= maxContexts) throw problem(429, 'context_limit', 'At most two isolated browser sessions may be open');
    creating++;
    let context;
    try {
      context = await (await browser()).newContext({viewport, acceptDownloads: false, serviceWorkers: 'block', permissions: [], ignoreHTTPSErrors: false});
      const session = {id: id('session'), context, page: null, queue: [], running: false, closed: false, touched: Date.now(), network: new AbortController(), requests: 0};
      setMaxListeners(40, session.network.signal); // The explicit per-session HTTP ceiling is 32.
      await context.route('**/*', async route => {
        if (session.closed || session.requests >= 32) { await route.abort('blockedbyclient').catch(() => {}); return; }
        session.requests++;
        try {
          const request = route.request();
          const upstream = await pinnedRequest({url: current(request.url()), method: request.method(),
            headers: await request.allHeaders(), body: request.postDataBuffer(), timeoutMs: jobTimeout,
            signal: session.network.signal, authorize: current});
          await route.fulfill(upstream);
        }
        catch { await route.abort('blockedbyclient').catch(() => {}); }
        finally { session.requests--; }
      });
      // Do not expose a second ungoverned data transport in this prototype.
      await context.routeWebSocket('**/*', socket => socket.close({code: 1008, reason: 'WebSockets are disabled in this companion prototype'}));
      await context.addInitScript(installPointer);
      await context.addInitScript(() => {
        for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection', 'WebTransport']) {
          try { Object.defineProperty(window, name, {value: undefined, configurable: false, writable: false}); } catch {}
        }
      });
      session.page = await context.newPage();
      context.on('page', page => { if (page !== session.page) void page.close().catch(() => {}); });
      session.page.on('dialog', dialog => void dialog.dismiss().catch(() => {}));
      session.page.on('download', download => void download.cancel().catch(() => {}));
      session.page.on('framenavigated', frame => {
        if (frame !== session.page.mainFrame() || frame.url() === 'about:blank') return;
        try { current(frame.url()); } catch { void retire(session).catch(() => {}); }
      });
      if (shuttingDown) throw problem(503, 'shutting_down', 'The companion is stopping');
      sessions.set(session.id, session);
      return {id: session.id, created_at: iso(), viewport, isolated: true};
    } catch (error) {
      if (context) await context.close().catch(() => {});
      throw error;
    } finally { creating--; }
  }
  async function pointer(page, locator) {
    await locator.scrollIntoViewIfNeeded();
    const box = await locator.boundingBox();
    if (!box) throw problem(422, 'target_invisible', 'The target has no visible rectangle');
    await page.evaluate(async ({x, y}) => {
      const marker = document.getElementById('__active_companion_pointer__');
      if (marker) {
        marker.style.transform = `translate(${Math.round(x)}px,${Math.round(y)}px)`;
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        await Promise.all(marker.getAnimations().map(animation => animation.finished.catch(() => {})));
      }
    }, {x: box.x + box.width / 2, y: box.y + box.height / 2});
  }
  async function perform(session, action) {
    const page = session.page;
    if (session.closed) throw problem(410, 'session_closed', 'The session is closed');
    if (action.type === 'navigate') {
      const url = current(action.url);
      await page.goto(url.href, {waitUntil: 'domcontentloaded'});
      current(page.url());
      return {type: action.type, url: page.url(), title: await page.evaluate(() => document.title.slice(0, 500))};
    }
    current(page.url());
    const locator = page.locator(`css=${action.selector || 'body'}`);
    if (action.type === 'click' || action.type === 'type') {
      await locator.waitFor({state: 'visible'});
      if (await locator.count() !== 1) throw problem(422, 'ambiguous_selector', 'The selector must identify exactly one visible target');
      if (action.type === 'click') {
        const targets = await locator.evaluate(element => [element.closest('a')?.href, element.getAttribute('formaction'), element.closest('form')?.action].filter(Boolean));
        for (const target of targets) current(new URL(target, page.url()).href);
      }
      await pointer(page, locator);
      if (action.type === 'click') await locator.click();
      else await locator.fill(action.text);
      current(page.url());
      return {type: action.type, selector: action.selector, ...(action.type === 'type' ? {characters: action.text.length} : {})};
    }
    if (action.type === 'inspect') {
      // Bound strings inside the browser before crossing the CDP boundary.
      // Oversized identifiers are omitted, not turned into invalid selectors.
      const inspected = await locator.evaluate(element => {
        const visible = element.innerText, nodes = element.querySelectorAll('input,textarea,button,a,select,[role="button"]'), controls = [];
        for (let index = 0; index < Math.min(100, nodes.length); index++) {
          const el = nodes[index]; let truncated = false;
          const bound = (value, max, identifier = false) => {
            if (value === null || value.length <= max) return value;
            truncated = true; return identifier ? null : value.slice(0, max);
          };
          const control = {tag: bound(el.tagName.toLowerCase(), 64), id: bound(el.id, 256, true), name: bound(el.getAttribute('name'), 256, true), role: bound(el.getAttribute('role'), 64), type: bound(el.getAttribute('type'), 64),
            label: bound(el.getAttribute('aria-label') || el.textContent?.trim() || '', 160), placeholder: bound(el.getAttribute('placeholder'), 160)};
          controls.push({...control, truncated});
        }
        return {text: visible.slice(0, 20000), controls, truncated: visible.length > 20000 || nodes.length > 100 || controls.some(control => control.truncated)};
      });
      return {type: action.type, url: page.url(), title: await page.evaluate(() => document.title.slice(0, 500)), ...inspected};
    }
    const buffer = await page.screenshot({type: 'png', fullPage: false});
    if (session.closed) throw problem(410, 'session_closed', 'The session is closed');
    if (buffer.length > 5 * 1024 * 1024) throw problem(413, 'screenshot_too_large', 'Screenshot exceeds the five-megabyte limit');
    if (screenshots.size >= maxScreenshots) screenshots.delete(screenshots.keys().next().value);
    const imageId = id('image');
    screenshots.set(imageId, {buffer, session_id: session.id, at: Date.now()});
    return {type: 'screenshot', path: `/screenshots/${imageId}`, bytes: buffer.length, sha256: crypto.createHash('sha256').update(buffer).digest('hex')};
  }
  async function drain(session) {
    if (session.running) return;
    session.running = true;
    try {
      while (!session.closed && session.queue.length) {
        const job = session.queue.shift();
        if (job.status !== 'queued') continue;
        job.status = 'running'; job.started_at = iso();
        session.page.setDefaultTimeout(jobTimeout); session.page.setDefaultNavigationTimeout(jobTimeout);
        let timer, timedOut = false;
        try {
          await Promise.race([
            (async () => { for (const action of job.actions) {
              if (session.closed) throw problem(410, 'session_closed', 'The session is closed');
              const result = await perform(session, action);
              if (session.closed || job.status !== 'running') throw problem(410, 'session_closed', 'The session is closed');
              job.results.push(result);
            } })(),
            new Promise((_, reject) => { timer = setTimeout(() => { timedOut = true; reject(problem(408, 'job_timeout', 'Job deadline exceeded; its session has been closed')); void retire(session).catch(() => {}); }, jobTimeout); }),
          ]);
          job.status = 'succeeded';
        } catch (error) {
          if (error?.name === 'TimeoutError') { timedOut = true; await retire(session); }
          job.status = 'failed'; job.error = timedOut ? {code: 'job_timeout', message: 'Job deadline exceeded; its session has been closed'} : safeError(error);
        } finally {
          clearTimeout(timer); delete job.actions; job.finished_at = iso(); session.touched = Date.now();
        }
      }
    } finally { session.running = false; }
  }
  const cleanup = setInterval(() => {
    const before = Date.now() - idleMs;
    for (const session of sessions.values()) if (!session.running && session.touched < before) void retire(session, true);
    for (const [key, job] of jobs) if (job.finished_at && Date.parse(job.finished_at) < before) jobs.delete(key);
    for (const [key, image] of screenshots) if (image.at < before) screenshots.delete(key);
  }, 30000);
  cleanup.unref();

  function json(response, status, value) { response.writeHead(status, {'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff'}); response.end(JSON.stringify(value)); }
  async function body(request) {
    if (!/^application\/json(?:;|$)/i.test(request.headers['content-type'] || '')) throw problem(415, 'json_required', 'Content-Type application/json is required');
    let bytes = 0; const chunks = [];
    for await (const chunk of request) { bytes += chunk.length; if (bytes > 65536) throw problem(413, 'body_too_large', 'Request body exceeds 64 KiB'); chunks.push(chunk); }
    try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw problem(400, 'invalid_json', 'Invalid JSON body'); }
  }
  const server = http.createServer(async (request, response) => {
    try {
      const supplied = /^Bearer ([^\s]+)$/.exec(request.headers.authorization || '')?.[1] || '';
      if (!crypto.timingSafeEqual(expectedToken, crypto.createHash('sha256').update(supplied).digest())) return json(response, 401, {error: {code: 'unauthorized', message: 'A companion bearer token is required'}});
      // No browser CORS integration in this prototype, and no DNS-rebinding host.
      if (request.headers.origin || request.headers.host !== new URL(origin).host) throw problem(403, 'request_origin_denied', 'Use this loopback service directly from an authorized client');
      if (shuttingDown) throw problem(503, 'shutting_down', 'The companion is stopping');
      const url = new URL(request.url, origin), route = url.pathname;
      if (url.search) throw problem(422, 'query_denied', 'API query parameters are not supported');
      if (request.method === 'GET' && route === '/health') return json(response, 200, {ok: true, service: 'active-companion', version: '0.1.0'});
      if (request.method === 'GET' && route === '/capabilities') return json(response, 200, {
        actions: ['navigate', 'click', 'type', 'inspect', 'screenshot'], policy: policy.description,
        limits: {max_contexts: maxContexts, job_timeout_ms: jobTimeout, max_actions_per_job: 20, max_queued_per_session: 20, max_retained_jobs: maxJobs, idle_ttl_seconds: idleMs / 1000},
        isolation: 'independent ephemeral BrowserContext; no user browser profile', pointer: 'purple in-page virtual cursor; operating-system pointer is never controlled',
        network: {dns: 'public unicast addresses checked and pinned per HTTP request; explicit literal loopback exception', max_inflight_per_session: 32, max_response_bytes: 16777216, boundary: 'browser HTTP mediation; not an operating-system network sandbox'},
        unsupported: ['shell', 'arbitrary evaluation', 'native application control', 'iOS cross-app control', 'recording', 'downloads', 'popups', 'WebSocket/WebRTC/WebTransport'],
      });
      if (request.method === 'POST' && route === '/sessions') return json(response, 201, {session: await addSession(await body(request))});
      let match = /^\/sessions\/(session_[a-f0-9-]+)\/jobs$/.exec(route);
      if (match && request.method === 'POST') {
        const session = sessions.get(match[1]);
        if (!session) throw problem(404, 'session_not_found', 'Session is unavailable');
        if (session.queue.length >= 20 || jobs.size >= maxJobs) throw problem(429, 'job_capacity', 'Job capacity reached; close old sessions or wait for expiry');
        const validated = actions(await body(request), policy);
        // Body parsing yields: cancellation, shutdown or other submissions may
        // have changed all of these limits before this request can commit.
        if (shuttingDown) throw problem(503, 'shutting_down', 'The companion is stopping');
        if (session.closed || sessions.get(session.id) !== session) throw problem(404, 'session_not_found', 'Session is unavailable');
        if (session.queue.length >= 20 || jobs.size >= maxJobs) throw problem(429, 'job_capacity', 'Job capacity reached; close old sessions or wait for expiry');
        const job = {id: id('job'), session_id: session.id, status: 'queued', submitted_at: iso(), actions: validated, results: []};
        jobs.set(job.id, job); session.queue.push(job); session.touched = Date.now();
        json(response, 202, {job: viewJob(job)});
        void drain(session).catch(() => retire(session).catch(() => {})); return;
      }
      match = /^\/jobs\/(job_[a-f0-9-]+)$/.exec(route);
      if (match && request.method === 'GET') {
        const job = jobs.get(match[1]); if (!job) throw problem(404, 'job_not_found', 'Job is unavailable');
        return json(response, 200, {job: viewJob(job)});
      }
      match = /^\/screenshots\/(image_[a-f0-9-]+)$/.exec(route);
      if (match && request.method === 'GET') {
        const image = screenshots.get(match[1]); if (!image) throw problem(404, 'image_not_found', 'Screenshot is unavailable');
        response.writeHead(200, {'content-type': 'image/png', 'content-length': image.buffer.length, 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'content-security-policy': "default-src 'none'; sandbox"});
        response.end(image.buffer); return;
      }
      match = /^\/sessions\/(session_[a-f0-9-]+)$/.exec(route);
      if (match && request.method === 'DELETE') {
        const session = sessions.get(match[1]); if (!session) throw problem(404, 'session_not_found', 'Session is unavailable');
        await retire(session, true); return json(response, 200, {closed: true});
      }
      throw problem(404, 'not_found', 'Unknown companion operation');
    } catch (error) { if (!response.headersSent) json(response, error.status || 500, {error: safeError(error)}); else response.end(); }
  });
  server.requestTimeout = 5000; server.headersTimeout = 5000; server.maxHeadersCount = 40;
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(options.port ?? 3780, '127.0.0.1', resolve); });
  origin = `http://127.0.0.1:${server.address().port}`;
  return {origin, async close() {
    shuttingDown = true; clearInterval(cleanup);
    await Promise.all([...sessions.values()].map(session => retire(session, true)));
    if (browserPromise) await (await browserPromise.catch(() => null))?.close().catch(() => {});
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
  }};
}

if (require.main === module) {
  createCompanion({port: Number(process.env.COMPANION_PORT || 3780)}).then(service => {
    console.log(JSON.stringify({service: 'active-companion', listening: service.origin, headless: true}));
    let closing = false;
    for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, async () => { if (closing) return; closing = true; await service.close(); });
  }).catch(error => { console.error(JSON.stringify({error: safeError(error)})); process.exitCode = 1; });
}
module.exports = {createCompanion};
