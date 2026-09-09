import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  CommercialOnboarding, CommercialProfileForm, CommercialRoomForm, CommercialWorkspaceForm,
  type CommercialOnboardingProps, type CommercialProfileFormProps, type CommercialRoomFormProps,
  type CommercialWorkspaceFormProps,
} from './CommercialOnboarding';
import type { Principal } from './types';

afterEach(cleanup);
const me: Principal = { id: 'human-1', kind: 'human', displayName: '新同事' };
const human: Principal = { id: 'human-2', kind: 'human', displayName: '陈同事' };
const agent: Principal = { id: 'agent-1', kind: 'agent', displayName: '项目助理' };
const workspace = { id: 'workspace-1', title: '真实团队', role: 'owner' };
const scopeKey = 'session-1';
const ready = { scopeKey, workspaceId: workspace.id, status: 'ready' as const };

const profileProps = (overrides: Partial<CommercialProfileFormProps> = {}): CommercialProfileFormProps => ({ scopeKey, me, enabled: true, onSubmit: vi.fn(), ...overrides });
const workspaceProps = (overrides: Partial<CommercialWorkspaceFormProps> = {}): CommercialWorkspaceFormProps => ({ scopeKey, enabled: true, onSubmit: vi.fn(), ...overrides });
const roomProps = (overrides: Partial<CommercialRoomFormProps> = {}): CommercialRoomFormProps => ({ scopeKey, me, workspace, members: [me, human, agent], membersLoad: ready, enabled: true, onSubmit: vi.fn(), ...overrides });
const onboardingProps = (overrides: Partial<CommercialOnboardingProps> = {}): CommercialOnboardingProps => ({ scopeKey, me, workspaces: [workspace], workspaceLoad: { scopeKey, status: 'ready' }, selectedWorkspaceId: workspace.id, members: [me], membersLoad: ready, canRename: true, canCreateWorkspace: true, canCreateRoom: true, onRename: vi.fn(), onCreateWorkspace: vi.fn(), onCreateRoom: vi.fn(), onSelectWorkspace: vi.fn(), ...overrides });
const isDisabled = (name: string) => (screen.getByRole('button', { name }) as HTMLButtonElement).disabled;
const enter = (label: string, value: string) => fireEvent.change(screen.getByRole('textbox', { name: label }), { target: { value } });

