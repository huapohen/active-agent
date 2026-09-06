# 群聊实现审阅与验收矩阵

- 记录时间：**2026-09-06T18:45:12+08:00**（Asia/Shanghai）。初始只读审阅约 18:33–18:39，随后按分工修复已读状态层。
- 分支：`equal_rights`。
- Active Agent 基线 commit：`6f44527dc7e3c486e9f8a1675a699384e1c1fdea`，`2026-09-06T18:29:28+08:00`，`docs: record settings alignment and verified capability limits`。
- 配套 Doc Free 已提交基线：`5618e90e370bb43ee7c4cd5b2cfd86156b1366a5`，`2026-09-06T17:39:33+08:00`，`fix: expose optional participation revision checks through MCP`。
- 描述：审阅 Flutter 群聊中的回复、转发、已读、成员、搜索、撤回及相关测试。本文区分源码确认、测试确认与待验证；没有操作飞书或真实账户，没有提交代码。两仓此时均有并行开发中的未提交内容，后续修复结果以本批最终验收台账为准。

## 1. 初始审阅结论

审阅来源为 [conversation.dart](../../../apps/office/lib/ui/conversation.dart)、[office_state.dart](../../../apps/office/lib/office_state.dart)、[office_dialogs.dart](../../../apps/office/lib/ui/office_dialogs.dart)，并检查 shell 搜索结果入口与现有状态、搜索、布局测试。

| 项目 | 源码已确认的能力 | 初始具体缺口 | 可直接执行的修补与回归 |
| --- | --- | --- | --- |
| 回复 | 消息操作菜单可设置 reply_to；草稿按 endpoint/身份/会话分开，发送签名包含引用，成功后清除 | 引用正文只在已加载 messages 找 parent；历史 parent 不在页内则只显示“更早消息”，卡片不能点击定位。草稿保存整份旧消息，没有随撤回/编辑重新核对引用 | 用受会话权限约束的单消息读取返回 parent；已撤回只展示撤回占位，引用卡提供定位。回归 parent 不在最新 200 条、parent 被撤回、切房恢复引用、失败重试仍保留 reply_to |
| 转发 | 单目标对话框、源消息版本校验参数、附件独立共享；`_createOfficeItem` 已使用 outbox client_id 保留模糊失败的同一意图 | 目标列表没有搜索，选目标即执行；前端没有消费 forwarded_from 说明来源。对话框返回后原方法根据当前 selectedRoomId 拼源路径 | 加可搜索目标与明确操作反馈，显示安全的来源说明；固定源房与身份。回归打开 A 的转发框后切 B/换身份不得发送旧操作，响应丢失重试 client_id 相同，撤回/权限变化不能假报成功 |
| 已读 | 自己消息展示其他当前成员 read_seq 对应的人数 | 原 selectRoom 和每次 `_loadCurrent` 都推进最新 seq；手机返回只隐藏详情，切其他应用模块仍保留 selectedRoomId，所以后台轮询可把没在看的会话标已读。人数是 Text，没有已读/未读成员明细；Agent 也被计入“人” | 本轮已修状态层可见性门槛，见下一节；再接真实前台生命周期。后续将文案改成成员，按实际 read_seq 展开明细；不把自动加载当成逐气泡阅读 |
| 群成员 | 展示人类/Agent、负责人身份；群负责人能逐个添加；Agent 有人格与参与配置入口，单聊不展示添加 | 对话框没有成员搜索/筛选、批量选择或移除入口；state 没有 removeMember 适配。列表随全局 state 变化，旧对话框未固定原房/身份 | 先补成员搜索和负责人移除，使用现有后端 DELETE `/rooms/:id/members/:principal`；固定房间身份，防重复请求，离开成员后撤销可见数据。回归作者/负责人/普通成员、同权 Agent、单聊禁改、负责人不能自移除 |
| 会话搜索 | 详情顶部“查找消息”，提示明确写“搜索已加载的消息”；全局 search 已有 room/author/date 参数与迟到响应保护 | 本地 filter 无匹配时直接 EmptyOffice，连“加载更早消息”按钮也不渲染；旧消息无法在搜索中继续找。全局消息搜索结果只打开 room_id，没有定位 message_id | 复用 `state.search(type:message,roomId:当前房)`，区分搜索空态与无消息空态；结果带目标消息定位与上下文。回归匹配项在第 201 条之前、零命中仍可退出/继续查找、点击结果精确跳到消息而非仅打开群 |
| 撤回 | 仅自己的消息菜单展示撤回；DELETE 使用 base_revision；撤回后消息行显示作者撤回占位 | 初始 UI 直接执行，没有确认/执行中禁重复或针对冲突读取；引用草稿仍可能显示已撤回正文。编辑对话框先关闭再请求，409 时文本仅在临时返回值中，用户不能继续修订 | 撤回提供明确确认或撤回反馈及请求锁，冲突保留状态并刷新；引用统一脱敏。编辑保留对话框直到保存确认。回归自己/他人、连续点击、409、撤回引用及附件、保存响应失败 |

