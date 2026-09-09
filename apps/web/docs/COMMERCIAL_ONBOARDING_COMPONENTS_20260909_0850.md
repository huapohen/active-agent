# 工作空间入门独立组件与验证

编写时间：`2026-09-09T08:51:54+08:00`。开始此子任务的当前提交为 `ddd947c7c3f74168ad1a17b11d4b04b5eb4599ad`。本文描述的入门组件目前尚未提交，由主线程接入 App 和真实协议；不得把组件测试写成已完成后端或原生 GUI 验收。

新组件让刚登录的同事设置昵称、选择或创建真实工作空间、创建群聊。产品界面只显示“个人资料”“工作空间”“创建群聊”。人类与 Agent 使用相同的成员选择控件，不生成示例组织、成员或成功结果。当前工作空间只有本人时，仍可以创建群聊。

## 文件与集成边界

- [CommercialOnboarding.tsx](../src/CommercialOnboarding.tsx)：整页入门与三个可复用表单。
- [commercial-onboarding.css](../src/commercial-onboarding.css)：独立 `co-` / `commercial-onboarding` 样式，圆头像、表单、真实工作空间与成员列表。
- [CommercialOnboarding.test.tsx](../src/CommercialOnboarding.test.tsx)：28 项聚焦回归。

本子任务没有修改 `App.tsx`、`api.ts`、`types.ts` 或全局样式；也没有操作 GUI、调用模型、访问生产服务或提交代码。无需新增依赖。

## 确定的回调契约

整页导出 `CommercialOnboarding` 和 `CommercialOnboardingProps`。单独可复用的导出为 `CommercialProfileForm`、`CommercialWorkspaceForm`、`CommercialRoomForm`，各有对应 Props 类型。

| 输入 | 形状与含义 |
| --- | --- |
| 当前身份 | `scopeKey` 与 `me: Principal`；组件随 scopeKey / principal ID 更换而重新挂载 |
| 工作空间 | `workspaces: {id,title,role?}[]`、`selectedWorkspaceId`、`workspaceLoad: {scopeKey,status,message?}` |
| 成员 | 当前工作空间真实 `Principal[]`；`membersLoad` 必带 scopeKey、workspaceId、status；列表包含当前本人 |
| 能力 | canRename、canCreateWorkspace、canCreateRoom，由上层真实能力声明决定 |
| 昵称输入 | `{displayName}`；onRename / 独立表单 onSubmit 收到输入与 scopeKey |
| 工作空间输入 | `{title}`；onCreateWorkspace / onSubmit 收到输入与 scopeKey |
| 群聊输入 | `{workspaceId,title,memberIds}`；包含本人、去重、排序后的真实 ID |
| 原操作核对 | 整页 `onReconcile('rename'|'workspace'|'room',scopeKey)`；独立表单 `onReconcile(scopeKey)` |
| 读取/选择 | onSelectWorkspace、onRefreshWorkspaces、onRefreshMembers 均携带身份范围；成员刷新还带 workspaceId |
| 已确认群聊入口 | `onOpenRoom(roomId,scopeKey)`；仅消费当前工作空间的 succeeded result |

`CommercialActionState<Input,Result>` 是上层拥有的操作状态：

```ts
{scopeKey, status: 'idle' | 'pending' | 'unknown' | 'error', message?, submitted?}
// 或
{scopeKey, status: 'succeeded', result, message?, submitted?}
```

对应结果为 Profile `{id,displayName}`、Workspace `{id,title,role?}`、Room `{id,workspaceId,title}`。Promise resolve 不等于成功；只有上层提供的 `succeeded/result` 会显示成功反馈或进入群聊按钮。error 文案由上层提供安全文本，不直接显示任意抛出异常。

组件不持有 token，不生成 action ID，不发 HTTP 请求。上层必须在首次调用前保存稳定 action ID 与完整原意图，按后端 profile expected_version 或创建动作协议处理。unknown 时传入原 submitted，表单冻结为原值，只能核对原操作；核对仍由上层使用原 ID。组件没有盲目“再次创建”入口。确定的 409 版本冲突需上层重新读取并提供 error 状态，由用户纠正后再提交。

