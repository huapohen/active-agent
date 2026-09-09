'use strict';
const {contextBridge,ipcRenderer}=require('electron');
require('@rongcloud/electron-renderer');
contextBridge.exposeInMainWorld('trustedReceiveBridge', {
  start: listener => ipcRenderer.on('bridge:start',(_event,config)=>listener(config)),
  report: value => ipcRenderer.send('bridge:report',value),
  ready: () => ipcRenderer.send('bridge:ready'),
});
