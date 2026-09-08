'use strict';
const { contextBridge, ipcRenderer } = require('electron');

// Product renderer has no generic IPC, shell execution, keyboard or file API.
contextBridge.exposeInMainWorld('renjiDesktop', {
  platform: process.platform,
  connectRongCloud: config => ipcRenderer.invoke('renji:transport:connect', config),
  disconnectRongCloud: () => ipcRenderer.invoke('renji:transport:disconnect'),
  onRongCloud: callback => {
    const listener = (_event, notice) => callback(notice);
    ipcRenderer.on('renji:transport:notice', listener);
    return () => ipcRenderer.removeListener('renji:transport:notice', listener);
  },
});
