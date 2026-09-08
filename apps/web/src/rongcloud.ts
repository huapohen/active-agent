import { useEffect, useRef, useState } from 'react';
import { StartupClient } from './api';
import type { CollaborationClient } from './types';

export type TransportState = 'connecting' | 'connected' | 'disconnected' | 'unavailable';
export type TransportConfig = { appKey: string; userId: string; token: string };
type TransportNotice = { kind: 'state'; state: TransportState } | { kind: 'changed' };
declare global { interface Window { renjiDesktop?: { platform: string; connectRongCloud: (config: TransportConfig) => Promise<{ connected: boolean }>; disconnectRongCloud: () => Promise<void>; onRongCloud: (listener: (notice: TransportNotice) => void) => () => void } } }

export interface ReceiveTransport { connect(config: TransportConfig, notice: (notice: TransportNotice) => void): Promise<void>; disconnect(): Promise<void> }

/** Web SDK owns a single connection. Serialize account changes and destroy the
 * old session before init; late callbacks never become a new user's events. */
export class RongCloudWebTransport implements ReceiveTransport {
  private sdk?: typeof import('@rongcloud/imlib-next');
  private alive = false;
  private verified = false;
  private unlisten: (() => void)[] = [];
  constructor(private load: () => Promise<typeof import('@rongcloud/imlib-next')> = () => import('@rongcloud/imlib-next')) {}
  async connect(config: TransportConfig, notice: (notice: TransportNotice) => void): Promise<void> {
    this.alive = true;
    const sdk = await this.load();
    if (!this.alive) return;
    this.sdk = sdk;
    sdk.init({ appkey: config.appKey, logOutputLevel: 1 });
    const connecting = () => { if (this.alive) notice({ kind: 'state', state: 'connecting' }); };
    const connected = () => { if (this.alive && this.verified) { notice({ kind: 'state', state: 'connected' }); notice({ kind: 'changed' }); } };
    const disconnected = () => { if (this.alive) notice({ kind: 'state', state: 'disconnected' }); };
    const changed = () => { if (this.alive && this.verified) notice({ kind: 'changed' }); };
    sdk.addEventListener(sdk.Events.CONNECTING, connecting);
    sdk.addEventListener(sdk.Events.CONNECTED, connected);
    sdk.addEventListener(sdk.Events.DISCONNECT, disconnected);
    sdk.addEventListener(sdk.Events.SUSPEND, connecting);
    sdk.addEventListener(sdk.Events.MESSAGES, changed);
    this.unlisten = [() => sdk.removeEventListener(sdk.Events.CONNECTING, connecting), () => sdk.removeEventListener(sdk.Events.CONNECTED, connected), () => sdk.removeEventListener(sdk.Events.DISCONNECT, disconnected), () => sdk.removeEventListener(sdk.Events.SUSPEND, connecting), () => sdk.removeEventListener(sdk.Events.MESSAGES, changed)];
    const result = await sdk.connect(config.token);
    if (!this.alive) return;
    if (result.code !== 0 || result.data?.userId !== config.userId) { await this.disconnect(); throw new Error('transport_identity_unverified'); }
    this.verified = true;
    connected();
  }
  async disconnect() { this.alive = false; this.verified = false; for (const off of this.unlisten) off(); this.unlisten = []; const sdk = this.sdk; this.sdk = undefined; if (sdk) { await sdk.disconnect(true, true); await sdk.destroy(); } }
}
class RongCloudDesktopTransport implements ReceiveTransport {
  private off?: () => void;
  async connect(config: TransportConfig, notice: (notice: TransportNotice) => void) { const bridge = window.renjiDesktop!; this.off = bridge.onRongCloud(notice); const result = await bridge.connectRongCloud(config); if (!result.connected) throw new Error('desktop_transport_unavailable'); }
  async disconnect() { this.off?.(); this.off = undefined; await window.renjiDesktop!.disconnectRongCloud(); }
}
let transportQueue = Promise.resolve();
let transportCleanupUncertain = false;
export function useRongCloud(client: CollaborationClient, onChanged: () => void) {
  const [state, setState] = useState<TransportState>('connecting');
  const changed = useRef(onChanged); changed.current = onChanged;
  useEffect(() => {
    if (!(client instanceof StartupClient)) { setState('unavailable'); return; }
    const controller = new AbortController();
    let live = true;
    const transport: ReceiveTransport = window.renjiDesktop ? new RongCloudDesktopTransport() : new RongCloudWebTransport();
    const notice = (event: TransportNotice) => { if (!live) return; if (event.kind === 'changed') changed.current(); else setState(event.state); };
    // Setup does not block cleanup on a still-pending provider connect promise.
    transportQueue = transportQueue.then(async () => {
      if (!live) return;
      if (transportCleanupUncertain) { setState('unavailable'); return; }
      const config = await client.rongCloudSession(controller.signal);
      if (!live) return;
      void transport.connect(config, notice).catch(() => { if (live) setState('unavailable'); });
    }).catch(() => { if (live) setState('unavailable'); });
    return () => { live = false; controller.abort(); transportQueue = transportQueue.then(() => transport.disconnect()).catch(() => { transportCleanupUncertain = true; }); };
  }, [client]);
  return { state, label: ({ connecting: '融云正在连接', connected: '融云已连接', disconnected: '融云连接已断开', unavailable: '融云暂不可用' })[state] };
}
