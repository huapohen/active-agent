'use strict';
const { app, BrowserWindow, ipcMain, protocol, net, session } = require('electron');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { randomUUID } = require('node:crypto');
const { developmentURL, trustedFrame, assetPath, validTransportConfig } = require('./security.cjs');

protocol.registerSchemesAsPrivileged([{ scheme: 'renji', privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true } }]);
const requested = process.env.RENJI_WEB_DEV_URL;
const uiOrigin = requested ? developmentURL(requested) : 'renji://app';
const appKey = process.env.RENJI_RONGCLOUD_APP_KEY || '';
const dist = path.resolve(__dirname, '../dist');
let window, worker, rcService, generation = 0, workerReady;
const pending = new Map();
let transportUncertain = false;
const rendererPreferences = { contextIsolation: true, nodeIntegration: false, sandbox: true, webSecurity: true, allowRunningInsecureContent: false };

function harden(win, origin) {
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', (event, url) => {
    const trusted = origin === 'renji://transport' ? url.startsWith('renji://transport/') : trustedFrame({ url }, origin);
    if (!trusted) event.preventDefault();
  });
  win.webContents.on('will-attach-webview', event => event.preventDefault());
}
async function disconnectTransport() {
  generation++;
  if (worker && !worker.isDestroyed()) await workerRequest('disconnect', {});
}
function workerRequest(action, value) {
  const requestId = randomUUID();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(requestId); transportUncertain = true; reject(new Error('Transport outcome unknown; restart required')); }, 30000);
    pending.set(requestId, { generation, finish: ok => { clearTimeout(timer); pending.delete(requestId); if (ok) resolve({ connected: action === 'connect' }); else { transportUncertain = true; reject(new Error('Transport operation failed')); } } });
    worker.webContents.send(`renji:worker:${action}`, { ...value, requestId, generation });
  });
}
async function createTransport(config) {
  if (transportUncertain) throw new Error('Transport outcome unknown; restart required');
  await disconnectTransport();
  if (worker && !worker.isDestroyed()) return workerRequest('connect', config);
  const initialize = require('@rongcloud/electron');
  rcService ||= initialize({ appkey: appKey, dbpath: app.getPath('userData'), logOutputLevel: 1, disableLogReport: true });
  worker = new BrowserWindow({ show: false, webPreferences: { ...rendererPreferences, preload: path.join(dist, 'transport-preload.cjs'), partition: 'renji-transport' } });
  harden(worker, 'renji://transport');
  const current = worker;
  const ready = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Transport worker unavailable')), 15000);
    workerReady = () => { clearTimeout(timer); resolve(); };
    current.webContents.once('render-process-gone', () => { clearTimeout(timer); reject(new Error('Transport worker closed')); });
  });
  await current.loadURL('renji://transport/index.html');
  await ready;
  if (current.isDestroyed()) return { connected: false };
  return workerRequest('connect', config);
}

if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', () => { if (window) { if (window.isMinimized()) window.restore(); window.focus(); } });
  app.whenReady().then(async () => {
    const serve = request => {
      const url = new URL(request.url);
      try {
        if (url.hostname === 'app') return net.fetch(pathToFileURL(assetPath(path.resolve(__dirname, '../../web/dist'), url.pathname)).href);
        if (url.hostname === 'transport') return net.fetch(pathToFileURL(assetPath(dist, url.pathname)).href);
      } catch { /* Deliberately omit request paths and possible credentials. */ }
      return new Response('Not found', { status: 404 });
    };
    protocol.handle('renji', serve);
    session.fromPartition('renji-transport').protocol.handle('renji', serve);
    for (const ses of [session.defaultSession, session.fromPartition('renji-transport')]) {
      ses.setPermissionRequestHandler((_webContents, _permission, callback) => callback(false));
      ses.setPermissionCheckHandler(() => false);
    }
    let operation = Promise.resolve();
    ipcMain.handle('renji:transport:connect', (event, config) => {
      if (!window || event.sender !== window.webContents || !trustedFrame(event.senderFrame, uiOrigin) || !appKey || !validTransportConfig(config, appKey)) throw new Error('Transport configuration rejected');
      const result = operation.then(() => createTransport(config)); operation = result.catch(() => {}); return result;
    });
    ipcMain.handle('renji:transport:disconnect', event => {
      if (!window || event.sender !== window.webContents || !trustedFrame(event.senderFrame, uiOrigin)) throw new Error('Untrusted transport request');
      const result = operation.then(disconnectTransport); operation = result.catch(() => {}); return result;
    });
    ipcMain.on('renji:worker:ready', event => { if (worker && event.sender === worker.webContents && event.senderFrame?.url === 'renji://transport/index.html') workerReady?.(); });
    ipcMain.on('renji:worker:notice', (event, notice) => {
      if (!worker || event.sender !== worker.webContents || event.senderFrame?.url !== 'renji://transport/index.html' || notice?.generation !== generation || !window || window.isDestroyed()) return;
      if (notice.kind === 'result') { const request = pending.get(notice.requestId); if (request?.generation === generation) request.finish(notice.ok === true); return; }
      if (notice.kind === 'changed') window.webContents.send('renji:transport:notice', { kind: 'changed' });
      else if (notice.kind === 'state' && ['connecting', 'connected', 'disconnected', 'unavailable'].includes(notice.state)) window.webContents.send('renji:transport:notice', { kind: 'state', state: notice.state });
    });
    window = new BrowserWindow({ title: '人机', width: 1280, height: 850, minWidth: 760, minHeight: 520, backgroundColor: '#ffffff', webPreferences: { ...rendererPreferences, preload: path.join(dist, 'preload.cjs') } });
    harden(window, uiOrigin);
    window.on('closed', () => { window = undefined; if (worker && !worker.isDestroyed()) worker.destroy(); worker = undefined; app.quit(); });
    await window.loadURL(requested ? `${uiOrigin}/` : 'renji://app/index.html');
  }).catch(() => { console.error('人机启动未完成，请检查构建与本机配置。'); app.quit(); });
  app.on('before-quit', () => { if (rcService) { rcService.destroy(); rcService = undefined; } });
  app.on('window-all-closed', () => app.quit());
}
