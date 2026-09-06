# 原生 Active Agent 动作执行合同（待实现设计）

| 字段 | 记录 |
| --- | --- |
| 状态 | **待实现设计；不是已交付能力或测试通过声明** |
| 记录时间 | `2026-09-06T11:57:12+08:00` / `2026-09-06T03:57:12Z` |
| 分支 | 两仓均为 `equal_rights` |
| Active Agent 基线 commit | `1ae44da253a9f097b02a7335678d485b285796cf` |
| Active Agent 提交时间 | `2026-09-06T10:44:22+08:00` |
| Active Agent 提交描述 | `feat: ship equal-rights Flutter office clients and native agent collaboration` |
| Doc Free 基线 commit | `134e0a78fc51345689be377004e793dd6a7fd71d` |
| Doc Free 提交时间 | `2026-09-06T10:42:30+08:00` |
| Doc Free 提交描述 | `feat: add native office meetings calendar and deep message workflows` |
| 本文描述 | 从仅回复、阻塞和文档草稿的默认 worker，演进到带可见计划、租约约束、版本检查和持久化回执的有界原生动作执行 |
| 审计对象 | 以上基线之后的当前工作树，包含正在开发的账号、企业、MCP/A2A 等模块；不表示基线 commit 已有这些新增能力 |

本文由只读代码审计形成，仅新增设计文档，没有实施下文端点、执行器或存储改动，也没有为它们启动构建或真实模型测试。最终实现需要单独 commit、时间、协议测试和端到端证据。

## 1. 实际现状与缺口

现有 [active_agent/im.py](../../../active_agent/im.py) 的 `SYSTEM` 明确说明模型没有工具；`IMAgent.validate()` 只接受 `reply/silent/blocked`，丢弃模型提交的工具和任意副作用字段。`IMAgent.cycle()` 的闭环是领取公开上下文、调用一次模型、验证输出、提交 `finish`，提交响应丢失时重试相同结果。

