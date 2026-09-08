# 人机 startup：文档原生核验与 Agent 执行证据阶段

记录时间：2026-09-09 05:44（Asia/Shanghai）。分支 `startup`。本文在实现提交前建立，提交信息在阶段收尾时补入；基线为 `380d7bef5b8ce78f6dae38b812e8aa9931ca67d1`。旧的 04:24 交付正文及其源文档保持原样，新事实另行追加。

收尾补记：实现 commit **`a639a8843093bed98b04b375d361de6e2c2129c9`**，Git 时间 **2026-09-09T05:56:24+08:00**，描述 **`feat(core): add native document verification and durable agent archives`**。专题文档中的“尚未提交”保留为当时状态；本行提供最终实现归属，文档本身另行提交。

## 本次解决的问题

电脑端以前只有云文档目录，无法在新 React 界面直接阅读正文；Agent 规划器不能原生读取授权消息；Temporal 结束后业务 Run 可能仍停留在 running；复杂文档的 Markdown 导出差异又使两平台的投影无法可靠签收。本批补齐这些具体路径，并开始将真实执行证据变成人和 Agent 都可读取的 doc_free 档案。

完整商业 IM、全量飞书界面、全部 Agent 原生办公操作仍是原目标。本阶段不是完整发布，也不把失败流程的可追溯性当作成功自主执行的证明。融云仍为必选传输。

## 用户可以直接查看的界面

Electron 电脑端保持 `huapohen` 已登录，当前为旧数据迁移模式。新文档阅读页显示标题、真实版本、时间、来源群以及完整正文；支持目录返回、所属会话、刷新。Markdown 通过 React 节点渲染，表格、标题、列表与代码格式可见。未绑定的本地相对链接明确显示状态；不把代码路径当作可打开的在线文档。

本机实际打开 `a74679d5` r1 的 7401 字正文，观察四张表格与页面排版，再点击“所属会话”，进入 `startup 文档投影合成验收 · 2026-09-09`、2 位同事的来源群，最后返回云文档目录。没有发送聊天消息。阅读页的权限失效隐藏旧正文、身份切换丢弃晚到响应由独立自动用例覆盖；本次未将这些用例夸大为所有端的原生视觉验收。

证据入口：[正文阅读器](CLOUD_DOCUMENT_READER_0510.md)。原生截图保存在本机 `output/startup-document-reader-native-20260909.png` 与 `output/startup-document-reader-source-room-native-20260909.png`。

## Agent 原生读取与模型协议

Eino 的 `im_room_list`、`im_message_read` 直接使用执行器上下文中的 Run；工具参数不能改变主体或 Run。每页读取检查当前权限、来源范围和停止代次，返回后再次检查。HTTP 与可替换插件的结果都必须满足房间 ID、消息序号、分页游标和数量约束；错误结果整页拒绝，不能将未经验证的数据交给模型。

新增显式 Responses 协议适配，使用 `RENJI_MODEL_API_STYLE=responses`。保留用户指定模型、思考强度与端点；失败时不隐式切换协议或模型。函数调用与结果按 call ID 延续；provider 返回的私有推理连续性字段仅保存在该次消息内存中，归档不包含它们。`final_answer` 与 `commentary` 分开处理，未知阶段、拒绝、未完成响应、重复调用 ID、歧义最终输出均不被当作有效规划。

独立回归见 [Responses 与原生读取复核](RESPONSES_NATIVE_READER_REVIEW_0526.md)。这些协议测试使用可控 HTTP 服务和假模型，不能代替真实模型效果验收。

## 真实 Temporal 运行结果

本机使用官方 Temporal CLI 1.8.3、服务端 1.31.2，namespace 为 `renji-startup`，监听 loopback 7233/8233，历史保存在 `data/startup/temporal/history.sqlite`。这是持久化的本地开发服务，不是生产集群。下载归档通过官方 SHA-256 校验，未清理或重建历史数据库。

