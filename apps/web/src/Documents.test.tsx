import { afterEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { Documents, DocumentReader } from './Documents';
import { ApiError } from './api';
import type { CollaborationClient, DocumentContent } from './types';
afterEach(cleanup);
const doc = { id: 'doc-one', roomId: 'room-a', roomIds: ['room-a', 'room-b'], title: '真实文档', revision: 2, updatedAt: '2026-09-09T00:00:00Z' };
const body: DocumentContent = { ...doc, content: '## 阶段正文\n\n人和 Agent 共享这一段。', contentHash: 'a'.repeat(64) };
function fake(read: CollaborationClient['document'] = vi.fn(async () => body)): CollaborationClient {
  return { mode: 'legacy', endpoint: 'http://localhost:3218', capabilities: { directory: true, documents: true, roomPreferences: true, createRoom: true, mentions: true, liveEvents: false, readReceipts: true }, me: vi.fn(), rooms: vi.fn(async () => ({ rooms: [{ id: 'room-a', title: '所属产品群', kind: 'group', version: 1 }], cursor: 0 })), messages: vi.fn(), send: vi.fn(), members: vi.fn(), people: vi.fn(), preferences: vi.fn(), createRoom: vi.fn(), direct: vi.fn(), documents: vi.fn(async () => [doc]), document: read, events: vi.fn(), close: vi.fn() };
}
function setup(client: CollaborationClient) {
  const cache = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const onBack = vi.fn(), onOpenRoom = vi.fn();
  const element = (c: CollaborationClient) => <QueryClientProvider client={cache}><DocumentReader client={c} document={doc} onBack={onBack} onOpenRoom={onOpenRoom} /></QueryClientProvider>;
  return { cache, onBack, onOpenRoom, element, ...render(element(client)) };
}
describe('authorized cloud document navigation and lifecycle', () => {
  it('opens real body from directory, returns to directory, and uses server room context', async () => {
    const client = fake(), onOpen = vi.fn(); const cache = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    render(<QueryClientProvider client={cache}><Documents client={client} onOpen={onOpen} /></QueryClientProvider>);
    fireEvent.click(await screen.findByRole('button', { name: /真实文档/ })); await screen.findByRole('article', { name: '文档正文' });
    expect(client.document).toHaveBeenCalledWith('room-a', 'doc-one', expect.any(AbortSignal)); expect(onOpen).not.toHaveBeenCalled();
    expect(screen.getByText('版本 2')).toBeTruthy(); fireEvent.click(screen.getByRole('button', { name: '所属会话' })); expect(onOpen).toHaveBeenCalledWith('room-a');
    fireEvent.click(screen.getByRole('button', { name: '云文档' })); expect(await screen.findByRole('region', { name: '云文档目录' })).toBeTruthy(); expect(screen.queryByRole('article')).toBeNull();
  });
  it('shows loading before the authorized response and replaces it with the actual revision', async () => {
    let resolve!: (v: DocumentContent) => void; const read = vi.fn(() => new Promise<DocumentContent>(r => { resolve = r; })); setup(fake(read));
    expect(screen.getByRole('status').textContent).toContain('校验权限'); expect(screen.queryByRole('article')).toBeNull();
    await act(async () => resolve(body)); expect(await screen.findByText('版本 2')).toBeTruthy();
  });
  it('refreshes exact server version/body without treating an old revision as the latest', async () => {
    const read = vi.fn().mockResolvedValueOnce(body).mockResolvedValueOnce({ ...body, revision: 3, content: '新的版本正文' }); setup(fake(read));
    await screen.findByText('版本 2'); fireEvent.click(screen.getByRole('button', { name: '刷新正文' }));
    await screen.findByText('版本 3'); expect(screen.getByText('新的版本正文')).toBeTruthy(); expect(screen.queryByText('人和 Agent 共享这一段。')).toBeNull();
  });
  it('hides previously read body and title after an authorization recheck returns 403', async () => {
    const read = vi.fn().mockResolvedValueOnce(body).mockRejectedValueOnce(new ApiError(403, 'document_scope')); setup(fake(read));
    await screen.findByRole('article'); fireEvent.click(screen.getByRole('button', { name: '刷新正文' }));
    await screen.findByRole('alert'); expect(screen.queryByRole('article')).toBeNull(); expect(screen.queryByText('真实文档')).toBeNull(); expect(screen.getByText('权限已失效')).toBeTruthy();
    expect(read).toHaveBeenCalledTimes(2);
  });
  it('does not expose old body under a new adapter with the same endpoint and document IDs', async () => {
    const one = fake(), two = fake(vi.fn(() => new Promise<DocumentContent>(() => {}))); const view = setup(one);
    await screen.findByRole('article'); view.rerender(view.element(two));
    expect(screen.queryByRole('article')).toBeNull(); expect(screen.queryByText('人和 Agent 共享这一段。')).toBeNull(); await waitFor(() => expect(two.document).toHaveBeenCalledTimes(1));
  });
  it('aborts pending old identity reads and discards late results across adapter changes', async () => {
    let resolve!: (v: DocumentContent) => void; const oldRead = vi.fn((_roomId: string, _documentId: string, _signal?: AbortSignal) => new Promise<DocumentContent>(r => { resolve = r; }));
    const one = fake(oldRead), two = fake(vi.fn(async () => ({ ...body, content: '第二身份正文' }))); const view = setup(one);
    await waitFor(() => expect(oldRead).toHaveBeenCalledTimes(1)); const signal = oldRead.mock.calls[0][2] as AbortSignal;
    view.rerender(view.element(two)); await screen.findByText('第二身份正文'); await act(async () => resolve(body));
    expect(signal.aborted).toBe(true); expect(screen.queryByText('人和 Agent 共享这一段。')).toBeNull();
  });
  it('has no editing or message-send side effect while entering a Chinese directory query', async () => {
    const client = fake(), onOpen = vi.fn(); const cache = new QueryClient();
    render(<QueryClientProvider client={cache}><Documents client={client} onOpen={onOpen} /></QueryClientProvider>);
    await screen.findByRole('button', { name: /真实文档/ }); const input = screen.getByRole('textbox', { name: '搜索文档' });
    fireEvent.compositionStart(input); fireEvent.change(input, { target: { value: '真实' } }); fireEvent.keyDown(input, { key: 'Enter', keyCode: 229, isComposing: true }); fireEvent.compositionEnd(input);
    expect((input as HTMLInputElement).value).toBe('真实'); expect(client.document).not.toHaveBeenCalled(); expect(client.send).not.toHaveBeenCalled(); expect(onOpen).not.toHaveBeenCalled();
  });
});
