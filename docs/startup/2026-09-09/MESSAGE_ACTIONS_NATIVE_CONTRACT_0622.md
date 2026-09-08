# 新电脑端消息浮层、表情回应与回复

- 记录时间：2026-09-09T06:22:05+08:00。
- 已提交基线：`d4814e6`（文档）；实现基线：`a639a8843093bed98b04b375d361de6e2c2129c9`，2026-09-09T05:56:24+08:00。
- 最终实现 commit：`2fc663150ec66fa2c402e1a38668264f0d961e5a`，2026-09-09T06:37:12+08:00，`feat(startup): automate execution archives and add native message actions`。本文消息交互与布局修复已包含在该提交中。
- 范围：`apps/web` 的 Electron/Web 共用 React 界面和 Legacy 适配器。不修改 Flutter、Go、Doc Free 源码或生产鉴权策略。

## 实际交互

消息悬浮工具栏、右键菜单、源发送时间和表情面板通过 `document.body` portal 绘制，使用 fixed 定位，不进入消息气泡的排版。旧行内工具栏节点已移除，鼠标进入不会向列表插入新高度。

工具栏提供表情回应、回复、复制、请 Agent 协作及更多入口；更多和右键共享四项实际动作。右键和 `Shift+F10` 可打开菜单，方向键移动操作焦点，`Escape` 关闭并还原消息焦点。工具栏和表情面板之间允许 180ms 的移动间隔；鼠标移出后关闭。会话切换、身份更换、列表滚动、窗口失焦和退出页面均关闭临时控件。

回复保留原消息 ID，编辑区显示引用和取消按钮。取消引用保留已输入文本；发送成功清除引用。发送结果不明确时，同一内容、提及和引用组合继续使用同一 `client_id`。源消息隐藏、撤回或读取失效后，引用不再显示旧正文，发送按钮暂时禁用，用户可以取消引用或刷新确认。

请 Agent 协作先引用当前消息，再打开当前会话真实 Agent 成员选择器。选择后以真实 Agent principal ID 添加提及。打开入口本身不会自动发送消息。

## API 与身份边界

| 稳定能力 ID | 实际 Legacy API | 本轮行为 | Startup / Go |
| --- | --- | --- | --- |
| `im.messages.reply` | `POST /api/im/rooms/:room_id/messages`，`reply_to` | 原消息引用，沿用 `client_id` 去重 | 未接入，明确拒绝 501 |
| `im.messages.reactions.toggle` | `POST /api/im/rooms/:room_id/messages/:message_id/reactions`，`{emoji}` | 使用服务端实际 reactor ID/count 显示和取消 | 未接入，明确拒绝 501 |
| `im.emoji.list` | `GET /api/im/emoji?q=&category=&offset=&limit=100` | 搜索、分类、分页加载 | 未接入，明确拒绝 501 |

上述 Legacy API 已在 Doc Free 原生服务实现；对应既有 MCP 分别为 `im_send` 的 `reply_to`、`im_react`、`im_emoji_catalog`。本轮复用这些 API，不宣称 Go/MCP/A2A 新服务已经实现同等覆盖。

反应接口是 **toggle**，不支持客户端幂等键。UI 对一次操作只发一个请求，不自动重试，不乐观伪造人数。失败或超时后锁住反应入口，显示结果待确认；用户成功刷新服务端状态后再操作。服务端应答必须属于请求的 room/message；撤回和隐藏消息的正文、附件、提及、反应不能经解析器恢复。

凭据继续只由现有 adapter 获取并写入 Authorization header，禁止重定向，不进入 URL 或持久化浏览器存储。查询按 client 实例生成身份代次；切换身份或会话后卸载旧交互、取消请求并隔离缓存，旧写入应答不能进入新会话。

## 表情资源与当前差距

实际 Doc Free 目录为 4,126 项、10 个分类，其中经典表情 182 项。目录、搜索结果和分页游标来自鉴权 API。经典 PNG 复用 `apps/office/assets/emoji/feishu`，由 Vite 构建到本地资源；不会跟随服务端返回的任意图片 URL，也不向第三方 CDN 发送聊天上下文。来源与权属仍由 `apps/office/assets/emoji/README.md` 和 `feishu-sources.json` 记录，未重新下载或复制一份素材库。

根任务本轮实际查看飞书，默认表情面板显示 189 项，另有最常使用；本轮现有经典目录比该截图少 7 项，且未接最近使用栏，不能称为完整视觉复刻。转发、创建话题、加急、撤回、多选、标记、Pin、置顶消息、消息链接、翻译、禁止转发、删除、任务、导出文档和快捷应用等其余菜单项均未纳入这次 React 实现，不显示虚假的完成提示。

## 验证证据

