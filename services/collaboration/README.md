# 人机商业版协作内核

`startup` 分支使用 Go/Gin、PostgreSQL/pgx/sqlc/goose、Clerk 和**必选的融云**。Temporal 管理持久执行流程；Eino DeepAgents 管理有界规划，业务动作仍由协作内核授权和提交。当前是可执行的迁移阶段，不能当作完整商业发布。

阶段验收入口：[首次实现与测试交付](../../docs/startup/2026-09-09/STARTUP_FOUNDATION_DELIVERY_0424.md)、[手动启动教程](../../docs/startup/2026-09-09/MANUAL_STARTUP_GUIDE.md)、[首次发布与格式差异](../../docs/startup/2026-09-09/STARTUP_FOUNDATION_PUBLICATION_RECEIPT_0443.md)、[文档正文阅读器](../../docs/startup/2026-09-09/CLOUD_DOCUMENT_READER_0510.md)。首次发布的未知回执保留。Docmost 已追加原生结构验证；AFFiNE 在原文档、原四个表格块 ID 上修复表头和单元格代码格式，随后回读完整结构。Markdown 字节一致与原生结构一致分开记录；浏览器视觉、通用原生增量写入仍需继续验收。

## 启动本机服务

在项目根目录打开终端。现有本机配置保存在 Git 忽略的 `data/startup`，这些文件中的凭据不复制到教程、聊天记录或提交。首次部署参考本目录 `.env.example`，将真实值放入部署环境的私密配置。

终端 1：Go 服务，默认 `127.0.0.1:3318`。当前机器已有独立 PostgreSQL 容器 `renji-startup-postgres`，端口 55434；先确认 Docker 和该容器正在运行。

```sh
cd /Users/lwblx/huapohen/agent/execute/enterprise_work/active_agent
set -a
source data/startup/api.env
source data/startup/clerk.env
source data/startup/rongcloud.env
source data/startup/clerk-machine.env
set +a
cd services/collaboration
go run ./cmd/api
```

新数据库首次部署或升级到含新迁移的版本时，使用 `go run ./cmd/api --migrate` 应用尚未执行的版本化迁移。正常重启无需重新初始化。不要重新运行文档实例 setup 或合成数据 provision。

终端 2：Web 热更新。

```sh
cd /Users/lwblx/huapohen/agent/execute/enterprise_work/active_agent
npm run dev:web
```

终端 3：Electron 电脑端。

```sh
cd /Users/lwblx/huapohen/agent/execute/enterprise_work/active_agent
npm run dev:desktop
```

Web 默认 `http://127.0.0.1:5173`。商业工作空间使用 Clerk；现有数据迁移入口使用原 3218 服务，两套身份不混用。原服务启动命令：

```sh
python3 scripts/dev_office.py --doc-free ../doc_free --no-worker
```

手机仍使用 `apps/office` 的 Flutter 客户端。先启动原服务，再打开一个已存在的模拟器，在 `apps/office` 执行 `flutter devices` 确认设备 ID，然后运行 `flutter run -d <实际设备ID> --no-pub`。终端中的 `r` 是热重载，`R` 是热重启。手机迁移到新 Go/Clerk/融云内核尚未完成，不能把原手机登录成功算作新商业栈验收。只保留一个主模拟器，优先用 Web 窗口和独立身份模拟多人。

不要在已有服务监听同一端口时启动第二份。关闭开发终端会终止其子进程；当前没有安装开机自启服务。桌面启动、主进程热更新与 SDK 约束见 [桌面说明](../../apps/desktop/README.md)。

## 数据与授权契约

- 人和 Agent 使用稳定 `principal_id`。Clerk 人类会话映射使用 `(issuer, subject)`；机器 token 先验证接收方范围，再由服务端 executor 绑定解析 Agent，客户端不能自报 Agent 身份。
- 工作区、群、消息和动作回执以 PostgreSQL 为业务事实来源。正式消息、序号、动作记录、事件和融云 Outbox 在同一个事务内提交。融云是必须接入的传输适配器，未配置就不能启动 API。
- `action_id` 在主体范围内持久去重。更换动作类型、对象、内容或停止版本不能复用同一 ID。回放仍检查当前主体、成员或管理角色；响应丢失不会重复建群或再次推进停止代次。
- Agent 执行使用已登记的 Run。子 Run 从服务器读取父 Run 的全部来源范围；检查、消息提交及延迟外发都服从来源群停止代次、当前成员关系、人格策略和 executor 版本。
- 人格主动开关不等于对象超管权限。主体、执行器、工作区和 Run 分别记录；管理员登记 executor 不赋予另一个工作区的数据权限。
- 停止后保留可审计的已接受结果；未知外部结果需要对账，不能自动当作失败重发。真实接收回执也不回写成模型自行宣称的“成功”。

## Agent 原生入口

`GET /v1/capabilities` 返回实际实现的协议覆盖和机器使用条件，不返回计划中的能力作为已实现功能。

