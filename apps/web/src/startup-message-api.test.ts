import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { createHash, webcrypto } from 'node:crypto';
beforeAll(() => vi.stubGlobal('crypto', webcrypto));
afterAll(() => vi.unstubAllGlobals());
import { StartupClient, message } from './api';

const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });
const png = new Uint8Array([137,80,78,71,13,10,26,10,0]);
const revision = `sha256:${'a'.repeat(64)}`, etag = `"sha256-${createHash('sha256').update(png).digest('hex')}"`;
const asset = '/v1/emoji/assets/feishu/OK.png';
const source = { id: 'm2', room_id: 'r1', author_id: 'p1', content: '实际回复', seq: 2, created_at: '2026-09-09T01:00:00Z', reply_to: 'm1', reply: { message_id: 'm1', room_id: 'r1', author_id: 'agent1', author_name: '机伴', author_kind: 'agent', excerpt: '服务器原文摘要', seq: 1 }, reactions: [{ emoji: '👍', count: 2, selected: true }], reaction_version: 4, reactions_has_more: true };
const caps = ['message.reply', 'message.reaction.set', 'message.reaction.read', 'emoji.read'].map(id => ({ id, version: '1', available: true, protocols: { api: true } }));
const catalog = { version: 'emoji-catalog/v1', revision, entries: [{ id: 'feishu:OK', name: 'OK', text: ':feishu:OK:', category: '经典表情', asset, asset_etag: etag }], categories: ['经典表情'], total: 1, catalog_count: 4126, offset: 0, has_more: false, next_offset: null };
async function session(next: typeof fetch, capabilities = caps) {
  const fetcher = vi.fn(async (url: RequestInfo | URL, options?: RequestInit) => String(url).endsWith('/me') ? json({ principal: { id: 'p1', kind: 'human', display_name: '合成用户' } }) : String(url).endsWith('/capabilities') ? json({ schema: 'renji.capabilities.v1', capabilities }) : next(url, options));
  const c = new StartupClient('https://work.example', async () => 'synthetic-session', fetcher);
  await c.me(); return { c, fetcher };
}

