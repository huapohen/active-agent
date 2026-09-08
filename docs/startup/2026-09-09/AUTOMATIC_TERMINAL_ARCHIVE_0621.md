# Temporal 终态自动归档与既有 Run 对账工作流

初稿记录：2026-09-09 06:21 +08:00。分支 `startup`。实现基线 `d4814e6e1fd916c47c08a1eb67c5ede67a8935a7`，提交时间 `2026-09-09T06:00:08+08:00`，描述 `docs: record native document repair and real run archive evidence`。初稿记录时本文新增代码尚未提交。

06:37 +08:00 提交归属追加：实际实现 commit 为 `2fc663150ec66fa2c402e1a38668264f0d961e5a`，提交时间 `2026-09-09T06:37:12+08:00`，描述 `feat(startup): automate execution archives and add native message actions`。保留初稿和验证时间，不将基线 SHA 当作实现提交。

06:28 +08:00 验证追加：已修复独立审查发现的 room stop 与 Terminal 写入竞态；只接受数据库产生的同 Run 停止状态事实，不改写执行器原事件。下文记录最终冻结行为与测试口径，初稿时间保持不变。

## 新增行为

已验证的 Doc Free 归档器现在通过独立 `ArchivePlugin` 接入 Temporal。业务工作流的 Terminal Activity 成功提交原始终态事件后，才调另一个 Archive Activity。业务成功、失败或取消与归档结果分别保存；归档 attention 不会把业务成功回滚，也不会把失败 Run 改写为成功。Terminal 写入失败则不启动归档，并记为 `terminal_not_persisted`。

另外注册 `renji.agent.archive.v1` 工作流，仅对已存在的终态 Run 归档/只读对账。它没有 Planner、Execute 或 Terminal 步骤；即使工作流完成，也只证明归档操作的结果，不能宣传为真实模型执行成功。适合验证已有 failed Run 的归档恢复，而不制造新的模型重试或业务消息。

06:21 本专题的本地验证没有在真实服务启动 Worker、没有实际向 Doc Free 新建文档、没有调用模型；根任务随后完成的真实服务验收单独追加在末尾。本地验证使用真实 Temporal SDK 测试环境、protobuf 历史重放、独立 PostgreSQL schema 和本机 `httptest`。

## 包依赖与替换接口

```text
cmd/worker → harness
           → runarchive → store → harness
                        → harness.ArchivePlugin
```

`harness` 只定义接口与工作流，不反向导入 Store 或 runarchive，避免循环依赖。`cmd/worker` 是装配入口；`runarchive.TerminalPlugin` 实现既有确定性归档流程。长期调度、重试和恢复仍由 Temporal 负责，没有第二套运行引擎。

```go
type ArchivePlugin interface {
    ArchiveRun(context.Context, string /* Go 持久 Run ID */) (ArchiveOutcome, error)
}
```

替换插件必须遵守当前身份/来源权限、持久写入意图及 unknown 不重建契约。接口不接受模型提供的 URL、token、群 ID、RunContext 或文档正文。当前正式装配的仍是受限 `single_source_synthetic` Doc Free 适配器；多来源生产动态 ACL 尚未闭合。

## 固定部署配置

新增进程环境项 `RENJI_RUN_ARCHIVE_CONFIG` 指向原有 0600 私有 JSON；JSON schema、目标白名单、principal 映射、endpoint 指纹、Clerk 有效期检查保持原样。详见 [受控 Doc Free 适配器](RUN_ARCHIVE_DOC_FREE_ADAPTER_0549.md)。模型和 Workflow 输入不能设置此路径。

| 配置 | Worker/Activity 行为 |
|---|---|
| 没有配置路径 | 启动记录 `disabled_no_config`；Archive 结果 `disabled / archive_not_configured` |
| JSON 显式 `enabled:false` | 启动记录 `disabled_by_config`；不读凭据、不连归档数据库或网络，Activity 返回 disabled |
| 无法读取、权限过宽或无效配置 | Worker 在模型/Temporal 连接前拒绝启动；不回退到隐式目标 |
| 有效且启用 | 由部署配置创建真实 Clerk 验证器、私有 PG 连接和 Doc Free 归档插件；退出 Worker 时关闭连接 |

