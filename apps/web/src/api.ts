import type { Capabilities, CollaborationClient, Document, DocumentContent, EmojiPage, EventPage, Message, MessagePage, Principal, Room, RoomPage, SendIntent, ReactionIntent, ReactionReceipt, ReactionPage, ReactionSummary, ReplySummary, OnboardingClient, Profile, ProfileIntent, WorkspaceInfo, WorkspaceIntent, WorkspaceMember, RoomIntent, RoomPreview, WorkspaceInvitation, InvitationCreateIntent, InvitationRevokeIntent, InvitationAcceptIntent, InvitationReceipt, InvitationAcceptance, InvitationAction, WorkspaceInvitationClient } from './types';

type Json = Record<string, unknown>;
const uuid = (value: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
export const validProfileName = (value: string) => { const name = value.trim(); return [...name].length > 0 && [...name].length <= 80 && !/[\p{Cc}\p{Cf}\p{Cs}\u2028\u2029]/u.test(name); };
export const validInvitationCode = (value: string) => /^rji_[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$/.test(value.trim());
export const validWorkspaceTitle = (value: string) => value.trim().length > 0 && new TextEncoder().encode(value.trim()).length <= 240 && !/[\p{Cc}\p{Cf}\p{Cs}\u2028\u2029]/u.test(value.trim());
const object = (value: unknown): Json => value && typeof value === 'object' && !Array.isArray(value) ? value as Json : {};
const list = (value: unknown): Json[] => Array.isArray(value) ? value.map(object) : [];
const text = (value: unknown, fallback = '') => typeof value === 'string' ? value : fallback;
const number = (value: unknown, fallback = 0) => typeof value === 'number' && Number.isFinite(value) ? value : fallback;
const timestamp = (value: unknown) => {
  const date = typeof value === 'number' || typeof value === 'string' ? new Date(value) : null;
  return date && Number.isFinite(date.getTime()) ? typeof value === 'string' ? value : date.toISOString() : '';
};
function workspaceInfo(value: Json, full = false): WorkspaceInfo {
  if (!uuid(text(value.id)) || typeof value.title !== 'string' || !validWorkspaceTitle(value.title) || full && (!['owner', 'admin', 'member'].includes(text(value.role)) || !timestamp(value.created_at))) throw new ApiError(502, 'invalid_workspace');
  return { id: text(value.id), title: value.title, ...(full ? { role: text(value.role), createdAt: timestamp(value.created_at) } : {}) };
}
function memberInfo(value: Json): WorkspaceMember {
  if (!uuid(text(value.principal_id)) || !['human', 'agent'].includes(text(value.kind)) || typeof value.display_name !== 'string' || !['owner', 'admin', 'member'].includes(text(value.role))) throw new ApiError(502, 'invalid_member');
  return { ...principal(value), role: text(value.role) };
}

export class ApiError extends Error {
  constructor(readonly status: number, readonly code: string) {
    super(({ 401: '登录已失效，请重新登录', 403: '当前身份没有这项权限', 404: '内容不存在或已不可访问', 409: '内容或授权范围已变化，请刷新后重试', 429: '请求频繁，请稍后重试', 503: '服务暂时不可用，请稍后重试' } as Record<number, string>)[status] ?? '请求未完成，请检查服务连接');
    this.name = 'ApiError';
  }
}
export function errorMessage(error: unknown): string {
  if (error instanceof ApiError) return error.message;
  if (error instanceof DOMException && error.name === 'AbortError') return '操作已取消';
  if (error instanceof DOMException && error.name === 'TimeoutError') return '请求超时，请重试（client_timeout）';
  // Classify known browser failures without displaying/logging raw messages,
  // request URLs, credentials or server response payloads.
  if (error instanceof TypeError && /Illegal invocation/i.test(error.message)) return '客户端网络调用异常，请重新加载页面（client_fetch_binding）';
  if (error instanceof SyntaxError) return '服务返回格式异常，请重试（client_response_format）';
  return '连接未完成，请检查服务地址和网络（client_network）';
}

export function normalizeEndpoint(value: string): string {
  const url = new URL(value.trim());
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) throw new ApiError(422, 'invalid_endpoint');
  if (url.protocol !== 'https:' && !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)) throw new ApiError(422, 'insecure_endpoint');
  return url.href.replace(/\/+$/, '');
}

