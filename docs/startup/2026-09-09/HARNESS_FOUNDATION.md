# 人机主动执行 Harness：首个可编译纵向实现

记录时间：2026-09-09T03:13:05+08:00（本轮实现与验证记录，后续验证追加在末尾）。

所在分支：`startup`。

实现基线：`acee8003c7c55694716778189179ec272da44347`，提交时间 `2026-09-09T01:22:28+08:00`，描述 `docs: close equal-rights stage and prepare major-version handoff`。

本文记录的 Harness 新代码尚未创建新提交。基线 SHA 不是这些新代码的实现提交号；正式阶段交付时应由总交付文档补充实际 SHA。

## 本轮范围与结果

已在 Go 模块 `services/collaboration` 实现可以实际编译、测试执行的 Temporal 工作流、Eino DeepAgent 阶段规划器、显式中间件、受限 HTTP 模型适配和 Worker 启动入口。假模型通过 Eino 的实际工具循环，Temporal 官方测试环境执行实际规划和动作 Activity，覆盖动作已经提交但回包丢失后的恢复。

这不是商业主动执行已经上线的声明。真实 Temporal 服务、持久 Run 登记、Clerk 机器绑定、统一动作与事件路由以及 PostgreSQL 持久幂等账本仍须完成端到端接入。本轮没有调用真实模型、启动 Harness Worker、注册第三方账号或修改现有公司群业务数据。

融云按用户最新要求作为正式 IM 传输必接；Harness 的 `message.send` 交给 Go 动作网关，网关结合 PostgreSQL / Outbox 和融云投递实现正式效果。Harness 不私下再发一条融云消息。

`message.send` 是首个纵向接入项，不是 Harness 的产品能力上限。`AllowedActionTypes` 和 Gateway 已按动作类型参数化，后续接统一能力/插件 registry：消息、群、联系人、文档、办公模块、设置、管理后台等都应以同一个已鉴权主体通过 API / MCP / A2A 获取、导出和执行。策略已授权时自动继续，不逐动作强制人工确认；未实现的能力明确拒绝，不用语言声称完成。原始动作和中间事件须可靠落入追加档案并实际投影到 doc_free，不能用聊天总结替代全过程。

## 版本与官方来源

| 组成 | 本模块锁定 | 本轮核对 |
| --- | --- | --- |
| Eino | `github.com/cloudwego/eino v0.9.19` | 稳定发布 tag；实际 `deep.Config` 为泛型配置的兼容别名，不能把旧示例字段直接照搬 |
| Temporal Go SDK | `go.temporal.io/sdk v1.48.0` | 官方发布版本；自身最低 Go 1.25.4 |
| 项目 Go | `go 1.26.0` | 与本模块其他依赖统一，由根任务维护 go.mod / go.sum；本次测试使用实际自动工具链 |

