# 人机 startup 第一阶段交付：商业协作内核、机器执行与双端文档投影

- 整理时间：2026-09-09T04:24:00+08:00，Asia/Shanghai。在线检查的实际发生时间分别列于下文；整理时间不替代验收时间。
- 分支：`startup`。
- 交付范围：新桌面/Web 迁移入口、Go 协作内核、Clerk 机器身份、必选融云 Outbox、持久 Run 与停止检查、doc_free → AFFiNE / Docmost 投影。
- 状态：本阶段实现已提交；完整商业版本、全量飞书复刻及持续主动执行仍在建设。本文是验收基线，不把阶段通过当作总目标完成。

## 1. 提交、蓝图与有效范围

| 仓库 / 内容 | 完整 commit | Git 时间 | 描述 |
| --- | --- | --- | --- |
| active_agent / 桌面与 Web | `71b80f8181fa243b7477ebac0c35c6ce13e2c960` | `2026-09-09T04:11:17+08:00` | `feat(desktop): introduce Electron React workspace and isolated RongCloud adapter` |
| active_agent / 协作、执行与文档内核 | `a9005c01ee059b3f093d877ae1eb13828075d692` | `2026-09-09T04:15:30+08:00` | `feat(core): add Clerk-bound agent runs, RongCloud outbox, and document projections` |
| active_agent / 原阶段基线 | `acee8003c7c55694716778189179ec272da44347` | `2026-09-09T01:22:28+08:00` | `docs: close equal-rights stage and prepare major-version handoff` |
| doc_free / 本阶段保持不变 | `dc728ddc99ce3bc7346bb4dc364824bbb32b1101` | `2026-09-09T01:22:28+08:00` | `docs: preserve stage baseline for major-version branch` |

本阶段其他专题文档按当时进度记录了“基线 / 尚未提交”。这些历史文字保留；本表提供已提交实现的最终关联，不覆盖旧验收记录。交付文档与发布回执另行提交，避免把文档自己的 commit 伪装成实现 commit。

依据用户指定的《2026-09-09_人机_从Google分享至Agent原生协作平台_方案演进完整对比与实施蓝图.md》，采用 Electron + React/TypeScript 桌面、React/TypeScript Web、Flutter iOS/Android、Go/Gin、PostgreSQL/pgx/sqlc/goose、Temporal、Eino ADK/DeepAgents 及显式中间件。Clerk 是第一轮方案，Logto + OpenFGA 保留为尚未实施的替换方案；国内优先，海外和鸿蒙暂缓。

**用户在实施会话中明确要求融云必选，覆盖蓝图中 Centrifugo 及融云可选的历史建议。** 当前 API 启动要求融云配置，服务端 Outbox 只有 `rongcloud` 提供方。协作正文和授权事实由自有内核管理，融云承担正式外发传输；不能把一般客户端可绕过内核的直接写入当作完成整合。

doc_free 源码和 CRDT 保持原状，新增适配、授权检查和投影在人机仓库实现。文档承担人和 Agent 可共同阅读的成果载体；持久动作与事件用于支持文档可追溯，不能仅凭模型总结宣称外部动作成功。

## 2. 用户现在能打开的界面

新 Electron 电脑端已打开，窗口名为「人机 · 协作工作空间」，账号 `huapohen`，显示「原生办公 · 产品共创」及真实旧会话内容。原生窗口检查确认「迁移模式 · 已同步」、消息输入区、`@ 人或 Agent`、Agent 超级入口存在。本阶段没有向真实飞书发送消息。

迁移模式连接原服务 3218；Clerk 商业工作空间入口与之明确分开。浏览器 `fetch` 的接收者绑定问题已经修复，并有回归测试。Electron/Web 输入没有在此次登录中观察到重复，但这不能证明此前用户反馈的系统级重复输入问题已经全面解决。