describe('real workspace onboarding', () => {
  it('shows the authenticated name and an honest empty workspace without invented people or organizations', () => {
    render(<CommercialOnboarding {...onboardingProps({ workspaces: [], selectedWorkspaceId: undefined, members: [], membersLoad: { scopeKey, workspaceId: '', status: 'ready' } })} />);
    expect(screen.getByRole('heading', { name: '欢迎，新同事' })).toBeTruthy();
    expect(screen.getByText('你还没有加入工作空间。创建后，可以在其中建立会话。')).toBeTruthy();
    expect(screen.queryByRole('checkbox')).toBeNull();
    expect(screen.queryByText('真实团队')).toBeNull();
    expect(isDisabled('创建群聊')).toBe(true);
    expect(screen.queryByText(/商业/)).toBeNull();
  });

  it('selects only a real workspace and prevents switching while an existing operation is pending', () => {
    const props = onboardingProps({ workspaces: [workspace, { id: 'workspace-2', title: '第二团队', role: 'member' }] });
    const view = render(<CommercialOnboarding {...props} />);
    fireEvent.click(screen.getByRole('button', { name: '第二团队 成员' }));
    expect(props.onSelectWorkspace).toHaveBeenCalledWith('workspace-2', scopeKey);
    view.rerender(<CommercialOnboarding {...props} roomState={{ scopeKey, status: 'pending', submitted: { workspaceId: workspace.id, title: '正在创建', memberIds: [me.id] } }} />);
    fireEvent.click(screen.getByRole('button', { name: '第二团队 成员' }));
    expect(props.onSelectWorkspace).toHaveBeenCalledTimes(1);
    expect((screen.getByRole('textbox', { name: '昵称' }) as HTMLInputElement).disabled).toBe(true);
    expect((screen.getByRole('textbox', { name: '工作空间名称' }) as HTMLInputElement).disabled).toBe(true);
  });

  it('does not show stale workspace contents or errors after changing identities', () => {
    const props = onboardingProps({ workspaceLoad: { scopeKey: 'old-session', status: 'error', message: '旧组织机密错误' } });
    render(<CommercialOnboarding {...props} />);
    expect(screen.queryByText('真实团队')).toBeNull();
    expect(screen.queryByText('旧组织机密错误')).toBeNull();
    expect(screen.queryByRole('checkbox')).toBeNull();
    expect(screen.getByText('正在读取工作空间…')).toBeTruthy();
  });

  it('accepts a legitimate workspace with only the current member', async () => {
    const props = roomProps({ members: [me] });
    render(<CommercialRoomForm {...props} />);
    expect(screen.getByText('当前工作空间只有你，也可以先创建群聊开始协作。')).toBeTruthy();
    enter('群聊名称', '  起步协作  ');
    expect(isDisabled('创建群聊')).toBe(false);
    fireEvent.click(screen.getByRole('button', { name: '创建群聊' }));
    await waitFor(() => expect(props.onSubmit).toHaveBeenCalledWith({ workspaceId: workspace.id, title: '起步协作', memberIds: [me.id] }, scopeKey));
  });

  it('selects real humans and Agents with the same controls and always includes self exactly once', async () => {
    const props = roomProps({ members: [me, human, agent, me] });
    render(<CommercialRoomForm {...props} />);
    enter('群聊名称', '混合协作');
    fireEvent.click(screen.getByRole('checkbox', { name: '陈同事 人类同事' }));
    fireEvent.click(screen.getByRole('checkbox', { name: '项目助理 Agent 同事' }));
    enter('搜索工作空间同事', 'Agent');
    expect(screen.queryByRole('checkbox', { name: '陈同事 人类同事' })).toBeNull();
    expect(screen.getByRole('checkbox', { name: '项目助理 Agent 同事' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: '创建群聊' }));
    await waitFor(() => expect(props.onSubmit).toHaveBeenCalledWith({ workspaceId: workspace.id, title: '混合协作', memberIds: [agent.id, me.id, human.id] }, scopeKey));
  });

  it('removes a revoked member from the draft before sending and does not invent self if membership is absent', async () => {
    const props = roomProps();
    const view = render(<CommercialRoomForm {...props} />);
    enter('群聊名称', '当前成员协作');
    fireEvent.click(screen.getByRole('checkbox', { name: '项目助理 Agent 同事' }));
    view.rerender(<CommercialRoomForm {...props} members={[me, human]} />);
    expect(screen.queryByRole('checkbox', { name: '项目助理 Agent 同事' })).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: '创建群聊' }));
    await waitFor(() => expect(props.onSubmit).toHaveBeenCalledWith({ workspaceId: workspace.id, title: '当前成员协作', memberIds: [me.id] }, scopeKey));
    view.rerender(<CommercialRoomForm {...props} members={[human]} />);
    expect(screen.getByRole('alert').textContent).toContain('当前身份不在此工作空间');
    expect(isDisabled('创建群聊')).toBe(true);
  });

  it.each(['wrong-workspace', 'wrong-identity', 'error'] as const)('discards stale member data when the source is %s', kind => {
    const membersLoad = kind === 'wrong-workspace' ? { ...ready, workspaceId: 'foreign-workspace' } : kind === 'wrong-identity' ? { ...ready, scopeKey: 'old-session' } : { ...ready, status: 'error' as const, message: '目录已失效' };
    render(<CommercialRoomForm {...roomProps({ membersLoad })} />);
    expect(screen.queryByRole('checkbox')).toBeNull();
    expect(screen.queryByText('陈同事')).toBeNull();
    expect(screen.queryByText('项目助理')).toBeNull();
    expect(isDisabled('创建群聊')).toBe(true);
  });

  it('clears the room title and selected members when the workspace changes', () => {
    const props = roomProps(); const view = render(<CommercialRoomForm {...props} />);
    enter('群聊名称', '旧工作空间草稿'); fireEvent.click(screen.getByRole('checkbox', { name: '陈同事 人类同事' }));
    view.rerender(<CommercialRoomForm {...props} workspace={{ id: 'new-workspace', title: '新工作空间' }} members={[me]} membersLoad={{ ...ready, workspaceId: 'new-workspace' }} />);
    expect((screen.getByRole('textbox', { name: '群聊名称' }) as HTMLInputElement).value).toBe('');
    expect(screen.queryByText('陈同事')).toBeNull();
    expect(screen.getByText('参与同事 · 已选 1 位')).toBeTruthy();
  });
});

