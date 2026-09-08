# Run archive 独立只读审查

2026-09-09，`startup` 工作区未提交实现。审查范围：`internal/runarchive/{config,runner}.go`、`cmd/run-archive/main.go`、`internal/store/execution_archive{,_audience}.go`、迁移 `00004/00005`，并追踪 `evidenceAccess`、执行器绑定及既有 Store 回归。没有启动 archive 命令，没有真实 Doc Free 写入，没有改实现。

截至本轮静态审查，未发现新增 P1/P2。

## 已核实的边界

- **入口与身份**：私有配置文件必须为普通文件且无 group/other 权限，严格 schema/mode/字段；目标来自部署配置，CLI 只有配置路径与 Run ID。Clerk 返回 issuer、receiver audience、subject 和有效期，不接受客户端 principal 自报。首次读取后再比 Run 的 executor/Agent principal，与 Doc Free Agent writer 的固定映射一致。执行器注册代码禁止同一机器重新绑定不同 principal/workspace。
- **目的地**：binding 指纹包含 endpoint、目标房间、身份映射和审批说明；数据库已存在同 ID 指纹不同即拒绝。Doc Free 请求不跟随重定向，错误回包与凭据不进入 CLI 输出。
- **来源范围**：每个外部请求前重新认证机器；Run 与所有映射受众在 Go 数据库中的当前来源权限锁保持到有界回调结束。单来源限制是实际代码条件，含任何 OriginScopes 的 Run 不进入此 runner。audit 可以读取停止后的证据，和继续执行动作的权限不同。
- **单次创建**：prepare 冻结证据前缀及分片，claim 将 prepared 转 in_flight；`request_started_at` 在网络前独立事务提交。同一 claim 重进、并发、租约过期均不能再次进入首次创建回调。
- **未知结果**：没有外部 ID 的 unknown 只能保持未知；有 ID 的重跑仅 GET 核对。未解决的旧归档优先返回，不能靠推进游标绕过它。旧租约 token 的迟到回执被新 claim 隔离；当前持有者可记录实际在途结果，记录本身不授权再次写入。
- **验证**：create 只提取真实 ID，随后独立合法 GET，验证 exact content hash 和标题 hash；全部分片 verified 后才推进归档游标。返回的 Archive 摘要不包含正文，claim token 不可 JSON 导出。

## 仍须如实描述

Doc Free 房间成员清单在 preflight 时读取，创建接口没有跨服务 ACL CAS 或成员版本锁。Go 的来源权限锁不能原子锁定目标系统的成员变化。因此这次 adapter 只用于 `single_source_synthetic` 的固定合成验收，不能声称已解决生产动态受众与来源交集的原子权限闭环。

已发起的请求即便随后撤权，也可以将它实际返回的 ID/回读事实记入账本；这不是继续对外执行的许可。外部系统不提供可确认 ID 时，保守保留 unknown，可能需要人工核对，不能自动清账重建。

## 验证状态

冻结后独立执行：

```sh
go test -p 2 ./internal/runarchive ./cmd/run-archive -count=1 -json
```

结果：**13 个顶层测试 + 14 个子测试通过，0 失败、0 跳过，两个包全部通过**。数据库连接通过 Python shlex 读取已忽略的 `data/startup/api.env`，仅放入子进程 `RENJI_TEST_DATABASE_URL`，没有打印凭据。测试创建独立 `archive_UUID` schema 并清理；Doc Free 由 httptest 代替，没有调用真实文档服务。

独立日志：`/tmp/renji-runarchive-independent-final-20260909.log`，保留 Go JSON 测试事件，可核对运行和跳过状态。测试覆盖私有配置与 CLI、身份及映射、受众、source scope、精确回读、配置漂移、丢响应/错正文/错标题/伪造 hash、并发单次创建、来源权限锁及重定向。

最后两处收尾实现也已只读复核：unknown 且无外部 ID 时直接返回，不为已知无可读 ID 的结果抢新租约；错误退出先清空旧的 Archive 快照，重新认证并读取持久状态，认证过期或撤权时仅保留已知 Archive/Run ID。未发现新增 P1/P2。

本子任务没有执行真实 archive CLI，没有归档外部文档，没有修改 runarchive 实现。
