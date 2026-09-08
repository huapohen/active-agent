import { useEffect, useRef, useState, type FormEvent } from 'react';
import { SignIn, useAuth } from '@clerk/react';
import { QueryClient, QueryClientProvider, useInfiniteQuery, useQuery, useQueryClient } from '@tanstack/react-query';
import { createStore } from 'zustand/vanilla';
import { useStore } from 'zustand';
import * as Menu from '@radix-ui/react-dropdown-menu';
import * as Dialog from '@radix-ui/react-dialog';
import { ArrowDown, AtSign, BellOff, Check, CheckCheck, ChevronDown, FileText, FolderClosed, Grid2x2, LoaderCircle, LogOut, Menu as MenuIcon, MessageCircle, MoreHorizontal, Pin, Plus, RefreshCw, Rocket, Search, Send, Settings, Smile, Sparkles, Users, X } from 'lucide-react';
import { ApiError, LegacyClient, StartupClient, errorMessage } from './api';
import type { CollaborationClient, Message, Principal, Room, SendIntent } from './types';
import { useRongCloud } from './rongcloud';

type Session = { id: string; client: CollaborationClient; principal: Principal; logout?: () => Promise<unknown> };
const defaultEndpoint = import.meta.env.VITE_API_BASE || 'http://127.0.0.1:3318';
const legacyEnabled = import.meta.env.VITE_ENABLE_LEGACY === 'true';
const label = (p: Principal) => p.displayName || p.id;

export function Avatar({ name, agent = false, room = false, small = false }: { name: string; agent?: boolean; room?: boolean; small?: boolean }) {
  return <span aria-hidden="true" className={`avatar ${agent ? 'agent-avatar' : ''} ${room ? 'room-avatar' : ''} ${small ? 'small' : ''}`}>{agent ? <Sparkles size={small ? 17 : 22} /> : room ? <MessageCircle size={small ? 17 : 23} /> : name.slice(0, 1)}</span>;
}
function Status({ error }: { error: unknown }) { return error ? <p className="error" role="alert">{errorMessage(error)}</p> : null; }

export function App({ clerkEnabled }: { clerkEnabled: boolean }) {
  const [session, setSession] = useState<Session>();
  const [mode, setMode] = useState<'startup' | 'legacy'>('startup');
  const retired = useRef<Session | undefined>(undefined);
  const open = (client: CollaborationClient, p: Principal, logout?: Session['logout']) => {
    retired.current?.client.close();
    const next = { id: crypto.randomUUID(), client, principal: p, logout };
    retired.current = next; setSession(next);
  };
  const close = () => {
    const current = retired.current;
    current?.client.close(); retired.current = undefined; setSession(undefined);
    void current?.logout?.();
  };
  if (session) return <SessionProvider key={session.id} session={session} onLogout={close} />;
  return <main className="login-layout"><section className="login-card">
    <div className="brand"><Rocket /><strong>人机</strong><span>共生 · 同权 · 主动协作</span></div>
    <h1>进入你的工作空间</h1><p className="subtle">人和 Agent 在同一个工作空间中，一起沟通、执行与交付。</p>
    {legacyEnabled && <div className="auth-tabs"><button className={mode === 'startup' ? 'active' : ''} onClick={() => setMode('startup')}>商业工作空间</button><button className={mode === 'legacy' ? 'active' : ''} onClick={() => setMode('legacy')}>现有数据迁移</button></div>}
    {mode === 'startup' ? clerkEnabled ? <ClerkLogin onConnect={open} /> : <div className="setup-note"><h2>配置企业登录</h2><p>当前部署尚未配置 Clerk 登录。请在本机配置公开的登录标识和工作空间地址，然后重新启动 Web 开发服务。</p><code>VITE_CLERK_PUBLISHABLE_KEY</code></div> : <LegacyLogin onConnect={open} />}
  </section><aside className="login-story"><Rocket size={56} /><h2>每一位同事，<br />都有自己的主动性。</h2><p>工作过程可见，协作成果可追溯。<br />让沟通自然走向行动。</p></aside></main>;
}

