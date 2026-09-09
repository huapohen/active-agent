# 接收桥独立只读审查

审查日期：2026-09-09，Asia/Shanghai。对象为当前尚未提交的 `transport_ingress`、00008 迁移、API/cmd 配置与商业前端 relay 契约。未修改实现、未发送外部消息、未启动桥或 Worker、未读取真实凭据。以下为源码可达路径分析，不冒称新增真实故障复现或已修复。

## P1：持久 SDK 日志未绑定接收身份，重绑目录可伪造另一主体的接收事实

位置：`services/rongcloud-bridge/main.cjs:27`、`:40`、`:51`、`:75`。

恢复 `queue.json` 只核对 room、消息白名单和 envelope 格式；`sdk-observations.jsonl` 保存 `{at,message}`，不保存 receiver 或固定部署绑定指纹。`projectMessage` 不含 receiver，因此旧日志的接收主体无法由正文重建。`state.json` 虽记录 receiver，但重启恢复路径不读取验证它。定时 `drain` 也不要求本次 SDK 连接完成身份验证。

可达场景：A 在群 R 收到真实 SDK 消息，留下 pending 队列或 journal；运维复用 state_dir，将配置改成同群成员 B，并配好 B 的可信桥密钥。旧消息通过 room/message 白名单，提交时被新桥绑定解释成 B 收到。Go 能验证原 UID、已 accepted Outbox、B 当前成员，却无法证明本次日志确实来自 B。结果是原来 A 的真实观察冒充 B 的接收事实。

建议：目录初始化时持久、原子写入 manifest，固定 bridge ID、receiver、room、provider app 身份、ingress endpoint 和版本；任何恢复前先精确验证。每条 observation/queue 标明同一不可变指纹。已有数据缺 manifest 时不可默认为当前身份，应保留原始数据并进入待审查；不能为通过校验批量补造历史 receiver。重绑采用新目录/唯一部署 ID。当前连接身份完成前不要把新的缓冲包交给 drain；历史对账仍须基于原始 manifest。

## P2：同 bridge ID 改绑后 heartbeat 更新零行却返回 accepted

位置：`services/collaboration/internal/store/transport_ingress.go:171`。

`ON CONFLICT(bridge_id) DO UPDATE ... WHERE old.receiver_id=new.receiver_id AND old.room_id=new.room_id` 在改绑时合法执行但更新零行。函数只检查 err，仍 Commit 成功，HTTP 回 `{accepted:true}`。查询正确过滤了原 tuple，因而旧心跳没有泄露；但新绑定不能插入也不能更新，接下来的每次心跳均虚报成功且新桥永久 unavailable。

建议：`RowsAffected()!=1` 返回可区分的冲突，要求新唯一 bridge ID；若必须支持同 ID 迁移，建立绑定 generation/复合键并保留旧事实，不直接覆盖旧身份。新增回归应在 rebound 后实际调用 heartbeat，断言不会返回无写入成功；当前测试仅覆盖 rebound 后读不到旧数据。

## P2：并发心跳可将旧 connected 覆盖新的 disconnected

位置：`services/rongcloud-bridge/main.cjs:52`、`:65`、`:79`；Store heartbeat UPSERT。

SDK 状态回调与 5 秒定时器可并发发 heartbeat，没有请求队列或序号。服务端按写入时刻覆盖当前状态。旧 connected 请求若较晚获得事务执行机会，就能在新 disconnected 已提交后再次写 connected。UI 随后在最长 30 秒有效期内显示桥已连接，虽然本地已断开。

建议：最小修正是在桥进程串行发送心跳、退出前等待最后 disconnected；跨重启也需严格保证时，加入不可变 generation 和单调 seq，服务端拒绝旧版本。此问题只影响连接状态事实，不会把 heartbeat 本身生成消息接收记录。

## 已确认的边界

