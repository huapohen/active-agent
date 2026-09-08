import { describe, expect, it, vi } from 'vitest';
import { RongCloudWebTransport } from './rongcloud';

const config = { appKey: 'public-test-key', token: 'private-test-transport-token', userId: 'principal-mapping' };
function fakeSdk() {
  const listeners = new Map<string, (...args: never[]) => void>();
  const sdk = { Events: { CONNECTING: 'connecting', CONNECTED: 'connected', DISCONNECT: 'disconnected', SUSPEND: 'suspend', MESSAGES: 'messages' }, init: vi.fn(), connect: vi.fn(async (_token: string) => ({ code: 0, data: { userId: config.userId } })), disconnect: vi.fn(async () => {}), destroy: vi.fn(async () => {}), addEventListener: vi.fn((event: string, listener: () => void) => { listeners.set(event, listener); }), removeEventListener: vi.fn((event: string, listener: () => void) => { if (listeners.get(event) === listener) listeners.delete(event); }) };
  return { sdk, listeners, load: async () => sdk as unknown as typeof import('@rongcloud/imlib-next') };
}
describe('RongCloud receive transport', () => {
  it('registers exactly one listener per event, validates provider identity, and only invalidates business reads', async () => {
    const fake = fakeSdk(), notice = vi.fn(), transport = new RongCloudWebTransport(fake.load);
    await transport.connect(config, notice); expect(fake.sdk.connect).toHaveBeenCalledWith(config.token); expect(fake.listeners.size).toBe(5);
    fake.listeners.get('messages')?.(); expect(notice).toHaveBeenLastCalledWith({ kind: 'changed' });
    expect(notice.mock.calls.flat().some(value => JSON.stringify(value).includes(config.token))).toBe(false);
    await transport.disconnect(); expect(fake.listeners.size).toBe(0); expect(fake.sdk.disconnect).toHaveBeenCalledWith(true, true); expect(fake.sdk.destroy).toHaveBeenCalledTimes(1);
  });
  it('does not report connected or expose events when provider connected user mismatches server binding', async () => {
    const fake = fakeSdk(), notice = vi.fn(); fake.sdk.connect.mockImplementation(async () => { fake.listeners.get('connected')?.(); fake.listeners.get('messages')?.(); return { code: 0, data: { userId: 'different-user' } }; });
    const transport = new RongCloudWebTransport(fake.load); await expect(transport.connect(config, notice)).rejects.toThrow('transport_identity_unverified');
    expect(notice.mock.calls.some(call => call[0].state === 'connected' || call[0].kind === 'changed')).toBe(false); expect(fake.listeners.size).toBe(0);
  });
  it('retiring before dynamic SDK load prevents init and connect', async () => {
    const fake = fakeSdk(); let resolve!: (sdk: typeof import('@rongcloud/imlib-next')) => void;
    const transport = new RongCloudWebTransport(() => new Promise(r => { resolve = r; }));
    const connecting = transport.connect(config, vi.fn()); await transport.disconnect(); resolve(await fake.load()); await connecting;
    expect(fake.sdk.init).not.toHaveBeenCalled(); expect(fake.sdk.connect).not.toHaveBeenCalled();
  });
  it('retired listeners and a late successful connect cannot affect the next identity', async () => {
    const fake = fakeSdk(), notice = vi.fn(); let resolve!: (value: { code: number; data: { userId: string } }) => void;
    fake.sdk.connect.mockImplementation(() => new Promise(r => { resolve = r; })); const transport = new RongCloudWebTransport(fake.load);
    const connecting = transport.connect(config, notice); await Promise.resolve(); const oldListener = fake.listeners.get('messages'); await transport.disconnect();
    oldListener?.(); resolve({ code: 0, data: { userId: config.userId } }); await connecting; expect(notice).not.toHaveBeenCalled();
  });
});