| 实际 Run | 发生的事实 | 当前结果 |
| --- | --- | --- |
| `b94da23b-4cb9-4f06-a03d-701fc4475108` | 旧网关遗漏 `stage.input` 事件协议，在模型请求前拒绝；Temporal 先失败，旧业务状态仍 running | 保留原失败历史，随后以实际 Temporal 结果追加对账事件；PG 为 failed，2 条证据，0 个业务动作 |
| `76dedd18-1ddf-4fc0-abfa-19aee795b034` | 协议修复后实际启动，三次有界模型请求未获得响应 | Terminal Activity 写回 failed；PG 有 3 条 stage.input、run.failed 与 run.status，共 5 条证据；0 个业务动作 |

配置的模型端点直连 TCP 超时，系统代理路径也在 TLS 阶段超时；同代理可访问 GitHub，故没有将此问题误报为整个网络不可用。没有切换到另一模型或端点。失败后停止实际 worker，不继续自动制造付费尝试。

将真实 Temporal 服务正常停止，再用同一 SQLite 文件启动后，第二个失败流程的全部 19 个历史事件与重启前一致。此证据只证明本次失败历史恢复；成功多阶段规划、持久等待后续行、提交业务动作后的 worker 强杀恢复仍未验证。

Terminal 是独立持久 Activity，使用稳定事件 ID。取消后仍尝试写入终态审计，当前成员与执行器绑定仍受服务端校验；重试审计不会重做消息发送。若终态记录自身持续不可用，则保留需对账状态，不能凭 Temporal 结束推断 PG 已同步。

## 文档投影的实际修复与签收边界

源仍为 doc_free `a74679d5` r1，目标 AFFiNE `SLrA9aXyZV-vehgtC91W-` 与 Docmost `01a082b6-bade-7ef2-8bfc-02b75fcd97de` 均沿用原 ID。

Docmost 在 05:15 通过完整 ProseMirror 原生结构对比，原 journal 的未知记录保留，追加 `native_verified`；未改目标正文。重复对账没有新增 journal 或目标写入。

AFFiNE 原四张普通 table 丢失表头角色，并将单元格代码变成字面反引号。依据当前部署的官方 database v3 模型，在原四个块 ID 上转为原生数据库表格与富文本单元格。05:37:51 只发送一次冻结的 Yjs 增量，随后合法 HTTP/Socket 读取确认源标题、原 ID 和完整结构一致，54 个非表格块保持不变。新增 21 个行块，总 79 块。独立核对没有只依赖写入器自身的反解：逐原生类型检查 54 个原对象、每张表的行列顺序以及每个字符和格式。

AFFiNE 随后以正式 Go reader 对账，追加第 8 行 journal，为该绑定的第 4 条 `native_verified`。原 7 行逐字保留；再次运行不追加。源和两端的规范结构哈希均为 `903e9410dfa7c2d7945546fe4001f2ee2b34f1eb12d1b1a733fd269787b1e320`，原文 SHA 与结构 SHA 分别保存。

`native_verified` 不等于 Markdown 字节完全相同，也不等于像素验收完成。AFFiNE 浏览器仍需登录现有账号以核查最终布局；本轮没有通过注入会话或重置旧密码绕过此项。平台链接行为差异单独记录。已原生核验的 AFFiNE 数据库文档出现新源版本时，旧 Markdown writer 被禁止写入，返回 `affine_native_write_plan_required`；通用原生增量同步仍待实现。

## 执行证据与可见档案

`GET /v1/runs/:id/evidence` 与 MCP `run_evidence` 共用处理器，人和 Agent 都按当前身份访问真实事件、动作、Outbox 状态与 Run 状态。分页使用 Run 内共享序号并冻结上界。历史迁移快照明确标记 `legacy_snapshot`，不伪装成旧事实当时的提交序号。audit 可核查终态；execution 对终态和过期 Run 返回 409。

PostgreSQL 保存归档意图、片段、源游标、目标绑定、请求是否已发出及实际读回。模型总结与真实动作结果在文档中分开；未知目标创建不会自动重建，新增源游标也不能绕过尚未解决的旧意图。

