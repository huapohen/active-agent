import { useEffect, useId, useRef, useState, type FormEvent } from 'react';
import { Check, Copy, KeyRound, Link2, LoaderCircle, RefreshCw, ShieldCheck, UserPlus, X } from 'lucide-react';
import { validInvitationCode } from './api';
import type { WorkspaceInfo } from './types';
import type { useWorkspaceInvitations } from './useWorkspaceInvitations';
import './workspace-invitations.css';

type Model = ReturnType<typeof useWorkspaceInvitations>;
export type WorkspaceInvitationsProps = { model: Model; workspaces: WorkspaceInfo[]; onSelectWorkspace: (id: string, scopeKey: string) => void; mode: 'invite' | 'join'; onOpenWorkspace?: (id: string, scopeKey: string) => void };
function date(value: string) { return new Date(value).toLocaleString('zh-CN', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false }); }
const status = { pending: '待使用', accepted: '已加入', revoked: '已撤销', expired: '已过期' };

/** This keyed boundary clears input and clipboard feedback on identity change. */
export function WorkspaceInvitations(props: WorkspaceInvitationsProps) { return <ScopedWorkspaceInvitations key={props.model.scopeKey} {...props} />; }
function ScopedWorkspaceInvitations({ model, workspaces, onSelectWorkspace, mode, onOpenWorkspace }: WorkspaceInvitationsProps) {
  const [code, setCode] = useState(''), [expires, setExpires] = useState(86400), [copied, setCopied] = useState<string>(), [copyError, setCopyError] = useState(false);
  const [submitting, setSubmitting] = useState(false), [revokeId, setRevokeId] = useState<string>();
  const active = useRef(true), synchronous = useRef(false), composing = useRef(false), inputId = useId();
  useEffect(() => { active.current = true; return () => { active.current = false; }; }, []);
  useEffect(() => { setCopied(undefined); setCopyError(false); setRevokeId(undefined); }, [model.workspace?.id, model.issuedCode?.invitationId, mode]);
  const pending = submitting || model.operation?.status === 'pending', unresolved = pending || model.operation?.status === 'unknown';
  async function action(callback: () => Promise<void>) {
    if (synchronous.current || !active.current) return;
    synchronous.current = true; setSubmitting(true);
    try { await callback(); } finally { synchronous.current = false; if (active.current) setSubmitting(false); }
  }
  function submit(event: FormEvent) {
    event.preventDefault(); if (composing.current || pending || !model.canAccept || !validInvitationCode(code) || unresolved && model.operation?.kind !== 'accept') return;
    const value = code; setCode(''); void action(() => model.onAccept(value, model.scopeKey));
  }
  async function copy() {
    const current = model.issuedCode; if (!current || pending || synchronous.current || !active.current || current.workspaceId !== model.workspace?.id || !model.invitations.some(item => item.id === current.invitationId && item.status === 'pending' && new Date(item.expiresAt).getTime() > Date.now())) return;
    setCopyError(false);
    try { await navigator.clipboard.writeText(current.code); if (active.current) setCopied(current.invitationId); }
    catch { if (active.current) setCopyError(true); }
  }
  return <div className="wi-panel">
    <div className="wi-heading"><span className="wi-icon">{mode === 'join' ? <KeyRound /> : <UserPlus />}</span><div><h2>{mode === 'join' ? '加入工作空间' : '邀请同事'}</h2><p>{mode === 'join' ? '使用同事提供的一次性邀请码加入团队。' : '让真实的人类和 Agent 同事加入同一个协作空间。'}</p></div></div>
    {model.error && <p className="wi-error" role="alert">{model.error}</p>}
    {model.operation && <div className={`wi-feedback wi-${model.operation.status}`} role={model.operation.status === 'error' ? 'alert' : 'status'}><p>{model.operation.status === 'pending' && <LoaderCircle className="wi-spin" size={15} />}{model.operation.message}</p>{model.operation.status === 'succeeded' && model.operation.kind === 'accept' && model.operation.workspaceId && onOpenWorkspace && <button type="button" className="secondary" onClick={() => onOpenWorkspace(model.operation!.workspaceId!, model.scopeKey)}>查看工作空间</button>}{model.operation.status === 'unknown' && <button type="button" className="secondary" disabled={pending || !model.canReconcile} title={!model.canReconcile ? '当前服务尚未开放原操作查询' : undefined} onClick={() => { void action(() => model.onReconcile(model.scopeKey)); }}><RefreshCw size={15} />核对原操作</button>}</div>}
    {mode === 'join' ? <form onSubmit={submit} onKeyDown={event => { if (event.key === 'Enter' && (event.nativeEvent.isComposing || composing.current || event.keyCode === 229)) event.preventDefault(); }}>
      <label htmlFor={inputId}>一次性邀请码</label><input id={inputId} type="password" autoComplete="off" spellCheck={false} value={code} onChange={event => setCode(event.target.value)} onCompositionStart={() => { composing.current = true; }} onCompositionEnd={() => { composing.current = false; }} disabled={pending || !model.canAccept || unresolved && model.operation?.kind !== 'accept'} placeholder="粘贴同事提供的邀请码" />
      <p className="wi-note">加入后只获得普通成员身份，不会自动加入所有群，也不会授予 Agent 新的执行来源权限。</p>
      <button className="primary" disabled={pending || !model.canAccept || !validInvitationCode(code) || unresolved && model.operation?.kind !== 'accept'}>{pending ? '正在核对…' : model.operation?.status === 'unknown' ? '使用原邀请码核对' : '加入工作空间'}</button>
      {!model.canAccept && <p className="wi-note">当前身份尚未开放邀请码加入，请联系工作空间管理员。</p>}
    </form> : <>
      <label htmlFor={inputId}>工作空间</label><select id={inputId} value={model.workspace?.id ?? ''} disabled={unresolved} onChange={event => onSelectWorkspace(event.target.value, model.scopeKey)}>{!workspaces.length && <option value="">尚未加入工作空间</option>}{workspaces.map(item => <option key={item.id} value={item.id}>{item.title}</option>)}</select>
      {model.canCreate ? <div className="wi-create"><label>有效期<select aria-label="邀请码有效期" value={expires} disabled={unresolved} onChange={event => setExpires(Number(event.target.value))}><option value={3600}>1 小时</option><option value={86400}>24 小时</option><option value={604800}>7 天</option></select></label><button className="primary" disabled={unresolved} onClick={() => { void action(() => model.onCreate(expires, model.scopeKey)); }}><Link2 size={16} />创建一次性邀请</button></div> : <p className="wi-note">只有当前工作空间的所有者或管理员可以创建邀请。</p>}
      {model.issuedCode && <div className="wi-code"><ShieldCheck size={20} /><div><strong>邀请码仅在本次操作中可见</strong><p>复制后私下分享给指定同事。关闭客户端后无法再次读取，可撤销后重新创建。</p></div><button className="secondary" disabled={pending} onClick={() => { void copy(); }}>{copied === model.issuedCode.invitationId ? <Check size={16} /> : <Copy size={16} />}{copied === model.issuedCode.invitationId ? '已复制' : '复制邀请码'}</button>{copyError && <p className="wi-error" role="alert">复制失败，请检查此客户端的剪贴板权限后重试。</p>}</div>}
      <div className="wi-list-heading"><h3>邀请记录</h3><button className="icon-button" aria-label="刷新邀请记录" disabled={pending || !model.canCreate && !model.canRevoke} onClick={() => { void action(() => model.onRefresh(model.scopeKey)); }}><RefreshCw size={17} /></button></div>
      {model.loading ? <p className="wi-note" role="status">正在读取邀请记录…</p> : model.invitations.length ? <ul className="wi-list">{model.invitations.map(item => <li key={item.id}><span className={`wi-status wi-status-${item.status}`}>{status[item.status]}</span><div><strong>一次性成员邀请</strong><small>创建于 {date(item.createdAt)} · 有效至 {date(item.expiresAt)}</small></div>{model.canRevoke && item.status === 'pending' && <button className="wi-text-button" disabled={unresolved} onClick={() => setRevokeId(item.id)}>撤销</button>}{revokeId === item.id && <div className="wi-revoke" role="group" aria-label="确认撤销邀请"><p>撤销后，此邀请码不能再被使用。</p><button className="secondary" disabled={pending} onClick={() => setRevokeId(undefined)}><X size={14} />取消</button><button className="secondary" disabled={unresolved} onClick={() => { setRevokeId(undefined); void action(() => model.onRevoke(item.id, model.scopeKey)); }}>确认撤销</button></div>}</li>)}</ul> : <p className="wi-note">当前没有可显示的邀请记录。</p>}
    </>}
  </div>;
}
