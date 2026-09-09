import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { WorkspaceInvitations, type WorkspaceInvitationsProps } from './WorkspaceInvitations';
import { WorkspaceInvitationDialog } from './WorkspaceInvitationDialog';
import type { WorkspaceInvitation } from './types';
const code = `rji_${'A'.repeat(43)}`;
const item: WorkspaceInvitation = { id: 'invite-1', workspaceId: 'space-1', createdBy: 'person', createActionId: 'action', role: 'member', status: 'pending', createdAt: '2026-09-09T01:00:00Z', expiresAt: '2099-09-09T02:00:00Z' };
const space = { id: 'space-1', title: '真实团队', role: 'owner' };
function props(mode: 'join' | 'invite' = 'invite'): WorkspaceInvitationsProps {
  return { mode, workspaces: [space], onSelectWorkspace: vi.fn(), onOpenWorkspace: vi.fn(), model: { scopeKey: 'scope-A', workspace: space, invitations: [item], loading: false, error: undefined, canCreate: true, canRevoke: true, canAccept: true, canReconcile: true, operation: undefined, issuedCode: undefined, onCreate: vi.fn(async () => {}), onAccept: vi.fn(async () => {}), onRevoke: vi.fn(async () => {}), onReconcile: vi.fn(async () => {}), onRefresh: vi.fn(async () => {}) } };
}
afterEach(() => { cleanup(); delete window.renjiDesktop; vi.restoreAllMocks(); });
describe('workspace invitation UI', () => {
  it('copies only a returned live invitation, with an explicit user button', async () => {
    const p = props(), copy = vi.fn(async () => {}); Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: copy } });
    p.model.issuedCode = { code, invitationId: item.id, workspaceId: space.id };
    render(<WorkspaceInvitations {...p} />); expect(copy).not.toHaveBeenCalled(); fireEvent.click(screen.getByRole('button', { name: '复制邀请码' })); await screen.findByRole('button', { name: '已复制' }); expect(copy).toHaveBeenCalledOnce(); expect(copy).toHaveBeenCalledWith(code);
    expect(document.querySelector(`a[href*="${code}"]`)).toBeNull(); expect(document.body.textContent).not.toContain(code);
  });
  it('does not expose a fake recoverable code or fake members when there is no issue receipt', () => {
    const p = props(); render(<WorkspaceInvitations {...p} />); expect(screen.queryByRole('button', { name: '复制邀请码' })).toBeNull(); expect(screen.getByText('一次性成员邀请')).toBeTruthy();
  });
  it('requires an explicit confirmation before revoking and cannot create again while uncertain', async () => {
    const p = props(); const h = render(<WorkspaceInvitations {...p} />); fireEvent.click(screen.getByRole('button', { name: '撤销' })); expect(p.model.onRevoke).not.toHaveBeenCalled(); fireEvent.click(screen.getByRole('button', { name: '确认撤销' })); await waitFor(() => expect(p.model.onRevoke).toHaveBeenCalledWith(item.id, 'scope-A'));
    p.model.operation = { status: 'unknown', kind: 'create', message: '原请求待核对' }; h.rerender(<WorkspaceInvitations {...p} />);
    expect((screen.getByRole('button', { name: '创建一次性邀请' }) as HTMLButtonElement).disabled).toBe(true); fireEvent.click(screen.getByRole('button', { name: '核对原操作' })); await waitFor(() => expect(p.model.onReconcile).toHaveBeenCalledWith('scope-A'));
  });
  it('keeps joining available for an empty registered account without inventing an organization', async () => {
    const p = props('join'); p.workspaces = []; p.model.workspace = undefined;
    render(<WorkspaceInvitations {...p} />); const input = screen.getByLabelText('一次性邀请码'); fireEvent.change(input, { target: { value: code } }); fireEvent.click(screen.getByRole('button', { name: '加入工作空间' }));
    await waitFor(() => expect(p.model.onAccept).toHaveBeenCalledWith(code, 'scope-A')); expect((input as HTMLInputElement).value).toBe('');
  });
  it('does not submit or duplicate an invitation during IME composition', async () => {
    const p = props('join'); render(<WorkspaceInvitations {...p} />); const input = screen.getByLabelText('一次性邀请码'); fireEvent.change(input, { target: { value: code } }); fireEvent.compositionStart(input); fireEvent.submit(input.closest('form')!); expect(p.model.onAccept).not.toHaveBeenCalled(); fireEvent.compositionEnd(input); fireEvent.submit(input.closest('form')!); fireEvent.submit(input.closest('form')!); await waitFor(() => expect(p.model.onAccept).toHaveBeenCalledTimes(1));
  });
  it('clears the secret input and clipboard feedback when identity changes', () => {
    const p = props('join'), h = render(<WorkspaceInvitations {...p} />); fireEvent.change(screen.getByLabelText('一次性邀请码'), { target: { value: code } });
    h.rerender(<WorkspaceInvitations {...p} model={{ ...p.model, scopeKey: 'scope-B' }} />); expect((screen.getByLabelText('一次性邀请码') as HTMLInputElement).value).toBe(''); expect(p.model.onAccept).not.toHaveBeenCalled();
  });
  it('shows the actual joined workspace entry only after confirmed membership', () => {
    const p = props('join'); p.model.operation = { kind: 'accept', status: 'succeeded', message: '已加入真实团队', workspaceId: space.id }; render(<WorkspaceInvitations {...p} />); fireEvent.click(screen.getByRole('button', { name: '查看工作空间' })); expect(p.onOpenWorkspace).toHaveBeenCalledWith(space.id, 'scope-A');
  });
  it('disables expiry and workspace changes for an unresolved original invite', () => {
    const p = props(); p.model.operation = { kind: 'create', status: 'unknown', message: '原请求未知' }; render(<WorkspaceInvitations {...p} />);
    expect((screen.getByLabelText('工作空间') as HTMLSelectElement).disabled).toBe(true); expect((screen.getByLabelText('邀请码有效期') as HTMLSelectElement).disabled).toBe(true);
  });
  it('marks copied only after the desktop confirms, and an unmounted identity cannot display late copy status', async () => {
    let finish!: (value: { written: boolean }) => void;
    window.renjiDesktop = { platform: 'darwin', connectRongCloud: vi.fn(), disconnectRongCloud: vi.fn(), onRongCloud: vi.fn(), writeClipboardText: vi.fn(() => new Promise<{ written: boolean }>(resolve => { finish = resolve; })) };
    const p = props(); p.model.issuedCode = { code, invitationId: item.id, workspaceId: space.id };
    const h = render(<WorkspaceInvitations {...p} />); fireEvent.click(screen.getByRole('button', { name: '复制邀请码' })); expect(screen.queryByRole('button', { name: '已复制' })).toBeNull();
    h.rerender(<WorkspaceInvitations {...p} model={{ ...p.model, scopeKey: 'scope-B', issuedCode: undefined }} />); finish({ written: true });
    await waitFor(() => expect(screen.queryByRole('button', { name: '已复制' })).toBeNull()); expect(document.body.textContent).not.toContain(code);
  });
  it('uses one accessible dialog heading with both close controls outside the scrolling invitation body', () => {
    const onOpenChange = vi.fn(); render(<WorkspaceInvitationDialog {...props()} open onOpenChange={onOpenChange} />);
    expect(screen.getAllByRole('heading', { name: '邀请同事' })).toHaveLength(1); expect(screen.getByRole('dialog', { name: '邀请同事' })).toBeTruthy();
    const corner = screen.getByRole('button', { name: '关闭邀请窗口' }), footer = screen.getByRole('button', { name: '关闭' });
    expect(corner.closest('.wi-dialog-body')).toBeNull(); expect(footer.closest('.wi-dialog-body')).toBeNull();
    fireEvent.click(corner); expect(onOpenChange).toHaveBeenCalledWith(false); onOpenChange.mockClear(); fireEvent.click(footer); expect(onOpenChange).toHaveBeenCalledWith(false);
  });
});