React 新端目前包括消息、会话、置顶、免打扰、Agent 和文档入口的迁移基础。Flutter 原客户端仍保留在 `apps/office`。本阶段没有将旧 Flutter 的全部页面迁移为 React，也没有完成工作台、设置、管理后台、移动端的全量像素对比。

手动启动教程见 [MANUAL_STARTUP_GUIDE.md](MANUAL_STARTUP_GUIDE.md)；服务与协议说明见 [协作服务 README](../../../services/collaboration/README.md)。桌面启动需要 Vite 服务；仅关闭开发窗口或进程不会删除数据。已运行的端口不要启动第二份。

## 3. 人和 Agent 的统一事实与动作

主体使用稳定的 `principal_id`，第三方身份通过 `(issuer, subject)` 映射。Agent 与模型分离；机器 token 验证接收方范围后，还必须命中服务端登记的 executor、Agent 和工作区绑定。客户端声明的 kind、Agent ID 或删除后的来源范围不能成为授权依据。

正式消息、群内序号、动作记录、领域事件和融云 Outbox 在 PostgreSQL 同一事务内提交。动作 ID 在主体范围内持久去重：同一 ID 改对象、改内容、换动作类型会冲突；丢失响应后读取同一回执，不生成第二条消息。重放仍受当前主体、成员与角色约束。

Run 保存执行器、主动人格策略版本、来源群和停止代次。子 Run 从服务端父 Run 继承全部来源，不能借新目标群删掉原群的停止约束。停止、恢复会推进代次；恢复不复活旧 Run。延迟融云外发再次检查所有继承来源、当前成员、执行器和人格策略。已接受的动作事实与外部未知结果分别保留。

当前正式机器动作实现为 `message.send`；注册执行器、建群等部分管理操作已有业务接口，但尚未全部成为机器动作网关能力。**同权是总目标，不能将这项阶段差距解释成永久只给人操作。** 后续必须用相同角色、授权与回执补全每个业务操作。

## 4. 可直接供 Agent 使用的协议

`GET /v1/capabilities` 描述 12 项实际能力及 API/MCP/A2A 覆盖，包含 `machine_access`，区分已授权读取、要求 Run、尚缺网关动作和隔离测试能力。动态数据授权仍由 Store 检查，能力声明不授予对象权限。

| 入口 | 本阶段真实能力 | 尚缺部分 |
| --- | --- | --- |
| API | 身份、工作区、群、分页消息、停止策略、executor、Agent 策略、Run | 全部办公域、通用导出、所有机器写操作 |
| MCP | 2025-11-25；人类 9 个工具，机器 6 个工具；与 REST 共享处理器 | 其余业务工具、资源/提示能力与部署验收 |
| 机器工具 | `run_create`、`run_read`、`identity_read`、`room_list`、`message_read`、`message_send` | 建群、成员、任务、文档等动作网关覆盖 |
| Harness 网关 | binding/check/actions/events；持久范围与事件去重 | Run 证据通用导出与自动文档归档 |
| A2A / 插件 / 外设 | 本阶段没有声明已实现 | 发现、调用、版本化、热替换与真实设备验证 |

机器消息必须携带持久 `run_id` 与 64 位十六进制稳定动作 ID；无 Run 的机器消息拒绝。普通授权历史读取限定 executor 的绑定工作区；显式 Run 的群和消息读取只允许该 Run 的来源范围，并在读取事务内校验当前停止代次，避免先检查、后越权读。

## 5. 真实外部联调结果