describe('original operation and identity boundaries', () => {
  it('freezes an unknown workspace request and invokes only the parent reconciliation callback', async () => {
    const onReconcile = vi.fn(); const props = workspaceProps({ onReconcile, state: { scopeKey, status: 'unknown', submitted: { title: '原工作空间' }, message: '响应尚未确认' } });
    const uuid = vi.spyOn(crypto, 'randomUUID');
    render(<CommercialWorkspaceForm {...props} />);
    const input = screen.getByRole('textbox', { name: '工作空间名称' }) as HTMLInputElement;
    expect(input.value).toBe('原工作空间'); expect(input.disabled).toBe(true);
    fireEvent.submit(screen.getByRole('form', { name: '创建工作空间' })); expect(props.onSubmit).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: '核对原操作' }));
    await waitFor(() => expect(onReconcile).toHaveBeenCalledWith(scopeKey));
    expect(uuid).not.toHaveBeenCalled();
    expect(screen.queryByText(/已创建 /)).toBeNull();
  });

  it('suppresses double submit synchronously before the owner can publish its pending state', async () => {
    let resolve!: () => void; const onSubmit = vi.fn(() => new Promise<void>(done => { resolve = done; }));
    render(<CommercialWorkspaceForm {...workspaceProps({ onSubmit })} />);
    enter('工作空间名称', '新团队');
    const form = screen.getByRole('form', { name: '创建工作空间' }); fireEvent.submit(form); fireEvent.submit(form);
    expect(onSubmit).toHaveBeenCalledTimes(1); expect(isDisabled('正在创建…')).toBe(true);
    await act(async () => { resolve(); });
    expect(screen.queryByText('已创建 新团队')).toBeNull();
  });

  it('does not expose an arbitrary thrown error or unlock creation after an unknown rejection', async () => {
    const props = workspaceProps({ onSubmit: vi.fn().mockRejectedValue(new Error('private-response-token')), onReconcile: vi.fn() });
    render(<CommercialWorkspaceForm {...props} />); enter('工作空间名称', '需要核对');
    fireEvent.click(screen.getByRole('button', { name: '创建工作空间' }));
    await screen.findByText('操作结果待确认');
    expect(screen.queryByText('private-response-token')).toBeNull(); expect(isDisabled('创建工作空间')).toBe(true);
    fireEvent.submit(screen.getByRole('form', { name: '创建工作空间' })); expect(props.onSubmit).toHaveBeenCalledTimes(1);
  });

  it('does not transfer a pending draft or late error into the next identity', async () => {
    let reject!: (value: Error) => void; const old = workspaceProps({ onSubmit: vi.fn(() => new Promise<void>((_, fail) => { reject = fail; })) });
    const view = render(<CommercialWorkspaceForm {...old} />); enter('工作空间名称', '旧身份私有草稿'); fireEvent.submit(screen.getByRole('form', { name: '创建工作空间' }));
    const next = workspaceProps({ scopeKey: 'session-2' }); view.rerender(<CommercialWorkspaceForm {...next} />);
    await act(async () => { reject(new Error('old-private-error')); });
    expect((screen.getByRole('textbox', { name: '工作空间名称' }) as HTMLInputElement).value).toBe('');
    expect(screen.queryByText('操作结果待确认')).toBeNull(); expect(screen.queryByText('旧身份私有草稿')).toBeNull();
    enter('工作空间名称', '新身份团队'); fireEvent.submit(screen.getByRole('form', { name: '创建工作空间' }));
    await waitFor(() => expect(next.onSubmit).toHaveBeenCalledWith({ title: '新身份团队' }, 'session-2'));
  });

  it('ignores an old identity action receipt and never reveals its result', () => {
    render(<CommercialWorkspaceForm {...workspaceProps({ state: { scopeKey: 'old-session', status: 'succeeded', submitted: { title: '旧秘密工作空间' }, result: { id: 'old', title: '旧秘密工作空间' } } })} />);
    expect(screen.queryByText(/旧秘密工作空间/)).toBeNull();
    expect((screen.getByRole('textbox', { name: '工作空间名称' }) as HTMLInputElement).value).toBe('');
    expect(isDisabled('创建工作空间')).toBe(true);
  });

  it('keeps a restricted original room reconciliation reachable without exposing the old title or changing its workspace', async () => {
    const onReconcile = vi.fn(), props = roomProps({ state: { scopeKey, status: 'unknown', submitted: { workspaceId: 'old-workspace', title: '旧会话私有名称', memberIds: ['old-member'] }, message: '旧私有响应' }, onReconcile });
    render(<CommercialRoomForm {...props} />);
    expect(screen.queryByText('旧私有响应')).toBeNull(); expect(screen.queryByText('旧会话私有名称')).toBeNull();
    expect((screen.getByRole('textbox', { name: '群聊名称' }) as HTMLInputElement).value).toBe('');
    expect(screen.queryByRole('checkbox')).toBeNull(); expect(isDisabled('创建群聊')).toBe(true);
    fireEvent.click(screen.getByRole('button', { name: '核对原操作' })); await waitFor(() => expect(onReconcile).toHaveBeenCalledWith(scopeKey));
    expect(props.onSubmit).not.toHaveBeenCalled();
  });

  it('hides the original room title after member access fails but retains the parent-owned reconciliation', async () => {
    const onReconcile = vi.fn();
    render(<CommercialRoomForm {...roomProps({ membersLoad: { ...ready, status: 'error', message: '当前无权读取成员' }, state: { scopeKey, status: 'unknown', submitted: { workspaceId: workspace.id, title: '撤权前的私有名称', memberIds: [me.id, agent.id] } }, onReconcile })} />);
    expect((screen.getByRole('textbox', { name: '群聊名称' }) as HTMLInputElement).value).toBe('');
    expect(screen.queryByText('项目助理')).toBeNull(); expect(screen.getByText('当前无权读取成员')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: '核对原操作' })); await waitFor(() => expect(onReconcile).toHaveBeenCalledWith(scopeKey));
  });

  it('never exposes a restricted old-identity reconciliation to a new session', () => {
    const onReconcile = vi.fn();
    render(<CommercialRoomForm {...roomProps({ state: { scopeKey: 'old-session', status: 'unknown', submitted: { workspaceId: workspace.id, title: '旧身份私有名称', memberIds: [me.id] } }, onReconcile })} />);
    expect((screen.getByRole('textbox', { name: '群聊名称' }) as HTMLInputElement).value).toBe('');
    expect(screen.queryByRole('button', { name: '核对原操作' })).toBeNull(); expect(onReconcile).not.toHaveBeenCalled();
  });

  it('uses only an explicit confirmed room result for entering a conversation', () => {
    const onOpenRoom = vi.fn(); const props = roomProps({ onOpenRoom }); const view = render(<CommercialRoomForm {...props} />);
    expect(screen.queryByRole('button', { name: '进入群聊' })).toBeNull();
    view.rerender(<CommercialRoomForm {...props} state={{ scopeKey, status: 'succeeded', result: { id: 'confirmed-room', workspaceId: workspace.id, title: '已确认群聊' } }} />);
    fireEvent.click(screen.getByRole('button', { name: '进入群聊' })); expect(onOpenRoom).toHaveBeenCalledWith('confirmed-room', scopeKey);
  });

  it('does not repeat a confirmed identical workspace creation without a changed name', () => {
    const props = workspaceProps({ state: { scopeKey, status: 'succeeded', submitted: { title: '已创建团队' }, result: { id: 'created', title: '已创建团队' } } });
    render(<CommercialWorkspaceForm {...props} />);
    expect(isDisabled('创建工作空间')).toBe(true); fireEvent.submit(screen.getByRole('form', { name: '创建工作空间' })); expect(props.onSubmit).not.toHaveBeenCalled();
    enter('工作空间名称', '另一个团队'); expect(isDisabled('创建工作空间')).toBe(false);
  });

  it('does not create the same confirmed room again when Enter submits the persisted form', () => {
    const props = roomProps({ state: { scopeKey, status: 'succeeded', submitted: { workspaceId: workspace.id, title: '已创建协作群', memberIds: [me.id] }, result: { id: 'confirmed-room', workspaceId: workspace.id, title: '已创建协作群' } }, onOpenRoom: vi.fn() });
    render(<CommercialRoomForm {...props} />);
    fireEvent.submit(screen.getByRole('form', { name: '创建群聊' }));
    expect(props.onSubmit).not.toHaveBeenCalled(); expect(screen.getByRole('button', { name: '进入群聊' })).toBeTruthy();
  });

  it('allows a new room intention after an actual change to the confirmed title', async () => {
    const props = roomProps({ state: { scopeKey, status: 'succeeded', submitted: { workspaceId: workspace.id, title: '已创建协作群', memberIds: [me.id] }, result: { id: 'confirmed-room', workspaceId: workspace.id, title: '已创建协作群' } }, onOpenRoom: vi.fn() });
    render(<CommercialRoomForm {...props} />); enter('群聊名称', '新项目群');
    expect(screen.queryByRole('button', { name: '进入群聊' })).toBeNull(); expect(isDisabled('创建群聊')).toBe(false);
    fireEvent.click(screen.getByRole('button', { name: '创建群聊' }));
    await waitFor(() => expect(props.onSubmit).toHaveBeenCalledWith({ workspaceId: workspace.id, title: '新项目群', memberIds: [me.id] }, scopeKey));
  });
});

