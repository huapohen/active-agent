# 会话摘要表情与加急滚动布局修补

> 验证版本边界：本文 525/525 与全量分析结果针对 2026-09-07 08:54:28 开始验证的合并转发、布局和成员详情批次。随后新增的输入发送框像素校准尚未包含在这份结果中，必须以该增量之后重新运行的检查为准。

- 记录时间：2026-09-07 00:01:08 +0800，Asia/Shanghai。
- 本次修补开工记录：2026-09-06 23:50:48 +08:00；问题来自 09-06 的原生截图，未改写已发布的 09-06 交付文档。
- 分支：`equal_rights`。
- 本批实现基准：`cd34da4d28be4e92111b201b96a96caa0e6aedcc`，2026-09-06 23:43:40 +08:00，`feat(office): add personal sidebar collapse and native message attention`。
- 开工时 HEAD：`09fe83f19cdee6d242fd4903d1a76d4c451b491d`，2026-09-06 23:48:19 +08:00，`docs(office): publish verified sidebar attention and identity delivery`。
- 本文记录上述基准之后的 UI 增量，最终实现 commit 由主集成补充；本子任务未提交，没有修改 `conversation.dart` 或 `office_state.dart`。

## 问题来源与本次范围

前一轮 [截图审计](../2026-09-06/VISUAL_ATTENTION_REVIEW_2345.md) 确认两个可见问题：桌面会话摘要露出 `:feishu:SMILE:` 存储编码；加急的可滚动渠道区在默认小窗中未完整露出，缺少明确的下方内容提示。本批仅修补这两个问题，并保留既有成员权限、未读证据、发送幂等与渠道禁用规则。

加急的问题是可滚动正文和固定操作区之间的可发现性，不是已证实的不可恢复布局溢出。原截图中的取消/发送按钮本来可以看见；本次没有把它们描述成“原先无法使用”。

## 一行会话摘要使用可读表情名称

`OfficeConversationRow` 是桌面和手机共用的会话行。摘要通过共享 `officeEmojiLabel` 获取经典表情名称：例如 `:feishu:SMILE:` 显示为 `[微笑]`，`:feishu:OK:` 显示为 `[OK]`。没有复制另一份表情词典；未知 token 原样保留，便于兼容未来的表情类型。

紧凑摘要继续使用 Text 的一行省略，不增加图片造成的行高变化。名称、时间、提及、未读角标和直接消息已读标识保持原布局。消息预览关闭或消息已撤回时，先采用隐藏/撤回占位，再做摘要处理，不解析或暴露原来的私有消息正文。

## 加急渠道更紧凑，滚动路径明确

成员选择与渠道选项使用更紧凑的现有列表样式，缩短应用内确认说明，三种 RadioListTile 仍然保留。仅应用内可发送，短信/电话仍明确显示未配置并禁用；没有增加后端未支持的渠道值。

发起页正文增加专用 ScrollController 和可见滚动条。固定操作区上方仅在正文下方仍有内容时提示“下方还有成员或发送方式，继续滚动查看”；到达末尾后提示消失。它是滚动说明，不是假按钮，也不改变当前已选成员或自动发送请求。

正文和底部操作仍是 Column 中不同的区域。最后一项渠道说明必须能完整滚入正文视口，不依靠被按钮覆盖的区域阅读。手机 modal 的高度明确受键盘后的可用约束限制；拖动正文允许收起软键盘，固定发送区保持在键盘上方。相同 modal 宿主继续服务加急详情和列表，没有更改它们的业务协议。

## 实际修改文件

| 文件 | 作用 |
| --- | --- |
| `apps/office/lib/ui/conversation_list.dart` | 已知表情名称摘要，未知编码保留 |
| `apps/office/lib/ui/message_urgency.dart` | 紧凑渠道、滚动条/提示、手机可用高度约束 |
| `apps/office/test/conversation_list_badges_test.dart` | 摘要、行高、已读/未读与隐私占位回归 |
| `apps/office/test/message_urgency_layout_test.dart` | 新增真实 modal 布局与键盘/多成员回归 |

原 `message_urgency_test.dart` 本轮没有修改，作为现有业务回归一起运行。