05:50:47，真实 Clerk 机器身份经已配置执行器，创建第二个失败 Run 的 doc_free 档案 **`9d62380a` r1**，归档 ID `75ae64e9-7234-4293-8b15-8cbfb70faefb`，覆盖并核实证据游标 5。正文 SHA-256 为 `e37f8cacc7f3e26a53c66be9b0c89e90273e98ca1efc5da44109b980aa5d9fe9`。05:53 的独立回读中，人和 Agent 均返回 200，标题及本机重新计算的正文哈希与冻结归档一致；真实非成员返回 403。第二次调用得到同一归档对象、同一文档，原有三份文档的整个对象保持一致，总共仅新增一份。

根任务在已登录 Electron 的云文档目录找到并打开该档案，观察到真实版本、时间、五项证据及 `failed` 服务端状态。没有将空动作回执写成已办成任务。当前正文偏审计用途，完整 JSON 与哈希对用户过于技术化；下一版应在保留可核对原文的同时增加清晰的任务、阶段、失败原因和实际动作摘要，不改写已冻结的历史档案。

实际回执与截图：[双身份与幂等核查](evidence/execution-runtime/doc-free-archive-verification.json)、[电脑端档案画面](evidence/execution-runtime/doc-free-archive-native.png)。本份 Run 档案尚未投影到 AFFiNE/Docmost，不能用此前 `a74679d5` 的双目标签收覆盖新的档案。档案中的代码围栏等格式需要后续投影验收。

当前归档适配仅支持明确配置的 `single_source_synthetic` 模式：目标 URL、房间和身份映射由部署配置固定，模型不能选择。多来源与生产跨服务动态 ACL 尚未完成；目标成员读取与写入之间仍没有跨服务原子权限事务。本阶段不能将手动 CLI 归档称作已经实现持续自动调度。

## 本批检查与运行保留

- 冻结源码后的 Go 全套 `go test -race -p 2 -count=1 -json ./...`：**151 个顶层 + 173 个子测试**通过，0 个失败、0 个实际用例跳过。5 个 package skip 均为没有测试文件；真实 PostgreSQL 用例使用隔离 schema。`go vet ./...` 与 `go build ./...` 通过。
- 首轮根部全套遇到并发编辑期间的 import/vet 构建失败，未记为通过；冻结后重新运行的日志和完整用例名保存在[检查记录](evidence/execution-runtime/full-go-tests.json)。没有忽略该次非零退出。
- AFFiNE Node 14/14，包括独立原生类型与每字符格式复核；归档适配器/命令的独立 PG 复跑 13 顶层 + 14 子测试通过。Web 42/42、TypeScript 与生产构建来自本批先前已完成且行为源码随后未变的检查，原生阅读由根任务补验。
- 迁移 00004、00005 已应用；新版 API 在 3318 正常运行，健康信息仍声明必选 `rongcloud`。Electron 与 Vite、旧服务 3218/1238、Temporal 持久开发服务保留。实际模型 worker 与通用 transport-worker 当前停止；未再次派发旧 Outbox。
- 22 个本机私有敏感值与 68 个实现暂存文件逐值扫描，0 匹配。文档证据另做扫描；完整 token、Cookie、密码与数据库 DSN 不进入 Git。

精简持久证据清单：[执行与档案](evidence/execution-runtime/MANIFEST.json)、[双平台原生结构](evidence/native-reconciliation/MANIFEST.json)。原始大日志保留在本机，清单提供可移交的关键证据与哈希，不通过复制整份运行目录扩大仓库。

## 后续必须继续完成

1. 真实模型端点恢复后，在相同受控群验证读取、连续动作、持久等待、重启恢复与停止来源群派生任务。
2. 将归档器作为配置插件接入终态流程和持续监督；归档失败保留业务事实，独立对账，不能重发已提交动作。
3. 补齐多来源档案的实际受众交集与动态权限撤销、通用 AFFiNE 原生增量写入、两平台视觉和复杂格式验收。
4. 继续 Clerk 真人多端登录、融云客户端真实接收与断线恢复、Flutter 新内核迁移，以及飞书各办公页面和相应 API/MCP/A2A 能力。

本批未修改 doc_free 源码，仍在 `equal_rights` 的 `dc728ddc99ce3bc7346bb4dc364824bbb32b1101`；新增适配和执行逻辑位于人机仓库。完整目标保持未完成。
