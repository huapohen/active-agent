import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { ArrowLeft, FileText, MessageCircle, RefreshCw, Search } from 'lucide-react';
import { ApiError, errorMessage } from './api';
import { DocumentMarkdown } from './DocumentMarkdown';
import type { CollaborationClient, Document } from './types';
import './documents.css';

// Identity generation belongs to the adapter instance, never a principal ID
// that might be reused after A → B → A. Query data lives only in memory.
const scopes = new WeakMap<CollaborationClient, string>();
function scope(client: CollaborationClient) { let id = scopes.get(client); if (!id) { id = crypto.randomUUID(); scopes.set(client, id); } return id; }
const date = (value?: string) => value ? new Date(value).toLocaleString('zh-CN', { hour12: false }) : '更新时间未知';
const retry = (attempt: number, error: unknown) => !(error instanceof ApiError && [401, 403, 404].includes(error.status)) && attempt < 1;

export function Documents({ client, onOpen }: { client: CollaborationClient; onOpen: (id: string) => void }) {
  return <DocumentDirectory key={scope(client)} client={client} onOpen={onOpen} />;
}
function DocumentDirectory({ client, onOpen }: { client: CollaborationClient; onOpen: (id: string) => void }) {
  const [selected, setSelected] = useState<Document>(), [search, setSearch] = useState('');
  const query = useQuery({ queryKey: ['documents', scope(client)], queryFn: ({ signal }) => client.documents(signal), retry, gcTime: 0, refetchOnWindowFocus: 'always' });
  const rooms = useQuery({ queryKey: ['rooms'], queryFn: ({ signal }) => client.rooms(signal) });
  if (selected) return <DocumentReader client={client} document={selected} roomTitle={rooms.data?.rooms.find(r => r.id === selected.roomId)?.title} onBack={() => setSelected(undefined)} onOpenRoom={onOpen} />;
  const entries = query.error ? [] : query.data?.filter(d => d.title.toLocaleLowerCase().includes(search.trim().toLocaleLowerCase())) ?? [];
  return <section className="directory document-directory" aria-label="云文档目录"><header className="panel-header"><h1>云文档</h1><button className="icon-button" onClick={() => { void query.refetch(); }} disabled={query.isFetching} aria-label="刷新文档"><RefreshCw size={18} /></button></header><div className="document-results">
    <div className="document-search"><Search size={18} /><input aria-label="搜索文档" placeholder="搜索文档标题" value={search} onChange={e => setSearch(e.target.value)} /></div>
    {query.error ? <p role="alert" className="error">{errorMessage(query.error)}</p> : query.isPending ? <p className="empty" role="status">正在读取文档目录…</p> : entries.length ? entries.map(d => <button className="document-row" key={`${d.roomId}:${d.id}`} disabled={!d.roomId} onClick={() => setSelected(d)} data-capability="documents.read"><FileText /><span className="document-row-copy"><strong>{d.title}</strong><small>{rooms.data?.rooms.find(r => r.id === d.roomId)?.title || (d.roomId ? '已共享的会话' : '没有可用会话入口')}</small></span><span className="document-row-meta"><span>{d.revision !== undefined ? `版本 ${d.revision}` : ''}</span><time dateTime={d.updatedAt}>{date(d.updatedAt)}</time></span></button>) : <p className="empty">{search ? '没有匹配的文档' : '暂无可访问的文档'}</p>}
  </div></section>;
}

export function DocumentReader(props: { client: CollaborationClient; document: Document; roomTitle?: string; onBack: () => void; onOpenRoom: (id: string) => void }) {
  return <ScopedDocumentReader key={`${scope(props.client)}:${props.document.roomId}:${props.document.id}`} {...props} />;
}
function ScopedDocumentReader({ client, document, roomTitle, onBack, onOpenRoom }: { client: CollaborationClient; document: Document; roomTitle?: string; onBack: () => void; onOpenRoom: (id: string) => void }) {
  const query = useQuery({
    queryKey: ['document', scope(client), document.roomId, document.id],
    queryFn: ({ signal }) => client.document(document.roomId, document.id, signal),
    retry, gcTime: 0, staleTime: 0, refetchInterval: 15000, refetchOnWindowFocus: 'always', refetchOnMount: 'always',
  });
  // A failed authorization or network recheck hides the previously read body.
  // Do not render query.data underneath errors after React Query refetch fails.
  const current = query.isError ? undefined : query.data;
  const denied = query.error instanceof ApiError && [401, 403, 404].includes(query.error.status);
  const title = current?.title ?? (denied ? '文档已不可访问' : document.title);
  return <section className="document-reader" aria-label="云文档阅读页">
    <header className="document-toolbar"><button className="document-back" onClick={onBack}><ArrowLeft size={18} />云文档</button><div className="document-toolbar-actions"><button className="secondary" aria-label="所属会话" onClick={() => onOpenRoom(document.roomId)}><MessageCircle size={16} /><span>所属会话</span></button><button className="icon-button" onClick={() => { void query.refetch(); }} disabled={query.isFetching} aria-label="刷新正文"><RefreshCw size={18} /></button></div></header>
    <div className="document-reader-scroll"><div className="document-paper"><div className="document-heading"><FileText size={30} /><h1>{title}</h1><div className="document-meta"><span className="document-readonly">只读</span>{current && <><span>版本 {current.revision}</span><time dateTime={current.updatedAt}>{date(current.updatedAt)}</time></>}<span>{denied ? '权限已失效' : roomTitle || '已共享的会话'}</span></div></div>
      {query.isPending ? <p className="empty" role="status">正在校验权限并读取正文…</p> : query.error ? <div className="document-unavailable"><h2>{denied ? '当前身份无法继续阅读' : '正文暂时无法读取'}</h2><p className="error" role="alert">{errorMessage(query.error)}</p><p>此前正文已从阅读区隐藏。重新校验后才能继续阅读。</p><button className="secondary" onClick={() => { void query.refetch(); }} disabled={query.isFetching}>重新校验</button></div> : current ? <>
        {query.isFetching && <p className="document-rechecking" role="status">正在校验权限和最新版本…</p>}
        {current.content ? <article aria-label="文档正文"><DocumentMarkdown content={current.content} /></article> : <p className="empty">这篇文档还没有正文。</p>}
        <footer className="document-footnote">当前为受权阅读。协同编辑、提案与冲突处理继续在现有客户端中使用。</footer>
      </> : null}
    </div></div>
  </section>;
}
