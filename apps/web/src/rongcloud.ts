import { useEffect, useRef, useState } from 'react';
import { StartupClient } from './api';
import type { CollaborationClient } from './types';

export type TransportState = 'connecting' | 'connected' | 'disconnected' | 'unavailable';
export type TransportConfig = { appKey: string; userId: string; token: string };
type TransportNotice = { kind: 'state'; state: TransportState } | { kind: 'changed' };
declare global { interface Window { renjiDesktop?: { platform: string; writeClipboardText?: (text: string) => Promise<{ written: boolean }>; connectRongCloud: (config: TransportConfig) => Promise<{ connected: boolean }>; disconnectRongCloud: () => Promise<void>; onRongCloud: (listener: (notice: TransportNotice) => void) => () => void } } }

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
/** Commercial renderers receive authorized arrival notices from Go. RongCloud
 * credentials remain inside the trusted development receiver process. */
export function useRongCloud(client: CollaborationClient, onChanged: () => void) {
  const [state, setState] = useState<TransportState>('connecting');
  const [lastReceivedAt, setLastReceivedAt] = useState('');
  const changed = useRef(onChanged); changed.current = onChanged;
  useEffect(() => {
    const controller = new AbortController();
    setState(client instanceof StartupClient ? 'connecting' : 'unavailable');
    setLastReceivedAt('');
    if (!(client instanceof StartupClient)) return () => controller.abort();
    let cursor = 0;
    const pause = (milliseconds: number) => new Promise<void>(resolve => {
      const done = () => { clearTimeout(timer); controller.signal.removeEventListener('abort', done); resolve(); };
      const timer = setTimeout(done, milliseconds);
      controller.signal.addEventListener('abort', done, { once: true });
      if (controller.signal.aborted) done();
    });
    async function poll() {
      while (!controller.signal.aborted) {
        let delay = 1500;
        try {
          const page = await (client as StartupClient).rongCloudEvents(cursor, controller.signal);
          if (controller.signal.aborted) return;
          cursor = page.nextCursor;
          setState(page.state); setLastReceivedAt(page.lastReceivedAt);
          if (page.events.length) changed.current();
          if (page.hasMore) delay = 50;
        } catch {
          if (controller.signal.aborted) return;
          setState('unavailable'); setLastReceivedAt(''); delay = 5000;
        }
        await pause(delay);
      }
    }
    void poll(); return () => controller.abort();
  }, [client]);
  return { state, lastReceivedAt, label: ({ connecting: '融云接收桥正在连接', connected: '融云接收桥已连接', disconnected: '融云接收桥已断开', unavailable: '融云接收桥未接入' })[state] };
}
