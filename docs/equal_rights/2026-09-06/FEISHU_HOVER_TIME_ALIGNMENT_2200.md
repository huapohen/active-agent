# 飞书桌面消息悬浮时间位置实测与修正

- 记录时间：2026-09-06 22:00:20 +08:00。
- 分支：`equal_rights`。
- 实现基准：`7e305492b996a1c0a8f727db8d353d97f742c4bc`，2026-09-06 21:53:08 +08:00，`feat(office): deepen native chat interactions and complete shared emoji`。
- 本文记录基准提交之后的独立增量；本轮最终 commit 由集成交付记录列出。旧观察与测试报告保留。

## 真实观察与原实现差异

2026-09-06 21:55，主集成 Agent 在恢复后的 CUA 中实际左击飞书桌面群聊文本，并让鼠标停留在消息上。截图确认：操作工具栏贴在消息右上方；时间为灰色 `HH:mm`，示例为 `15:30`，位于气泡左侧的头像列中段。它不是工具栏上方的一整行年月日时间。本轮负责实现的子 Agent 使用该次真实观察结果，没有再次接管共享桌面，也没有将之前的源码审查当成飞书实测。

基准实现将完整 `YYYY/MM/DD HH:mm:ss` 放在工具栏上方，这使工具栏整体按包含日期行的高度上移。本轮把两个元素拆成独立 OverlayPortal 子区域：工具栏仍按消息右侧对齐并贴近上沿，灰色时间单独放到气泡左侧，垂直对齐消息中点。两者均不占用消息列表布局空间。

## 本轮实现

- 默认时间区域宽度 36 px、与气泡间隔 8 px，即左边缘约在气泡左侧 44 px。12 小时制或字体缩放产生更宽文本时，时间向左扩展，保持气泡侧间距。
- 可见文字只使用 `officeHourMinute`；24 小时制显示 `13:04`，12 小时制显示 `下午 1:04`，遵循应用注入的 MediaQuery 时间设置。
- 时间区域 Tooltip 保留完整日期与秒，可供进一步查看；完整时间不再常驻工具栏上方。
- 工具栏与时间分别约束在屏幕边缘 8 px 内。时间为空或不可解析时，不显示时间，也不改变工具栏锚点。
- 鼠标从消息移入时间或工具栏时保持悬浮状态，离开后的原关闭延迟保留；时间 Tooltip、完整表情选择和消息动作继续工作。

修改范围仅为 `apps/office/lib/ui/message_hover_tools.dart` 与 `apps/office/test/message_hover_tools_test.dart`。没有修改消息菜单项、会话逻辑或表情目录。

## 验证

专项测试 **18/18 通过**，分析 **No issues found**，`git diff --check` 无问题。

```text
flutter test --no-pub test/message_hover_tools_test.dart
/tmp/active-office-hover-time-20260906-2200.log

flutter analyze --no-pub lib/ui/message_hover_tools.dart test/message_hover_tools_test.dart
/tmp/active-office-hover-time-analyze-20260906-2200.log
```

原有 13 项悬浮动作、表情面板、卸载与隐藏状态测试全部保留。新增 5 项验证 12 小时制、完整时间 Tooltip、左上和右下屏幕边缘、无时间时的工具栏锚点。关键矩形断言确认消息自身与后一条消息在鼠标进入、时间显示和完整 Tooltip 展开后都保持原坐标。

测试环境使用 Ahem 字体，数字比真实桌面字体更宽，因此测试断言时间向左扩展且保留间距，避免把字体差异误判成布局错误。本轮专项证明浮层锚点和交互稳定；手机端长按菜单、实际消息右键菜单的完整复刻与新构建的原生验收由主集成继续记录。
