'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createClipboardWriter } = require('../src/clipboard.cjs');
function fixture(origin = 'http://127.0.0.1:5173') {
  const frame = { url: `${origin}/index.html` }, sender = { mainFrame: frame };
  const win = { webContents: sender, isDestroyed: () => false }, writes = [];
  return { frame, sender, win, writes, event: { sender, senderFrame: frame }, handler: createClipboardWriter(() => win, origin, async text => { writes.push(text); }) };
}
test('only exact current application main frame may write at trusted dev or packaged origin', async () => {
  for (const origin of ['http://127.0.0.1:5173', 'renji://app']) {
    const f = fixture(origin);
    assert.deepEqual(await f.handler(f.event, '合成复制'), { written: true });
    for (const event of [{ ...f.event, sender: {} }, { ...f.event, senderFrame: { ...f.frame } }, { ...f.event, senderFrame: { url: f.frame.url, parent: f.frame } }, { ...f.event, senderFrame: undefined }]) await assert.rejects(f.handler(event, 'refused'), /Clipboard sender rejected/);
    for (const url of ['http://127.0.0.1:5174/', 'http://127.0.0.1.evil.test/', 'renji://transport/index.html', 'renji://user@app/index.html', 'renji://app:8080/index.html', 'about:blank']) { f.frame.url = url; await assert.rejects(f.handler(f.event, 'refused'), /Clipboard sender rejected/); }
    assert.deepEqual(f.writes, ['合成复制']);
  }
});
test('closed and replaced windows cannot issue late clipboard requests', async () => {
  const f = fixture(); f.win.isDestroyed = () => true;
  await assert.rejects(f.handler(f.event, 'refused'), /Clipboard sender rejected/);
  await assert.rejects(createClipboardWriter(() => undefined, 'renji://app', () => { throw new Error('must not write'); })(f.event, 'refused'), /Clipboard sender rejected/);
  assert.equal(f.writes.length, 0);
});
test('clipboard accepts only bounded plain strings and never echoes their content', async () => {
  const f = fixture();
  for (const value of [undefined, null, {}, ['text'], 1, '', 'x\0y', 'x'.repeat(65537)]) await assert.rejects(f.handler(f.event, value), /Clipboard text rejected/);
  const value = '中'.repeat(65536); assert.deepEqual(await f.handler(f.event, value), { written: true }); assert.equal(f.writes.length, 1);
});
test('native asynchronous failure is sanitized and acknowledgement waits for completed write', async () => {
  const f = fixture(); let release; let done = false;
  const handler = createClipboardWriter(() => f.win, 'http://127.0.0.1:5173', () => new Promise(resolve => { release = resolve; }));
  const result = handler(f.event, 'sensitive synthetic text').then(value => { done = true; return value; });
  await Promise.resolve(); assert.equal(done, false); release(); assert.deepEqual(await result, { written: true });
  const failed = createClipboardWriter(() => f.win, 'http://127.0.0.1:5173', async () => { throw new Error('must not expose supplied content'); });
  await assert.rejects(failed(f.event, 'sensitive synthetic text'), error => error.message === 'Clipboard write failed');
});
