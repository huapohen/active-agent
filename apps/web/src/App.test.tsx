import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { Conversation, ConversationRow, mergeMessagePages } from './App';
import { ApiError } from './api';
import type { CollaborationClient, Message, Room } from './types';
beforeAll(() => { Element.prototype.scrollIntoView = vi.fn(); window.HTMLElement.prototype.hasPointerCapture = () => false; window.HTMLElement.prototype.setPointerCapture = () => {}; window.HTMLElement.prototype.releasePointerCapture = () => {}; });
afterEach(cleanup);
const room: Room = { id: 'r1', title: '产品协作', kind: 'group', version: 1 };
const me = { id: 'human1', kind: 'human' as const, displayName: '人类' };
const message: Message = { id: 'm1', roomId: 'r1', authorId: 'human1', content: '中文', seq: 1, createdAt: '2026-09-09T01:00:00Z', retracted: false, mentions: [] };
function fake(send = vi.fn(async () => message)): CollaborationClient {
  return { mode: 'legacy', endpoint: 'http://localhost:3218', capabilities: { directory: true, documents: true, roomPreferences: true, createRoom: true, mentions: true, liveEvents: false, readReceipts: true, reactions: true, replies: true }, me: vi.fn(), rooms: vi.fn(), messages: vi.fn(async () => ({ messages: [], hasMoreBefore: false, hasMoreAfter: false })), send, members: vi.fn(async () => [me, { id: 'agent1', kind: 'agent' as const, displayName: '机伴' }]), people: vi.fn(), preferences: vi.fn(), createRoom: vi.fn(), direct: vi.fn(), documents: vi.fn(), document: vi.fn(), emoji: vi.fn(async () => ({ entries: [], categories: [], total: 0, catalogCount: 0 })), react: vi.fn(), events: vi.fn(), close: vi.fn() };
}
function mount(client: CollaborationClient) { const cache = new QueryClient({ defaultOptions: { queries: { retry: false } } }); return { cache, ...render(<QueryClientProvider client={cache}><Conversation client={client} me={me} room={room} /></QueryClientProvider>) }; }
describe('real composer intent and input safety', () => {
  it('does not submit during Chinese composition and sends once after composition finishes', async () => {
    const client = fake(); mount(client); const input = screen.getByRole('textbox', { name: '消息内容' });
    fireEvent.compositionStart(input); fireEvent.change(input, { target: { value: '你好' } }); fireEvent.keyDown(input, { key: 'Enter', keyCode: 229, isComposing: true });
    expect(client.send).not.toHaveBeenCalled(); fireEvent.compositionEnd(input); fireEvent.keyDown(input, { key: 'Enter', keyCode: 13 });
    await waitFor(() => expect(client.send).toHaveBeenCalledTimes(1)); expect(vi.mocked(client.send).mock.calls[0][1].content).toBe('你好');
  });
  it('keeps one action ID on an ambiguous retry, and clears a successful send independently of refresh', async () => {
    const send = vi.fn().mockRejectedValueOnce(new ApiError(503, 'unknown')).mockResolvedValueOnce(message);
    const client = fake(send); mount(client); const input = screen.getByRole('textbox', { name: '消息内容' });
    fireEvent.change(input, { target: { value: '中文' } }); fireEvent.click(screen.getByRole('button', { name: '发送' }));
    await screen.findByRole('button', { name: '重试发送' }); fireEvent.click(screen.getByRole('button', { name: '重试发送' }));
    await waitFor(() => expect(send).toHaveBeenCalledTimes(2)); expect(send.mock.calls[0][1].actionId).toBe(send.mock.calls[1][1].actionId); await waitFor(() => expect((input as HTMLTextAreaElement).value).toBe(''));
  });
  it('retains Shift+Enter newline and has a fixed send-button slot before typing', () => {
    const client = fake(); mount(client); const input = screen.getByRole('textbox', { name: '消息内容' });
    expect(screen.getByRole('button', { name: '发送' })).toBeTruthy(); fireEvent.change(input, { target: { value: 'line' } }); fireEvent.keyDown(input, { key: 'Enter', shiftKey: true }); expect(client.send).not.toHaveBeenCalled();
  });
  it('uses actual member IDs for Agent mentions', async () => {
    const client = fake(); mount(client); fireEvent.click(screen.getByTitle('Agent 超级入口'));
    fireEvent.click(await screen.findByRole('button', { name: /机伴/ })); fireEvent.click(screen.getByRole('button', { name: '发送' }));
    await waitFor(() => expect(client.send).toHaveBeenCalledTimes(1)); expect(vi.mocked(client.send).mock.calls[0][1].mentions).toEqual(['agent1']);
  });
  it('does not accept a late send into the next room after unmount', async () => {
    let resolve!: (value: Message) => void; const send = vi.fn(() => new Promise<Message>(r => { resolve = r; })); const client = fake(send); const view = mount(client);
    fireEvent.change(screen.getByRole('textbox'), { target: { value: '中文' } }); fireEvent.click(screen.getByRole('button', { name: '发送' })); view.unmount(); resolve(message); await Promise.resolve();
    expect(view.cache.getQueryData(['messages', 'r1'])).toBeUndefined();
  });
  it('merges history by stable message identity and authoritative sequence', () => {
    expect(mergeMessagePages([{ messages: [{ ...message, content: 'edited' }] }, { messages: [{ ...message, content: 'old' }, { ...message, id: 'm0', seq: 0 }] }]).map(m => [m.id, m.content])).toEqual([['m0', '中文'], ['m1', 'edited']]);
  });
  it('conversation left click opens it while right click exposes real pin preference', async () => {
    const open = vi.fn(), preferences = vi.fn(); render(<ConversationRow room={room} selected={false} onOpen={open} preferences={preferences} />);
    fireEvent.pointerDown(screen.getByRole('button', { name: room.title }), { button: 0 }); fireEvent.click(screen.getByRole('button', { name: room.title })); expect(open).toHaveBeenCalledTimes(1); expect(screen.queryByRole('menu')).toBeNull();
    fireEvent.contextMenu(screen.getByRole('button', { name: room.title })); fireEvent.click(await screen.findByRole('menuitem', { name: '置顶' })); expect(preferences).toHaveBeenCalledWith({ pinned: true });
  });
});