export function principal(value: unknown): Principal {
  const p = object(value);
  if (!text(p.id) && !text(p.principal_id)) throw new ApiError(502, 'invalid_principal');
  return { id: text(p.id, text(p.principal_id)), kind: p.kind === 'agent' ? 'agent' : 'human', displayName: text(p.display_name, text(p.name, '未命名成员')), organization: text(p.organization_name), profession: text(p.profession), category: text(p.category_name) };
}
export function message(value: unknown, roomId = ''): Message {
  const m = object(value), author = object(m.author), receipt = object(m.receipt_summary);
  if (!text(m.id) || !Number.isSafeInteger(m.seq) || number(m.seq) < 0) throw new ApiError(502, 'invalid_message');
  if (roomId && m.room_id !== undefined && m.room_id !== roomId) throw new ApiError(502, 'invalid_message_room');
  const unavailable = Boolean(m.retracted_at) || m.hidden === true;
  const reactions: Record<string, string[]> = {};
  for (const [id, users] of Object.entries(object(m.reactions))) {
    if (!Array.isArray(users) || users.some(user => typeof user !== 'string' || !user)) throw new ApiError(502, 'invalid_reactions');
    if (!unavailable && users.length) Object.defineProperty(reactions, id, { value: [...new Set(users)], enumerable: true });
  }
  let reply: ReplySummary | undefined;
  if (!unavailable && m.reply !== undefined) {
    const q = object(m.reply);
    if (!text(m.reply_to) || q.message_id !== m.reply_to || q.room_id !== text(m.room_id, roomId) || !text(q.author_id) || typeof q.author_name !== 'string' || !['human', 'agent'].includes(text(q.author_kind)) || typeof q.excerpt !== 'string' || [...q.excerpt].length > 240 || !Number.isSafeInteger(q.seq) || number(q.seq) < 1 || number(q.seq) >= number(m.seq)) throw new ApiError(502, 'invalid_reply_summary');
    reply = { messageId: text(q.message_id), roomId: text(q.room_id), authorId: text(q.author_id), authorName: text(q.author_name), authorKind: q.author_kind as 'human' | 'agent', excerpt: text(q.excerpt), seq: number(q.seq) };
  }
  const summaries = !unavailable && Array.isArray(m.reactions) ? reactionSummaries(m.reactions, 20) : undefined;
  if (m.reaction_version !== undefined && (!Number.isSafeInteger(m.reaction_version) || number(m.reaction_version, -1) < 0) || m.reactions_has_more !== undefined && typeof m.reactions_has_more !== 'boolean') throw new ApiError(502, 'invalid_reaction_version');
  return { reply, reactionSummaries: summaries, reactionVersion: number(m.reaction_version), reactionsHasMore: !unavailable && m.reactions_has_more === true, id: text(m.id), roomId: text(m.room_id, roomId), authorId: text(m.author_id), authorName: text(author.display_name, text(author.name)), authorKind: text(author.kind), content: unavailable ? '' : text(m.content), seq: number(m.seq), createdAt: timestamp(m.created_at ?? m.at), retracted: Boolean(m.retracted_at), hidden: m.hidden === true, replyTo: unavailable ? undefined : text(m.reply_to) || undefined, reactions, mentions: unavailable ? [] : Array.isArray(m.mentions) ? m.mentions.filter((id): id is string => typeof id === 'string') : [], isVoice: !unavailable && Boolean(m.voice), attachmentCount: !unavailable && Array.isArray(m.attachments) ? m.attachments.length : 0, receipt: receipt.known === true && typeof receipt.read_count === 'number' && typeof receipt.eligible_count === 'number' ? { read: receipt.read_count, total: receipt.eligible_count } : undefined };
}
function reactionSummaries(value: unknown, limit: number): ReactionSummary[] {
  if (!Array.isArray(value) || value.length > limit) throw new ApiError(502, 'invalid_reactions');
  const summaries = value.map(item => { const s = object(item); if (!text(s.emoji) || !Number.isSafeInteger(s.count) || number(s.count, -1) < 1 || typeof s.selected !== 'boolean') throw new ApiError(502, 'invalid_reactions'); return { emoji: text(s.emoji), count: number(s.count), selected: s.selected }; });
  if (new Set(summaries.map(s => s.emoji)).size !== summaries.length) throw new ApiError(502, 'invalid_reactions');
  return summaries;
}
export function room(value: unknown): Room {
  const r = object(value);
  if (!text(r.id)) throw new ApiError(502, 'invalid_room');
  return { id: text(r.id), ...(typeof r.workspace_id === 'string' ? { workspaceId: r.workspace_id } : {}), title: text(r.title, text(r.name, '未命名会话')), kind: text(r.kind, 'group'), version: number(r.version, number(r.revision, 1)), scopeEpoch: typeof r.scope_epoch === 'number' ? r.scope_epoch : undefined, stopped: typeof r.stopped === 'boolean' ? r.stopped : undefined, unread: typeof r.unread_count === 'number' ? r.unread_count : undefined, pinned: typeof r.is_pinned === 'boolean' ? r.is_pinned : undefined, muted: typeof r.muted === 'boolean' ? r.muted : undefined, firstUnreadSeq: typeof r.first_unread_seq === 'number' ? r.first_unread_seq : undefined, lastMessage: r.last_message ? message(r.last_message, text(r.id)) : undefined };
}

function roomPreview(value: unknown, roomId: string): RoomPreview | null | undefined {
  if (value === undefined || value === null) return value;
  const p = object(value);
  if (!uuid(text(p.id)) || p.room_id !== roomId || !uuid(text(p.author_id)) || typeof p.author_name !== 'string' || !['human', 'agent'].includes(text(p.author_kind)) || typeof p.excerpt !== 'string' || [...p.excerpt].length > 240 || !Number.isSafeInteger(p.seq) || number(p.seq) < 1 || typeof p.created_at !== 'string' || !timestamp(p.created_at) || p.content_kind !== 'text') throw new ApiError(502, 'invalid_room_preview');
  return { id: text(p.id), roomId, authorId: text(p.author_id), authorName: p.author_name, authorKind: p.author_kind as 'human' | 'agent', excerpt: p.excerpt, seq: number(p.seq), createdAt: p.created_at, contentKind: 'text' };
}
function invitation(value: unknown, workspaceId?: string): WorkspaceInvitation {
  const i = object(value);
  if (!uuid(text(i.id)) || !uuid(text(i.workspace_id)) || workspaceId && i.workspace_id !== workspaceId || !uuid(text(i.created_by)) || !text(i.create_action_id) || i.role !== 'member' || !['pending', 'accepted', 'revoked', 'expired'].includes(text(i.status)) || !timestamp(i.created_at) || !timestamp(i.expires_at) || new Date(text(i.expires_at)).getTime() <= new Date(text(i.created_at)).getTime() || i.accepted_by !== undefined && !uuid(text(i.accepted_by)) || i.accepted_at !== undefined && !timestamp(i.accepted_at) || i.revoked_at !== undefined && !timestamp(i.revoked_at)) throw new ApiError(502, 'invalid_invitation');
  return { id: text(i.id), workspaceId: text(i.workspace_id), createdBy: text(i.created_by), createActionId: text(i.create_action_id), role: 'member', status: i.status as WorkspaceInvitation['status'], createdAt: timestamp(i.created_at), expiresAt: timestamp(i.expires_at), ...(i.accepted_by ? { acceptedBy: text(i.accepted_by) } : {}), ...(i.accepted_at ? { acceptedAt: timestamp(i.accepted_at) } : {}), ...(i.revoked_at ? { revokedAt: timestamp(i.revoked_at) } : {}) };
}

