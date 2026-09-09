# 工作空间邀请与真实会话摘要：Web 客户端阶段记录

- 记录时间：2026-09-09 10:31，Asia/Shanghai。
- 本轮基线：`1ea4685b4df3f0a9e9bffd0400c295b2bfb723e1`，提交时间 `2026-09-09T10:00:39+08:00`，说明 `docs(startup): preserve account phase publication and independent receipts`。
- 撰写时本记录描述基线之后尚未提交的客户端实现；以上 SHA 不是本轮功能的实施提交。该撰写时点保留为历史，最终归属见下方补记。
- 范围为 Electron 所载 Web 客户端与浏览器 Web 的共同 React 代码。本子任务未操作 GUI、生产服务、Flutter、融云或真实邀请，也没有调用模型、发送邮件或飞书消息。

## 交互变化

商业账号的头像菜单、消息页加号和工作空间页增加“邀请同事”“加入工作空间”。没有工作空间的新账号也可以从欢迎页进入邀请码加入表单。

邀请页使用当前授权工作空间与真实邀请记录。所有者或管理员可选择 1 小时、24 小时、7 天有效期，创建一次性成员邀请；首次创建的真实返回码通过“复制邀请码”按钮写入剪贴板。页面不生成示例码，也不将邀请码放入链接。撤销需在对应记录中明确确认。

加入表单使用密码式输入，支持粘贴；中文输入法组合中的回车不提交。同步提交锁覆盖异步指纹计算及后续请求，连续点击不会产生第二个意图。加入回执确认后重新读取工作空间、目标空间成员和会话目录，再更新当前空间，并提供“查看工作空间”入口。

加入只获得服务端确认的工作空间成员身份，不自动进入所有群，也不扩展 Agent 的执行来源权限。当前 Web 人类表单不持有 Agent Run，因此不冒充 Agent 发起无 Run 的写入；Agent 通过后端受 Run 管理的同一邀请动作内核参与，后端范围见[邀请内核记录](../../../docs/startup/2026-09-09/WORKSPACE_INVITATION_KERNEL_1025.md)。

## 接口与能力声明

所有请求保留现有 Clerk/Bearer 身份路径，未使用 Legacy 凭据或绕过鉴权。只有 `renji.capabilities.v1` 中版本 `1`、`protocols.api=true`、`available=true` 的明确声明才启用相应能力。

| 行为 | 原生接口 | capability |
| --- | --- | --- |
| 读取邀请元数据 | `GET /v1/workspaces/:id/invitations?after&limit` | `workspace.invitation.list` |
| 创建一次性邀请 | `POST /v1/workspaces/:id/invitations` | `workspace.invitation.create` |
| 撤销邀请 | `POST /v1/workspaces/:id/invitations/:invitation_id/revoke` | `workspace.invitation.revoke` |
| 输入邀请码加入 | `POST /v1/workspace-invitations/accept` | `workspace.invitation.accept` |
| 核对原操作 | `GET /v1/workspace-invitation-actions/:action_id` | `workspace.invitation.action.read` |
| 读取含摘要的会话列表 | `GET /v1/rooms`，沿已有 ID 游标分页 | `room.list` |

写入以稳定 `action_id` 标识，创建附带 `expires_in_seconds`，接受仅在 POST JSON 正文携带原邀请码。动作查询返回当前主体自己的脱敏持久回执，客户端验证返回的 action、kind、工作空间、邀请及接受主体，不把任意返回对象直接当作授权事实。

UI 的新邀请写入还要求原操作查询能力可用，确保响应丢失时有明确核对路径。若该能力缺失，已有 unknown 原意图继续保留，核对按钮禁用并说明服务尚未开放原操作查询；不会偷偷切换认证或创建另一份邀请。

## 一次性邀请码与未知结果

1. 服务端首次成功响应的明文只保留在当前 hook 实例内存中；邀请查询、React Query 缓存与本地意图记录均不保存明文。用户主动复制会使用系统剪贴板，这是明确的分享动作。
2. 创建回执之后还需重新确认当前工作空间管理权限及邀请状态，才提供复制按钮。切换空间、失去管理权限、邀请不再有效或卸载身份作用域会隐藏并清除内存码。
3. 创建动作响应丢失后先查询原 `action_id`。已经创建的邀请只能返回元数据，不能再次读取明文；界面明确提示显式撤销后创建新邀请，不自动补建。
4. 本地 `sessionStorage` 在任何写请求前保存原 action 与必要的非秘密参数。接受操作只保存随机高熵邀请码的 SHA-256 指纹；该指纹仅绑定本地原意图，不是服务端接受凭证，不能代替明文授权。
5. 刷新后接受操作可以仅凭原 action 查询已提交回执。未找到回执仍不是“从未提交”的证明；只有用户重新提供指纹相同的原码，才使用原 action 重放。换一个码不会替换未决原意图。
6. 只有后端保证尚未提交时返回的明确 `invitation_expired`、`invitation_revoked`、`invitation_used` 才允许解除本次接受意图。泛化权限错误、超时、无回执或成功 POST 后的目录读取失败继续保留 unknown。
7. 写入后的授权目录、成员与会话重新读取成功后才显示加入完成。A→B→A 身份变化不会复活旧 hook；失效请求不能把先前身份的内容发布回缓存或 UI。

本地操作编号无法保存时，写请求为零。持久化并不包含密码、Token 或邀请码；文档和测试回执同样不记录真实邀请码。

## 会话列表摘要

Startup 的 `last_message` 被解析为专用 `RoomPreview`，不会伪装成完整 `Message`：

