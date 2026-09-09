'use strict';
const path = require('node:path');
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
function validateConfig(c) {
  if (!c || c.schema !== 'renji.rongcloud.trusted-bridge.v1' || !/^[a-zA-Z0-9_-]{1,128}$/.test(c.bridge_id) || !uuid(c.receiver_id) || !uuid(c.room_id)) throw new Error('bridge_config_invalid');
  for (const key of ['app_key','provider_token','bridge_secret']) if (typeof c[key] !== 'string' || !c[key] || c[key].length > 4096 || /\s/.test(c[key])) throw new Error('bridge_config_invalid');
  if (c.bridge_secret.length < 32 || c.bridge_secret.length > 256 || !Array.isArray(c.message_ids) || c.message_ids.length < 1 || c.message_ids.length > 20 || c.message_ids.some(v=>!uuid(v)) || new Set(c.message_ids).size !== c.message_ids.length) throw new Error('bridge_config_invalid');
  const url = new URL(c.ingress_url);
  if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1' || !url.port || url.username || url.password || url.search || url.hash || url.pathname !== `/internal/transport/rongcloud/${c.bridge_id}`) throw new Error('bridge_config_invalid');
  if (!path.isAbsolute(c.state_dir)) throw new Error('bridge_config_invalid');
  if (c.sdk_mode !== undefined && c.sdk_mode !== 'web' && c.sdk_mode !== 'native') throw new Error('bridge_config_invalid');
  return c;
}
function projectMessage(message, config) {
  if (!message || message.conversationType !== 3 || message.targetId !== config.room_id || !uuid(message.senderUserId) || typeof message.messageUId !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(message.messageUId)) return null;
  const content = message.content;
  if (!content || typeof content !== 'object') return null;
  let pointer, normalized;
  try {
    if (message.messageType === 'RC:TxtMsg') {
      if (typeof content.content !== 'string' || typeof content.extra !== 'string') return null;
      pointer = JSON.parse(content.extra);
      if (pointer.schema !== 'renji.message.v1') return null;
      normalized = {content: content.content, extra: content.extra};
    } else if (message.messageType === 'RC:CmdMsg') {
      if (content.name !== 'renji.message.reaction' || typeof content.data !== 'string') return null;
      pointer = JSON.parse(content.data);
      if (pointer.schema !== 'renji.reaction.v1') return null;
      normalized = {name: content.name, data: content.data};
    } else return null;
  } catch { return null; }
  if (pointer.room_id !== config.room_id || !config.message_ids.includes(pointer.message_id)) return null;
  const received = Number.isSafeInteger(message.receivedTime) && message.receivedTime >= 0 ? message.receivedTime : 0;
  return {schema:'renji.rongcloud.sdk-received.v1',message_uid:message.messageUId,conversation_type:3,target_id:message.targetId,sender_id:message.senderUserId,message_type:message.messageType,content:normalized,received_time:received};
}
module.exports = {validateConfig,projectMessage};