## 验证

```text
flutter test --no-pub test/conversation_list_badges_test.dart test/message_urgency_test.dart test/message_urgency_layout_test.dart
39/39 PASS = 摘要/角标 12 + 原加急业务 23 + 新布局 4
/tmp/active-office-summary-urgency-layout-test.log

flutter analyze --no-pub lib/ui/conversation_list.dart lib/ui/message_urgency.dart test/conversation_list_badges_test.dart test/message_urgency_test.dart test/message_urgency_layout_test.dart
No issues found
/tmp/active-office-summary-urgency-layout-analyze.log
```

新增摘要测试在 290 和 390 宽的会话行内同时检查已知名称、未知 token、一行省略、相同行高以及已有已读/未读标识；另测隐藏预览和撤回内容没有泄漏。

新增布局测试通过真实 `showOfficeMessageUrgency` 打开 Dialog/BottomSheet，没有把独立 widget 直接铺满大屏来替代小窗。覆盖 1079 × 709 桌面内容视口与 390 × 700 手机逻辑视口，检查默认状态有可见的剩余内容提示或已经露出最后说明，并实际滚动至最后渠道、正常取消返回。

另外两项覆盖 390 × 700、300 高键盘、50 位候选成员和 1.0/1.6 字体缩放。测试验证电话说明完整位于正文可见矩形内、在固定操作区上方；操作区底部不超过键盘顶端；到末尾后提示消失；没有非 GET 请求。

这些是明确的 widget 逻辑视口，不把它们冒充含系统标题栏、模拟器外壳的原截图像素尺寸。没有从本次测试推导原生飞书像素等价、iPhone 真机或所有平台已经完成实点。主集成仍需在最新原生构建中复看两个修补点，并保存同状态截图。

## 交付边界

本批未增加 API、MCP/A2A 工具、模型调用或新的发送渠道。合并转发、会话主界面与企业成员状态由其他任务负责。未知表情、渠道未配置、用户未选择成员、身份失效、离线或来源变化等原有边界继续由原加急业务与列表回归覆盖。

本批文件交给主集成冻结、构建与提交；本子任务不操作共享的真实飞书焦点。

## 2026-09-07 08:55 验证续记

此前专项日志在续接时已不存在，因此本轮重新执行，而没有仅复述旧通过结果：摘要/角标与加急布局 16/16 通过，证据 `/tmp/renji-ui-regression-0907.log`；原加急业务与企业目录 36/36 通过，其中加急业务 23 项，证据 `/tmp/renji-ui-business-directory-review-0907.log`。前述三组本文件专项仍为 12 + 23 + 4 = 39 项，混合运行总计 52 项额外包含企业目录 13 项。

最终源码冻结后，2026-09-07 08:54:28 再运行完整 Flutter 套件，51 秒完成，525/525 通过，包含新增合并转发入口的全部 20 项测试。日志 `/tmp/renji-office-final-ui-docs-0907.log`；最终全量分析 `No issues found`，日志 `/tmp/renji-office-final-ui-docs-analyze-0907.log`。这些检查更新了当前源码证据，没有覆盖或修改此前发布的共享文档。

新增完整检查仍不替代本批摘要、加急在最终原生客户端中的截图和操作验收；主集成实际完成的路径及最终 commit 由本日综合交付记录承接。


## 最终实现提交索引

| 仓库 | 最终实现 commit | 实际 Git 时间 | 描述 |
| --- | --- | --- | --- |
| Active Agent | `7570ac2d81b119f14280fc4bf9866151b57e1059` | `2026-09-07T10:27:19+08:00` | `feat(office): align native composers and share rich conversation records` |
| Doc Free | `c34de6ac2e3ec67c7f10f3ef6e2090438d2598a0` | `2026-09-07T10:18:02+08:00` | `feat(im): preserve rich text across native actions and merged forwards` |

本文件中的早期专项或草稿状态按其记录时间保留。最终验证、原生实点与发布范围统一见 `COMPOSER_RICH_TEXT_MERGED_DELIVERY_1027.md`；本批最后Flutter全量为636/636，静态分析无问题。
