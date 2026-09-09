import { describe, expect, it, vi } from 'vitest';
import { StartupClient, validInvitationCode } from './api';
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const code = `rji_${'A'.repeat(43)}`;
const actor = { id: id(1), kind: 'human', display_name: '本人' };
const item = { id: id(4), workspace_id: id(2), created_by: id(1), create_action_id: id(3), role: 'member', status: 'pending', created_at: '2026-09-09T01:00:00Z', expires_at: '2026-09-10T01:00:00Z' };
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers: { 'Cache-Control': 'no-store' } });
const capIds = ['workspace.invitation.list', 'workspace.invitation.create', 'workspace.invitation.revoke', 'workspace.invitation.accept', 'workspace.invitation.action.read'];
const receipt = (patch = {}) => ({ invitation: item, replayed: false, code_available: true, code, ...patch });
const accepted = (patch = {}) => ({ invitation: { ...item, status: 'accepted', accepted_by: id(1), accepted_at: '2026-09-09T02:00:00Z' }, workspace_id: id(2), principal_id: id(1), role: 'member', already_member: false, execution_scope_extended: false, code_available: false, replayed: false, ...patch });
async function connect(next: typeof fetch, caps = capIds) {
  const fetcher = vi.fn(async (url: RequestInfo | URL, init?: RequestInit) => String(url).endsWith('/me') ? json({ principal: actor }) : String(url).endsWith('/capabilities') ? json({ schema: 'renji.capabilities.v1', capabilities: caps.map(id => ({ id, version: '1', available: true, protocols: { api: true } })) }) : next(url, init));
  const client = new StartupClient('https://work.example', async () => 'synthetic', fetcher); await client.me(); return client;
}
describe('workspace invitation API contracts', () => {
  it('requires explicit capabilities and a canonical high-entropy code before any request', async () => {
    const fetcher = vi.fn(); const noCap = await connect(fetcher, []);
    await expect(noCap.acceptInvitation({ actionId: id(3), code })).rejects.toMatchObject({ status: 501 });
    const c = await connect(fetcher);
    for (const invalid of ['raw text', `${code}A`, code.slice(0, -1) + 'B', 'https://work.example/' + code]) await expect(c.acceptInvitation({ actionId: id(3), code: invalid })).rejects.toMatchObject({ status: 422 });
    expect(validInvitationCode(` ${code} `)).toBe(true); expect(fetcher).not.toHaveBeenCalled();
  });
  it('requires action.read separately from write capabilities', async () => {
    const fetcher = vi.fn(); const c = await connect(fetcher, capIds.filter(id => id !== 'workspace.invitation.action.read'));
    await expect(c.invitationAction(id(3))).rejects.toMatchObject({ status: 501 }); expect(fetcher).not.toHaveBeenCalled();
  });
  it('creates and replays only the original action, with the code available once', async () => {
    const fetcher = vi.fn().mockResolvedValueOnce(json(receipt())).mockResolvedValueOnce(json(receipt({ code: undefined, code_available: false, replayed: true })));
    const c = await connect(fetcher), intent = { actionId: id(3), workspaceId: id(2), expiresInSeconds: 86400 };
    expect(await c.createInvitation(intent)).toMatchObject({ code, codeAvailable: true });
    expect(await c.createInvitation(intent)).toMatchObject({ codeAvailable: false, replayed: true });
    expect(fetcher.mock.calls.map(call => JSON.parse(call[1]!.body))).toEqual([{ action_id: id(3), expires_in_seconds: 86400 }, { action_id: id(3), expires_in_seconds: 86400 }]);
  });
  it.each([{ invitation: { ...item, workspace_id: id(5) } }, { invitation: { ...item, created_by: id(5) } }, { replayed: true }, { code_available: false }])('rejects a wrong-scope or contradictory issue receipt %j', async patch => {
    const c = await connect(async () => json(receipt(patch)));
    await expect(c.createInvitation({ actionId: id(3), workspaceId: id(2), expiresInSeconds: 86400 })).rejects.toMatchObject({ status: 502 });
  });
  it('accepts in a POST body only, never putting the code in URL or result', async () => {
    const fetcher = vi.fn(async (_url: RequestInfo | URL, _init?: RequestInit) => json(accepted())); const c = await connect(fetcher);
    const result = await c.acceptInvitation({ actionId: id(3), code });
    expect(result).toMatchObject({ principalId: id(1), workspaceId: id(2), executionScopeExtended: false });
    expect(String(fetcher.mock.calls[0][0])).toBe('https://work.example/v1/workspace-invitations/accept');
    expect(JSON.parse(fetcher.mock.calls[0][1]!.body as string)).toEqual({ action_id: id(3), code }); expect(JSON.stringify(result)).not.toContain(code);
  });
  it.each([{ principal_id: id(7) }, { workspace_id: id(7) }, { execution_scope_extended: true }, { code_available: true, code }])('rejects unbound accepting identity and authority %j', async patch => {
    const c = await connect(async () => json(accepted(patch))); await expect(c.acceptInvitation({ actionId: id(3), code })).rejects.toMatchObject({ status: 502 });
  });
  it('reads code-free action results and refuses a code-bearing recovery receipt', async () => {
    const fetcher = vi.fn().mockResolvedValueOnce(json({ action_id: id(3), kind: 'workspace.invitation.accept', receipt: accepted({ replayed: true }) })).mockResolvedValueOnce(json({ action_id: id(3), kind: 'workspace.invitation.create', receipt: receipt({ replayed: true }) }));
    const c = await connect(fetcher); expect(await c.invitationAction(id(3))).toMatchObject({ kind: 'accept', actionId: id(3) }); await expect(c.invitationAction(id(3))).rejects.toMatchObject({ status: 502 });
    expect(fetcher.mock.calls.every(call => !String(call[0]).includes(code))).toBe(true);
  });
  it('follows invite metadata pages and rejects a foreign workspace without extra message requests', async () => {
    const fetcher = vi.fn().mockResolvedValueOnce(json({ invitations: [item], cursor: id(4) })).mockResolvedValueOnce(json({ invitations: [{ ...item, id: id(5) }], cursor: '' })).mockResolvedValueOnce(json({ invitations: [{ ...item, workspace_id: id(7) }], cursor: '' }));
    const c = await connect(fetcher); expect(await c.workspaceInvitations(id(2))).toHaveLength(2); await expect(c.workspaceInvitations(id(2))).rejects.toMatchObject({ status: 502 });
    expect(fetcher.mock.calls[1][0]).toContain(`after=${id(4)}`);
  });
  it('permanently retires an invitation result after identity logout', async () => {
    let done!: (value: Response) => void; const c = await connect(() => new Promise<Response>(resolve => { done = resolve; }));
    const result = c.acceptInvitation({ actionId: id(3), code }); await Promise.resolve(); c.close(); done(json(accepted())); await expect(result).rejects.toMatchObject({ name: 'AbortError' });
  });
});
