import { describe, it, expect, vi } from 'vitest';
import { ApiError, LegacyClient, StartupClient, legacyRequestURL, message, normalizeEndpoint } from './api';

const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });
const sent = { id: 'm-1', room_id: 'r-1', author_id: 'p-1', content: '中文消息', seq: 4, created_at: '2026-09-09T01:00:00Z' };
describe('credential and domain boundary', () => {
  it('calls browser-native fetch with its Window receiver for authenticated reads', async () => {
    const browserFetch = vi.fn(function (this: unknown, _input: RequestInfo | URL, _init?: RequestInit) {
      if (this !== globalThis) throw new TypeError("Failed to execute 'fetch' on 'Window': Illegal invocation");
      return Promise.resolve(json({ principal: { id: 'human1', kind: 'human', display_name: '已登录同事' } }));
    });
    const client = new LegacyClient('http://127.0.0.1:3218', async () => 'session-token', browserFetch);
    expect((await client.me()).displayName).toBe('已登录同事');
    expect(browserFetch).toHaveBeenCalledTimes(1);
  });
  it('proxies only the explicitly fixed local migration source in development', () => {
    expect(legacyRequestURL('http://127.0.0.1:3218', '/auth/login', true)).toBe('/legacy/api/im/auth/login');
    expect(legacyRequestURL('http://127.0.0.1:3218', '/auth/login', false)).toBe('http://127.0.0.1:3218/api/im/auth/login');
    expect(legacyRequestURL('https://other.example', '/auth/login', true)).toBe('https://other.example/api/im/auth/login');
    expect(legacyRequestURL('http://127.0.0.1:3318', '/auth/login', true)).toBe('http://127.0.0.1:3318/api/im/auth/login');
  });
  it('accepts HTTPS and loopback only, with no userinfo or query credentials', () => {
    expect(normalizeEndpoint('http://127.0.0.1:3318/')).toBe('http://127.0.0.1:3318');
    expect(normalizeEndpoint('https://workspace.example/path/')).toBe('https://workspace.example/path');
    for (const url of ['http://example.com', 'https://user:password@example.com', 'https://example.com?token=secret', 'file:///tmp/a', 'https://example.com#secret']) expect(() => normalizeEndpoint(url)).toThrow();
  });
  it('sends only authoritative Go intent fields with current bearer and no identity header', async () => {
    const fetcher = vi.fn(async () => json({ message: sent, replayed: false }));
    const client = new StartupClient('http://127.0.0.1:3318', async () => 'session-one', fetcher);
    const response = await client.send('r-1', { actionId: 'action-1', content: '中文消息', mentions: [], scopeEpoch: 3 });
    expect(response.id).toBe('m-1');
    const [url, options] = fetcher.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe('http://127.0.0.1:3318/v1/rooms/r-1/messages');
    expect(JSON.parse(options.body as string)).toEqual({ action_id: 'action-1', content: '中文消息', scope_epoch: 3 });
    expect(options.headers).toEqual({ Authorization: 'Bearer session-one', Accept: 'application/json', 'Content-Type': 'application/json' });
    expect(options.redirect).toBe('error'); expect(options.credentials).toBe('omit');
  });
  it('does not fallback to legacy password after startup auth fails or leak raw errors', async () => {
    const fetcher = vi.fn(async () => json({ code: 'invalid_token', error: 'sensitive raw payload' }, 401));
    const client = new StartupClient('https://work.example', async () => 'bad', fetcher);
    await expect(client.me()).rejects.toMatchObject({ status: 401, message: '登录已失效，请重新登录' });
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect((fetcher.mock.calls[0] as unknown as [string])[0]).toBe('https://work.example/v1/me');
  });
  it('retiring a client while token acquisition is pending prevents the request', async () => {
    let resolve!: (token: string) => void;
    const fetcher = vi.fn(); const client = new StartupClient('https://work.example', () => new Promise(r => { resolve = r; }), fetcher);
    const pending = client.me(); client.close(); resolve('old-token');
    await expect(pending).rejects.toMatchObject({ name: 'AbortError' }); expect(fetcher).not.toHaveBeenCalled();
  });
  it('retiring a client rejects a late successful response and all future calls', async () => {
    let resolve!: (value: Response) => void;
    const fetcher = vi.fn(() => new Promise<Response>(r => { resolve = r; }));
    const client = new StartupClient('https://work.example', async () => 'old-token', fetcher);
    const pending = client.me(); await Promise.resolve(); client.close(); resolve(json({ principal: { id: 'old', kind: 'human', display_name: '旧身份' } }));
    await expect(pending).rejects.toMatchObject({ name: 'AbortError' });
    await expect(client.rooms()).rejects.toMatchObject({ name: 'AbortError' }); expect(fetcher).toHaveBeenCalledTimes(1);
  });
  it('uses fresh Clerk token for each request and validates transport binding shape', async () => {
    const token = vi.fn().mockResolvedValueOnce('one').mockResolvedValueOnce('two');
    const fetcher = vi.fn().mockResolvedValueOnce(json({ rooms: [], cursor: 0 })).mockResolvedValueOnce(json({ app_key: 'public-key', user_id: 'principal-mapping', token: 'transport-token' }));
    const client = new StartupClient('https://work.example', token, fetcher);
    await client.rooms(); expect(await client.rongCloudSession()).toEqual({ appKey: 'public-key', userId: 'principal-mapping', token: 'transport-token' });
    expect(fetcher.mock.calls.map(call => call[1].headers.Authorization)).toEqual(['Bearer one', 'Bearer two']);
  });
  it('legacy login and send preserve the old protocol, with no password persistence', async () => {
    const fetcher = vi.fn().mockResolvedValueOnce(json({ token: 'old-session' })).mockResolvedValueOnce(json({ message: { ...sent, created_at: undefined, at: sent.created_at } }));
    const client = await LegacyClient.login('http://localhost:3218', 'human', 'password', undefined, fetcher);
    await client.send('r-1', { actionId: 'same-retry-id', content: '中文消息', mentions: ['agent-1'] });
    expect(fetcher.mock.calls[1][0]).toContain('/api/im/rooms/r-1/messages');
    expect(JSON.parse(fetcher.mock.calls[1][1].body)).toEqual({ client_id: 'same-retry-id', content: '中文消息', mentions: ['agent-1'], mention_all: false, attachment_ids: [] });
    client.close(); await expect(client.me()).rejects.toMatchObject({ name: 'AbortError' });
  });
  it('shows receipts only when the server explicitly knows original recipients', () => {
    expect(message({ ...sent, receipt_summary: { known: false, read_count: null, eligible_count: null } }).receipt).toBeUndefined();
    expect(message({ ...sent, receipt_summary: { known: true, read_count: 2, eligible_count: 3 } }).receipt).toEqual({ read: 2, total: 3 });
  });
  it('rejects malformed message sequence, rather than inventing a timestamp or ordering', () => {
    expect(() => message({ ...sent, seq: '4' })).toThrow(ApiError);
    expect(message({ ...sent, created_at: undefined }).createdAt).toBe('');
  });
});