function ClerkLogin({ onConnect }: { onConnect: (c: CollaborationClient, p: Principal, logout?: Session['logout']) => void }) {
  const { isLoaded, isSignedIn, getToken, signOut } = useAuth();
  const [error, setError] = useState<unknown>();
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    if (!isLoaded || !isSignedIn) return;
    const client = new StartupClient(defaultEndpoint, () => getToken());
    let live = true, transferred = false;
    client.me().then(p => { if (live) { transferred = true; onConnect(client, p, () => signOut()); } }).catch(e => { if (live) setError(e); });
    return () => { live = false; if (!transferred) client.close(); };
    // An adapter is handed to the authenticated shell exactly once per attempt.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isLoaded, isSignedIn, attempt]);
  if (!isLoaded) return <p className="subtle">正在加载登录…</p>;
  if (!isSignedIn) return <SignIn routing="hash" />;
  return <div><p>正在进入工作空间…</p><Status error={error} />{Boolean(error) && <button className="primary" onClick={() => { setError(undefined); setAttempt(attempt + 1); }}>重新连接</button>}</div>;
}

function LegacyLogin({ onConnect }: { onConnect: (c: CollaborationClient, p: Principal) => void }) {
  const [endpoint, setEndpoint] = useState(import.meta.env.VITE_LEGACY_API_BASE || 'http://127.0.0.1:3218');
  const [username, setUsername] = useState(''), [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false), [error, setError] = useState<unknown>();
  const lifecycle = useRef(new AbortController());
  useEffect(() => { const controller = new AbortController(); lifecycle.current = controller; return () => controller.abort(); }, []);
  async function submit(e: FormEvent) {
    e.preventDefault(); if (busy) return; setBusy(true); setError(undefined);
    const signal = lifecycle.current.signal; let client: LegacyClient | undefined;
    try { client = await LegacyClient.login(endpoint, username.trim(), password, signal); const p = await client.me(signal); signal.throwIfAborted(); setPassword(''); onConnect(client, p); client = undefined; }
    catch (e) { client?.close(); if (!signal.aborted) setError(e); }
    finally { if (!signal.aborted) setBusy(false); }
  }
  return <form onSubmit={submit} className="login-form"><p className="migration-note">使用现有办公服务的真实账号和数据。此模式独立于商业工作空间，不能代替 Clerk 认证。</p>
    <label>工作空间地址<input value={endpoint} onChange={e => setEndpoint(e.target.value)} type="url" required disabled={busy} /></label>
    <label>账号<input autoComplete="username" value={username} onChange={e => setUsername(e.target.value)} required disabled={busy} /></label>
    <label>密码<input autoComplete="current-password" type="password" value={password} onChange={e => setPassword(e.target.value)} required disabled={busy} /></label>
    <Status error={error} /><button className="primary" disabled={busy}>{busy ? '正在登录…' : '登录工作空间'}</button>
  </form>;
}

function SessionProvider({ session, onLogout }: { session: Session; onLogout: () => void }) {
  const [queryClient] = useState(() => new QueryClient({ defaultOptions: { queries: { retry: (attempt, error) => !(error instanceof ApiError && [401, 403, 404].includes(error.status)) && attempt < 1, staleTime: 5000, refetchOnWindowFocus: true }, mutations: { retry: false } } }));
  useEffect(() => {
    const off = queryClient.getQueryCache().subscribe(event => { const error = event.query.state.error; if (error instanceof ApiError && error.status === 401) onLogout(); });
    return () => { off(); void queryClient.cancelQueries(); queryClient.clear(); };
  }, [queryClient]);
  return <QueryClientProvider client={queryClient}><Workspace session={session} onLogout={onLogout} /></QueryClientProvider>;
}

