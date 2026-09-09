import { useEffect, useId, useRef, useState, type FormEvent, type KeyboardEvent } from 'react';
import { ArrowRight, Building2, Check, CheckCircle2, LoaderCircle, MessageCircle, Plus, RefreshCw, Rocket, Search, Sparkles, UserRound } from 'lucide-react';
import type { Principal } from './types';
import './commercial-onboarding.css';

export type CommercialWorkspace = { id: string; title: string; role?: string };
export type CommercialOperationName = 'rename' | 'workspace' | 'room';
export type CommercialProfileInput = { displayName: string };
export type CommercialWorkspaceInput = { title: string };
export type CommercialRoomInput = { workspaceId: string; title: string; memberIds: string[] };
export type CommercialProfileResult = { id: string; displayName: string };
export type CommercialRoomResult = { id: string; workspaceId: string; title: string };

/** The owner keeps the action ID and original intent, including across dialogs.
 * A resolved callback is not a success receipt: only state.result confirms it. */
export type CommercialActionState<Input, Result> = {
  scopeKey: string;
  status: 'idle' | 'pending' | 'unknown' | 'error';
  message?: string;
  submitted?: Input;
  result?: never;
} | {
  scopeKey: string;
  status: 'succeeded';
  message?: string;
  submitted?: Input;
  result: Result;
};
export type CommercialProfileState = CommercialActionState<CommercialProfileInput, CommercialProfileResult>;
export type CommercialWorkspaceState = CommercialActionState<CommercialWorkspaceInput, CommercialWorkspace>;
export type CommercialRoomState = CommercialActionState<CommercialRoomInput, CommercialRoomResult>;
export type CommercialLoadState = { scopeKey: string; status: 'loading' | 'ready' | 'error'; message?: string };
export type CommercialMemberLoadState = CommercialLoadState & { workspaceId: string };

type Callback<Input> = (input: Input, scopeKey: string) => void | Promise<void>;
type Reconcile = (scopeKey: string) => void | Promise<void>;
type ActionBase<Input, Result> = {
  scopeKey: string;
  enabled: boolean;
  state?: CommercialActionState<Input, Result>;
  onSubmit: Callback<Input>;
  onReconcile?: Reconcile;
  onCancel?: () => void;
};
export type CommercialProfileFormProps = ActionBase<CommercialProfileInput, CommercialProfileResult> & { me: Principal };
export type CommercialWorkspaceFormProps = ActionBase<CommercialWorkspaceInput, CommercialWorkspace>;
export type CommercialRoomFormProps = ActionBase<CommercialRoomInput, CommercialRoomResult> & {
  me: Principal;
  workspace?: CommercialWorkspace;
  members: Principal[];
  membersLoad: CommercialMemberLoadState;
  onRefreshMembers?: (workspaceId: string, scopeKey: string) => void | Promise<void>;
  onOpenRoom?: (roomId: string, scopeKey: string) => void;
};
export type CommercialOnboardingProps = {
  scopeKey: string;
  me: Principal;
  workspaces: CommercialWorkspace[];
  workspaceLoad: CommercialLoadState;
  selectedWorkspaceId?: string;
  members: Principal[];
  membersLoad: CommercialMemberLoadState;
  canRename: boolean;
  canCreateWorkspace: boolean;
  canCreateRoom: boolean;
  profileState?: CommercialProfileState;
  workspaceState?: CommercialWorkspaceState;
  roomState?: CommercialRoomState;
  onRename: Callback<CommercialProfileInput>;
  onCreateWorkspace: Callback<CommercialWorkspaceInput>;
  onCreateRoom: Callback<CommercialRoomInput>;
  onSelectWorkspace: (workspaceId: string, scopeKey: string) => void;
  onReconcile?: (operation: CommercialOperationName, scopeKey: string) => void | Promise<void>;
  onRefreshWorkspaces?: (scopeKey: string) => void | Promise<void>;
  onRefreshMembers?: CommercialRoomFormProps['onRefreshMembers'];
  onOpenRoom?: CommercialRoomFormProps['onOpenRoom'];
};

