# 首条未读窗口与实际可见消息已读上报

- 记录时间：2026-09-06 21:18:53 +08:00。
- 分支：`equal_rights`。
- 编写时已提交基础：`345bfad`，2026-09-06 20:40:31 +08:00，`docs: record folded conversation and broadcast delivery`。
- 前一个功能基础：`49d6115`，2026-09-06 20:35:29 +08:00，`feat(office): add folded chat UI and native everyone mentions`。
- 本文为 HEAD 之后的独立工作区增量记录；实现提交号由最终集成交付补充。

## 行为与 API

进入有未读消息的会话，原生状态先读取会话上下文，再请求 `GET /rooms/:id/messages?first_unread=true&limit=100`，以首条真实未读开头展示窗口。例如已有 351 条消息、读到第 20 条时，首窗显示 21–120，进入时未读数为 331，后方仍有 231 条未读。没有未读时沿用最新窗口，不编造首条未读标记。

新文件 `apps/office/lib/conversation_unread.dart` 定义只读 `OfficeConversationWindow`；`office_state.dart` 导出该类型，并提供：

| API | 用途 |
| --- | --- |
| `conversationWindow` | 窗口状态及进入时快照 |
| `conversationSelection` | 当前会话选择版本 |
| `loadingMessageWindow` | 定位与分页进行中 |
| `loadEarlierMessages()` | 保留兼容的前向历史加载 |
| `loadLaterMessages()` | 连续加载窗口后方消息 |
| `jumpToLatestMessages()` | 明确跳到最新窗口，不自动 ACK |
| `reportVisibleMessageSequences(roomId, seqs, selection:, identityGeneration:)` | 上报实际进入可视区域的序号集合 |

窗口保存进入时 `entryFirstUnreadSeq/entryUnreadCount`，以及当前 `anchorSeq/firstUnreadSeq`、前后游标、`hasMoreBefore/hasMoreAfter`、`remainingUnreadAfter`、`positionVersion/startAtUnread`。进入时快照在分页、已读回执和后台刷新后保持不变；明确跳最新增加定位版本，供界面滚动处理。

## 已读语义

`setConversationVisible` 现在只登记当前会话是否处于可见前台，不发已读请求。选择会话、载入首窗、加载前后窗口、跳最新和后台事件刷新均不自动 ACK。界面需按实际渲染矩形检测可见消息，再调用上报 API。

上报只接受当前选择版本、当前身份 generation、当前可见会话及已加载消息中的序号。未加载的末条序号或过期布局结果不会产生请求。服务端协议仍是累积水位 `PATCH /rooms/:id/preferences {read_seq: 上报可见序号的上界}`，不把本地已加载列表的最大序号当作用户已读范围。

同一待确认水位去重；失败可以重试。迟到回执不能修改另一身份、另一次会话选择或已经隐藏的会话。返回的计数快照若落后于本地最新消息，不覆盖更鲜的未读数；服务端已存在更高设备水位时沿用其更高水位和准确计数。

每次 `selectRoom` 都产生新的选择版本并重置内部可见状态；界面再次进入同一 room ID 时也需重新登记可见，不能仅比较房间字符串。

## 后台刷新与并发

后台刷新更新已加载范围，保留尚未读完的中间窗口，不用最新 tail 替换它。此前已到最新的窗口可以连续追加下一页新消息；突发消息超过一页时仍保留真实后向分页。窗口请求绑定身份、房间选择及请求版本；明确定位会使旧后台窗口结果失效，切房间或切身份后迟到页也被丢弃。

后端负责人确认 `after=0` 合法，取 seq 大于 0 的最早页；first_unread/around/after/before 定位互斥，limit 为 1–200。本轮客户端 GET 不发送 ACK。消息读者明细与可靠 receipt_summary 的界面展示由集成端另行处理。

## 验证

```text
flutter test --no-pub test/conversation_unread_test.dart test/read_receipts_test.dart test/office_state_test.dart
24/24 PASS

flutter analyze --no-pub lib/office_state.dart lib/conversation_unread.dart test/conversation_unread_test.dart test/read_receipts_test.dart
No issues found
```

新增窗口测试覆盖人类/Agent 同权、331 条未读首窗、连续前后分页、后台新消息不吞旧窗口、跳最新不 ACK、无未读、隐藏/未加载/旧身份与旧选择报告、迟到页、失败重试、后台与显式跳转竞争、迟到回执计数及另一设备更高水位。原 5 项 read_receipts 测试已按显式可见上报语义更新；原 6 项通用状态测试继续通过。

曾联跑旧 mention_all 组件回归，发现集成中的悬浮工具栏在 build 阶段隐藏 OverlayPortal 及窄消息底部 Row 溢出，已交由界面负责人处理；它们不计入本记录的 24 项通过。真实视口检测、首屏滚动、悬浮工具条、真实后端联调和实机验证由集成记录单列，本记录不声称已完成这些验证。
