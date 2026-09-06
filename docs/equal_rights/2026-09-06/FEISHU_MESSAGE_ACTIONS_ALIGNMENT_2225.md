# 飞书消息长按与右键菜单实测对齐

- 记录时间：2026-09-06 22:24:32 +08:00。
- 分支：`equal_rights`。
- 基准 commit：`7e305492b996a1c0a8f727db8d353d97f742c4bc`，2026-09-06 21:53:08 +08:00，`feat(office): deepen native chat interactions and complete shared emoji`。
- 本文描述该基准之后的消息操作菜单增量；最终实现提交由本轮集成报告补充。

## 真实观察

主集成 Agent 在本轮恢复的 iPhone Mirror 中实际长按消息，并拖动面板展开到完整高度。完整手机菜单的顺序确认如下，子 Agent 根据这些操作结果实现，没有另行占用共享手机。

1. 顶部六个快捷表情及 `…` 更多入口。
2. 四格主操作：回复、转发、创建话题、复制。
3. 第一组：撤回（观察到旧消息呈灰色）、加急、多选。
4. 第二组：标记。
5. 后续组：Pin、置顶消息、复制消息链接、禁止转发、翻译、企业内搜索、网页搜索、删除。

主集成还实际进入多选：消息左侧出现圆形复选框，顶部右侧为取消，底部为可横向滚动的操作栏，可见合并转发、逐条转发、复制消息链接、添加任务、导出到文档及右侧未完整显露的快捷入口。该多选页面由主集成实现，本文件只负责菜单入口与返回协议。

手机 sheet 的半屏到高屏展开已在 22:01 的表情实测中验证；消息菜单本轮按同一真实可拖动结构补齐，不再使用仅有装饰 handle 的固定高度滚动容器。

## 菜单实现

手机使用真正的 `DraggableScrollableSheet`，初始 45%，最大 85%；顶部 handle、快捷表情、四格主操作和分组列表全部接入该 sheet 提供的同一 ScrollController。拖动到最大高度后继续滚动内容。四格主操作保持一行，不把全部菜单动作挤入多行图标网格。

可用菜单项按实测顺序整理为撤回/多选、标记、置顶/复制消息链接/转发限制。选择文本、编辑、Agent 协作、创建任务、导出、阅读状态与查看原文保留在后续分组；“删除消息（仅自己）”位于底部。桌面右键与更多沿用同一动作定义，完整显示已接通 handler 的能力，按紧凑行展示。

已撤回消息不显示表情回应、回复、编辑或转发限制切换。有效 `no_forward` 使转发入口禁用；作者自己的 `forwarding_own_no_forward` 决定切换项显示“允许转发”或“禁止转发”。个人 `personal_preferences.marked` 决定“标记”或“取消标记”。不把他人标记或继承的转发限制误认成作者自己的设置。

## 接口合同

```dart
Future<String?> showOfficeMessageActions(
  BuildContext context,
  Json message, {
  required bool own,
  Offset? position,
  OfficeState? state,
})
```

旧调用继续可用。传入 `state` 后，面板绑定打开时的 OfficeState 对象、identityGeneration、endpoint、稳定 principal ID 与会话 ID。身份或会话变更永久作废该面板；迟到的最近使用响应不会恢复旧面板，保留的旧点击回调不会派发动作。

| ID | 显示与用途 |
| --- | --- |
| `multi_select` | 多选，由会话接入批量模式 |
| `mark` | 标记 / 取消标记，仅本人偏好 |
| `copy_link` | 复制消息链接 |
| `forwarding` | 作者允许 / 禁止转发 |
| `hide` | 删除消息（仅自己），不等同于撤回 |
| `task` | 创建任务 |
| `export` | 导出消息 |

原有 `reply`、`forward`、`topic`、`copy`、`select`、`agent`、`pin`、`edit`、`retract`、`read`、`original` 保留。具体任务、导出、链接、多选和个人集合的 handler 由主集成负责，不能单凭本菜单测试宣称后端业务闭环完成。

## 个人快捷表情

传入 state 后通过本人 `GET /emoji/recents` 读取前六项，不传其他 owner。不足六项时从六个经典默认表情补足，网络失败或离线仍能选择本地经典表情。Human 与 Agent 使用同一逻辑。

选择快捷项返回 `react:canonicalId`，以当前身份发起一次最近使用 POST；记录属于尽力同步，不阻塞消息动作。点击更多会先关闭消息菜单，再打开完整共享 picker，最终仍返回 `react:canonicalId`；完整 picker 自己记录最近使用，外层不会重复 POST。没有 state 的兼容调用继续返回 `emoji` 交给原处理器。

