# Run 执行档案 → Doc Free：受控单来源合成适配器

记录时间：2026-09-09 05:49 +08:00。基线 commit：`380d7bef5b8ce78f6dae38b812e8aa9931ca67d1`，提交时间 `2026-09-09T04:52:22+08:00`，描述 `docs: preserve native publication evidence and fidelity gaps`。

初稿记录时，本文对应的 Store 证据导出、归档和适配器改动尚未提交。2026-09-09 05:57 +08:00 补充实际实现 commit：`a639a8843093bed98b04b375d361de6e2c2129c9`，提交时间 `2026-09-09T05:56:24+08:00`，描述 `feat(core): add native document verification and durable agent archives`。保留 05:49 初稿时间；`380d7bef` 仍是基线。

## 已实现与实际验证范围

服务端将已经持久化的 Run 原始事件、真实 action Receipt、Outbox 传输状态及终态渲染为可见 Markdown；`cmd/run-archive` 以真实 Clerk 机器验证器和固定部署配置，执行一次 Doc Free 创建并独立读回比对。命令没有模型、业务消息、Temporal worker 或任意 URL 入口。

本组件已通过本机 `httptest` + 独立真实 PostgreSQL schema 测试；这些自动测试没有访问真实 Doc Free、没有发送聊天消息、没有运行模型。真实 Doc Free 的首次创建及人/Agent 读回随后由主任务单独执行，结果单列于末尾，不从模拟 HTTP 测试推断。

**当前只开放 `single_source_synthetic`。这是隔离合成群归档能力，不是生产环境跨服务 ACL 闭环。** 目标成员查询与随后 POST 之间没有跨服务 CAS；文档创建后，直接从 Doc Free 阅读也不能动态回查 Go 原始来源的成员撤权。多来源 Run 一律拒绝。仅创建专用群、先核对成员或保存映射，不足以宣称解决上述问题。

## 固定配置与启动

新增迁移 `00005_archive_target_binding.sql` 固化 `binding_id → config_hash`。需先通过既有 API 部署迁移流程应用 00004/00005；归档命令自身不会迁移数据库，也不会启动后台服务。不要因缺少表而手工复制旧表、删除 intent 或重建文档。

私有 JSON 必须是普通文件、权限 0600、100 KB 以内，放在 Git 忽略的 `data/startup/run-archive/`。不允许符号链接、未知字段、JSON 后追加对象或内联 token。所有凭据只通过下列 env 名从进程环境读取：

```json
{
  "schema": "renji.run-archive.v1",
  "enabled": false,
  "mode": "single_source_synthetic",
  "database_url_env": "RENJI_DATABASE_URL",
  "clerk": {
    "issuer": "https://INSTANCE.clerk.accounts.dev",
    "receiver_machine_id": "mch_RECEIVER",
    "machine_secret_env": "CLERK_MACHINE_SECRET_KEY",
    "token_env": "RENJI_EXECUTOR_TOKEN"
  },
  "targets": [
    {
      "binding_id": "approved-synthetic-source-v1",
      "approved_by": "deployment-owner",
      "approval_reference": "approved-isolated-synthetic-test",
      "workspace_id": "GO_WORKSPACE_UUID",
      "source_room_id": "GO_SOURCE_ROOM_UUID",
      "doc_free_endpoint": "http://127.0.0.1:3218",
      "doc_free_room_id": "room-SYNTHETIC_TARGET",
      "doc_free_principal_id": "principal-ARCHIVE_AGENT",
      "doc_free_token_env": "RENJI_ARCHIVE_DOC_FREE_TOKEN",
      "principal_mappings": [
        {
          "go_principal_id": "GO_HUMAN_UUID",
          "doc_free_principal_id": "principal-SYNTHETIC_HUMAN"
        },
        {
          "go_principal_id": "GO_AGENT_UUID",
          "doc_free_principal_id": "principal-ARCHIVE_AGENT"
        }
      ]
    }
  ]
}
```

上面是不可直接执行的占位模板。实际 source/target 和 principal 映射须由部署者固定，不接收模型指定的地址、凭据、目标群或身份。`approved_by` / `approval_reference` 记录部署审批上下文，不是密码学授权证明。

