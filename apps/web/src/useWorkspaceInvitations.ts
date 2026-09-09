import { useEffect, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { ApiError, errorMessage, validInvitationCode } from './api';
import type { CollaborationClient, InvitationAcceptance, InvitationAction, InvitationCreateIntent, InvitationReceipt, InvitationRevokeIntent, Principal, WorkspaceInfo } from './types';

export type InvitationOperation = { kind: 'create'; intent: InvitationCreateIntent } | { kind: 'revoke'; intent: InvitationRevokeIntent } | { kind: 'accept'; intent: { actionId: string; codeFingerprint: string } };
export type InvitationOperationState = { status: 'pending' | 'unknown' | 'error' | 'succeeded'; kind: InvitationOperation['kind']; message: string; workspaceId?: string; invitationId?: string };
const uuid = (value: unknown): value is string => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
const unknown = '操作结果待确认，请核对原操作；不会自动创建另一份邀请。';
const actionWorkspace = (operation: InvitationOperation) => operation.kind === 'accept' ? undefined : operation.intent.workspaceId;
function restore(key: string): InvitationOperation | undefined {
  const raw = sessionStorage.getItem(key); if (!raw) return;
  const value = JSON.parse(raw), operation = value?.operation, intent = operation?.intent;
  if (value?.version !== 1 || !operation || !['create', 'revoke', 'accept'].includes(operation.kind) || !intent || !uuid(intent.actionId)) throw new Error('invalid_invitation_operation');
  const keys = operation.kind === 'create' ? ['actionId', 'workspaceId', 'expiresInSeconds'] : operation.kind === 'revoke' ? ['actionId', 'workspaceId', 'invitationId'] : ['actionId', 'codeFingerprint'];
  if (operation.kind === 'accept' && (typeof intent.codeFingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(intent.codeFingerprint)) || Object.keys(intent).some(key => !keys.includes(key)) || Object.keys(operation).some(key => !['kind', 'intent'].includes(key)) || operation.kind !== 'accept' && !uuid(intent.workspaceId) || operation.kind === 'revoke' && !uuid(intent.invitationId) || operation.kind === 'create' && (!Number.isSafeInteger(intent.expiresInSeconds) || intent.expiresInSeconds < 60 || intent.expiresInSeconds > 604800)) throw new Error('invalid_invitation_operation');
  return operation;
}

/** Invitation codes live only in these instance refs, never query/storage/URLs. */
export function useWorkspaceInvitations(client: CollaborationClient, me: Principal, scopeKey: string, workspaces: WorkspaceInfo[], selectedWorkspaceId: string | undefined, onMembershipChanged: (id: string, signal: AbortSignal) => Promise<WorkspaceInfo | undefined>, logout: () => void) {
  const api = client.invitations, cache = useQueryClient();
  const mountedIdentity = useRef({ client, principalId: me.id, scopeKey }), retired = useRef(false);
  if (mountedIdentity.current.client !== client || mountedIdentity.current.principalId !== me.id || mountedIdentity.current.scopeKey !== scopeKey) retired.current = true;
  const identityValid = !retired.current;
  const key = `renji:invitation-intents:v1:${client.mode}:${client.endpoint}:${me.id}`;
  const [initial] = useState(() => { try { return { operation: api ? restore(key) : undefined, error: false }; } catch { return { operation: undefined, error: true }; } });
  const pending = useRef(initial.operation), busy = useRef(false), preparingAccept = useRef(false), lifecycle = useRef(new AbortController());
  const acceptCode = useRef<string | undefined>(undefined), issued = useRef<{ workspaceId: string; invitationId: string; code: string } | undefined>(undefined);
  const [storageError, setStorageError] = useState(initial.error), [, repaint] = useState(0);
  const [operation, setOperation] = useState<InvitationOperationState | undefined>(() => initial.operation ? { kind: initial.operation.kind, status: 'unknown', message: unknown, workspaceId: actionWorkspace(initial.operation) } : undefined);
  useEffect(() => { const controller = new AbortController(); lifecycle.current = controller; return () => { controller.abort(); acceptCode.current = undefined; issued.current = undefined; }; }, [client, scopeKey, me.id]);
  const workspace = workspaces.find(item => item.id === selectedWorkspaceId);
  const canManage = Boolean(identityValid && api && me.kind === 'human' && workspace && ['owner', 'admin'].includes(workspace.role ?? ''));
  const list = useQuery({ queryKey: ['workspace-invitations', scopeKey, workspace?.id], queryFn: ({ signal }) => api!.workspaceInvitations(workspace!.id, signal), enabled: Boolean(canManage && api?.invitationCapabilities.list), retry: false, refetchInterval: 15000 });
  const invitations = canManage && !list.isError ? list.data ?? [] : [];
  const code = issued.current;
  const liveCode = code && canManage && code.workspaceId === workspace?.id && invitations.some(item => item.id === code.invitationId && item.status === 'pending' && new Date(item.expiresAt).getTime() > Date.now()) ? code : undefined;
  useEffect(() => { if (issued.current && (!canManage || issued.current.workspaceId !== workspace?.id || list.isError || list.isSuccess && !invitations.some(item => item.id === issued.current?.invitationId && item.status === 'pending'))) { issued.current = undefined; repaint(value => value + 1); } }, [canManage, workspace?.id, list.isError, list.data]);
  function save(value: InvitationOperation | undefined) {
    if (value) sessionStorage.setItem(key, JSON.stringify({ version: 1, operation: value })); else sessionStorage.removeItem(key);
    pending.current = value;
  }
  const alive = (signal: AbortSignal) => !signal.aborted;
  async function freshList(workspaceId: string, signal: AbortSignal) {
    const spaces = await client.onboarding!.workspaces(signal);
    if (!alive(signal)) throw new DOMException('Aborted', 'AbortError');
    const current = spaces.find(item => item.id === workspaceId);
    if (!current || !['owner', 'admin'].includes(current.role ?? '')) throw new ApiError(403, 'invitation_workspace_unavailable');
    const items = await api!.workspaceInvitations(workspaceId, signal);
    await cache.cancelQueries({ queryKey: ['workspace-invitations', scopeKey, workspaceId] });
    if (!alive(signal)) throw new DOMException('Aborted', 'AbortError');
    cache.setQueryData(['workspace-invitations', scopeKey, workspaceId], items);
    return items;
  }
  async function confirm(original: InvitationOperation, receipt: InvitationReceipt | InvitationAcceptance, signal: AbortSignal) {
    if (original.kind === 'accept') {
      if (!('principalId' in receipt) || receipt.principalId !== me.id) throw new ApiError(502, 'invalid_invitation_acceptance');
      const joined = await onMembershipChanged(receipt.workspaceId, signal);
      if (!alive(signal) || !joined) throw new DOMException('Aborted', 'AbortError');
      save(undefined); acceptCode.current = undefined;
      setOperation({ kind: 'accept', status: 'succeeded', message: `已加入 ${joined.title}，成员列表已更新。`, workspaceId: joined.id });
      return;
    }
    if (!('codeAvailable' in receipt) || receipt.invitation.workspaceId !== original.intent.workspaceId || original.kind === 'create' && receipt.invitation.createActionId !== original.intent.actionId || original.kind === 'revoke' && receipt.invitation.id !== original.intent.invitationId) throw new ApiError(502, 'invalid_invitation_receipt');
    if (original.kind === 'create' && receipt.codeAvailable && receipt.code) issued.current = { workspaceId: receipt.invitation.workspaceId, invitationId: receipt.invitation.id, code: receipt.code };
    const current = (await freshList(original.intent.workspaceId, signal)).find(item => item.id === receipt.invitation.id);
    if (!current) throw new ApiError(403, 'invitation_unavailable');
    if (original.kind === 'revoke' && current.status === 'pending') throw new ApiError(502, 'invitation_revoke_unconfirmed');
    save(undefined);
    setOperation({ kind: original.kind, status: 'succeeded', workspaceId: original.intent.workspaceId, invitationId: current.id, message: original.kind === 'revoke' ? current.status === 'revoked' ? '邀请已撤销，不能再用来加入。' : '原撤销操作已核对，该邀请当前已不可使用。' : current.status !== 'pending' ? '原邀请操作已确认，已显示当前状态。' : issued.current?.invitationId === current.id ? '一次性邀请码已创建，请只分享给准备加入的同事。' : '邀请已创建，但原邀请码无法再次读取。可以显式撤销后创建新邀请。' });
  }
  async function request(original: InvitationOperation, signal: AbortSignal): Promise<InvitationReceipt | InvitationAcceptance> {
    if (original.kind === 'create') return api!.createInvitation(original.intent, signal);
    if (original.kind === 'revoke') return api!.revokeInvitation(original.intent, signal);
    if (!acceptCode.current) throw new ApiError(422, 'original_invitation_code_required');
    return api!.acceptInvitation({ actionId: original.intent.actionId, code: acceptCode.current }, signal);
  }
  async function perform(original: InvitationOperation, reconcile: boolean, caller: string) {
    if (!api || !api.invitationCapabilities.actionRead || retired.current || caller !== scopeKey || busy.current || storageError) return;
    const signal = lifecycle.current.signal; if (!alive(signal)) return;
    busy.current = true;
    try { save(original); } catch { busy.current = false; setStorageError(true); setOperation({ kind: original.kind, status: 'error', message: '无法保存操作编号，提交已暂停。' }); return; }
    setOperation({ kind: original.kind, status: 'pending', workspaceId: actionWorkspace(original), message: reconcile ? '正在核对原操作…' : '正在提交…' });
    let mutationCommitted = false;
    try {
      let receipt: InvitationReceipt | InvitationAcceptance;
      if (reconcile) {
        try {
          const action: InvitationAction = await api.invitationAction(original.intent.actionId, signal);
          if (action.kind !== original.kind || action.actionId !== original.intent.actionId) throw new ApiError(502, 'invalid_invitation_action');
          receipt = action.receipt;
        } catch (error) {
          if (!(error instanceof ApiError) || error.status !== 404) throw error;
          // A missing receipt is not proof that the old request never committed.
          // Replay only the original stable ID; accept requires its original code.
          receipt = await request(original, signal);
        }
      } else receipt = await request(original, signal);
      mutationCommitted = true;
      if (!alive(signal)) return;
      await confirm(original, receipt, signal);
    } catch (error) {
      if (!alive(signal)) return;
      if (!mutationCommitted && original.kind === 'accept' && error instanceof ApiError && ['invitation_expired', 'invitation_revoked', 'invitation_used'].includes(error.code)) {
        try { save(undefined); acceptCode.current = undefined; setOperation({ kind: 'accept', status: 'error', message: '该邀请码已经过期、撤销或使用，本次未加入。请向同事索取新的邀请码。' }); return; } catch { /* Original action remains unresolved if its local marker cannot be cleared. */ }
      }
      setOperation({ kind: original.kind, status: 'unknown', workspaceId: actionWorkspace(original), message: error instanceof ApiError && error.code === 'original_invitation_code_required' ? '尚未找到原操作回执，请重新输入原邀请码后使用原操作核对。' : `${unknown} ${errorMessage(error)}` });
      if (error instanceof ApiError && error.status === 401) logout();
      if (error instanceof ApiError && [403, 404, 409, 410].includes(error.status)) { issued.current = undefined; void cache.invalidateQueries({ queryKey: ['workspaces', scopeKey] }); void cache.invalidateQueries({ queryKey: ['workspace-invitations', scopeKey] }); }
    } finally { busy.current = false; }
  }
  const visibleOperation = !identityValid ? undefined : operation?.workspaceId && !workspaces.some(item => item.id === operation.workspaceId) ? operation.status === 'unknown' || operation.status === 'pending' ? { ...operation, message: '原工作空间当前无法确认，原操作已保留，请核对原操作。' } : undefined : operation;
  return {
    scopeKey, workspace: identityValid ? workspace : undefined, invitations: identityValid ? invitations : [],
    loading: canManage && list.isPending,
    error: storageError ? '本地操作编号暂不可用，邀请提交已暂停。' : canManage && list.isError ? errorMessage(list.error) : undefined,
    canCreate: Boolean(canManage && api?.invitationCapabilities.create && api.invitationCapabilities.actionRead && api.invitationCapabilities.list && !storageError),
    canRevoke: Boolean(canManage && api?.invitationCapabilities.revoke && api.invitationCapabilities.actionRead && !storageError),
    canAccept: Boolean(identityValid && me.kind === 'human' && api?.invitationCapabilities.accept && api.invitationCapabilities.actionRead && !storageError),
    canReconcile: Boolean(identityValid && api?.invitationCapabilities.actionRead && !storageError),
    operation: visibleOperation, issuedCode: identityValid ? liveCode : undefined,
    onCreate: async (expiresInSeconds: number, caller: string) => { if (retired.current || preparingAccept.current || caller !== scopeKey || !workspace || !canManage || !api?.invitationCapabilities.create || !api.invitationCapabilities.actionRead || pending.current || ![3600, 86400, 604800].includes(expiresInSeconds)) return; issued.current = undefined; await perform({ kind: 'create', intent: { actionId: crypto.randomUUID(), workspaceId: workspace.id, expiresInSeconds } }, false, caller); },
    onRevoke: async (invitationId: string, caller: string) => { if (retired.current || preparingAccept.current || caller !== scopeKey || !workspace || !canManage || !api?.invitationCapabilities.revoke || !api.invitationCapabilities.actionRead || pending.current || !invitations.some(item => item.id === invitationId && item.status === 'pending')) return; issued.current = undefined; await perform({ kind: 'revoke', intent: { actionId: crypto.randomUUID(), workspaceId: workspace.id, invitationId } }, false, caller); },
    onAccept: async (value: string, caller: string) => {
      if (retired.current || caller !== scopeKey || !api?.invitationCapabilities.accept || !api.invitationCapabilities.actionRead || me.kind !== 'human' || busy.current || preparingAccept.current || pending.current && pending.current.kind !== 'accept' || !validInvitationCode(value)) return;
      const signal = lifecycle.current.signal; if (!alive(signal)) return;
      preparingAccept.current = true;
      try {
        const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value.trim()));
        const codeFingerprint = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('');
        if (!alive(signal)) return;
        if (pending.current?.kind === 'accept' && pending.current.intent.codeFingerprint !== codeFingerprint) { setOperation({ kind: 'accept', status: 'unknown', message: '输入的不是原邀请码。原操作已保留，请核对原操作或重新输入原邀请码。' }); return; }
        acceptCode.current = value.trim();
        await perform(pending.current ?? { kind: 'accept', intent: { actionId: crypto.randomUUID(), codeFingerprint } }, Boolean(pending.current), caller);
      } catch { if (alive(signal)) setOperation({ kind: 'accept', status: pending.current ? 'unknown' : 'error', message: '无法校验原操作，请恢复安全浏览器环境后重试。' }); }
      finally { preparingAccept.current = false; }
    },
    onReconcile: async (caller: string) => { if (!retired.current && caller === scopeKey && pending.current) await perform(pending.current, true, caller); },
    onRefresh: async (caller: string) => { if (!retired.current && caller === scopeKey && canManage) await Promise.all([list.refetch(), cache.invalidateQueries({ queryKey: ['workspace-members', scopeKey, workspace?.id] })]); },
  };
}
