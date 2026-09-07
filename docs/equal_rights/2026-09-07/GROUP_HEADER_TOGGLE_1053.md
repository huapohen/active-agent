# 消息分组按钮随开合迁移：两端参考与交付记录

记录时间：2026-09-07 10:53:17 +08:00。
分支：`equal_rights`。基准 commit：`5a38f7fd42e2264f4896043cd35177aa9a8eb2ab`。
初始记录时修改位于该基准之后的工作区，尚未单独提交。现已随 commit `c28c5422fa67b5b6490d206f3f05b26a70e9286d` 提交，时间 2026-09-07T10:59:56+08:00，描述：`fix(office): relocate group toggle and stabilize mobile composer tools`。

## 已实看参考

主任务在用户已登录的飞书上实际点击开合，并提供当前截图。本子任务只读取截图，没有控制桌面或手机 UI。

- 手机关闭：`output/feishu-mobile-groups-closed-1039.png`。三条杠位于消息/未读快捷筛选左侧。
- 手机打开：`output/feishu-mobile-groups-open-1040.png`。左侧白色抽屉约占内容宽 78%，header 左为“分组”、右为收起按钮；主任务再次点击该按钮已确认关闭抽屉。
- 桌面打开：`output/feishu-desktop-groups-open-header-1042.png`。分组 header 左为三条杠，随后“分组”，右侧齿轮用于编辑；旁边消息栏不重复显示开关。
- 桌面关闭：`output/feishu-desktop-groups-closed-header-1042.png`。分组栏消失，开关留在原窗口位置并出现在“消息”标题左侧。

参考图含真实账户水印，仅保留本机，不纳入提交、不嵌入文档。

## 本次实现

修改 `apps/office/lib/ui/office_shell.dart` 和 `apps/office/lib/ui/message_group_widgets.dart`，新增 `apps/office/test/message_group_toggle_position_test.dart`。没有修改发送输入框、后端分组协议或 `office_ui_test.dart` / `mention_all_test.dart`。

桌面展开时，消息标题旁的开关被移除，在分组 header 左侧出现收起开关，右侧仍保留原有编辑齿轮。关闭后，开关回到消息标题左侧。两处采用一致的左内边距和 32×32 按钮布局，使同一窗口内开合按钮中心坐标一致；消息与分组标题使用一致的 15 号字。选择分组只改变会话过滤，分组栏保持打开；用户随后关闭仍保留选中的筛选。

手机打开抽屉后，消息快捷筛选旁的开关从底层界面移除，抽屉 header 右侧出现收起按钮。点击该按钮、点击遮罩、使用系统返回或选择分组，都会关闭抽屉并恢复消息旁的入口。header 左侧保留“分组”，右侧不额外加入桌面齿轮；原有设置页分组编辑入口保持可用，标题长按或右键也能进入分组管理。

分组导航只读取与筛选已有会话，按钮开合和筛选本身不会提交 PATCH/POST。编辑窗口取消后会回到原分组 header，开关位置保持不变。

## 生命周期与身份边界

- 桌面打开状态绑定工作身份；切换身份后恢复收起状态，旧分组回调不能选择旧标签或打开旧身份管理窗口。
- 手机打开时捕获身份，变化后立即用重新打开提示替代旧分组内容，关闭后可以在新身份下正常打开。
- 手机保留的关闭回调会检查原 drawer context 仍挂载且对应路由位于最前；不能误关闭其上方编辑窗口，也不能在旧抽屉销毁后关闭新抽屉。
- 桌面导航到其他模块再回消息时，同身份下原打开状态和开关位置保留。

## 验证

最终专项 **38/38 通过**：新增位置/状态测试 13 项，既有分组与折叠会话测试合计 25 项。三份修改/新增 Dart 文件静态检查为 **No issues found**。

执行目录：`apps/office`。

```sh
/Users/lwblx/development/flutter/bin/flutter test --no-pub test/message_group_toggle_position_test.dart test/message_groups_test.dart test/folded_conversations_test.dart --reporter expanded
/Users/lwblx/development/flutter/bin/flutter analyze --no-pub lib/ui/office_shell.dart lib/ui/message_group_widgets.dart test/message_group_toggle_position_test.dart
```

日志：`/tmp/renji-group-toggle-tests-final-1052.log`、`/tmp/renji-group-toggle-analyze-final-1052.log`。

新增用例包括两端重复开合三次且无重复开关、桌面同窗口按钮中心坐标不变、手机遮罩/返回/选择分组退出、桌面筛选后保留打开状态、两端管理窗口取消、标题右键管理、桌面切换模块返回、两端身份变化使旧回调失效，以及旧手机关闭回调不能误 pop 编辑窗口或新抽屉。

本记录没有把 widget 验证作为原生像素验收。主任务继续负责热加载后的 macOS 与 iOS 实点、截图复核以及整体交付提交信息。之前的 636 项全量验证早于本次分组迁移和新的手机发送方式，不作为本次最终整体结果。

## 最终补记：2026-09-07 11:05:35 +08:00

最终源码 commit 为上方 `c28c5422fa67b5b6490d206f3f05b26a70e9286d`。主任务已完成 macOS 原生打开 → 关闭 → 再打开，同窗口实际点击坐标 `(203,68)` 稳定；iOS 原生标题收起、遮罩关闭、选择分组关闭均恢复原入口。最终桌面原生参考采用指针移出后的 1057 截图。

Flutter 全量 **662/662 通过**，全项目静态分析无问题，macOS 构建运行与 Web 构建成功。详细日志、局部截图裁剪、手机宽度归一以及图标形状仍有差别的边界，见 [消息分组开合原生截图独立复核](GROUP_HEADER_NATIVE_QA_1100.md)。至此原生验证已完成，以上初始阶段“继续负责”是历史进度描述。
