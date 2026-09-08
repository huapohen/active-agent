import { describe, expect, it, vi } from 'vitest';
import { LegacyClient, StartupClient, message } from './api';

const json = (value: unknown) => new Response(JSON.stringify(value), { headers: { 'Content-Type': 'application/json' } });
const original = { id: 'msg-11', author_id: 'agent-1', author: { display_name: '机伴', kind: 'agent' }, content: '源消息', seq: 18, at: '2026-09-09T01:00:00Z', reply_to: 'msg-10', reactions: { 'feishu:OK': ['human-1', 'agent-1'], '👍': [] } };
describe('native reply/reaction contracts', () => {
  it('parses native source time, reply target and actual reactor IDs without synthesizing counts', () => {
    expect(message(original, 'room-1')).toMatchObject({ roomId: 'room-1', replyTo: 'msg-10', createdAt: original.at, reactions: { 'feishu:OK': ['human-1', 'agent-1'] } });
    expect(message({ ...original, at: 1788899408121 }, 'room-1').createdAt).toBe('2026-09-08T20:30:08.121Z');
    expect(() => message({ ...original, room_id: 'foreign' }, 'room-1')).toThrow();
    expect(() => message({ ...original, reactions: { '👍': [123] } }, 'room-1')).toThrow();
  });
  it('does not expose hidden/retracted source content, reactions, mentions or reply quotes', () => {
    for (const unavailable of [{ hidden: true }, { retracted_at: original.at }]) {
      expect(message({ ...original, ...unavailable, mentions: ['human-1'], voice: {}, attachments: [{ id: 'a' }] }, 'room-1')).toMatchObject({ content: '', reactions: {}, mentions: [], replyTo: undefined, isVoice: false, attachmentCount: 0 });
    }
  });
  it('sends the exact native reply_to and preserves the same client_id on deliberate retries', async () => {
    const fetcher = vi.fn(async () => json({ message: original }));
    const client = new LegacyClient('http://localhost:3218', async () => 'test-session', fetcher);
    const intent = { actionId: 'stable-reply', content: '回复', mentions: ['agent-1'], replyTo: 'msg-10' };
    await client.send('room-1', intent); await client.send('room-1', intent);
    const calls = fetcher.mock.calls as unknown as [string, RequestInit][];
    for (const [url, request] of calls) {
      expect(url).toBe('http://localhost:3218/api/im/rooms/room-1/messages');
      expect(JSON.parse(request.body as string)).toEqual({ client_id: 'stable-reply', content: '回复', mentions: ['agent-1'], reply_to: 'msg-10', mention_all: false, attachment_ids: [] });
      expect(request.redirect).toBe('error');
    }
  });
  it('performs one server toggle and checks the acknowledged message identity', async () => {
    const fetcher = vi.fn().mockResolvedValueOnce(json({ message: original })).mockResolvedValueOnce(json({ message: { ...original, id: 'msg-wrong' } }));
    const client = new LegacyClient('http://localhost:3218', async () => 'test-session', fetcher);
    expect((await client.react('room-1', 'msg-11', 'feishu:OK')).reactions).toEqual({ 'feishu:OK': ['human-1', 'agent-1'] });
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(fetcher.mock.calls[0][0]).toBe('http://localhost:3218/api/im/rooms/room-1/messages/msg-11/reactions');
    expect(JSON.parse(fetcher.mock.calls[0][1].body)).toEqual({ emoji: 'feishu:OK' });
    await expect(client.react('room-1', 'msg-11', 'feishu:OK')).rejects.toMatchObject({ code: 'invalid_reaction_target' });
  });
  it('does not retry an uncertain toggle and rejects late old-identity results', async () => {
    let complete!: (response: Response) => void;
    const fetcher = vi.fn(() => new Promise<Response>(resolve => { complete = resolve; }));
    const client = new LegacyClient('http://localhost:3218', async () => 'test-session', fetcher);
    const pending = client.react('room-1', 'msg-11', '👍'); await Promise.resolve(); client.close(); complete(json({ message: original }));
    await expect(pending).rejects.toMatchObject({ name: 'AbortError' }); expect(fetcher).toHaveBeenCalledTimes(1);
    const fails = vi.fn().mockRejectedValue(new TypeError('offline'));
    await expect(new LegacyClient('http://localhost:3218', async () => 'session', fails).react('room-1', 'msg-11', '👍')).rejects.toThrow(); expect(fails).toHaveBeenCalledTimes(1);
  });
  it('reads the complete catalog through native search/category/pagination and ignores remote asset URLs', async () => {
    const fetcher = vi.fn(async () => json({ categories: ['经典表情'], catalog_count: 4126, total: 182, offset: 100, has_more: true, next_offset: 101, entries: [{ id: 'feishu:OK', name: 'OK', text: ':feishu:OK:', category: '经典表情', asset: 'https://untrusted.invalid/pixel?secret=x' }] }));
    const client = new LegacyClient('http://localhost:3218', async () => 'test-session', fetcher);
    const page = await client.emoji({ query: 'OK', category: '经典表情', offset: 100 });
    expect(page).toEqual({ categories: ['经典表情'], catalogCount: 4126, total: 182, nextOffset: 101, entries: [{ id: 'feishu:OK', name: 'OK', text: ':feishu:OK:', category: '经典表情' }] });
    const url = new URL((fetcher.mock.calls[0] as unknown as [string])[0]);
    expect(Object.fromEntries(url.searchParams)).toEqual({ q: 'OK', category: '经典表情', offset: '100', limit: '100' });
  });
  it('rejects nonadvancing catalog cursors and never downgrades unsupported startup actions', async () => {
    const fetcher = vi.fn(async () => json({ categories: [], catalog_count: 1, total: 1, offset: 0, has_more: true, next_offset: 0, entries: [] }));
    await expect(new LegacyClient('http://localhost:3218', async () => 'session', fetcher).emoji()).rejects.toMatchObject({ code: 'invalid_emoji_cursor' });
    const forbidden = vi.fn(); const startup = new StartupClient('http://localhost:3318', async () => 'clerk-test', forbidden);
    await expect(startup.send('room-1', { actionId: 'a', content: '回复', mentions: [], replyTo: 'msg-11' })).rejects.toMatchObject({ status: 501 });
    await expect(startup.react('room-1', 'msg-11', '👍')).rejects.toMatchObject({ status: 501 });
    await expect(startup.emoji()).rejects.toMatchObject({ status: 501 }); expect(forbidden).not.toHaveBeenCalled();
  });
});