| 项目 | 已核实证据 | 本次证据不能证明的内容 |
| --- | --- | --- |
| Clerk M2M | 官方创建的接收方与 worker；有限期限 opaque token 经 Go 线上验证成功 | 真人全端登录、刷新、国内长期可用性 |
| 融云服务端 | 03:56:57–03:56:58 +08；3 次身份登记、1 次建群、3 次消息发布均有回执；PG 4/4 Outbox delivered、attempts=1；同 fixture 重启验证无新增外部调用 | Electron/Web/手机 SDK 实际收包、断线补拉、全通道直接写约束 |
| 机器 → Run → 动作 | 04:07:12–04:07:19 +08；21/21 通过；REST/internal/MCP 相同动作仅一条 PG 消息；伪造、删来源、无 Run、停止与恢复旧代次均被拒绝 | 测试管理 CLI 初始化不等于 Clerk 真人管理员闭环；未运行模型 |
| 机器读取范围 | 04:13:30 +08；真实机器认证的 6/6 检查通过，过时来源 Run 的读取返回 409；另有真实 PG 跨工作区与锁等待竞态测试 | 全部办公资源的同类覆盖 |
| doc_free 双端投影 | 03:45:18 +08；69/69 通过；2 个源文档、4 个 AFFiNE/Docmost 投影；标题和正文读回一致，更新复用原外部 ID | 持续自动同步、复杂富文档全保真、生产权限撤销 |

机器动作验收新增目标群与消息的两条 Outbox 保持 `pending`、`attempts=0`，没有宣称融云投递成功。消息 Outbox #6 的旧 child Run 已过时；建群 Outbox #5 未绑定 Run，启动通用 worker 仍可能先外发建群。两项继续保留未派发测试事实，不启动通用 worker，也不手工改为 delivered。外部结果未知时先对账，不把重跑 CLI 或删除 manifest 当作恢复办法。

融云客户端普通 token 的供应商直接写入范围尚未完整约束，因此当前默认不为一般主体发放，仅显式隔离测试主体可申请。服务端融云 Outbox 仍是必选链路。正式放开需要实测原始 SDK 的群、消息、撤回及其他写入口；前端不显示按钮不能代替此验收。

## 6. doc_free、AFFiNE 和 Docmost

本阶段集成经过真实源身份及来源群权限检查；投影使用显式目标绑定、持久意图、进程锁、版本与哈希读回。外部创建结果未知时不自动新建第二份。目标内容发生冲突时拒绝盲覆盖。

- doc_free：`25ae13fb` r3、`f6b5ff58` r2；人和 Agent 均能读取相同当前版本。
- AFFiNE：既有本机 3010 服务的独立验收工作区，2 个投影。
- Docmost：本机新隔离实例 3021，2 个投影；原 3020 数据保持原样。旧实例登录未成功，不能说旧实例迁移完成。
- 26 个历史业务文档内容与既有字段保留；25 个整个对象哈希相同，`5ddcd4f4` 仅新增空运行时字段 `applied_operations: {}`。不将此记录夸大为 26 个整个对象完全相同。

本交付文档会作为新的共享文档发布；该发布与投影的实际 ID、版本、时间及独立读回结果记录在后续发布回执。此处列出的 69/69 是前述双文档合成验收，不提前替新交付文档签收。

## 7. Harness 和持续主动执行的边界

已构建真实 Eino DeepAgent，并显式配置 Skills、摘要与大工具结果缩减。Temporal 工作流区分规划阶段、独立业务动作、下一阶段与等待；阶段有模型调用、动作数量、时间和总阶段上限，避免规划失败时盲重做已提交业务。内部子 Agent 有独立 trace；每次尝试的证据存储隔离。

Harness 自动用例使用假模型和 Temporal 测试环境，没有连接真实 Temporal 服务或请求真实大模型。默认关闭 Worker，不因登记 Run 就声称已开始自主工作。真实 Temporal 服务、Worker 强杀恢复、真实模型多阶段执行、事件触发与定时持续调度、文件/代码沙箱及 Run 自动归档到 doc_free **尚未完成**。用户要求的“授权后无需人为干预、持续办事并落入人眼可见文档”仍必须作为下一阶段主要交付，不能以当前合成消息测试替代。

## 8. 自动检查与可保留证据

Go 全套最终日志 `/tmp/renji-startup-full-go-20260909.jsonl` 中，100 个顶层测试与 95 个子测试通过，无失败、无实际测试 skip；5 个 skip 事件是没有测试文件的包。PostgreSQL 测试使用真实本机数据库、独立 schema，并在测试结束后清理。构建、vet 与 SQL 生成后的编译均通过。

