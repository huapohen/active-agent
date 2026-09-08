// @vitest-environment node
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import { randomBytes, randomUUID } from 'node:crypto';
import { expect, it } from 'vitest';
import { LegacyClient } from './api';

const require = createRequire(import.meta.url);
const { createNativeIM } = require(fileURLToPath(new URL('../../../../doc_free/native-im.js', import.meta.url)));

it('runs the Web adapter against real Doc Free native auth, replies, reaction toggles and all catalog pages on an isolated HTTP port', async () => {
  const temporary = await mkdtemp(join(tmpdir(), 'renji-web-message-native-'));
  const admin = randomBytes(32).toString('hex');
  const native = createNativeIM({ file: join(temporary, 'native.json'), adminToken: admin, workspace: { handle: async () => { throw new Error('Unexpected document operation in isolated fixture'); } } });
  const server = createServer(async (request, response) => {
    try {
      const url = new URL(request.url!, 'http://fixture'); let body = '';
      for await (const chunk of request) { body += chunk; if (body.length > 100000) throw new Error('Fixture input exceeded bound'); }
      const token = request.headers.authorization?.replace(/^Bearer /, '') ?? '';
      const result = await native.handle(request.method, url.pathname, body ? JSON.parse(body) : {}, token, url.searchParams);
      response.setHeader('Content-Type', 'application/json'); response.end(JSON.stringify(result));
    } catch (error: unknown) {
      const failure = error as { status?: number; code?: string };
      response.statusCode = failure.status || 500; response.setHeader('Content-Type', 'application/json'); response.end(JSON.stringify({ code: failure.code || 'fixture_failed' }));
    }
  });
  const clients: LegacyClient[] = [];
  try {
    const human = await native.handle('POST', '/api/im/admin/principals', { name: '合成界面验收人员', kind: 'human' }, admin);
    const agent = await native.handle('POST', '/api/im/admin/principals', { name: '合成界面验收Agent', kind: 'agent' }, admin);
    const outside = await native.handle('POST', '/api/im/admin/principals', { name: '合成群外人员', kind: 'human' }, admin);
    server.listen(0, '127.0.0.1'); await once(server, 'listening');
    const address = server.address(); if (!address || typeof address === 'string') throw new Error('Fixture address unavailable');
    const endpoint = `http://127.0.0.1:${address.port}`;
    for (const identity of [human, agent, outside]) clients.push(new LegacyClient(endpoint, async () => identity.token));
    const [owner, coworker, foreign] = clients;
    const room = await owner.createRoom('Web消息交互合成验收');
    await native.handle('POST', `/api/im/rooms/${room.id}/members`, { principal_id: agent.principal.id }, human.token);
    const original = await owner.send(room.id, { actionId: randomUUID(), content: '合成源消息，不涉及真实工作内容', mentions: [] });
    const replyIntent = { actionId: randomUUID(), content: 'Agent 原生回复合成验收', mentions: [human.principal.id], replyTo: original.id };
    const reply = await coworker.send(room.id, replyIntent), replay = await coworker.send(room.id, replyIntent);
    expect(reply.id).toBe(replay.id); expect(reply.replyTo).toBe(original.id);
    expect((await owner.messages(room.id)).messages).toHaveLength(2);
    const first = await owner.react(room.id, original.id, 'feishu:SMILE'); expect(first.reactions?.['feishu:SMILE']).toEqual([human.principal.id]);
    const both = await coworker.react(room.id, original.id, 'feishu:SMILE'); expect(both.reactions?.['feishu:SMILE']).toEqual([human.principal.id, agent.principal.id]);
    const removed = await owner.react(room.id, original.id, 'feishu:SMILE'); expect(removed.reactions?.['feishu:SMILE']).toEqual([agent.principal.id]);
    await expect(foreign.react(room.id, original.id, '👍')).rejects.toMatchObject({ status: 403 });
    await expect(coworker.send(room.id, { ...replyIntent, actionId: randomUUID(), replyTo: `msg-${randomUUID()}` })).rejects.toMatchObject({ status: 422 });
    const ids: string[] = []; let offset: number | undefined = 0;
    while (offset !== undefined) { const page = await coworker.emoji({ offset }); expect(page.catalogCount).toBe(4126); ids.push(...page.entries.map(entry => entry.id)); offset = page.nextOffset; }
    expect(ids).toHaveLength(4126); expect(new Set(ids).size).toBe(4126); expect(ids.filter(id => id.startsWith('feishu:'))).toHaveLength(182);
    expect((await owner.emoji({ query: 'feishu:SMILE' })).entries.some(entry => entry.id === 'feishu:SMILE')).toBe(true);
    expect((await owner.emoji({ category: '经典表情' })).total).toBe(182);
  } finally {
    clients.forEach(client => client.close());
    server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(temporary, { recursive: true, force: true });
  }
}, 15000);
