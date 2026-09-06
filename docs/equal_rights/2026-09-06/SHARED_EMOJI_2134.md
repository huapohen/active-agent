# 共享表情选择、最近使用与消息图文渲染

- 记录时间：**2026-09-06T21:34:48+08:00**（Asia/Shanghai）。
- 分支：`equal_rights`。
- Active Agent 集成前基线 commit：`345bfad3bdc07f31eccf6bd6bd53894627a02cc8`，时间 `2026-09-06T20:40:31+08:00`，描述 `docs: record folded conversation and broadcast delivery`。
- 本批记录时尚未提交；以上为基线，最终实现 commit 由主线集成记录补充。
- 描述：提供统一表情选择器、个人最近使用、可读图片表情与消息内联渲染，供输入框、回应、更多与悬浮工具栏共用。

## 共享接口与目录

新增 `apps/office/lib/ui/office_emoji.dart`。

| 接口 | 语义 |
| --- | --- |
| `OfficeEmojiGlyph(id:, size:)` | 规范 `feishu:CODE` 使用白名单中的本地图片；Unicode 使用平台字形 |
| `officeEmojiText(id)` | 把图片表情规范 ID 转为消息载荷 `:feishu:CODE:`，Unicode 保持原样 |
| `OfficeEmojiPicker(state:, onSelected:, width:, height:)` | 内嵌选择器，返回规范 ID，服从外层尺寸约束 |
| `showOfficeEmojiPicker(context, state)` | 手机底部面板、桌面弹层；可关闭，结果同样是规范 ID |
| `OfficeEmojiText(content:, style:, onAction:, selectable:)` | 已知图片表情 token 与文字混排；默认保留选择能力，也可让外层处理长按 |

使用现有 `assets/emoji/catalog.json` 的 **4,126** 个唯一条目、十类目录与中英文别名。`emoji_assets.dart` 中 **182** 个经典图片表情均指向打包 PNG，不从用户消息中的字符串构造任意文件路径或远端图片地址。

默认分类为经典表情，也支持全部、最近使用、其他类别。搜索按中文名称、英文别名、代码与 ID 匹配；搜索跨类别。网格采用 `GridView.builder`，根据可用宽度调整列数，实际只构建可见区域附近的项目。鼠标悬浮显示大图及名称预览；只预览不会选择或写入最近使用。

目录只解析并缓存一次公共数据，缓存同时保留解析值，后续选择器不依赖最初加载时的异步执行上下文。Picker 本身遵守父容器约束，已覆盖 380×430 菜单容器与 300×300 小屏区域，未出现布局溢出。

## 当前身份的最近使用

使用服务端真实协议：

- `GET /emoji/recents` 读取 `emoji_ids`。
- `POST /emoji/recents` 只发送 `{emoji: <规范ID>}`。
- `DELETE /emoji/recents` 清空当前身份的记录。

不会传 `principal_id` 或指定其他成员；人类和 Agent 使用同一路径及权限。后端最多保留 32 项，选择器按返回顺序呈现。

选择立即回传规范 ID，用于原输入/回应动作；记录请求在弹层关闭前启动，记录失败不会取消选择。内嵌选择器保留未同步提示，可只重试记录而不再次回调选中动作。离线仍可选择表情写入本地草稿，最近使用不会冒充已同步。

“清空最近使用”只出现在最近使用分类，断网或其他写入尚未完成时禁用。DELETE 成功才清空界面，失败保留记录并提供重试。清空等待期间暂停新选择，避免清空与新记录竞争。

选择器捕获 state 对象、身份代次、端点与 principal ID；身份变化时永久锁定、清空搜索和个人最近使用。旧 GET 不能覆盖新的选择，旧身份的 GET/POST/DELETE 回执和保留的点击回调也不能重新显示旧身份数据。

## 消息与话题

`agent_message_content.dart` 的正文改用 `OfficeEmojiText`。无已知 token 的消息保持原 `SelectableText` 行为及选择菜单；未知 token 原样保留。已知 token 使用内联图片和文字渲染，不改变保存的消息正文或 Agent 动作回执校验。

为使手机长按进入完整消息操作面板，`OfficeEmojiText` 和 `AgentMessageContent` 增加默认 `true` 的 `selectable` 参数。传入 `false` 时使用 `Text` / `Text.rich`，展开的动作回执原文也不会插入内部文本选择控件；外层长按不再被 `SelectableText` 抢占。独立“选择文本”入口由主线提供。

同一渲染器已接入 `message_thread.dart` 的话题原消息和后代回复正文。阅读状态依照最新要求调整：单聊已读为红色单勾，群聊已读数量和名单状态使用项目蓝色 `accentColor`。主时间线、回应工具栏和其他触发入口由主线接入，本文不将尚未接线的入口算作已完成。

## 本批验证

- `office_emoji_test.dart`：**15/15 通过**，包括目录唯一性、全部 182 个打包文件 PNG 签名、人/Agent 同权、中文/英文搜索、惰性网格、真实鼠标悬浮预览、最近使用乱序读回执、离线、失败重试、DELETE、身份切换、手机/桌面弹层结果、普通文本与图片 token 混排，以及纯文字/图片混排均由外层接收真实长按。
- `agent_message_content_test.dart` + `message_thread_receipts_test.dart`：**18/18 通过**，确认既有 Agent 动作回执展示与新话题/阅读状态行为未被图文渲染破坏。
- 增加可选文本选择参数后，重新运行表情与 Agent 正文两文件：**20/20 通过**；五个相关源/测试文件 analyze 零问题，`git diff --check` 通过。

测试使用合成身份和 API fixture；素材从实际打包 assets 读取。未操作真实飞书设置、发送真实消息、清空真实账号最近使用或重启本地服务。目录来源及素材获取记录由相应素材清单说明，不将本项目选择器宣称为本轮飞书实际交互复测。
