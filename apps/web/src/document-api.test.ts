import { describe, expect, it, vi } from 'vitest';
import { LegacyClient, StartupClient } from './api';
const payload = { id: 'doc_actual-shape', title: '受权文档', content: '# 正文\n\n| A | B |\n|---|---|\n| 人 | Agent |', revision: 3, updated_at: 1788899408121, content_hash: 'a'.repeat(64), contract: null };
const json = (document: unknown, status = 200) => new Response(JSON.stringify(status === 200 ? { document } : { code: 'document_scope' }), { status, headers: { 'Content-Type': 'application/json' } });
describe('authorized document native protocol', () => {
  it('reads actual room-scoped shape with fresh bearer, epoch timestamp and no URL credential', async () => {
    const fetcher = vi.fn(async () => json(payload));
    const client = new LegacyClient('http://127.0.0.1:3218', async () => 'synthetic-session', fetcher);
    const result = await client.document('room/a', payload.id);
    expect(result).toEqual({ id: payload.id, roomId: 'room/a', title: payload.title, content: payload.content, revision: 3, updatedAt: '2026-09-08T20:30:08.121Z', contentHash: payload.content_hash });
    const [url, init] = fetcher.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe('/legacy/api/im/rooms/room%2Fa/documents/doc_actual-shape');
    expect(url).not.toContain('synthetic-session'); expect(init.headers).toMatchObject({ Authorization: 'Bearer synthetic-session' });
    expect(init.method).toBe('GET'); expect(init.body).toBeUndefined(); expect(init.cache).toBe('no-store'); expect(init.credentials).toBe('omit'); expect(init.redirect).toBe('error');
  });
  it('rejects a mismatched ID, missing body, invalid version/hash and oversized body', async () => {
    for (const change of [{ id: 'another' }, { content: undefined }, { revision: '3' }, { revision: -1 }, { content_hash: 'invalid' }, { content: 'x'.repeat(200001) }]) {
      const client = new LegacyClient('http://localhost:3218', async () => 'synthetic', vi.fn(async () => json({ ...payload, ...change })));
      await expect(client.document('room-a', payload.id)).rejects.toMatchObject({ status: 502, code: 'invalid_document' });
    }
  });
  it('rejects 401/403/404 without retrying through a document management bypass', async () => {
    for (const status of [401, 403, 404]) {
      const fetcher = vi.fn(async () => json({}, status)); const client = new LegacyClient('http://localhost:3218', async () => 'synthetic', fetcher);
      await expect(client.document('room-a', payload.id)).rejects.toMatchObject({ status }); expect(fetcher).toHaveBeenCalledTimes(1);
      expect((fetcher.mock.calls[0] as unknown as [string])[0]).toContain('/api/im/rooms/room-a/documents/');
    }
  });
  it('discards an old response after adapter retirement and does not persist its token', async () => {
    const storage = vi.spyOn(Storage.prototype, 'setItem'); let resolve!: (r: Response) => void;
    const fetcher = vi.fn(() => new Promise<Response>(r => { resolve = r; }));
    const client = new LegacyClient('http://localhost:3218', async () => 'synthetic', fetcher);
    const pending = client.document('room-a', payload.id); await Promise.resolve(); client.close(); resolve(json(payload));
    await expect(pending).rejects.toMatchObject({ name: 'AbortError' }); expect(storage).not.toHaveBeenCalled();
  });
  it('honors cancellation and blocks missing context before any request', async () => {
    const fetcher = vi.fn(async () => json(payload)); const client = new LegacyClient('http://localhost:3218', async () => 'synthetic', fetcher);
    const controller = new AbortController(); controller.abort();
    await expect(client.document('room-a', payload.id, controller.signal)).rejects.toMatchObject({ name: 'AbortError' });
    await expect(client.document('', payload.id)).rejects.toMatchObject({ status: 422 });
    await expect(client.document('room-a', '../outside')).rejects.toMatchObject({ status: 422 });
    expect(fetcher).not.toHaveBeenCalled();
  });
  it('startup cannot silently use the legacy document endpoint', async () => {
    const fetcher = vi.fn(); const client = new StartupClient('http://localhost:3318', async () => 'synthetic', fetcher);
    await expect(client.document('room-a', payload.id)).rejects.toMatchObject({ status: 501 }); expect(fetcher).not.toHaveBeenCalled();
  });
});
