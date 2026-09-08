/** Stable UI action IDs refer to domain capabilities, never privileged renderer handlers.
 * These IDs are an adapter migration inventory, not a declaration of API parity. */
export const clientActions = [
  { id: 'im.messages.list', navigation: 'messages', api: 'GET /v1/rooms/:room_id/messages', startup: true, legacy: true },
  { id: 'im.messages.send', navigation: 'messages', api: 'POST /v1/rooms/:room_id/messages', startup: true, legacy: true },
  { id: 'im.messages.reply', navigation: 'messages', api: 'POST /api/im/rooms/:room_id/messages (reply_to)', startup: false, legacy: true },
  { id: 'im.messages.reactions.toggle', navigation: 'messages', api: 'POST /api/im/rooms/:room_id/messages/:message_id/reactions', startup: false, legacy: true },
  { id: 'im.emoji.list', navigation: 'messages', api: 'GET /api/im/emoji', startup: false, legacy: true },
  { id: 'im.rooms.list', navigation: 'messages', api: 'GET /v1/rooms', startup: true, legacy: true },
  { id: 'im.rooms.create', navigation: 'messages', api: 'POST /api/im/rooms', startup: false, legacy: true },
  { id: 'im.rooms.preferences.update', navigation: 'messages', api: 'PATCH /api/im/rooms/:room_id/preferences', startup: false, legacy: true },
  { id: 'im.direct.open', navigation: 'agents', api: 'POST /api/im/rooms/direct', startup: false, legacy: true },
  { id: 'directory.principals.list', navigation: 'agents', api: 'GET /api/im/principals', startup: false, legacy: true },
  { id: 'documents.list', navigation: 'docs', api: 'GET /api/im/library', startup: false, legacy: true },
  { id: 'documents.read', navigation: 'docs', api: 'GET /api/im/rooms/:room_id/documents/:document_id', startup: false, legacy: true },
  { id: 'transport.rongcloud.connect', navigation: null, api: 'POST /v1/transport/rongcloud/session', startup: true, legacy: false },
] as const;
export const navigationIds = ['messages', 'agents', 'docs', 'contacts', 'tasks', 'workbench', 'meetings', 'calendar', 'mail', 'attendance', 'approvals', 'minutes', 'settings', 'enterprise'] as const;
