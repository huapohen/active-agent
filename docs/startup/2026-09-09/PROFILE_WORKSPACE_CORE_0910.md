# 商业账号资料、工作空间与建群后端阶段记录

- 初稿时间：2026-09-09 09:10（Asia/Shanghai）。
- 冻结基线：`ddd947c7c3f74168ad1a17b11d4b04b5eb4599ad`，2026-09-09T08:34:06+08:00，`docs(startup): preserve message phase publication and native repair receipts`。
- 本文所述实施代码在写作时尚未提交；以上 SHA 是基线，不能作为本轮实施提交。最终实施提交由阶段主报告补录，不修改初稿时间。
- 机器可读证据：[PROFILE_WORKSPACE_CORE_EVIDENCE_0910.json](PROFILE_WORKSPACE_CORE_EVIDENCE_0910.json)。
- 本专题只记录后端及其隔离验证；真实 Clerk 用户界面、融云桥接和阶段主发布由各自交付记录说明。

## 本阶段实际行为

新的已认证账号可以读取自己的资料、修改昵称，看到真实的空工作空间列表，创建自己拥有的工作空间，再创建只有自己的群。成员查询只返回真实成员，创建时不补造同事。Human 与 Agent 使用同一 `principals` 身份、资料版本和持久动作表。

Agent 增加可执行的 `profile.update` 动作：先通过 `im_profile_read` 读取当前身份及版本，再通过已有 Run 网关改自己的昵称。该动作不接受请求指定另一个 principal，不改变角色或登录身份。完整来源 scope、停止代次、策略版本、成员权限和 executor 绑定仍在数据库事务内检查。没有只把工具名称挂到目录却绕过执行治理。

## API 与 MCP 契约

| HTTP | MCP | 返回与约束 |
| --- | --- | --- |
| `GET /v1/profile` | `profile_read` | `{principal:{id,kind,display_name},version}` |
| `POST /v1/profile` | `profile_update` | Human：`{principal,version,replayed}`；Machine：既有结构化 Action Receipt |
| `GET /v1/workspaces` | `workspace_list` | `{workspaces:[{id,title,role,created_at}],cursor}` |
| `GET /v1/workspaces/:workspace/members` | `workspace_member_list` | `{members:[{principal_id,kind,display_name,role}],cursor}` |
| `GET /v1/rooms/:room/members` | `room_member_list` | 同上，仅当前授权会话成员 |
| `POST /v1/workspaces` | `workspace_create` | 保留既有 201 和 `{workspace:{id,title}}`；本阶段 Human 可用 |
| `POST /v1/rooms` | `room_create` | 保留既有 201 和 `{room}`；`members:[]` 创建真实单人群 |

资料更新输入为 `action_id`、`display_name`、`expected_version`；Machine 额外必须传 `run_id` 和合法 64 位十六进制 action ID。HTTP 与 MCP 共用 Store，不接受 `principal_id`、`role`、未知字段、缺省版本或尾随第二个 JSON 对象。

列表支持 `after`（UUID exclusive 游标）、`limit`（默认 100，1–100）。数据库取 `limit+1` 判断后页。空列表为 `[]`，末页游标为空字符串；`/v1/rooms` 继续返回 `workspace_id`。

昵称先 trim，再校验 1–80 个 Unicode 码点、至多 320 字节、合法 UTF-8；控制字符、格式控制字符和 Unicode 行/段分隔符不允许。工作空间和群标题继续受 240 字节限制，并补上单行及合法 Unicode 校验。中文和 emoji 不是按单字节误判。

## 身份与来源权限

Human 普通读取以当前认证 principal 和当前成员关系为准；不接收 Human 自报 Run 作为额外权限。普通 Machine 读取限定当前有效 executor 绑定的工作空间。机器属于另一个工作空间，不等于该机器凭证获得另一个工作空间的访问权限。

Machine 显式带 `run_id` 的读取必须在同一事务内保持 Run 当前状态、所有原始来源 scope 和版本检查。工作空间成员读取进一步限制为该 Run 来源房间中当前可见的同事，避免把局部 Run 变成全组织通讯录导出。

停止执行不等于撤销正常历史读取：当前仍有效的机器绑定可以不带 Run 读取自己的资料及绑定空间内当前授权的目录；显式 Run 读取和动作重放仍拒绝已停止、旧代次或失效策略。撤销成员、禁用 principal 或禁用 executor 后不能通过列表、分页或重放绕过权限。

## 幂等、并发与事实记录

`profile_version` 由迁移 `00007_profile_version.sql` 添加，现有身份起始版本为 1，和房间执行版本分离。身份主键、种类与成员角色不随昵称改变。

同一 action ID 的规范化 payload hash 必须相同。重放返回原始动作回执，即使当前资料已到更新版本，也不会把原始回执改成当前状态。新的 action 若期望版本已过期，返回 `409 profile_version_conflict`；已有 action 换 payload 返回 `409 action_conflict`。客户端可据此区分“本次版本尚未提交”和“不能擅自替换不明动作”。

机器执行与 Human 更新共用资料动作事务，同时保留 `execution_actions`、原始执行事件和证据。资料更新不产生聊天消息或融云 Outbox，回执明确 `canonical_status:committed`、`transport_status:not_applicable`，不伪称外部送达。

