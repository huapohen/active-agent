import { act, cleanup, renderHook, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { ReactNode } from 'react';
import { ApiError } from './api';
import { useCommercialAccount } from './useCommercialAccount';
import type { CollaborationClient, Principal, Profile, ProfileIntent, RoomIntent, WorkspaceIntent } from './types';

const person: Principal = { id: '00000000-0000-4000-8000-000000000001', kind: 'human', displayName: '新同事' };
const agent: Principal = { id: '00000000-0000-4000-8000-000000000002', kind: 'agent', displayName: '真实 Agent' };
const space = { id: '10000000-0000-4000-8000-000000000001', title: '当前团队', role: 'owner' };
const second = { id: '10000000-0000-4000-8000-000000000002', title: '另一个团队', role: 'owner' };
const roomId = '20000000-0000-4000-8000-000000000001';
const actionId = '30000000-0000-4000-8000-000000000001';
const scope = 'session-A-1';
const room = { id: roomId, workspaceId: space.id, title: '当前协作', kind: 'group', version: 1, scopeEpoch: 1 };

beforeEach(() => sessionStorage.clear());
afterEach(() => { cleanup(); vi.restoreAllMocks(); sessionStorage.clear(); });

function fake(principal = person) {
  let currentProfile: Profile = { principal, version: 1 };
  const onboarding = {
    onboardingCapabilities: { profileRead: true, profileUpdate: true, workspaces: true, workspaceCreate: true, workspaceMembers: true, roomMembers: true, roomCreate: true },
    profile: vi.fn(async (_signal?: AbortSignal) => currentProfile),
    updateProfile: vi.fn(async (intent: ProfileIntent, _signal?: AbortSignal) => {
      currentProfile = { principal: { ...principal, displayName: intent.displayName }, version: intent.expectedVersion + 1 };
      return { ...currentProfile, replayed: false };
    }),
    workspaces: vi.fn(async (_signal?: AbortSignal) => [space]),
    workspaceMembers: vi.fn(async (_workspaceId: string, _signal?: AbortSignal) => [{ ...principal, role: 'owner' }, { ...agent, role: 'member' }]),
    createWorkspace: vi.fn(async (intent: WorkspaceIntent, _signal?: AbortSignal) => ({ ...second, title: intent.title })),
    createWorkspaceRoom: vi.fn(async (intent: RoomIntent, _signal?: AbortSignal) => ({ ...room, workspaceId: intent.workspaceId, title: intent.title })),
  };
  const methods = { onboarding, rooms: vi.fn(async (_signal?: AbortSignal) => ({ rooms: [room], cursor: 0 })), members: vi.fn(async (_id: string, _signal?: AbortSignal) => [principal, agent]) };
  return { mode: 'startup', endpoint: 'http://127.0.0.1:3318', ...methods } as unknown as CollaborationClient & typeof methods;
}
const storageKey = (client: CollaborationClient, principal = person) => `renji:account-intents:v1:${client.mode}:${client.endpoint}:${principal.id}`;
const stored = (client: CollaborationClient, principal = person) => JSON.parse(sessionStorage.getItem(storageKey(client, principal)) || '{"operations":[]}').operations;
async function mount(client = fake(), principal = person, identity = scope) {
  const cache = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } } });
  const open = vi.fn(), logout = vi.fn();
  const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={cache}>{children}</QueryClientProvider>;
  const hook = renderHook(() => useCommercialAccount(client, principal, identity, open, logout), { wrapper });
  await waitFor(() => expect(hook.result.current.view.workspaceLoad.status).toBe('ready'));
  await waitFor(() => expect(hook.result.current.view.membersLoad.status).toBe('ready'));
  return { ...hook, cache, client, open, logout };
}

