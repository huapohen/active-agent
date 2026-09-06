# 办公 IM 会话徽标、消息悬浮操作与菜单审查

- 记录时间：2026-09-06 21:35:39 +08:00。
- 分支：`equal_rights`。
- 编写时已提交基础：`345bfad`，2026-09-06 20:40:31 +08:00，`docs: record folded conversation and broadcast delivery`。
- 前一个功能基础：`49d6115`，2026-09-06 20:35:29 +08:00，`feat(office): add folded chat UI and native everyone mentions`。
- 本文记录上述 HEAD 之后的独立工作区增量。最终实现 commit 由集成交付记录补充，不将基准提交冒充本轮实现提交。

## 会话列表徽标

`OfficeConversationRow` 将未读计数放在会话头像右上方，只出现一次，避免在摘要行重复显示同一计数。普通会话采用红色；静音或折叠会话采用灰色。0 和负数不显示，超过 99 的视觉文案为 `99+`，无障碍语义仍保留真实计数，例如“137 条未读消息”。徽标位于头像外缘，通过 Stack 叠加，不挤占消息摘要文本宽度。

列表对“对方已读”的显示采用明确接收人回执。新增 `officeDirectMessageRead(room, currentPrincipalId)` 只有在以下条件全部满足时返回 true：会话为单聊，末条消息由当前身份发送、没有撤回，服务端 summary 声明 `known: true`、`basis: explicit_read_ack`，且 eligible/read 均为 1、unread/unknown 均为 0。通过时在摘要前显示红色勾选图标及“对方已读”提示。

人类与 Agent 当前身份使用同一判定。旧版未知回执、worker 工作游标、收到的消息、群聊、不完整 summary、已撤回消息，都不会被推断成“对方已读”。Shell 需要传入当前稳定 principal ID；头像、昵称和姓名不是身份键。

变更文件：

- `apps/office/lib/ui/conversation_list.dart`
- `apps/office/test/conversation_list_badges_test.dart`

## 悬浮工具栏专项验证

本段验证集成端编写的 `OfficeMessageHoverTools`，本轮只新增 `apps/office/test/message_hover_tools_test.dart`，未修改悬浮组件、菜单或表情生产源码。测试使用真实 `officeTheme()` 和捆绑的表情目录、PNG 资源；`/emoji/recents` 使用合成成员及隔离 transport，不访问用户真实会话。

| 场景 | 验证结果 |
| --- | --- |
| 鼠标进入消息 | 出现工具栏和精确到秒的时间；消息矩形及下一条消息矩形完全不变 |
| 鼠标离开消息进入工具栏 | 工具栏继续可见；离开全部区域后经过 180 ms 关闭延迟消失 |
| 回复、转发、创建话题、Agent 协作、更多 | 各自只回调一次对应 action，随即关闭工具栏 |
| 更多菜单锚点 | `onOpenMore` 接收实际按钮左下角的全局位置；不会重复派发 fallback `more` action |
| enabled=false | 打开的 OverlayPortal 在后续帧关闭，无 build/layout 阶段断言 |
| TickerMode inactive | 保留在工作台导航栈中的隐藏页面关闭悬浮控制，无帧断言 |
| 组件卸载 | 工具栏与待执行离开计时器不产生已销毁组件调用 |
| 表情按钮 hover | 直接打开完整 `OfficeEmojiPicker`，包含最近使用、全部、经典表情及中英搜索 |
| 移入完整表情面板 | 超过工具栏离开延迟仍保留 picker，可通过搜索选择经典点赞 |
| 选择经典点赞 | 回调 `react:feishu:THUMBSUP`；GET 读取最近使用，POST 写入 canonical emoji ID，关闭面板 |
| 表情菜单打开且目录加载中卸载 | 没有遗留 OverlayPortal 或菜单帧断言 |

时间格式来自当前实现：本地日期 `YYYY/MM/DD`、系统 24/12 小时设置与秒。本测试固定 24 小时偏好和本地时间输入，断言 `2026/09/06 13:04:05`。这项验证确认自家实现稳定，不声称该日期格式或延迟数值已从飞书实测得出。

真实资源目录解码需要在 Flutter fake clock 之外交付异步结果；测试通过 `runAsync` 完成资产加载后再验证 picker，避免把持续 loading 的测试时钟超时误认成生产错误。表情选择用真实目录中的 `feishu:THUMBSUP`，没有替换成仅供测试的表情按钮。

## 右键、更多菜单只读审查

证据来源是当前源码与本项目既有飞书观察记录：`FEISHU_REFERENCE.md`、`FEISHU_LIVE_DEEP_COMPARISON_1530.md`、`FEISHU_PROFILE_NAV_MINUTES_1636.md`。本轮没有再次操作飞书、Simulator 或用户已登录的办公客户端。

历史记录已经确认会话列表密度、阅读圆圈、消息卡片、reaction pills、两行输入区、@ 选择器等。它们没有逐项列出消息右键菜单，也没有记录悬浮时间的精确格式、出现延迟与坐标，因此不能据此宣布“飞书消息菜单全部覆盖”或像素一致。

| 审查项 | 当前结论 |
| --- | --- |
| 入口一致性 | 右键、长按、Shift+F10、context-menu 键和 hover 更多进入同一 `showOfficeMessageActions` |
| 常用消息动作 | 表情回应、回复、复制非空正文、转发、话题、Agent 协作、置顶/取消置顶、阅读状态、原文均有实际入口 |
| 作者动作 | 编辑、撤回仅对本人未撤回消息显示 |
| 完整表情 | 菜单有完整 picker 入口；快捷反应使用 canonical 经典表情 ID |
| hover 更多的位置 | 此前默认居中缺口已补：组件上报按钮位置，conversation 将位置传入公共菜单 |
| 延迟菜单身份 | conversation 在打开与返回后比对工作身份及会话，丢弃旧上下文结果 |
| 已撤回消息的快捷表情 | 21:34 只读审查发现桌面/手机快捷表情行仍无条件显示，手机“全部表情”亦然；已同步主实现修复，最终闭合与菜单回归以集成记录为准 |
| 新增待办候选 | 已有真实 createTask API 可作为后续功能基础，但未建立飞书对应菜单证据，本轮不新增功能 |
| 收藏、标为未读、消息深链接、翻译、提醒、多选 | 现有参考没有确认具体菜单与流程，客户端也没有已确认的专用业务闭环，不能用无效按钮补齐 |

特别注意“标为未读”不能通过降低累积 `read_seq` 实现：该水位具有单调语义，需要独立产品状态与服务端协议。原文弹窗当前使用 endpoint/principal 字符串绑定身份，尚未纳入 state 对象和 generation；已作为后续一致性审查项同步，不在本测试文件中修改它。

## 验证记录

```text
flutter test --no-pub test/conversation_list_badges_test.dart
9/9 PASS

flutter analyze --no-pub lib/ui/conversation_list.dart test/conversation_list_badges_test.dart
No issues found

flutter test --no-pub test/message_hover_tools_test.dart
13/13 PASS

flutter analyze --no-pub test/message_hover_tools_test.dart
No issues found
```

两项分别执行的专项测试共 22 项通过。原折叠会话回归曾在集成生产源码临时依赖不完整时联跑失败，不计入这 22 项；全项目回归、菜单撤回修复、真实后端交互以及原生桌面/移动端实机验收由主集成文档单列。