## 尚未实现的真实差距

本轮不增加没有 handler 的加急、翻译、企业内搜索、网页搜索或快捷应用空入口。实测中的 Pin 与置顶消息是两个可见入口，当前只有一个既有 `pin` 能力，未制造第二个无独立语义的入口。飞书旧消息撤回灰态涉及服务端时间窗，而当前服务端尚未提供该规则；本轮只按作者与撤回状态控制，未编造客户端时间限制。

合并转发和更多快捷操作未在此子任务实现。跨端全面复刻仍需继续对照这些差距推进。

## 验证

```text
flutter test --no-pub test/message_actions_menu_test.dart
24/24 PASS
/tmp/active-office-message-menu-20260906-2220.log

flutter analyze --no-pub lib/ui/message_actions.dart test/message_actions_menu_test.dart test/message_interaction_test.dart
No issues found
/tmp/active-office-message-menu-analyze-20260906-2220.log
```

覆盖所有新增 action 在桌面和手机各返回一次、作者权限、个人标记、禁转发状态、六个快捷项与四格首行、真实 45%→85% 拖动后滚动、Human/Agent 本人 recents、完整 picker 单次记录、身份/会话变更与迟到响应、离线本地选择。

旧 `message_interaction_test.dart` 的两处撤回点击改为先滚动至该菜单项，符合新分组列表位置。主集成个人集合源文件落盘后，旧互动 **8/8** 已通过；以下为同批后续完成的正文右键与多选集成验证。

## 22:36 正文右键与真实多选集成补充

新集成测试识别出此前未覆盖的缺口：桌面直接在 SelectableText 正文右键时，Flutter 文本选择菜单会先于消息外层右键区域处理事件，只提供部分动作。此前仅验证“回复”存在的测试不足以证明完整消息菜单已出现。

本轮为 `OfficeEmojiText` 和 `AgentMessageContent` 增加可选 `onOpenMessageMenu(Offset)`。文字的 contextMenuBuilder 读取真实右键全局锚点，通过一次 post-frame 跳转先关闭文字工具栏再打开完整消息菜单，避免 build 阶段导航或两个菜单同时出现。纯文本继续使用 SelectableText，已知经典表情混排继续使用 SelectionArea；无新回调的旧 onAction 行为保持。Agent 展开的服务端动作回执正文也使用相同转交逻辑。主集成在 conversation 传入稳定身份、代次、会话与多选状态守卫的回调。

新增 `conversation_multi_select_test.dart` **10/10**，使用真实正文右键或手机长按进入完整菜单，不把桌面测试目标移到非正文 padding。验证包括：

- 正文与经典表情混排直接显示一份完整菜单，包含多选、复制消息链接和选择文本；没有残留原文字选择菜单。
- Checkbox 实际勾选、取消勾选和取消多选恢复输入区。
- 复制消息链接先逐条 GET 当前消息，再按消息 seq 生成坐标链接；刚被个人隐藏的消息不会复制。
- 三条逐条转发时第一条成功、第二条失败：保留失败与未尝试两条；重试仅调用第二、第三条，不重复第一条。
- 同一 principal 的 identityGeneration 变化清空选中项；迟到的 GET、单条转发、批量转发失败均不向下一身份显示旧提示。

部分失败会显示 Snackbar，测试等待该实际提示消失后点击底部重试按钮，避免点击被遮挡按钮制造假失败。转发目标弹窗打开时批量状态仍有工作指示器，测试等待有限的弹窗过渡帧，不对持续工作的指示器调用无限 settle。

`conversation_viewport_test.dart` 的手机菜单入口断言更新为真实“全部表情”和回复四格入口；原有面板遮挡期间不报告新已读、关闭后恢复报告的断言完整保留，并在滚动菜单至取消之后再次确认未新增底层阅读报告。

```text
flutter test --no-pub test/conversation_multi_select_test.dart test/message_interaction_test.dart test/conversation_viewport_test.dart test/office_emoji_test.dart
42/42 PASS = 多选 10 + 旧互动 8 + viewport 5 + emoji 19
/tmp/active-office-multi-select-20260906-2230.log

flutter analyze --no-pub lib/ui/office_emoji.dart lib/ui/agent_message_content.dart test/conversation_multi_select_test.dart test/conversation_viewport_test.dart
No issues found
/tmp/active-office-multi-select-analyze-20260906-2230.log
```

该 42 项联跑与前述 24 项菜单专项覆盖范围不同，不能直接与全项目总量相加。全项目最终回归、真实后端与原生新构建验收继续由主集成交付记录汇总。
