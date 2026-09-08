'use strict';
const { contextBridge, ipcRenderer } = require('electron');
// Only the isolated transport window loads the vendor's broad native bridge.
// This window serves no messages, user HTML, Clerk pages or remote navigation.
require('@rongcloud/electron-renderer');
contextBridge.exposeInMainWorld('renjiTransportWorker', {
  onConnect: callback => {
    const listener = (_event, config) => callback(config);
    ipcRenderer.on('renji:worker:connect', listener);
    return () => ipcRenderer.removeListener('renji:worker:connect', listener);
  },
  onDisconnect: callback => {
    const listener = (_event, request) => callback(request);
    ipcRenderer.on('renji:worker:disconnect', listener);
    return () => ipcRenderer.removeListener('renji:worker:disconnect', listener);
  },
  notice: notice => ipcRenderer.send('renji:worker:notice', notice),
  ready: () => ipcRenderer.send('renji:worker:ready'),
});
