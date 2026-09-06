# 消息添加任务与导出文档面板 · 2026-09-06 22:20

记录时间：2026-09-06T22:20:04+08:00，Asia/Shanghai。分支 `equal_rights`。

本批实现前基线为 `7e305492b996a1c0a8f727db8d353d97f742c4bc`，Git 时间 `2026-09-06T21:53:08+08:00`，描述 `feat(office): deepen native chat interactions and complete shared emoji`。本专题代码此时尚未提交，最终实现 commit 由集成交付补充；上述是基线，不冒充这次实现版本。

## 实际参考与新增接口

主集成负责人在镜像恢复后的飞书桌面群消息右键菜单实际看到了“添加任务”和“导出到文档”。本批提供相应真实业务面板；消息右键、更多、多选入口由主线接入。本专题不把新面板自己的布局称为已经逐像素对照飞书相应子窗口。

新增 `apps/office/lib/ui/message_work_actions.dart`：

```dart
Future<Json?> showOfficeMessageTask(
  BuildContext context, OfficeState state, String roomId, List<Json> messages,
)
Future<Json?> showOfficeMessageExport(
  BuildContext context, OfficeState state, String roomId, List<Json> messages,
)
```

两个入口都支持 1–50 条来源消息，按输入顺序去重。桌面弹出可关闭对话框，手机使用底部面板并避让键盘。展示来源作者、时间及消息正文预览，预填可编辑标题，提供可编辑“补充说明”。任务可选择待分配、真实人类成员或 Agent 成员作为负责人。

补充说明不重复预填来源正文；后端在同一创建操作中生成真实来源快照。预览保持原始经典表情 token 和 Unicode 内容，通过现有共享正文渲染显示，不把图片换成丢失语义的字符。

成功显示明确的任务/文档标题与保存位置。关闭成功面板返回后端实际 task/document record，可由调用者打开现有文档页面。不会创建聊天占位消息，也不返回自造任务或文档 ID。

## 原子来源命令

面板初次打开及提交前均读取来源会话和每条来源消息，确认本人仍有权限、消息仍属于同一来源会话。真正保存使用新增命令，而非不带来源约束的通用 createTask/saveDocument：

- `POST /api/im/rooms/:rid/messages/create-task`
- `POST /api/im/rooms/:rid/messages/export-document`

请求包含固定 `message_ids`、精确覆盖这些 ID 的 `base_revisions`、`title`、稳定 `client_id`，以及任务的 `description`/`assignee_id` 或文档的 `content`。description/content 仅为用户补充。服务端再次原子核对当前成员、IM 与 tasks/docs 策略、消息隐藏/撤回/禁止转发和版本，并生成包含来源稳定 ID、作者、时间、版本及附件索引的快照。

打开时已禁止转发、已隐藏或已撤回的消息，两种动作均拒绝，且不展示受保护正文。面板打开后发生同样变化，提交前重新读取会阻止创建并清除旧正文草稿；观察到当前状态更新也会遮挡。普通权限/网络失败保留草稿，不假报成功。

来源只是普通编辑时刷新预览并保留补充，要求再次明确提交；不会一次点击静默采用新来源版本。原子写返回 409 时保留草稿、禁用保存，需先“重新核对来源”，再明确提交。负责人在期间离开来源会话时要求重新选择。

## 未知结果与幂等恢复

发出写请求前冻结完整 payload 和 client_id。同一未确认结果只能重试同一次意图，标题、补充及负责人暂停编辑，避免超时后另建重复资源。关闭并重新打开同一 OfficeState、同一身份代次、同一来源集合及操作的面板，会恢复内存中的未确认意图；不落盘，不跨身份共享。

未知结果重试先调用 `GET /rooms/:rid/messages/source-operations?client_id=...&operation=...`。状态仍 pending 时只提示继续核对，不再次创建；completed 时通过真实文档 GET 或来源会话 tasks 读取既有 resource_id，返回实际结果。没有保存记录时，才在来源前检后重试完全相同的 payload。

`idempotency_conflict` 保留并冻结原意图，不生成新 client_id 绕过。重新核对来源本身失败不会丢掉更早未知结果的 client_id。网络超时、503、响应缺少真实 ID 和普通失败均没有成功占位。

## 身份与来源范围

面板固定 state 对象、generation、endpoint、principal ID、来源 room ID 和消息 IDs。当前主会话切到别处不会把任务或文档写到那个会话；请求仍明确使用打开时来源房间。身份或来源 props 变化永久锁定旧面板、清空旧内容，A→B→A 不恢复旧草稿。晚到读/写响应不能显示在新身份，也不会关闭下面的页面。

临时离线保留草稿并禁止提交；恢复连接不会自动创建。等待中的面板可关闭，控制器及异步回执安全释放；实际已经发出的服务端请求不伪装成已取消，未知意图继续保留供同身份重开核对。

## 验证与集成边界

- `flutter test --no-pub test/message_work_actions_test.dart`：**22/22 通过**；日志 `/tmp/message-work-actions-test.log`。
- `flutter analyze --no-pub lib/ui/message_work_actions.dart test/message_work_actions_test.dart`：**No issues found**。
- `git diff --check` 通过。

专项包含人类/Agent 对称创建、真实 Agent 指派、多条消息和手机返回真实文档、源正文不重复放入补充、同源跨当前会话、打开前及提交前的 hidden/retracted/no_forward、版本变化再次确认、原子 409、未知结果冻结/重开/同 ID 重试、pending 不再 POST、completed 读取真实资源、请求标识冲突、离线、权限失败、A→B→A、晚到响应、关闭等待、成员离开和 50 条限制。

测试使用独立 OfficeState fixture，验证实际 UI 与公开命令 payload，没有发真实群消息、重启服务或调用模型。后端原子性、HTTP/MCP、业务数据落盘和主菜单接线由主线及后端专题另行验证。本文件仅新增独立面板、测试与说明，不修改 conversation、message_actions 或 office_state。