在 Go 模块 `services/collaboration`，已安全加载上述私有环境后执行：

```sh
go run -p 2 ./cmd/run-archive --config ../../data/startup/run-archive/synthetic-v1.json --run RUN_UUID
```

只有显式设置 `enabled: true` 才会工作；关闭时在读取凭据、连接数据库和网络操作前返回 `run_archive_disabled`。`--token`、`--endpoint`、`--fake-machine` 等参数不存在。停止命令可使用正常进程取消；取消不会给予第二次创建许可。

## 身份、读取与目标约束

1. 每次归档通过真实 Clerk `VerifyMachine` 检查有限有效期、issuer 和 receiver audience；凭证是机器 token，不能沿用人类 JWT。每个外部请求前再次验证，并固定同一个 machine subject。
2. Store 从持久绑定解析 executor → Agent / workspace。该 Run 必须属于这个 executor 和 Agent。仅同名、客户端自报 principal 或映射给另一 Agent 均不接受。
3. 来源 workspace/room 必须在配置白名单中，Run 的 `OriginScopes` 必须为空。所有配置中的目标 principal 都必须有明确 Go principal 映射；写文档的 Doc Free 身份必须是该映射中的 Agent。
4. 归档使用历史 `audit` 读取规则：停止、旧 epoch 或已失败不抹去已有事实；当前主体禁用、绑定停用、任一原始来源的成员/工作区权限撤销会拒绝读取。它不使用归档权限执行新业务动作。
5. 每次外部调用都在 Store 的当前来源与映射受众成员检查事务中进行，锁保持到该次请求结束。网络最多 12 秒，源事务回调最多 15 秒；不把上次 preflight 缓存作为新调用的来源授权。
6. Doc Free `GET /api/im/me` 确认固定 Agent；`GET /api/im/rooms/:id` 的全部成员必须属于配置映射，不能含未知成员或重复成员，写入者必须在场。目标读是有界完整 JSON，不能拿截断的成员数组当全部受众。
7. 固定 endpoint 只允许 HTTPS 或本机 loopback HTTP，禁止 userinfo/query/path，所有重定向拒绝跟随，凭据不会跟随重定向到新地址。URL、room、writer、映射或审批配置在同一 binding ID 下改变会冲突；token 值可以在原 env 名下正常轮换。

## 一次创建与可对账结果

PG `execution_archives` 保存固定 Run 前缀、renderer version、标题、正文精确 hash、parts 和验证游标。模型文本明确标为报告，不能覆盖真实 Receipt、传输 unknown/pending 或 failed Run；原始事件 JSON 保留。Markdown 没有末尾 LF，以符合 Doc Free 入口尾部换行规范，同时仍要求精确 hash 相等，不接受模糊文本相似。

创建前 claim 和 `request_started_at` 先落盘；网络前再校验当前来源权限。每个 part 仅首次允许 POST。请求一旦可能外发，超时、断连或进程退出会保留 unknown；不会把 token/lease 过期当作重新 POST 的许可。

| 持久结果 | 下一次归档行为 |
|---|---|
| prepared，未开始写 | 当前授权后取得首次创建 claim |
| in_flight 且有效 lease | 并发调用返回冲突 |
| unknown，缺少目标 ID | 保留 `create_outcome_unknown`，不再次创建；需可靠外部证据辨认原目标 |
| unknown，已有目标 ID | 仅 GET 原目标；读取成功且精确 title/body hash 相等才能 verified |
| verified | 复用同一 intent/ID并再次只读校验；目标已变更返回 `archive_target_changed` |
| 新证据游标但旧 intent 未验证 | 先复用旧 intent，不绕过未知创建 |
| 旧快照已验证，Run 有新证据 | 新建下一版固定证据快照；旧快照与游标保留 |

目标 GET 必须返回相同 ID、有效 revision、完整正文及与其原始 bytes 一致的 content hash；随后才与源标题和正文精确 hash 比较。POST 返回 ID 不等于 verified。外部实际响应即使晚于调用取消/权限变化，也可以由原 claim 记录事实；这种记账不授予读取正文或再发请求的权限。

