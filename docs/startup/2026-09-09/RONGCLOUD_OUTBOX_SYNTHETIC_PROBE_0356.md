# 融云 Outbox 真实合成联调工具与执行回执

- 记录时间：2026-09-09 03:56 +08:00；真实执行回执追加于 03:59 +08:00。
- 分支：`startup`。
- 基线：`acee8003c7c55694716778189179ec272da44347`，2026-09-09T01:22:28+08:00，`docs: close equal-rights stage and prepare major-version handoff`。新增 probe 当前未提交，此 SHA 不代表新增实现。
- 代码：`services/collaboration/cmd/transport-probe/main.go`、`main_test.go`。
- 未修改 Store、Outbox、路由和迁移源码；未重启 Electron/Vite，未操作真实飞书内容。

**本轮结果：真实融云 Server API 投递成功。** 独立合成群创建成功，人类管理员、人类员工、Agent 各一条消息均取得真实 `messageUID`；PostgreSQL 4 个 Outbox 项全部 delivered、attempts=1。重启同一 manifest 后没有新增外调。客户端实时接收尚未验收。

## 本轮范围

使用新 startup PostgreSQL 的 `renji_startup/public`，创建独立的 3 个合成 principal（人类管理员、人类员工、Agent）、1 个合成工作区、1 个合成群以及 3 条有限合成消息。业务资源经过 `Store.CreateWorkspace`、`CreateRoom`、`Send` 及 `DispatchOne`，不是直接向 provider 发消息后伪造本地状态。