Web 22/22、桌面 6/6 自动测试通过，类型检查和 Web 构建通过。本次收尾核对的是此前测试的成功退出日志、验收记录和未变更源码，没有重新运行客户端用例；具体证据可用性见 [客户端独立审计](STARTUP_CLIENT_EVIDENCE_0425.md)。这些是前端与边界用例，不是全部页面视觉验收或五端生产包验收。

持久脱敏证据见 [STARTUP_FOUNDATION_EVIDENCE.json](STARTUP_FOUNDATION_EVIDENCE.json)，包含顶层与子测试名称、日志哈希、机器读取实测结果和文档投影回执。详细专题见：

- [机器执行网关真实验收](CLERK_EXECUTION_GATEWAY_REAL_PROBE_0409.md)
- [融云真实 Outbox 验收](RONGCLOUD_OUTBOX_SYNTHETIC_PROBE_0356.md)
- [Clerk 机器适配](CLERK_MACHINE_AUTH_ADAPTER_0343.md)
- [文档投影实现与证据](DOCUMENT_SYNC_FOUNDATION.md)
- [Harness 实现与阶段历史](HARNESS_FOUNDATION.md)

## 9. 与完整蓝图的差距和后续验收

| 蓝图阶段 | 当前状态 | 继续完成的明确结果 |
| --- | --- | --- |
| A：盘点与契约 | 第一轮实现和证据已建立，Clerk 机器路径实测 | 完整功能/平台矩阵与真人认证评估 |
| B：统一内核 | 群/消息/身份/Run/停止/Outbox 已有实际链路 | 好友、组织、任务/成果、客户端补拉及所有同权操作 |
| C：文档 | 双供应商投影实测 | 统一云文档操作、ACL 撤销、目录标签、申请与版本界面 |
| D/E：主动与监督 | 持久 Run、来源继承、关闸和动作去重已测 | Temporal/模型持续执行、委派、自动文档档案、监督 UI 与完整竞态 |
| F：跨端商业验证 | Electron/React 开发入口可打开，Flutter 原端保留 | Clerk 与融云移动迁移，Windows/macOS 发行、签名更新及真机弱网/后台 |
| G：完整飞书与 Agent 能力 | 旧实现保留，新客户端迁移未全量 | 每页视觉/交互与每个业务域 API/MCP/A2A 同步补齐 |
| H：国内规模可靠性 | 本机小规模合成验证 | 国内部署、检索/百万目录、容量、成本、备份恢复 |

下一阶段首要闭环：真实人类与数个 Agent 使用独立身份；在授权范围内持续协作、委派和修改文档；人从超级入口停止来源群衍生任务；旧 Run/子任务不能继续发布；人和 Agent 可直接查询执行记录，并在 doc_free、AFFiNE 与 Docmost 看到可核对的成果。随后扩展每个办公能力与平台，不将“所有东西都能 Agent 原生访问”缩成仅消息工具。

## 10. 本阶段运行保留与回退

本机保留已登录 Electron、Vite 5173、Go API 3318、原服务 3218/1238、独立 PostgreSQL 55434、AFFiNE 3010 与新 Docmost 3021。它们是开发进程/本机服务，没有安装完整生产部署或开机自启。Temporal 与通用 transport-worker 当前不运行。

凭据保存在 Git 忽略的 `data/startup`、原 `data/office` 及本机私密配置；教程、交付文档与提交不包含完整密码、token、Cookie 或数据库连接串。机器 token 有有效期，不把过期后的请求失败误诊为代码回归。

新服务与旧数据分开保留。需要回到原界面时，通过旧 Flutter 客户端和原服务查看；不降级新数据库迁移、不删除持久 intent、不重建供应商映射。进入下一阶段前以本表实现 commit 和发布回执作为验收基线。