命令失败时会重新验证机器身份及当前来源 ACL 后读取持久元数据，避免把 dispatch 前的 prepared 快照当作当前状态；若无权再读，只返回已经知道的归档/Run ID。stdout 不包含凭据、claim token 或正文。

## 验证证据与后续自动化边界

正常回归：Store 36 个顶层 + 16 个子测试，HTTP 11 + 4，runarchive 11 + 14，命令 2；合计 **60 个顶层 + 34 个子测试**，全部通过，无跳过。最后冻结的 adapter/命令 race：**13 个顶层 + 14 个子测试**，全部通过；四包 `go vet -p 2` 通过。

测试覆盖：失败及停止后的审计、精确读回和重复调用、丢失创建响应、伪造 hash/标题、已知 ID 只读恢复、多来源拒绝、陌生目标成员、源 Agent/人类受众撤权、禁用 executor、错误机器身份/receiver、无限期 token、发前重新认证、源权限锁与并发撤权、6 次并发归档仅 1 次 POST、目标配置漂移、重定向不泄露凭据、配置关闭及参数注入。每个 PG fixture 创建独立 schema，结束后删除；所有 Doc Free HTTP 都是本机 `httptest`。

日志和当前源文件 hash：`RUN_ARCHIVE_DOC_FREE_EVIDENCE_0549.json`。首轮测试暴露的 unknown 缺 ID 重复取得无意义 lease 已修正；未知创建仍从未重发。

**本期仍是 CLI，尚未自动连接 Temporal Terminal Activity。** 建议最小插件接口：

```go
type ArchivePlugin interface {
    ArchiveRun(context.Context, string /* persistent Run ID */) (ArchiveResult, error)
}
```

插件从固定服务器配置绑定凭据和目标，不接收模型提供的 RunContext/正文/URL。Terminal 的真实终态事件成功提交后，独立 Archive Activity 调用插件；终态事实和归档投递结果分别保存。归档失败不能回滚 run.failed/completed、不能重跑 Planner 或重发 message.send。Temporal 重试只重试归档调用：已知 ID 的 unknown 可只读重试；无 ID 的 unknown 必须转待对账而非创建重试。完成 durable intent 的恢复与插件注册、取消语义及真实工作流验证后，才能声称终态自动留痕已接通。

持续每阶段可见留痕也仍需后续独立设计，不能由“终态自动归档”替代。生产多来源需要动态来源 ACL 网关与明确跨系统 principal 映射；本次没有把这些未完成项描述为已经实现。

## 2026-09-09 05:57 +08:00 真实归档结果追加

主任务在已授权的隔离合成群完成了真实 Doc Free 创建与第二次归档。原始验证记录时间为 `2026-09-08T21:53:42.838679+00:00`（北京时间 05:53:42），本节在实现提交后追加，没有把执行时间改为提交时间。

| 事实 | 真实读回结果 |
|---|---|
| 来源 Run | `76dedd18-1ddf-4fc0-abfa-19aee795b034`，状态 `failed` |
| 固定归档 | `75ae64e9-7234-4293-8b15-8cbfb70faefb`，`through=5`，`verified_through=5` |
| 新建 Doc Free 文档 | `9d62380a`，revision 1 |
| 人类与 Agent 读取 | 均 HTTP 200，均读回同一文档与 revision，实际正文 bytes 的 hash 匹配冻结来源 |
| 非成员读取 | HTTP 403 |
| 第二次归档 | 归档对象相同，复用原文档 ID，没有第二次创建 |
| 旧文档保护 | 原 3 份文档的完整对象保持相同；总量从 3 到 4，仅新增 1 份 |

正文 SHA-256：`e37f8cacc7f3e26a53c66be9b0c89e90273e98ca1efc5da44109b980aa5d9fe9`。标题 SHA-256：`68f797beab2c5ded0e2e757b45e5054fda3deb1bcd2bb619f010295c2090d887`。两个身份读回一致。

本机原始证据：[live-verification.json](../../../output/startup-runarchive-case2-20260909/live-verification.json)。该结果证明失败执行的既有事实可以可靠、可见地归档；`model_success_claimed=false`，没有宣称模型执行成功，也没有产生新的模型或聊天动作。终态自动归档和生产动态来源 ACL 的未完成范围保持不变。
