# 展开输入框与真实富文本：独立组件交付记录

版本定位：前文为 **09:51 初次交付记录**；文末“10:21 视觉审阅修复补记”更新减少缩进、图标尺寸、真实 Agent 协作接口和测试结果。早期 24 项结果不代表最终集成验收。

记录时间：2026-09-07 09:51:01 +08:00。分支：`equal_rights`。

基准 commit：`09fe83f19cdee6d242fd4903d1a76d4c451b491d`。本文和本次组件修改仍在工作区，最终提交 SHA 由集成交付记录补齐；基准 commit 不代表已包含本次实现。

## 本次交付范围

移动端展开输入框采用白色全屏页面，保留可选标题、右上角收回、正文输入区和底部表情、@、图片/附件、文字格式、缩进、Agent 超级入口、发送按钮。桌面端采用独立编辑窗口并提供取消和完成。正文使用 `OfficeRichTextEditingController`，所选文字在编辑区内实际显示加粗、斜体、下划线和删除线；保存原生范围数据，不插入 Markdown 标记冒充富文本。

文件：

- `apps/office/lib/ui/composer_expanded_editor.dart`
- `apps/office/test/composer_expanded_editor_test.dart`
- 共用已交付组件：`apps/office/lib/ui/office_rich_text.dart`

参考来自本机实看飞书手机端展开输入页，详见同目录 `COMPOSER_PIXEL_REFERENCE_0930.md`。参考截图中的真实账户水印保留在本机 `output/`，不纳入提交、不嵌入文档。本次 24 项 widget 测试确认布局约束与交互行为，不等于真机或像素对齐验收。

## 草稿与发送约定

入口为 `showOfficeExpandedComposer(context, state: ..., value: ..., mobile: ...)`。返回 `OfficeExpandedDraft?`，包含 `value`、`title`、`mentions`、`mentionAll`、`sendRequested`。

1. 手机右上角收回及系统返回均返回当前草稿，`sendRequested` 为 `false`；桌面完成同样只保存草稿。
2. 桌面取消返回 `null`，调用方保留原草稿。
3. 发送按钮只返回 `sendRequested: true`，组件本身不发送消息；消息写入由调用方在自身身份/会话验证通过后负责。
4. 非空标题以 `标题 + 换行 + 正文` 编入 `value.content`，标题自带加粗范围，正文格式位置按前缀 UTF-16 长度平移。重开仅在传入正文确实以记忆的 `title + 换行` 开头时拆分；标题记忆不匹配时保留整段正文，避免重复标题或误删第一行。
5. 字符合计上限 12000，原生格式范围上限 200。标题增加的范围也计入上限，超限保留窗口和全文，显示错误，不静默丢弃格式。

## 人与 Agent 交互

@ 入口先读取当前会话成员，核对房间 ID、成员列表及当前身份仍在成员中，再使用共享 `OfficeMentionPicker`。人类和 Agent 使用相同的成员 ID 选择语义；明确提及列表与 @所有人独立，不把展示文字当作提及协议。单聊不能带 @所有人。

若调用方未提供 `onAgent`，Agent 入口打开只显示 Agent 的选择器，保留已有真人提及和 @所有人。若调用方提供 `onAgent`，则调用该入口。调用方需要在应用返回草稿时合并进入展开窗口以后由外部 Agent 入口新增的提及 ID，避免被窗口开始时的副本覆盖。

表情使用现有共享表情库，插入 canonical 表情文本；选取时只记录本人最近表情，不产生消息写入。附件使用调用方提供的上传回调与名称 getter；上传中屏蔽重复触发和发送。桌面取消只取消文字编辑，不能被描述为撤销已经上传的附件，上传事务由调用方负责。

## 隔离与异步边界

窗口绑定 `OfficeState` 对象、身份 generation、服务 endpoint、principal ID、room ID。任意一项变化，立即清空标题、正文、原生格式、提及及 @所有人，移除编辑和发送入口。已捕获的旧发送回调不会返回内容。成员读取迟到后不能打开旧成员窗口；成员窗口已经打开时发生身份变化，也立即移除旧成员列表。附件异步完成后不会在失效窗口显示旧附件名称。

## 验证记录

独立测试：**24/24 通过**。分析：**No issues found**。

执行命令（目录 `apps/office`）：

```sh
/Users/lwblx/development/flutter/bin/flutter test --no-pub test/composer_expanded_editor_test.dart --reporter expanded
/Users/lwblx/development/flutter/bin/flutter analyze --no-pub lib/ui/composer_expanded_editor.dart test/composer_expanded_editor_test.dart
```

本机日志：`/tmp/renji-expanded-tests-0907.log`、`/tmp/renji-expanded-analyze-0907.log`。

测试包括全屏矩形、模拟键盘遮挡、标题加粗与 UTF-16 平移、标题重开/移除/不匹配保护、取消/完成/系统返回、发送仅产生返回意图、空正文及附件发送、RenderEditable 实际四种文字样式、列表前缀与格式保持、真人/Agent/@所有人、Agent 过滤、单聊保护、真实表情选择、同 ID 重新登录和切换房间清空、迟到成员请求、已打开成员窗口失效、错误房间和退群、附件重复点击与迟到结果、外部 Agent 回调、长度及 200 范围边界。

首轮为 22/24：一项测试误把单行标题输入的换行过滤视为保存后的空格行为，已改用真实可输入的单行标题；另一项发现 `FormatException` 经过共用错误文案处理会残留 `Format` 前缀，已在本组件保留其用户提示正文。第二轮完整 24 项通过。静态检查首轮无功能错误，仅测试中一个多余类型转换，已移除。

