# 邀请码原生复制与弹窗可达性修复

记录时间：2026-09-09 10:45，Asia/Shanghai。问题发现于阶段实施提交 `30c6c22ce3ff24676d9d5a43bf1b3ce0cf14aafa`（`2026-09-09T10:33:54+08:00`，`feat(startup): invite human and agent colleagues with scoped arrival reads`）的真实 Electron 验收。本修复在该提交之后，撰写时尚未提交；不能将它追溯归入 `30c6c22`。

## 实际问题与修复

主任务在已登录 Electron 中创建了真实一次性邀请。服务创建成功，但点击“复制邀请码”显示复制失败；[当时截图](../../../output/workspace-invitations-20260909/invitation-created-native.png)记录了该状态。原实现使用 `navigator.clipboard.writeText`，严格 Electron 权限处理器拒绝此浏览器权限。

桌面现在通过现有 `contextBridge` 增加唯一的 `writeClipboardText(text)` 能力，由主进程调用 `clipboard.writeText`。主进程校验完成并等待异步原生写入完成，才返回 `{written:true}`；不回传明文。浏览器 Web 继续使用 `navigator.clipboard.writeText`。旧 Electron 若未加载新 preload，界面会保持复制失败，需正常重启桌面；不会放开权限或偷偷切换旁路。

同时修复邀请弹窗的两处原生问题：外层与内层重复显示“邀请同事”，以及默认窗口高度下列表和关闭区域被遮挡。新邀请弹窗只保留一个可访问标题；标题栏含角落关闭按钮，底栏含“关闭”，两者位于滚动正文之外。弹窗最大高度为动态视口减 32 px；邀请表单与记录在中间独立滚动，保持窄视口边距。

## 桌面边界

- 主进程只注册 `renji:clipboard:write-text`；没有剪贴板读取、HTML/MIME 格式选择、通用 IPC、文件或命令执行接口。
- 每次请求校验当前窗口仍存在、`event.sender` 为该窗口的 `webContents`、`event.senderFrame` 与其当前 `mainFrame` 完全相同，并属于已配置可信开发 origin 或 `renji://app`。子框架、其他窗口、融云 worker、外部页面、带用户信息的 URL 和异常 packaged 端口被拒绝。
- preload、Web helper 与主进程均只接收非空字符串，最多 65,536 个 UTF-16 code units，禁止 NUL。没有将邀请码本身用于 URL、日志或持久化。
- Electron 的 `sandbox`、`contextIsolation`、`webSecurity` 保持开启；权限处理器仍全部拒绝。该 IPC 是受限的文本写入能力，不是授予网页通用剪贴板权限。
- 本轮只将邀请复制入口切换到新 helper，没有扩展到剪贴板读取或自动复制。用户主动点击复制才发起写入，身份卸载后的迟到结果不显示“已复制”。

官方资料与本机安装的 Electron 44 类型一致：[`clipboard.writeText`](https://www.electronjs.org/docs/latest/api/clipboard#clipboardwritetexttext) 返回异步写入结果，应等待完成；[Electron 安全指南](https://www.electronjs.org/docs/latest/tutorial/security#17-validate-the-sender-of-all-ipc-messages)要求检查 IPC 来源。实现只应用本任务所需的主进程文本写入能力。

## 本地验证

| 范围 | 结果 | 覆盖 |
| --- | --- | --- |
| 桌面测试 | 10/10 | 原有 6 项加 4 项剪贴板发送者、边界、异步确认与错误脱敏；原 preload 测试扩展为只写接口与输入校验 |
| Web 定向 | 14/14 | clipboard helper 4 项与邀请组件 10 项；原生优先、浏览器 receiver、旧桥/假回执失败、迟到复制及单标题/关闭按钮 |
| 全 Web | 206/206，21 文件 | 在此前 200 项上增加 6 项，不与定向结果重复相加 |
| TypeScript | 通过 | `npm run check --workspace @renji/web` |
| preload 构建 | 通过 | `npm run prepare:preload --workspace @renji/desktop` |
| 生产 Web 构建 | 通过 | `npm run build:web`，主 JS 642.48 kB、gzip 205.69 kB；保留超过 500 kB 的体积提示 |
| diff 检查 | 通过 | `git diff --check -- apps/web apps/desktop` |

全 Web 日志 `/tmp/renji-invitation-clipboard-final-web-20260909.log`，构建日志 `/tmp/renji-invitation-clipboard-final-build-20260909.log`。这些是本机临时日志，不当作永久归档。

代码：[主进程写入校验](../../desktop/src/clipboard.cjs)、[注册 IPC](../../desktop/src/main.cjs)、[preload](../../desktop/src/preload.cjs)、[Web helper](../src/clipboard.ts)、[独立邀请弹窗](../src/WorkspaceInvitationDialog.tsx)。测试：[桌面边界](../../desktop/test/clipboard.test.cjs)、[Web 路由](../src/clipboard.test.ts)、[邀请交互](../src/WorkspaceInvitations.test.tsx)。

自动化验证没有读取系统剪贴板或真实邀请码，也没有操作 GUI。主任务后续需重启 Electron，验证复制后直接粘贴到密码式邀请码框的往返，以及实际窗口中的滚动与关闭。此记录截至撰写时不声称原生往返已经通过。

## 最终实施归属与原生复验补记

修复已纳入 `313572c6881b488cccc6b943918d5598f2f9b5ae`，Git 时间 `2026-09-09T10:49:01+08:00`，说明 `fix(desktop): support scoped invitation copy and accessible dialogs`。上文“尚未提交”和“原生待验证”保留为撰写时点；当前结果以下列复验为准，原始复制失败证据未覆盖。

主任务实际重启 Electron 后，Clerk 登录保持有效。原生点击复制显示“已复制”，随后在同一应用的加入窗口中直接粘贴到密码式邀请码框并提交成功。该过程未将邀请码读取或输出到报告中。此验收使用已在空间内的所有者本人接受邀请；结果为 `already_member=true`，所有者角色及 1 名成员保持不变。它证明真实剪贴板往返与接受接口闭环，不代表第二个真实用户或 Agent SDK 已验收。

两次原生邀请最终分别为“已撤销”和“已接受”，没有新增聊天消息。单标题、邀请内容滚动区域及关闭入口也在本次原生窗口中复验。证据：[复制成功](../../../docs/startup/2026-09-09/evidence/workspace-invitation-stage/invitation-copy-fixed-native.png)、[本人接受成功](../../../docs/startup/2026-09-09/evidence/workspace-invitation-stage/invitation-accept-fixed-native.png)、[桌面最终登录状态](../../../docs/startup/2026-09-09/evidence/workspace-invitation-stage/desktop-final-logged-in-native.png)。这些原生证据与上文自动化测试分开计数。