/** An adapter is retired permanently on identity change, including A → B → A. */
abstract class HttpClient implements CollaborationClient {
  abstract readonly mode: 'startup' | 'legacy';
  abstract readonly capabilities: Capabilities;
  protected readonly lifecycle = new AbortController();
  readonly endpoint: string;
  protected readonly fetcher: typeof fetch;
  constructor(endpoint: string, protected token: () => Promise<string | null>, fetcher: typeof fetch = fetch) {
    this.endpoint = normalizeEndpoint(endpoint);
    // Window.fetch is a WebIDL method; a class member call otherwise gives it
    // this HttpClient as receiver and Chromium rejects it as Illegal invocation.
    this.fetcher = fetcher.bind(globalThis);
  }
  protected abstract get prefix(): string;
  protected requestURL(path: string): string { return `${this.endpoint}${this.prefix}${path}`; }
  async request(path: string, method = 'GET', body?: Json, signal?: AbortSignal): Promise<Json> {
    const combined = AbortSignal.any([this.lifecycle.signal, AbortSignal.timeout(30000), ...(signal ? [signal] : [])]);
    combined.throwIfAborted();
    const bearer = await this.token();
    combined.throwIfAborted();
    if (!bearer) throw new ApiError(401, 'missing_session');
    const response = await this.fetcher(this.requestURL(path), { method, redirect: 'error', cache: 'no-store', credentials: 'omit', headers: { Authorization: `Bearer ${bearer}`, Accept: 'application/json', ...(body ? { 'Content-Type': 'application/json' } : {}) }, body: body ? JSON.stringify(body) : undefined, signal: combined });
    const result = await response.json().catch(() => ({}));
    combined.throwIfAborted();
    if (!response.ok) {
      const json = object(result), nested = object(json.error);
      // Go uses {error: code}; the migration service can use {error:{code}}.
      const code = text(json.code, text(nested.code, text(json.error, 'request_failed')));
      throw new ApiError(response.status, /^[a-z][a-z0-9_]{0,95}$/.test(code) ? code : 'request_failed');
    }
    return object(result);
  }
  async me(signal?: AbortSignal): Promise<Principal> { return principal((await this.request('/me', 'GET', undefined, signal)).principal); }
  async rooms(signal?: AbortSignal): Promise<RoomPage> { const r = await this.request('/rooms', 'GET', undefined, signal); return { rooms: list(r.rooms).map(room), cursor: number(r.cursor) }; }
  async messages(roomId: string, options: { before?: number; firstUnread?: boolean; signal?: AbortSignal } = {}): Promise<MessagePage> {
    const params = new URLSearchParams({ limit: '100' });
    if (options.before !== undefined || this.mode === 'startup') params.set('before', String(options.before ?? 0));
    if (options.firstUnread && this.mode === 'legacy') params.set('first_unread', 'true');
    const r = await this.request(`/rooms/${encodeURIComponent(roomId)}/messages?${params}`, 'GET', undefined, options.signal);
    const messages = list(r.messages).map(m => message(m, roomId));
    if (this.mode === 'startup' && (!Array.isArray(r.messages) || messages.length > 100 || r.direction !== 'before' || typeof r.has_more_before !== 'boolean' || r.has_more !== r.has_more_before || r.cursor !== (messages[0]?.seq ?? 0) || messages.some((m, i) => object((r.messages as unknown[])[i]).room_id !== roomId || m.seq < 1 || i > 0 && m.seq <= messages[i - 1].seq || options.before !== undefined && options.before > 0 && m.seq >= options.before) || new Set(messages.map(m => m.id)).size !== messages.length || r.has_more_before && messages.length === 0)) throw new ApiError(502, 'invalid_message_page');
    return { messages: messages.sort((a, b) => a.seq - b.seq), hasMoreBefore: r.has_more_before === true, hasMoreAfter: r.has_more_after === true, firstUnreadSeq: typeof r.anchor_seq === 'number' ? r.anchor_seq : undefined };
  }
  abstract send(roomId: string, intent: SendIntent, signal?: AbortSignal): Promise<Message>;
  async react(_roomId: string, _messageId: string, _emojiId: string, _signal?: AbortSignal): Promise<Message> { return this.unsupported(); }
  async emoji(_options: { query?: string; category?: string; offset?: number; signal?: AbortSignal } = {}): Promise<EmojiPage> { return this.unsupported(); }
  protected unsupported(): never { throw new ApiError(501, 'capability_unavailable'); }
  async people(_signal?: AbortSignal): Promise<Principal[]> { return this.unsupported(); }
  async members(_roomId: string, _signal?: AbortSignal): Promise<Principal[]> { return this.unsupported(); }
  async preferences(_roomId: string, _values: { pinned?: boolean; muted?: boolean; read_seq?: number }, _signal?: AbortSignal): Promise<void> { return this.unsupported(); }
  async createRoom(_title: string, _signal?: AbortSignal): Promise<Room> { return this.unsupported(); }
  async direct(_principalId: string, _signal?: AbortSignal): Promise<Room> { return this.unsupported(); }
  async documents(_signal?: AbortSignal): Promise<Document[]> { return this.unsupported(); }
  async document(_roomId: string, _documentId: string, _signal?: AbortSignal): Promise<DocumentContent> { return this.unsupported(); }
  async events(_after: number, _signal?: AbortSignal): Promise<EventPage> { return this.unsupported(); }
  close() { this.lifecycle.abort(); this.token = async () => null; }
}