依据：[Eino 发布记录](https://github.com/cloudwego/eino/releases/tag/v0.9.19)、[固定 tag DeepAgent 构造源码](https://github.com/cloudwego/eino/blob/v0.9.19/adk/prebuilt/deep/deep.go)、[Temporal 发布记录](https://github.com/temporalio/sdk-go/releases/tag/v1.48.0)、[Temporal SDK go.mod](https://github.com/temporalio/sdk-go/blob/v1.48.0/go.mod)。

`deep.New` 没有替平台自动装齐所有中间件。本轮在代码中显式组合技能、输出缩减、摘要及 scope 检查。Runner 未设置 CheckPointStore，没有使用 TurnLoop 作为第二套长期主引擎；长期推进由 Temporal 唯一负责。[Runner 保存与恢复源码](https://github.com/cloudwego/eino/blob/v0.9.19/adk/runner.go)、[技能中间件](https://github.com/cloudwego/eino/blob/v0.9.19/adk/middlewares/skill/skill.go)、[输出缩减中间件](https://github.com/cloudwego/eino/blob/v0.9.19/adk/middlewares/reduction/reduction.go)、[摘要中间件](https://github.com/cloudwego/eino/blob/v0.9.19/adk/middlewares/summarization/summarization.go)。

## 代码与职责

| 路径（模块相对路径） | 已实现职责 |
| --- | --- |
| `internal/harness/contracts.go` | 固定版本 RunContext、原始 scope 链、Action / Receipt / Event、统一 Gateway / Planner 接口 |
| `internal/harness/planner.go` | 实际 Eino DeepAgent，规划输出严格解析，显式技能/缩减/摘要，模型与工具 scope 检查、事件归档 |
| `internal/harness/workflow.go` | 规划 Activity → 动作 Activity → 下一阶段；持久 timer、重试、取消、固定 action_id |
| `internal/harness/http_gateway.go` | 进程配置机器凭据绑定、握手检查、HTTP 契约、错误分类、禁止重定向传凭据 |
| `internal/harness/http_model.go` | 实现 Eino BaseChatModel，对显式兼容端点传输工具 JSON Schema；无隐式模型回退 |
| `cmd/worker/main.go` | 默认关闭；机器绑定与服务契约就绪后才能启动 Temporal Worker；Ctrl+C 关闭 |
| `internal/harness/harness_test.go`、`cmd/worker/main_test.go` | 真实 SDK + 假模型 + 假业务网关的边界测试 |

## 身份、scope 与生命周期

`RunContext` 保存 `PrincipalID`、`ExecutorID`、`RunID`、`RoomID`、`ScopeEpoch`、`OriginScopes`、`RuntimeVersion`、`WorkflowVersion`。这些字段只是执行元数据，不能凭请求正文自行证明身份或权限。服务端必须从机器凭据解析执行器，反查已登记 Run 的 Agent、来源群及所有继承代次；换群不能丢掉原来的停止约束。

规划器在每次模型调用前后、工具调用前后检查 Gateway。正式动作 Activity 再检查一次；Action Gateway 必须在持久事务中执行最终检查。每个长期存在的 Agent 有自己的人机 principal；DeepAgent 默认 `general-purpose` 仅是本阶段的临时研究角色，并未创建 IM 新成员，也不获得独立业务权限。

临时子 Agent 通过同一个受限预算模型、同一 scope 和独立带 Agent 路径的输出事件工作。跨独立 Agent 的委派登记、接受/拒绝、子 Run 与预算继承还未在本模块完成，不能用已有 `task` 工具冒充这部分能力。

## 恢复、停止与幂等

1. 工作流中没有网络、文件或模型 I/O。规划及动作的返回结果由 Temporal 历史记录；重放已经完成的阶段不再调用模型。
2. 规划 Activity 失败可以在同一阶段的新 attempt 重新运行。Trace ID 含 stage / attempt / event 序号，保留每次尝试，不把模型再次规划的不同结果覆盖到旧事件。
3. 模型只提出稳定逻辑 key。代码用 `SHA-256(run_id + NUL + key)` 生成 action_id，重排不能换一个 ID 重做同一效果；已成功 ID 在同一工作流内不再发出。相同 ID 改类型或 payload 当作契约错误终止。网关还必须跨进程持久比较意图并返回 409。
4. 正式网关回执为 `succeeded`、`rejected`、`running` 或 `unknown`。`running/unknown` 进入 `reconciliation_required`，不继续其他动作。后续平台需提供明确的查询/对账恢复入口，不把返回超时当成未执行。
5. 取消传播使用 Temporal heartbeat 和 context。规划器出现错误后先取消，并消费 Eino iterator 到关闭，避免遗留事件生产者。群停止仍必须先持久增加代次并关闸，再传播取消；停止 Worker 不能证明第三方已经撤回在途操作。[Temporal 取消语义](https://docs.temporal.io/develop/go/workflows/cancellation)。
6. 长期等待用 `workflow.Sleep`，恢复后重查当前 scope。暂未实施真实 Worker 强杀、服务重启及历史兼容回放测试；官方测试环境里的失败重试不是这类真实部署证据。

Run 固定 `eino-v0.9.19-renji-1` / `renji-stage-v1`。未来替换引擎可以实现同一 Planner 契约，但在途历史仍要由兼容版本 Worker 排空，不能把 Eino 私有状态直接加载成另一种图。

## 显式 Harness 装配及界限

- **技能：** 实际加载 `native-collaboration` 技能。每次列举和读取前均检查 scope。这里是内置的行为说明，没有装载任意磁盘脚本或把技能正文当授权。
- **输出缩减：** 12,000 字节以上的大工具结果卸载到每个 attempt 独有的私有存储，Agent 通过受控 `read_file` 回读。该存储不接宿主机路径，也不接 doc_free 共享正文。阶段失败重算时创建新存储，原始可见结果通过网关追加事件保留。
- **摘要：** 24,000 上下文 tokens 阈值显式触发，使用同一受控模型和全阶段调用预算；要求保留目标、用户修正、身份、原始 scope 及已完成回执。没有填写不存在的 TranscriptFilePath；设置摘要路径不等于创建档案。
- **预算：** 默认 8 次单 Agent 迭代、整个阶段最多 12 次模型调用、90 秒阶段时间；每阶段最多 4 个正式动作，Run 最多 32 阶段。HTTP 请求、响应、回执与 action payload 均有大小上限。
- **工作区：** 本轮只有隔离的阶段证据卸载存储，没有开放 Shell、真实电脑接管或共享目录写入。文件/代码 Agent 的实际沙箱、快照、进程租约和出口控制属于后续完整 Harness 范围。
- **文档：** doc_free、AFFiNE、Docmost 仍经 Document Gateway 接入正式资源。不能用本阶段 `read_file` 整体覆盖共享富文本，也没有把可编辑 Markdown 充当唯一审计事实。

## 内部 Gateway 接口

| 方法 / 路由 | 客户端要求 |
| --- | --- |
| `POST /internal/harness/binding` | 返回 `protocol=renji-harness-v1`，实际绑定 principal / executor，且 `server_bound`、`actions_idempotent`、`scope_epochs_enforced` 均为 true |
| `POST /internal/harness/check` | `{context}` → `{allowed:true}`；服务器以凭据和数据库登记为准 |
| `POST /internal/harness/actions` | `{context,action}` → 真实 Receipt；成功回包丢失后以原 action_id 查回执，不能重复派发 |
| `POST /internal/harness/events` | `{context,event}` → 2xx；按 Event.ID 幂等追加原始执行档案 |

服务端路由和持久绑定未实现之前，Worker 通过首个握手就会拒绝启动；不能把普通 Clerk 人类 JWT 填成执行器凭据绕过接入。HTTP 适配器只接受本机 HTTP 或 HTTPS；不跟随重定向传递凭据，日志不包含服务端原始错误正文或 token。

## 验证方式与已有证据

在 `services/collaboration` 运行：

```sh
go test -p 2 ./internal/harness ./cmd/worker
go test -race -p 2 ./internal/harness ./cmd/worker
RENJI_HARNESS_ENABLED=false go run ./cmd/worker
```

当前定向测试包含 18 个用例：真实 DeepAgent 技能调用；临时子 Agent 独立 trace；大结果卸载后回读；摘要阈值实际触发；模型结束时 scope 已停；Temporal 已提交动作回包丢失后的同 ID 重试；跨阶段重排去重；unknown 停止；停止前模型不启动；timer 恢复时撤权；timer 取消；同 ID 不同 payload；无效规划字段；HTTP 绑定/禁止重定向；握手字段缺失拒绝；模型工具 Schema；默认关闭；服务端未绑定时拒启。

这些用例不证明真实模型质量、规模化调度、商业认证、融云投递或真实服务宕机恢复已经完成。未调用任何真实模型接口，本轮假模型密钥只存在测试函数内，没有生产凭据。

## 下一步实际接入

1. Go 核心登记 principal / executor / Run，完整保留来源 scope 链与停止代次；增加机器鉴权与上表四个内部路由。
2. PostgreSQL 事务内原子关闸、动作意图哈希、回执与 Outbox；融云投递沿用同一 action_id 对应的正式消息。
3. 用真实 Temporal 持久服务启动 Worker，先验证消息动作成功回包丢失、Worker 强杀及重启、停止后旧进程和子 Run 不可继续。
4. 将事件归档投影到 doc_free 并同步 AFFiNE / Docmost；增加可见任务树、停止、对账与恢复 UI。
5. 接入正式独立 Agent 委派、模型实际评估、隔离工作区与快照，逐项验证完整蓝图要求。

## 2026-09-09T03:19:21+08:00 验证追加

- 最终定向测试：18 / 18 通过。
- 最终 race 检查：两个包通过；`internal/harness` 2.035 秒、`cmd/worker` 2.520 秒。记录在本机临时日志 `/tmp/renji-startup-harness-20260909-tests.jsonl`，不是长期归档或 Git 证据。
- `RENJI_HARNESS_ENABLED=false go run -p 2 ./cmd/worker` 成功返回并显示 disabled，没有连接模型、网关或 Temporal。
- 初次编译发现的 Eino API 字段差异已按固定版本修正：文件读取返回 `FileContent`，工具配置使用嵌入的 `compose.ToolsNodeConfig`。最终代码经过实际编译，未依赖只读文档推断可运行。
- 错误路径复核后修正 Eino iterator 的早退处理：先取消并消费到关闭；正式动作结果未知不新建逻辑 ID 重试；跨阶段相同 ID 改 payload 被拒绝。测试已覆盖对应可观察行为。
