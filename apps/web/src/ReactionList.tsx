import { useState } from 'react';
import { useInfiniteQuery } from '@tanstack/react-query';
import * as Dialog from '@radix-ui/react-dialog';
import { X } from 'lucide-react';
import { errorMessage } from './api';
import { EmojiIcon, messageClientScope } from './MessageActions';
import type { CollaborationClient, Message, ReactionSummary } from './types';

export function visibleReactions(message: Message, principalId: string): ReactionSummary[] {
  return message.reactionSummaries ?? Object.entries(message.reactions ?? {}).filter(([, people]) => people.length).map(([emoji, people]) => ({ emoji, count: people.length, selected: people.includes(principalId) }));
}

/** The page version freezes a complete read, never combining two populations. */
export function ReactionList({ client, roomId, messageId, onClose, onSelect, disabled }: { client: CollaborationClient; roomId: string; messageId: string; onClose: () => void; onSelect: (summary: ReactionSummary) => void; disabled: boolean }) {
  const [attempt, setAttempt] = useState(0);
  const query = useInfiniteQuery({ queryKey: ['reaction-list', messageClientScope(client), roomId, messageId, attempt],
    initialPageParam: { after: undefined as string | undefined, expectedVersion: undefined as number | undefined },
    queryFn: ({ pageParam, signal }) => client.reactionSummaries!(roomId, messageId, { ...pageParam, signal }),
    getNextPageParam: page => page.nextAfter ? { after: page.nextAfter, expectedVersion: page.version } : undefined,
    retry: false, gcTime: 0, staleTime: 0 });
  const summaries = query.isError ? [] : query.data?.pages.flatMap(page => page.summaries) ?? [];
  return <Dialog.Root open onOpenChange={open => { if (!open) onClose(); }}><Dialog.Portal><Dialog.Overlay className="dialog-overlay" /><Dialog.Content className="dialog-content reaction-list-dialog">
    <Dialog.Title>全部表情回应</Dialog.Title><Dialog.Description>当前会话成员可见的回应数量与我的选择。</Dialog.Description>
    <Dialog.Close className="icon-button" aria-label="关闭回应列表"><X size={18} /></Dialog.Close>
    {query.isError ? <div role="alert"><p className="error">{errorMessage(query.error)}</p><button onClick={() => setAttempt(value => value + 1)}>重新读取回应</button></div> : query.isPending ? <p role="status">正在读取回应…</p> : <div className="reaction-list-rows">{summaries.length ? summaries.map(s => <button key={s.emoji} disabled={disabled} aria-pressed={s.selected} onClick={() => onSelect(s)}><EmojiIcon client={client} id={s.emoji} /><span>{s.emoji}</span><span>{s.count} 位回应{s.selected ? ' · 包括我' : ''}</span></button>) : <p>暂无回应</p>}</div>}
    {!query.isError && query.hasNextPage && <button disabled={query.isFetchingNextPage} onClick={() => { void query.fetchNextPage(); }}>加载更多回应</button>}
  </Dialog.Content></Dialog.Portal></Dialog.Root>;
}
