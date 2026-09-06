# 每位 Agent 同事的原生动作：实现与验证

- 记录时间：2026-09-06T15:20:16+08:00。
- 分支：两个仓库均为 `equal_rights`。
- Active Agent 基线 commit：`3beae3137c3193555360145300f81a0b5a1c888c`（2026-09-06T12:49:59+08:00）。
- Doc Free 基线 commit：`862609f45d7d4e61c1b2a9c4d33fe527fd31b5e1`（2026-09-06T12:49:59+08:00）。
- 本记录描述这些基线之后的工作区实现；最终交付 commit 由本批次总交付记录关联。先前 `NATIVE_ACTION_EXECUTION_DESIGN.md` 保留为设计时点文档，不改写为完成证明。

## 已交付行为

每个已安装、在会话内 active 且具备完整上下文应用权限的 Agent 以自己的身份领取租约。模型公开计划，服务器冻结步骤、参数、原文依据和最终说明，工作器依序执行真实业务动作，最后发布服务器生成的回执摘要。100 个职业目录模板不会启动 100 个模型进程；安装并进入可运行会话才进入工作器调度。

原生动作包括创建/更新任务、添加当前会话同事为联系人、创建/更新日历及以自己身份响应邀请。配置 canonical 文档适配器后增加创建/更新共享 Doc Free 文档。每一步仍走和人类同样的业务规则：会话成员、应用权限、日历创建者/邀请者、资源版本，不允许模型指定其他 actor 或发明任意外部工具。

任务标记 done 必须引用此次领取时已经存在的共享文档依据。未捕获到原始上下文的新文档不能被同一计划伪装成已经验证的证据；可以真实创建文档并创建下一位同事的评审任务。

## 接口与可见数据

1. `POST /api/im/rooms/:rid/turns/claim` 返回不变的 `context.context_hash` 与 `context.actions` 能力/预算。
2. `POST .../turns/:tid/plan` 提交 `lease_token/context_hash/model/reasoning_effort/summary/steps/final_result`。每步包含 `key/operation/arguments/evidence`，证据为捕获消息、文档、任务或日历的真实子串及版本；一次计划不可改写。
3. `POST .../turns/:tid/operations/:operation_id/execute` 提交租约和 `plan_hash`。稳定 operation_id 与 input_hash 使超时重试、工作器重启均返回既有结果，不重复业务。
4. `GET .../turns/:tid/plan` 返回公开计划和回执，也可调和已经提交但本地未确认的 canonical 文档回执。当前读者仍须具备会话及完整上下文权限。
5. finish 将权威 `action_summary` 和 `[服务端动作回执]` 写入运行/消息；不能用模型文本冒充执行成功。存在 applying 时先恢复再构造摘要，未确认则拒绝结束。

回执公开动作、参与者、运行及因果根、开始/提交时间、resource_id、前后版本、证据引用、失败码；文档增加 after_hash。提交后的业务不会因为后续步骤冲突被悄悄回滚。lease、凭据及内部恢复 intent 不进入运行视图。

## 有界自主性与恢复

- 每 Agent/会话可修订 `autonomy={enabled,max_steps,allowed_operations,review_interval_seconds}`；需 base_revision，自己或会话 owner 可配置，修改取消当前运行且保留已提交回执。
- 默认每次最多 4 步；每因果根最多预留 12 步；深度最多 3；同一 Agent 每根只运行一次。Agent 消息触发其他 Agent 仍要求明确 mention。
- 默认 300 秒复查，范围 60–86400 秒；active 同事有自己未完成任务或未来 24 小时内日历时，服务器产生可见独立 `agent.review`，不用人反复发消息。首次复查时钟持久化，重启不会重新开始等待。
- 每次业务前及 canonical I/O 后重新验证身份、应用、成员、租约与原始版本；只把自己真实动作生成的版本推进到 execution_manifest。其他人改动仍使后续动作 stale。
- 同文件任务/日历/联系人变更、事件、回执、manifest 一次持久化；存储失败进入 fail-stop，重启前不再接受读写。
- canonical 文档先持久化 applying+intent，再做稳定 create-once/CAS。确定未提交的4xx可记 rejected；通信不确定保留 applying，读取已提交回执恢复，一律不盲重做。恢复原 r1 回执不能覆盖人后续的 r2。
- 工作器5xx至多原 payload重试一次；已冻结计划恢复不再请求模型。`AA_IM_WORKER_SLOTS` 默认8、范围1–32；`AA_IM_MODEL_CONCURRENCY` 默认3、范围1–8，实际并发取两者较小值。worker不持有管理员密钥。

## 此时点验证

- Python `tests.test_im/tests.test_im_actions/tests.test_im_fleet`：19/19。
- Node动作、应用权限、IM、办公、MCP和真实文档HTTP专项：53/53，其中原生动作14例。
- 真实 HTTP+CRDT 两例：创建+更新 canonical 文档并创建真实任务、重复执行/finish、服务重启后读回；以及持久化 applying 的故障快照，恢复实际 CRDT 已提交回执，保持随后的人类 r2 不变，并拒绝后续过期任务动作。
- 故障注入覆盖保存失败、未知提交结果、旧租约、根预算、依据伪造、权限撤销、文档读取后到期、损坏账本与恢复摘要。这些测试的模型为固定 fixture；真实模型验收由本批次独立演示/验证文档记录，不能将故障模拟计为真实断电实验。

## 内嵌协作文档即时授权

Doc Free `nativeIM.authorizeDocument(credential,roomId,documentId)` 是同步只读函数，检查登录/机器身份、当前成员资格、im/docs 应用权限和单文档会话绑定。它不进入串行队列、不读取文档、不修改状态，供同进程 CRDT 在 Y 事务和 outbound 前调用。测试确认 logout、移群、停用账号、撤销 im/docs 权限立即失效；完整富文本入口由本批次主集成另外验证。

## 当前边界

这是受预算与版本约束的办公执行器；没有开放任意代码、外部转账或邮件发送给模型。时间复查依赖持续运行的fleet领取循环，进程停机期间不会假装执行。组织目录当前是单工作空间组织记录，不是多租户隔离。打卡 location_note 是自报备注，不能表示真实定位或围栏验证。
