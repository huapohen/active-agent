# 人机 startup 阶段交付：原生回复、显式反应与鉴权表情

交付整理时间：2026-09-09T08:17:47+08:00。分支为 `startup`。本阶段实现已提交；真实 Clerk 人类登录和机器只读验收已通过。新账号尚无工作空间或会话，商业消息界面实测与融云客户端接收仍待完成。本文在发布前冻结，后续文档同步结果由独立回执记录。

实施提交：`50570cac03b1314c831fc856e6ed826f60486fa8`。提交时间：`2026-09-09T07:55:18+08:00`。描述：`feat(startup): deliver native replies reactions and authenticated emoji`。

本阶段把原先只在迁移入口可用的回复与表情回应接入 Go 商业消息领域，并让 HTTP、MCP 和 Eino 执行工具使用同一套消息、身份和动作事实。人类使用界面，Agent 使用原生接口；二者共享权限和持久数据，但停止 Agent 执行不会禁止人类继续沟通。完成的是这组具体能力及其验证，不代表整个办公 IM、全部飞书页面或五个平台都已完成。

## 一、这一阶段改变了什么

回复只由调用者提交原消息 ID。服务端确认原消息与当前会话相同，再保存作者、消息序号和最多 240 个 Unicode 字符的摘要。调用者不能提交自选作者或伪造引用正文。重放返回最初保存的快照；即使原作者后来改名，动作回执也不会悄悄变化。当前商业领域还没有消息撤回、删除的完整生命周期，这一阶段没有把它们视为已经接通。

表情操作从不确定的 toggle 改为明确的 `active=true/false`。同一主体、同一 `action_id` 与同一意图只产生一次持久动作；不同意图复用 ID 返回冲突。反应状态、消息反应版本、计数、当前身份是否已选、事件以及待派发 Outbox 在同一数据库事务里提交。即使状态本来就匹配，新动作也保留 `changed=false` 的事实；原动作重放不新增事件和 Outbox。

客户端在请求结果未知时保留原 ID 和原目标状态，只能核对原动作。旧幂等回执里的计数可能已经过时，因此确认后再读取当前单条消息，而不是把旧回执直接覆盖到界面。点读失败仍保留原动作。换身份或会话会取消请求并丢弃迟到数据。

每条消息先显示最多 20 类回应；“查看全部回应”可以读取完整分页，每页最多 50 类。后续页携带首屏反应版本，版本改变则清空旧列表并从头读取，避免拼接不同时间的统计。完整列表中的本人回应也可以取消。

消息历史支持超过第一页：`before=0` 取最新消息，后续使用最旧已接收序号向前读取；已有 `after` 顺序导出保留。真实 PostgreSQL 测试遍历了 205 条消息，无重复序号或缺页。客户端另外检查所属会话、递增序号、游标和边界，房间事件游标不会被误用为消息历史游标。

## 二、协议覆盖与调用语义

所有下列商业接口位于独立 Go 服务的 `/v1`，使用当前有效的商业身份或服务器绑定的机器身份。它们不读取迁移 token，不回退到旧账号认证，也不接受调用方自报的 principal 或 executor 作为身份。

|     |     |     |     |     |
| --- | --- | --- | --- | --- |
| 能力  | HTTP/API | MCP | Eino / 执行动作 | 本阶段边界 |
| 同会话回复 | `POST /v1/rooms/:room/messages`，可选 `reply_to` | `message_send` 增加 `reply_to` | 规划 `message.send` 动作，payload 可带 `reply_to` | 摘要由服务端生成；机器写要求真实 Run |
| 明确添加/取消反应 | `POST /v1/rooms/:room/messages/:message/reactions` | `message_reaction_set` | `reaction.set`，`active` 必填 | stable action ID；原动作核对不重复变更 |
| 单条当前消息 | `GET /v1/rooms/:room/messages/:message` | `message_get` | `im_message_get` | 包含服务端回复摘要及有界反应汇总 |
| 全部反应分页 | `GET /v1/rooms/:room/messages/:message/reactions` | `message_reaction_read` | `im_reaction_list` | `after/limit/expected_version`；版本冲突重新读取 |
| 真实表情目录 | `GET /v1/emoji` | `emoji_list` | `im_emoji_list` | 搜索、分类、offset/limit、revision；无目录时不可用 |
| 单个表情条目 | `GET /v1/emoji/entries/:id` | `emoji_get` | 可由目录工具查精确稳定 ID | 不把任意字符串或任意 URL 当成表情资源 |
| 经典表情图片 | `GET /v1/emoji/assets/*path` | 目录返回认证资源路径 | 工具返回资源描述，不自动访问图片 | Bearer 鉴权、ETag、字节校验；没有凭据 URL |
| 历史与导出 | `GET /v1/rooms/:room/messages` | `message_read` 支持 `after` 或 `before` | `im_message_read` 本轮仍只支持 `after` | REST 与 MCP 可向前翻历史；同次请求不可混用两个方向 |
| 实际能力声明 | `GET /v1/capabilities` | `tools/list` 随部署过滤 | binding 提供 `action_types/read_capabilities` | 未声明、缺字段、未知版本不推断为已接通 |

