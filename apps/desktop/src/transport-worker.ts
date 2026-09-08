import * as sdk from '@rongcloud/imlib-next';

declare global { interface Window { renjiTransportWorker: { onConnect: (callback: (config: { appKey: string; userId: string; token: string; generation: number; requestId: string }) => void) => void; onDisconnect: (callback: (request: { generation: number; requestId: string }) => void) => void; notice: (value: unknown) => void; ready: () => void } } }
const bridge = window.renjiTransportWorker;
let generation = 0;
let initialized = false;
let verified = false;
let operation = Promise.resolve();
const notice = (value: object) => bridge.notice({ generation, ...value });
bridge.onConnect(config => { operation = operation.then(async () => {
  generation = config.generation;
  verified = false;
  try {
    if (!initialized) {
    sdk.init({ appkey: config.appKey, logOutputLevel: 1 }); initialized = true;
    sdk.addEventListener(sdk.Events.CONNECTING, () => notice({ kind: 'state', state: 'connecting' }));
    sdk.addEventListener(sdk.Events.CONNECTED, () => { if (verified) { notice({ kind: 'state', state: 'connected' }); notice({ kind: 'changed' }); } });
    sdk.addEventListener(sdk.Events.SUSPEND, () => notice({ kind: 'state', state: 'connecting' }));
    sdk.addEventListener(sdk.Events.DISCONNECT, () => notice({ kind: 'state', state: 'disconnected' }));
    sdk.addEventListener(sdk.Events.MESSAGES, () => { if (verified) notice({ kind: 'changed' }); });
    }
    const result = await sdk.connect(config.token);
    if (result.code !== 0 || result.data?.userId !== config.userId) { await sdk.disconnect(true, true); notice({ kind: 'state', state: 'unavailable' }); notice({ kind: 'result', requestId: config.requestId, ok: false }); return; }
    verified = true; notice({ kind: 'state', state: 'connected' }); notice({ kind: 'changed' });
    notice({ kind: 'result', requestId: config.requestId, ok: true });
  } catch { notice({ kind: 'state', state: 'unavailable' }); notice({ kind: 'result', requestId: config.requestId, ok: false }); }
}); });
bridge.onDisconnect(request => {
  // Fence events immediately, but serialize the actual SDK transition.
  generation = request.generation;
  verified = false;
  operation = operation.then(async () => { try { if (initialized) await sdk.disconnect(true, true); notice({ kind: 'result', requestId: request.requestId, ok: true }); } catch { notice({ kind: 'result', requestId: request.requestId, ok: false }); } });
});
bridge.ready();
