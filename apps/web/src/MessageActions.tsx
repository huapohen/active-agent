import { useEffect, useRef, useState, type KeyboardEvent, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { useInfiniteQuery } from '@tanstack/react-query';
import { Copy, MoreHorizontal, Reply, Search, Smile, Sparkles, X } from 'lucide-react';
import { errorMessage } from './api';
import type { CollaborationClient, Message } from './types';
import './message-actions.css';

// Reuse the reviewed local PNGs; never follow asset URLs returned by a server.
// Vite bundles them into Web/Electron assets with their existing provenance.
const images = import.meta.glob('../../office/assets/emoji/feishu/*.png', { eager: true, query: '?url', import: 'default' }) as Record<string, string>;
const clientScopes = new WeakMap<CollaborationClient, string>();
export function messageClientScope(client: CollaborationClient) {
  let id = clientScopes.get(client);
  if (!id) { id = crypto.randomUUID(); clientScopes.set(client, id); }
  return id;
}
export function EmojiIcon({ id, name }: { id: string; name?: string }) {
  const code = id.startsWith('feishu:') ? id.slice(7) : '';
  const source = /^[a-zA-Z0-9_]+$/.test(code) ? images[`../../office/assets/emoji/feishu/${code}.png`] : undefined;
  return source ? <img src={source} alt="" draggable={false} className="reaction-image" /> : <span aria-hidden="true" className="reaction-glyph">{code ? `[${name || code}]` : id}</span>;
}
export function sourceTime(value: string) {
  const date = new Date(value);
  return Number.isFinite(date.getTime()) ? date.toLocaleString('zh-CN', { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false }) : '发送时间未知';
}
export function messagePreview(message?: Message): string {
  return !message ? '原消息不在当前已加载记录中' : message.hidden ? '原消息已隐藏' : message.retracted ? '原消息已撤回' : message.isVoice ? '[语音消息]' : message.content || `[${message.attachmentCount || 1} 个附件]`;
}

type Surface = { id: string; rect: DOMRect; kind: 'toolbar' | 'menu'; keyboard: boolean };
type Props = {
  client: CollaborationClient; messages: Message[]; meId: string; children: ReactNode;
  reactionBlocked: boolean; onReact: (message: Message, emoji: string) => void;
  onReply: (message: Message) => void; onAgent: (message: Message) => void;
  onError: (error: unknown) => void;
};

/** Transient controls live in a body portal, never in a message's layout box. */
export function MessageActions({ client, messages, children, reactionBlocked, onReact, onReply, onAgent, onError }: Props) {
  const [surface, setSurface] = useState<Surface>(), [palette, setPalette] = useState(false);
  const host = useRef<HTMLDivElement>(null), portal = useRef<HTMLDivElement>(null);
  const state = useRef<Surface | undefined>(undefined), leave = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const suppressFocus = useRef(false), alive = useRef(true);
  const selected = messages.find(message => message.id === surface?.id);
  const allowed = selected && !selected.retracted && !selected.hidden;
  const cancelLeave = () => { clearTimeout(leave.current); leave.current = undefined; };
  const close = (restoreFocus = false) => {
    cancelLeave(); const previous = state.current; state.current = undefined;
    setSurface(undefined); setPalette(false);
    if (restoreFocus && previous) {
      const row = [...(host.current?.querySelectorAll<HTMLElement>('[data-message-id]') ?? [])].find(node => node.dataset.messageId === previous.id);
      suppressFocus.current = true; row?.focus({ preventScroll: true }); suppressFocus.current = false;
    }
  };
  const deferClose = () => {
    cancelLeave();
    leave.current = setTimeout(() => {
      if (state.current?.keyboard && portal.current?.contains(document.activeElement)) return;
      close();
    }, 180);
  };
  const open = (row: HTMLElement, kind: Surface['kind'], keyboard = false, point?: { x: number; y: number }) => {
    const id = row.dataset.messageId;
    if (!id || !messages.some(message => message.id === id && !message.retracted && !message.hidden)) return;
    cancelLeave();
    const rect = point ? new DOMRect(point.x, point.y, 0, 0) : (row.querySelector('.bubble') || row).getBoundingClientRect();
    const next = { id, rect, kind, keyboard };
    if (state.current?.id !== id || state.current.kind !== kind) setPalette(false);
    state.current = next; setSurface(next);
  };
  const rowAt = (target: EventTarget | null) => target instanceof Element ? target.closest<HTMLElement>('[data-message-id]') : null;
  useEffect(() => {
    alive.current = true;
    return () => { alive.current = false; clearTimeout(leave.current); };
  }, []);
  useEffect(() => { close(); }, [client]);
  useEffect(() => { if (surface && !allowed) close(); }, [Boolean(allowed)]);
  useEffect(() => {
    if (!surface) return;
    const outside = (event: Event) => {
      if (portal.current?.contains(event.target as Node)) return;
      const row = rowAt(event.target);
      if (row?.dataset.messageId !== state.current?.id) close();
    };
    const scroll = (event: Event) => { if (!portal.current?.contains(event.target as Node)) close(); };
    const escape = (event: globalThis.KeyboardEvent) => { if (event.key === 'Escape') { event.preventDefault(); close(true); } };
    const hide = () => close();
    document.addEventListener('pointerdown', outside, true);
    document.addEventListener('scroll', scroll, true);
    document.addEventListener('keydown', escape);
    document.addEventListener('visibilitychange', hide);
    window.addEventListener('resize', hide); window.addEventListener('blur', hide);
    return () => {
      document.removeEventListener('pointerdown', outside, true);
      document.removeEventListener('scroll', scroll, true);
      document.removeEventListener('keydown', escape);
      document.removeEventListener('visibilitychange', hide);
      window.removeEventListener('resize', hide); window.removeEventListener('blur', hide);
    };
  }, [Boolean(surface)]);
  useEffect(() => {
    if (surface?.keyboard && surface.kind === 'menu') portal.current?.querySelector<HTMLButtonElement>('[role="menuitem"]:not(:disabled)')?.focus();
  }, [surface?.kind, surface?.keyboard]);
  const act = (callback: (message: Message) => void) => { if (allowed) { const current = selected!; close(); callback(current); } };
  const copy = async () => {
    if (!allowed) return;
    const content = selected!.content; close();
    try { await navigator.clipboard.writeText(content); } catch (error) { if (alive.current) onError(error); }
  };
  const keyboard = (event: KeyboardEvent<HTMLElement>) => {
    if (!['ArrowRight', 'ArrowLeft', 'ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key) || event.target instanceof HTMLInputElement || event.target instanceof HTMLSelectElement) return;
    const buttons = [...event.currentTarget.querySelectorAll<HTMLButtonElement>('button:not(:disabled)')];
    if (!buttons.length) return;
    const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? buttons.length - 1 : (index + (['ArrowLeft', 'ArrowUp'].includes(event.key) ? -1 : 1) + buttons.length) % buttons.length;
    event.preventDefault(); buttons[next]?.focus();
  };
  const left = surface ? Math.max(8, Math.min(surface.kind === 'menu' ? surface.rect.left : surface.rect.right - 212, window.innerWidth - (surface.kind === 'menu' ? 238 : 212) - 8)) : 8;
  const top = surface ? Math.max(8, Math.min(surface.kind === 'menu' ? surface.rect.bottom : surface.rect.top - 42, window.innerHeight - (surface.kind === 'menu' ? 240 : 36) - 8)) : 8;
  const paletteHeight = Math.min(430, window.innerHeight - 16);
  const paletteTop = top + 42 + paletteHeight <= window.innerHeight - 8 ? top + 42 : Math.max(8, top - paletteHeight - 6);
  const toolProps = { onPointerEnter: cancelLeave, onPointerOver: cancelLeave, onPointerLeave: deferClose, onKeyDown: keyboard };
  return <div ref={host} className="message-interactions"
    onPointerOver={event => { if (event.pointerType === 'touch') return; const row = rowAt(event.target); if (row && row.dataset.messageId !== state.current?.id) open(row, 'toolbar'); else if (row) cancelLeave(); }}
    onPointerOut={event => { const next = rowAt(event.relatedTarget); if (!next || next.dataset.messageId !== state.current?.id) deferClose(); }}
    onFocusCapture={event => { if (suppressFocus.current || event.target !== rowAt(event.target)) return; open(event.target as HTMLElement, 'toolbar', true); }}
    onBlurCapture={event => { if (!portal.current?.contains(event.relatedTarget as Node)) deferClose(); }}
    onContextMenu={event => { const row = rowAt(event.target); if (row) { event.preventDefault(); open(row, 'menu', true, { x: event.clientX, y: event.clientY }); } }}
    onKeyDown={event => { const row = rowAt(event.target); if (!row) return; if (event.key === 'ContextMenu' || event.key === 'F10' && event.shiftKey) { event.preventDefault(); open(row, 'menu', true); } else if (event.key === 'Tab' && !event.shiftKey && state.current?.id === row.dataset.messageId && event.target === row) { const first = portal.current?.querySelector<HTMLButtonElement>('button:not(:disabled)'); if (first) { event.preventDefault(); first.focus(); } } }}>
    {children}
    {surface && selected && allowed && createPortal(<div ref={portal} className="message-action-layer" onBlur={event => { if (!event.currentTarget.contains(event.relatedTarget as Node)) close(); }}>
      {surface.kind === 'toolbar' ? <div {...toolProps} className="message-action-toolbar" role="toolbar" aria-label="消息操作" style={{ left, top }}>
        <button aria-label="表情回应" title={client.capabilities.reactions ? '表情回应' : '当前服务尚未开放表情回应'} disabled={!client.capabilities.reactions || reactionBlocked} data-capability="im.messages.reactions.toggle" onPointerEnter={event => { if (event.pointerType !== 'touch' && client.capabilities.reactions && !reactionBlocked) setPalette(true); }} onClick={() => setPalette(!palette)} aria-expanded={palette}><Smile size={18} /></button>
        <button aria-label="回复消息" title="回复消息" disabled={!client.capabilities.replies} data-capability="im.messages.reply" onClick={() => act(onReply)}><Reply size={18} /></button>
        <button aria-label="复制消息" title="复制消息" disabled={!selected.content} onClick={() => { void copy(); }}><Copy size={17} /></button>
        <button aria-label="请 Agent 协作" title="请 Agent 协作" disabled={!client.capabilities.mentions || !client.capabilities.replies} onClick={() => act(onAgent)}><Sparkles size={18} /></button>
        <button aria-label="更多消息操作" title="更多" onClick={() => { setPalette(false); const next = { ...surface, kind: 'menu' as const, keyboard: true }; state.current = next; setSurface(next); }}><MoreHorizontal size={19} /></button>
      </div> : <div {...toolProps} className="message-action-menu" role="menu" aria-label="更多消息操作" style={{ left, top }}>
        <time dateTime={selected.createdAt}>{sourceTime(selected.createdAt)}</time>
        <button role="menuitem" disabled={!client.capabilities.reactions || reactionBlocked} onClick={() => setPalette(!palette)}><Smile />表情回应</button>
        <button role="menuitem" disabled={!client.capabilities.replies} onClick={() => act(onReply)}><Reply />回复消息</button>
        <button role="menuitem" disabled={!selected.content} onClick={() => { void copy(); }}><Copy />复制消息</button>
        <button role="menuitem" disabled={!client.capabilities.mentions || !client.capabilities.replies} onClick={() => act(onAgent)}><Sparkles />请 Agent 协作</button>
      </div>}
      {surface.kind === 'toolbar' && <time className="message-source-time" dateTime={selected.createdAt} style={{ left, top: top >= 30 ? top - 23 : top + 39 }}>{sourceTime(selected.createdAt)}</time>}
      {palette && <div {...toolProps} className="message-emoji-panel" style={{ left: Math.max(8, Math.min(left, window.innerWidth - 344 - 8)), top: paletteTop, height: paletteHeight }}>
        <EmojiPicker client={client} onSelect={id => act(message => onReact(message, id))} onClose={() => { setPalette(false); portal.current?.querySelector<HTMLButtonElement>('button:not(:disabled)')?.focus(); }} keyboard={surface.keyboard} />
      </div>}
    </div>, document.body)}
  </div>;
}

function EmojiPicker({ client, onSelect, onClose, keyboard }: { client: CollaborationClient; onSelect: (id: string) => void; onClose: () => void; keyboard: boolean }) {
  const [search, setSearch] = useState(''), [term, setTerm] = useState(''), [category, setCategory] = useState('');
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => { if (keyboard) input.current?.focus(); }, []);
  useEffect(() => { const timer = setTimeout(() => setTerm(search.trim()), 180); return () => clearTimeout(timer); }, [search]);
  const query = useInfiniteQuery({ queryKey: ['emoji', messageClientScope(client), term, category], initialPageParam: 0,
    queryFn: ({ pageParam, signal }) => client.emoji({ query: term, category, offset: pageParam, signal }),
    getNextPageParam: page => page.nextOffset, staleTime: 60000, gcTime: 0, retry: false });
  const entries = query.isError ? [] : (query.data?.pages.flatMap(page => page.entries) ?? []);
  const searching = term !== search.trim();
  return <section role="dialog" aria-label="选择表情回应" className="emoji-picker">
    <header><strong>表情回应</strong><button aria-label="关闭表情面板" onClick={onClose}><X size={17} /></button></header>
    <div className="emoji-search"><Search size={16} /><input ref={input} aria-label="搜索表情" placeholder="搜索表情" maxLength={100} value={search} onChange={event => setSearch(event.target.value)} /></div>
    <label className="emoji-category">分类<select aria-label="表情分类" value={category} onChange={event => setCategory(event.target.value)}><option value="">全部表情</option>{query.data?.pages[0].categories.map(name => <option key={name}>{name}</option>)}</select></label>
    <div className="emoji-results" aria-busy={query.isFetching || searching}>
      {query.error ? <p className="error" role="alert">{errorMessage(query.error)}</p> : query.isPending || searching ? <p role="status">正在读取表情…</p> : entries.length ? <div className="emoji-grid">{entries.map(entry => <button key={entry.id} title={entry.name} aria-label={entry.name} onClick={() => onSelect(entry.id)}><EmojiIcon id={entry.id} name={entry.name} /></button>)}</div> : <p>没有匹配的表情</p>}
      {query.hasNextPage && !searching && <button className="emoji-load-more" disabled={query.isFetchingNextPage} onClick={() => { void query.fetchNextPage(); }}>{query.isFetchingNextPage ? '正在加载…' : '加载更多表情'}</button>}
    </div>
    <footer>{query.data ? `${query.data.pages[0].total} 个匹配表情` : '表情来自当前工作空间'}<span>点击已有反应可取消</span></footer>
  </section>;
}