`message.reply`、`message.reaction.set`、`message.reaction.read`、`emoji.read` 有明确能力 ID。客户端只在版本 `1` 且 `available:true` 时开启相关入口。协议登记仍明确 `a2a:false`；有 API/MCP 不等于已经完成 A2A 服务端或所有软件/硬件插件连接。

机器写入经注册 executor、持久 Run context、当前工作区及全部继承来源范围检查。来源停止、撤权、策略版本变化、绑定版本变化或旧 epoch 都不能通过重试复活。Eino 的新增读取工具在 HTTP 和可替换 Reader 两层验证数据；读取期间发生来源失效，会丢弃结果，不写入工具轨迹或交给模型。工具参数不能覆盖网关地址、凭据或身份。

## 三、表情资源与可配置能力

本地 provider 固定读取已配置的绝对目录并验证只读快照：共 4,126 个稳定 ID、10 个分类，其中 182 项为经典 PNG、3,944 项为 Unicode 17.0 表情。它使用已有资源，没有调用 Doc Free、Flutter 服务、CDN 或外部图片网站。目录和每张图由 manifest 固定字节大小及 SHA-256；分页与资源使用 revision/ETag，HTTP 改写资源路径后重新计算响应标识。

浏览器与 Electron 通过当前身份请求图片，限制路径、类型与大小，并把实际图片字节 SHA-256 与目录固定 ETag 比较；即使响应头相同，损坏字节也拒绝。blob URL 仅存在于当前组件，卸载或换身份即释放。上述校验是完整性证明，不是数字签名或图片商业授权证明；已有来源与授权说明保持在资源文档中。

配置能力可以替换，但没有宣称无条件热更新。provider 启动后持有已验证快照；变更磁盘文件不会自动改变运行中的目录，更换 bundle 需要重新构造或重启并校验。目录未配置时，能力声明、MCP 工具和底层反应校验同时禁用；复用 Store 构造无目录服务时会清除旧 validator，避免旧配置残留继续放行。已配置但损坏的 bundle 明确报错，不静默借用迁移服务。

