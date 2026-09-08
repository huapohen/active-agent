# 自动归档边界独立复核

审读时间：2026-09-09，本次工作树。审读者未改 Go 源码，未执行模型、业务消息、真实 Doc Free 写入或 UI 操作。

## 结论

初审发现一项 P2，已交根任务和 harness：`Store.AppendExecutionEvent` 在 room stop 与 Terminal 之间竞态时将 `Run.status` 改成 `stopped`，但仍原样保存调用方 `run.failed` / `run.completed` 事件。原 `requireTerminal` 找不到 `run.stopped` 时返回 `archive_terminal_fact_missing`。随后已只读确认下面的最小修复，没有通过接受任意旧终态放宽校验。

除该项外，在本次限定范围内未发现新增 P1/P2：

- `internal/harness/workflow.go` 的 defer 先成功提交独立 Terminal Activity，之后才安排归档。Terminal 提交失败设置 `skipped/terminal_not_persisted`；不会调用归档。归档错误不回滚或重跑业务动作，归档 query 与业务状态分开。
- `internal/harness/archive.go` 的 `ArchiveInput` 仅 `run_id`；provider 凭据、目标、正文均留在部署插件。结果只含受限状态、ID、游标、错误码、次数。异常和 panic 转为固定错误，不把任意错误文本放入新增 Activity 的结果或 failure。
- 归档 Activity 最多三次；已知 ID 的 claim 冲突采用 125 秒重试间隔，超过数据库 2 分钟租期。最坏 3×2 分钟执行加 2×125 秒等待为 10 分 10 秒，位于 11 分钟 ScheduleToClose 范围内。重试只调用 Archive，不重跑 Plan、Action 或 Terminal。
- unknown 且无 external ID 在 Runner 中提前停止，不再 claim；插件不请求重试，Activity 再次强制禁止 Retryable。历史 in-flight 租期到期只转成 reconcile-only，不恢复 WriteAllowed；没有 ID 时停止，不重新 POST。
- `internal/store/execution_archive.go` 在调用外部创建前持久化单次 request marker；来源和 audience 锁在有界调用期内保留。已知 ID 后续只读验证，已有 verified 部分继续只读核对。旧 claim 不能写回新代次观测。
- `internal/runarchive/plugin.go` 读取真实持久证据页，固定证据 through 前缀，检查当前 Run 状态及准确对应 `run.<status>` 事件；单纯模型文字或 status 字段不能作为终态事实。当前机器身份和全来源权限每页检查。
- `cmd/worker/main.go` 由部署环境指定私有 archive 配置路径；先确认 gateway 机器绑定，再打开归档配置，最后创建模型/Temporal。无配置为 disabled，不创建另一套业务工作流。

## 独立运行的检查

执行：

```sh
go test -p 2 ./internal/harness \
  -run 'TestTemporalArchive|TestTemporalFailedAndCancelledBusinessStillExposeArchiveQuery|TestTemporalLegacyHistoryVersionDoesNotScheduleNewArchive|TestReplay.*Archive' \
  -count=1 -json
```

结果：10 个顶层测试、8 个子测试通过，0 失败、0 跳过。日志 `/tmp/renji-autoarchive-independent-review-20260909.log`。

这些是 Temporal SDK 测试环境/离线 replay，覆盖提交顺序、已知 ID 三次恢复及耗尽、125 秒租期间隔、未知无 ID 不重试、错误脱敏、终态提交失败跳过、失败/取消业务 query 和旧历史兼容；不是本审读者执行的真实 Temporal / PostgreSQL / Doc Free 联调。

真实 case2 `ArchiveWorkflow` 仅一次归档 Activity、原 `9d62380a` 复读 verified 的执行由根任务负责，需引用根任务自己的运行回执。

## 停止竞态修复复核

harness 经根任务批准修改 `requireTerminal`：仅当当前 Run 为 `stopped`，证据行自身的 `Kind == run.status`、`ObjectID == 当前 RunID` 且数据 `status == stopped` 时，使用该服务器事实确认终态。其他终态继续严格匹配原执行器事件。

本审读者检查了 `internal/store/migrations/00004_execution_archive.sql`：该 kind 由 `execution_status_archive` 的数据库触发器在实际状态更新时生成，object ID 来自 `NEW.id`，正文仅 old/new status。`ReadExecutionEvidence` 从 `execution_evidence_entries` 读取该独立 kind；模型事件中的同名 JSON 字段不会改变行本身的 kind。修复没有伪造或替换原失败/完成执行器事件。

已只读检查新增真实 PG 测试：failed/completed 两个 stop-before-Terminal 分支各保留一条原 event、一条服务器 stop fact，归档后 execution_events 仍只有原一条；模型伪造同名 kind/object/status 的路径拒绝并保持零目标 POST。harness 报告完整最终 race 60 顶层+59 子通过，日志 `/tmp/renji-autoarchive-stop-final-20260909.jsonl`。本审读者未重复整套 PG/race 测试，独立运行范围仍为上面的 10 顶层+8 子旧边界测试。
