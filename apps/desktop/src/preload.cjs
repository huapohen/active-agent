'use strict';
const { contextBridge, ipcRenderer } = require('electron');

// Product renderer has no generic IPC, shell execution, keyboard or file API.
contextBridge.exposeInMainWorld('renjiDesktop', {
  platform: process.platform,
  writeClipboardText: text => {
    if (typeof text !== 'string' || text.length === 0 || text.length > 65536 || text.includes('\0')) return Promise.reject(new Error('Clipboard text rejected'));
    return ipcRenderer.invoke('renji:clipboard:write-text', text);
  },
  connectRongCloud: config => ipcRenderer.invoke('renji:transport:connect', config),
  disconnectRongCloud: () => ipcRenderer.invoke('renji:transport:disconnect'),
  onRongCloud: callback => {
    const listener = (_event, notice) => callback(notice);
    ipcRenderer.on('renji:transport:notice', listener);
    return () => ipcRenderer.removeListener('renji:transport:notice', listener);
  },
});
