import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { ConversationRow, conversationPreview } from './App';
import { StartupClient } from './api';
import type { Room } from './types';
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const preview = { id: id(4), room_id: id(2), author_id: id(3), author_name: '真实同事', author_kind: 'agent', excerpt: '基于数据库的最后一条中文消息', seq: 18, created_at: '2026-09-09T01:00:00Z', content_kind: 'text' };
const rawRoom = { id: id(2), workspace_id: id(1), title: '真实协作群', kind: 'group', version: 1, last_message: preview };
afterEach(cleanup);
describe('room previews are source facts rather than per-row queries', () => {
  it('uses one list request, a distinct preview and the actual timestamp', async () => {
    const fetcher = vi.fn(async () => new Response(JSON.stringify({ rooms: [rawRoom], cursor: '' })));
    const c = new StartupClient('https://work.example', async () => 'synthetic', fetcher); const page = await c.rooms();
    expect(fetcher).toHaveBeenCalledTimes(1); expect(page.rooms[0].lastMessage).toBeUndefined();
    expect(conversationPreview(page.rooms[0])).toBe('真实同事：基于数据库的最后一条中文消息');
    const view = render(<ConversationRow room={page.rooms[0]} selected={false} onOpen={vi.fn()} />);
    expect(view.container.querySelector('time')?.dateTime).toBe(preview.created_at); expect(screen.queryByText('暂无消息')).toBeNull(); expect(view.container.querySelector('.avatar')).toBeTruthy();
  });
  it('distinguishes empty rooms from an older service that has not provided previews', async () => {
    for (const [last_message, expected] of [[null, '暂无消息'], [undefined, '消息摘要暂未提供']] as const) {
      const c = new StartupClient('https://work.example', async () => 'synthetic', async () => new Response(JSON.stringify({ rooms: [{ ...rawRoom, last_message }], cursor: '' })));
      expect(conversationPreview((await c.rooms()).rooms[0])).toBe(expected);
    }
  });
  it.each([{ room_id: id(8) }, { seq: 0 }, { author_kind: 'system' }, { created_at: 'invalid' }, { excerpt: '字'.repeat(241) }, { content_kind: 'invented' }])('rejects malformed or cross-room summaries %j', async patch => {
    const c = new StartupClient('https://work.example', async () => 'synthetic', async () => new Response(JSON.stringify({ rooms: [{ ...rawRoom, last_message: { ...preview, ...patch } }], cursor: '' })));
    await expect(c.rooms()).rejects.toMatchObject({ code: 'invalid_room_preview' });
  });
  it('keeps legacy message previews without pretending hidden content is an attachment', () => {
    const room = { id: 'legacy', title: '旧群', kind: 'group', version: 1, lastMessage: { hidden: true, content: 'must not show' } } as Room;
    expect(conversationPreview(room)).toBe('消息已不可见');
  });
});
