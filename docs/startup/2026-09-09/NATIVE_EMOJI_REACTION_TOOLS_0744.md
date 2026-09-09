# 原生表情与反应工具：Harness 接线记录

初稿时间：2026-09-09 07:44:44 +08:00。基线 `c3a6f2697544d6c9784c9d6e49da658c19736c78`（2026-09-09 07:03:54 +08:00，`docs(startup): preserve three-platform phase publication receipts`）。当前实现未提交；基线 SHA 不冒充本次变更提交。

本批把商业 Go 消息领域接到真实 Eino 工具构造、HTTPGateway 和既有 Temporal 动作阶段。没有调用真实模型、没有启动实际 Temporal Worker、没有融云派发或 Doc Free 写入；完整商业运行及原生界面验收由根任务独立记录。

## 部署能力与兼容

`/internal/harness/binding` 的明确 `action_types / read_capabilities` 决定 Worker 的可用动作及扩展读取工具。`cmd/worker` 使用已验证的 `AllowedActionTypes()`，不再固定为只有 `message.send`。没有表情目录时，服务端不承诺 `reaction.set / emoji.list`。

只有旧服务缺失 `action_types` 字段时兼容为原 v1 的 `message.send`；明确 null、空列表、重复类型或握手失败拒绝，并清空之前的能力。对调用者返回切片副本，避免在另一个协程或调用处悄悄修改能力。

未变更 `RuntimeVersion / WorkflowVersion`、Workflow 名称、Activity 名称、入参或既有历史分支。模型与 HTTP I/O 都仍在 Activity 中；历史回放不重新调用已完成的模型或动作。已有旧业务及归档历史回放用例随最终 Harness race 套件通过。

## Agent 原生工具

新增可选 `NativeInteractionReader`，不要求旧 `NativeReader` 测试夹具或部署实现新增方法。明确声明相应读取能力时，Eino 注册：

- `im_emoji_list`：查真实目录 ID、名称及资源路径，支持搜索、分类和 revision/offset 分页。
- `im_message_get`：直接读指定消息，包含同会话回复快照和有界反应汇总。
- `im_reaction_list`：分页读取当前统计及当前 Agent 的 selected 状态；后续页必须带 expected_version。

接口 URL、凭据、Principal、Executor、Run 和来源范围都来自执行器配置及已固化 Run，模型参数不能覆盖。HTTP 请求自动带 `run_id`，包括共享目录；每次读取前后进行当前授权检查。来源停止或撤权发生在读取期间时，丢弃整个结果，不写入 tool.result，不再传给模型。

HTTP 边界与可替换 Reader 的工具边界各自验证结果：会话与目标消息一致、回复不能跨来源、消息反应汇总有界、计数为正、版本和游标匹配、目录分页推进且 revision 一致。旧分页消息工具也新增回复/反应嵌套校验，避免替换 Reader 通过内嵌引用带入其他会话内容。目录资源路径只作为认证 API 数据返回，不会自动访问外部 URL。

规划指令提供 `message.send` 的可选 reply_to 以及 `reaction.set` 的实际 payload 形状，明确 active 必填 true/false、不得 toggle、不得在规划中进行写动作。最终动作仍经过既有网关、动作幂等账本及完整来源 epoch 治理。

## 隔离联调证据

新增 `internal/httpapi/harness_interactions_test.go` 使用真实 PostgreSQL 隔离 schema、真实 Gin API、真实 HTTPGateway 和 Eino DeepAgent；模型为确定脚本，Temporal 为 SDK testsuite。

一次合成执行实际完成：目录查找 `feishu:OK` → 单条消息 → 反应页 → 取消当前 Agent 的反应 → 同会话引用回复 → 持久 run.completed 与事件记录。数据库确认 2 个原生动作、2 个绑定该 Run 的 pending Outbox；统计从两人反应变为一人，当前 Agent selected=false。没有将 pending 说成融云已送达。

另外验证真实 API 的全局目录仍遵守来源停止、恢复后旧 epoch 不复活；未配置目录的 binding 仅提供 message.send，反应动作和目录读被拒绝。

最终测试时段 2026-09-09 07:42:28–07:42:37 +08:00：

- `internal/harness + cmd/worker` race：49 顶层、54 子测试通过，0 失败、0 跳过。
- 新增真实 PostgreSQL/HTTP/Eino/Temporal 联调 race：2 顶层通过，0 失败、0 跳过。
- `go vet` 与本批 `git diff --check` 通过。

完整路径、日志 SHA-256、冻结源码 SHA-256 与具体时间见 `output/startup-native-interactions-harness-20260909.json`。原始 reaction evidence 已持久化；已发布的档案 v2 渲染器未改，未伪称新增专门反应摘要或新的真实模型成功执行。

## 配置一致性收尾

2026-09-09 07:47:48 +08:00 追加。只读审查根部 HTTP/MCP 发现两项配置一致性问题，经根任务授权做最小修复：去除目录时清空旧 Store validator；MCP 隐藏未配置目录的查找/读取/反应写工具，反应历史读取保留。工具数在无目录时为人类 12 / 机器 9，有目录时为 15 / 12。绑定能力、MCP 与底层反应校验不再因旧配置残留而分歧。

最后变更只影响 httpapi，受影响整包真实 PostgreSQL race 为 19 顶层、4 子测试通过，0 失败、0 跳过（07:47:24–37）。包含新增复用 Store 去除目录的内部动作拒绝回归。Harness/Worker 源码维持上一轮冻结；没有重复扩展功能。初稿中 2 项联调仍是当时测试记录，本次整包包含这 2 项及新增目录移除回归。

## 最终实施提交归属

本阶段实施已归入提交 `50570cac03b1314c831fc856e6ed826f60486fa8`，提交时间 `2026-09-09T07:55:18+08:00`，描述为 `feat(startup): deliver native replies reactions and authenticated emoji`。以上三项已与 Git 提交元数据逐项核对。

前文的基线、观察时间及“当时尚未提交”状态保留为历史记录；本段补充最终实施归属，不改写当时的测试范围，也不将脚本模型联调改称真实模型或融云端到端验收。