const byteLength = (value: string) => new TextEncoder().encode(value).length;
const hasControl = (value: string) => /[\p{Cc}\p{Cf}\p{Cs}\u2028\u2029]/u.test(value);
const validTitle = (value: string) => value.trim().length > 0 && byteLength(value.trim()) <= 240 && !hasControl(value.trim());
const validName = (value: string) => { const name = value.trim(); return Array.from(name).length >= 1 && Array.from(name).length <= 80 && !hasControl(name); };
const roleLabel = (role?: string) => role === 'owner' ? '所有者' : role === 'admin' ? '管理员' : role === 'member' ? '成员' : undefined;

function IdentityAvatar({ person }: { person: Principal }) {
  return <span aria-hidden="true" className={`co-avatar ${person.kind === 'agent' ? 'co-avatar-agent' : ''}`}>{person.kind === 'agent' ? <Sparkles size={20} /> : Array.from(person.displayName || person.id)[0]}</span>;
}

/** No global keyboard hooks: an IME confirmation is never a form submission. */
function useComposition() {
  const composing = useRef(false);
  return {
    composing,
    onCompositionStart: () => { composing.current = true; },
    onCompositionEnd: () => { composing.current = false; },
    onKeyDown: (event: KeyboardEvent<HTMLFormElement>) => {
      if (event.key === 'Enter' && (event.nativeEvent.isComposing || composing.current || event.keyCode === 229)) event.preventDefault();
    },
  };
}

function useAction<Input, Result>(scopeKey: string, state?: CommercialActionState<Input, Result>) {
  const alive = useRef(true), inFlight = useRef(false);
  const [localBusy, setLocalBusy] = useState(false), [localUnknown, setLocalUnknown] = useState(false);
  useEffect(() => { alive.current = true; return () => { alive.current = false; }; }, []);
  const stateMatches = !state || state.scopeKey === scopeKey;
  const scoped = stateMatches ? state : undefined;
  const busy = localBusy || scoped?.status === 'pending';
  const unknown = scoped?.status === 'unknown' || (localUnknown && scoped?.status !== 'error' && scoped?.status !== 'succeeded');
  async function invoke(callback: () => void | Promise<void>) {
    if (!alive.current || inFlight.current || !stateMatches || scoped?.status === 'pending') return;
    inFlight.current = true; setLocalBusy(true);
    try { await callback(); }
    catch { if (alive.current) setLocalUnknown(true); }
    finally { inFlight.current = false; if (alive.current) setLocalBusy(false); }
  }
  return { busy, unknown, stateMatches, scoped, locked: busy || unknown || !stateMatches, invoke };
}

function OperationFeedback<Input, Result>({ state, unknown, stateMatches, busy, onReconcile, success }: {
  state?: CommercialActionState<Input, Result>;
  unknown: boolean;
  stateMatches: boolean;
  busy: boolean;
  onReconcile?: () => void;
  success?: string;
}) {
  if (!stateMatches) return <p className="co-note" role="status">正在切换工作身份…</p>;
  if (unknown) return <div className="co-feedback co-feedback-unknown" role="status"><strong>操作结果待确认</strong><p>{state?.message || '请先核对原操作，当前内容已保留。'}</p>{onReconcile ? <button className="co-button co-button-secondary" type="button" disabled={busy} onClick={onReconcile}><RefreshCw size={15} />{busy ? '正在核对…' : '核对原操作'}</button> : <p>重新连接后，请核对原操作。</p>}</div>;
  if (state?.status === 'error') return <p className="co-feedback co-feedback-error" role="alert">{state.message || '操作未完成，请检查当前内容或重新读取工作空间。'}</p>;
  if (state?.status === 'succeeded' && success) return <p className="co-feedback co-feedback-success" role="status"><CheckCircle2 size={16} />{success}</p>;
  return null;
}

export function CommercialProfileForm(props: CommercialProfileFormProps) {
  return <ProfileForm key={`${props.scopeKey}:${props.me.id}`} {...props} />;
}

