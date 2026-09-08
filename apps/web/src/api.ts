import type { Capabilities, CollaborationClient, Document, EventPage, Message, MessagePage, Principal, Room, RoomPage, SendIntent } from './types';

type Json = Record<string, unknown>;
const object = (value: unknown): Json => value && typeof value === 'object' && !Array.isArray(value) ? value as Json : {};
const list = (value: unknown): Json[] => Array.isArray(value) ? value.map(object) : [];
const text = (value: unknown, fallback = '') => typeof value === 'string' ? value : fallback;
const number = (value: unknown, fallback = 0) => typeof value === 'number' && Number.isFinite(value) ? value : fallback;

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
  return { id: text(m.id), roomId: text(m.room_id, roomId), authorId: text(m.author_id), authorName: text(author.display_name, text(author.name)), authorKind: text(author.kind), content: text(m.content), seq: number(m.seq), createdAt: text(m.created_at, text(m.at)), retracted: Boolean(m.retracted_at), mentions: Array.isArray(m.mentions) ? m.mentions.filter((id): id is string => typeof id === 'string') : [], isVoice: Boolean(m.voice), attachmentCount: Array.isArray(m.attachments) ? m.attachments.length : 0, receipt: receipt.known === true && typeof receipt.read_count === 'number' && typeof receipt.eligible_count === 'number' ? { read: receipt.read_count, total: receipt.eligible_count } : undefined };
}
export function room(value: unknown): Room {
  const r = object(value);
  if (!text(r.id)) throw new ApiError(502, 'invalid_room');
  return { id: text(r.id), title: text(r.title, text(r.name, '未命名会话')), kind: text(r.kind, 'group'), version: number(r.version, number(r.revision, 1)), scopeEpoch: typeof r.scope_epoch === 'number' ? r.scope_epoch : undefined, stopped: typeof r.stopped === 'boolean' ? r.stopped : undefined, unread: typeof r.unread_count === 'number' ? r.unread_count : undefined, pinned: typeof r.is_pinned === 'boolean' ? r.is_pinned : undefined, muted: typeof r.muted === 'boolean' ? r.muted : undefined, firstUnreadSeq: typeof r.first_unread_seq === 'number' ? r.first_unread_seq : undefined, lastMessage: r.last_message ? message(r.last_message, text(r.id)) : undefined };
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
      throw new ApiError(response.status, text(json.code, text(nested.code, 'request_failed')));
    }
    return object(result);
  }
  async me(signal?: AbortSignal): Promise<Principal> { return principal((await this.request('/me', 'GET', undefined, signal)).principal); }
  async rooms(signal?: AbortSignal): Promise<RoomPage> { const r = await this.request('/rooms', 'GET', undefined, signal); return { rooms: list(r.rooms).map(room), cursor: number(r.cursor) }; }
  async messages(roomId: string, options: { before?: number; firstUnread?: boolean; signal?: AbortSignal } = {}): Promise<MessagePage> {
    const params = new URLSearchParams({ limit: '100' });
    if (options.before !== undefined) params.set('before', String(options.before));
    if (options.firstUnread && this.mode === 'legacy') params.set('first_unread', 'true');
    const r = await this.request(`/rooms/${encodeURIComponent(roomId)}/messages?${params}`, 'GET', undefined, options.signal);
    return { messages: list(r.messages).map(m => message(m, roomId)).sort((a, b) => a.seq - b.seq), hasMoreBefore: r.has_more_before === true, hasMoreAfter: r.has_more_after === true, firstUnreadSeq: typeof r.anchor_seq === 'number' ? r.anchor_seq : undefined };
  }
  abstract send(roomId: string, intent: SendIntent, signal?: AbortSignal): Promise<Message>;
  protected unsupported(): never { throw new ApiError(501, 'capability_unavailable'); }
  async people(_signal?: AbortSignal): Promise<Principal[]> { return this.unsupported(); }
  async members(_roomId: string, _signal?: AbortSignal): Promise<Principal[]> { return this.unsupported(); }
  async preferences(_roomId: string, _values: { pinned?: boolean; muted?: boolean; read_seq?: number }, _signal?: AbortSignal): Promise<void> { return this.unsupported(); }
  async createRoom(_title: string, _signal?: AbortSignal): Promise<Room> { return this.unsupported(); }
  async direct(_principalId: string, _signal?: AbortSignal): Promise<Room> { return this.unsupported(); }
  async documents(_signal?: AbortSignal): Promise<Document[]> { return this.unsupported(); }
  async events(_after: number, _signal?: AbortSignal): Promise<EventPage> { return this.unsupported(); }
  close() { this.lifecycle.abort(); this.token = async () => null; }
}

