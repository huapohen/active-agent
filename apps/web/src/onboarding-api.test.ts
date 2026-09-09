import { describe, expect, it, vi } from 'vitest';
import { StartupClient, validProfileName, validWorkspaceTitle } from './api';

const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const actor = { id: id(1), kind: 'human', display_name: '新同事' };
const workspace = (n: number) => ({ id: id(n), title: `协作空间${n}`, role: 'owner', created_at: '2026-09-09T01:00:00Z' });
const capIds = ['profile.read', 'profile.update', 'workspace.list', 'workspace.create', 'workspace.member.list', 'room.member.list', 'room.create'];
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status });
async function connect(next: typeof fetch, ids = capIds) {
  const fetcher = vi.fn(async (url: RequestInfo | URL, options?: RequestInit) => String(url).endsWith('/me') ? json({ principal: actor }) : String(url).endsWith('/capabilities') ? json({ schema: 'renji.capabilities.v1', capabilities: ids.map(id => ({ id, version: '1', available: true, protocols: { api: true } })) }) : next(url, options));
  const client = new StartupClient('https://work.example', async () => 'synthetic-token', fetcher);
  await client.me(); return client;
}
describe('real account API contracts', () => {
  it('requires explicit runtime capabilities before exposing account writes', async () => {
    const fetcher = vi.fn(); const c = await connect(fetcher, []);
    expect(c.capabilities.createRoom).toBe(false);
    await expect(c.profile()).rejects.toMatchObject({ status: 501 });
    await expect(c.createWorkspace({ actionId: 'one', title: '空间' })).rejects.toMatchObject({ status: 501 });
    expect(fetcher).not.toHaveBeenCalled();
  });
  it('preserves explicit Go error code needed for recoverable profile conflict', async () => {
    const c = await connect(async () => json({ error: 'profile_version_conflict' }, 409));
    await expect(c.updateProfile({ actionId: 'one', displayName: 'huapohen', expectedVersion: 1 })).rejects.toMatchObject({ status: 409, code: 'profile_version_conflict' });
  });
  it('does not accept a foreign profile or invented version as a successful rename', async () => {
    const fetcher = vi.fn().mockResolvedValueOnce(json({ principal: { ...actor, id: id(2) }, version: 1 })).mockResolvedValueOnce(json({ principal: { ...actor, display_name: 'huapohen' }, version: 3, replayed: false }));
    const c = await connect(fetcher);
    await expect(c.profile()).rejects.toMatchObject({ code: 'invalid_profile' });
    await expect(c.updateProfile({ actionId: 'one', displayName: 'huapohen', expectedVersion: 1 })).rejects.toMatchObject({ code: 'invalid_profile_receipt' });
  });
  it('sends immutable profile intent, handles historical receipt without claiming current profile', async () => {
    const fetcher = vi.fn(async (_url: RequestInfo | URL, _options?: RequestInit) => json({ principal: { ...actor, display_name: 'huapohen' }, version: 2, replayed: true }));
    const c = await connect(fetcher);
    expect(await c.updateProfile({ actionId: 'one', displayName: 'huapohen', expectedVersion: 1 })).toMatchObject({ version: 2, replayed: true });
    expect(JSON.parse(fetcher.mock.calls[0][1]!.body as string)).toEqual({ action_id: 'one', display_name: 'huapohen', expected_version: 1 });
  });
  it('follows workspace cursors and preserves server role; never accepts repeated or backwards pages', async () => {
    const fetcher = vi.fn().mockResolvedValueOnce(json({ workspaces: [workspace(2)], cursor: id(2) })).mockResolvedValueOnce(json({ workspaces: [workspace(3)], cursor: '' }));
    const c = await connect(fetcher); expect((await c.workspaces()).map(w => w.id)).toEqual([id(2), id(3)]);
    expect(fetcher.mock.calls[1][0]).toContain(`after=${id(2)}`);
    fetcher.mockResolvedValueOnce(json({ workspaces: [workspace(3)], cursor: id(3) })).mockResolvedValueOnce(json({ workspaces: [workspace(3)], cursor: '' }));
    await expect(c.workspaces()).rejects.toMatchObject({ code: 'invalid_account_cursor' });
  });
  it('reads human and Agent member IDs only from the selected source path', async () => {
    const fetcher = vi.fn(async (_url: RequestInfo | URL, _options?: RequestInit) => json({ members: [{ principal_id: id(1), kind: 'human', display_name: '本人', role: 'owner' }, { principal_id: id(2), kind: 'agent', display_name: '机伴', role: 'member' }], cursor: '' }));
    const c = await connect(fetcher); expect((await c.workspaceMembers(id(3))).map(p => [p.id, p.kind])).toEqual([[id(1), 'human'], [id(2), 'agent']]);
    expect(fetcher.mock.calls[0][0]).toContain(`/workspaces/${id(3)}/members?`);
  });
  it('retains workspace source and stable action on group creation, rejecting wrong-source receipts', async () => {
    const intent = { actionId: 'one', title: '共创群', workspaceId: id(2), memberIds: [id(1)] };
    const fetcher = vi.fn().mockResolvedValueOnce(json({ room: { id: id(3), workspace_id: id(2), title: intent.title, kind: 'group', version: 1, scope_epoch: 1 } })).mockResolvedValueOnce(json({ room: { id: id(3), workspace_id: id(4), title: intent.title, kind: 'group', version: 1, scope_epoch: 1 } }));
    const c = await connect(fetcher);
    expect(await c.createWorkspaceRoom(intent)).toMatchObject({ id: id(3), workspaceId: id(2) });
    expect(JSON.parse(fetcher.mock.calls[0][1]!.body as string)).toEqual({ action_id: 'one', title: intent.title, workspace_id: id(2), members: [id(1)] });
    await expect(c.createWorkspaceRoom(intent)).rejects.toMatchObject({ code: 'invalid_room_receipt' });
  });
  it('rejects foreign-only member selection before sending', async () => {
    const fetcher = vi.fn(); const c = await connect(fetcher);
    await expect(c.createWorkspaceRoom({ actionId: 'one', title: '群', workspaceId: id(2), memberIds: [id(3)] })).rejects.toMatchObject({ code: 'invalid_room_intent' });
    expect(fetcher).not.toHaveBeenCalled();
  });
  it('reads every room page with workspace identities instead of losing a UUID cursor', async () => {
    const item = (n: number) => ({ id: id(n), workspace_id: id(2), title: '群', kind: 'group', version: 1 });
    const fetcher = vi.fn().mockResolvedValueOnce(json({ rooms: [item(3)], cursor: id(3) })).mockResolvedValueOnce(json({ rooms: [item(4)], cursor: '' }));
    const c = await connect(fetcher); expect((await c.rooms()).rooms.map(r => [r.id, r.workspaceId])).toEqual([[id(3), id(2)], [id(4), id(2)]]);
  });
  it('rejects a late membership response after account retirement', async () => {
    let resolve!: (r: Response) => void;
    const c = await connect(() => new Promise<Response>(r => { resolve = r; }));
    const read = c.workspaceMembers(id(2)); await Promise.resolve(); c.close(); resolve(json({ members: [], cursor: '' }));
    await expect(read).rejects.toMatchObject({ name: 'AbortError' });
  });
  it('matches Unicode nickname and UTF-8 title limits without accepting control or unpaired surrogate input', () => {
    expect(validProfileName('🚀'.repeat(80))).toBe(true); expect(validProfileName('字'.repeat(81))).toBe(false);
    expect(validWorkspaceTitle('中'.repeat(80))).toBe(true); expect(validWorkspaceTitle('中'.repeat(81))).toBe(false);
    for (const value of ['a\n b', 'a\u200db', 'a\ud800', '\u0000']) { expect(validProfileName(value)).toBe(false); expect(validWorkspaceTitle(value)).toBe(false); }
  });
});