export class StartupClient extends HttpClient implements OnboardingClient, WorkspaceInvitationClient {
  private principalId = '';
  private assets = new Map<string, string>();
  readonly mode = 'startup' as const;
  readonly capabilities: Capabilities = { directory: false, documents: false, roomPreferences: false, createRoom: false, mentions: false, liveEvents: false, readReceipts: false, reactions: false, replies: false };
  readonly onboardingCapabilities = { profileRead: false, profileUpdate: false, workspaces: false, workspaceCreate: false, workspaceMembers: false, roomMembers: false, roomCreate: false };
  get onboarding(): OnboardingClient { return this; }
  readonly invitationCapabilities = { list: false, create: false, revoke: false, accept: false, actionRead: false };
  get invitations(): WorkspaceInvitationClient { return this; }
  protected get prefix() { return '/v1'; }
  async me(signal?: AbortSignal): Promise<Principal> {
    const me = await super.me(signal);
    const registry = await this.request('/capabilities', 'GET', undefined, signal);
    if (registry.schema !== 'renji.capabilities.v1' || !Array.isArray(registry.capabilities)) throw new ApiError(502, 'invalid_capabilities');
    const supported = (id: string) => registry.capabilities instanceof Array && registry.capabilities.some(value => { const c = object(value); return c.id === id && c.version === '1' && object(c.protocols).api === true && c.available === true; });
    this.capabilities.replies = supported('message.reply');
    this.capabilities.reactions = supported('message.reaction.set') && supported('message.reaction.read') && supported('emoji.read');
    Object.assign(this.onboardingCapabilities, { profileRead: supported('profile.read'), profileUpdate: supported('profile.update'), workspaces: supported('workspace.list'), workspaceCreate: supported('workspace.create'), workspaceMembers: supported('workspace.member.list'), roomMembers: supported('room.member.list'), roomCreate: supported('room.create') });
    this.capabilities.createRoom = this.onboardingCapabilities.roomCreate && this.onboardingCapabilities.workspaces && this.onboardingCapabilities.workspaceMembers;
    Object.assign(this.invitationCapabilities, Object.fromEntries(['list', 'create', 'revoke', 'accept'].map(kind => [kind, me.kind === 'human' && supported(`workspace.invitation.${kind}`)])));
    this.invitationCapabilities.actionRead = me.kind === 'human' && supported('workspace.invitation.action.read');
    this.principalId = me.id;
    return me;
  }
  async rooms(signal?: AbortSignal): Promise<RoomPage> {
    let after = ''; const values: Room[] = []; const seen = new Set<string>();
    for (let page = 0; page < 100; page++) {
      const result = await this.request(`/rooms${after ? `?after=${after}` : ''}`, 'GET', undefined, signal);
      if (!Array.isArray(result.rooms) || result.rooms.length > 100 || typeof result.cursor !== 'string') throw new ApiError(502, 'invalid_room_page');
      for (const value of result.rooms) {
        const raw = object(value), item = room({ ...raw, last_message: undefined });
        item.preview = roomPreview(raw.last_message, item.id);
        item.previewState = item.preview === undefined ? 'unavailable' : item.preview === null ? 'empty' : 'ready';
        if (!uuid(item.id) || !uuid(text(raw.workspace_id)) || seen.has(item.id) || after && item.id <= after || values.length && item.id <= values.at(-1)!.id) throw new ApiError(502, 'invalid_room_page');
        seen.add(item.id); values.push(item);
      }
      if (!result.cursor) return { rooms: values, cursor: 0 };
      if (!uuid(result.cursor) || result.cursor !== values.at(-1)?.id || result.cursor === after) throw new ApiError(502, 'invalid_room_cursor');
      after = result.cursor;
    }
    throw new ApiError(422, 'room_directory_too_large');
  }
  private profileValue(value: Json): Profile {
    const p = object(value.principal);
    if (p.id !== this.principalId || !['human', 'agent'].includes(text(p.kind)) || typeof p.display_name !== 'string' || !Number.isSafeInteger(value.version) || number(value.version) < 1) throw new ApiError(502, 'invalid_profile');
    return { principal: principal(p), version: number(value.version) };
  }
  async profile(signal?: AbortSignal): Promise<Profile> {
    if (!this.onboardingCapabilities.profileRead) return this.unsupported();
    return this.profileValue(await this.request('/profile', 'GET', undefined, signal));
  }
  async updateProfile(intent: ProfileIntent, signal?: AbortSignal): Promise<Profile & { replayed: boolean }> {
    if (!this.onboardingCapabilities.profileUpdate) return this.unsupported();
    if (!intent.actionId || !Number.isSafeInteger(intent.expectedVersion) || intent.expectedVersion < 1 || !validProfileName(intent.displayName)) throw new ApiError(422, 'invalid_profile_intent');
    const r = await this.request('/profile', 'POST', { action_id: intent.actionId, display_name: intent.displayName.trim(), expected_version: intent.expectedVersion }, signal);
    const result = this.profileValue(r);
    if (typeof r.replayed !== 'boolean' || result.principal.displayName !== intent.displayName.trim() || result.version !== intent.expectedVersion + 1) throw new ApiError(502, 'invalid_profile_receipt');
    return { ...result, replayed: r.replayed };
  }
  /** Follow only validated UUID cursors. Never silently present a partial directory. */
  private async accountPages(path: string, field: string, signal?: AbortSignal): Promise<Json[]> {
    let after = ''; const entries: Json[] = []; const seen = new Set<string>();
    for (let page = 0; page < 100; page++) {
      const result = await this.request(`${path}?limit=100${after ? `&after=${after}` : ''}`, 'GET', undefined, signal);
      if (!Array.isArray(result[field]) || result[field].length > 100 || typeof result.cursor !== 'string') throw new ApiError(502, 'invalid_account_page');
      const values = list(result[field]);
      for (const value of values) {
        const id = text(value.id, text(value.principal_id));
        if (!uuid(id) || seen.has(id) || (after && id <= after) || (entries.length && id <= text(entries.at(-1)?.id, text(entries.at(-1)?.principal_id)))) throw new ApiError(502, 'invalid_account_cursor');
        seen.add(id); entries.push(value);
      }
      if (!result.cursor) return entries;
      if (!uuid(result.cursor) || !values.length || result.cursor !== text(values.at(-1)?.id, text(values.at(-1)?.principal_id)) || result.cursor === after) throw new ApiError(502, 'invalid_account_cursor');
      after = result.cursor;
    }
    throw new ApiError(422, 'account_directory_too_large');
  }
  async workspaces(signal?: AbortSignal): Promise<WorkspaceInfo[]> {
    if (!this.onboardingCapabilities.workspaces) return this.unsupported();
    return (await this.accountPages('/workspaces', 'workspaces', signal)).map(value => workspaceInfo(value, true));
  }
  async workspaceMembers(workspaceId: string, signal?: AbortSignal): Promise<WorkspaceMember[]> {
    if (!this.onboardingCapabilities.workspaceMembers) return this.unsupported();
    if (!uuid(workspaceId)) throw new ApiError(422, 'invalid_workspace');
    return (await this.accountPages(`/workspaces/${workspaceId}/members`, 'members', signal)).map(memberInfo);
  }
  async members(roomId: string, signal?: AbortSignal): Promise<Principal[]> {
    if (!this.onboardingCapabilities.roomMembers) return this.unsupported();
    if (!uuid(roomId)) throw new ApiError(422, 'invalid_room');
    return (await this.accountPages(`/rooms/${roomId}/members`, 'members', signal)).map(memberInfo);
  }
  async createWorkspace(intent: WorkspaceIntent, signal?: AbortSignal): Promise<WorkspaceInfo> {
    if (!this.onboardingCapabilities.workspaceCreate) return this.unsupported();
    if (!intent.actionId || !validWorkspaceTitle(intent.title)) throw new ApiError(422, 'invalid_workspace_intent');
    const result = workspaceInfo(object((await this.request('/workspaces', 'POST', { action_id: intent.actionId, title: intent.title.trim() }, signal)).workspace));
    if (result.title !== intent.title.trim()) throw new ApiError(502, 'invalid_workspace_receipt');
    return result;
  }
  async createWorkspaceRoom(intent: RoomIntent, signal?: AbortSignal): Promise<Room> {
    if (!this.onboardingCapabilities.roomCreate) return this.unsupported();
    if (!intent.actionId || !uuid(intent.workspaceId) || !validWorkspaceTitle(intent.title) || intent.memberIds.length > 100 || intent.memberIds.some(id => !uuid(id)) || new Set(intent.memberIds).size !== intent.memberIds.length || !intent.memberIds.includes(this.principalId)) throw new ApiError(422, 'invalid_room_intent');
    const r = object((await this.request('/rooms', 'POST', { action_id: intent.actionId, workspace_id: intent.workspaceId, title: intent.title.trim(), members: intent.memberIds }, signal)).room);
    if (!uuid(text(r.id)) || r.workspace_id !== intent.workspaceId || r.title !== intent.title.trim() || r.kind !== 'group' || !Number.isSafeInteger(r.version) || number(r.version) < 1 || !Number.isSafeInteger(r.scope_epoch) || number(r.scope_epoch) < 1) throw new ApiError(502, 'invalid_room_receipt');
    return { ...room(r), workspaceId: intent.workspaceId };
  }
  async workspaceInvitations(workspaceId: string, signal?: AbortSignal): Promise<WorkspaceInvitation[]> {
    if (!this.invitationCapabilities.list) return this.unsupported();
    if (!uuid(workspaceId)) throw new ApiError(422, 'invalid_workspace');
    return (await this.accountPages(`/workspaces/${workspaceId}/invitations`, 'invitations', signal)).map(value => invitation(value, workspaceId));
  }
  private invitationReceipt(value: Json, workspaceId: string): InvitationReceipt {
    const item = invitation(value.invitation, workspaceId);
    if (typeof value.replayed !== 'boolean' || typeof value.code_available !== 'boolean' || value.code_available && (value.replayed || item.status !== 'pending' || typeof value.code !== 'string' || !validInvitationCode(value.code)) || !value.code_available && value.code !== undefined) throw new ApiError(502, 'invalid_invitation_receipt');
    return { invitation: item, replayed: value.replayed, codeAvailable: value.code_available, ...(value.code_available ? { code: text(value.code) } : {}) };
  }
  async createInvitation(intent: InvitationCreateIntent, signal?: AbortSignal): Promise<InvitationReceipt> {
    if (!this.invitationCapabilities.create) return this.unsupported();
    if (!uuid(intent.actionId) || !uuid(intent.workspaceId) || !Number.isSafeInteger(intent.expiresInSeconds) || intent.expiresInSeconds < 60 || intent.expiresInSeconds > 604800) throw new ApiError(422, 'invalid_invitation_intent');
    const receipt = this.invitationReceipt(await this.request(`/workspaces/${intent.workspaceId}/invitations`, 'POST', { action_id: intent.actionId, expires_in_seconds: intent.expiresInSeconds }, signal), intent.workspaceId);
    if (receipt.invitation.createActionId !== intent.actionId || receipt.invitation.createdBy !== this.principalId) throw new ApiError(502, 'invalid_invitation_owner');
    return receipt;
  }
  async revokeInvitation(intent: InvitationRevokeIntent, signal?: AbortSignal): Promise<InvitationReceipt> {
    if (!this.invitationCapabilities.revoke) return this.unsupported();
    if (!uuid(intent.actionId) || !uuid(intent.workspaceId) || !uuid(intent.invitationId)) throw new ApiError(422, 'invalid_invitation_intent');
    const receipt = this.invitationReceipt(await this.request(`/workspaces/${intent.workspaceId}/invitations/${intent.invitationId}/revoke`, 'POST', { action_id: intent.actionId }, signal), intent.workspaceId);
    if (receipt.invitation.id !== intent.invitationId || receipt.codeAvailable) throw new ApiError(502, 'invalid_invitation_receipt');
    return receipt;
  }
  private acceptance(value: Json): InvitationAcceptance {
    const item = invitation(value.invitation);
    if (value.code_available !== false || value.code !== undefined || value.workspace_id !== item.workspaceId || value.principal_id !== this.principalId || !['owner', 'admin', 'member'].includes(text(value.role)) || typeof value.already_member !== 'boolean' || typeof value.replayed !== 'boolean' || value.execution_scope_extended !== false || item.status !== 'accepted' || item.acceptedBy !== this.principalId) throw new ApiError(502, 'invalid_invitation_acceptance');
    return { invitation: item, workspaceId: item.workspaceId, principalId: this.principalId, role: text(value.role), alreadyMember: value.already_member, replayed: value.replayed, executionScopeExtended: false };
  }
  async acceptInvitation(intent: InvitationAcceptIntent, signal?: AbortSignal): Promise<InvitationAcceptance> {
    if (!this.invitationCapabilities.accept) return this.unsupported();
    if (!uuid(intent.actionId) || !validInvitationCode(intent.code)) throw new ApiError(422, 'invalid_invitation_intent');
    return this.acceptance(await this.request('/workspace-invitations/accept', 'POST', { action_id: intent.actionId, code: intent.code.trim() }, signal));
  }
  async invitationAction(actionId: string, signal?: AbortSignal): Promise<InvitationAction> {
    if (!this.invitationCapabilities.actionRead) return this.unsupported();
    if (!uuid(actionId)) throw new ApiError(422, 'invalid_invitation_action');
    const value = await this.request(`/workspace-invitation-actions/${actionId}`, 'GET', undefined, signal);
    const kinds: Record<string, 'create' | 'revoke' | 'accept'> = { 'workspace.invitation.create': 'create', 'workspace.invitation.revoke': 'revoke', 'workspace.invitation.accept': 'accept' };
    const kind = kinds[text(value.kind)];
    if (value.action_id !== actionId || !kind || !this.invitationCapabilities[kind]) throw new ApiError(502, 'invalid_invitation_action');
    const raw = object(value.receipt);
    if (kind === 'accept') { const receipt = this.acceptance(raw); if (!receipt.replayed) throw new ApiError(502, 'invalid_invitation_action'); return { actionId, kind, receipt }; }
    const receipt = this.invitationReceipt(raw, text(object(raw.invitation).workspace_id));
    if (receipt.codeAvailable || !receipt.replayed || kind === 'create' && (receipt.invitation.createActionId !== actionId || receipt.invitation.createdBy !== this.principalId)) throw new ApiError(502, 'invalid_invitation_action');
    return { actionId, kind, receipt };
  }
  async rongCloudEvents(after: number, signal?: AbortSignal) {
    if (!Number.isSafeInteger(after) || after < 0) throw new ApiError(422, 'invalid_transport_cursor');
    const r = await this.request(`/transport/events?after=${after}&limit=50`, 'GET', undefined, signal), status = object(r.status);
    if (r.schema !== 'renji.transport.events.v1' || r.transport !== 'rongcloud' || r.mode !== 'trusted_development_bridge' || !Array.isArray(r.events) || r.events.length > 50 || !Number.isSafeInteger(r.next_cursor) || number(r.next_cursor, -1) < after || typeof r.has_more !== 'boolean' || !['connected', 'disconnected', 'unavailable'].includes(text(status.bridge_state))) throw new ApiError(502, 'invalid_transport_events');
    const events = r.events.map((value, index) => {
      const e = object(value);
      if (!Number.isSafeInteger(e.cursor) || number(e.cursor) <= (index ? number(object((r.events as unknown[])[index - 1]).cursor) : after) || number(e.cursor) > number(r.next_cursor) || (!Number.isSafeInteger(e.event_id) || number(e.event_id) < 1) || !uuid(text(e.room_id)) || !uuid(text(e.message_id)) || !text(e.provider_uid) || !['message.created', 'message.reaction_set'].includes(text(e.kind)) || !timestamp(e.received_at)) throw new ApiError(502, 'invalid_transport_event');
      return { cursor: number(e.cursor), roomId: text(e.room_id), messageId: text(e.message_id) };
    });
    if (r.has_more && number(r.next_cursor) === after || status.last_received_at && !timestamp(status.last_received_at) || status.last_heartbeat_at && !timestamp(status.last_heartbeat_at)) throw new ApiError(502, 'invalid_transport_status');
    return { events, nextCursor: number(r.next_cursor), hasMore: r.has_more, state: status.bridge_state as 'connected' | 'disconnected' | 'unavailable', lastReceivedAt: timestamp(status.last_received_at) };
  }
  async send(roomId: string, intent: SendIntent, signal?: AbortSignal): Promise<Message> {
    if (intent.mentions.length) throw new ApiError(501, 'mentions_unavailable');
    if (intent.replyTo && !this.capabilities.replies) throw new ApiError(501, 'replies_unavailable');
    const result = await this.request(`/rooms/${encodeURIComponent(roomId)}/messages`, 'POST', { action_id: intent.actionId, content: intent.content, ...(intent.replyTo ? { reply_to: intent.replyTo } : {}), ...(intent.scopeEpoch !== undefined ? { scope_epoch: intent.scopeEpoch } : {}) }, signal);
    return message(result.message, roomId);
  }
  async message(roomId: string, messageId: string, signal?: AbortSignal): Promise<Message> {
    const raw = object((await this.request(`/rooms/${encodeURIComponent(roomId)}/messages/${encodeURIComponent(messageId)}`, 'GET', undefined, signal)).message);
    if (raw.id !== messageId || raw.room_id !== roomId || !Number.isSafeInteger(raw.seq) || number(raw.seq) < 1) throw new ApiError(502, 'invalid_message_target');
    return message(raw, roomId);
  }
  async setReaction(roomId: string, messageId: string, intent: ReactionIntent, signal?: AbortSignal): Promise<ReactionReceipt> {
    if (!this.capabilities.reactions || !this.principalId) return this.unsupported();
    if (!intent.actionId || !intent.emoji || typeof intent.active !== 'boolean') throw new ApiError(422, 'invalid_reaction_intent');
    const r = await this.request(`/rooms/${encodeURIComponent(roomId)}/messages/${encodeURIComponent(messageId)}/reactions`, 'POST', { action_id: intent.actionId, emoji: intent.emoji, active: intent.active, ...(intent.scopeEpoch !== undefined ? { scope_epoch: intent.scopeEpoch } : {}) }, signal);
    if (r.room_id !== roomId || r.message_id !== messageId || r.principal_id !== this.principalId || r.emoji !== intent.emoji || r.active !== intent.active || typeof r.changed !== 'boolean' || typeof r.replayed !== 'boolean' || typeof r.selected !== 'boolean' || r.selected !== intent.active || !Number.isSafeInteger(r.version) || number(r.version, -1) < 0 || !Number.isSafeInteger(r.count) || number(r.count, -1) < 0) throw new ApiError(502, 'invalid_reaction_receipt');
    return { roomId, messageId, principalId: this.principalId, emoji: intent.emoji, active: intent.active, version: number(r.version), replayed: r.replayed };
  }
  async reactionSummaries(roomId: string, messageId: string, options: { after?: string; expectedVersion?: number; signal?: AbortSignal } = {}): Promise<ReactionPage> {
    if (!this.capabilities.reactions) return this.unsupported();
    if (options.expectedVersion !== undefined && (!Number.isSafeInteger(options.expectedVersion) || options.expectedVersion < 0) || (options.after?.length ?? 0) > 512) throw new ApiError(422, 'invalid_reaction_query');
    const params = new URLSearchParams({ limit: '50' });
    if (options.after) params.set('after', options.after);
    if (options.expectedVersion !== undefined) params.set('expected_version', String(options.expectedVersion));
    const r = await this.request(`/rooms/${encodeURIComponent(roomId)}/messages/${encodeURIComponent(messageId)}/reactions?${params}`, 'GET', undefined, options.signal);
    if (r.room_id !== roomId || r.message_id !== messageId || typeof r.has_more !== 'boolean' || !Number.isSafeInteger(r.version) || number(r.version, -1) < 0 || options.expectedVersion !== undefined && r.version !== options.expectedVersion || r.next_after !== undefined && typeof r.next_after !== 'string') throw new ApiError(502, 'invalid_reaction_page');
    const summaries = reactionSummaries(r.summaries, 50);
    if (r.has_more && !r.next_after || r.next_after && (!summaries.length || r.next_after !== summaries.at(-1)?.emoji || r.next_after === options.after)) throw new ApiError(502, 'invalid_reaction_cursor');
    return { summaries, version: number(r.version), nextAfter: r.has_more ? text(r.next_after) : undefined };
  }
  async emoji(options: { query?: string; category?: string; offset?: number; revision?: string; signal?: AbortSignal } = {}): Promise<EmojiPage> {
    if (!this.capabilities.reactions) return this.unsupported();
    const offset = options.offset ?? 0;
    if (!Number.isSafeInteger(offset) || offset < 0 || (options.query?.length ?? 0) > 100) throw new ApiError(422, 'invalid_emoji_query');
    const params = new URLSearchParams({ offset: String(offset), limit: '100' });
    if (options.query) params.set('q', options.query);
    if (options.category) params.set('category', options.category);
    if (options.revision) params.set('revision', options.revision);
    const r = await this.request(`/emoji?${params}`, 'GET', undefined, options.signal);
    if (r.version !== 'emoji-catalog/v1' || !/^sha256:[a-f0-9]{64}$/.test(text(r.revision)) || options.revision && r.revision !== options.revision || !Array.isArray(r.entries) || r.entries.length > 100 || !Array.isArray(r.categories) || r.categories.some(c => typeof c !== 'string') || !Number.isSafeInteger(r.total) || number(r.total, -1) < 0 || !Number.isSafeInteger(r.catalog_count) || number(r.catalog_count, -1) < 0 || r.offset !== offset || typeof r.has_more !== 'boolean') throw new ApiError(502, 'invalid_emoji_catalog');
    const revision = text(r.revision), rawEntries = r.entries;
    const entries = rawEntries.map(value => {
      const e = object(value);
      if (!text(e.id) || !text(e.name) || !text(e.text) || !text(e.category)) throw new ApiError(502, 'invalid_emoji_catalog');
      if (e.asset !== undefined && (!/^\/v1\/emoji\/assets\/feishu\/[A-Za-z0-9_]+\.png$/.test(text(e.asset)) || !/^"sha256-[a-f0-9]{64}"$/.test(text(e.asset_etag)))) throw new ApiError(502, 'invalid_emoji_asset');
      return { id: text(e.id), name: text(e.name), text: text(e.text), category: text(e.category), ...(e.asset ? { asset: text(e.asset), revision } : {}) };
    });
    if (new Set(entries.map(e => e.id)).size !== entries.length || r.has_more && (!entries.length || r.next_offset !== offset + entries.length)) throw new ApiError(502, 'invalid_emoji_cursor');
    entries.forEach((e, i) => { if (e.asset) this.assets.set(`${revision}:${e.asset}`, text(object(rawEntries[i]).asset_etag)); });
    return { entries, categories: r.categories as string[], total: number(r.total), catalogCount: number(r.catalog_count), revision, nextOffset: r.has_more ? number(r.next_offset) : undefined };
  }
  async emojiAsset(asset: string, revision: string, signal?: AbortSignal): Promise<Blob> {
    const etag = this.assets.get(`${revision}:${asset}`);
    if (!etag || !/^\/v1\/emoji\/assets\/feishu\/[A-Za-z0-9_]+\.png$/.test(asset)) throw new ApiError(422, 'unverified_emoji_asset');
    const combined = AbortSignal.any([this.lifecycle.signal, AbortSignal.timeout(15000), ...(signal ? [signal] : [])]);
    combined.throwIfAborted();
    const bearer = await this.token(); combined.throwIfAborted();
    if (!bearer) throw new ApiError(401, 'missing_session');
    const response = await this.fetcher(`${this.endpoint}${asset}`, { redirect: 'error', cache: 'no-store', credentials: 'omit', headers: { Authorization: `Bearer ${bearer}`, Accept: 'image/png', 'If-Match': etag }, signal: combined });
    combined.throwIfAborted();
    if (!response.ok) throw new ApiError(response.status, 'emoji_asset_failed');
    if (response.headers.get('Content-Type')?.split(';')[0] !== 'image/png' || response.headers.get('ETag') !== etag) throw new ApiError(502, 'invalid_emoji_asset');
    const reader = response.body?.getReader();
    if (!reader) throw new ApiError(502, 'invalid_emoji_asset');
    const chunks: Uint8Array<ArrayBuffer>[] = []; let size = 0;
    try { while (true) { const { done, value } = await reader.read(); combined.throwIfAborted(); if (done) break; size += value.length; if (size > 1048576) throw new ApiError(502, 'emoji_asset_too_large'); chunks.push(new Uint8Array(value)); } } finally { await reader.cancel(); }
    const bytes = new Uint8Array(size); let at = 0; for (const chunk of chunks) { bytes.set(chunk, at); at += chunk.length; }
    if (size < 8 || ![137,80,78,71,13,10,26,10].every((v, i) => bytes[i] === v)) throw new ApiError(502, 'invalid_emoji_asset');
    const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
    const hash = [...digest].map(byte => byte.toString(16).padStart(2, '0')).join('');
    combined.throwIfAborted();
    if (etag !== `"sha256-${hash}"`) throw new ApiError(502, 'emoji_asset_hash_mismatch');
    return new Blob([bytes], { type: 'image/png' });
  }
  close() { this.assets.clear(); this.principalId = ''; this.capabilities.reactions = false; this.capabilities.replies = false; super.close(); }
  async rongCloudSession(signal?: AbortSignal): Promise<{ appKey: string; userId: string; token: string }> {
    const result = await this.request('/transport/rongcloud/session', 'POST', {}, signal);
    if (!text(result.app_key) || !text(result.user_id) || !text(result.token)) throw new ApiError(502, 'invalid_transport_session');
    return { appKey: text(result.app_key), userId: text(result.user_id), token: text(result.token) };
  }
}