后端当前工作区已出现单消息 GET 和 reply_parent 返回等新增实现，以上“初始缺口”描述的是本轮开始时客户端链路。不能将并行开发中的代码存在当成界面已经接通或已经运行验证。

## 2. 移动与桌面交互差异

源码显示两端共享上述操作逻辑。手机每条消息常显约 25×25 的菜单槽；桌面在 MouseRegion hover 时才显示菜单。消息气泡本身没有 long press、secondary click 或专门键盘焦点入口。手机长按与桌面右键可以复用同一动作菜单，键盘 focus 时也应显示操作入口，并扩大实际点击区域。

手机消息头固定高度 65，同时有返回、头像、标题、搜索、成员和更多；长群名依赖省略。现有 390 宽布局与输入工具测试可以证明已有场景不溢出，但没有覆盖群聊动作弹窗打开时键盘占 300 像素、超长引用与大群成员列表。应作为新回归，而不是仅根据共用 Widget 声称两端完全一致。

## 3. 本轮已完成：已读状态层修复

新增公开接口：

```dart
Future<void> setConversationVisible(String roomId, bool visible)
```

默认没有可见会话。`selectRoom` 保持加载/选中行为；只有当前房间被界面声明为可见时，读取和轮询才允许提交 read_seq。隐藏只影响指定房间，旧 Widget 的 dispose 不会误关另一个当前可见房间。前台恢复可补交最新已加载消息的回执。

每次回执捕获身份 generation 和可见性版本；迟到响应不能污染新身份、隐藏房间或新未读状态。同一可见阶段的重复请求会去重，隐藏后重显和失败重试仍然可用。新增消息比旧回执更新时，旧回执不能简单把 unread_count 清零。

新增 [read_receipts_test.dart](../../../apps/office/test/read_receipts_test.dart)，保留真实登录、selectRoom、事件轮询和 HTTP 请求，只替换网络为严格合成服务并跳过无关业务刷新。

| 专项测试 | 已运行结果 |
| --- | --- |
| 登录、自动选中与 hidden poll 不发回执；可见/恢复后发真实最高 seq | 通过 |
| 切房需新可见状态，旧 Widget hide/activate 不影响当前房 | 通过 |
| 隐藏后迟到回执不清新未读 | 通过 |
| 旧身份回执不污染新身份缓存和计数 | 通过 |
| 重复可见通知去重；隐藏重显、503 均可重试 | 通过 |

专项 **5/5**；与既有 `office_state_test.dart` 合跑 **11/11**；`dart analyze lib/office_state.dart test/read_receipts_test.dart` 为 **No issues found**。

这证明状态层的“当前可见会话”合同。真实界面的 foreground/resumed、路由、挂载/销毁调用由主实现方接入，本记录没有单独运行设备生命周期。当前也不宣称按每一条气泡的 viewport 可见区域判断阅读。

同批按主实现需要，为 `editMessage` 和 `forwardMessage` 添加可选 `sourceRoomId`，显式房间经过 URI 编码；未传参数保持原调用方式。转发仍通过 `_createOfficeItem`，保留 outbox 幂等重试。身份和对话框房间守卫由调用层接入；这两处方法的静态检查通过，尚未在本专项中运行完整转发 UI。

## 4. 测试证据边界

审阅时的既有 `office_state_test` 覆盖人/Agent 同一消息能力和模糊发送重试；`office_search_test` 覆盖过滤参数、时间范围、键盘选择和打开房间；`office_ui_test` 覆盖手机编辑器、工具和不同宽度布局。它们没有直接断言回复引用定位、转发目标确认、已读成员明细、成员移除或撤回冲突流程。

本轮没有把这些源码推断写成运行失败，也没有增加无关业务测试。后续验收应优先锁定：跨身份旧操作、隐藏时错误已读、历史搜索定位、已撤回内容不再出现，然后再补多选/快捷操作等交互增强。