- `npm run check --workspace=@renji/web`：通过。
- `npm run test --workspace=@renji/web -- --reporter=dot`：9 个文件、61/61 通过；相对原 42 项新增 19 项。
- `npm run build --workspace=@renji/web`：通过。已有大于 500KB 的应用/RongCloud bundle 提示仍存在，未把构建警告描述为体积优化完成。
- 日志：`/tmp/renji-message-actions-web-20260909.log`、`/tmp/renji-message-actions-build-20260909.log`。

新增测试覆盖 portal 在消息 DOM 之外、源时间、跨面板鼠标移动和离开、键盘/右键、引用去重与取消、真实分类/分页/表情 ID、中文输入期间不发送、反应不确定结果不重试、Agent 引用和提及、身份/会话切换及源隐藏后禁用引用。

`apps/web/src/message-native-http.test.ts` 额外启动随机 loopback 端口和独立临时数据文件，将真实 `LegacyClient` 请求送入相邻 Doc Free 仓库的 `createNativeIM`。该测试验证真实 Human/Agent 身份、回复重放只有一条消息、双方添加及取消经典反应、群外 403、无效引用 422，并完整读取 4,126 项目录（ID 无重复、182 项经典）。它不读取本机已登录账号、业务数据或模型凭据，也不调用文档服务和模型；结束后关闭端口并删除自己的临时目录。此集成测试需要相邻的 `doc_free` 仓库及其已有依赖。

上述为自动化和真实本地 HTTP 协议证据。原生和浏览器验收另外记录如下，不把 jsdom 测试当作像素或原生输入验收。

## 根任务原生与真实浏览器复验

根任务使用已登录 Electron，在自有合成消息上实际右键并选择回复：出现准确源时间 `2026/09/07 10:51:15` 和引用 `Stable toolbar 0907`。原生右键菜单的独立截图未能取得，证据来自实际 AX 菜单状态与进入引用后的截图，不能把截图缺失描述为菜单截图验收完成。

原生验收额外发现长会话列表引起外层整体滚动，左上头像和标题栏离开屏幕。修复只涉及 CSS：固定单行 grid 的可收缩轨道，列表/内容容器 `min-height:0`，会话列表独立滚动，登录后的 document 与 workspace 限制外层滚动。根任务重新点击列表下方会话后，确认头像、导航与标题固定；再次右键打开 Agent 引用正常。

- 修复前反例：`output/startup-automatic-archive-20260909/desktop-reply-before-layout-fix.png`。
- 修复后原生 Agent 引用：`output/startup-automatic-archive-20260909/desktop-agent-reply.png`。

根任务通过真实浏览器 CUA mouseMoved 完成消息 hover → 表情 → 移入面板 → 移出：1280×720 视口中，10 条已加载消息的每项 DOMRect 在前/中/后完全一致，document x/y 滚动均为 0，表情层确实在消息行之外，最后 toolbar 和 palette 数量都为 0。这证明此次交互路径没有列表伸缩或残留面板；不代表所有飞书页面像素一致。

- 数值证据：`output/startup-automatic-archive-20260909/web-hover-layout-evidence.json`。
- 打开/关闭截图：`web-hover-palette.png`、`web-hover-closed.png`，位于同目录。
- 早期表情打开截图采集时部分图片仍在加载；最终加载检查及截图见下文。

## 最终图片、反应与桌面状态

根任务等待图片完成后再次验证，当前页 100/100 张经典表情图片均 `complete=true` 且 `naturalWidth>0`，0 张失败；面板底部显示 4,126 个匹配表情。证据为同目录 `web-palette-loaded.png` 和 `web-palette-loaded.json`。此结论只覆盖当前已加载的 100 张图片；全部 4,126 项目录完整性由前述真实 HTTP 分页测试验证，两者不混为全量图片原生验收。

根任务在真实 UI 上对自有合成消息 `Stable toolbar 0907` 选择点赞，出现 `feishu:THUMBSUP`、人数 1 及本人已回应状态；再次点击取消并刷新后不再显示该反应。这次验证没有发送消息。已保存 `output/startup-automatic-archive-20260909/web-reaction-committed.png`；最终已登录电脑端状态保存为同目录 `desktop-final-logged-in.png`。

根任务的最终阶段测试汇总为 Web 61/61、Desktop 6/6、Go 175 个顶层与 204 个子测试通过；其中本消息子任务独立执行范围仍为前文 Web 类型检查、构建、61 项测试及真实隔离 HTTP 联调。最终桌面继续使用明确的 Legacy 迁移登录模式，不将此验收描述成 Clerk 人类商业登录或 Go 新消息链全量完成。

可随仓库复核的本阶段截图、布局测量、完整加载与回执证据见 [已归档证据清单](evidence/automatic-archive/MANIFEST.json)；上述 output 和 /tmp 路径保留为本机原始运行记录。