function ProfileForm({ scopeKey, me, enabled, state, onSubmit, onReconcile, onCancel }: CommercialProfileFormProps) {
  const [name, setName] = useState(state?.scopeKey === scopeKey && state.submitted ? state.submitted.displayName : me.displayName);
  const id = useId(), composition = useComposition(), action = useAction(scopeKey, state);
  const frozen = action.locked && action.scoped?.submitted ? action.scoped.submitted.displayName : name;
  const nameValid = validName(frozen), changed = frozen.trim() !== me.displayName;
  const alreadyConfirmed = action.scoped?.status === 'succeeded' && action.scoped.result.id === me.id && action.scoped.result.displayName === frozen.trim();
  const blocked = !enabled || action.locked;
  async function submit(event: FormEvent) {
    event.preventDefault();
    if (blocked || !nameValid || !changed || alreadyConfirmed || composition.composing.current) return;
    await action.invoke(() => onSubmit({ displayName: frozen.trim() }, scopeKey));
  }
  return <form className="co-form" aria-label="设置昵称" onSubmit={submit} onKeyDown={composition.onKeyDown}>
    <label htmlFor={id}>昵称<input id={id} autoComplete="nickname" value={frozen} disabled={blocked} onChange={event => setName(event.target.value)} onCompositionStart={composition.onCompositionStart} onCompositionEnd={composition.onCompositionEnd} aria-describedby={`${id}-hint`} aria-invalid={frozen.length > 0 && !nameValid} /></label>
    <p className="co-note" id={`${id}-hint`}>同事会在消息和协作中看到这个名字。最多 80 个字符。</p>
    {frozen.length > 0 && !nameValid && <p className="co-validation" role="alert">昵称需为 1–80 个字符，不能包含控制字符。</p>}
    {!enabled && <p className="co-note">当前身份暂不可修改昵称。</p>}
    <OperationFeedback {...action} state={action.scoped} onReconcile={onReconcile ? () => { void action.invoke(() => onReconcile(scopeKey)); } : undefined} success={action.scoped?.status === 'succeeded' && action.scoped.result.id === me.id ? `昵称已更新为 ${action.scoped.result.displayName}` : undefined} />
    <div className="co-form-footer">{onCancel && <button className="co-button co-button-secondary" type="button" disabled={action.busy} onClick={onCancel}>取消</button>}<button className="co-button co-button-primary" type="submit" disabled={blocked || !nameValid || !changed || alreadyConfirmed}>{action.busy ? <LoaderCircle size={16} className="co-spin" /> : <Check size={16} />}{action.busy ? '正在保存…' : '保存昵称'}</button></div>
  </form>;
}

export function CommercialWorkspaceForm(props: CommercialWorkspaceFormProps) {
  return <WorkspaceForm key={props.scopeKey} {...props} />;
}

function WorkspaceForm({ scopeKey, enabled, state, onSubmit, onReconcile, onCancel }: CommercialWorkspaceFormProps) {
  const [title, setTitle] = useState(state?.scopeKey === scopeKey && state.submitted ? state.submitted.title : '');
  const id = useId(), composition = useComposition(), action = useAction(scopeKey, state);
  const frozen = action.locked && action.scoped?.submitted ? action.scoped.submitted.title : title;
  const titleValid = validTitle(frozen), blocked = !enabled || action.locked;
  const alreadyConfirmed = action.scoped?.status === 'succeeded' && action.scoped.result.title === frozen.trim();
  async function submit(event: FormEvent) {
    event.preventDefault(); if (blocked || !titleValid || alreadyConfirmed || composition.composing.current) return;
    await action.invoke(() => onSubmit({ title: frozen.trim() }, scopeKey));
  }
  return <form className="co-form" aria-label="创建工作空间" onSubmit={submit} onKeyDown={composition.onKeyDown}>
    <label htmlFor={id}>工作空间名称<input id={id} value={frozen} disabled={blocked} placeholder="输入公司或团队名称" onChange={event => setTitle(event.target.value)} onCompositionStart={composition.onCompositionStart} onCompositionEnd={composition.onCompositionEnd} aria-describedby={`${id}-hint`} aria-invalid={frozen.length > 0 && !titleValid} /></label>
    <p className="co-note" id={`${id}-hint`}>创建后，你将成为这个工作空间的所有者。</p>
    {frozen.length > 0 && !titleValid && <p className="co-validation" role="alert">名称需为有效的单行文字，不能超过 240 字节（通常为 80 个汉字）。</p>}
    {!enabled && <p className="co-note">当前身份暂不可创建工作空间。</p>}
    <OperationFeedback {...action} state={action.scoped} onReconcile={onReconcile ? () => { void action.invoke(() => onReconcile(scopeKey)); } : undefined} success={action.scoped?.status === 'succeeded' ? `已创建 ${action.scoped.result.title}` : undefined} />
    <div className="co-form-footer">{onCancel && <button className="co-button co-button-secondary" type="button" disabled={action.busy} onClick={onCancel}>取消</button>}<button className="co-button co-button-primary" type="submit" disabled={blocked || !titleValid || alreadyConfirmed}>{action.busy ? <LoaderCircle size={16} className="co-spin" /> : <Plus size={16} />}{action.busy ? '正在创建…' : '创建工作空间'}</button></div>
  </form>;
}