融云 Server API 向群发消息本身不要求发送者是成员，所以本项目必须在 Go 动作准入与 Outbox 投递前自行校验当前权限。实际接口返回的 `messageUIDs` 用作传输回执，不取代 PostgreSQL 中的消息 ID 和序号。[融云群聊发送接口](https://docs.rongcloud.cn/platform-chat-api/message/send-group)

本轮只验收 **Server API 投递链**。不宣称 Web、Electron、Flutter 实时接收完成；`client_receive_verified` 始终为 false。

## 执行前置与当前状态

私有配置从被 Git 忽略的 `data/startup/api.env`、`rongcloud.env` 读取，不回显值、不导出 token，不把凭据放到命令行参数中。两份配置只在进程内使用。

第一次 prepare 已确认可以连接 `renji_startup/public`，但 public 尚未初始化，Outbox 查询收到 PostgreSQL `42P01`。程序立即停止；当时没有创建 public principal、群，也没有任何融云外调。Root 确认 `00003_execution.sql` 尚在并行开发，本轮等待其 schema 冻结后再执行迁移。

显式 `initialize-empty` 模式只在所有核心表与 `goose_db_version` 均不存在时调用现有 `Store.Migrate`。它不会给一个有数据或部分迁移的 public 做猜测性修补。Schema 冻结由主任务协调，不由 probe 修改迁移文件。

## 可恢复性和外调范围

`prepare` 先将本次 run ID、3 个 principal UUID、工作区/群/消息 action IDs、精确合成标题与内容写入 `0600` manifest 并 fsync。首次写入使用 O_EXCL，已有或损坏的 manifest 不会被盲目替换。后续业务对象持久成功即原子更新 manifest；进程重启用原 action ID 读取幂等回执。

私有文件：

| 文件 | 内容 |
| --- | --- |
| `data/startup/rongcloud-outbox-fixture-v1.json` | 固定 fixture、action IDs、业务资源和消息回执 |
| `data/startup/rongcloud-outbox-provider-observations-v1.jsonl` | 每次外调开始/结果；不含 client token 或 secret |
| `data/startup/rongcloud-outbox-readback-v1.json` | PostgreSQL Outbox 状态和 provider_receipt 回读 |

不要为了重新试验删除这些文件或 PostgreSQL 映射。外部资源可能已创建；清理本地对应关系会留下孤立群或造成重复消息。

每次 `DispatchOne` 前均确认不存在非 fixture pending/in_flight，存在任何 in_flight 也停止。本轮主任务确保 transport-worker 不运行且没有其他 public Outbox 写入；因为当前 Store 只提供全局 claim，这个独占前置是必要条件，probe 不是通用生产 worker。

额外的 Messenger 包装器只允许 manifest 中精确的 principal、群、成员集合、消息 ID、作者、正文、序号和时间。即使错误路由到包装器，也不能向非 fixture 资源发送。单次最多处理 4 个已知 Outbox 项，不做无范围 Drain。

每个外调前写入并 fsync `began`。重启发现已尝试过的操作，不论当时已成功还是结果未知，都不会重新调用 provider。成功以 provider 真实确认和 PostgreSQL 回执为准；超时/断网保留 unknown、停止，不能改回 pending。精确 provider code 和 unknown 标志保存在私有观察日志；原始错误 body 和 token 不输出。

## 手动命令

从 `execute/enterprise_work/active_agent/services/collaboration` 执行：

```sh
# 准备固定 fixture；没有外部创建/发送。
go run ./cmd/transport-probe -env-dir ../../data/startup -mode prepare

# 仅用于本轮确认过尚未初始化、且迁移源码已冻结的 startup public。
go run ./cmd/transport-probe -env-dir ../../data/startup -mode initialize-empty

# 使用既有 manifest 及 Store Outbox，向独立合成群投递最多 3 条消息。
go run ./cmd/transport-probe -env-dir ../../data/startup -mode execute

# 只读 PostgreSQL 并刷新脱敏回执文件，不发融云请求。
go run ./cmd/transport-probe -env-dir ../../data/startup -mode inspect
```

成功重跑 execute 会复用原 action 和 delivered 项，不产生新逻辑消息；unknown/rejected/in_flight 要人工依据证据核对，程序不提供自动重置重试选项。

## 自动验证

`go test -race ./cmd/transport-probe -count=1` 已通过；带 `RENJI_TEST_DATABASE_URL` 的真实 PostgreSQL 回归也已通过（独立 `probe_test_*` schema，测试完只清理该测试 schema，未触及 public）。覆盖：

- manifest 先持久、重启复用、损坏不覆盖、DB/provider binding 不符拒绝。
- 外调开始日志持久化后，未完成或已完成操作均不重发。
- 非 fixture 主体、群、成员、正文和作者在 provider 调用前拒绝。
- Store 事件 JSON 往返后，按相同时间点比较消息，避免 Go time.Location 差异误拒。
- provider 已知错误 code/unknown 状态不丢失、不记录 token。
- Store seed 重跑仍为 3 principals、1 room、3 messages、4 outbox；原 room/message ID 保持不变。
- 插入一项独立测试群 pending 后，准入检查阻止 Dispatch，原非 fixture 项仍是 pending/attempts=0。

以上回归使用本地可控测试替身验证范围与恢复行为，不是实际融云成功证据。真实 Server API 结果将单独追加。

## 真实执行回执（2026-09-09 03:56–03:57 +08:00）

主任务确认 `00003_execution.sql` schema 冻结后，按顺序执行 `initialize-empty` → 同一 manifest 的 `prepare` → `execute`。全程没有运行 transport-worker，public 无其他 pending/in_flight；只处理本次明确合成范围。

| 项目 | 实际值 |
| --- | --- |
| Run | `2164910f-f0be-4660-8297-e1d3db3a491a` |
| 工作区 | `736b5198-479b-4505-8dbb-8d54b0d5c697` |
| 群 | `63892e35-efbd-40cb-86e6-17c7cab37aa6` |
| 人类管理员 / workspace owner | `19519294-3539-479b-8615-a9ee68709c2d` |
| 人类员工 / member | `798eb3da-b217-4204-8baf-23ff2941a88c` |
| Agent / member | `b49d2ffc-946c-4061-a6ef-5ed7e4308465` |

这三个主体的显示名均包含“合成验收”和 run 短 ID。它们不绑定已有真实用户，也没有读写旧飞书或旧融云群。

7 次真实 provider 调用均已确认：3 次注册用户（返回 token 仅留进程内）、1 次群创建、3 次消息发布。外调观察日志共 14 行，每次有一个 fsync 的 began 和一个 acknowledged 结果。

| PG Outbox | 主体 / seq | 人机消息 ID | 融云 messageUID | 最终状态 |
| --- | --- | --- | --- | --- |
| 1 | 群创建 | — | provider code 200 | delivered，attempts=1 |
| 2 | 人类管理员 / 1 | `4987a67d-dde7-4e8e-a500-f737646284d5` | `D0GA-C5MO-RNME-75D4` | delivered，attempts=1 |
| 3 | 人类员工 / 2 | `4c80964f-87c7-4b1e-b161-f509afb81741` | `D0GA-C5N8-7PQE-75D4` | delivered，attempts=1 |
| 4 | Agent / 3 | `0ca89e75-71f5-43e2-a147-da8a9369a82d` | `D0GA-C5NL-UR8E-75D4` | delivered，attempts=1 |

首次全量回读时间：2026-09-09T03:56:58.126635+08:00。来源是 PostgreSQL `transport_outbox.provider_receipt`，不是仅凭客户端或本地 toast 判定。

03:57:47 +08:00 使用同一 manifest 重启执行，六项验证全部通过：

- run ID 相同。
- room ID 相同。
- 三个人机 message ID 相同。
- 三条 Store 消息回执均 `replayed=true`。
- 外调观察日志字节完全相同，新增外调为 0。
- PostgreSQL 仍是 4 项 delivered 且各 attempts=1。

重启回执：`data/startup/rongcloud-outbox-restart-verification-v1.json`。provider journal SHA-256：`a639c19552fad2ce55815e3bc44debde821f0c7c2c622149d7f8070bab05095e`。该指纹是脱敏调用日志完整性指纹，不是密钥指纹。

**完成边界：** Go 持久业务消息 → Outbox → 融云 Server API 的人/Agent 同群投递已真实验证。机器凭据→执行器→此合成 Agent 的绑定、Run/停止控制及三个客户端的实时接收是后续验收；本轮未宣称完成。03:57 后 probe 已释放 public 独占，不再写 public 或调用 provider，由主任务接续使用同一合成 Agent。