/** Explicit legacy migration adapter; never a fallback for failed Clerk auth. */
export class LegacyClient extends HttpClient {
  readonly mode = 'legacy' as const;
  readonly capabilities: Capabilities = { directory: true, documents: true, roomPreferences: true, createRoom: true, mentions: true, liveEvents: true, readReceipts: true, reactions: true, replies: true };
  protected get prefix() { return '/api/im'; }
  protected requestURL(path: string) { return legacyRequestURL(this.endpoint, path, import.meta.env.DEV); }
  static async login(endpoint: string, username: string, password: string, signal?: AbortSignal, fetcher: typeof fetch = fetch): Promise<LegacyClient> {
    const address = normalizeEndpoint(endpoint), combined = AbortSignal.any([AbortSignal.timeout(20000), ...(signal ? [signal] : [])]);
    const response = await fetcher(legacyRequestURL(address, '/auth/login', import.meta.env.DEV), { method: 'POST', redirect: 'error', credentials: 'omit', cache: 'no-store', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username, password }), signal: combined });
    const result = object(await response.json().catch(() => ({})));
    combined.throwIfAborted();
    if (!response.ok || !text(result.token)) throw new ApiError(response.status === 200 ? 502 : response.status, 'login_failed');
    let token = text(result.token);
    const client = new LegacyClient(address, async () => token, fetcher);
    const retire = client.close.bind(client);
    client.close = () => { token = ''; retire(); };
    return client;
  }
  async send(roomId: string, intent: SendIntent, signal?: AbortSignal): Promise<Message> {
    return message((await this.request(`/rooms/${encodeURIComponent(roomId)}/messages`, 'POST', { client_id: intent.actionId, content: intent.content, mentions: intent.mentions, mention_all: false, attachment_ids: [], ...(intent.replyTo ? { reply_to: intent.replyTo } : {}) }, signal)).message, roomId);
  }
  async react(roomId: string, messageId: string, emojiId: string, signal?: AbortSignal): Promise<Message> {
    const result = message((await this.request(`/rooms/${encodeURIComponent(roomId)}/messages/${encodeURIComponent(messageId)}/reactions`, 'POST', { emoji: emojiId }, signal)).message, roomId);
    if (result.id !== messageId) throw new ApiError(502, 'invalid_reaction_target');
    return result;
  }
  async emoji(options: { query?: string; category?: string; offset?: number; signal?: AbortSignal } = {}): Promise<EmojiPage> {
    const offset = options.offset ?? 0;
    if (!Number.isSafeInteger(offset) || offset < 0 || (options.query?.length ?? 0) > 100) throw new ApiError(422, 'invalid_emoji_query');
    const params = new URLSearchParams({ offset: String(offset), limit: '100' });
    if (options.query) params.set('q', options.query);
    if (options.category) params.set('category', options.category);
    const result = await this.request(`/emoji?${params}`, 'GET', undefined, options.signal);
    if (!Array.isArray(result.entries) || result.entries.length > 100 || !Array.isArray(result.categories) || result.categories.some(c => typeof c !== 'string') || !Number.isSafeInteger(result.total) || number(result.total, -1) < 0 || !Number.isSafeInteger(result.catalog_count) || result.offset !== offset || typeof result.has_more !== 'boolean') throw new ApiError(502, 'invalid_emoji_catalog');
    const entries = result.entries.map(value => {
      const entry = object(value);
      if (!text(entry.id) || !text(entry.name) || !text(entry.text) || !text(entry.category)) throw new ApiError(502, 'invalid_emoji_catalog');
      return { id: text(entry.id), name: text(entry.name), text: text(entry.text), category: text(entry.category) };
    });
    if (new Set(entries.map(e => e.id)).size !== entries.length || result.has_more && (!entries.length || result.next_offset !== offset + entries.length)) throw new ApiError(502, 'invalid_emoji_cursor');
    return { entries, categories: result.categories as string[], total: result.total as number, catalogCount: result.catalog_count as number, nextOffset: result.has_more ? result.next_offset as number : undefined };
  }
  async people(signal?: AbortSignal): Promise<Principal[]> { return list((await this.request('/principals', 'GET', undefined, signal)).principals).map(principal); }
  async members(roomId: string, signal?: AbortSignal): Promise<Principal[]> { return list((await this.request(`/rooms/${encodeURIComponent(roomId)}`, 'GET', undefined, signal)).members).filter(p => !p.disabled).map(principal); }
  async preferences(roomId: string, values: { pinned?: boolean; muted?: boolean; read_seq?: number }, signal?: AbortSignal) { await this.request(`/rooms/${encodeURIComponent(roomId)}/preferences`, 'PATCH', values, signal); }
  async createRoom(title: string, signal?: AbortSignal) { return room((await this.request('/rooms', 'POST', { name: title }, signal)).room); }
  async direct(principalId: string, signal?: AbortSignal) { return room((await this.request('/rooms/direct', 'POST', { principal_id: principalId }, signal)).room); }
  async documents(signal?: AbortSignal): Promise<Document[]> {
    return list((await this.request('/library', 'GET', undefined, signal)).documents).map(d => {
      // The authorized library returns room_ids, including documents shared in
      // several rooms. Use only a server-returned context; never invent one.
      const roomIds = Array.isArray(d.room_ids) ? d.room_ids.filter((id): id is string => typeof id === 'string' && id.length > 0) : [];
      return { id: text(d.id), roomId: text(d.room_id) || roomIds[0] || '', roomIds, title: text(d.title, text(d.name, '未命名文档')), revision: number(d.revision), updatedAt: timestamp(d.updated_at) };
    });
  }
  async document(roomId: string, documentId: string, signal?: AbortSignal): Promise<DocumentContent> {
    if (!roomId || roomId.length > 200 || !/^[a-zA-Z0-9_-]{1,100}$/.test(documentId)) throw new ApiError(422, 'invalid_document_context');
    const result = await this.request(`/rooms/${encodeURIComponent(roomId)}/documents/${encodeURIComponent(documentId)}`, 'GET', undefined, signal);
    const d = object(result.document);
    if (d.id !== documentId || typeof d.title !== 'string' || typeof d.content !== 'string' || d.content.length > 200000 || !Number.isSafeInteger(d.revision) || number(d.revision, -1) < 0 || typeof d.content_hash !== 'string' || !/^[a-f0-9]{64}$/.test(d.content_hash)) throw new ApiError(502, 'invalid_document');
    return { id: documentId, roomId, title: d.title, content: d.content, revision: d.revision as number, contentHash: d.content_hash, updatedAt: timestamp(d.updated_at) };
  }
  async events(after: number, signal?: AbortSignal): Promise<EventPage> { const result = await this.request(`/events?after=${after}&wait=20`, 'GET', undefined, signal); return { cursor: number(result.cursor, after), changed: list(result.events).length > 0, resetRequired: result.reset_required === true }; }
}

export function legacyRequestURL(endpoint: string, path: string, development: boolean): string {
  return `${development && endpoint === 'http://127.0.0.1:3218' ? '/legacy' : endpoint}/api/im${path}`;
}