export function CommercialRoomForm(props: CommercialRoomFormProps) {
  return <RoomForm key={`${props.scopeKey}:${props.me.id}:${props.workspace?.id || ''}`} {...props} />;
}

function RoomForm({ scopeKey, me, workspace, members, membersLoad, enabled, state, onSubmit, onReconcile, onCancel, onRefreshMembers, onOpenRoom }: CommercialRoomFormProps) {
  const submitted = state?.scopeKey === scopeKey && state.submitted?.workspaceId === workspace?.id ? state.submitted : undefined;
  const [title, setTitle] = useState(submitted?.title || ''), [selected, setSelected] = useState<string[]>(submitted?.memberIds || []), [query, setQuery] = useState(''), [edited, setEdited] = useState(false);
  const sourceMatches = !state?.submitted || state.submitted.workspaceId === workspace?.id;
  const id = useId(), composition = useComposition(), action = useAction(scopeKey, state);
  const loadMatches = membersLoad.scopeKey === scopeKey && membersLoad.workspaceId === workspace?.id;
  const ready = loadMatches && membersLoad.status === 'ready';
  const safeMembers = ready && sourceMatches ? [...new Map(members.map(person => [person.id, person])).values()] : [];
  const self = safeMembers.find(person => person.id === me.id);
  const allowedIds = new Set(safeMembers.map(person => person.id));
  const frozen = action.locked && submitted ? submitted : { workspaceId: workspace?.id || '', title, memberIds: selected };
  const selectedIds = new Set(frozen.memberIds.filter(memberId => allowedIds.has(memberId))); if (self) selectedIds.add(self.id);
  const people = safeMembers.filter(person => person.id !== me.id && `${person.displayName} ${person.kind === 'agent' ? 'Agent' : '人类'}`.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase()));
  const titleValid = validTitle(frozen.title), blocked = !enabled || action.locked || !sourceMatches || !workspace || !ready || !self;
  const originalRestricted = action.stateMatches && (action.unknown || action.busy) && (!sourceMatches || !workspace || !ready || !self);
  const visibleTitle = originalRestricted || !action.stateMatches ? '' : frozen.title;
  const result = action.scoped?.status === 'succeeded' && action.scoped.result.workspaceId === workspace?.id ? action.scoped.result : undefined;
  const alreadyConfirmed = Boolean(result) && (submitted ? frozen.title.trim() === submitted.title.trim() && JSON.stringify([...selectedIds].sort()) === JSON.stringify([...new Set(submitted.memberIds)].sort()) : !edited);
  async function submit(event: FormEvent) {
    event.preventDefault(); if (blocked || !titleValid || alreadyConfirmed || selectedIds.size > 100 || composition.composing.current) return;
    await action.invoke(() => onSubmit({ workspaceId: workspace!.id, title: frozen.title.trim(), memberIds: [...selectedIds].sort() }, scopeKey));
  }
  return <form className="co-form" aria-label="创建群聊" onSubmit={submit} onKeyDown={composition.onKeyDown}>
    {workspace ? <div className="co-current-workspace"><Building2 size={17} /><span>{workspace.title}</span></div> : <p className="co-note">请先选择或创建工作空间。</p>}
    <label htmlFor={id}>群聊名称<input id={id} value={visibleTitle} disabled={blocked} placeholder="例如：项目协作" onChange={event => { setEdited(true); setTitle(event.target.value); }} onCompositionStart={composition.onCompositionStart} onCompositionEnd={composition.onCompositionEnd} aria-invalid={visibleTitle.length > 0 && !titleValid} /></label>
    {visibleTitle.length > 0 && !titleValid && <p className="co-validation" role="alert">群聊名称需为有效的单行文字，不能超过 240 字节（通常为 80 个汉字）。</p>}
    <fieldset className="co-members" disabled={!enabled || action.locked || !sourceMatches || !ready}><legend>参与同事{ready && self ? ` · 已选 ${selectedIds.size} 位` : ''}</legend>
      {!sourceMatches ? <p className="co-note">原群聊操作的成员信息暂不可显示。</p> : !workspace ? <p className="co-note">选择工作空间后读取同事列表。</p> : !loadMatches || membersLoad.status === 'loading' ? <p className="co-note" role="status">正在读取当前工作空间的同事…</p> : membersLoad.status === 'error' ? <div role="alert"><p className="co-validation">{membersLoad.message || '暂时无法读取同事列表。'}</p></div> : !self ? <p className="co-validation" role="alert">当前身份不在此工作空间的成员列表中，请重新读取。</p> : <>
        <div className="co-self"><IdentityAvatar person={self} /><span><strong>{self.displayName || self.id}</strong><small>{self.kind === 'agent' ? 'Agent 同事' : '人类同事'} · 我</small></span><span className="co-member-fixed"><Check size={15} />已加入</span></div>
        {safeMembers.length > 1 ? <><label className="co-member-search"><Search size={16} /><input aria-label="搜索工作空间同事" value={query} placeholder="搜索人或 Agent 同事" onChange={event => setQuery(event.target.value)} /></label><div className="co-member-options">{people.length ? people.map(person => <label key={person.id} className="co-member-option"><input type="checkbox" aria-label={`${person.displayName || person.id} ${person.kind === 'agent' ? 'Agent 同事' : '人类同事'}`} checked={selectedIds.has(person.id)} disabled={(!selectedIds.has(person.id) && selectedIds.size >= 100) || !enabled || action.locked} onChange={event => { setEdited(true); setSelected(previous => event.target.checked ? [...new Set([...previous, person.id])] : previous.filter(memberId => memberId !== person.id)); }} /><IdentityAvatar person={person} /><span><strong>{person.displayName || person.id}</strong><small>{person.kind === 'agent' ? 'Agent 同事' : '人类同事'}</small></span></label>) : <p className="co-note">没有匹配的同事。</p>}</div></> : <p className="co-note">当前工作空间只有你，也可以先创建群聊开始协作。</p>}
      </>}
    </fieldset>
    {workspace && onRefreshMembers && <button type="button" className="co-text-button" disabled={action.locked || !loadMatches || membersLoad.status === 'loading'} onClick={() => { void onRefreshMembers(workspace.id, scopeKey); }}><RefreshCw size={14} />重新读取同事</button>}
    <p className="co-note">人和 Agent 同事都从当前工作空间的真实成员中选择，拥有各自的身份与协作权限。</p>
    {!enabled && <p className="co-note">当前身份暂不可创建群聊。</p>}
    {originalRestricted ? <div className="co-feedback co-feedback-unknown" role="status"><strong>{action.busy ? '正在核对原群聊操作' : '原群聊操作仍待核对'}</strong><p>原工作空间或成员权限暂无法确认。原操作已保留，不能改为当前工作空间重新创建。</p>{onReconcile && <button type="button" className="co-button co-button-secondary" disabled={action.busy} onClick={() => { void action.invoke(() => onReconcile(scopeKey)); }}><RefreshCw size={15} />核对原操作</button>}</div> : <OperationFeedback {...action} stateMatches={action.stateMatches && sourceMatches} state={action.scoped} onReconcile={onReconcile && sourceMatches ? () => { void action.invoke(() => onReconcile(scopeKey)); } : undefined} success={result ? `已创建群聊 ${result.title}` : undefined} />}
    <div className="co-form-footer">{onCancel && <button className="co-button co-button-secondary" type="button" disabled={action.busy} onClick={onCancel}>取消</button>}{result && alreadyConfirmed && onOpenRoom ? <button type="button" className="co-button co-button-primary" onClick={() => onOpenRoom(result.id, scopeKey)}>进入群聊<ArrowRight size={16} /></button> : <button className="co-button co-button-primary" type="submit" disabled={blocked || !titleValid || alreadyConfirmed || selectedIds.size > 100}>{action.busy ? <LoaderCircle size={16} className="co-spin" /> : <MessageCircle size={16} />}{action.busy ? '正在创建…' : '创建群聊'}</button>}</div>
  </form>;
}

