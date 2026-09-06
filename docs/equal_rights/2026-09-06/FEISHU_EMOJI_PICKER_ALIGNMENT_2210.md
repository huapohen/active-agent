# 飞书表情面板桌面与手机实测对齐

- 记录时间：2026-09-06 22:10 +08:00。
- 分支：`equal_rights`。
- 编写时实现基准：`7e305492b996a1c0a8f727db8d353d97f742c4bc`，2026-09-06 21:53:08 +08:00，`feat(office): deepen native chat interactions and complete shared emoji`。
- 本文记录基准之后的独立 UI 增量。最终 commit 由集成交付记录补充，不将基准 commit 当成本轮实现提交。

## 已实际观察的交互

以下为主集成 Agent 通过恢复后的 CUA 实际操作所得；子 Agent 没有再次占用共享桌面。截图与原始操作由主集成保留。

| 时间 | 实际操作与结果 |
| --- | --- |
| 21:51 | 桌面点击表情面板：面板约 340 × 400，滚动内容先“最常使用”两行七列，再“默认表情”七列；底部固定加号、笑脸、齿轮 |
| 21:57 | 手机长按消息，菜单顶部有六个快捷表情及更多入口 |
| 22:01 | 点击手机快捷表情后的更多入口，出现约半屏高的表情 sheet；顶部有拖动条，图片约 28 px，最近两行七列，默认七列，上方保留聊天 |
| 22:01 | 拖动 sheet 顶部 handle 从 y≈400 到 y≈190，实际扩大到顶部 y≈98，约 85% 屏幕高度，背景变暗；展开后可以在 sheet 内滚动内容 |

此前共享 picker 默认常驻搜索框及横向十余个分类 chip；本轮根据真实观察改为更直接的经典表情快选。飞书加号与齿轮的具体完整业务没有在此次操作中逐项确认，不能据此声称自定义表情包、第三方表情商店或组织专属包已经复刻。

## 本轮交互

默认页使用一个 `CustomScrollView` 和 lazy `SliverGrid`，同屏顺序为“最常使用”快捷区与“默认表情”。快捷区展示本人最近记录中的前 14 个，满额时两行七列；默认区保留全部 182 个已打包经典表情，七列，每个图片 28 px、行高 42 px。没有捏造本人使用历史：没有记录时显示空态。“最常使用”的补充提示明确说明当前按最近使用排序，并非声称后端已经保存使用频率。

顶部默认仅保留小搜索按钮；点击后展开输入框，仍能按中文、英文、经典 code、canonical ID 与 Unicode 搜索全目录。原分类入口收进底部加号打开的二级表情库，没有丢掉任何目录项。

底部固定三个真实入口：

- 加号：打开包含全部 4,126 项的表情库及分类。
- 笑脸：返回默认表情与最近快捷区。
- 齿轮：查看本人全部最多 32 条最近使用记录，并能通过真实 DELETE 接口清空。

桌面独立弹窗为 340 × 400；共享组件继续适应消息工具栏提供的 380 × 430 约束。固定底栏不会随表情滚动离开视口。同步失败和离线提示保留在底栏上方，避免选择表情后滚动位置把错误与重试入口藏起来。

手机使用真正的 `DraggableScrollableSheet`：初始 45%，可以从顶部 handle 拖至 85%，并在最大高度继续滚动表情。handle 与网格属于同一个接入 sheet `ScrollController` 的滚动内容，不是装饰条；父 modal 不再截获该拖动导致误关闭。展开后背景仍保留原聊天；固定底栏不滚动。键盘出现时 sheet 让出键盘 inset，搜索框与底栏保持在键盘上方。

## 接口与数据完整性

保留 `OfficeEmojiPicker(state, onSelected, width, height)` 和 `showOfficeEmojiPicker(context, state)` 的使用方式与 canonical ID 返回值，仅增加可选 `scrollController`、`showDragHandle`、`onClose` 参数。桌面 hover 中的调用无需改生产代码。

Human 与 Agent 仍使用同一目录和本人最近使用接口。目录仍为 182 个经典表情 + 3,944 个 Unicode 17.0 fully-qualified 表情，共 4,126 项；图片资源和后端目录没有改动。个人最近记录仍最多 32 条，选择仍先发身份绑定 POST 再关闭 modal；离线可以选择本地表情，禁用最近记录同步与清空。

重复出现在默认区和最近快捷区的同一表情使用不同 UI key，返回的业务 ID 不变。工作身份变化后，两个区的旧回调都会失效；不会通过旧最近快捷项向新身份写入。

## 验证

```text
flutter test --no-pub test/office_emoji_test.dart test/message_hover_tools_test.dart
37/37 PASS = emoji 19 + hover 18
/tmp/active-office-emoji-layout-20260906-2210.log

flutter analyze --no-pub lib/ui/office_emoji.dart test/office_emoji_test.dart test/message_hover_tools_test.dart
No issues found
/tmp/active-office-emoji-layout-analyze-20260906-2210.log
```

保留原目录唯一性与 PNG 完整性、中文英文搜索、lazy 渲染、预览、离线、重试、清空竞争、旧 GET 竞态、身份变更、移动与桌面 canonical 选择等测试。新增验证覆盖两行七列及 28 px 图片、最近与默认同一滚动区、固定底栏、全部 32 条管理、快捷回调身份失效、二级分类、code/Unicode 搜索，以及真实手势将 45% sheet 扩至 85% 后滚动内容。手机测试还注入 300 px 键盘 inset，确认搜索与底栏不被键盘遮挡。

hover 测试仅适配默认面板的新入口：先验证最近与默认两段，点击搜索按钮后再搜索经典点赞；其余原有动作、时间与卸载覆盖保持。全项目构建、原生新 UI 验收和整批 commit 由主集成记录。
