# 官方 Clerk 机器凭据 → Go Run 网关：真实联调回执

- 记录时间：2026-09-09 04:09 +08:00。
- HTTP 验收时间：2026-09-09 04:07:12–04:07:19 +08:00；独立 PostgreSQL 只读回查至 04:08:48 +08:00。
- 分支：`startup`。
- 基线提交：`acee8003c7c55694716778189179ec272da44347`，2026-09-09T01:22:28+08:00，`docs: close equal-rights stage and prepare major-version handoff`。本轮新增实现尚未提交，该 SHA 仅是基线。
- 新增文件：`services/collaboration/cmd/execution-probe/main.go`、`main_test.go`。未改 Store/路由/Outbox/迁移、未启动 transport-worker、未操作桌面或 Web。

## 结果

**21/21 项真实检查通过。** 官方签发的 opaque M2M token 经正在运行的 Go API 和 Clerk 验证器解析为服务端绑定的合成 Agent；REST、internal action gateway、MCP 的同一 stable action 只落一条消息。伪造执行器、删减来源范围、没有 Run 的消息请求均拒绝。只停止来源群时，未停止的目标群也拒绝旧 Run 的新动作；来源恢复后，旧 epoch 不会复活。

这是**真实机器凭据与 Go HTTP/PG 链路**验收，未使用假 M2M JWT、mock 人类会话或模型生成的成功文字。Clerk 默认 opaque M2M 需按接收方 machine secret 调用官方验证服务；机器身份与业务 Agent 绑定分开。[Clerk M2M 指南](https://clerk.com/docs/guides/development/machine-auth/m2m-tokens)

**管理员初始化边界：** 注册 executor、开启 Agent proactive、创建父子 Run、停止/恢复来源群使用受控测试 CLI，通过已有 Store 管理接口调用。CLI 复用了已登记的合成 workspace owner。这不等于已经完成 Clerk 真人登录→管理员页面操作的闭环；回执固定记录 `bootstrap: test-admin-store-cli`、`clerk_human_login_verified: false`。

本轮没有运行 Eino 规划或 Temporal worker，也没有将新增目标群/消息投递融云。前一阶段融云 4 项 delivered 的真实验收保留不变。

## 持久测试范围

复用原融云合成 run、workspace、owner、Agent、source room；原融云 fixture manifest 保持原样。执行测试单独创建 `data/startup/execution-gateway-fixture-v1.json`，所有 action IDs 在任何管理写入前按原 fixture run ID 和稳定逻辑名确定并 fsync。

| 对象 | 实际 ID |
| --- | --- |
| 原合成 fixture run | `2164910f-f0be-4660-8297-e1d3db3a491a` |
| workspace | `736b5198-479b-4505-8dbb-8d54b0d5c697` |
| 管理员 / owner | `19519294-3539-479b-8615-a9ee68709c2d` |
| 执行 Agent | `b49d2ffc-946c-4061-a6ef-5ed7e4308465` |
| server-bound executor | `65406456-48cf-4d57-83ee-6a90c206e7a1` |
| source room | `63892e35-efbd-40cb-86e6-17c7cab37aa6` |
| child target room | `97917531-399b-4540-ab3c-7edf2ad15f54` |
| child Run | `8983c3f0-6900-4e99-b8d6-3088d176a8d7` |
| 唯一提交消息 | `32dc50fa-b415-4f02-8e46-b8ad862c0d88` |
| 跨接口共享 action ID | `b06e5190a533850df8e981fdfa83e6c9a05c596d39ad9f987c1f77bc9c415b90` |

prepare 依次调用 `Store.RegisterExecutor`、`SetAgentExecutionPolicy`、`CreateRoom`、两次 `CreateExecutionRun`。child Context 中保存 source room epoch 1，目标自身 epoch 1；绑定不是由客户端提供的 `agent_id` 决定。

## 真实 HTTP 与 PostgreSQL 结果

| 检查 | 实际结果 |
| --- | --- |
| `GET /v1/me` | 200；principal 为表中合成 Agent，kind=agent |
| `POST /internal/harness/binding` | 200；协议 `renji-harness-v1`，principal/executor 与服务端登记一致，server_bound=true |
| `GET /v1/runs/:id` | 200；返回持久化 child Context，保留来源 scope |
| `POST /internal/harness/check` | 初始 200 |
| REST 首次提交 | 200；canonical committed，transport pending |
| REST 同 action 重复 | 200；同一消息回执 |
| internal gateway 同 action 重复 | 200；同一消息回执 |
| MCP `message_send` 同 action 重复 | 200；structuredContent 为同一成功回执 |
| 消息未带 `run_id` | 400 `invalid_request` |
| 伪造 binding 的 executor | 403 `forbidden` |
| 伪造 action Context executor | 403 `forbidden` |
| 删除 Context origin_scopes | 403 `forbidden` |
| PG 幂等计数 | target 1 message、child 1 execution_action、1 关联执行 Outbox |
| source stop 后 target 当前状态 | target 仍 stopped=false、epoch=1 |
| source stop 后新 action | 409 `scope_stopped` |
| source stop 后 Run check | 409 `scope_stopped` |
| source resume 后 target 状态 | 仍 stopped=false、epoch=1 |
| source resume 后旧 Run 新 action | 409 `scope_stopped` |
| source resume 后旧成功 action 重放 | 409 `scope_stopped`，没有利用旧回执越过当前停止代次 |
| 未向融云投递 | target 两项 Outbox 均 pending、attempts=0 |
| 拒绝测试结束后消息数 | 仍为 1 |

`/v1/me` 本次耗时约 1.67 秒，其余认证 HTTP 请求约 0.45–0.54 秒。这里只记录该次实际请求时长，不作为稳定延迟承诺。

## 最终数据库回查

- source：`stopped=false`，scope_epoch=3，version=3；经历 epoch 1 → stop epoch 2 → resume epoch 3。
- target：`stopped=false`，scope_epoch=1，version=1。
- target messages：1；child execution_actions：1。
- 原 source room 的融云 delivered Outbox：4 项，保留前一阶段结果。
- 新 target Outbox #5：room.created，pending，attempts=0。
- 新 target Outbox #6：message.created，pending，attempts=0，execution_run_id 绑定表中 child Run。

**不要为本次检查启动通用 transport-worker。** 新增目标群及消息明确留在本地，旧 child Run 已因继承 epoch 1 而过时。后续验收应按当前范围创建新的授权 Run，不能修改旧 Context 来删除来源，也不能把旧 Outbox 手工标成 delivered。

## 重启、凭据与命令

私有输入：`data/startup/api.env`、`clerk.env`、`clerk-worker.env`。CLI 只读取必要配置项，HTTP 使用 `RENJI_GATEWAY_TOKEN`，固定访问 `http://127.0.0.1:3318`，不跟随重定向、不回显 token/secret、不保存原始 HTTP body。receiver 配置由主任务启动的 API 加载，不由这个 probe 改动。

私有输出均被 Git 忽略、权限 0600：

- `data/startup/execution-gateway-fixture-v1.json`：固定动作、绑定、父子 Run、检查点。
- `data/startup/execution-gateway-readback-v1.json`：脱敏 HTTP 检查记录与当前 PG 回读。

从 `services/collaboration` 执行：

```sh
go run ./cmd/execution-probe -env-dir ../../data/startup -mode prepare
go run ./cmd/execution-probe -env-dir ../../data/startup -mode verify
go run ./cmd/execution-probe -env-dir ../../data/startup -mode inspect
```

已完成的检查点不会在重启后再次发送 HTTP；其原始验收时间保留。`inspect` 只读取数据库并刷新脱敏文件，不代表重新认证旧检查。若中途发生超时则停止，使用同一 manifest 和 action ID 核对持久回执后继续，不能删除 manifest 盲目重建主体、群或 Run。

## 自动验证与未覆盖项

最终 `go test -race ./cmd/execution-probe -count=1` 通过（约 1.63 秒）；测试覆盖固定 action ID、manifest 同 machine/DB 绑定、非合成来源拒绝、JSON 回执等价、检查点恢复不重发、脱敏错误码与重定向不传凭据。真实 HTTP 的 21 项结果另列于上表，未把单元测试当作真实供应商成功证据。

未覆盖：Clerk 真人管理员登录闭环、网页管理操作、Temporal/Eino 的真实模型多阶段执行、M2M JWT/API key、客户端即时接收、生产签名/部署。本轮服务端能力仍需与这些阶段逐项衔接。