之前富文本组件独立 **30/30** 的记录仍适用于其自己的测试文件；之前全量 **525/525** 运行早于此次输入框工作，不能作为本次集成后全量验证结果。本文没有调用大模型，没有执行真实飞书消息或成员写入。

## 待集成验收

调用方接入、父草稿和附件生命周期、真实发送链路、桌面/模拟器运行、实际截图对齐、整体 Flutter 回归和最终 commit 由主任务继续完成。不能据此宣称输入区完整像素复刻或全量飞书复刻已经完成。


## 10:21 视觉审阅修复补记

源码/测试冻结时间：2026-09-07 10:21:04 +08:00。基准 commit 仍为 `09fe83f19cdee6d242fd4903d1a76d4c451b491d`；这是其后的未提交工作区修改，最终源码提交由主任务统一记录。

只读视觉对照发现手机实际工具图标偏小、展开底部缺少减少缩进，以及展开 Agent 图标的默认成员选择行为与普通输入区超级入口能力不一致。经主任务授权，已经完成以下修复：

- 展开页同时保留增加缩进、减少缩进和 Agent 图标。减少缩进对选中每段移除至多两个前导空格或一个制表符，不删除项目列表/编号标记，不修改未缩进正文；选择范围末尾刚好落在换行时，不处理下一段。正向和反向选择都保持富文本的 UTF-16 范围。
- 展开页移动端普通工具图标由 21 调至 27 逻辑像素，Aa 保持 19；桌面图标仍为 21。参考展开内容宽约 301 像素时，27 逻辑像素的本机绘制图标按内容宽归一化后约 17.75 像素，与参考约 17 像素接近。最终截图复核由主任务与输入区负责人继续完成，不能以该尺寸推算替代实际截图验收。
- `onAgent` 更新为 `OfficeExpandedAgentEntry`：`Future<List<String>?> Function(Future<bool> Function() saveAndClose)`。真实聊天调用方现提供完整 Agent 协作面板，直接返回原生成员 ID；展开页收到后立即合并提及。无回调的独立组件仍保留 Agent-only 成员选择器兜底，真实聊天不使用该兜底作为超级入口。
- 协作面板跳往工作记录或商店前，调用方必须等待 `saveAndClose()`：草稿校验失败返回 `false`，保留编辑器与完整内容；成功返回当前草稿，并让外层接收草稿后才允许导航。切换身份、房间或迟到回调均不能恢复旧提及。已有弹层在前时，不显示背景编辑器的持续加载动画；忙碌状态仍阻止重复触发。

专项最终结果：**32/32 通过，analyze No issues found**。

日志：`/tmp/renji-expanded-p2-tests-final-1022.log`、`/tmp/renji-expanded-p2-analyze-final-1022.log`。在原 24 项基础上新增 8 项：整组选中段落缩进往返及 UTF-16 格式保持、混合前导空格/制表符减少缩进、尾部换行选择边界、320 宽键盘场景八工具不溢出、真实 Agent 返回提及即时合并、身份变化后的迟到 Agent 结果、导航等待草稿接收、超长草稿拒绝导航。

第一次整体集成曾在 10:04–10:05 达到 Flutter 623/623，随后 analyze 清理了 5 项等价 lint 并通过；**该 623 结果早于本节新增行为，不能作为本节最终整体结果**。主任务已安排本轮全部源码再次冻结后的最终全量验证，其精确总数与新指纹在最终交付文档记录。手机麦克风仍以禁用入口诚实标示未接入，本文不宣称语音能力或全量飞书复刻完成。


### 本轮最终整体验证

2026-09-07 10:23:34–10:24:24 +08:00，Flutter 全量 **636/636 通过**，50.948 秒；10:23:34–10:23:37，完整 `flutter analyze --no-pub` 为 **No issues found**。这是本文件 10:21 新行为与调用方真实 Agent 导航完成后再次冻结的最终结果，替代之前的 623 项整体记录用于本轮验收。

日志：`/tmp/renji-office-full-tests-final-1024.log`、`/tmp/renji-office-full-analyze-final-1024.log`。前后 `apps/office` 442 个已跟踪/未忽略文件和 Flutter 输入 322 个文件内容指纹均一致；期间只有独立交付补记文档增加，不影响源码或测试输入。

Flutter 输入 SHA-256：`c344cb3fa674a41b4f291aa4ce245530ec8ffb46e5152de668b73687940b6ed7`。

`apps/office` 内容 SHA-256：`4e362a8b2d986543a0beb2b4fccef5a4107d2afabc27e871758278e957afcc95`。

本轮至此停止扩展测试；原生构建、截图实点和最终提交信息由主任务补齐。


## 最终实现提交索引

| 仓库 | 最终实现 commit | 实际 Git 时间 | 描述 |
| --- | --- | --- | --- |
| Active Agent | `7570ac2d81b119f14280fc4bf9866151b57e1059` | `2026-09-07T10:27:19+08:00` | `feat(office): align native composers and share rich conversation records` |
| Doc Free | `c34de6ac2e3ec67c7f10f3ef6e2090438d2598a0` | `2026-09-07T10:18:02+08:00` | `feat(im): preserve rich text across native actions and merged forwards` |

本文件中的早期专项或草稿状态按其记录时间保留。最终验证、原生实点与发布范围统一见 `COMPOSER_RICH_TEXT_MERGED_DELIVERY_1027.md`；本批最后Flutter全量为636/636，静态分析无问题。