export class StartupClient extends HttpClient {
  readonly mode = 'startup' as const;
  readonly capabilities: Capabilities = { directory: false, documents: false, roomPreferences: false, createRoom: false, mentions: false, liveEvents: false, readReceipts: false };
  protected get prefix() { return '/v1'; }
  async send(roomId: string, intent: SendIntent, signal?: AbortSignal): Promise<Message> {
    if (intent.mentions.length) throw new ApiError(501, 'mentions_unavailable');
    const result = await this.request(`/rooms/${encodeURIComponent(roomId)}/messages`, 'POST', { action_id: intent.actionId, content: intent.content, ...(intent.scopeEpoch !== undefined ? { scope_epoch: intent.scopeEpoch } : {}) }, signal);
    return message(result.message, roomId);
  }
  async rongCloudSession(signal?: AbortSignal): Promise<{ appKey: string; userId: string; token: string }> {
    const result = await this.request('/transport/rongcloud/session', 'POST', {}, signal);
    if (!text(result.app_key) || !text(result.user_id) || !text(result.token)) throw new ApiError(502, 'invalid_transport_session');
    return { appKey: text(result.app_key), userId: text(result.user_id), token: text(result.token) };
  }
}

/** Explicit legacy migration adapter; never a fallback for failed Clerk auth. */
export class LegacyClient extends HttpClient {
  readonly mode = 'legacy' as const;
  readonly capabilities: Capabilities = { directory: true, documents: true, roomPreferences: true, createRoom: true, mentions: true, liveEvents: true, readReceipts: true };
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
    return message((await this.request(`/rooms/${encodeURIComponent(roomId)}/messages`, 'POST', { client_id: intent.actionId, content: intent.content, mentions: intent.mentions, mention_all: false, attachment_ids: [] }, signal)).message, roomId);
  }
  async people(signal?: AbortSignal): Promise<Principal[]> { return list((await this.request('/principals', 'GET', undefined, signal)).principals).map(principal); }
  async members(roomId: string, signal?: AbortSignal): Promise<Principal[]> { return list((await this.request(`/rooms/${encodeURIComponent(roomId)}`, 'GET', undefined, signal)).members).filter(p => !p.disabled).map(principal); }
  async preferences(roomId: string, values: { pinned?: boolean; muted?: boolean; read_seq?: number }, signal?: AbortSignal) { await this.request(`/rooms/${encodeURIComponent(roomId)}/preferences`, 'PATCH', values, signal); }
  async createRoom(title: string, signal?: AbortSignal) { return room((await this.request('/rooms', 'POST', { name: title }, signal)).room); }
  async direct(principalId: string, signal?: AbortSignal) { return room((await this.request('/rooms/direct', 'POST', { principal_id: principalId }, signal)).room); }
  async documents(signal?: AbortSignal): Promise<Document[]> { return list((await this.request('/library', 'GET', undefined, signal)).documents).map(d => ({ id: text(d.id), roomId: text(d.room_id), title: text(d.title, text(d.name, '未命名文档')), revision: number(d.revision), updatedAt: text(d.updated_at) })); }
  async events(after: number, signal?: AbortSignal): Promise<EventPage> { const result = await this.request(`/events?after=${after}&wait=20`, 'GET', undefined, signal); return { cursor: number(result.cursor, after), changed: list(result.events).length > 0, resetRequired: result.reset_required === true }; }
}

export function legacyRequestURL(endpoint: string, path: string, development: boolean): string {
  return `${development && endpoint === 'http://127.0.0.1:3218' ? '/legacy' : endpoint}/api/im${path}`;
}
