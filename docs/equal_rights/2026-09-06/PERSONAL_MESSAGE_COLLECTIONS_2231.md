# 本人标记与已删除消息清单 · 2026-09-06 22:31

记录时间：2026-09-06T22:31:23+08:00，Asia/Shanghai。分支 `equal_rights`。

本批实现前基线 commit 为 `7e305492b996a1c0a8f727db8d353d97f742c4bc`，Git 时间 `2026-09-06T21:53:08+08:00`，描述 `feat(office): deepen native chat interactions and complete shared emoji`。此时新增面板尚未提交，最终实现 commit 由集成交付补充，不能用基线代替新实现。

## 入口与返回值

新增 `apps/office/lib/ui/message_personal.dart`：

```dart
Future<Json?> showOfficePersonalMessages(
  BuildContext context,
  OfficeState state, {
  String? roomId,
  bool hidden = false,
})
```

未指定 roomId 时查看本人所有仍有会话成员资格的相关消息，指定时固定在该来源会话。hidden=false 打开“标记的消息”，hidden=true 打开“已删除消息”。桌面显示可关闭对话框，手机显示底部面板；均有刷新、错误重试、空态和分页。

标记消息提供“打开原消息”和“取消标记”。打开前重新 GET 来源消息，返回实际 `{room_id, message}`，供主线定位原时间线；面板不主动切换会话或 ACK。已删除消息仅提供恢复，不把隐藏正文作为跳转返回值。列表显示来源会话、作者及时间，人类与 Agent 使用同一套入口和权限。

## 本人集合协议

- 标记：`GET /api/im/message-marks?limit=50&room_id=...&before=...`。
- 已删除：`GET /api/im/hidden-messages?limit=50&room_id=...&before=...`。
- 未指定的 room_id/before 不发送。返回 `items:[{room_id,room_name,message}]`、`has_more`、`next_before`。

向后翻页使用服务端返回的独占 before 游标，按来源会话与消息 ID 去重。刷新时重新核对已经载入的页深度，避免读取三页后刷新又突然退回第一页。分页不前进时报实际错误并保留前面已加载结果，不通过伪造游标跳过消息。

取消标记调用 `state.setMessagePersonal(sourceRoomId, messageId, marked:false)`；恢复调用相同接口的 `hidden:false`。两者只发送本人明确意图，不指定目标身份、不反转旧值、不混改另一个偏好。服务端确认写入后真实重新 GET 清单，不靠本地先删掉行制造成功。普通写失败保留行，重新操作仍发送相同 false。

写入成功但清单刷新失败时明确说明“已恢复/已取消标记，列表刷新失败”，重试刷新只读取清单，不重复写入。如果刷新仍返回该项，则提示列表尚未反映变化，继续核对。

## 隐藏、撤回与权限变化

已删除清单仅渲染作者、时间等墓碑元信息。即使异常响应附带正文、历史或附件，面板也按白名单剥离这些内容，不渲染隐藏预览。标记清单中若意外混入 hidden=true 项则跳过；撤回项只显示撤回占位。

打开原消息前取得新版本。如果此时消息已隐藏，保留面板并刷新清单，提示去已删除消息恢复，不返回打开时缓存的旧正文。撤回消息仍可返回用于定位的空墓碑，移除正文、历史及附件。读取源消息或执行个人动作时遇到 401/403，移除该条陈旧记录；整个清单授权失败时清空旧清单，错误保留供重试。

## 身份、异步和离线

面板固定 OfficeState、identityGeneration、endpoint、principal ID、可选来源房间和集合类型。身份或查看范围 props 变化永久过期，旧内容立即清空；A→B→A 不恢复。当前主会话变化不会改变既有来源过滤或给另一个会话提交动作。

读取、分页、恢复/取消标记、打开原消息相互隔离，等待期间禁用新的动作。任何迟到结果均核对当前身份及请求版本。等待中可关闭面板，不会由随后完成的请求再关闭下面页面或展示成功。

离线保留已有清单但禁用远端动作；重新连接可刷新读取，不会自动执行恢复或取消标记。服务端个人事件触发当前列表重新读取，不把另一身份的状态缓存到本人的面板。

## 验证

- `flutter test --no-pub test/message_personal_test.dart`：**15/15 通过**，日志 `/tmp/message-personal-test.log`。
- `flutter analyze --no-pub lib/ui/message_personal.dart test/message_personal_test.dart`：**No issues found**。
- `git diff --check` 通过。

专项覆盖人类/Agent 同权、固定来源与全会话列表、手机隐藏墓碑、显式恢复/取消标记和真实重新读取、120 条三页游标与刷新保持页深度、不前进游标、普通失败重试、写入成功但刷新失败、打开前隐藏、撤回占位、离线及重连、A→B→A、迟到写/读响应、关闭等待、成员权限变化和跨来源错误响应。

测试使用隔离 fixture 验证 UI、读取路径和 OfficeState 调用，不操作真实飞书、不发送群消息、不重启服务。主线的侧栏、会话详情和时间线入口由集成负责人接入；本批只新增面板、测试与此专题，未修改 room_details、shell 或 conversation。后端真实持久化和多身份 HTTP/MCP 另有专项证据。
