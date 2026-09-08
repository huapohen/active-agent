export type Principal = { id: string; kind: 'human' | 'agent'; displayName: string; organization?: string; profession?: string; category?: string };
export type Receipt = { read?: number; total?: number };
export type Message = { id: string; roomId: string; authorId: string; authorName?: string; authorKind?: string; content: string; seq: number; createdAt: string; retracted: boolean; receipt?: Receipt; mentions: string[]; isVoice?: boolean; attachmentCount?: number };
export type Room = { id: string; title: string; kind: string; version: number; scopeEpoch?: number; stopped?: boolean; unread?: number; pinned?: boolean; muted?: boolean; firstUnreadSeq?: number; lastMessage?: Message };
export type RoomPage = { rooms: Room[]; cursor: number };
export type MessagePage = { messages: Message[]; hasMoreBefore: boolean; hasMoreAfter: boolean; firstUnreadSeq?: number };
export type SendIntent = { actionId: string; content: string; mentions: string[]; scopeEpoch?: number };
export type Document = { id: string; roomId: string; roomIds?: string[]; title: string; revision?: number; updatedAt?: string };
export type DocumentContent = Document & { content: string; revision: number; contentHash: string };
export type EventPage = { cursor: number; changed: boolean; resetRequired: boolean };
export type Capabilities = { directory: boolean; documents: boolean; roomPreferences: boolean; createRoom: boolean; mentions: boolean; liveEvents: boolean; readReceipts: boolean };

/** UI, Web and Electron share this boundary; credentials stay in the adapter. */
export interface CollaborationClient {
  readonly mode: 'startup' | 'legacy';
  readonly endpoint: string;
  readonly capabilities: Capabilities;
  me(signal?: AbortSignal): Promise<Principal>;
  rooms(signal?: AbortSignal): Promise<RoomPage>;
  messages(roomId: string, options?: { before?: number; firstUnread?: boolean; signal?: AbortSignal }): Promise<MessagePage>;
  send(roomId: string, intent: SendIntent, signal?: AbortSignal): Promise<Message>;
  people(signal?: AbortSignal): Promise<Principal[]>;
  members(roomId: string, signal?: AbortSignal): Promise<Principal[]>;
  preferences(roomId: string, values: { pinned?: boolean; muted?: boolean; read_seq?: number }, signal?: AbortSignal): Promise<void>;
  createRoom(title: string, signal?: AbortSignal): Promise<Room>;
  direct(principalId: string, signal?: AbortSignal): Promise<Room>;
  documents(signal?: AbortSignal): Promise<Document[]>;
  document(roomId: string, documentId: string, signal?: AbortSignal): Promise<DocumentContent>;
  events(after: number, signal?: AbortSignal): Promise<EventPage>;
  close(): void;
}
