# Run 完整执行档案与持久归档基础

- 记录时间：2026-09-09T05:22:00+08:00，Asia/Shanghai。
- 工作分支：`startup`。
- 当前仓库基线：`380d7bef5b8ce78f6dae38b812e8aa9931ca67d1`，2026-09-09T04:52:22+08:00，`docs: preserve native publication evidence and fidelity gaps`。
- 原协作内核实现：`a9005c01ee059b3f093d877ae1eb13828075d692`，2026-09-09T04:15:30+08:00，`feat(core): add Clerk-bound agent runs, RongCloud outbox, and document projections`。
- 初稿记录时，本文新增代码尚未提交。2026-09-09 05:57 +08:00 补充实际实现 commit：`a639a8843093bed98b04b375d361de6e2c2129c9`，`2026-09-09T05:56:24+08:00`，`feat(core): add native document verification and durable agent archives`。保留 05:22 初稿时间，上述 `380d7bef` 仍是基线，不是本次实现 commit。

## 本次实现

Run 不再只能读取上下文。新增 API `GET /v1/runs/:run/evidence` 和 MCP `run_evidence`，二者共用同一个处理器及 Store 事务，返回完整 Run 元数据，以及动作账本、原始执行器事件、运输状态快照和 Run 状态变更。原始字段保留，不用模型总结替代。

`execution.evidence.read` 已进入能力注册表。当前注册表共 13 项；人类 MCP 工具 10 个、机器 7 个。归档网络写没有伪装成已完成的 MCP 工具；持久归档基础先提供进程内 Go 接口，由可信且绑定目标的适配器接真实 doc_free。

查询参数包括 `after`、`through`、`limit`、`mode`。首次读取确定 `through`，后续页面显式传同一游标，避免新事件挤进旧快照；每页仍重查当前身份与所有来源权限。单页最多 100 项，并按约 1.5MB 原始事件数据控制响应，绝不截断一条事件。Run 元数据为每次读取时的当前记录，与固定证据前缀分开；记录中的 running 状态不代替当前执行准入。

## 审计读取与执行读取

| 模式 | 人类 | Agent 机器 | 停止后的行为 |
| --- | --- | --- | --- |
| `audit`，默认 | 当前有效主体，属于 Run 全部来源房间及工作区 | 先核实当前 enabled executor 绑定及其工作区，再按相同当前来源成员权限 | 允许读取历史；停止不等于撤销历史阅读权 |
| `execution` | 不接受以人类会话冒充机器执行态 | 必须是本 Run 的执行器、策略和绑定版本一致，所有来源代次仍相同且未停止，Run 为 running | 返回 409，恢复来源也不复活旧代次 |

审计模式没有给人类专属管理员绕过。另一位 Agent 同事具备相同当前来源成员权限时，可以审计该 Run；它不能把该 Run 当成自己的执行 Run。工作区 A 绑定的机器不能因同一 Agent 主体也属于工作区 B 而读到 B 的档案。

任一继承来源撤销成员、主体禁用、机器绑定失效或工作区成员被移除时，相应读取拒绝。一个有权限的人类仍可审计已禁用 Agent 的旧档案。所有来源从服务端已存 Run 取得，查询不接受 caller 自报或缩减来源列表。

## PostgreSQL 证据与游标

迁移 `00004_execution_archive.sql` 新增 Run 证据序号与统一账本。动作提交、事件插入、Outbox 状态变化、Run 状态变化在原事务中捕获；按 Run 串行推进游标，分页不会因并发提交漏过较小的未提交序号。Outbox 心跳不产生重复事实，pending、unknown、delivered 等运输状态独立保留，本地 succeeded 不被改写为已外发。

旧数据只回填为 `legacy_snapshot=true`：旧表没有共同提交序号，迁移的确定性排序不声称恢复了历史真实发生顺序。原动作、原事件及其时间仍保留。

## 可见 Markdown 档案

`PrepareExecutionArchive` 在全来源权限锁内冻结完整证据前缀，保存 Run 快照、渲染版本、分片正文和 SHA-256，形成持久归档意图。每条原始 JSON 和摘要标签一起保留，标签明确区分：

- 执行器报告的模型/Agent/工具文字；
- 服务端动作账本证明的本地提交；
- Outbox 证明的运输事实；
- Run 状态变更。

模型输出即使写着“action.succeeded”，也仍是原始事件文字。unknown 不自动变成成功。代码围栏按内容确定长度和符号，文本不能逃出围栏伪造档案段落。长 JSON 按 UTF-8 边界分成编号片段，按序直接拼接可恢复完整原始 JSON；记录整项 SHA-256。正文模板固定不输出末尾 LF，匹配 doc_free 写入口的既有处理，校验仍要求精确正文及标题 hash。

单个可见文档控制在约 500KB 内；当前准备器允许完整 Run 原始事件数据最多 64MB，超过时明确失败，不截断，分页证据导出仍可完整取回。更大档案的流式准备尚未实现。

