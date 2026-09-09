'use strict';
const { trustedFrame } = require('./security.cjs');

// A single write-only capability; no clipboard read, MIME selection or raw IPC.
function createClipboardWriter(getWindow, origin, writeText) {
  return async (event, value) => {
    const win = getWindow();
    if (!win || win.isDestroyed() || event.sender !== win.webContents || event.senderFrame !== win.webContents.mainFrame || !trustedFrame(event.senderFrame, origin)) throw new Error('Clipboard sender rejected');
    let url;
    try { url = new URL(event.senderFrame.url); } catch { throw new Error('Clipboard sender rejected'); }
    if (url.username || url.password || origin === 'renji://app' && url.port) throw new Error('Clipboard sender rejected');
    if (typeof value !== 'string' || value.length === 0 || value.length > 65536 || value.includes('\0')) throw new Error('Clipboard text rejected');
    try { await writeText(value); } catch { throw new Error('Clipboard write failed'); }
    return { written: true };
  };
}
module.exports = { createClipboardWriter };
