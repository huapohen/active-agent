import { act, cleanup, renderHook, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { StartupClient } from './api';
import { useRongCloud } from './rongcloud';

afterEach(() => { cleanup(); vi.useRealTimers(); });
const idle = { events: [], nextCursor: 0, hasMore: false, state: 'unavailable' as const, lastReceivedAt: '' };
it('uses authorized Go notices without issuing a provider session or connecting a renderer SDK', async () => {
  const client = new StartupClient('http://localhost:3318', vi.fn());
  const sessions = vi.spyOn(client, 'rongCloudSession');
  const read = vi.spyOn(client, 'rongCloudEvents').mockResolvedValue({ ...idle, state: 'connected', events: [{ cursor: 3, roomId: 'r', messageId: 'm' }], nextCursor: 3, lastReceivedAt: '2026-09-09T01:00:00Z' });
  const changed = vi.fn(); const view = renderHook(() => useRongCloud(client, changed));
  await waitFor(() => expect(view.result.current.label).toBe('融云接收桥已连接'));
  expect(view.result.current.lastReceivedAt).toBe('2026-09-09T01:00:00Z');
  expect(changed).toHaveBeenCalledTimes(1); expect(read.mock.calls[0][0]).toBe(0); expect(sessions).not.toHaveBeenCalled();
});
it('does not pretend HTTP availability or another principal coverage is a RongCloud connection', async () => {
  const client = new StartupClient('http://localhost:3318', vi.fn());
  vi.spyOn(client, 'rongCloudEvents').mockResolvedValue(idle);
  const changed = vi.fn(); const view = renderHook(() => useRongCloud(client, changed));
  await waitFor(() => expect(view.result.current.label).toBe('融云接收桥未接入'));
  expect(changed).not.toHaveBeenCalled(); expect(view.result.current.lastReceivedAt).toBe('');
});
it('isolates delayed arrival and connection status across account changes', async () => {
  const a = new StartupClient('http://localhost:3318', vi.fn()), b = new StartupClient('http://localhost:3318', vi.fn());
  let resolve!: (value: Awaited<ReturnType<StartupClient['rongCloudEvents']>>) => void;
  vi.spyOn(a, 'rongCloudEvents').mockImplementation(() => new Promise(r => { resolve = r; }));
  vi.spyOn(b, 'rongCloudEvents').mockResolvedValue(idle);
  const changed = vi.fn(); const view = renderHook(({ client }) => useRongCloud(client, changed), { initialProps: { client: a } });
  view.rerender({ client: b }); await waitFor(() => expect(view.result.current.state).toBe('unavailable'));
  await act(async () => { resolve({ ...idle, state: 'connected', events: [{ cursor: 1, roomId: 'foreign', messageId: 'm' }], nextCursor: 1 }); });
  expect(changed).not.toHaveBeenCalled(); expect(view.result.current.state).toBe('unavailable');
});
it('rejects malformed provider notice cursors and never accepts a false route mode', async () => {
  const base = { schema: 'renji.transport.events.v1', transport: 'rongcloud', mode: 'trusted_development_bridge', events: [], next_cursor: 2, has_more: false, status: { bridge_state: 'unavailable', last_heartbeat_at: null, last_received_at: null } };
  const response = vi.fn(async () => new Response(JSON.stringify(base), { status: 200 }));
  const client = new StartupClient('http://localhost:3318', async () => 'synthetic-token', response);
  expect(await client.rongCloudEvents(2)).toMatchObject({ state: 'unavailable', nextCursor: 2 });
  response.mockResolvedValueOnce(new Response(JSON.stringify({ ...base, mode: 'native_sdk' })));
  await expect(client.rongCloudEvents(2)).rejects.toMatchObject({ code: 'invalid_transport_events' });
  response.mockResolvedValueOnce(new Response(JSON.stringify({ ...base, next_cursor: 1 })));
  await expect(client.rongCloudEvents(2)).rejects.toMatchObject({ code: 'invalid_transport_events' });
});