describe('input validation and composition', () => {
  it('counts Unicode characters rather than UTF-16 code units for the 80-character nickname limit', async () => {
    const props = profileProps(); render(<CommercialProfileForm {...props} />);
    enter('昵称', '🚀'.repeat(80)); expect(isDisabled('保存昵称')).toBe(false);
    fireEvent.click(screen.getByRole('button', { name: '保存昵称' }));
    await waitFor(() => expect(props.onSubmit).toHaveBeenCalledWith({ displayName: '🚀'.repeat(80) }, scopeKey));
    enter('昵称', '🚀'.repeat(81)); expect(isDisabled('保存昵称')).toBe(true);
  });

  it.each(['   ', '昵称\u0001', '昵称\u200d', '昵称\u2028称呼', '昵称\u2029称呼', '昵称\ud800', '同'.repeat(81)])('rejects an invalid nickname without calling the parent', value => {
    const props = profileProps(); render(<CommercialProfileForm {...props} />); enter('昵称', value);
    fireEvent.submit(screen.getByRole('form', { name: '设置昵称' })); expect(props.onSubmit).not.toHaveBeenCalled();
    expect(screen.getByRole('alert').textContent).toContain('1–80');
  });

  it('enforces the actual 240-byte title boundary for multibyte text', async () => {
    const props = workspaceProps(); render(<CommercialWorkspaceForm {...props} />);
    enter('工作空间名称', '汉'.repeat(81)); expect(isDisabled('创建工作空间')).toBe(true);
    fireEvent.submit(screen.getByRole('form', { name: '创建工作空间' })); expect(props.onSubmit).not.toHaveBeenCalled();
    enter('工作空间名称', '汉'.repeat(80)); expect(isDisabled('创建工作空间')).toBe(false);
    fireEvent.submit(screen.getByRole('form', { name: '创建工作空间' })); await waitFor(() => expect(props.onSubmit).toHaveBeenCalledTimes(1));
  });

  it.each(['团队\u2028名称', '团队\u2029名称', '团队\ud800', '团队\u200d名称'])('rejects nonsingle-line or invalid Unicode workspace names', value => {
    const props = workspaceProps(); render(<CommercialWorkspaceForm {...props} />); enter('工作空间名称', value);
    fireEvent.submit(screen.getByRole('form', { name: '创建工作空间' })); expect(props.onSubmit).not.toHaveBeenCalled();
    expect(isDisabled('创建工作空间')).toBe(true);
  });

  it.each(['profile', 'workspace', 'room'] as const)('does not submit %s during Chinese composition confirmation', async kind => {
    const onSubmit = vi.fn();
    if (kind === 'profile') render(<CommercialProfileForm {...profileProps({ onSubmit })} />);
    else if (kind === 'workspace') render(<CommercialWorkspaceForm {...workspaceProps({ onSubmit })} />);
    else render(<CommercialRoomForm {...roomProps({ onSubmit })} />);
    const label = kind === 'profile' ? '昵称' : kind === 'workspace' ? '工作空间名称' : '群聊名称';
    const formName = kind === 'profile' ? '设置昵称' : kind === 'workspace' ? '创建工作空间' : '创建群聊';
    const input = screen.getByRole('textbox', { name: label }); enter(label, '输入中文'); fireEvent.compositionStart(input);
    fireEvent.keyDown(input, { key: 'Enter', isComposing: true, keyCode: 229 }); fireEvent.submit(screen.getByRole('form', { name: formName })); expect(onSubmit).not.toHaveBeenCalled();
    fireEvent.compositionEnd(input); fireEvent.submit(screen.getByRole('form', { name: formName })); await waitFor(() => expect(onSubmit).toHaveBeenCalledTimes(1));
  });

  it('keeps the same safe controls at a narrow viewport without window or document keyboard hooks', () => {
    const listener = vi.spyOn(window, 'addEventListener');
    vi.stubGlobal('innerWidth', 320);
    render(<CommercialOnboarding {...onboardingProps()} />);
    const page = screen.getByRole('region', { name: '开始协作' });
    expect(within(page).getByRole('heading', { name: '工作空间' })).toBeTruthy();
    expect(within(page).getByRole('form', { name: '创建群聊' })).toBeTruthy();
    expect(listener.mock.calls.filter(([name]) => name === 'keydown' || name === 'keyup' || name === 'keypress')).toHaveLength(0);
    vi.unstubAllGlobals();
  });
});