function Workspace({ session, onLogout }: { session: Session; onLogout: () => void }) {
  const { client, principal: me } = session;
  const cache = useQueryClient();
  const [ui] = useState(() => createStore<{ nav: 'messages' | 'agents' | 'docs'; roomId?: string; collapsed: boolean }>(() => ({ nav: 'messages', collapsed: false })));
  const { nav, roomId, collapsed } = useStore(ui);
  const [search, setSearch] = useState(''), [filter, setFilter] = useState('all');
  const [createOpen, setCreateOpen] = useState(false), [createTitle, setCreateTitle] = useState(''), [busyCreate, setBusyCreate] = useState(false);
  const [error, setError] = useState<unknown>();
  const [eventsState, setEventsState] = useState('正在同步');
  const rooms = useQuery({ queryKey: ['rooms'], queryFn: ({ signal }) => client.rooms(signal), refetchInterval: client.capabilities.liveEvents ? false : 5000 });
  const transport = useRongCloud(client, () => { void cache.invalidateQueries({ queryKey: ['rooms'] }); void cache.invalidateQueries({ queryKey: ['messages'] }); });
  const selected = rooms.data?.rooms.find(r => r.id === roomId);
  useEffect(() => { if (roomId && rooms.isSuccess && !selected) ui.setState({ roomId: undefined }); }, [selected, roomId, rooms.isSuccess]);
  useEffect(() => {
    if (!client.capabilities.liveEvents || !rooms.data) return;
    const controller = new AbortController(); let cursor = rooms.data.cursor;
    async function poll() { while (!controller.signal.aborted) { try { const page = await client.events(cursor, controller.signal); if (controller.signal.aborted) return; cursor = page.cursor; setEventsState('已同步'); if (page.changed || page.resetRequired) { await Promise.all([cache.invalidateQueries({ queryKey: ['rooms'] }), cache.invalidateQueries({ queryKey: ['messages'] }), cache.invalidateQueries({ queryKey: ['members'] })]); } } catch (e) { if (controller.signal.aborted) return; if (e instanceof ApiError && e.status === 401) { onLogout(); return; } setEventsState('连接中断 · 正在重试'); await new Promise<void>(resolve => { const timer = setTimeout(resolve, 3000); controller.signal.addEventListener('abort', () => { clearTimeout(timer); resolve(); }, { once: true }); }); } } }
    void poll(); return () => controller.abort();
  }, [client, Boolean(rooms.data)]);
  const openRoom = (id: string) => { ui.setState({ nav: 'messages', roomId: id }); };
  const filtered = (rooms.data?.rooms ?? []).filter(r => r.title.toLocaleLowerCase().includes(search.trim().toLocaleLowerCase()) && (filter !== 'unread' || (r.unread ?? 0) > 0));
  async function preference(r: Room, values: { pinned?: boolean; muted?: boolean }) { setError(undefined); try { await client.preferences(r.id, values); await cache.invalidateQueries({ queryKey: ['rooms'] }); } catch (e) { setError(e); } }
  async function create(e: FormEvent) { e.preventDefault(); if (!createTitle.trim() || busyCreate) return; setBusyCreate(true); setError(undefined); try { const r = await client.createRoom(createTitle.trim()); await cache.invalidateQueries({ queryKey: ['rooms'] }); openRoom(r.id); setCreateOpen(false); setCreateTitle(''); } catch (e) { setError(e); } finally { setBusyCreate(false); } }
  return <main className={`workspace ${collapsed ? 'collapsed' : ''}`}>
    <nav className="sidebar" aria-label="主导航"><div className="account-row"><Menu.Root><Menu.Trigger className="profile-trigger" aria-label="我的与设置"><Avatar name={label(me)} agent={me.kind === 'agent'} />{!collapsed && <span><strong>人机</strong><small>{label(me)}</small></span>}</Menu.Trigger><Menu.Portal><Menu.Content className="popup" sideOffset={8}><div className="profile-summary"><strong>{label(me)}</strong><span>{me.kind === 'agent' ? 'Agent 同事' : '人类同事'}</span></div><Menu.Item onSelect={onLogout}><LogOut />退出登录</Menu.Item></Menu.Content></Menu.Portal></Menu.Root>
      {!collapsed && <QuickMenu canCreate={client.capabilities.createRoom} onCreate={() => setCreateOpen(true)} onAgents={() => ui.setState({ nav: 'agents' })} agents={client.capabilities.directory} />}</div>
      {!collapsed && <div className="sidebar-search"><Search size={17} /><input aria-label="搜索会话" placeholder="搜索会话" value={search} onChange={e => { setSearch(e.target.value); ui.setState({ nav: 'messages' }); }} /></div>}
      <button className={`nav-item ${nav === 'messages' ? 'selected' : ''}`} onClick={() => ui.setState({ nav: 'messages' })}><MessageCircle /><span>消息</span></button>
      <button className={`nav-item ${nav === 'agents' ? 'selected' : ''}`} disabled={!client.capabilities.directory} title={!client.capabilities.directory ? '当前服务尚未开放同事目录' : undefined} onClick={() => ui.setState({ nav: 'agents' })}><Sparkles /><span>Agent 同事</span></button>
      <button className={`nav-item ${nav === 'docs' ? 'selected' : ''}`} disabled={!client.capabilities.documents} title={!client.capabilities.documents ? '文档网关尚未开放' : undefined} onClick={() => ui.setState({ nav: 'docs' })}><FolderClosed /><span>云文档</span></button>
      <div className="sidebar-bottom"><button className="nav-item" onClick={() => ui.setState({ collapsed: !collapsed })} title={collapsed ? '展开导航栏' : '收起导航栏'}><MenuIcon /><span>收起导航栏</span></button><div className="connection" title={client.endpoint}><i className={client.mode === 'startup' && transport.state !== 'connected' ? 'pending' : ''} />{!collapsed && <span>{client.mode === 'legacy' ? `迁移模式 · ${eventsState}` : transport.label}</span>}</div></div>
    </nav>
    {nav === 'messages' ? <><aside className="room-list"><header className="panel-header"><h1>消息</h1><QuickMenu canCreate={client.capabilities.createRoom} onCreate={() => setCreateOpen(true)} onAgents={() => ui.setState({ nav: 'agents' })} agents={client.capabilities.directory} /></header>
      {(rooms.data?.rooms.some(r => r.pinned)) && <div className="pinned-shelf" aria-label="置顶会话">{rooms.data.rooms.filter(r => r.pinned).map(r => <button key={r.id} onClick={() => openRoom(r.id)} title={r.title}><Avatar name={r.title} room /><span>{r.title}</span></button>)}</div>}
      <div className="filters"><button className={filter === 'all' ? 'active' : ''} onClick={() => setFilter('all')}>全部</button><button disabled={client.mode === 'startup'} className={filter === 'unread' ? 'active' : ''} onClick={() => setFilter('unread')}>未读</button><button onClick={() => { void rooms.refetch(); }} aria-label="刷新会话"><RefreshCw size={15} /></button></div>
      <Status error={rooms.error || error} />{rooms.isPending ? <p className="empty">正在读取会话…</p> : filtered.length === 0 ? <p className="empty">{search ? '没有匹配的会话' : '当前工作身份还没有会话'}</p> : <div className="room-scroll">{filtered.map(r => <ConversationRow key={r.id} room={r} selected={r.id === roomId} onOpen={() => openRoom(r.id)} preferences={client.capabilities.roomPreferences ? value => { void preference(r, value); } : undefined} />)}</div>}
    </aside><section className="main-panel">{selected ? <Conversation key={selected.id} client={client} me={me} room={selected} /> : <div className="welcome"><Rocket size={50} /><h2>开始一段协作</h2><p>选择一个会话，查看消息并与同事交流。</p>{client.mode === 'startup' && <p className="subtle">当前使用企业身份与正式消息服务。</p>}</div>}</section></> : nav === 'agents' ? <Directory client={client} onOpen={openRoom} /> : <Documents client={client} onOpen={openRoom} />}
    <Dialog.Root open={createOpen} onOpenChange={setCreateOpen}><Dialog.Portal><Dialog.Overlay className="dialog-overlay" /><Dialog.Content className="dialog-content"><Dialog.Title>创建群聊</Dialog.Title><Dialog.Description>群创建后，可以在现有客户端管理人和 Agent 成员。</Dialog.Description><form onSubmit={create}><label>群聊名称<input autoFocus required maxLength={100} value={createTitle} onChange={e => setCreateTitle(e.target.value)} /></label><Status error={error} /><footer><Dialog.Close className="secondary">取消</Dialog.Close><button className="primary" disabled={busyCreate}>{busyCreate ? '正在创建…' : '创建'}</button></footer></form></Dialog.Content></Dialog.Portal></Dialog.Root>
  </main>;
}

