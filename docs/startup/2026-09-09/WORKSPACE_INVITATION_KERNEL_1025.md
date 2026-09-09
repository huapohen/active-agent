# 工作空间邀请：Human / Agent 同源授权与一次性凭据

记录时间：2026-09-09T10:25:00.267401+08:00。

基线提交：`1ea4685b4df3f0a9e9bffd0400c295b2bfb723e1`，2026-09-09T10:00:39+08:00，`docs(startup): preserve account phase publication and independent receipts`。本文件所述邀请实现当前尚未提交；最终实施 commit 由根任务收尾追加，不能把基线当成本次实现归属。

本阶段新增已认证同事加入既有团队的业务内核。没有注册新的 Clerk 身份，没有以昵称或自报邮箱选定接受人，没有发送邀请邮件，也没有修改本机真实业务库或重启服务。现有 Clerk 人类验证和 M2M issuer/subject 绑定继续提供真实主体，邀请只负责工作空间的 `member` 授权。

## 权限与凭据

- 当前 workspace owner/admin 可以创建或撤销邀请；Human 和具备同样角色的 Agent 进入同一 Store 内核。Agent 写操作必须带绑定机器身份及真实运行中的 Run，不能只传裸 principal ID 绕过执行范围。
- 服务端生成 32 个随机字节，编码为 `rji_` 加 43 个 base64url 字符。数据库只保存 SHA-256；明文仅首次成功响应提供。邀请码不进入 actions、execution_actions、events 或普通档案。固定只授予 member；若接受者已经是成员，保留其原角色，不替换管理员角色，也不额外授权。
- 有效期默认 86400 秒，可配置 60—604800 秒；有效期在最终数据库更新处再次检查。每个邀请只有一次消费结果；同一接受者的原 action 并发重试得到相同效果，另一个主体不能抢用已消费邀请。
- 身份来自认证中间件。昵称、邮箱、客户端 principal_id 和 role 不是接受身份或授予角色的选择入口。

## 原来源不会因为邀请被转交而消失

Agent 创建的邀请附有 creator_role、issued_run_id 和固定 authority 快照：原 Run.Context、工作空间、执行器/人格策略版本、issuer/subject。任何主体接受尚未消费的邀请时，都重新检查创建者当前 owner/admin、执行器启用与绑定、策略版本、所有原群停止和 epoch。原 Run 已 completed 可以完成之前发出的授权；stopped/failed/reconciliation_required 或来源、配置已撤销的 Run 不行。

若接受者自身是 Agent，其当前 Run 也必须运行中并通过全部来源检查。两方 Run 锁与合并后的来源 room 锁按固定顺序取得，锁保留到本地事务提交。接受新团队只登记 member 和 grant 审计，**不修改 executor.workspace_id、Run.Context、来源 scopes 或执行人格策略**。这个执行器随后仍无法使用旧绑定读取/执行另一工作空间；新执行范围需要目标团队的独立正式授权。

一次邀请消费不等于自动入群，不创建任何群成员；既有私密群仍独立检查 room membership。

## API / MCP 共用内核契约

HTTP 使用新文件中的 nativeWorkspaceInvitation* helper；根任务负责共享 MCP/capabilities 接线。此子任务的验证范围是 Store 与 HTTP，不能提前把尚未完成的 MCP 集成说成已验收。

| 接口 | 内容 |
| --- | --- |
| POST `/v1/workspaces/:workspace/invitations` | `action_id`、可选 `expires_in_seconds`、Agent 的 `run_id`；首次返回 `code_available=true` 和 code |
| GET `/v1/workspaces/:workspace/invitations` | owner/admin 分页元数据；`after/limit/run_id`；从不返回 code |
| POST `/v1/workspaces/:workspace/invitations/:invitation/revoke` | `action_id/run_id`；撤销未消费邀请 |
| POST `/v1/workspace-invitations/accept` | `action_id/code/run_id`；仅为当前已认证主体接受 |
| GET `/v1/workspace-invitation-actions/:action` | 当前主体自己的脱敏动作回执；Machine 检查原 Run；不恢复邀请码 |

请求严格拒绝未知字段、身份/角色伪造及重复查询参数。所有邀请 HTTP 响应标记 `Cache-Control: no-store`。Machine action_id 必须为 64 位十六进制，Human 沿用现有逻辑动作 ID 规范。

邀请状态为 pending / accepted / revoked / expired。写回执包含 invitation、workspace_id、principal_id、role、already_member、execution_scope_extended（当前总是 false）、replayed、code_available；只在首次创建成功时出现 code。元数据包含 create_action_id，便于丢失响应后查找原邀请。

