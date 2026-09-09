# 消息回复与表情反应：Go 持久领域交付记录

初稿时间：2026-09-09 07:30:21 +08:00。基线提交 `c3a6f2697544d6c9784c9d6e49da658c19736c78`（2026-09-09 07:03:54 +08:00，`docs(startup): preserve three-platform phase publication receipts`）。本专题实现当前未提交；该 SHA 是基线，不是本次实现归属。

本批完成领域层、隔离数据库验证和融云 Outbox 的能力分流。HTTP/MCP、Web、融云真实链路和原生验收由根任务另行记录，不能据本专题宣称已经上线。

## 回复引用

`SendMessage.reply_to` 为可选的同会话消息 ID。服务端读取引用消息，持久生成 `reply`：消息与会话 ID、作者 ID/名称/种类、原消息序号和最多 240 Unicode 字符的原文摘要。客户端不能提交作者或摘要；不存在、格式错误或跨会话引用拒绝。当前领域尚无撤回/删除状态，因此这里的有效消息是数据库中存在且属于当前会话的消息，并未声称实现撤回生命周期。

迁移 `00006_message_interactions.sql` 增加引用外键及快照；组合外键同时约束引用消息和会话。没有回复时新 JSON 字段全部省略，保留原 `SendMessage` 序列化顺序和既有动作哈希。重放返回首次提交的引用快照，作者后续改名不会悄悄改写旧回执。

## 表情动作与权威数据

`SetReaction(ctx, actor, roomID, messageID, cmd)` 接受 `action_id / emoji / active / scope_epoch`。`active` 是明确的设置状态，不是 toggle；HTTP 和原生执行解析必须区分缺失、null 与 false。原生 `ExecuteAction` 已实现该严格字段校验。

Emoji 是部署目录中的稳定 ID，包括 `feishu:*`。Store 只依赖注入的 `ReactionEmojiValidator.Contains`，没有目录时拒绝反应操作；不以任意 Unicode 字符串替代实际目录。

人和 Agent 共用 `actions`，反应状态主键为消息、操作者、Emoji。每个新动作在同一事务保存状态、增加消息反应版本、保存回执、追加 `message.reaction_set` 事件及融云 Outbox。事件 data 是完整 `ReactionReceipt`。即使状态已匹配，新的动作仍增加版本并保存 `changed=false` 的事实；同一动作重放不增加版本、事件或 Outbox。

回执 JSON：`room_id, message_id, principal_id, emoji, active, changed, version, count, selected, replayed`。统计来自数据库，身份来自认证操作者；客户端不能指定计数。重放保留首次提交时的计数与版本，界面应重新读取单条消息或反应分页以获取当前状态。首次原生回执和 PostgreSQL jsonb 重放统一规范化，避免嵌套 JSON 键序不同被误判为新的结果。

## 读取与分页

普通消息读取每条最多返回 20 类反应，包含 `reactions / reaction_version / reactions_has_more / reactions_next_after`；初始版本 0 及空反应字段省略。原有 after 导出顺序和上限保持。

`ReactionSummaries` 及 `ExecutorReactionSummaries / ExecutionReactionSummaries` 返回扁平对象：`room_id, message_id, summaries, version, next_after, has_more`，其中每项为 `emoji, count, selected`。最多 50 类；按稳定 ID 的 C 排序分页。非第一页必须带 `expected_version`，版本不一致返回冲突，避免拼接不同快照。分页查询与身份、成员及来源范围验证持有同一事务锁。

机器普通历史读取仅允许当前绑定工作区与成员范围，停止不等于撤销历史阅读；显式 Run 读取同时要求原始 Run、全部继承来源、当前策略与 epoch 仍有效。根任务新增的单条及 before 读取复用本批 `scanMessage` 和 `hydrateMessages`，其 API 行为与独立测试由根任务记录。

## 执行与外发

原生 `reaction.set` 走现有执行身份和全部来源范围锁，并与领域修改及 Outbox 绑定同事务提交。来源停止、旧 epoch、策略版本变化、机器绑定变化或撤权均阻止新的原生操作；原生重放仍受完整 Run 治理。领域普通 Agent 回执重放沿用既有规则：当前成员仍可读首次回执，但不能因此创建新动作。

`ReactionMessenger.NotifyReaction` 是可替换运输能力；不支持该能力时明确拒绝，不调用普通文字 `Publish`。实际融云适配器由另一子任务实现，采用失效通知后读取权威状态。Outbox 对反应沿用租约、所有来源权限、unknown 不自动重发的规则；已确认 blocked 的 Agent 反应不阻挡之后的人类消息。

现有档案 v2 的摘要计数只识别 `message.send`。新的反应动作仍完整保存在原始执行证据中，尚未新增专门的反应摘要计数，不把模型文字或通知发送等同于业务完成。

## 验证与边界

- 专项真实 PostgreSQL：9 顶层测试、16 子测试通过，0 失败、0 跳过。覆盖回复快照、旧哈希、跨房间拒绝、12 并发同动作、明确取消、统计、分页版本、目录缺失、机器来源与工作区、停止/恢复/撤权、通知 unknown 与缺失插件。
- 完整 Store `go test -p 2 -race -count=1 -json ./internal/store`：48 顶层、32 子测试通过，0 失败、0 跳过。日志时段为 07:28:52–07:29:11 +08:00。
- `go vet -p 2 ./internal/store ./internal/domain`、`git diff --check` 通过。
- 使用已缓存 sqlc v1.31.1 源码及 Go 1.26.8 只读编译，再执行生成命令；生成模型也补齐先前迁移 00004/00005 的模型声明，没有手工伪造 generated 文件，没有新增模块依赖。

数据库凭据只经私有配置进入测试进程；测试只创建随机隔离 schema 并在结束后清理。未迁移真实环境、未启动 API/Worker、未向外部派发、未调用模型、未提交 Git。精简证据和本批源码哈希见 `output/startup-message-reaction-domain-20260909.json`。

## 最终实施提交归属

以上保留初次记录时的观察和边界。最终实施已纳入 `50570cac03b1314c831fc856e6ed826f60486fa8`，提交时间 `2026-09-09T07:55:18+08:00`，描述 `feat(startup): deliver native replies reactions and authenticated emoji`。后续集成测试、真实服务与注册状态以本阶段主交付文档为准，不将这里的早期测试数量重复计入最终总数。
