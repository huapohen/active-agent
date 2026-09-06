# 原生话题与明确已读状态组件

- 记录时间：**2026-09-06T21:16:50+08:00**（Asia/Shanghai）。
- 分支：`equal_rights`。
- Active Agent 集成前基线 commit：`345bfad3bdc07f31eccf6bd6bd53894627a02cc8`，时间 `2026-09-06T20:40:31+08:00`，描述 `docs: record folded conversation and broadcast delivery`。
- 本批组件记录时尚未提交；以上为基线，最终实现 commit 由主线集成记录补充。
- 描述：将消息话题作为真实回复树呈现，补齐单聊已读红色勾、群聊阅读数量和接收成员名单；读取不会代替明确阅读确认。

## 话题

新增 `apps/office/lib/ui/message_thread.dart`，入口为 `showOfficeMessageThread(context, state, roomId, rootMessage)`。手机使用可关闭底部面板，桌面使用靠右面板，两者呈现相同真实数据。

读取 `GET /rooms/:rid/messages/:mid/thread?after=<seq>&limit=50`。后端返回 `root_message`、按 `reply_to` 传递的后代 `messages`、`total_replies`、`has_more`、`next_after`、`after_cursor`。前端按序号分页、按消息 ID 合并，刷新时重新验证已加载的完整窗口，不将普通后续群消息当成话题回复。服务端返回撤回占位时，只显示“这条消息已撤回”，不展示此前正文或附件。

回复使用现有 `OfficeState.send(content, sourceRoomId: openedRoomId, replyTo: selectedMessageId)`。默认回复话题原消息，也可以回复某一条真实后代。打开话题是纯读取；不会新建“话题创建成功”消息或其他占位记录。发送成功显示服务端返回的实际消息；失败保留草稿与回复目标，沿用 OfficeState 的发送去重。

读取与发送互斥，避免旧分页响应覆盖刚提交的回复。断网保留本地草稿并禁用发送与刷新。同步事件在同帧合并，下一帧重新验证当前已加载窗口；403/404 等访问错误清除旧话题正文并暂停发送。手动刷新和读取错误重试始终使用打开时的原始会话。

## 阅读状态

新增 `apps/office/lib/ui/message_receipts.dart`：

| 接口 | 实际行为 |
| --- | --- |
| `OfficeMessageReceiptIndicator(message:, roomKind:, onOpen:)` | 从消息的 `receipt_summary` 展示状态；单聊已读为用户指定的红色单勾，群聊显示 `已读数/接收人数 已读`，可打开名单 |
| `showOfficeMessageReceipts(context, state, roomId, message)` | 读取明确消息的 `/readers`，显示发送时接收成员的当前阅读状态和成员关系 |

协议中的新消息为 `known:true, basis:explicit_read_ack`，具有 `eligible_count`、`read_count`、`unread_count`。前端不以当前会话人数减去发送者来猜测接收人数，也不把浏览话题或打开已读名单视为阅读 ACK。

历史消息 `known:false, basis:legacy_unknown` 明确显示“阅读状态未知”，解释缺少发送时的接收成员记录。所有计数字段为 null 时不会补成零或全员未读。撤回消息 `basis:message_retracted` 不展示主时间线已读指示，详情说明阅读状态不再展示。

名单使用服务端 `readers` 中的 `principal_id`、`name`、`kind`、`status`、`current_member`、`same_membership`、`read_ack_seq` 和 `acknowledged_at`。人类和 Agent 使用相同规则；已退出或重新加入的成员关系明确标注。`acknowledged_at` 标签为“最近确认”，它是最后累计 ACK 时间，不能描述为该消息的精确阅读时刻。

## 身份与异步边界

两个面板均在打开时固定 state 对象、身份代次、端点、principal ID 和原始会话/消息 ID。当前主会话变化不改变请求目标。身份变化时永久锁定旧面板并移除旧内容；话题输入控制器也清空。A→B→A 不恢复旧数据，晚到的读取或发送回执不会复活旧身份内容或关闭底层页面。面板关闭后也拒绝晚到 UI 更新。

## 本批验证

`flutter test --no-pub test/message_thread_receipts_test.dart`：**13/13 通过**。

覆盖人和 Agent 同一真实发送接口、失败草稿与重试、显式 sourceRoomId、回复真实后代、序号分页、重验已加载窗口、撤回清理、断网与成员资格失败、读取中禁止发送、关闭等待中的面板、同 ID 代次变化、晚到读/写回执、成员快照、历史未知、撤回未知、红色单勾及群阅读数量。

测试使用独立 OfficeState fixture，验证请求协议和面板交互；没有发出真实消息，没有读取真实企业内容，也没有启动或重启服务。后端 HTTP/MCP 合约、主时间线浮动工具栏和原生设备验证由相应集成记录证明。自定义图片表情由主线统一渲染，本批只处理现有文本和附件。