本轮没有增加“最近常用表情”、企业自定义贴纸或私有图片包，也不把这 182 张图称为当前飞书客户端所有经典图的完整集合。[本地 provider 的配置、完整性与来源说明](https://github.com/huapohen/active-agent/blob/28187632b76bce6d0f45a6c1b3f8fb1755b9773a/services/collaboration/internal/emoji/README.md)。

## 四、人类界面与认证现场

暂停语义已纠正：`room.stopped` 表示暂停 Agent 执行范围。人类仍能编辑、点击发送或按 Enter 发言；界面提示“Agent 执行已暂停，人类同事仍可沟通”。Agent 的已有草稿保留，但输入与发送禁用。服务端也验证了暂停后人类可介入，不能只靠前端按钮实现授权。

迁移入口保留旧真实账号和数据，旧 reaction toggle 的未知结果仍先刷新，不能擅自当成商业幂等 set。原生 Electron 已以真实迁移账号登录，完成消息右键、打开准确引用草稿、取消草稿的操作；本轮这次界面验收没有发送聊天。它证明旧交互在升级后可用，不证明 Clerk 商业会话已经登录。

商业注册入口改为 Electron 同源路由中的 Clerk SignUp/SignIn 组件，继续保留导航保护，没有以关闭安全策略换取外部跳转。主线程已经实际进入同源注册页。

### 商业人类认证：已登录，新账号尚无会话

08:10 的观察仍停在真人验证，已作为历史证据保留。随后用户亲自完成 Cloudflare 和邮箱验证码，并报告登录成功；主线程实际检查 Electron 已进入 `/` 商业工作空间，明确显示“当前使用企业身份与正式消息服务”，个人菜单显示“人类同事”。这次没有回退到迁移认证。

08:14:39 +08:00 只读核对数据库：当前 Clerk issuer 下恰有一份真实 `user_` 人类绑定，未禁用，显示名为“新同事”，工作空间和会话成员数均为 0。这个名字是 Go 首次绑定的默认昵称；注册表单只有 email/password，没有 username 字段，因此不能称为已把 Clerk username 或人机昵称设置成用户要求的账号名。

原生检查还确认商业“创建群聊”和“查找 Agent 同事”入口禁用，云文档尚未接入该客户端，融云状态显示“暂不可用”。现有服务端只向受控测试身份发 SDK token，普通客户端写入绕过网关的策略尚未闭合，本轮没有放开这一限制。融云仍是必用服务；提供商命令受理与新账号客户端连接分别记录，不能互相代替。

本次完成的是实际注册后的商业登录、Go 持久身份与空会话界面验证。由于尚无会话、建群入口未接通，本次没有执行商业 Human 的回复/反应 GUI 验收，也没有新业务消息外发。[旧注册阻断观察](https://github.com/huapohen/active-agent/blob/28187632b76bce6d0f45a6c1b3f8fb1755b9773a/docs/startup/2026-09-09/evidence/message-interactions-runtime/native-auth-observation.json)、[当前原生登录验收](https://github.com/huapohen/active-agent/blob/28187632b76bce6d0f45a6c1b3f8fb1755b9773a/docs/startup/2026-09-09/evidence/message-interactions-runtime/human-native-acceptance.json)、[持久身份只读回执](https://github.com/huapohen/active-agent/blob/28187632b76bce6d0f45a6c1b3f8fb1755b9773a/docs/startup/2026-09-09/evidence/message-interactions-runtime/human-identity-readback.json)和[商业登录实际截图](https://github.com/huapohen/active-agent/blob/28187632b76bce6d0f45a6c1b3f8fb1755b9773a/docs/startup/2026-09-09/evidence/message-interactions-runtime/clerk-human-login-native.png)分别记录先后事实。

### 真实 Clerk M2M 只读验收

`2026-09-09T08:03:35.063+08:00` 至 `08:03:50.974+08:00`，独立的 attempt2 仅发出一次机器令牌创建请求，获得 HTTP 201；创建前后完整列表精确增加一个新 ID。原申请的 unknown 记录保持，不因本次成功而被改写成成功或确定拒绝。旧申请意图和三份原环境文件的 hash 前后相同，没有替换既有 runtime 凭据。

使用本次实际有效的 Clerk M2M 凭证，11 次 Go API / MCP 只读检查全部 HTTP 200 且语义断言通过：`/v1/me` 返回持久 executor 绑定的 Agent；实际能力 17 项，机器工具 12 项，目录 4,126 项；图片 PNG 头与实际字节 SHA-256 匹配；`before=0` 最新消息页、REST 点读、反应页和 MCP `message_get` 来源与内容一致。9 次 GET 加两次仅用于 `tools/list`、`message_get` 的 MCP POST，没有业务消息写入、Outbox 派发、worker 启动或模型调用。看到 reply/reaction 能力声明，不等于本轮用真实机器执行过这两种写入。

该临时凭证到期时间为 `2026-09-09T09:03:41.826+08:00`，这里记录的是验收时有效的事实。脱敏回执位于本机 `output/startup-message-interactions-20260909/machine-read-acceptance-attempt2-20260909-080335-a6b50746.json`，SHA-256 为 `2d8f861fd68593fd52ee49a0ad52e273b647449d54654f09976ce3fb8efea63e`；同目录 `machine-attempt2-acceptance.md` 记录单次签发与旧配置保护。完整凭据不进入交付文档。[已归档的 M2M 验收报告](https://github.com/huapohen/active-agent/blob/28187632b76bce6d0f45a6c1b3f8fb1755b9773a/docs/startup/2026-09-09/M2M_MESSAGE_READ_ACCEPTANCE_0803.md)和[脱敏回执](https://github.com/huapohen/active-agent/blob/28187632b76bce6d0f45a6c1b3f8fb1755b9773a/docs/startup/2026-09-09/M2M_MESSAGE_READ_EVIDENCE_0803.json)可复核本轮结果。

## 五、真实运行与验收边界

Go public 数据库已由 schema 5 迁移到 6，应用 `00006_message_interactions.sql`。迁移前先保存 69,093 bytes 备份，SHA-256 为 `52eca4318e60d901f56f5bfe32ebc8a59767259150f72e4bf311c674c77072f9`。迁移前后既有 4 条消息、6 条 Outbox、15 条动作数量相同；新增 reactions 为 0，健康检查返回 `renji.v1 / renji-collaboration / rongcloud`。这是该次迁移的前后保护事实，不是对以后其他已授权操作的全库不变承诺。[迁移回执](https://github.com/huapohen/active-agent/blob/28187632b76bce6d0f45a6c1b3f8fb1755b9773a/docs/startup/2026-09-09/evidence/message-interactions-runtime/migration-receipt.json)。

08:09:48 +08:00 又核实了实际监听 API 的二进制：Go buildinfo 中 `vcs.revision` 为本阶段 `50570cac03b1314c831fc856e6ed826f60486fa8`，当前只有一个服务监听，健康端点继续报告 `transport=rongcloud`。这不是根据二进制文件名推定版本。[运行版本与健康回执](https://github.com/huapohen/active-agent/blob/28187632b76bce6d0f45a6c1b3f8fb1755b9773a/docs/startup/2026-09-09/evidence/message-interactions-runtime/runtime-final.json)。

真实 PostgreSQL、Gin API、HTTPGateway 与 Eino DeepAgent 的隔离联调使用确定脚本模型和 Temporal testsuite，完成“查目录 → 读单条 → 读反应 → 取消当前 Agent 的反应 → 同会话引用回复 → 持久执行完成记录”。数据库有 2 个动作、2 个绑定 Run 的 pending Outbox；取消后统计由两人变一人，当前 Agent selected=false。这里没有调用真实 LLM，也没有把 pending 写成融云送达。

07:50:05 +08:00，真实融云已受理一次 `RC:CmdMsg` 反应失效通知，返回 `code=200` 和同群非空 messageUID `D0GD-MSGD-GO4E-75D4`。此次使用既有三名合成身份和受控群，只进行了 1 次官方群成员查询与 1 次命令发送；没有注册、建群或普通文本外发。原动作再次执行返回同一持久回执，随后没有新派发。

这次外部受理有明确隔离限制：canonical 合成消息在临时 schema 中，本地文本派发被测试范围故意阻止，临时 schema 最后清理；该消息不存在于 public 业务消息表。因此它证明真实融云命令受理与 Outbox 记录，不证明客户端收到、已读或能在 public 中刷新该消息。`delivered` 只是现有 Outbox 枚举，在本证据中必须解释为“提供商已受理”。[完整受控范围、请求及字节回执](https://github.com/huapohen/active-agent/blob/28187632b76bce6d0f45a6c1b3f8fb1755b9773a/docs/startup/2026-09-09/RONGCLOUD_REACTION_ACCEPTANCE_0753.md)。

|     |     |     |
| --- | --- | --- |
| 验收层 | 结果  | 能证明的范围 |
| 完整 Go 测试 | 208 顶层 + 252 子项，合计 460 条通过，0 失败、0 跳过 | 本地真实 PostgreSQL 隔离 schema 及代码测试 |
| 最后受影响 HTTP race | 19 顶层 + 4 子项，23 条通过 | 包含目录移除的新增回归；与完整套件重叠，不相加成新的唯一用例总数 |
| Web 最终测试 | 12 个文件，85/85 通过 | 包含同源 Clerk 入口及人类暂停期间发言语义 |
| Desktop 测试 | 6/6 通过 | Electron 壳既有约束回归 |
| 类型检查、vet、Web 生产构建 | 通过  | 构建仍有大包体阈值和融云浏览器包 `path` externalized 提示 |
| public 迁移 | schema 5 → 6，旧数量不变 | 已记录备份及迁移时刻的前后对比 |
| 原生 Electron 迁移入口 | 已登录；引用草稿与取消通过 | 本轮无聊天发送，不等于商业 Clerk 登录 |
| 真实 Clerk Human | 用户完成验证后，Electron 商业首页及持久 Human 身份通过 | 无会话；昵称编辑、建群及商业消息界面实测仍待接通 |
| 真实 Clerk M2M | 单次 201 签发，11 项只读检查通过 | 实际 Agent 身份、目录和消息 API/MCP 读取；无业务写入 |
| 融云真实受理 | 1 次命令获得匹配 UID | 没有客户端收包、已读或 canonical 刷新端到端证明 |

[最终测试统计](https://github.com/huapohen/active-agent/blob/28187632b76bce6d0f45a6c1b3f8fb1755b9773a/docs/startup/2026-09-09/evidence/message-interactions-runtime/tests.json)及[证据文件 SHA-256 清单](https://github.com/huapohen/active-agent/blob/28187632b76bce6d0f45a6c1b3f8fb1755b9773a/docs/startup/2026-09-09/evidence/message-interactions-runtime/MANIFEST.json)已归档。原始聚合测试与迁移回执在本机 `output/startup-message-interactions-20260909/tests.json`、`migration-receipt.json`；GUI 截图为同目录的 `legacy-reply-native.png` 和 `clerk-signup-policy-native.png`。这些路径是工作区证据位置；对外发布附件应以主线程最终归档的副本与清单为准。

## 六、已有交付保护与阶段缺口

既有执行与自动归档 v1/v2 保持，未修改旧 Workflow/Activity 名称或历史分支。旧档案 v2 的专门摘要计数仍只识别 `message.send`；本轮反应动作完整存在原始执行证据里，尚未新增专门反应摘要或把模型文字当完成证明。

截至本文冻结，新文档发布尚未执行。已用独立 publisher 草稿读取并保护 5 份旧 Doc Free 源、10 份 AFFiNE/Docmost 投影和 4 组配置/journal。每份旧源的人类与 Agent 完整 JSON 相等，非成员全部 403；再次读取与初始保护相同。旧 publisher 未运行或覆写。发布将只新增本阶段源文档和两个投影；实际新 ID、正文 hash、原生模型比对与旧资源保护由后续独立发布回执记录。

仍待后续阶段完成：新账号工作空间/建群与昵称设置、商业人类登录后的消息界面验收、真正可刷新 public canonical 的融云客户端收包、商业会话成员目录与 Agent 超级入口、未读锚点和已读统计、撤回/删除/转发等消息生命周期、A2A 与更广泛插件能力，以及全部桌面/移动平台的签名、分发与完整办公页面。

## 七、专题与后续操作入口

以下链接按正式文件位于 `docs/startup/2026-09-09/` 设计，便于发布时统一转换为不可变 Git 文档链接。专题保留编写当时的测试与未提交时点；本阶段最终实施归属为本文顶部的 `50570cac03b1314c831fc856e6ed826f60486fa8`，不能把该实施版本继续称为未提交。

- [消息回复与反应的持久领域、事务及权限](https://github.com/huapohen/active-agent/blob/28187632b76bce6d0f45a6c1b3f8fb1755b9773a/docs/startup/2026-09-09/MESSAGE_REPLY_REACTION_DOMAIN_0730.md)。
- [MCP/HTTPGateway/Eino 工具与配置能力](https://github.com/huapohen/active-agent/blob/28187632b76bce6d0f45a6c1b3f8fb1755b9773a/docs/startup/2026-09-09/NATIVE_EMOJI_REACTION_TOOLS_0744.md)。
- [React 商业回复、回应、图片和身份边界](https://github.com/huapohen/active-agent/blob/28187632b76bce6d0f45a6c1b3f8fb1755b9773a/apps/web/docs/COMMERCIAL_MESSAGE_ACTIONS_20260909_0734.md)。
- [真实融云命令受理及隔离限制](https://github.com/huapohen/active-agent/blob/28187632b76bce6d0f45a6c1b3f8fb1755b9773a/docs/startup/2026-09-09/RONGCLOUD_REACTION_ACCEPTANCE_0753.md)。
- [表情 provider 部署、完整性与资源说明](https://github.com/huapohen/active-agent/blob/28187632b76bce6d0f45a6c1b3f8fb1755b9773a/services/collaboration/internal/emoji/README.md)。
- [手动启动服务、Electron 和手机 Flutter 教程](https://github.com/huapohen/active-agent/blob/28187632b76bce6d0f45a6c1b3f8fb1755b9773a/docs/startup/2026-09-09/MANUAL_STARTUP_GUIDE.md)。