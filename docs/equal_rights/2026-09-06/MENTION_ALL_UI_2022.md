# 原生 IM：独立 @所有人 语义及草稿身份隔离

- 记录时间：2026-09-06 20:22:09 +08:00。
- 开发分支：`equal_rights`。
- 本轮指定基础提交：`0d61b9a`，2026-09-06 19:56:43 +08:00，`feat: align native settings and deepen equal-rights group collaboration`。
- 编写时已提交 HEAD：`7a18e1c`，2026-09-06 20:00:38 +08:00，`docs: record settings and group delivery with commit evidence`。
- 本文描述 HEAD 之后的工作区增量；上列提交不是本功能实现提交。最终功能提交及整机验证由集成记录补充。

## 产品行为

办公 IM 群聊中的“@所有人”具有独立广播意图。人类与 Agent 使用相同协议、相同选择界面及同一组权限约束。勾选所有成员不等于广播；广播可与显式提及某些成员同时存在。单聊不提供广播入口，原生发送层也拒绝单聊广播。

选择器返回 `OfficeMentionSelection(selectedIds, mentionAll)`：`selectedIds` 是去重的只读成员 ID 列表，`mentionAll` 是独立布尔值。选择或取消“@所有人”不会覆盖显式成员；移除广播 chip 也不会删除已选同事。消息气泡仅根据 `mention_all: true` 显示一次广播 chip，显式成员 chip 可共存。不会由 `mentions` 或后端广播目标快照 `mention_all_ids` 推断广播。

## 实现范围与兼容性

主要实现位于 `apps/office/lib/ui/mentions.dart`、`apps/office/lib/ui/conversation.dart` 和 `apps/office/lib/office_state.dart`。

1. `OfficeState.send` 新增独立 `mentionAll` 和可选 `sourceRoomId`；请求带 `mention_all` 与 `mentions`。目标会话在发起操作时固定，不能因用户切群而改变。未知会话或单聊的广播请求返回 `group_required`。
2. 草稿独立保存 `mention_all`。没有该字段的旧草稿按普通显式提及恢复；单聊草稿会清除不合法的广播状态。草稿按端点、身份和会话隔离，交互有效性额外绑定 state 实例与身份 generation。
3. 发送意图签名和 outbox 包含广播布尔值。旧版普通消息签名及 outbox 可迁移，避免升级界面时给同一待确认消息创建新的 `client_id`。失败重试保留原 ID；删除广播产生不同发送意图，获得不同 ID。
4. 切群或切身份会使已打开选择器失效；迟到结果不写回新的会话。发送回执只清除未被继续编辑的来源草稿，不能清空目的会话或新身份的草稿；旧操作的报错和 busy 收尾也不会影响新操作。
5. 显式 Agent 协作回调和展开编辑器回写也使用来源作用域检查。

## 前端验证证据

执行环境为仓库已有 Flutter SDK，使用 `--no-pub`。本轮没有下载依赖。

```text
flutter test --no-pub test/mention_all_test.dart test/message_interaction_test.dart test/office_state_test.dart test/office_ui_test.dart
41/41 PASS

flutter analyze --no-pub lib/ui/conversation.dart lib/ui/mentions.dart lib/office_state.dart test/mention_all_test.dart test/message_interaction_test.dart
No issues found

flutter test --no-pub test/mention_all_test.dart
13/13 PASS（补入 state 实例隔离后复验，20:22 前完成）
```

新增 `test/mention_all_test.dart` 覆盖旧草稿不推断广播、群聊与单聊选择器、人类与 Agent 原生发送协议及重试 ID、固定来源会话、直接调用单聊广播拒绝、广播和显式 Agent 共存、失败重试、删除广播产生不同意图、跨群草稿、打开选择器后身份 generation 变化、迟到发送确认及新身份草稿保护、历史消息气泡渲染。

原 `message_interaction_test.dart` 适配强类型选择结果，`office_ui_test.dart` 适配明确的“@所有人”标签。本记录的验证是自动化组件与状态验证，不声称已完成真实 App 或真实模型验证。

## 对接契约

后端负责人确认以下语义与本次前端一致：`mention_all: true` 进入广播发送意图 hash；false/缺省沿用普通消息旧 hash。历史消息输出 `mention_all: false`、空广播目标快照。显式提及与广播共存；个人屏蔽广播不能压制显式提及；折叠会话通知数为零。编辑时省略广播字段保留原值与快照，true 保留原目标快照，false 清除广播。

后端负责人另报告后端全量 252 项通过；这属于后端交付证据，未纳入本文的前端 41/13 项计数。实际 HTTP/MCP 联调及最终构建由集成负责人单独记录。

## 集成提交补记

2026-09-06T20:37:51+08:00：实际前端实现 `49d6115f5bd0ea15e3e9437f060e3ade503bf545`（2026-09-06T20:35:29+08:00），后端实现 `b8747976dc37a68eedd199a76054a33a53a1d978`（2026-09-06T20:35:03+08:00）。完整交付和验证边界见 [FOLDED_BROADCAST_DELIVERY_2035.md](FOLDED_BROADCAST_DELIVERY_2035.md)。
