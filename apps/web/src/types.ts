export type Principal = { id: string; kind: 'human' | 'agent'; displayName: string; organization?: string; profession?: string; category?: string };
export type Receipt = { read?: number; total?: number };
export type ReplySummary = { messageId: string; roomId: string; authorId: string; authorName: string; authorKind: 'human' | 'agent'; excerpt: string; seq: number };
export type ReactionSummary = { emoji: string; count: number; selected: boolean };
export type ReactionIntent = { actionId: string; emoji: string; active: boolean; scopeEpoch?: number };
export type ReactionReceipt = { roomId: string; messageId: string; principalId: string; emoji: string; active: boolean; version: number; replayed: boolean };
export type ReactionPage = { summaries: ReactionSummary[]; version: number; nextAfter?: string };
export type Message = { id: string; roomId: string; authorId: string; authorName?: string; authorKind?: string; content: string; seq: number; createdAt: string; retracted: boolean; hidden?: boolean; receipt?: Receipt; mentions: string[]; isVoice?: boolean; attachmentCount?: number; replyTo?: string; reply?: ReplySummary; reactionSummaries?: ReactionSummary[]; reactionVersion?: number; reactionsHasMore?: boolean; reactions?: Record<string, string[]> };
export type RoomPreview = { id: string; roomId: string; authorId: string; authorName: string; authorKind: 'human' | 'agent'; excerpt: string; seq: number; createdAt: string; contentKind: 'text' };
export type Room = { id: string; workspaceId?: string; title: string; kind: string; version: number; scopeEpoch?: number; stopped?: boolean; unread?: number; pinned?: boolean; muted?: boolean; firstUnreadSeq?: number; lastMessage?: Message; preview?: RoomPreview | null; previewState?: 'ready' | 'empty' | 'unavailable' };
export type RoomPage = { rooms: Room[]; cursor: number };
export type MessagePage = { messages: Message[]; hasMoreBefore: boolean; hasMoreAfter: boolean; firstUnreadSeq?: number };
export type SendIntent = { actionId: string; content: string; mentions: string[]; scopeEpoch?: number; replyTo?: string };
export type Emoji = { id: string; name: string; text: string; category: string; asset?: string; revision?: string };
export type EmojiPage = { entries: Emoji[]; categories: string[]; total: number; catalogCount: number; revision?: string; nextOffset?: number };
export type Document = { id: string; roomId: string; roomIds?: string[]; title: string; revision?: number; updatedAt?: string };
export type DocumentContent = Document & { content: string; revision: number; contentHash: string };
export type EventPage = { cursor: number; changed: boolean; resetRequired: boolean };
export type Capabilities = { directory: boolean; documents: boolean; roomPreferences: boolean; createRoom: boolean; mentions: boolean; liveEvents: boolean; readReceipts: boolean; reactions: boolean; replies: boolean };

export type Profile = { principal: Principal; version: number };
export type WorkspaceInfo = { id: string; title: string; role?: string; createdAt?: string };
export type WorkspaceMember = Principal & { role: string };
export type ProfileIntent = { actionId: string; displayName: string; expectedVersion: number };
export type WorkspaceIntent = { actionId: string; title: string };
export type RoomIntent = { actionId: string; workspaceId: string; title: string; memberIds: string[] };
export type WorkspaceInvitation = { id: string; workspaceId: string; createdBy: string; createActionId: string; role: 'member'; status: 'pending' | 'accepted' | 'revoked' | 'expired'; createdAt: string; expiresAt: string; acceptedBy?: string; acceptedAt?: string; revokedAt?: string };
export type InvitationCreateIntent = { actionId: string; workspaceId: string; expiresInSeconds: number };
export type InvitationRevokeIntent = { actionId: string; workspaceId: string; invitationId: string };
/** Code is sensitive and must never enter a persistent intent or query cache. */
export type InvitationAcceptIntent = { actionId: string; code: string };
export type InvitationReceipt = { invitation: WorkspaceInvitation; replayed: boolean; codeAvailable: boolean; code?: string };
export type InvitationAcceptance = { invitation: WorkspaceInvitation; workspaceId: string; principalId: string; role: string; alreadyMember: boolean; replayed: boolean; executionScopeExtended: false };
export type InvitationAction = { actionId: string; kind: 'create' | 'revoke'; receipt: InvitationReceipt } | { actionId: string; kind: 'accept'; receipt: InvitationAcceptance };
export interface WorkspaceInvitationClient {
  readonly invitationCapabilities: { list: boolean; create: boolean; revoke: boolean; accept: boolean; actionRead: boolean };
  workspaceInvitations(workspaceId: string, signal?: AbortSignal): Promise<WorkspaceInvitation[]>;
  createInvitation(intent: InvitationCreateIntent, signal?: AbortSignal): Promise<InvitationReceipt>;
  revokeInvitation(intent: InvitationRevokeIntent, signal?: AbortSignal): Promise<InvitationReceipt>;
  acceptInvitation(intent: InvitationAcceptIntent, signal?: AbortSignal): Promise<InvitationAcceptance>;
  invitationAction(actionId: string, signal?: AbortSignal): Promise<InvitationAction>;
}
/** Each operation retains one intent until its receipt is reconciled. */
export interface OnboardingClient {
  readonly onboardingCapabilities: { profileRead: boolean; profileUpdate: boolean; workspaces: boolean; workspaceCreate: boolean; workspaceMembers: boolean; roomMembers: boolean; roomCreate: boolean };
  profile(signal?: AbortSignal): Promise<Profile>;
  updateProfile(intent: ProfileIntent, signal?: AbortSignal): Promise<Profile & { replayed: boolean }>;
  workspaces(signal?: AbortSignal): Promise<WorkspaceInfo[]>;
  workspaceMembers(workspaceId: string, signal?: AbortSignal): Promise<WorkspaceMember[]>;
  createWorkspace(intent: WorkspaceIntent, signal?: AbortSignal): Promise<WorkspaceInfo>;
  createWorkspaceRoom(intent: RoomIntent, signal?: AbortSignal): Promise<Room>;
}

/** UI, Web and Electron share this boundary; credentials stay in the adapter. */
export interface CollaborationClient {
  readonly mode: 'startup' | 'legacy';
  readonly endpoint: string;
  readonly capabilities: Capabilities;
  readonly onboarding?: OnboardingClient;
  readonly invitations?: WorkspaceInvitationClient;
  me(signal?: AbortSignal): Promise<Principal>;
  rooms(signal?: AbortSignal): Promise<RoomPage>;
  messages(roomId: string, options?: { before?: number; firstUnread?: boolean; signal?: AbortSignal }): Promise<MessagePage>;
  send(roomId: string, intent: SendIntent, signal?: AbortSignal): Promise<Message>;
  /** Legacy is a server-side toggle: callers must never automatically retry. */
  react(roomId: string, messageId: string, emojiId: string, signal?: AbortSignal): Promise<Message>;
  message?(roomId: string, messageId: string, signal?: AbortSignal): Promise<Message>;
  setReaction?(roomId: string, messageId: string, intent: ReactionIntent, signal?: AbortSignal): Promise<ReactionReceipt>;
  reactionSummaries?(roomId: string, messageId: string, options?: { after?: string; expectedVersion?: number; signal?: AbortSignal }): Promise<ReactionPage>;
  emojiAsset?(asset: string, revision: string, signal?: AbortSignal): Promise<Blob>;
  emoji(options?: { query?: string; category?: string; offset?: number; revision?: string; signal?: AbortSignal }): Promise<EmojiPage>;
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
