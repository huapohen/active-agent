'use strict';
const {contextBridge,ipcRenderer}=require('electron');
// Official Web IMLib uses its own WSS connection. No native engine bridge is
// installed in this worker, and no arbitrary IPC or Node API is exposed.
contextBridge.exposeInMainWorld('trustedReceiveBridge', {
  start: listener => ipcRenderer.on('bridge:start',(_event,config)=>listener(config)),
  report: value => ipcRenderer.send('bridge:report',value),
  ready: () => ipcRenderer.send('bridge:ready'),
});