Worker 原有机器绑定握手、明确模型配置、Temporal 连接与默认关闭规则保持。归档凭据来自服务器进程环境；轮换后由部署流程重启 Worker，不把凭据写入历史或日志。

## 业务终态与归档顺序

1. 原有业务工作流完成、失败或收到取消。
2. 以独立取消上下文提交 Terminal Activity 的原始终态事实；当前执行器绑定和来源 ACL 仍由网关检查。
3. 只有 Terminal 成功，才通过新的版本标记调独立 Archive Activity。业务已取消时仍可保存授权范围内的历史归档事实。
4. 插件重新机器认证，从服务端 Run 读取当前状态，并固定证据游标分页检查原始事件。通常必须找到 **事件类型精确等于 `run.` + 当前 Run.Status** 的终态事件。当前状态为 stopped 时，也接受 **kind=`run.status`、ObjectID 等于该 Run ID、data.status=`stopped`** 的数据库停止事实。该 kind 由服务端触发器生成，调用者不能通过模型文字或 AppendExecutionEvent 构造。仅有 running、模型声称完成，或缺少上述精确事实，均拒绝归档。
5. 已授权的适配器复用持久 intent，继续一次写入/只读对账；结果返回安全元数据，不返回标题、正文、原始 provider 错误或凭据。

归档前的事件检查仍重新评估全部来源成员权限。停止不是撤销历史审计阅读权；绑定停用、主体/成员撤权则拒绝。停止发生在 Terminal 前时，PG 状态可能是 stopped，而执行器如实提交其原始 run.failed 或 run.completed 报告；数据库已经存在的同 Run stopped 状态事实足以认定停止，不再伪造第二条 run.stopped 执行器事件。若上述原始或数据库事实都缺少，仍需基于真实历史的可信对账。

## 持久状态与重试

新增 Archive Activity / ArchiveWorkflow 入参只有 `{"run_id":"..."}`。新结果只含状态、归档 ID、证据游标、part 编号/状态/外部 ID、安全 code 和 attempt。既有 Plan/Execute 历史中的业务载荷不是由此接口复制出来的文档正文。

成功业务的 `RunResult.archive` 返回归档结果；业务失败或取消依然保持原错误，通过 `renji.archive.status.v1` 查询归档状态。状态由已持久化的 Activity 结果/失败历史重放还原，不依赖成功业务返回。Query 属于受控 Temporal 运维接口；还没有因此新增面向终端用户的 IM HTTP/MCP 归档查询路由。

| 归档情况 | 自动处理 |
|---|---|
| verified | 保存结果；不重跑业务、终态或文档创建 |
| unknown 且无外部 ID | attention，禁止自动创建重试，即使替换插件误报可重试也拒绝 |
| 已知外部 ID，暂时读回失败 | 最多 3 次 Archive Activity 尝试；沿原 ID 只读，其他业务步骤不重跑 |
| `archive_claim_conflict` | 每次等待 125 秒后重试，足够原 2 分钟 PG lease 过期；仍最多 3 次 |
| 其他可重试的有界读回故障 | 采用快速重试间隔，最多 3 次 |
| 鉴权、配置、来源或终态事实不符 | attention；不放宽权限或虚构成功 |
| 插件返回原始错误或 panic | 转换为固定安全 code；不把错误正文、panic 文本或堆栈写入新增失败结果 |

单次 Activity 最长 2 分钟，整体最多 11 分钟，覆盖 3 次最长调用及 2 次 125 秒 lease 等待。重试预算耗尽后仍可通过独立 ArchiveWorkflow 继续受控对账；不能删除 intent、换 binding ID 或换 action ID 绕过 unknown。

两个版本标记分别保护终态写入和新增归档命令。旧历史没有新归档标记时，不补发 Archive Activity；旧成功结果不追加 archive 字段。已结束的历史 Run 可显式走只归档工作流，而不重放业务。

## 根部真实验收入口

已加载固定机器与归档配置的 Worker 注册：

