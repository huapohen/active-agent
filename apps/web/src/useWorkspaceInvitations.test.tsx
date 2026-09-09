import { webcrypto } from 'node:crypto';
import { act, cleanup, renderHook, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { ReactNode } from 'react';
import { ApiError } from './api';
import { useWorkspaceInvitations } from './useWorkspaceInvitations';
import type { CollaborationClient, InvitationAcceptance, InvitationAcceptIntent, InvitationCreateIntent, InvitationReceipt, Principal, WorkspaceInvitation } from './types';
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const code = `rji_${'A'.repeat(43)}`, otherCode = `rji_${'B'.repeat(42)}A`;
const me: Principal = { id: id(1), kind: 'human', displayName: '本人' }, other: Principal = { id: id(9), kind: 'human', displayName: '另一个人' };
const space = { id: id(2), title: '真实团队', role: 'owner' };
const invitation: WorkspaceInvitation = { id: id(4), workspaceId: space.id, createdBy: me.id, createActionId: id(3), role: 'member', status: 'pending', createdAt: '2026-09-09T01:00:00Z', expiresAt: '2099-09-10T01:00:00Z' };
const accepted: InvitationAcceptance = { invitation: { ...invitation, status: 'accepted', acceptedBy: me.id }, workspaceId: space.id, principalId: me.id, role: 'member', alreadyMember: false, replayed: false, executionScopeExtended: false };
const key = (client: CollaborationClient, actor = me) => `renji:invitation-intents:v1:${client.mode}:${client.endpoint}:${actor.id}`;
beforeEach(() => { sessionStorage.clear(); vi.stubGlobal('crypto', webcrypto); });
afterEach(() => { cleanup(); vi.unstubAllGlobals(); vi.restoreAllMocks(); sessionStorage.clear(); });
function fake() {
  let items: WorkspaceInvitation[] = [];
  const invitations = {
    invitationCapabilities: { list: true, create: true, revoke: true, accept: true, actionRead: true },
    workspaceInvitations: vi.fn(async () => items),
    createInvitation: vi.fn(async (intent: InvitationCreateIntent) => { const item = { ...invitation, createActionId: intent.actionId }; items = [item]; return { invitation: item, codeAvailable: true, code, replayed: false }; }),
    revokeInvitation: vi.fn(async () => { items = items.map(item => ({ ...item, status: 'revoked' })); return { invitation: items[0], codeAvailable: false, replayed: false }; }),
    acceptInvitation: vi.fn(async (_intent: InvitationAcceptIntent) => accepted),
    invitationAction: vi.fn(async () => { throw new ApiError(404, 'invitation_not_found'); }),
  };
  const client = { mode: 'startup', endpoint: 'https://work.example', invitations, onboarding: { workspaces: vi.fn(async () => [space]) } } as unknown as CollaborationClient & { invitations: typeof invitations; onboarding: { workspaces: ReturnType<typeof vi.fn> } };
  return client;
}
function mount(client = fake(), actor = me, scope = 'scope-A', spaces = [space]) {
  const cache = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } });
  const changed = vi.fn(async () => space), logout = vi.fn();
  const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={cache}>{children}</QueryClientProvider>;
  const hook = renderHook(({ person, identity, workspaces }) => useWorkspaceInvitations(client, person, identity, workspaces, space.id, changed, logout), { wrapper, initialProps: { person: actor, identity: scope, workspaces: spaces } });
  return { ...hook, client, cache, changed, logout };
}
const stored = (client: CollaborationClient) => JSON.parse(sessionStorage.getItem(key(client)) || 'null');
describe('invitation intent and sensitive code lifecycle', () => {
  it('does not start a write without the explicit action reconciliation capability', async () => {
    const client = fake(); client.invitations.invitationCapabilities.actionRead = false; const h = mount(client);
    expect(h.result.current.canCreate).toBe(false); expect(h.result.current.canAccept).toBe(false); expect(h.result.current.canReconcile).toBe(false);
    await act(async () => { await h.result.current.onCreate(86400, 'scope-A'); await h.result.current.onAccept(code, 'scope-A'); });
    expect(client.invitations.createInvitation).not.toHaveBeenCalled(); expect(client.invitations.acceptInvitation).not.toHaveBeenCalled();
  });
  it('keeps the one-time code out of persistent state and query cache while exposing the authorized copy action', async () => {
    const h = mount(); await waitFor(() => expect(h.result.current.loading).toBe(false));
    await act(async () => { await h.result.current.onCreate(86400, 'scope-A'); });
    expect(h.result.current.issuedCode?.code).toBe(code); expect(h.result.current.operation?.status).toBe('succeeded');
    expect(JSON.stringify(sessionStorage)).not.toContain(code); expect(JSON.stringify(h.cache.getQueriesData({}))).not.toContain(code);
    expect(h.client.invitations.createInvitation).toHaveBeenCalledTimes(1);
  });
  it('recovers an unknown create through the original action read without creating a second invitation', async () => {
    const h = mount(); h.client.invitations.createInvitation.mockRejectedValueOnce(new ApiError(503, 'unknown'));
    await act(async () => { await h.result.current.onCreate(86400, 'scope-A'); });
    const original = stored(h.client).operation;
    h.client.invitations.workspaceInvitations.mockResolvedValue([{ ...invitation, createActionId: original.intent.actionId }]);
    h.client.invitations.invitationAction.mockImplementation(async () => ({ actionId: original.intent.actionId, kind: 'create', receipt: { invitation: { ...invitation, createActionId: original.intent.actionId }, codeAvailable: false, replayed: true } }) as never);
    await act(async () => { await h.result.current.onCreate(3600, 'scope-A'); await h.result.current.onReconcile('scope-A'); });
    expect(h.client.invitations.createInvitation).toHaveBeenCalledTimes(1); expect(h.result.current.issuedCode).toBeUndefined(); expect(h.result.current.operation?.message).toContain('无法再次读取');
  });
  it('retains a known first-response code through failed fresh read, and verifies the actual current invitation before copying', async () => {
    const h = mount(); await waitFor(() => expect(h.result.current.loading).toBe(false));
    h.client.onboarding.workspaces.mockRejectedValueOnce(new ApiError(503, 'read_failed'));
    await act(async () => { await h.result.current.onCreate(86400, 'scope-A'); });
    const original = stored(h.client).operation; expect(h.result.current.issuedCode).toBeUndefined();
    h.client.invitations.invitationAction.mockImplementation(async () => ({ actionId: original.intent.actionId, kind: 'create', receipt: { invitation: { ...invitation, createActionId: original.intent.actionId }, codeAvailable: false, replayed: true } }) as never);
    await act(async () => { await h.result.current.onReconcile('scope-A'); });
    expect(h.result.current.issuedCode?.code).toBe(code); expect(h.client.invitations.createInvitation).toHaveBeenCalledTimes(1);
  });
  it('persists only the accept action and its one-way input fingerprint, before POST', async () => {
    const h = mount(); h.client.invitations.acceptInvitation.mockImplementation(async () => { expect(stored(h.client).operation.intent.codeFingerprint).toMatch(/^[a-f0-9]{64}$/); expect(JSON.stringify(stored(h.client))).not.toContain(code); throw new ApiError(503, 'unknown'); });
    await act(async () => { await h.result.current.onAccept(code, 'scope-A'); });
    expect(h.result.current.operation?.status).toBe('unknown'); expect(stored(h.client).operation.intent).not.toHaveProperty('code');
  });
  it('restores an unknown accept after refresh using code-free action lookup and fresh membership only', async () => {
    const first = mount(); first.client.invitations.acceptInvitation.mockRejectedValueOnce(new ApiError(503, 'unknown'));
    await act(async () => { await first.result.current.onAccept(code, 'scope-A'); });
    const original = stored(first.client).operation; first.unmount();
    const client = fake(); client.invitations.invitationAction.mockImplementation(async () => ({ actionId: original.intent.actionId, kind: 'accept', receipt: { ...accepted, replayed: true } }) as never);
    const h = mount(client); await act(async () => { await h.result.current.onReconcile('scope-A'); });
    expect(h.client.invitations.acceptInvitation).not.toHaveBeenCalled(); expect(h.changed).toHaveBeenCalledWith(space.id, expect.any(AbortSignal)); expect(h.result.current.operation?.status).toBe('succeeded');
  });
  it('does not swap a different code into an unresolved action, including after refresh', async () => {
    const first = mount(); first.client.invitations.acceptInvitation.mockRejectedValueOnce(new ApiError(503, 'unknown'));
    await act(async () => { await first.result.current.onAccept(code, 'scope-A'); }); const original = stored(first.client); first.unmount();
    const h = mount(); await act(async () => { await h.result.current.onAccept(otherCode, 'scope-A'); });
    expect(h.client.invitations.acceptInvitation).not.toHaveBeenCalled(); expect(h.client.invitations.invitationAction).not.toHaveBeenCalled(); expect(stored(h.client)).toEqual(original); expect(h.result.current.operation?.message).toContain('不是原邀请码');
  });
  it('keeps an original missing receipt unresolved until its same code can replay, with no new action', async () => {
    const first = mount(); first.client.invitations.acceptInvitation.mockRejectedValueOnce(new ApiError(503, 'unknown'));
    await act(async () => { await first.result.current.onAccept(code, 'scope-A'); }); const original = stored(first.client).operation; first.unmount();
    const h = mount(); await act(async () => { await h.result.current.onReconcile('scope-A'); }); expect(h.client.invitations.acceptInvitation).not.toHaveBeenCalled();
    await act(async () => { await h.result.current.onAccept(code, 'scope-A'); });
    expect(h.client.invitations.acceptInvitation.mock.calls[0][0]).toMatchObject({ actionId: original.intent.actionId, code }); expect(h.result.current.operation?.status).toBe('succeeded');
  });
  it('only clears precise uncommitted business rejection, retaining a committed action when fresh membership fails', async () => {
    const h = mount(); h.client.invitations.acceptInvitation.mockRejectedValueOnce(new ApiError(410, 'invitation_expired'));
    await act(async () => { await h.result.current.onAccept(code, 'scope-A'); }); expect(stored(h.client)).toBeNull(); expect(h.result.current.operation?.status).toBe('error');
    h.changed.mockRejectedValueOnce(new ApiError(410, 'invitation_expired'));
    await act(async () => { await h.result.current.onAccept(code, 'scope-A'); }); expect(stored(h.client).operation.kind).toBe('accept'); expect(h.result.current.operation?.status).toBe('unknown');
  });
  it('makes no write if metadata storage fails, and keeps sensitive code out of the error', async () => {
    const h = mount(); vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error(code); });
    await act(async () => { await h.result.current.onAccept(code, 'scope-A'); }); expect(h.client.invitations.acceptInvitation).not.toHaveBeenCalled(); expect(h.result.current.operation?.message).not.toContain(code);
  });
  it('synchronously locks fingerprint computation against repeated submit and retires A-B-A in-place reuse', async () => {
    const h = mount(); let a!: Promise<void>, b!: Promise<void>;
    act(() => { a = h.result.current.onAccept(code, 'scope-A'); b = h.result.current.onAccept(code, 'scope-A'); }); await act(async () => { await Promise.all([a, b]); }); expect(h.client.invitations.acceptInvitation).toHaveBeenCalledTimes(1);
    h.rerender({ person: other, identity: 'scope-B', workspaces: [space] }); expect(h.result.current.canAccept).toBe(false); expect(h.result.current.operation).toBeUndefined();
    h.rerender({ person: me, identity: 'scope-A', workspaces: [space] }); await act(async () => { await h.result.current.onAccept(code, 'scope-A'); }); expect(h.client.invitations.acceptInvitation).toHaveBeenCalledTimes(1);
  });
  it('suppresses a late accept response after identity unmount without publishing old membership', async () => {
    const h = mount(); let done!: (v: InvitationAcceptance) => void; h.client.invitations.acceptInvitation.mockImplementation(() => new Promise(resolve => { done = resolve; }));
    let promise!: Promise<void>; act(() => { promise = h.result.current.onAccept(code, 'scope-A'); }); await waitFor(() => expect(h.client.invitations.acceptInvitation).toHaveBeenCalledTimes(1)); h.unmount();
    await act(async () => { done(accepted); await promise; }); expect(h.changed).not.toHaveBeenCalled();
  });
  it('hides an issued code immediately on workspace revocation and cannot create as an ordinary member', async () => {
    const h = mount(); await act(async () => { await h.result.current.onCreate(86400, 'scope-A'); }); expect(h.result.current.issuedCode).toBeTruthy();
    h.rerender({ person: me, identity: 'scope-A', workspaces: [{ ...space, role: 'member' }] }); expect(h.result.current.issuedCode).toBeUndefined(); expect(h.result.current.canCreate).toBe(false);
    await act(async () => { await h.result.current.onCreate(86400, 'scope-A'); }); expect(h.client.invitations.createInvitation).toHaveBeenCalledTimes(1);
  });
});