## 输入、身份与重复操作

昵称先 trim，限制 1–80 个 Unicode 字符，拒绝控制字符及格式控制字符（Cc/Cf）。工作空间和群名称按服务端约束限制为 240 UTF-8 bytes。所有表单保留中文组合输入，Enter 确认候选字不会提交；组件没有注册 window/document 全局键盘或输入事件钩子。

同步 in-flight 锁挡住同一渲染周期的重复 submit。结果未知时保留字段并禁止新提交；已确认的同名工作空间不会再次创建，需更改名称才可提交新意图。

旧身份工作空间/成员/错误不会呈现给新身份；工作空间切换清空群名称与选中成员。成员页尚在加载、来源不匹配、读取失败或当前本人不在列表中时，不拼出成员，也不发起群创建。已撤除的成员从当前提交中移除。成员最多 100 位，当前本人固定加入且只出现一次。

整页在上层 pending / unknown 状态下阻止切换工作空间和开启其他创建操作。对页面关闭、身份更换和原操作持久性的最终控制仍由 App 层负责；组件不代替后端成员授权或幂等事务。

## 本轮验证

`npm run test --workspace @renji/web -- --run src/CommercialOnboarding.test.tsx`：**28/28 通过**，2026-09-09 08:49:15 开始。日志 `/tmp/renji-commercial-onboarding-tests-20260909.log`。

`npm run check --workspace @renji/web`：TypeScript 检查通过。日志 `/tmp/renji-commercial-onboarding-check-20260909.log`。

回归覆盖：空工作空间无假成员、真实身份选择、单人成员群、人和 Agent 同权选择、成员撤除、错误来源/身份/工作空间过滤、切换时清空草稿、未知结果仅核对原操作且不生成 action ID、同步重复提交、异常文本不泄露、迟到错误隔离、确认回执才可进入群聊、Unicode 与字节边界、三个表单中文 IME、没有全局键盘钩子。

320px 情况仅通过 jsdom 检查控件与语义仍存在，不能作为真实像素布局证明。独立 CSS 有 740px / 400px 断点及局部滚动区域；原生 Electron、实际窄窗口、真实 Clerk profile / workspace / room 闭环，均待主线程集成后验收。

## 最终组件修订与独立 Hook 复核（2026-09-09T09:10:47+08:00）

本节补充初版 28 项后的实际修订，不改写上文当时的测试结果。最终组件回归 **39 项**：昵称、工作空间和群名同步拒绝格式控制、孤立代理码元与 U+2028/U+2029，匹配 API / Go 的单行规则；原工作空间缺失或成员撤权时隐藏旧群标题/成员，只保留固定的“核对原操作”入口，由上层执行原意图，不能切到当前工作空间新建。旧身份的未知操作不会获得核对按钮。

已经确认成功的群聊不能通过 Enter 再次提交同一意图。原名称或成员真正改变后才重新呈现“创建群聊”，以便同一表单用于后续群创建。未修改时仅显示已确认群的入口。

独立 Hook 复核另有 **16 项**，覆盖上层持久意图、重放后读取当前事实、精确 profile 版本冲突、A-B-A、存储失败、成员失效与后台旧 GET 延迟回包。[独立审查说明](COMMERCIAL_ACCOUNT_INDEPENDENT_REVIEW_20260909_0908.md)。组件与 Hook 合计 55 项，不替代真实 API、原生 GUI 或生产发布验收。

## 阶段提交归属（2026-09-09T09:50:44+08:00）

上文“尚未提交”和“待主线程验收”描述的是各次复核发生时的状态。本阶段最终实施提交为 `e975e94e900cc892e39ed52ac0ce94ccd71c6ea1`，提交时间 `2026-09-09T09:35:36+08:00`，描述 `feat(startup): onboard colleagues and relay verified RongCloud arrivals`。实际 Clerk Human 的昵称、工作空间、单人成员群、中文消息、回复与表情回应已在 Electron 操作并由数据库读回；详见[本阶段主交付](../../../docs/startup/2026-09-09/STARTUP_ACCOUNT_BRIDGE_DELIVERY_0943.md)。这不补作原生窄窗口或物理键盘的验收。