| 入口 | 当前职责 |
| --- | --- |
| `/v1/me`、`/v1/rooms`、群消息读取 | 当前身份与授权数据；支持分页 |
| `/v1/workspaces`、`/v1/rooms`、群执行策略 | 有幂等回执的业务操作；机器版本尚未全部接入动作网关 |
| `/v1/executors`、`/v1/agents/execution-policy` | 工作区管理员登记机器绑定、配置主动人格 |
| `/v1/runs`、`/v1/runs/:id` | 创建和读取持久 Run；不会仅因创建而声称模型已经执行 |
| `/v1/runs/:id/evidence`、MCP `run_evidence` | 按共享序号分页读取真实事件、动作、传输状态和 Run 状态；audit 模式保留终态核查，execution 模式拒绝停止或过期的执行范围 |
| `/v1/mcp` | MCP 2025-11-25，提供当前身份、房间、消息及 Run 工具，和 REST 共用业务处理器 |
| `/internal/harness/{binding,check,actions,events}` | 真实机器绑定、动态检查、动作提交和有界过程证据 |

机器消息要求 `run_id` 与 64 位十六进制稳定动作 ID；没有 Run 的机器消息写入被拒绝。机器工具列表明确剔除尚未注册动作实现的管理工具。A2A、全部办公模块动作与外设协议仍在建设，不把任意模型文本输出当作协议能力。

普通融云 SDK token 可以直接调用供应商写接口，单靠前端不调用发送无法构成服务端约束。目前仅允许显式列入 `RENJI_RONGCLOUD_TEST_PRINCIPALS` 的隔离测试主体申请客户端 token；默认不面向一般账号发放。此门槛不关闭服务端融云 Outbox，也不把融云降为可选。正式开通前仍需验证供应商禁言、托管群、撤回、其他会话类型及原始 SDK 对抗行为。

## 持久执行与文档核验

`cmd/worker` 使用 `.env.example` 中的独立 worker 配置。`RENJI_MODEL_API_STYLE=responses` 明确选择 Responses；空值或 `chat_completions` 选择原协议，未知值拒绝启动。不会因请求失败切换模型、端点或协议。Eino 在规划期间可通过已绑定 Run 读取当前房间和消息，每页都检查来源权限和停止状态；终态由单独 Temporal Activity 持久写回，重试终态记录不会再次执行业务动作。

本机已运行使用 SQLite 历史的 Temporal 开发服务，并验证失败流程的 19 个历史事件经过实际服务重启后保持一致。配置的模型端点本轮网络超时，因此尚未证明成功的自主多阶段执行、持久等待后的模型续行或已提交动作之后的 worker 恢复。不能用失败历史恢复代替这些验收。

`cmd/document-sync` 默认仍严格比较正文与标题。原生结构对账必须显式指定 `-binding` 和已支持的 `-native-profile`；AFFiNE 还需要 `-native-codec` 的绝对目录和 `-native-node` 的绝对可执行路径。独立 codec 使用自身锁文件安装依赖，子进程不继承父服务凭据。`native_verified` 是单独状态，保留 Markdown 导出差异；旧有未知记录不删除。已原生验证的 AFFiNE 数据库文档遇到新的源版本会要求原生写入方案，不能自动交给旧 Markdown writer 损坏表格。

## 验证与证据

本目录测试使用 `RENJI_TEST_DATABASE_URL`，为每次测试创建独立 schema 并清理，只在明确指定本机测试数据库时运行 PostgreSQL 用例；缺配置时出现 skip 不算集成验收。

```sh
go test -race -p 2 ./...
go vet ./...
go build ./...
```

真实验证工具不会默认批量创建数据：

- `cmd/auth-probe`：在线验证已配置的 Clerk 机器 token，仅输出身份与期限，不输出凭据。
- `cmd/transport-probe`：显式合成 fixture、持久意图与逐次外部观察，未知结果不重试。已有 fixture 必须复用，不能删除映射后重建。
- `cmd/document-sync`：对已授权的 Doc Free 源文档建立 AFFiNE/Docmost 投影并读回正文和标题；具体配置见阶段文档。
- `cmd/run-archive --config /absolute/private/config.json --run <Run ID>`：从持久证据生成 doc_free 档案并校验实际正文、标题与受众；当前仅允许显式单来源合成配置，未知创建不重建。配置与边界见 [归档适配说明](../../docs/startup/2026-09-09/RUN_ARCHIVE_DOC_FREE_ADAPTER_0549.md)。此命令尚未接入持续自动调度。

详细结果见 [融云真实回执](../../docs/startup/2026-09-09/RONGCLOUD_OUTBOX_SYNTHETIC_PROBE_0356.md)、[文档双端同步](../../docs/startup/2026-09-09/DOCUMENT_SYNC_FOUNDATION.md)、[机器认证](../../docs/startup/2026-09-09/CLERK_MACHINE_AUTH_ADAPTER_0343.md)。

## 本阶段没有完成的商业要求

Clerk 真人在所有端的登录/刷新、融云客户端接收与断线恢复、Flutter 迁移、完整飞书页面、生产签名与更新、A2A、全量办公插件、外设接入、真实模型成功多阶段执行、自主执行的持续调度和文档自动归档，均需继续实现和验收。Doc Free → AFFiNE/Docmost 已有真实合成验证，但旧 Docmost 3020 尚未迁移，生产目标权限撤回和全部复杂文档格式保真也未完成。

Clerk 是首轮认证方案；Logto + OpenFGA 完整保留为第二方案，本阶段没有部署第二套身份系统。国内优先，海外和鸿蒙不在当前实施范围。
