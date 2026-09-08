# 2026-09-07 13:41：图 6 / 图 12 的会话列表与原生操作菜单

- 记录时间：2026-09-07T13:41:21+08:00，后续定向集成验证完成后更新。
- 分支：`equal_rights`。
- 已提交基准：`1774c284ba41d5db71ed77a4b905bd3db1c0369f`。
- 基准提交时间：2026-09-07T12:18:30+08:00。
- 基准描述：`docs(office): record mobile group fidelity and native verification limits`。
- 本文记录基准之后的工作树修改；本轮集成 SHA 由主任务提交后补录，不能把基准冒充新实现提交。

## 参考与问题

已实际打开用户提供的 `automation/2026/04_09/3/05/input/img/6.png`、`12.png`。图 6 的右侧飞书列表在标题右边显示活动时间，摘要右边显示真实免打扰状态。图 12 的飞书长按菜单贴在会话右侧，无整屏暗幕，文字在左、图标在右；人机原来直接打开带开关的“整理会话”大对话框，交互层级不一致。

此前已校准的 17 / 14 / 12 字号、48 圆头像及 68 基准行距延续，不回退。

## 列表修正

1. 手机不再构建常驻的三个点按钮，也不再保留其 26×24 布局占位，时间获得原本被挤占的横向空间；桌面保留可见菜单入口。
2. 时间取服务端 `last_message.at`。只有真正空会话才回退到服务端 `created_at`；无合法时间则保持空白，不使用本机当前时间伪造活跃记录。协议依据是 `doc_free/native-im.js` 的 `roomView` 字段投影。
3. 免打扰以 `preferences.muted` 为优先，兼容旧版顶层 `muted`；通知徽标计数使用同一来源。免打扰图标手机为 16，桌面为 12。
4. `OfficeConversationRow.onContextMenuAt` 提供该行的全局矩形。手机长按、桌面右键均可调用；旧的无位置回调仍保留兼容。

## 新会话菜单

新文件：`apps/office/lib/ui/conversation_context_menu.dart`。接口为：

```dart
showOfficeConversationContextMenu(
  context,
  state,
  groups,
  room,
  anchor: rowRect,
  onAgent: () async { /* 由壳进入当前会话的既有 Agent 面板 */ },
);
```

菜单贴近该行右侧，并限制在屏幕安全区域内。手机宽度最大 256，常规行高 46；桌面最大宽度 220，文字使用 14。透明背景遮罩允许看见会话列表，点击外部只关闭菜单。字体放大或小屏幕时允许菜单内部滚动。

| 菜单 | 当前状态反向文案 | 实际行为 |
| --- | --- | --- |
| 置顶 | 取消置顶 | `PATCH /rooms/:id/preferences`，只更新 `pinned` |
| 清除未读 | 无 | 只确认菜单所见的最新消息序号 `read_seq`；无未读或无合法序号时禁用 |
| 标记 | 取消标记 | `PATCH /rooms/:id/message-groups`，只更新 `marked`，带捕获的 `base_revision` |
| 标签 | 无 | 用户明确选择后进入已有标签/归组编辑器 |
| 允许消息通知 | 关闭消息通知 | 只更新该身份的 `muted` 偏好 |
| 完成 | 撤销完成 | 只更新个人会话归组 `completed`，带版本校验；不会修改任务状态 |
| Agent 超级入口 | 无 | 由主壳打开当前会话原有的 Agent 协作面板 |

置顶与收藏是独立的服务端字段。顶部置顶头像区由主任务结合 `pinned` 实现；本菜单写入的也是 `pinned`，不会用收藏伪装置顶。

打开菜单本身不切换会话、不清未读、不发消息。所有写入使用菜单来源的明确 `roomId`，不会用 `selectedRoomId` 代替来源，从而避免操作者长按另一行时误改当前打开的会话。

菜单捕获身份代次、端点和 principal。断连、身份变化或原会话不再可访问时，只移除本菜单拥有的路由；保留下来的旧点击回调不能关闭随后打开的新页面，也不能提交动作。已提交的请求如果晚于身份切换返回，不刷新新身份。

## Agent 入口接入原有输入区

`OfficeConversation` 增加 `agentEntryRequest` 和 `onAgentEntryHandled`。非零请求在首次挂载或属性更新后的下一帧处理，捕获身份、会话和会话选择代次。

先调用 `onAgentEntryHandled` 让主壳消费一次性请求，再次验证原作用域后调用已有 `_openComposerAgent(applyMentions: true)`。这使菜单与输入区 Agent 按钮使用同一组能力：添加 Agent、分派任务、工作记录、人格与参与、明确 `@` 协作。选择同事会回填现有草稿的提及信息；没有复制一个能力不完整的第二套面板。

请求在打开前已被消费，因此关闭面板后重挂载会话不会自动再次打开。消费回调引起身份变化时也不会进入旧上下文。

## 验证与范围

- 新菜单、真实时间与偏好徽标：27/27，通过；`/tmp/renji-room-context-menu-tests.log`。
- Agent 入口桥接：5/5，通过；`/tmp/renji-room-agent-entry-tests.log`。
- 新菜单 + 徽标 + Agent 请求 + 既有输入区 + 分组与开关交互联合验证：101/101，通过；`/tmp/renji-room-menu-integration-tests.log`。
- 六个实现/测试文件 analyze：通过；`/tmp/renji-room-context-menu-analyze.log`。

回归覆盖未读清理序号、源会话定位、单字段写入、版本冲突不重试覆盖、A→B→A 身份变化、旧回调不能关闭新路由、延迟写入不刷新新身份、桌面右键、标签子层级、真实 Agent 面板及草稿提及保留。

本子任务没有修改 `OfficeState`，没有操作真实企业消息或构建原生应用。主壳绑定、置顶头像区与最终原生截图由主任务集成验证。以上是图 6 / 12 的实现及自动化验证记录，不能替代七张图所有页面的原生逐页验收。