[Doc Free native-im.js](https://github.com/huapohen/doc-free/blob/equal_rights/native-im.js) 的 `claim()` 在发出 lease 前保存精确上下文；`finish()` 对原始消息、文档、任务、日程和成员版本进行检查。其优点是旧模型结果不能覆盖新工作现场，但直接增加中途工具写入会造成下面的问题：

1. 自己刚成功修改的任务、文档或日程也会让 `finish()` 判为 `stale_context`。
2. 当前 MCP/A2A 检查身份和业务 ACL，没有 turn lease、参与暂停、精确上下文和自动动作预算约束。worker 直接调用它们，旧 lease 仍可能完成工具写入。
3. 任务创建、普通文档创建没有客户端幂等。日程回应没有 `base_revision`，重复调用还会增加 revision。
4. `turnView()`、运行详情和 `exportRoom()` 向房间成员公开完整运行。私人邮箱、考勤、审批或账号工具的输入/回执不能直接纳入这一共享记录。
5. `eligible()` 的消息分支有深度限制，任务/文档动作若每次产生新 root，可能形成 Agent 相互派任务的无限触发链。
6. 业务修改和 A2A 回执保存分属不同文件。A2A 能拒绝自动重放未知结果，但不能据此证明业务修改与回执是同一事务。

函数名为本文检索锚点；当前工作树行号会随提交变化，不把当前行号冒充为基线 commit 的永久位置。

## 2. 首批固定允许操作

服务器根据当前角色和参与策略生成当轮能力目录，模型只可选择目录中的操作。它是默认自动执行器的范围约束；已有 REST/MCP 的人机同权 ACL 保持一致。

| 操作 | 首批范围与前置条件 |
| --- | --- |
| `im_create_task` | 当前房间；负责人来自已捕获且仍有效的成员名单 |
| `im_update_task` | 已读取的当前房间任务；预期 revision；标记完成时关联可见交付依据 |
| `im_add_contact` | 只把当前房间参与者加入自己联系人；回执只给目标 ID 和“已加入”，不公开先前关系及私人联系人列表 |
| `office_create_event` | 当前房间；明确的带时区时间；参与者来自当前成员 |
| `office_update_event` | 当前房间和现有创建者/owner ACL；预期 revision；首批排除联动会议改期 |
| `office_respond_event` | 只代表自己的身份回应；执行适配器补预期 revision |
| `im_create_document` | 创建真实规范共享文档；先补稳定创建 ID、create-once 和规范存储操作回执 |
| `im_update_document` | 普通共享正文；revision + content hash + CRDT CAS；保存 before/after 依据 |

首批不开放企业角色变更、成员增删、账号、任意扩展执行、媒体操作、审批决定、邮件发送和任意 URL。允许目录后续可增加，但每一项先明确可见范围、权限、幂等、版本、恢复与测试合同。

文档内容和对话仍是不可信工作数据。证据引用证明它来自哪个可见版本，不自动把正文中的“系统指令”、改权限请求或访问秘密请求升级为执行授权。

## 3. 领取与冻结动作计划

`claim()` 在原始 `turn.context` 中新增 `context_hash`、能力目录及完整 schema、`capability_version`、参与/应用策略版本和动作预算。保留精确原始上下文不可变；执行推进状态另存。

建议首版每轮最多 4 个动作、严格串行、每个因果 root 最多 12 个动作；一轮只调用一次模型生成有界计划，不做隐形无限工具循环。所有动作预算在服务器持久化核算，而非仅靠提示词。

拟新增 `POST /api/im/rooms/:rid/turns/:tid/plan`：

```json
{
  "lease_token": "<仅请求传输，不进入可见计划>",
  "context_hash": "<领取时上下文摘要>",
  "model": "<领取时模型>",
  "reasoning_effort": "<领取时配置>",
  "summary": "整理验收文档并推进任务",
  "steps": [
    {
      "key": "update-task",
      "operation": "im_update_task",
      "arguments": {
        "task_id": "<已经读取的任务 ID>",
        "base_revision": 3,
        "status": "doing"
      },
      "evidence": [
        {
          "kind": "message",
          "id": "<消息 ID>",
          "revision": 1,
          "quote": "<原文中实际存在的工作请求>"
        }
      ]
    }
  ]
}
```

服务器校验身份、lease、快照和目录，确认引用确实在捕获上下文中，quote 是原文子串；它不宣称理解并验证了任务完成的业务语义。规范化后的计划、摘要、证据和输入哈希先持久化，然后才可执行。

相同计划重试返回原计划；同一 turn 的不同计划返回冲突。`operation_id` 由服务器从 `principal + room + turn + step_index` 生成，不随模型重试、lease attempt 或进程重启改变。模型不能设置 actor、目标房间、operation ID、任意凭据或权限。

步骤依赖只允许引用前一步已提交资源的特定 ID 字段，例如创建文档后关联任务；采用固定类型的结果绑定，拒绝任意 JSONPath、代码、模板或 URL 拼接。输入哈希包含冻结操作、规范参数、依赖和证据；结果绑定的实际资源 ID 另存可审计解析结果。

## 4. 每一步动作的 lease 与版本约束

拟新增 `POST /api/im/rooms/:rid/turns/:tid/operations/:operation_id/execute`。请求只携带当前 lease 和 `plan_hash`；业务参数必须从已保存计划读取，不能在重试时替换。

每次执行重新检查：

- 当前 principal、成员资格、目标资源与业务 ACL；企业/应用策略如参与判定也读取当前版本。
- 参与状态未暂停、turn 未取消、lease 匹配且有效、操作者为本 turn 所属身份。
- operation 属于冻结计划、输入哈希一致、前置步骤已提交、动作与因果预算未耗尽。
- 依据和目标资源 revision/hash 与预期一致；目标引用不是模型猜测的房间外 ID。

检查和原生修改在同一串行事务边界完成。撤权先提交则动作被拒绝；动作先提交则保留成功回执并拒绝后续步骤。取消 turn 不回滚或抹去已经提交的真实工作。

只有 `planned` 且尚未执行的步骤可取消。业务失败停止剩余步骤；不提供隐式多步回滚。如果第一步完成、第二步冲突，文档显示“第一步完成、第二步冲突、后续未执行”。

当前租约为模型超时加 60 秒，上限 360 秒。首版需要为动作和最终提交预留期限；剩余时间不足时停止领取新步骤，通过同一计划和新 lease 恢复，不重新生成 ID。若增加续租，必须有 turn 总时长上限，不能借续租无限执行。

## 5. 回执与自己的版本推进

operation receipt 至少包含：

```text
operation_id, input_hash, operation, principal_id,
turn_id, root_id, status, started_at, committed_at,
resource_id, before_revision, after_revision,
before_hash, after_hash, evidence_refs, error_code
```

本地原子操作状态为 `planned → committed/rejected`；跨存储文档增加 `applying/reconciling/needs_attention`。不得保存 lease token、bearer、原始异常或私人业务正文。

`turn.context` 保持不可变，新增 `execution_manifest`。执行前比较预期状态，提交后只推进该步骤实际修改对象的版本；不能直接把整个房间重新拍照当成新依据。其他人的修改仍会阻止后续动作，不会被自己的 manifest 更新掩盖。

`finish()` 继续只负责发布结果，校验推进后的 manifest 和真实回执。服务器根据已提交 receipts 生成动作完成摘要，模型不能自报工具执行成功、伪造资源 ID 或版本。原始模型说明可保留，但需要清楚区分计划说明和服务器证实的结果。

最终消息因外部修改未能发布时，已提交操作仍在运行文档中可见，不能被记为“没有执行”。

## 6. 原子提交、响应丢失与重启恢复

### 6.1 同一 IM 文件内的动作

任务、联系人和日历业务状态、事件、operation receipt 及 `execution_manifest` 必须进入同一次 `persist()`。现有 handler 会自行保存，应抽出共享业务 reducer，让 REST 与 turn execution 复用相同校验/修改，再由各自事务边界保存。

不能在 `serial()` 中再次调用 `im.handle()`，否则等待自己的串行队列；不能先调用现有 handler 保存业务，再单独保存回执，留下“业务成功、回执丢失”的重复执行窗口；也不应使用全局跳过 persist 的标志绕过模块事务。

计划先保存、操作后提交。进程在原子操作保存前崩溃，磁盘仍为 planned 且没有业务修改；保存后崩溃，磁盘同时已有修改和 committed receipt。持久化失败进入现有 fail-stop，不能继续响应未提交业务状态。

响应丢失时按原 operation ID 读取回执或重试同一 execute。重启接管时 `claim()` 返回原计划和回执，worker 跳过 committed 步骤，不再次调用模型。输入哈希不同直接冲突。

### 6.2 规范文档跨存储动作

[workspace.js](https://github.com/huapohen/doc-free/blob/equal_rights/workspace.js) 的 `edit()` 目前未把普通编辑的 operation ID 透传给规范写入；[server.js](https://github.com/huapohen/doc-free/blob/equal_rights/server.js) 的 `createLocalDocument()` 直接 replace，不能安全重试；[collab-server.js](https://github.com/huapohen/doc-free/blob/equal_rights/collab-server.js) 的 `/internal/compare-replace` 已有 operation map 雏形，但仅保存 revision，没有输入哈希校验。

实施需要：

1. 在 IM 计划中保存文档意图、输入哈希和服务器预留的稳定 doc ID。
2. CRDT 事务同时提交正文和 `{operation_id,input_hash,result_revision,result_hash}`，同 ID 不同输入拒绝。
3. 创建增加真正的 create-once：原 operation 已成功时返回原创建回执；不可 replace 已存在且可能已被人修改的文档。
4. 通过 CRDT receipt 查询确认结果，再完成规范文档索引、房间绑定和 IM receipt。后续人类修改不改变原 operation 已提交的事实。
5. 无法确认是否已执行时进入 needs_attention，不盲重放或换 ID 再创建；只有证明尚未提交且当前 fence 有效，才可继续同一操作。
6. 规范文档保存与 CRDT receipt 文件补 fsync，明确可声明的进程崩溃/掉电耐久性边界。

跨服务写入的 lease deadline 应在实际 CRDT 提交事务中核验；不能只在发出 HTTP 请求前检查，随后把超时但可能已提交的结果当作未执行。当前 IM 串行处理意味着已开始动作与撤权按提交顺序生效；不能承诺已经在另一服务提交的动作可被后来的撤权回滚。

这仍不是跨文件全局事务，但可通过稳定 operation ID、同业务存储的操作回执与显式恢复证明不会盲目重复。文档创建与更新必须在补齐这些机制后才进入默认自动执行目录。

## 7. 人眼可见的工作文档与因果限制

复用运行详情和 Markdown 导出作为动作工作文档：执行前展示计划、证据原文/版本、预计变更；执行后展示资源链接、before/after、操作时间、实际版本和每步状态。任务/日程回执不必再写成一篇普通规范文档，否则连原子任务更新都变成跨存储操作。

共享运行中只记录房间可见业务。今后支持私人邮箱等动作时，需要单独的个人可见运行文档、单独的事件范围和安全摘要；不能因为 Agent 可读自己的私信就向房间广播。

所有自动动作事件继承 `turn.root_id` 与深度，`eligible()` 对消息、任务、文档统一应用最大深度、同 root 去重和全 root 动作预算。它们不能通过把消息换成任务/文档事件产生无限新 root。模型输出、人工操作、协议调用都保留真实 actor，不能用伪造来源掩盖自动动作。

## 8. 具体接线点

| 位置 | 计划改动 |
| --- | --- |
| `active_agent/im.py`: SYSTEM、IMAgent.validate、cycle | 验证固定计划 schema；恢复原计划；顺序执行；读取回执；据实际结果提交 finish |
| `IMClient.request` | 安全解析受限 error code；当前只保留 HTTP status，无法区分 conflict、lease_expired、outcome_unknown |
| `native-im.js`: boundedContext、claim | 上下文摘要、能力/策略版本、动作预算及已有计划恢复 |
| `native-im.js`: 新 plan / operation 路由 | 计划冻结、lease fence、operation ledger 和统一业务 reducer |
| `finish`、cancelRunning、invalidateMessageRuns | 部分完成状态；停止未执行动作；保留真实 committed receipts |
| `eligible`、event、turnView、turnSummary、exportRoom | 统一因果预算、安全可见计划与回执渲染 |
| `office-features.js`: calendarInput、eventById、calendar handle | 复用当前房间/创建者 ACL；分离 reducer；回应补 revision |
| `workspace.js`、server.js、collab-server.js | 文档 operation ID、输入哈希、create-once、CAS receipts 与恢复 |
| `native-im-mcp.js`、native-a2a.js | 保持成员协议适配职责；以后可映射专用动作端点，不把全部工具塞进 finish |

A2A 的 owner/messageId 幂等和 fail-stop 设计可以借鉴，但 `native-a2a.json` 与 IM 业务保存分离，重启会把未知 submitted/working 转为 input-required；它不能替代本设计要求的同业务提交回执。首次实施优先使用上述专用 turn 端点。

## 9. 代码阶段验收要求

- 成功提交但丢失 HTTP 响应，仍返回同一资源与回执；没有再次模型推理。
- 第一步成功后重启，只恢复原计划剩余步骤；旧 lease、不同输入和新造 operation ID 不得绕过防重。
- pause、移除成员、停用身份、撤销会话、应用策略收紧后，下一动作被拒绝。
- 自己提交的版本推进不触发误判；他人的并发修改仍引发明确冲突。
- 部分完成、失败和取消都保留已发生事实；不存在模型自报成功却没有 receipt 的状态。
- 文档 CRDT 已提交但规范索引/IM receipt 丢失，可经同 operation 回执恢复；未知结果不盲写。
- 文档相同 operation 不同输入被拒绝，创建重试不会覆盖后续人工编辑。
- 私人业务不出现在房间上下文、事件、详情和导出中。
- Agent 互派任务、文档更新和消息交接都遵守同 root 深度与动作预算。
- 使用实际 HTTP 服务与真实模型分别验证协议和执行决策，报告明确 commit、时间、模型配置和产物，不把夹具输出当作模型完成业务。
