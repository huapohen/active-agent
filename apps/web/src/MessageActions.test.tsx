import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import { Conversation } from './App';
import { ApiError } from './api';
import { sourceTime } from './MessageActions';
import type { CollaborationClient, EmojiPage, Message, Principal, Room } from './types';

beforeAll(() => { Element.prototype.scrollIntoView = vi.fn(); });
afterEach(cleanup);
const me: Principal = { id: 'human1', displayName: '人类', kind: 'human' };
const room: Room = { id: 'r1', title: '合成协作群', kind: 'group', version: 1 };
const source: Message = { id: 'm1', roomId: 'r1', authorId: 'agent1', authorName: '机伴', authorKind: 'agent', content: '合成源消息', seq: 1, createdAt: '2026-09-09T01:00:00Z', retracted: false, mentions: [], reactions: {} };
const catalog: EmojiPage = { entries: [{ id: 'feishu:OK', name: 'OK', text: ':feishu:OK:', category: '经典表情' }, { id: '👍', name: '点赞', text: '👍', category: '人物与手势' }], categories: ['经典表情', '人物与手势'], total: 3, catalogCount: 4126, nextOffset: 2 };
function client(): CollaborationClient {
  return { mode: 'legacy', endpoint: 'http://localhost:3218', capabilities: { directory: true, documents: true, roomPreferences: true, createRoom: true, mentions: true, liveEvents: false, readReceipts: true, reactions: true, replies: true },
    me: vi.fn(), rooms: vi.fn(), messages: vi.fn(async () => ({ messages: [source], hasMoreBefore: false, hasMoreAfter: false })), send: vi.fn(async () => ({ ...source, id: 'm2', seq: 2, authorId: me.id, content: '回复', replyTo: source.id })),
    emoji: vi.fn(async options => options?.offset ? { ...catalog, entries: [{ id: '✅', name: '完成', text: '✅', category: '人物与手势' }], nextOffset: undefined } : catalog), react: vi.fn(async () => ({ ...source, reactions: { '👍': [me.id] } })),
    members: vi.fn(async () => [me, { id: 'agent1', kind: 'agent' as const, displayName: '机伴' }]), people: vi.fn(), preferences: vi.fn(), createRoom: vi.fn(), direct: vi.fn(), documents: vi.fn(), document: vi.fn(), events: vi.fn(), close: vi.fn() };
}
function mount(c: CollaborationClient) {
  const cache = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const element = (next: CollaborationClient, nextRoom = room) => <QueryClientProvider client={cache}><Conversation client={next} me={me} room={nextRoom} /></QueryClientProvider>;
  return { cache, element, ...render(element(c)) };
}
async function hover() { const text = await screen.findByText(source.content); const row = text.closest<HTMLElement>('[data-message-id]')!; fireEvent.pointerOver(row, { pointerType: 'mouse' }); return row; }
async function pause() { await act(async () => { await new Promise(resolve => setTimeout(resolve, 220)); }); }