function QuickMenu({ canCreate, agents, onCreate, onAgents }: { canCreate: boolean; agents: boolean; onCreate: () => void; onAgents: () => void }) {
  return <Menu.Root><Menu.Trigger className="icon-button" aria-label="新建与添加"><Plus size={22} /></Menu.Trigger><Menu.Portal><Menu.Content className="popup quick-menu" align="end" sideOffset={8}><Menu.Item disabled={!canCreate} onSelect={onCreate}><MessageCircle />创建群聊</Menu.Item><Menu.Item disabled={!agents} onSelect={onAgents}><Sparkles />查找 Agent 同事</Menu.Item></Menu.Content></Menu.Portal></Menu.Root>;
}
function time(value?: string) { if (!value) return ''; const d = new Date(value); if (!Number.isFinite(d.getTime())) return ''; const now = new Date(); return d.toDateString() === now.toDateString() ? d.toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit', hour12: false }) : d.toLocaleDateString('zh-CN', { month: 'numeric', day: 'numeric' }); }

export function ConversationRow({ room, selected, onOpen, preferences }: { room: Room; selected: boolean; onOpen: () => void; preferences?: (values: { pinned?: boolean; muted?: boolean }) => void }) {
  const [context, setContext] = useState(false);
  return <Menu.Root open={context} onOpenChange={setContext}><Menu.Trigger asChild><button className={`room-row ${selected ? 'selected' : ''}`} onPointerDown={event => { if (event.button === 0) event.preventDefault(); }} onKeyDown={event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); onOpen(); } }} onClick={event => { event.preventDefault(); onOpen(); }} onContextMenu={event => { if (preferences) { event.preventDefault(); setContext(true); } }} aria-label={room.title}>
    <div className="room-avatar-wrap"><Avatar name={room.title} room={room.kind !== 'direct'} />{(room.unread ?? 0) > 0 && <span className={`badge ${room.muted ? 'muted' : ''}`}>{room.unread! > 99 ? '99+' : room.unread}</span>}</div><div className="room-copy"><div><strong>{room.title}</strong><time>{time(room.lastMessage?.createdAt)}</time></div><div><p>{room.lastMessage ? room.lastMessage.retracted ? '消息已撤回' : room.lastMessage.isVoice ? '[语音]' : room.lastMessage.content || '[附件]' : '暂无消息'}</p><span className="row-flags">{room.muted && <BellOff size={13} />}{room.pinned && <Pin size={13} />}</span></div></div>
  </button></Menu.Trigger>{preferences && <Menu.Portal><Menu.Content className="popup" align="end" sideOffset={-20}><Menu.Item onSelect={() => preferences({ pinned: !room.pinned })}><Pin />{room.pinned ? '取消置顶' : '置顶'}</Menu.Item><Menu.Item onSelect={() => preferences({ muted: !room.muted })}><BellOff />{room.muted ? '取消免打扰' : '消息免打扰'}</Menu.Item><Menu.Item onSelect={onOpen}><Sparkles />进入协作会话</Menu.Item></Menu.Content></Menu.Portal>}</Menu.Root>;
}