## 持久归档接口与恢复规则

进程内 Go 接口：

```go
ReadExecutionEvidence(ctx, reader, runID, EvidenceQuery)
PrepareExecutionArchive(ctx, reader, runID, targetBinding)
ReadExecutionArchive(ctx, reader, archiveID)
ClaimExecutionArchivePart(ctx, reader, archiveID, part)
WithExecutionArchiveClaim(ctx, reader, claim, readOnly, callback)
RecordExecutionArchiveObservation(ctx, claim, observation)
```

`EvidenceReader` 只能由已认证服务端上下文构造：人类 principal，或经过机器验证的 issuer/subject，二选一；不接受 HTTP body 自报。`targetBinding` 是特权适配器配置的非秘密稳定 ID，不是任意目标 URL。

首次 claim 发出 2 分钟租约。外部请求标记在网络调用前独立持久化，之后再取得并保留当前全来源权限锁执行最长 15 秒的有界请求。同一 claim 不能再次开始写。即使进程在请求标记后、真正发送前崩溃，也保守进入 unknown，不自动重试创建。

已知 external ID 的 unknown 只允许读回对账；没有 ID 的 unknown 不自动建第二份。同一 Run/目标有旧快照未验证时，即使新事件推进了游标，Prepare 也返回旧意图，不能通过新游标绕过未知结果。旧快照全部验证后才允许生成下一个带游标的新快照，历史文档和 ID 保留。

`RecordExecutionArchiveObservation` 只供可信适配器记录供应商真实 ID、标题及正文读回 hash，不通过 API/MCP 暴露任意“标记 verified”入口。已在途结果可在权限后来撤销后记录，不能因此再次读取正文或发新请求。新租约 token 会屏蔽旧 owner 的迟到改写。分片完成串行更新，全部精确验证后才推进 verified 游标；并发完成不会遗漏最后一次推进。

适配器必须在 `WithExecutionArchiveClaim` 回调中完成其有界请求，回调返回后再调用 `RecordExecutionArchiveObservation`，不要在回调中嵌套该记录事务。网络失败须保留未知事实；不得删除意图、改 external ID 或手工改 verified 来恢复。

## stage.input 真正接线的修复

真实 Temporal 第一轮暴露出 `stage.input` 不在 Store 接受列表，导致规划器在模型调用前即失败。本次补齐严格契约：Data 必须为 `harness.StageInput`，context 与已存 Run 一致，goal 相同，stage 与外层 Event 相同且为 0–31，attempt 为正数，summary/receipt 数量有界。每条传入历史 receipt 必须匹配本 Run 已提交的动作账本。

真实 HTTP + PostgreSQL 用例验证：首次/同事件重放 204 且仅一行；删来源 403；stage 错配 400；伪造未提交 receipt 403；篡改真实 receipt 409；真实提交 receipt 可以进入下一阶段；停止后的新 stage.input 返回 409。原 run.failed/completed/stopped 等终态类型保留，迟到模型输出仍按已有审计规则保存。

## 验证与实际边界

本组件最终真实 PostgreSQL 独立 schema 回归：Store 36 个顶层测试 + 16 个子测试；HTTP 11 个顶层测试 + 4 个子测试，全部通过。新增档案/证据目标用例共 11 个，加原有 1 个证据用例，共 12 个 race 用例全部通过；两包 vet 通过。日志哈希、测试名称和源码 hash 见 [RUN_EVIDENCE_ARCHIVE_EVIDENCE_0522.json](RUN_EVIDENCE_ARCHIVE_EVIDENCE_0522.json)。

另在 2026-09-09T05:20:18+08:00 用真实机器凭据只读检查根任务的运行结果，未产生业务动作或模型请求：

- Run `76dedd18-1ddf-4fc0-abfa-19aee795b034`：audit 返回 failed、5 项证据，包含三次 stage.input、run.failed 与 run.status，0 个业务动作；execution 返回 409。
- 首轮 Run `b94da23b-4cb9-4f06-a03d-701fc4475108`：当时 PG 仍 running、游标 0，execution 仍允许。其 Temporal 已失败由根任务另行读取；这一差异需要可信终态对账，不能称为成功，本文不修改旧运行状态。

只读证据：`output/startup-temporal-runtime-20260909/run-evidence-independent-readback-0520.json`。这些状态是该时点读回，后续根任务对账另留记录。

05:22 本专题验证未启动 API、Temporal Worker 或模型，也没有向 doc_free 外发归档。后续单来源合成归档已由根任务独立联调，失败 Run 的真实结果见 [适配器追加记录](RUN_ARCHIVE_DOC_FREE_ADAPTER_0549.md#2026-09-09-0557-0800-真实归档结果追加)。多来源档案含祖先来源内容，不能直接授予目标群全部成员；必须有全来源权限交集、明确主体映射和动态撤权校验。doc_free 尚无动态父来源授权闭环，因此多来源生产文档归档仍未完成，不能以专用测试群替代。