- 业务工作流：`renji.agent.run.v1`。
- 只归档/对账工作流：`renji.agent.archive.v1`。
- 两者的归档查询：`renji.archive.status.v1`。

通过受控 Temporal SDK 启动只归档工作流时，参数是 `harness.ArchiveInput{RunID: existingTerminalRunID}`。Go 持久 Run ID 与 Temporal 自身的 Workflow/Run ID 是不同字段，不要互换。只有已验证终态的业务 Run 才能进入实际归档器。

首个真实验收建议继续使用此前已有的 failed case2 与旧文档 `9d62380a`，只验证原 intent/ID 的读取、状态查询及恢复；其通过不证明模型故障已经恢复。跨 renderer 复用与人类可读摘要由本轮 Store 组件另行实现和验证。

## 本轮测试证据

06:28 最终 3 包 race：`internal/harness` 40 个顶层 + 38 个子测试，`internal/runarchive` 17 + 21，`cmd/worker` 3；总计 **60 个顶层 + 59 个子测试**，0 失败、0 跳过。三包 vet 通过。

重点验证包括：先提交终态、归档恢复/耗尽不重业务、未知 ID 无重试、错误/panic 脱敏、终态提交失败跳过、业务失败/取消仍能查询、明确 disabled、旧版本不新增命令、真实 protobuf 旧业务与已完成归档历史 Replay、当前状态精确终态事实、撤权拒绝、真实 PG 下读回失败后仅 1 次 POST、125 秒 lease 等待两次后 Planner/动作/终态仍各 1 次。额外真实 PG 测试分别覆盖 room stop 后提交 run.failed/run.completed、原事件与数据库停止事实各 1 条且归档不增造事件，以及模型伪造相同字段无法产生服务器停止事实。

日志、源文件 hash 及 scope 记录见 `AUTOMATIC_TERMINAL_ARCHIVE_EVIDENCE_0621.json`。没有把测试环境的时钟快进或历史重放称为真实 Worker 强杀恢复；真实部署证据由根任务追加。

## 06:37 +08:00 根部真实 Temporal 验证追加

根任务使用最终二进制，在持久 Temporal 服务上运行 `renji-archive-case2-20260909-0620-final`。原始验证记录时间为 `2026-09-08T22:32:28.384260+00:00`（北京时间 06:32:28）；这里在实现提交后补录，不改写实际发生时间。

| 验证项 | 真实结果 |
|---|---|
| Temporal 历史 | 11 个事件，仅 1 个 `renji.agent.archive.v1` Activity |
| 工作流结果 | `verified`，1 次 Activity attempt |
| 原始业务 Run | 仍为 `failed`，原 5 条证据、0 个业务动作，未重跑 Planner、Execute 或 Terminal |
| 归档 | 原 ID `75ae64e9-7234-4293-8b15-8cbfb70faefb`，`through=5`、`verified_through=5` |
| Doc Free | 原文档 `9d62380a`，未新建第二份 |
| 旧数据保护 | 原归档对象、原 `renji-run-markdown-v1`、目标群 4 份文档的完整对象在前后快照中一致 |

`write_attempts=1` 是该归档从最初创建保留的累计值，不是本次又创建一次。此工作流只对已验证目标读回对账；`model_success_claimed=false`。

证据：[live-verification.json](../../../output/startup-automatic-archive-20260909/live-verification.json)、[workflow-final-history.json](../../../output/startup-automatic-archive-20260909/workflow-final-history.json)。历史 SHA-256：`5e49dc1e627bb6cf5596bad5ea41f5f780da6c04d767ceab1b49e81217497e07`。首次可选基线读取曾使用未支持的文档列表路由而未完成采集；最终二进制验收改用成功的房间详情前后快照和独立对账工作流，上表基于后者。

本次真实服务验证的是已有失败 Run 的独立归档/对账工作流。业务终态自动触发、取消、125 秒 lease 等待及停止竞态的验证仍分别以本地 SDK/真实 PG 测试为据；未将它们改写成新的真实模型成功或真实 Worker 强杀恢复证据。生产多来源动态 ACL 的未完成范围保持不变。