describe('independent account action review', () => {
  it('persists before POST and reconciles an unknown workspace operation with exactly the original ID and payload', async () => {
    const client = fake();
    client.onboarding.createWorkspace.mockImplementationOnce(async intent => {
      expect(stored(client)).toEqual([{ kind: 'workspace', intent }]);
      throw new ApiError(503, 'transport_unknown');
    });
    const h = await mount(client);
    await act(async () => { await h.result.current.view.onCreateWorkspace({ title: '需要核对的团队' }, scope); });
    expect(h.result.current.view.workspaceState?.status).toBe('unknown');
    const original = client.onboarding.createWorkspace.mock.calls[0][0];
    await act(async () => { await h.result.current.view.onCreateWorkspace({ title: '不能替换原请求' }, scope); });
    expect(client.onboarding.createWorkspace).toHaveBeenCalledTimes(1);
    client.onboarding.workspaces.mockResolvedValue([space, { ...second, title: original.title }]);
    await act(async () => { await h.result.current.view.onReconcile?.('workspace', scope); });
    expect(client.onboarding.createWorkspace.mock.calls[1][0]).toEqual(original);
    expect(h.result.current.view.workspaceState).toMatchObject({ status: 'succeeded', result: { id: second.id, title: original.title } });
    expect(h.result.current.view.selectedWorkspaceId).toBe(second.id);
    expect(stored(client)).toEqual([]);
  });

  it('keeps a successful create intent when its fresh directory read fails, then uses the same action to reconcile', async () => {
    const client = fake(); const h = await mount(client);
    client.onboarding.workspaces.mockRejectedValueOnce(new ApiError(503, 'read_unknown'));
    await act(async () => { await h.result.current.view.onCreateWorkspace({ title: '实际已创建' }, scope); });
    const original = client.onboarding.createWorkspace.mock.calls[0][0];
    expect(h.result.current.view.workspaceState?.status).toBe('unknown'); expect(stored(client)[0].intent).toEqual(original);
    client.onboarding.workspaces.mockResolvedValue([space, { ...second, title: original.title }]);
    await act(async () => { await h.result.current.view.onReconcile?.('workspace', scope); });
    expect(client.onboarding.createWorkspace.mock.calls[1][0]).toEqual(original);
    expect(h.result.current.view.workspaceState?.status).toBe('succeeded');
  });

  it('uses the fresh profile after a replay instead of the historical rename receipt', async () => {
    const client = fake(); const h = await mount(client);
    client.onboarding.updateProfile.mockResolvedValue({ principal: { ...person, displayName: '原动作昵称' }, version: 2, replayed: true });
    client.onboarding.profile.mockResolvedValue({ principal: { ...person, displayName: '后来改过的昵称' }, version: 5 });
    await act(async () => { await h.result.current.view.onRename({ displayName: '原动作昵称' }, scope); });
    expect(h.result.current.me.displayName).toBe('后来改过的昵称');
    expect(h.result.current.view.profileState).toMatchObject({ status: 'succeeded', result: { displayName: '后来改过的昵称' } });
    expect(stored(client)).toEqual([]);
  });

  it('does not let a background read started during a write overwrite the verified fresh profile', async () => {
    const client = fake(), next: Profile = { principal: { ...person, displayName: '服务端已确认的新昵称' }, version: 2 };
    const h = await mount(client);
    let commit!: (value: Profile & { replayed: boolean }) => void;
    client.onboarding.updateProfile.mockImplementationOnce(() => new Promise(done => { commit = done; }));
    client.onboarding.profile.mockResolvedValue(next);
    let operation!: void | Promise<void>;
    act(() => { operation = h.result.current.view.onRename({ displayName: next.principal.displayName }, scope); });
    await waitFor(() => expect(client.onboarding.updateProfile).toHaveBeenCalledTimes(1));
    let resolveOlder!: (value: Profile) => void;
    const older = h.cache.fetchQuery({ queryKey: ['profile', scope], queryFn: () => new Promise<Profile>(done => { resolveOlder = done; }) }).catch(() => undefined);
    await act(async () => { commit({ ...next, replayed: false }); await operation; });
    expect(h.result.current.me.displayName).toBe(next.principal.displayName);
    await act(async () => { resolveOlder({ principal: person, version: 1 }); await older; });
    expect(h.result.current.me.displayName).toBe(next.principal.displayName);
    expect(h.cache.getQueryData<Profile>(['profile', scope])?.version).toBe(2);
  });

  it('recovers an explicit first-POST profile version conflict using a fresh version and a new corrected action', async () => {
    const client = fake(); const h = await mount(client);
    client.onboarding.updateProfile.mockRejectedValueOnce(new ApiError(409, 'profile_version_conflict'));
    client.onboarding.profile.mockResolvedValue({ principal: { ...person, displayName: '另一窗口更新' }, version: 4 });
    await act(async () => { await h.result.current.view.onRename({ displayName: '我的改名' }, scope); });
    await waitFor(() => expect(h.result.current.view.profileState?.status).toBe('error'));
    expect(stored(client)).toEqual([]);
    await act(async () => { await h.result.current.view.onRename({ displayName: '按当前版本改名' }, scope); });
    expect(client.onboarding.updateProfile).toHaveBeenCalledTimes(2);
    const [first, retry] = client.onboarding.updateProfile.mock.calls.map(call => call[0]);
    expect(retry.expectedVersion).toBe(4); expect(retry.actionId).not.toBe(first.actionId);
  });

  it('does not discard a committed rename when the subsequent fresh read reports a conflict', async () => {
    const client = fake(); const h = await mount(client);
    client.onboarding.profile.mockRejectedValueOnce(new ApiError(409, 'profile_version_conflict'));
    await act(async () => { await h.result.current.view.onRename({ displayName: '已经提交的改名' }, scope); });
    expect(h.result.current.view.profileState?.status).toBe('unknown');
    expect(stored(client)[0].kind).toBe('rename');
    const first = client.onboarding.updateProfile.mock.calls[0][0];
    client.onboarding.profile.mockResolvedValue({ principal: { ...person, displayName: first.displayName }, version: 2 });
    await act(async () => { await h.result.current.view.onReconcile?.('rename', scope); });
    expect(client.onboarding.updateProfile.mock.calls[1][0]).toEqual(first);
  });

  it('does not treat a generic conflict as proof that an original rename never committed', async () => {
    const client = fake(); const h = await mount(client);
    client.onboarding.updateProfile.mockRejectedValue(new ApiError(409, 'action_conflict'));
    await act(async () => { await h.result.current.view.onRename({ displayName: '结果仍需核对' }, scope); });
    const first = client.onboarding.updateProfile.mock.calls[0][0];
    expect(h.result.current.view.profileState?.status).toBe('unknown'); expect(stored(client)[0].intent).toEqual(first);
    await act(async () => { await h.result.current.view.onRename({ displayName: '不能替换原意图' }, scope); });
    expect(client.onboarding.updateProfile).toHaveBeenCalledTimes(1);
    await act(async () => { await h.result.current.view.onReconcile?.('rename', scope); });
    expect(client.onboarding.updateProfile.mock.calls[1][0]).toEqual(first);
  });

  it('makes no write when the original intent cannot be persisted', async () => {
    const client = fake(); const h = await mount(client);
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new DOMException('synthetic quota', 'QuotaExceededError'); });
    await act(async () => { await h.result.current.view.onCreateWorkspace({ title: '禁止未记录的创建' }, scope); });
    expect(client.onboarding.createWorkspace).not.toHaveBeenCalled(); expect(h.result.current.view.canCreateWorkspace).toBe(false);
    expect(h.result.current.view.workspaceState?.status).toBe('error');
  });

  it('retains the original action when removing its durable intent fails after a successful write and read', async () => {
    const client = fake(); const h = await mount(client);
    client.onboarding.workspaces.mockResolvedValue([space, { ...second, title: '删除记录失败' }]);
    const originalSet = Storage.prototype.setItem; let writes = 0;
    const spy = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(function (this: Storage, key, value) { if (++writes === 2) throw new DOMException('synthetic quota', 'QuotaExceededError'); originalSet.call(this, key, value); });
    await act(async () => { await h.result.current.view.onCreateWorkspace({ title: '删除记录失败' }, scope); });
    expect(h.result.current.view.workspaceState?.status).toBe('unknown');
    const original = client.onboarding.createWorkspace.mock.calls[0][0]; expect(stored(client)[0].intent).toEqual(original);
    spy.mockRestore();
    await act(async () => { await h.result.current.view.onReconcile?.('workspace', scope); });
    expect(client.onboarding.createWorkspace.mock.calls[1][0]).toEqual(original);
    expect(stored(client)).toEqual([]);
  });

  it('fails closed for corrupt stored intentions without making an external write', async () => {
    const client = fake(); sessionStorage.setItem(storageKey(client), '{broken json');
    const h = await mount(client);
    expect(h.result.current.error).toContain('本地操作记录');
    expect(h.result.current.view.canCreateWorkspace).toBe(false);
    await act(async () => { await h.result.current.view.onCreateWorkspace({ title: '不能创建' }, scope); });
    expect(client.onboarding.createWorkspace).not.toHaveBeenCalled();
  });

  it('restores a pending room in its original authorized workspace rather than trapping it in the first workspace', async () => {
    const client = fake(); client.onboarding.workspaces.mockResolvedValue([space, second]);
    const intent: RoomIntent = { actionId, workspaceId: second.id, title: 'B工作空间原操作', memberIds: [person.id] };
    sessionStorage.setItem(storageKey(client), JSON.stringify({ version: 1, operations: [{ kind: 'room', intent }] }));
    const h = await mount(client);
    expect(h.result.current.view.roomState).toMatchObject({ status: 'unknown', submitted: intent });
    expect(h.result.current.view.selectedWorkspaceId).toBe(second.id);
    expect(h.result.current.view.membersLoad.workspaceId).toBe(second.id);
  });

  it('prevents workspace switching through a dialog callback while a room request is pending or unknown', async () => {
    const client = fake(); client.onboarding.workspaces.mockResolvedValue([space, second]);
    let reject!: (error: Error) => void;
    client.onboarding.createWorkspaceRoom.mockImplementationOnce(() => new Promise((_, fail) => { reject = fail; }));
    const h = await mount(client);
    let operation!: void | Promise<void>;
    act(() => { operation = h.result.current.view.onCreateRoom({ workspaceId: space.id, title: '未完成建群', memberIds: [person.id] }, scope); });
    act(() => { h.result.current.view.onSelectWorkspace(second.id, scope); });
    expect(h.result.current.view.selectedWorkspaceId).toBe(space.id);
    await waitFor(() => expect(client.onboarding.createWorkspaceRoom).toHaveBeenCalledTimes(1));
    await act(async () => { reject(new ApiError(503, 'unknown')); await operation; });
    act(() => { h.result.current.view.onSelectWorkspace(second.id, scope); });
    expect(h.result.current.view.selectedWorkspaceId).toBe(space.id);
  });

  it('protects A-B-A identity changes and restores only the original identity intent with its same action', async () => {
    const a = fake(); a.onboarding.createWorkspace.mockRejectedValueOnce(new ApiError(503, 'unknown'));
    const firstA = await mount(a);
    await act(async () => { await firstA.result.current.view.onCreateWorkspace({ title: 'A身份私有意图' }, scope); });
    const original = a.onboarding.createWorkspace.mock.calls[0][0]; firstA.unmount();
    const bPerson = { ...person, id: '00000000-0000-4000-8000-000000000003', displayName: 'B同事' }, b = fake(bPerson);
    const bHook = await mount(b, bPerson, 'session-B');
    expect(bHook.result.current.view.workspaceState).toBeUndefined(); expect(stored(b, bPerson)).toEqual([]); bHook.unmount();
    const aAgain = fake(); aAgain.onboarding.workspaces.mockResolvedValue([space, { ...second, title: original.title }]);
    const nextA = await mount(aAgain, person, 'session-A-2');
    expect(nextA.result.current.view.workspaceState).toMatchObject({ scopeKey: 'session-A-2', status: 'unknown', submitted: { title: original.title } });
    await act(async () => { await nextA.result.current.view.onReconcile?.('workspace', 'session-A-2'); });
    expect(aAgain.onboarding.createWorkspace.mock.calls[0][0]).toEqual(original);
  });

  it('drops a late completed old-identity result and preserves its intent for later reconciliation', async () => {
    const a = fake(); let resolve!: (value: typeof second) => void;
    a.onboarding.createWorkspace.mockImplementationOnce(() => new Promise(done => { resolve = done; }));
    const firstA = await mount(a); const staleView = firstA.result.current.view;
    let operation!: void | Promise<void>;
    act(() => { operation = staleView.onCreateWorkspace({ title: '旧身份后到结果' }, scope); });
    await waitFor(() => expect(a.onboarding.createWorkspace).toHaveBeenCalledTimes(1));
    firstA.unmount();
    const bPerson = { ...person, id: '00000000-0000-4000-8000-000000000003' }, b = fake(bPerson); const current = await mount(b, bPerson, 'session-B');
    await act(async () => { resolve({ ...second, title: '旧身份后到结果' }); await operation; });
    expect(current.result.current.view.workspaceState).toBeUndefined(); expect(b.onboarding.createWorkspace).not.toHaveBeenCalled();
    expect(stored(a)[0].intent.title).toBe('旧身份后到结果');
    await act(async () => { await staleView.onCreateWorkspace({ title: '离开后新请求' }, scope); });
    expect(a.onboarding.createWorkspace).toHaveBeenCalledTimes(1);
  });

  it('requires fresh self membership after a room receipt and will not offer an unauthorized room', async () => {
    const client = fake(); const h = await mount(client);
    client.members.mockResolvedValue([agent]);
    await act(async () => { await h.result.current.view.onCreateRoom({ workspaceId: space.id, title: room.title, memberIds: [person.id] }, scope); });
    expect(h.result.current.view.roomState?.status).toBe('unknown');
    act(() => h.result.current.view.onOpenRoom?.(room.id, scope)); expect(h.open).not.toHaveBeenCalled();
    expect(stored(client)[0].kind).toBe('room');
  });

  it('rejects member IDs outside the current workspace before allocating an action or writing', async () => {
    const client = fake(); const h = await mount(client); const ids = vi.spyOn(crypto, 'randomUUID');
    await act(async () => { await h.result.current.view.onCreateRoom({ workspaceId: space.id, title: '不能跨组织拉人', memberIds: [person.id, '00000000-0000-4000-8000-000000000099'] }, scope); });
    expect(client.onboarding.createWorkspaceRoom).not.toHaveBeenCalled(); expect(ids).not.toHaveBeenCalled(); expect(stored(client)).toEqual([]);
  });
});