资料修改需要全局本人 principal 的独占锁，同时执行仍锁所有来源。与群成员外发准入出现反向锁顺序时，profile 事务使用 150 毫秒局部锁等待上限；仅 PostgreSQL 确认回滚的 `55P03`、`40P01`、`40001` 进行最多 8 次同 action 重试。事务已返回并回滚后才重试，未知网络或提交结果不重试。耗尽返回 `503 profile_update_busy`，调用方继续保留同一个 action ID。未修改既有 Outbox 的派发方式。

## 能力声明

当前 registry 为 **23 项 capability**。有 emoji 目录时 MCP：Human 20 项、Machine 17 项；没有目录时分别 17、14 项。计数包含已有能力，不能当作本阶段新完成项。

本阶段新增 `profile.read`、`profile.update`、`workspace.list`、`workspace.member.list`、`room.member.list`。`profile.update` 的机器访问是 `run_required`，binding 明确返回该可执行动作及 `profile.read` 读取能力，Eino 只在能力可用时增加 `im_profile_read`。

配合接收桥登记 `transport.arrival.read`：Human API/导出可用，MCP/A2A 尚未实现；Machine 为 `available:false`、`run_scoped_receive_pending`。Human 能读该接口只表示能查询真实覆盖和接收事实，覆盖可以是 unavailable，不代表融云已连接或已收到消息。`transport.session` 只对部署配置中明确列出的合成验收 principal 声明可用；普通主体为 `rongcloud_client_write_policy_unverified`。白名单也不构成已验证的提供商连接事实。

## 验证证据与不重复计数

1. 首轮最终核心回归：真实隔离 PostgreSQL，`go test -p 2 -race -count=1 -json ./internal/store ./internal/httpapi ./internal/harness`，**133 个顶层测试 + 98 个子测试**，全部通过，0 跳过。日志 `/tmp/renji-profile-workspace-race-20260909.log`。
2. 最后补齐接收能力声明后：`go test -p 2 -race -count=1 -json ./internal/httpapi`，**27 个顶层测试 + 8 个子测试**，全部通过，0 跳过。日志 `/tmp/renji-profile-workspace-http-final-20260909.log`。

第二次覆盖并替代第一次中的 HTTP 重叠测试，不能相加。按 `package + test name` 去重并取最后结果，共 **134 个顶层测试 + 102 个子测试**。这些数字包括既有包回归；不等于本阶段新增的测试数量。JSON 证据保留各次日志 hash、测试名称、包结果及去重口径。

关键回归覆盖：12 路 Human 同 action 更新；8 路机器同 action 更新；版本冲突与 action 冲突不同错误码；修改本人不影响身份；撤权/禁用/停止与恢复旧代次拒绝；跨工作空间读取隔离；分页与真实 Human/Agent 角色；空账号和真实单人群；profile 与消息并发；群成员准入反向锁序下整笔回滚后仅成功一次。

`TestProfileEinoReadsCurrentVersionAndCommitsThroughRealHTTPPG` 使用真实 Eino 构造、HTTPGateway、Gin 和 PostgreSQL，Temporal 使用 SDK 测试环境，模型使用脚本假模型。它先原生读取版本，再提交 profile 动作、记录 completed，产生 1 条回执、0 条关联 Outbox；完成的 Run 不能再用于执行态读。该结果不能写成“真实大模型已成功运行”或“线上 Temporal 已验收”。

复跑须仅把本机忽略文件 `data/startup/api.env` 中的 `RENJI_DATABASE_URL` 装载为子进程环境变量 `RENJI_TEST_DATABASE_URL`，不要打印连接串或把它放命令参数。使用 `/opt/homebrew/bin/go`；fixture 每次创建独立 UUID schema、在该 schema 应用迁移，测试后清理。不要以复跑名义对 public 执行迁移或派发待发 Outbox。

## 本阶段没有完成的范围

- Machine `workspace.create`：全局空间 bootstrap 需要独立授权能力，本阶段明确不可用。
- Machine `room.create`：需要持久保存创建时所有来源 scope，并使以后在新房间创建的 Run 强制继承。只在创建动作挂当前 Run、却允许后续独立 Run 丢掉来源是不完整的。本阶段明确不可用，未放开 unscoped 写入口。
- 成员邀请、加入/退出、角色变更：未新增；本阶段是当前成员读取和既有创建群成员参数。
- A2A 和机器 Run 原生接收桥尚未闭合，未通过能力声明伪称实现。
- 本任务未调用真实模型、未启动真实 Worker、未迁移真实 public schema、未派发融云、未改原有待发业务记录。
- Runtime/Workflow 版本和已发布归档 renderer 均未修改。

后端源码冻结后，本专题只追加实施提交归属和其他责任方给出的真实验收结果，不用隔离测试替代真人界面或第三方接收证据。

## 提交后归属

本阶段实施现已提交为 `e975e94e900cc892e39ed52ac0ce94ccd71c6ea1`，时间 `2026-09-09T09:35:36+08:00`，描述 `feat(startup): onboard colleagues and relay verified RongCloud arrivals`。以上未提交说明属于当时验证记录；此归属不改写历史运行时间。真人 Clerk 的昵称、空间、单人群和消息操作已另作原生界面与数据库读回验收，见本阶段主交付文档。