export function CommercialOnboarding(props: CommercialOnboardingProps) {
  return <Onboarding key={`${props.scopeKey}:${props.me.id}`} {...props} />;
}

function Onboarding(props: CommercialOnboardingProps) {
  const { scopeKey, me, workspaces, workspaceLoad, selectedWorkspaceId } = props;
  const ready = workspaceLoad.scopeKey === scopeKey && workspaceLoad.status === 'ready';
  const safeWorkspaces = ready ? workspaces : [];
  const workspace = safeWorkspaces.find(item => item.id === selectedWorkspaceId);
  const blockedSwitch = [props.profileState, props.workspaceState, props.roomState].some(state => state?.scopeKey === scopeKey && (state.status === 'pending' || state.status === 'unknown'));
  return <section className="commercial-onboarding" aria-label="开始协作"><div className="co-layout">
    <header className="co-welcome"><span className="co-welcome-icon"><Rocket size={29} /></span><div><h1>欢迎，{me.displayName || me.id}</h1><p>设置工作身份，和人、Agent 同事一起开始协作。</p></div></header>
    <div className="co-grid">
      <section className="co-card"><header className="co-card-heading"><span className="co-step">1</span><div><h2>个人资料</h2><p>让同事知道如何称呼你</p></div><UserRound size={21} /></header><div className="co-identity"><IdentityAvatar person={me} /><div><strong>{me.displayName || me.id}</strong><small>{me.kind === 'agent' ? 'Agent 同事' : '人类同事'}</small></div></div><CommercialProfileForm scopeKey={scopeKey} me={me} enabled={props.canRename && ![props.workspaceState, props.roomState].some(state => state?.scopeKey === scopeKey && (state.status === 'pending' || state.status === 'unknown'))} state={props.profileState} onSubmit={props.onRename} onReconcile={props.onReconcile ? key => props.onReconcile!('rename', key) : undefined} /></section>
      <section className="co-card"><header className="co-card-heading"><span className="co-step">2</span><div><h2>工作空间</h2><p>选择已有团队，或创建你的工作空间</p></div><Building2 size={21} /></header>
        {!ready ? workspaceLoad.scopeKey === scopeKey && workspaceLoad.status === 'error' ? <p className="co-validation" role="alert">{workspaceLoad.message || '暂时无法读取工作空间。'}</p> : <p className="co-note" role="status">正在读取工作空间…</p> : safeWorkspaces.length ? <div className="co-workspaces" aria-label="我的工作空间">{safeWorkspaces.map(item => <button key={item.id} type="button" className={`co-workspace-option ${item.id === selectedWorkspaceId ? 'co-selected' : ''}`} aria-label={`${item.title}${roleLabel(item.role) ? ` ${roleLabel(item.role)}` : ''}`} aria-pressed={item.id === selectedWorkspaceId} disabled={blockedSwitch} onClick={() => props.onSelectWorkspace(item.id, scopeKey)}><Building2 size={20} /><span><strong>{item.title}</strong>{roleLabel(item.role) && <small>{roleLabel(item.role)}</small>}</span>{item.id === selectedWorkspaceId && <Check size={17} />}</button>)}</div> : <p className="co-empty">你还没有加入工作空间。创建后，可以在其中建立会话。</p>}
        {props.onRefreshWorkspaces && <button type="button" className="co-text-button" disabled={blockedSwitch || workspaceLoad.scopeKey !== scopeKey || workspaceLoad.status === 'loading'} onClick={() => { void props.onRefreshWorkspaces!(scopeKey); }}><RefreshCw size={14} />重新读取工作空间</button>}
        <CommercialWorkspaceForm scopeKey={scopeKey} enabled={props.canCreateWorkspace && !blockedSwitch} state={props.workspaceState} onSubmit={props.onCreateWorkspace} onReconcile={props.onReconcile ? key => props.onReconcile!('workspace', key) : undefined} />
      </section>
      <section className="co-card co-room-card"><header className="co-card-heading"><span className="co-step">3</span><div><h2>创建群聊</h2><p>在工作空间里建立一个协作会话</p></div><MessageCircle size={21} /></header><CommercialRoomForm scopeKey={scopeKey} me={me} workspace={workspace} members={props.members} membersLoad={props.membersLoad} enabled={props.canCreateRoom && ![props.profileState, props.workspaceState].some(state => state?.scopeKey === scopeKey && (state.status === 'pending' || state.status === 'unknown'))} state={props.roomState} onSubmit={props.onCreateRoom} onReconcile={props.onReconcile ? key => props.onReconcile!('room', key) : undefined} onRefreshMembers={props.onRefreshMembers} onOpenRoom={props.onOpenRoom} /></section>
    </div>
  </div></section>;
}