describe('transient message surfaces and real actions', () => {
  it('keeps tools outside the message flow, displays source time and closes emoji after the pointer leaves', async () => {
    mount(client()); const row = await hover(); const structure = row.innerHTML;
    const toolbar = screen.getByRole('toolbar', { name: '消息操作' }); expect(row.contains(toolbar)).toBe(false);
    expect(screen.getByText(sourceTime(source.createdAt))).toBeTruthy();
    fireEvent.pointerOver(screen.getByRole('button', { name: '表情回应' }));
    const palette = await screen.findByRole('dialog', { name: '选择表情回应' });
    fireEvent.pointerOut(row, { relatedTarget: null });
    fireEvent.pointerOver(palette, { relatedTarget: row }); await pause();
    expect(screen.getByRole('dialog', { name: '选择表情回应' })).toBeTruthy(); expect(row.innerHTML).toBe(structure);
    fireEvent.pointerOut(palette, { relatedTarget: document.body }); await pause();
    expect(screen.queryByRole('dialog')).toBeNull(); expect(screen.queryByRole('toolbar')).toBeNull();
  });
  it('supports the keyboard context menu, arrow navigation and Escape focus restoration', async () => {
    mount(client()); const row = await hover(); act(() => row.focus());
    fireEvent.keyDown(row, { key: 'F10', shiftKey: true });
    const menu = screen.getByRole('menu', { name: '更多消息操作' });
    expect(document.activeElement).toBe(within(menu).getByRole('menuitem', { name: '表情回应' }));
    fireEvent.keyDown(menu, { key: 'ArrowDown' }); expect(document.activeElement).toBe(within(menu).getByRole('menuitem', { name: '回复消息' }));
    fireEvent.keyDown(document, { key: 'Escape' }); expect(screen.queryByRole('menu')).toBeNull(); expect(document.activeElement).toBe(row);
  });
  it('opens a compact right-click menu and binds replies to the original message ID', async () => {
    const c = client(); mount(c); const row = await hover(); fireEvent.contextMenu(row, { clientX: 500, clientY: 300 });
    fireEvent.click(screen.getByRole('menuitem', { name: '回复消息' }));
    expect(screen.getByLabelText('正在回复').textContent).toContain(source.content);
    fireEvent.change(screen.getByRole('textbox', { name: '消息内容' }), { target: { value: '回复' } }); fireEvent.click(screen.getByRole('button', { name: '发送' }));
    await waitFor(() => expect(c.send).toHaveBeenCalledTimes(1)); expect(vi.mocked(c.send).mock.calls[0].slice(0, 2)).toMatchObject(['r1', { replyTo: 'm1', content: '回复' }]);
    await waitFor(() => expect(screen.queryByLabelText('正在回复')).toBeNull());
  });
  it('keeps one reply action ID on uncertain send retries and cancels only the quote when requested', async () => {
    const c = client(); vi.mocked(c.send).mockRejectedValueOnce(new ApiError(503, 'unknown')); mount(c); await hover();
    fireEvent.click(screen.getByRole('button', { name: '回复消息' })); fireEvent.change(screen.getByRole('textbox', { name: '消息内容' }), { target: { value: '回复' } }); fireEvent.click(screen.getByRole('button', { name: '发送' }));
    fireEvent.click(await screen.findByRole('button', { name: '重试发送' })); await waitFor(() => expect(c.send).toHaveBeenCalledTimes(2));
    expect(vi.mocked(c.send).mock.calls[0][1]).toEqual(vi.mocked(c.send).mock.calls[1][1]);
    await hover(); fireEvent.click(screen.getByRole('button', { name: '回复消息' })); fireEvent.change(screen.getByRole('textbox', { name: '消息内容' }), { target: { value: '保留草稿' } }); fireEvent.click(screen.getByRole('button', { name: '取消回复' }));
    expect((screen.getByRole('textbox', { name: '消息内容' }) as HTMLTextAreaElement).value).toBe('保留草稿');
  });
  it('uses current native catalog pages and selects the actual classic emoji ID', async () => {
    const c = client(); mount(c); await hover(); fireEvent.click(screen.getByRole('button', { name: '表情回应' }));
    const ok = await screen.findByRole('button', { name: 'OK' }); expect(ok.querySelector('img')?.getAttribute('src')).toContain('OK.png');
    fireEvent.click(screen.getByRole('button', { name: '加载更多表情' })); await screen.findByRole('button', { name: '完成' }); expect(vi.mocked(c.emoji).mock.calls.some(([options]) => options?.offset === 2)).toBe(true);
    fireEvent.click(ok); await waitFor(() => expect(c.react).toHaveBeenCalledTimes(1)); expect(vi.mocked(c.react).mock.calls[0].slice(0, 3)).toEqual(['r1', 'm1', 'feishu:OK']); expect(screen.queryByRole('dialog')).toBeNull();
  });
  it('searches and filters through the native API without submitting while Chinese text composes', async () => {
    const c = client(); mount(c); await hover(); fireEvent.click(screen.getByRole('button', { name: '表情回应' })); await screen.findByRole('button', { name: 'OK' });
    fireEvent.change(screen.getByRole('combobox', { name: '表情分类' }), { target: { value: '人物与手势' } });
    await waitFor(() => expect(vi.mocked(c.emoji).mock.calls.some(([options]) => options?.category === '人物与手势')).toBe(true));
    fireEvent.compositionStart(screen.getByRole('textbox', { name: '搜索表情' })); fireEvent.change(screen.getByRole('textbox', { name: '搜索表情' }), { target: { value: '点赞' } }); fireEvent.keyDown(screen.getByRole('textbox', { name: '搜索表情' }), { key: 'Enter', isComposing: true });
    await waitFor(() => expect(vi.mocked(c.emoji).mock.calls.some(([options]) => options?.query === '点赞')).toBe(true)); expect(c.send).not.toHaveBeenCalled(); expect(c.react).not.toHaveBeenCalled();
  });
  it('does not double-toggle or retry an uncertain result until a successful explicit refresh', async () => {
    const c = client(); vi.mocked(c.messages).mockResolvedValue({ messages: [{ ...source, reactions: { '👍': [me.id] } }], hasMoreBefore: false, hasMoreAfter: false });
    let reject!: (error: Error) => void; vi.mocked(c.react).mockImplementationOnce(() => new Promise((_resolve, no) => { reject = no; })); mount(c);
    const chip = await screen.findByRole('button', { name: /再次点击取消我的回应/ }); fireEvent.click(chip); fireEvent.click(chip); expect(c.react).toHaveBeenCalledTimes(1);
    await act(async () => reject(new TypeError('network lost'))); expect((chip as HTMLButtonElement).disabled).toBe(true); expect(screen.getByText('反应结果待确认，请先刷新')).toBeTruthy();
    fireEvent.click(chip); expect(c.react).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByRole('button', { name: '刷新确认' })); await waitFor(() => expect((chip as HTMLButtonElement).disabled).toBe(false));
    expect(c.react).toHaveBeenCalledTimes(1);
  });
  it('clears the palette, reply draft and old data immediately on identity/room switches', async () => {
    const c = client(); const view = mount(c); await hover(); fireEvent.click(screen.getByRole('button', { name: '回复消息' }));
    fireEvent.change(screen.getByRole('textbox', { name: '消息内容' }), { target: { value: '旧身份草稿' } }); await hover(); fireEvent.click(screen.getByRole('button', { name: '表情回应' })); await screen.findByRole('dialog');
    const next = client(); vi.mocked(next.messages).mockResolvedValue({ messages: [], hasMoreBefore: false, hasMoreAfter: false });
    view.rerender(view.element(next)); expect(screen.queryByRole('dialog')).toBeNull(); expect(screen.queryByLabelText('正在回复')).toBeNull(); expect(screen.queryByText(source.content)).toBeNull(); expect((screen.getByRole('textbox', { name: '消息内容' }) as HTMLTextAreaElement).value).toBe('');
    view.rerender(view.element(c, { ...room, id: 'r2', title: '另一个群' })); expect(screen.queryByRole('dialog')).toBeNull();
  });
  it('the Agent entry preserves the source reply and real chosen Agent mention', async () => {
    const c = client(); mount(c); await hover(); fireEvent.click(screen.getByRole('button', { name: '请 Agent 协作' })); fireEvent.click(await screen.findByRole('button', { name: /机伴.*Agent/ }));
    fireEvent.click(screen.getByRole('button', { name: '发送' })); await waitFor(() => expect(c.send).toHaveBeenCalledTimes(1)); expect(vi.mocked(c.send).mock.calls[0][1]).toMatchObject({ replyTo: 'm1', mentions: ['agent1'] });
  });
  it('closes floating tools on scrolling and window blur and exposes no fake startup mutations', async () => {
    const c = client(); c.capabilities.replies = false; c.capabilities.reactions = false; mount(c); const row = await hover();
    expect((screen.getByRole('button', { name: '回复消息' }) as HTMLButtonElement).disabled).toBe(true); expect((screen.getByRole('button', { name: '表情回应' }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.scroll(row.closest('.messages-pane')!); expect(screen.queryByRole('toolbar')).toBeNull(); await hover(); fireEvent.blur(window); expect(screen.queryByRole('toolbar')).toBeNull(); expect(c.react).not.toHaveBeenCalled();
  });
  it('withdraws source content and disables the draft reply after a revoked/hidden message refresh', async () => {
    const c = client(); mount(c); await hover(); fireEvent.click(screen.getByRole('button', { name: '回复消息' })); fireEvent.change(screen.getByRole('textbox', { name: '消息内容' }), { target: { value: '回复' } });
    vi.mocked(c.messages).mockResolvedValue({ messages: [{ ...source, hidden: true, content: '' }], hasMoreBefore: false, hasMoreAfter: false }); fireEvent.click(screen.getByRole('button', { name: '刷新消息' }));
    await screen.findByText('这条消息已隐藏'); expect(screen.queryByText(source.content)).toBeNull(); expect((screen.getByRole('button', { name: '发送' }) as HTMLButtonElement).disabled).toBe(true);
  });
});

describe('commercial explicit reaction reconciliation', () => {
  function commercial(): CollaborationClient {
    const c = client();
    return { ...c, mode: 'startup', capabilities: { ...c.capabilities, mentions: false },
      messages: vi.fn(async () => ({ messages: [{ ...source, reactionSummaries: [{ emoji: '👍', count: 1, selected: false }], reactionVersion: 1 }], hasMoreBefore: false, hasMoreAfter: false })),
      setReaction: vi.fn(async (_room, _message, intent) => ({ roomId: 'r1', messageId: 'm1', principalId: me.id, emoji: intent.emoji, active: intent.active, version: 2, replayed: false })),
      message: vi.fn(async () => ({ ...source, reactionSummaries: [{ emoji: '👍', count: 2, selected: true }], reactionVersion: 2 })) };
  }
  it('reconciles unknown writes with the exact action rather than toggling again or trusting an old receipt', async () => {
    const c = commercial(); vi.mocked(c.setReaction!).mockRejectedValueOnce(new TypeError('connection lost'));
    vi.mocked(c.message!).mockResolvedValueOnce({ ...source, reactionSummaries: [{ emoji: '👍', count: 1, selected: false }], reactionVersion: 9 });
    mount(c); const chip = await screen.findByRole('button', { name: '👍，1 位回应' }); fireEvent.click(chip); fireEvent.click(chip);
    fireEvent.click(await screen.findByRole('button', { name: '核对原动作' }));
    await waitFor(() => expect(c.setReaction).toHaveBeenCalledTimes(2));
    expect(vi.mocked(c.setReaction!).mock.calls[0][2]).toEqual(vi.mocked(c.setReaction!).mock.calls[1][2]);
    expect(vi.mocked(c.setReaction!).mock.calls[0][2]).toMatchObject({ emoji: '👍', active: true });
    await waitFor(() => expect(chip.getAttribute('aria-pressed')).toBe('false'));
    expect(c.react).not.toHaveBeenCalled(); expect(c.message).toHaveBeenCalledTimes(1);
    fireEvent.click(chip); await waitFor(() => expect(c.setReaction).toHaveBeenCalledTimes(3));
    expect(vi.mocked(c.setReaction!).mock.calls[2][2].actionId).not.toBe(vi.mocked(c.setReaction!).mock.calls[0][2].actionId);
  });
  it('does not apply an acknowledged receipt when its current-state read fails', async () => {
    const c = commercial(); vi.mocked(c.message!).mockRejectedValueOnce(new TypeError('read timeout'));
    mount(c); const chip = await screen.findByRole('button', { name: '👍，1 位回应' }); fireEvent.click(chip);
    await screen.findByRole('button', { name: '核对原动作' }); expect(chip.getAttribute('aria-pressed')).toBe('false');
    fireEvent.click(screen.getByRole('button', { name: '核对原动作' }));
    await waitFor(() => expect(chip.getAttribute('aria-pressed')).toBe('true'));
    expect(vi.mocked(c.setReaction!).mock.calls[0][2]).toEqual(vi.mocked(c.setReaction!).mock.calls[1][2]);
    expect(c.message).toHaveBeenCalledTimes(2);
  });
  it('rechecks source authorization after a denied write and removes old visible content', async () => {
    const c = commercial(); mount(c); const chip = await screen.findByRole('button', { name: '👍，1 位回应' });
    vi.mocked(c.setReaction!).mockRejectedValueOnce(new ApiError(403, 'forbidden'));
    vi.mocked(c.messages).mockRejectedValue(new ApiError(403, 'forbidden'));
    fireEvent.click(chip); await waitFor(() => expect(screen.queryByText(source.content)).toBeNull());
    expect(c.setReaction).toHaveBeenCalledTimes(1); expect(c.message).not.toHaveBeenCalled();
  });
  it('does not unlock an unknown action after ordinary refresh and disables fabricated Agent choices', async () => {
    const c = commercial(); vi.mocked(c.setReaction!).mockRejectedValueOnce(new TypeError('timeout')); mount(c);
    const chip = await screen.findByRole('button', { name: '👍，1 位回应' }); fireEvent.click(chip); await screen.findByRole('button', { name: '核对原动作' });
    fireEvent.click(screen.getByRole('button', { name: '刷新消息' })); await waitFor(() => expect(c.messages).toHaveBeenCalledTimes(2));
    expect((chip as HTMLButtonElement).disabled).toBe(true); fireEvent.click(chip); expect(c.setReaction).toHaveBeenCalledTimes(1);
    await hover(); expect((screen.getByRole('button', { name: '请 Agent 协作' }) as HTMLButtonElement).disabled).toBe(true); expect(c.members).not.toHaveBeenCalled();
  });
  it('retires an uncertain identity action without reading or displaying its late result', async () => {
    const c = commercial(); let resolve!: (receipt: Awaited<ReturnType<NonNullable<CollaborationClient['setReaction']>>>) => void;
    vi.mocked(c.setReaction!).mockImplementationOnce(() => new Promise(ok => { resolve = ok; }));
    const view = mount(c); fireEvent.click(await screen.findByRole('button', { name: '👍，1 位回应' }));
    await waitFor(() => expect(c.setReaction).toHaveBeenCalledTimes(1));
    const next = commercial(); vi.mocked(next.messages).mockResolvedValue({ messages: [], hasMoreBefore: false, hasMoreAfter: false }); view.rerender(view.element(next));
    await act(async () => resolve({ roomId: 'r1', messageId: 'm1', principalId: me.id, emoji: '👍', active: true, version: 2, replayed: false }));
    expect(c.message).not.toHaveBeenCalled(); expect(vi.mocked(c.setReaction!).mock.calls[0][3]?.aborted).toBe(true); expect(screen.queryByText(source.content)).toBeNull();
  });
  it('renders server quote summaries without the original loaded, never replacing a missing summary with cached source text', async () => {
    const c = commercial(); const reply: Message = { ...source, id: 'm2', seq: 2, content: '回复正文', replyTo: 'missing', reply: { messageId: 'missing', roomId: 'r1', authorId: 'other', authorKind: 'human', authorName: '成员', seq: 1, excerpt: '真实摘要' } };
    vi.mocked(c.messages).mockResolvedValue({ messages: [reply], hasMoreBefore: false, hasMoreAfter: false }); mount(c);
    expect(await screen.findByText('回复：成员：真实摘要')).toBeTruthy();
    vi.mocked(c.messages).mockResolvedValue({ messages: [{ ...reply, reply: undefined, replyTo: source.id }, source], hasMoreBefore: false, hasMoreAfter: false }); fireEvent.click(screen.getByRole('button', { name: '刷新消息' }));
    expect(await screen.findByText('回复：原消息摘要不可用')).toBeTruthy();
  });
  it('reads all reaction pages with one version, discards pages on conflict and starts again cleanly', async () => {
    const c = commercial(); vi.mocked(c.messages).mockResolvedValue({ messages: [{ ...source, reactionsHasMore: true }], hasMoreBefore: false, hasMoreAfter: false });
    c.reactionSummaries = vi.fn().mockResolvedValueOnce({ summaries: [{ emoji: '👍', count: 3, selected: false }], version: 7, nextAfter: '👍' }).mockRejectedValueOnce(new ApiError(409, 'reaction_version_changed')).mockResolvedValueOnce({ summaries: [{ emoji: '✅', count: 2, selected: true }], version: 8 });
    mount(c); fireEvent.click(await screen.findByRole('button', { name: '查看全部回应' }));
    fireEvent.click(await screen.findByRole('button', { name: '加载更多回应' }));
    await screen.findByRole('button', { name: '重新读取回应' });
    expect(vi.mocked(c.reactionSummaries).mock.calls[1][2]).toMatchObject({ after: '👍', expectedVersion: 7 });
    const dialog = screen.getByRole('dialog'); expect(within(dialog).queryByText('👍')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: '重新读取回应' }));
    fireEvent.click(await within(dialog).findByRole('button', { name: /✅.*2 位回应/ }));
    await waitFor(() => expect(c.setReaction).toHaveBeenCalledTimes(1)); expect(vi.mocked(c.setReaction!).mock.calls[0][2]).toMatchObject({ emoji: '✅', active: false });
  });
});
