'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const { developmentURL, trustedFrame, assetPath, validTransportConfig } = require('../src/security.cjs');
test('development origin cannot load a remote page or embedded credential', () => {
  assert.equal(developmentURL('http://127.0.0.1:5173/'), 'http://127.0.0.1:5173');
  for (const url of ['https://evil.example', 'file:///tmp/page', 'http://user:pass@localhost:5173', 'http://127.0.0.1:5173?token=x']) assert.throws(() => developmentURL(url));
});
test('only our main frame can use business IPC', () => {
  assert.equal(trustedFrame({ url: 'http://127.0.0.1:5173/path' }, 'http://127.0.0.1:5173'), true);
  assert.equal(trustedFrame({ url: 'http://127.0.0.1:5173/path', parent: {} }, 'http://127.0.0.1:5173'), false);
  assert.equal(trustedFrame({ url: 'http://127.0.0.1:5173.evil.example' }, 'http://127.0.0.1:5173'), false);
  assert.equal(trustedFrame({ url: 'renji://transport/index.html' }, 'renji://app'), false);
});
test('static asset resolver rejects encoded traversal and mixed slashes', () => {
  const base = path.resolve('/tmp/renji-renderer'); assert.equal(assetPath(base, '/'), path.join(base, 'index.html'));
  assert.equal(assetPath(base, '/assets/ui.js'), path.join(base, 'assets/ui.js'));
  for (const value of ['/../secret', '/%2e%2e/secret', '/a\\..\\secret', '/%00secret', '/%zz']) assert.throws(() => assetPath(base, value));
});
test('transport session requires the configured app and bounded fields', () => {
  const config = { appKey: 'public-app', userId: 'mapped-principal', token: 'transport-token' };
  assert.equal(validTransportConfig(config, 'public-app'), true);
  assert.equal(validTransportConfig(config, 'different-app'), false);
  assert.equal(validTransportConfig({ ...config, method: 'readFile' }, 'public-app'), false);
  assert.equal(validTransportConfig({ ...config, token: 'x'.repeat(8193) }, 'public-app'), false);
});
test('product preload provides only typed transport API and strips raw IPC events', async () => {
  const listeners = new Map(), calls = [], published = {};
  const ipc = { invoke: (...args) => { calls.push(args); return Promise.resolve(); }, on: (name, callback) => listeners.set(name, callback), removeListener: (name, callback) => { if (listeners.get(name) === callback) listeners.delete(name); } };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../src/preload.cjs'), 'utf8'), { require: name => { assert.equal(name, 'electron'); return { contextBridge: { exposeInMainWorld: (name, value) => { published[name] = value; } }, ipcRenderer: ipc }; }, process: { platform: 'darwin' } });
  const bridge = published.renjiDesktop;
  assert.deepEqual(Object.keys(bridge).sort(), ['connectRongCloud', 'disconnectRongCloud', 'onRongCloud', 'platform']);
  let received; const off = bridge.onRongCloud(value => { received = value; });
  listeners.get('renji:transport:notice')({ sender: 'privileged-object' }, { kind: 'changed' });
  assert.deepEqual(received, { kind: 'changed' }); off(); assert.equal(listeners.size, 0);
  await bridge.disconnectRongCloud(); assert.deepEqual(calls, [['renji:transport:disconnect']]);
});
test('all four native SDK packages share an exact version', () => {
  const desktop = require('../package.json'), web = require('../../web/package.json');
  const versions = [web.dependencies['@rongcloud/engine'], web.dependencies['@rongcloud/imlib-next'], desktop.dependencies['@rongcloud/electron'], desktop.dependencies['@rongcloud/electron-renderer']];
  assert.equal(new Set(versions).size, 1); assert.match(versions[0], /^\d+\.\d+\.\d+$/);
});
