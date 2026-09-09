import { useEffect, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { ApiError, errorMessage, validProfileName, validWorkspaceTitle } from './api';
import type { CollaborationClient, Principal, ProfileIntent, RoomIntent, WorkspaceIntent } from './types';
import type { CommercialOnboardingProps, CommercialOperationName, CommercialProfileState, CommercialRoomState, CommercialWorkspaceState } from './CommercialOnboarding';

type Pending = { kind: 'rename'; intent: ProfileIntent } | { kind: 'workspace'; intent: WorkspaceIntent } | { kind: 'room'; intent: RoomIntent };
const unknownMessage = '尚未确认操作结果，请核对原操作。不会重复创建。';
/** Only local drafts and immutable action IDs: no Clerk or provider credentials. */
function loadPending(key: string): Partial<Record<CommercialOperationName, Pending>> {
  const raw = sessionStorage.getItem(key);
  if (!raw) return {};
  const value = JSON.parse(raw);
  if (!value || value.version !== 1 || !Array.isArray(value.operations) || value.operations.length > 3) throw new Error('invalid_pending_operations');
  const out: Partial<Record<CommercialOperationName, Pending>> = {};
  for (const p of value.operations) {
    if (!p || !['rename', 'workspace', 'room'].includes(p.kind) || !p.intent || typeof p.intent.actionId !== 'string' || !/^[a-f0-9-]{36}$/.test(p.intent.actionId) || out[p.kind as CommercialOperationName]) throw new Error('invalid_pending_operation');
    const i = p.intent;
    if (p.kind === 'rename' ? typeof i.displayName !== 'string' || !validProfileName(i.displayName) || !Number.isSafeInteger(i.expectedVersion) || i.expectedVersion < 1 : typeof i.title !== 'string' || !validWorkspaceTitle(i.title) || p.kind === 'room' && (typeof i.workspaceId !== 'string' || !Array.isArray(i.memberIds) || i.memberIds.length > 100 || i.memberIds.some((m: unknown) => typeof m !== 'string'))) throw new Error('invalid_pending_intent');
    out[p.kind as CommercialOperationName] = p;
  }
  return out;
}

/** Mounted above all menus/dialogs so closing a form cannot forget a write. */
export function useCommercialAccount(client: CollaborationClient, initial: Principal, scopeKey: string, openRoom: (id: string) => void, logout: () => void) {
  const api = client.onboarding, cap = api?.onboardingCapabilities;
  const cache = useQueryClient(), lifecycle = useRef(new AbortController());
  const storageKey = `renji:account-intents:v1:${client.mode}:${client.endpoint}:${initial.id}`;
  const [restored] = useState(() => {
    if (!api) return { operations: {} as Partial<Record<CommercialOperationName, Pending>>, error: false };
    try { return { operations: loadPending(storageKey), error: false }; } catch { return { operations: {}, error: true }; }
  });
  const pending = useRef(restored.operations), busy = useRef(new Set<CommercialOperationName>());
  const [storageError, setStorageError] = useState(restored.error);
  const [profileState, setProfileState] = useState<CommercialProfileState | undefined>(() => restored.operations.rename?.kind === 'rename' ? { scopeKey, status: 'unknown', message: unknownMessage, submitted: { displayName: restored.operations.rename.intent.displayName } } : undefined);
  const [workspaceState, setWorkspaceState] = useState<CommercialWorkspaceState | undefined>(() => restored.operations.workspace?.kind === 'workspace' ? { scopeKey, status: 'unknown', message: unknownMessage, submitted: { title: restored.operations.workspace.intent.title } } : undefined);
  const [roomState, setRoomState] = useState<CommercialRoomState | undefined>(() => restored.operations.room?.kind === 'room' ? { scopeKey, status: 'unknown', message: unknownMessage, submitted: restored.operations.room.intent } : undefined);
  const [selectedWorkspaceId, setSelectedWorkspace] = useState<string | undefined>(() => restored.operations.room?.kind === 'room' ? restored.operations.room.intent.workspaceId : undefined);
  useEffect(() => { const controller = new AbortController(); lifecycle.current = controller; return () => controller.abort(); }, [client, scopeKey]);
  const profile = useQuery({ queryKey: ['profile', scopeKey], queryFn: ({ signal }) => api!.profile(signal), enabled: Boolean(cap?.profileRead), retry: false });
  const spaces = useQuery({ queryKey: ['workspaces', scopeKey], queryFn: ({ signal }) => api!.workspaces(signal), enabled: Boolean(cap?.workspaces), retry: false });
  const workspaces = spaces.isError ? [] : spaces.data ?? [];
  const effectiveWorkspaceId = workspaces.find(w => w.id === selectedWorkspaceId)?.id ?? workspaces[0]?.id;
  const members = useQuery({ queryKey: ['workspace-members', scopeKey, effectiveWorkspaceId], queryFn: ({ signal }) => api!.workspaceMembers(effectiveWorkspaceId!, signal), enabled: Boolean(effectiveWorkspaceId && cap?.workspaceMembers), retry: false });
  const me = profile.isError ? initial : profile.data?.principal ?? initial;

  function save(next: Partial<Record<CommercialOperationName, Pending>>) {
    sessionStorage.setItem(storageKey, JSON.stringify({ version: 1, operations: Object.values(next) }));
    pending.current = next;
  }
  const alive = (signal: AbortSignal) => !signal.aborted;
  async function publishCurrent(key: string[], value: unknown, signal: AbortSignal) {
    // A focus refresh may have started while the write was in flight. Retire
    // that read too, immediately before publishing the confirmed current data.
    await cache.cancelQueries({ queryKey: key });
    if (!alive(signal)) return false;
    cache.setQueryData(key, value);
    return true;
  }
  function state(operation: Pending, status: 'pending' | 'unknown' | 'error', message?: string) {
    const base = { scopeKey, status, message };
    if (operation.kind === 'rename') setProfileState({ ...base, submitted: { displayName: operation.intent.displayName } });
    if (operation.kind === 'workspace') setWorkspaceState({ ...base, submitted: { title: operation.intent.title } });
    if (operation.kind === 'room') setRoomState({ ...base, submitted: operation.intent });
  }
  async function perform(operation: Pending, caller: string) {
    if (!api || caller !== scopeKey || busy.current.has(operation.kind) || storageError) return;
    const signal = lifecycle.current.signal;
    if (!alive(signal)) return;
    busy.current.add(operation.kind);
    try { save({ ...pending.current, [operation.kind]: operation }); }
    catch { busy.current.delete(operation.kind); setStorageError(true); state(operation, 'error', '无法保存操作记录，请恢复此窗口的本地存储后重试。'); return; }
    state(operation, 'pending');
    let mutationCommitted = false;
    try {
      await cache.cancelQueries({ queryKey: operation.kind === 'rename' ? ['profile', scopeKey] : operation.kind === 'workspace' ? ['workspaces', scopeKey] : ['rooms'] });
      if (!alive(signal)) return;
      if (operation.kind === 'rename') {
        await api.updateProfile(operation.intent, signal);
        mutationCommitted = true;
        const current = await api.profile(signal);
        if (!alive(signal)) return;
        if (current.principal.id !== initial.id) throw new ApiError(502, 'profile_identity_changed');
        if (!await publishCurrent(['profile', scopeKey], current, signal)) return;
        const next = { ...pending.current }; delete next.rename; save(next);
        setProfileState({ scopeKey, status: 'succeeded', submitted: { displayName: operation.intent.displayName }, result: { id: current.principal.id, displayName: current.principal.displayName }, ...(current.principal.displayName !== operation.intent.displayName ? { message: '原操作已确认；昵称随后发生变化，已显示当前资料。' } : {}) });
      } else if (operation.kind === 'workspace') {
        const receipt = await api.createWorkspace(operation.intent, signal);
        const current = await api.workspaces(signal);
        if (!alive(signal)) return;
        const actual = current.find(w => w.id === receipt.id);
        if (!actual) throw new ApiError(403, 'created_workspace_unavailable');
        if (!await publishCurrent(['workspaces', scopeKey], current, signal)) return;
        if (!pending.current.room) setSelectedWorkspace(actual.id);
        const next = { ...pending.current }; delete next.workspace; save(next);
        setWorkspaceState({ scopeKey, status: 'succeeded', submitted: { title: operation.intent.title }, result: actual });
      } else {
        const receipt = await api.createWorkspaceRoom(operation.intent, signal);
        // A historical receipt is not proof of today's membership or room state.
        const current = await client.rooms(signal);
        const currentMembers = await client.members(receipt.id, signal);
        if (!alive(signal)) return;
        const actual = current.rooms.find(r => r.id === receipt.id && r.workspaceId === operation.intent.workspaceId);
        if (!actual || !currentMembers.some(m => m.id === initial.id)) throw new ApiError(403, 'created_room_unavailable');
        if (!await publishCurrent(['rooms'], current, signal)) return;
        const next = { ...pending.current }; delete next.room; save(next);
        setRoomState({ scopeKey, status: 'succeeded', submitted: operation.intent, result: { id: actual.id, workspaceId: operation.intent.workspaceId, title: actual.title } });
      }
    } catch (error) {
      if (!alive(signal)) return;
      if (operation.kind === 'rename' && !mutationCommitted && error instanceof ApiError && error.status === 409 && error.code === 'profile_version_conflict') {
        try {
          // This precise server result is issued only after ruling out a prior
          // receipt. A generic conflict cannot release an unknown operation.
          const current = await api.profile(signal);
          if (!alive(signal)) return;
          if (current.principal.id !== initial.id) throw new ApiError(502, 'profile_identity_changed');
          if (!await publishCurrent(['profile', scopeKey], current, signal)) return;
          const next = { ...pending.current }; delete next.rename; save(next);
          state(operation, 'error', '资料已在另一处更新。已读取最新版本，请确认昵称后重新保存。');
          return;
        } catch { /* Preserve the original intent until the current read works. */ }
      }
      // Keep the same action after all uncertain results, including a failed
      // fresh read following a successful commit. Never infer failure from 5xx.
      state(operation, 'unknown', `${unknownMessage} ${errorMessage(error)}`);
      if (error instanceof ApiError && error.status === 401) logout();
      if (error instanceof ApiError && [403, 404, 409].includes(error.status)) {
        void cache.invalidateQueries({ queryKey: ['profile', scopeKey] });
        void cache.invalidateQueries({ queryKey: ['workspaces', scopeKey] });
        void cache.invalidateQueries({ queryKey: ['workspace-members', scopeKey] });
      }
    } finally { busy.current.delete(operation.kind); }
  }
  const view: CommercialOnboardingProps = {
    scopeKey, me, workspaces, selectedWorkspaceId: effectiveWorkspaceId,
    workspaceLoad: { scopeKey, status: !cap?.workspaces || spaces.isError ? 'error' : spaces.isSuccess ? 'ready' : 'loading', ...(!cap?.workspaces ? { message: '工作空间暂不可用，请稍后重新打开客户端。' } : spaces.isError ? { message: errorMessage(spaces.error) } : {}) },
    members: members.isError ? [] : members.data ?? [],
    membersLoad: { scopeKey, workspaceId: effectiveWorkspaceId ?? '', status: members.isError ? 'error' : members.isSuccess ? 'ready' : 'loading', ...(members.isError ? { message: errorMessage(members.error) } : {}) },
    canRename: Boolean(cap?.profileUpdate && profile.isSuccess && !profile.isError && !storageError),
    canCreateWorkspace: Boolean(cap?.workspaceCreate && spaces.isSuccess && !spaces.isError && !storageError),
    canCreateRoom: Boolean(cap?.roomCreate && cap.roomMembers && spaces.isSuccess && !spaces.isError && !storageError),
    profileState, workspaceState, roomState,
    onSelectWorkspace: (id, caller) => { if (caller === scopeKey && !pending.current.room && !busy.current.has('room') && workspaces.some(w => w.id === id)) setSelectedWorkspace(id); },
    onRename: async (input, caller) => { if (caller !== scopeKey || !view.canRename || pending.current.rename || !profile.data || !validProfileName(input.displayName)) return; await perform({ kind: 'rename', intent: { actionId: crypto.randomUUID(), displayName: input.displayName.trim(), expectedVersion: profile.data.version } }, caller); },
    onCreateWorkspace: async (input, caller) => { if (caller !== scopeKey || !view.canCreateWorkspace || pending.current.workspace || !validWorkspaceTitle(input.title)) return; await perform({ kind: 'workspace', intent: { actionId: crypto.randomUUID(), title: input.title.trim() } }, caller); },
    onCreateRoom: async (input, caller) => {
      if (caller !== scopeKey || !view.canCreateRoom || pending.current.room || input.workspaceId !== effectiveWorkspaceId || !members.isSuccess || members.isError || !validWorkspaceTitle(input.title) || !input.memberIds.includes(initial.id) || input.memberIds.some(id => !members.data.some(m => m.id === id))) return;
      await perform({ kind: 'room', intent: { ...input, title: input.title.trim(), memberIds: [...input.memberIds], actionId: crypto.randomUUID() } }, caller);
    },
    onReconcile: async (kind, caller) => { const operation = pending.current[kind]; if (operation) await perform(operation, caller); },
    onRefreshWorkspaces: async caller => { if (caller === scopeKey) await spaces.refetch(); },
    onRefreshMembers: async (id, caller) => { if (caller === scopeKey && id === effectiveWorkspaceId) await members.refetch(); },
    onOpenRoom: (id, caller) => { if (caller === scopeKey && roomState?.status === 'succeeded' && roomState.result.id === id) openRoom(id); },
  };
  async function onMembershipChanged(workspaceId: string, callerSignal: AbortSignal) {
    if (!api) throw new ApiError(501, 'account_unavailable');
    const signal = AbortSignal.any([lifecycle.current.signal, callerSignal]);
    const [currentSpaces, currentMembers, currentRooms] = await Promise.all([api.workspaces(signal), api.workspaceMembers(workspaceId, signal), client.rooms(signal)]);
    if (!alive(signal)) throw new DOMException('Aborted', 'AbortError');
    const current = currentSpaces.find(item => item.id === workspaceId);
    if (!current || !currentMembers.some(item => item.id === initial.id)) throw new ApiError(403, 'joined_workspace_unavailable');
    if (!await publishCurrent(['workspaces', scopeKey], currentSpaces, signal) || !await publishCurrent(['workspace-members', scopeKey, workspaceId], currentMembers, signal) || !await publishCurrent(['rooms'], currentRooms, signal)) throw new DOMException('Aborted', 'AbortError');
    if (!pending.current.room) setSelectedWorkspace(workspaceId);
    return current;
  }
  return { view, me, onMembershipChanged, error: storageError ? '本地操作记录暂不可用。为防止重复创建，提交已暂停。' : profile.isError ? errorMessage(profile.error) : undefined };
}