export function mergeMessagePages(pages: { messages: Message[] }[]): Message[] {
  const map = new Map<string, Message>();
  for (const page of [...pages].reverse()) for (const message of page.messages) map.set(message.id, message);
  return [...map.values()].sort((a, b) => a.seq - b.seq);
}

export function Conversation({ client, me, room }: { client: CollaborationClient; me: Principal; room: Room }) {
  const cache = useQueryClient();
  const [draft, setDraft] = useState(''), [sending, setSending] = useState(false), [sendError, setSendError] = useState<unknown>();
  const [mentionOpen, setMentionOpen] = useState(false), [agentOnly, setAgentOnly] = useState(false), [mentionIds, setMentionIds] = useState<string[]>([]);
  const pendingIntent = useRef<{ key: string; intent: SendIntent } | undefined>(undefined);
  const pane = useRef<HTMLDivElement>(null), input = useRef<HTMLTextAreaElement>(null), alive = useRef(true), composing = useRef(false), anchored = useRef(false);
  useEffect(() => { alive.current = true; return () => { alive.current = false; }; }, []);
  const query = useInfiniteQuery({ queryKey: ['messages', room.id], initialPageParam: undefined as number | undefined, queryFn: ({ signal, pageParam }) => client.messages(room.id, { before: pageParam, firstUnread: pageParam === undefined && (room.unread ?? 0) > 0, signal }), getNextPageParam: page => page.hasMoreBefore && page.messages.length ? page.messages[0].seq : undefined, refetchInterval: client.mode === 'startup' ? 5000 : false });
  const members = useQuery({ queryKey: ['members', room.id], queryFn: ({ signal }) => client.members(room.id, signal), enabled: client.capabilities.mentions });
  const messages = mergeMessagePages(query.data?.pages ?? []);
  useEffect(() => {
    if (anchored.current || !messages.length || !pane.current) return;
    const first = room.firstUnreadSeq || query.data?.pages[0].firstUnreadSeq;
    const node = first ? pane.current.querySelector<HTMLElement>(`[data-seq="${first}"]`) : undefined;
    if (node) node.scrollIntoView({ block: 'start' }); else pane.current.scrollTop = pane.current.scrollHeight;
    anchored.current = true;
  }, [messages.length, room.firstUnreadSeq]);
  async function send() {
    const content = draft.trim(); if (!content || sending || room.stopped || composing.current) return;
    const key = JSON.stringify([room.id, content, mentionIds]);
    if (pendingIntent.current?.key !== key) pendingIntent.current = { key, intent: { actionId: crypto.randomUUID(), content, mentions: [...mentionIds], scopeEpoch: room.scopeEpoch } };
    const intent = pendingIntent.current.intent;
    setSending(true); setSendError(undefined);
    try { const sent = await client.send(room.id, intent); if (!alive.current) return;
      // A successful write is final even if the subsequent refresh fails.
      setDraft(''); setMentionIds([]); pendingIntent.current = undefined;
      cache.setQueryData<{ pages: { messages: Message[]; hasMoreBefore: boolean; hasMoreAfter: boolean }[]; pageParams: unknown[] }>(['messages', room.id], old => old ? { ...old, pages: old.pages.map((p, i) => i === 0 ? { ...p, messages: [...p.messages.filter(m => m.id !== sent.id), sent] } : p) } : { pages: [{ messages: [sent], hasMoreBefore: false, hasMoreAfter: false }], pageParams: [undefined] });
      void cache.invalidateQueries({ queryKey: ['rooms'] }); void cache.invalidateQueries({ queryKey: ['messages', room.id] });
      requestAnimationFrame(() => { if (pane.current) pane.current.scrollTop = pane.current.scrollHeight; });
    } catch (e) { if (alive.current) setSendError(e); } finally { if (alive.current) setSending(false); }
  }
  const candidates = (members.data ?? []).filter(p => p.id !== me.id && (!agentOnly || p.kind === 'agent'));
  const addMention = (p: Principal) => { setMentionIds(ids => [...new Set([...ids, p.id])]); setDraft(d => `${d}${d && !/\s$/.test(d) ? ' ' : ''}@${label(p)} `); setMentionOpen(false); input.current?.focus(); };
  return <><header className="conversation-header"><div><h2>{room.title}</h2><span>{members.data ? `${members.data.length} 位同事` : room.kind === 'direct' ? '单聊' : '群聊'}{room.stopped ? ' · 主动执行已停止' : ''}</span></div><button className="icon-button" onClick={() => { void query.refetch(); }} aria-label="刷新消息"><RefreshCw size={19} /></button></header>
    <div className="conversation-tabs"><span className="active">消息</span></div>
    <div className="messages-pane" ref={pane}><Status error={query.error} />{query.hasNextPage && <button className="load-history" disabled={query.isFetchingNextPage} onClick={() => { void query.fetchNextPage(); }}>{query.isFetchingNextPage ? '正在加载…' : '查看更早消息'}</button>}{query.isPending && <p className="empty">正在读取消息…</p>}{!query.isPending && !messages.length && <p className="empty">还没有消息，开始协作吧</p>}
      {messages.map(m => <div key={m.id} className={`message-row ${m.authorId === me.id ? 'mine' : ''}`} data-seq={m.seq}><Avatar name={m.authorName || (m.authorId === me.id ? label(me) : m.authorId)} agent={m.authorKind === 'agent' || (m.authorId === me.id && me.kind === 'agent')} small /><div className="message-main"><div className="message-author">{m.authorName || (m.authorId === me.id ? label(me) : m.authorId)} <time title={m.createdAt}>{time(m.createdAt)}</time></div><div className={`bubble ${m.retracted ? 'retracted' : ''}`}>{m.retracted ? '这条消息已撤回' : m.isVoice ? '[语音消息 · 请在移动客户端播放]' : m.content || `[${m.attachmentCount || 1} 个附件]`}</div>{m.authorId === me.id && m.receipt && <span className="read-receipt">{m.receipt.read === m.receipt.total ? <CheckCheck size={12} /> : <Check size={12} />}{m.receipt.read}/{m.receipt.total} 已读</span>}<div className="message-hover" aria-label="消息操作"><button title="复制消息" onClick={() => { void navigator.clipboard.writeText(m.content); }}><FileText size={16} /></button><button disabled={!client.capabilities.mentions} title="请 Agent 协作" onClick={() => { setAgentOnly(true); setMentionOpen(true); }}><Sparkles size={16} /></button></div></div></div>)}
    </div><div className="composer"><div className="composer-tools"><button className="icon-button" disabled={!client.capabilities.mentions} title="@ 人或 Agent" onClick={() => { setAgentOnly(false); setMentionOpen(!mentionOpen); }}><AtSign size={21} /></button><button className="icon-button agent-entry" disabled={!client.capabilities.mentions} title="Agent 超级入口" onClick={() => { setAgentOnly(true); setMentionOpen(!mentionOpen || !agentOnly); }}><Sparkles size={21} /></button><span className="composer-hint">Enter 发送 · Shift + Enter 换行</span></div>
      {mentionOpen && <div className="mention-panel"><header><strong>{agentOnly ? '选择 Agent 同事' : '@ 人或 Agent'}</strong><button className="icon-button" onClick={() => setMentionOpen(false)} aria-label="关闭"><X size={16} /></button></header>{members.isPending ? <p>正在读取成员…</p> : candidates.length ? candidates.map(p => <button key={p.id} onClick={() => addMention(p)}><Avatar name={label(p)} agent={p.kind === 'agent'} small /><span>{label(p)}</span><small>{p.kind === 'agent' ? 'Agent' : '人'}</small></button>) : <p>当前会话没有符合条件的成员</p>}<Status error={members.error} /></div>}
      <textarea ref={input} aria-label="消息内容" placeholder={room.stopped ? '此群的执行范围已暂停' : `发送给 ${room.title}`} value={draft} disabled={sending || room.stopped} onChange={e => setDraft(e.target.value)} onCompositionStart={() => { composing.current = true; }} onCompositionEnd={() => { composing.current = false; }} onKeyDown={e => { if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing && !composing.current && e.keyCode !== 229) { e.preventDefault(); void send(); } }} />
      {mentionIds.length > 0 && <div className="mention-chips">{mentionIds.map(id => <button key={id} onClick={() => setMentionIds(ids => ids.filter(p => p !== id))}>@{members.data?.find(p => p.id === id)?.displayName || id}<X size={12} /></button>)}</div>}
      <div className="composer-footer"><Status error={sendError} /><button className="send-button" disabled={!draft.trim() || sending || room.stopped} onClick={() => { void send(); }}><Send size={16} />{sending ? '发送中' : sendError ? '重试发送' : '发送'}</button></div>
    </div></>;
}