- 内部入口使用固定配置的 bridge 绑定，要求 loopback、拒绝 Origin、恒定时间验证密钥；商业 renderer 不获取 SDK token。
- canonical 指针与权威事件、作者、会话、seq/version、正文 SHA、已 delivered 的 RongCloud receipt 和精确 UID 匹配。pending/in_flight/unknown 不产生已收记录。
- 接收 Agent 动作时复用 `executionDeliveryAdmission`，检查服务端持久 Run 的所有原始来源、当前策略、成员和代次；不信 envelope 自报 scope。
- Human 在 Agent 停止期间仍可提交/观察自己被接受的沟通；普通 Human 历史通知读取不等于重新授权 Agent 执行。
- Machine `/v1/transport/events` 直接拒绝并明确尚需 Run 原生接收契约；本轮没有借普通主体读取绕开全部来源检查。
- 接收 inbox 按 receiver+UID、receiver+event 去重；当前配置覆盖、当前成员和禁用状态限制导出。改房间后的旧 tuple 状态不会被误读为新房间（上述零行 success 是另一个问题）。
- 前端仅轮询合法 Go 通知，严格校验 schema/cursor/类型，换账号会 abort 并丢弃迟到响应；`connected` 与 `last_received_at` 分开。
- 本轮未确认新的确定性死锁。接收事务会在 outbox share lock 后持 Run/来源授权锁；已有 profile 反向锁序使用有界确认回滚重试。审查不等于已通过新的真实 PG 接收前后并发命中测试，现有 ingress 用例主要是顺序验收。

## 建议阶段验收口径

当前可证明的范围是可信合成桥的实际 SDK 观察→严格 canonical 校验→持久 inbox→当前主体查询。待以上问题修正或明确隔离约束前，不应宣称“任意桥重启/改绑后的接收事实不会串身份”。真实一次收包的原始日志应保持原样；不能用重新写入的 manifest 替代当时未记录的历史接收身份。

## 09:20 修复复核追加

原发现保留，以下描述后续修复，不覆盖发现时的事实。

1. P1 已通过源码复核与独立 Node 回归：新增 `state.cjs` 在任何 queue/journal 读取前验证不可变 manifest（bridge、receiver、room、app key 的 hash、endpoint、SDK mode、消息白名单）。目录非空且无 manifest 时直接拒绝；queue/journal 新写与恢复逐条要求同一指纹。`drain` 必须等待 SDK 身份验证。实现者保留旧真实状态目录，不给旧 journal 补身份；改用相同明确绑定的新空目录继续验收。
2. 零行 heartbeat P2 已在源码中关闭：`RowsAffected()!=1` 返回 `domain.ErrConflict`；rebound 测试新增真实 Store 调用并断言冲突。此审查者没有重复运行 PG；真实 PG 回归证据由实现者与根任务提供。
3. 独立执行 `node --test services/rongcloud-bridge/security.test.cjs services/rongcloud-bridge/state.test.cjs`：6/6 通过，0 fail/skip，仅本机临时目录，不访问提供商。
4. 此次读取的 `main.cjs` 仍未序列化 heartbeat；并发状态倒序 P2 保留开放，等待根任务决定及实现者修正。

## 09:35 最终心跳修复复核

后续 `heartbeat.cjs`、00009、HTTP 和 Store 已完成以下修正：

- 每次发送前 fsync 写入 scope 指纹绑定的递增序号，取上次序号加一和当前毫秒时间乘 1000 的较大值；同目录重启和时钟回退不复用序号。
- 心跳在进程内串行发送，发送失败后仍可发送后续状态。退出同步排入最后的 disconnected 后设置 closing，阻止新状态与定时器再排队，并等待最终心跳结束。
- HTTP/Store 要求正且不超过 JavaScript safe integer 上界的 sequence。数据库同一 bridge/receiver/room 仅接受更大的序号；迟到 connected、重复序号、身份重绑均拒绝，零行不再回成功。
- 新增迁移 `00009_transport_heartbeat_sequence.sql`，没有改写已应用 00008。

独立 Node 验证：`node --test services/rongcloud-bridge/security.test.cjs services/rongcloud-bridge/state.test.cjs services/rongcloud-bridge/heartbeat.test.cjs`，8/8 通过，0 fail/skip。涵盖身份目录、遗留日志拒绝、心跳失败后的串行、重启与时钟回退。

独立真实 PostgreSQL race 验证：`go test -p 2 -race -count=1 -json -run 'TestTransportIngress|TestTrustedBridge' ./internal/store ./internal/httpapi`，6 个顶层 + 2 个子测试通过，0 fail/skip。所有数据库变化限定 fixture 的独立临时 schema；没有 public 迁移或外部消息。日志 `/tmp/renji-transport-ingress-independent-final-20260909.log`，SHA-256 `ca746e88c10490b9f56fc016ae458818450452b06ecd0db1699f140930daf23b`。

本次审查发现的 1 个 P1 与 2 个 P2 均已关闭，未发现新增确定 P1/P2。早期发现和中间开放状态仍保留作追溯；本文不扩大到“所有接收协议和生产机器推送均完成”，也不把本机 fake provider receipt 夹具当真实提供商收包证据。实际单条 SDK 收包由原始联调记录另证。