| 服务端状态 | 客户端表现 |
| --- | --- |
| 显式 `last_message:null` | “暂无消息”，没有伪时间 |
| 缺少 `last_message` | “消息摘要暂未提供”，不误报空会话 |
| 完整授权摘要 | 群聊显示真实作者名与 excerpt，时间来自 `created_at` |

客户端检查摘要所属 room、消息及作者 ID、作者种类、正整数 seq、文本种类、240 Unicode 字符上限与有效时间。错房或形状异常会拒绝该响应。列表读取按服务端分页，不为每一行另发历史消息请求；沿已有 ID 顺序展示，不擅自增加服务端未实现的最近消息排序。

主列表只使用服务端给出的真实时间，没有 `now()` 占位值。原有圆形头像组件、Legacy 摘要与隐藏消息处理保留。元数据变更响应可能省略摘要；它与列表显式 null 的含义不同，不借此抹除已有摘要。

## 本轮验证

截至 2026-09-09 10:31，以下均为本地自动化或构建验证，不是原生界面截图验收：

| 范围 | 结果 | 主要覆盖 |
| --- | --- | --- |
| 全 Web 测试 | 200/200，20 文件 | 本轮变化与既有登录、消息、文档、账户和融云桥客户端回归 |
| 新邀请 API | 15 项 | canonical 码输入、能力缺失、真实回执形状、来源身份、分页、动作回读与迟到请求 |
| 新邀请 hook | 13 项 | 明文不落缓存、稳定 action、指纹、unknown、刷新恢复、存储失败、权限撤回、A→B→A 与卸载 |
| 新邀请表单 | 8 项 | 真实复制、无假码、明确撤销、空账号加入、IME、重复提交、换身份和原意图锁 |
| 新会话摘要 | 9 项 | 单次列表读取、真实时间、null/缺字段区别、错房与非法字段、Legacy 隐藏消息 |
| TypeScript 检查 | 通过 | `npm run check --workspace @renji/web` |
| Web 生产构建 | 通过 | `npm run build:web`；主 JS 641.73 kB、gzip 205.48 kB，仍有超过 500 kB 的体积提示 |

本轮新增 45 项，其余 155 项是已有覆盖。全量日志 `/tmp/renji-workspace-invitation-final-web-20260909.log`，检查日志 `/tmp/renji-workspace-invitation-final-check-20260909.log`；构建另以 `/tmp/renji-workspace-invitation-final-build-20260909.log` 记录，不把这些临时日志称为永久归档。

主要代码：[接口适配](../src/api.ts)、[邀请状态与恢复](../src/useWorkspaceInvitations.ts)、[邀请界面](../src/WorkspaceInvitations.tsx)、[加入后的目录刷新](../src/useCommercialAccount.ts)、[应用入口与摘要](../src/App.tsx)。独立测试：[API](../src/invitation-api.test.ts)、[状态恢复](../src/useWorkspaceInvitations.test.tsx)、[表单](../src/WorkspaceInvitations.test.tsx)、[摘要](../src/room-preview.test.tsx)。

## 仍需阶段验收的范围

- 主任务需在真实 Clerk 人类身份下验收创建、复制、另一主体接受、撤销与刷新，并留存不含邀请码的证据；本子任务没有执行这些外部动作。
- 没有发邀请邮件、短信或飞书消息，也没有地址簿导入、邀请链接或自动全群加入。
- Agent 接受邀请不会自动扩展 Run 权限；Web 的 Agent Run 邀请表单不在本轮范围。
- Flutter 手机端仍在原迁移栈，本轮不代表手机新商业链路或全量飞书页面完成。

## 最终实施提交补记

本轮实现已纳入 `30c6c22ce3ff24676d9d5a43bf1b3ce0cf14aafa`，Git 时间 `2026-09-09T10:33:54+08:00`，说明 `feat(startup): invite human and agent colleagues with scoped arrival reads`。该归属替代撰写时的“尚未提交”状态，不改变上述基线历史、测试统计与 GUI 验收边界。运行时迁移和真实多主体验收由主任务另行记录，不能仅凭实施提交认定已经完成。

## 原生验收发现与最终修复补记

主任务的首次 Electron 验收发现复制按钮被浏览器剪贴板权限拒绝，邀请弹窗还存在重复标题和关闭区域可达性问题。后续修复提交为 `313572c6881b488cccc6b943918d5598f2f9b5ae`，Git 时间 `2026-09-09T10:49:01+08:00`，说明 `fix(desktop): support scoped invitation copy and accessible dialogs`。详细边界与原始失败证据保留在[1045 修复专题](INVITATION_NATIVE_COPY_DIALOG_FIX_20260909_1045.md)。该提交不是对先前失败验收的覆盖或改写。

重启新 Electron 后，主任务实际完成“复制邀请码”→同一应用密码式邀请码框粘贴→提交接受。账号保持 Clerk 登录，接受者是空间原有所有者本人，`already_member=true`，仍为 owner、1 名成员，没有新增消息。两次原生邀请一项已撤销、一项已接受；未使用第二个真实账号，也未证明 Agent SDK 实时收包或新成员跨端通信完成。

最终修复自动化结果为 Web 206/206（21 文件）、桌面 10/10，TypeScript、preload 与 Web 构建通过；它们是上方 200 项阶段测试之后的新增修复回归，不能累加成 406 项。原生结果另见[复制成功](../../../docs/startup/2026-09-09/evidence/workspace-invitation-stage/invitation-copy-fixed-native.png)、[接受成功](../../../docs/startup/2026-09-09/evidence/workspace-invitation-stage/invitation-accept-fixed-native.png)与[最终桌面](../../../docs/startup/2026-09-09/evidence/workspace-invitation-stage/desktop-final-logged-in-native.png)。