function Directory({ client, onOpen }: { client: CollaborationClient; onOpen: (id: string) => void }) {
  const cache = useQueryClient(), query = useQuery({ queryKey: ['people'], queryFn: ({ signal }) => client.people(signal) });
  const [search, setSearch] = useState(''), [organization, setOrganization] = useState(''), [busy, setBusy] = useState<string>(), [error, setError] = useState<unknown>();
  const agents = query.data?.filter(p => p.kind === 'agent') ?? [];
  const groups = [...new Set(agents.map(p => p.organization || '未分配组织'))].sort();
  async function open(p: Principal) { if (busy) return; setBusy(p.id); setError(undefined); try { const r = await client.direct(p.id); await cache.invalidateQueries({ queryKey: ['rooms'] }); onOpen(r.id); } catch (e) { setError(e); } finally { setBusy(undefined); } }
  return <section className="directory"><header className="panel-header"><h1>Agent 同事</h1><span>{agents.length} 位</span></header><div className="directory-body"><aside className="directory-tree"><h3>组织</h3><button className={!organization ? 'active' : ''} onClick={() => setOrganization('')}>全部组织</button>{groups.map(name => <button key={name} className={name === organization ? 'active' : ''} onClick={() => setOrganization(name)}><Users size={16} />{name}</button>)}</aside><div className="directory-results"><div className="sidebar-search"><Search size={17} /><input value={search} onChange={e => setSearch(e.target.value)} placeholder="搜索姓名、职业、分类" /></div><Status error={query.error || error} />{query.isPending && <p>正在读取同事…</p>}{agents.filter(p => (!organization || (p.organization || '未分配组织') === organization) && [p.displayName, p.profession, p.category].join(' ').toLocaleLowerCase().includes(search.toLocaleLowerCase())).map(p => <button className="person-card" key={p.id} disabled={Boolean(busy)} onClick={() => { void open(p); }}><Avatar name={label(p)} agent /><span><strong>{label(p)}</strong><small>{[p.profession, p.organization].filter(Boolean).join(' · ') || 'Agent 同事'}</small></span>{busy === p.id ? <LoaderCircle size={18} /> : <MessageCircle size={18} />}</button>)}</div></div></section>;
}

function Documents({ client, onOpen }: { client: CollaborationClient; onOpen: (id: string) => void }) {
  const query = useQuery({ queryKey: ['documents'], queryFn: ({ signal }) => client.documents(signal) });
  return <section className="directory"><header className="panel-header"><h1>云文档</h1><button className="icon-button" onClick={() => { void query.refetch(); }} aria-label="刷新文档"><RefreshCw size={18} /></button></header><div className="document-results"><p className="subtle">当前可访问的协作文档。打开所属会话查看协作上下文；编辑能力继续在现有客户端使用。</p><Status error={query.error} />{query.isPending ? <p>正在读取文档…</p> : query.data?.length ? query.data.map(d => <button className="document-row" key={`${d.roomId}:${d.id}`} disabled={!d.roomId} onClick={() => onOpen(d.roomId)}><FileText /><strong>{d.title}</strong><span>{d.revision ? `版本 ${d.revision}` : ''}</span><time>{time(d.updatedAt)}</time></button>) : <p className="empty">暂无可访问的文档</p>}</div></section>;
}