## 超时和幂等恢复

同一 action 不重复创建邀请码或消费授权。创建响应丢失后，再次提交原 action 返回原邀请元数据和 `code_available=false`，无法反解旧密码。客户端内存中已持有 code 可继续显示；页面刷新丢失 code 后，可以显式撤销旧邀请，再由新的用户意图创建，不自动重建。

接受超时后可用原 action ID 查询回执；查询 404 只表示未找到，不能把其他异常当成没执行。code 仅留内存，不写 URL/sessionStorage/普通日志。若需重输原 code，应继续原 action，换 payload 会发生 action_conflict。

invitation_expired / invitation_revoked / invitation_used 只在原主体/action 尚未提交时返回。已提交 action 的重放先检查持久回执；普通权限撤销、Run 停止或读取失败仍需保留原意图，不自动生成新动作。未知邀请码统一拒绝，不能通过昵称或邮箱替代 code。

## 审计、迁移与独立复核

迁移 `00010_workspace_invitations.sql` 新建邀请表，保留 code_hash、签发身份与角色、过期/撤销/接受时间、两方 Run 关联，不级联删除旧审计。原事务同步写 actions，Machine 另外写 execution_actions 与原来源群的 execution.action.committed；代码明文只存在首次返回对象，持久副本固定去除。

独立审查发现的锁序问题已修复：普通 Send/ExecuteAction 在 room 前取得 action advisory，而初版邀请曾相反。现统一为 Run → actor/action advisory → 全部来源 room；确定性 PG 回归在 action 被另一事务占用时验证没有提前持有来源 room，避免交叉路由同 action 死锁。

真实隔离 PostgreSQL 的 race 回归通过 **11 个顶层测试 + 3 个子测试**，0 skip，覆盖权限、code 不持久、同 action/不同消费者并发、过期撤销、当前创建者角色与机器配置撤权、completed 原 Run、父群刹车、跨团队 grant 不扩执行器范围、认证 HTTP 和恢复查询。证据：[MANIFEST.json](evidence/workspace-invitations/MANIFEST.json)、[原始测试输出](evidence/workspace-invitations/isolated-pg-race-tests.txt)。

边界：这不是自动邮箱发送、全量组织身份同步、自动入群、动态跨 workspace executor 改绑或完整通用 Eino 邀请工具链。未来通用模型/工具记录必须单独处理这类一次性凭据，不能把原 code 放入普通 tool.result/model transcript。真实 UI 与 MCP 联合验收由根任务继续，当前没有 live 数据变更。

## 最终源码冻结与 MCP 一致性复核

追加时间：2026-09-09T10:34:13.619314+08:00。保留上文 10:25 初稿的 Store/HTTP 观察范围；本次新增完成根任务的 5 个 MCP 工具接线后独立协议验证，尚未产生本阶段实施 commit。

`workspace_invitation_create/list/revoke/accept/action_read` 与上述 HTTP 共同调用同一动作内核。新 `workspace_invitation_mcp_test.go` 覆盖首次邀请码仅在响应出现、HTTP/MCP 交叉重放与动作读取逐字段相等、列表不含 code、撤销/已消费错误、Machine 真实 Run 与原来源刹车、Agent 接受新工作空间但 executor 范围仍不改变。

输入存在性统一：TTL 省略才使用默认值，显式 0/null 拒绝；code/action 的 null 拒绝，额外 role/身份字段拒绝。Human 写入及读取任何显式 run_id（包括空串）拒绝；Machine 邀请 list 与其他四个工具均须有效 Run 并检查全部来源，不能借目录读绕过 run_required。

最终真实隔离 PostgreSQL `go test -race ./internal/store ./internal/httpapi -run TestWorkspaceInvitation -count=1 -v` 通过 **15 个顶层 + 8 个子测试，0 skip**。无 live 迁移、业务写入、外部消息或模型调用。初版锁序 P2 已由独立 Harness 审查确认关闭：固定 Run → actor/action advisory → 全来源 room。更新后的上述 manifest 固定当前 7 份源码及最终测试日志哈希，真实界面/部署验收另由根任务记录。

## 实际实施提交归属

最终实施已纳入提交 `30c6c22ce3ff24676d9d5a43bf1b3ce0cf14aafa`，提交时间 **2026-09-09T10:33:54+08:00**，描述：`feat(startup): invite human and agent colleagues with scoped arrival reads`。上文“尚未提交”为各初稿及测试观察时的历史状态，现追加真实归属，不将原基线或文档提交冒称实施提交。此条不代表本专题已执行 live 迁移或真实邀请码验收；运行态由根任务另行记录。