describe('commercial message protocols stay separate from migration', () => {
  it('opens only exact runtime capabilities and fails closed for unavailable catalog or unknown versions', async () => {
    const { c } = await session(vi.fn(), caps.map(v => v.id === 'emoji.read' ? { ...v, available: false } : v));
    expect(c.capabilities.replies).toBe(true); expect(c.capabilities.reactions).toBe(false); expect(c.capabilities.mentions).toBe(false);
    await expect(c.setReaction('r1', 'm2', { actionId: 'a', emoji: '👍', active: true })).rejects.toMatchObject({ status: 501 });
    const other = await session(vi.fn(), caps.map(v => ({ ...v, version: '2' })));
    expect(other.c.capabilities.replies).toBe(false); expect(other.c.capabilities.reactions).toBe(false);
    const missing = await session(vi.fn(), caps.map(v => ({ ...v, available: undefined })) as unknown as typeof caps);
    expect(missing.c.capabilities.replies).toBe(false); expect(missing.c.capabilities.reactions).toBe(false);
  });
  it('sends reply ID only and parses server summary without requiring a loaded parent', async () => {
    const write = vi.fn(async (_url: RequestInfo | URL, _options?: RequestInit) => json({ message: source, replayed: false })); const { c } = await session(write);
    const m = await c.send('r1', { actionId: 'one', content: '实际回复', mentions: [], replyTo: 'm1', scopeEpoch: 3 });
    expect(m.reply).toMatchObject({ messageId: 'm1', authorName: '机伴', excerpt: '服务器原文摘要' });
    expect(m.reactionSummaries).toEqual([{ emoji: '👍', count: 2, selected: true }]);
    expect(JSON.parse(write.mock.calls[0][1]!.body as string)).toEqual({ action_id: 'one', content: '实际回复', reply_to: 'm1', scope_epoch: 3 });
  });
  it('rejects wrong-room, wrong-parent, future or overlong reply summaries and malformed reaction counts', () => {
    for (const reply of [{ ...source.reply, room_id: 'foreign' }, { ...source.reply, message_id: 'other' }, { ...source.reply, seq: 2 }, { ...source.reply, excerpt: '字'.repeat(241) }]) expect(() => message({ ...source, reply }, 'r1')).toThrow();
    for (const reactions of [[{ emoji: '👍', count: -1, selected: true }], [{ emoji: '👍', count: 2, selected: 'true' }], [source.reactions[0], source.reactions[0]]]) expect(() => message({ ...source, reactions }, 'r1')).toThrow();
    expect(message({ ...source, hidden: true }, 'r1')).toMatchObject({ content: '', reply: undefined, reactionSummaries: undefined, reactionsHasMore: false });
  });
  it('uses explicit active and stable intent, validates receipt actor/room, and never retries transport itself', async () => {
    const receipt = { room_id: 'r1', message_id: 'm2', principal_id: 'p1', emoji: '👍', active: false, changed: true, version: 5, count: 1, selected: false, replayed: false };
    const write = vi.fn(async (_url: RequestInfo | URL, _options?: RequestInit) => json(receipt)); const { c } = await session(write);
    const intent = { actionId: 'stable-action', emoji: '👍', active: false, scopeEpoch: 3 };
    expect(await c.setReaction('r1', 'm2', intent)).toMatchObject({ active: false, version: 5 });
    expect(JSON.parse(write.mock.calls[0][1]!.body as string)).toEqual({ action_id: 'stable-action', emoji: '👍', active: false, scope_epoch: 3 });
    write.mockResolvedValueOnce(json({ ...receipt, principal_id: 'foreign' })); await expect(c.setReaction('r1', 'm2', intent)).rejects.toMatchObject({ code: 'invalid_reaction_receipt' });
    write.mockRejectedValueOnce(new TypeError('network')); await expect(c.setReaction('r1', 'm2', intent)).rejects.toThrow(); expect(write).toHaveBeenCalledTimes(3);
  });
  it('uses before=0 for latest messages and the point read for authoritative current state', async () => {
    const read = vi.fn(async (url: RequestInfo | URL) => String(url).endsWith('/m2') ? json({ message: source }) : json({ messages: [source], cursor: 2, direction: 'before', has_more: true, has_more_before: true })); const { c } = await session(read);
    expect((await c.messages('r1')).hasMoreBefore).toBe(true); expect(String(read.mock.calls[0][0])).toContain('before=0');
    await c.message('r1', 'm2'); expect(String(read.mock.calls[1][0])).toBe('https://work.example/v1/rooms/r1/messages/m2');
    for (const patch of [{ id: 'other' }, { room_id: 'foreign' }, { room_id: undefined }, { seq: 0 }, { seq: -1 }, { seq: '2' }]) { read.mockResolvedValueOnce(json({ message: { ...source, ...patch } })); await expect(c.message('r1', 'm2')).rejects.toMatchObject({ code: 'invalid_message_target' }); }
  });
  it('keeps the oldest exclusive cursor separate from polling and rejects overlapping or foreign pages', async () => {
    const older = { ...source, id: 'm1', seq: 1, reply_to: undefined, reply: undefined };
    const page = { messages: [source], cursor: 2, direction: 'before', has_more: true, has_more_before: true };
    const read = vi.fn(async (_url: RequestInfo | URL) => json(page)); const { c } = await session(read);
    await c.messages('r1'); read.mockResolvedValueOnce(json({ ...page, messages: [older], cursor: 1, has_more: false, has_more_before: false }));
    expect((await c.messages('r1', { before: 2 })).messages[0].id).toBe('m1');
    await c.messages('r1');
    expect(read.mock.calls.map(([url]) => new URL(String(url)).searchParams.get('before'))).toEqual(['0', '2', '0']);
    await expect(c.messages('r1', { before: 2 })).rejects.toMatchObject({ code: 'invalid_message_page' });
    read.mockResolvedValueOnce(json({ ...page, messages: [{ ...source, room_id: undefined }] })); await expect(c.messages('r1')).rejects.toMatchObject({ code: 'invalid_message_page' });
    read.mockResolvedValueOnce(json({ ...page, messages: [source, source] })); await expect(c.messages('r1')).rejects.toMatchObject({ code: 'invalid_message_page' });
    read.mockResolvedValueOnce(json({ ...page, cursor: 99 })); await expect(c.messages('r1')).rejects.toMatchObject({ code: 'invalid_message_page' });
  });
  it('fences complete reaction pages by room, message, stable version and advancing cursor', async () => {
    const page = { room_id: 'r1', message_id: 'm2', summaries: [{ emoji: '👍', count: 2, selected: true }], version: 4, has_more: true, next_after: '👍' };
    const read = vi.fn(async () => json(page)); const { c } = await session(read);
    expect(await c.reactionSummaries('r1', 'm2')).toMatchObject({ nextAfter: '👍', version: 4 });
    await expect(c.reactionSummaries('r1', 'm2', { expectedVersion: 3 })).rejects.toMatchObject({ code: 'invalid_reaction_page' });
    read.mockResolvedValueOnce(json({ ...page, room_id: 'foreign' })); await expect(c.reactionSummaries('r1', 'm2')).rejects.toThrow();
    await expect(c.reactionSummaries('r1', 'm2', { after: '👍', expectedVersion: 4 })).rejects.toMatchObject({ code: 'invalid_reaction_cursor' });
  });
  it('accepts only provider catalog assets and fetches PNG through bearer, never URL credentials or redirects', async () => {
    const read = vi.fn(async (url: RequestInfo | URL) => String(url).includes('/assets/') ? new Response(png, { headers: { 'Content-Type': 'image/png', ETag: etag } }) : json(catalog));
    const { c } = await session(read); const page = await c.emoji(); expect(page.entries[0]).toMatchObject({ asset, revision });
    expect((await c.emojiAsset(asset, revision)).size).toBe(9);
    const [url, options] = read.mock.calls[1] as unknown as [string, RequestInit]; expect(url).toBe(`https://work.example${asset}`); expect(options.headers).toMatchObject({ Authorization: 'Bearer synthetic-session', 'If-Match': etag }); expect(options.redirect).toBe('error');
    await expect(c.emojiAsset('/v1/emoji/assets/feishu/UNKNOWN.png', revision)).rejects.toMatchObject({ code: 'unverified_emoji_asset' });
    read.mockResolvedValueOnce(json({ ...catalog, entries: [{ ...catalog.entries[0], asset: 'https://foreign.example/image.png' }] })); await expect(c.emoji()).rejects.toMatchObject({ code: 'invalid_emoji_asset' });
  });
  it('rejects changed catalog revisions and invalid or oversized PNG bodies', async () => {
    const read = vi.fn(async () => json(catalog)); const { c } = await session(read);
    await expect(c.emoji({ revision: `sha256:${'c'.repeat(64)}` })).rejects.toMatchObject({ code: 'invalid_emoji_catalog' });
    await c.emoji();
    const changed = new Uint8Array(png); changed[8] = 1; read.mockResolvedValueOnce(new Response(changed, { headers: { 'Content-Type': 'image/png', ETag: etag } })); await expect(c.emojiAsset(asset, revision)).rejects.toMatchObject({ code: 'emoji_asset_hash_mismatch' });
    read.mockResolvedValueOnce(new Response('<script>bad</script>', { headers: { 'Content-Type': 'image/png', ETag: etag } })); await expect(c.emojiAsset(asset, revision)).rejects.toMatchObject({ code: 'invalid_emoji_asset' });
    read.mockResolvedValueOnce(new Response(new Uint8Array(1048577), { headers: { 'Content-Type': 'image/png', ETag: etag } })); await expect(c.emojiAsset(asset, revision)).rejects.toMatchObject({ code: 'emoji_asset_too_large' });
  });
  it('retires pending authenticated images and point reads on identity change', async () => {
    let complete!: (response: Response) => void;
    const read = vi.fn(async () => json(catalog)); const { c } = await session(read); await c.emoji();
    read.mockImplementationOnce(() => new Promise<Response>(resolve => { complete = resolve; }));
    const pending = c.emojiAsset(asset, revision); await Promise.resolve(); c.close(); complete(new Response(new Uint8Array([137,80,78,71,13,10,26,10]), { headers: { 'Content-Type': 'image/png', ETag: etag } }));
    await expect(pending).rejects.toMatchObject({ name: 'AbortError' });
    await expect(c.message('r1', 'm2')).rejects.toMatchObject({ name: 'AbortError' });
    expect(c.capabilities.reactions).toBe(false);
  });
});
