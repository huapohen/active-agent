# startup 文档网关与双下游同步：实现、运行证据和边界

记录时间：2026-09-09 03:47，Asia/Shanghai。本文对应 startup 首轮基础建设；不是商业上线或全量文档迁移验收。

## 1. 基线与本轮授权

| 仓库 | 审计时分支/提交 | 提交时间 | 描述 |
| --- | --- | --- | --- |
| Active Agent | `startup`，`acee8003c7c55694716778189179ec272da44347` | 2026-09-09T01:22:28+08:00 | docs: close equal-rights stage and prepare major-version handoff |
| Doc Free | `equal_rights`，`dc728ddc99ce3bc7346bb4dc364824bbb32b1101` | 2026-09-09T01:22:28+08:00 | docs: preserve stage baseline for major-version branch |

本轮新增实现截至本文写入时尚未提交；以上 SHA 仅为已提交基线。最终提交号由 startup 阶段交付记录补充，不将基线冒充实现提交。

依据用户的《人机：从 Google 分享方案到主动式 Agent 原生协作平台》蓝图，第 6、7、8、15.5、16.1 节要求：正式正文由 Doc Free 管理，网关负责稳定资源映射、权限、版本、同步回执和归档关联；AFFiNE、Docmost 不成为第二个可独立写入的正文主源。蓝图中的“当时只给方案”是历史任务范围，本轮用户已明确授权 startup 实施和同步接入。

本轮只在 Active Agent 新增 Go 模块，未编辑 Doc Free 源码或 CRDT 内核。运行验收使用既有 Doc Free 成员 API、新合成群和新合成文档，没有调用模型。

## 2. 发现的真实缺口

| 核查项目 | 当前事实 | 对实现的影响 |
| --- | --- | --- |
| 原生办公文档同步 | 办公 `documents.json` 原有 26 篇没有 AFFiNE/Docmost 外部映射 | 不能把旧 README 的集成说明当作当前办公文档已同步 |
| 旧管理入口 | `server.js` 的自然语言文档更新和块更新会调用 `syncAgentDocument`；原生成员文档 POST/PUT/CRDT 保存不调用它 | 新建独立投影 Worker，保持正文单主 |
| AFFiNE 运行态 | 3010 在线；当前 workspace MCP token 的 tools/list/read 可用 | 真实 HTTP 适配器可用，不能只做假接口 |
| AFFiNE 写能力 | 当前容器源码仅在 `READ_WRITE` 且 dev/canary 时暴露写工具；部署为 `AFFINE_ENV=dev` | 当前读写验证属于开发环境，生产写接口/版本兼容仍要落实 |
| AFFiNE 标题 | MCP `read_document` 仅返回正文；正文和标题分别写入 | 增加可选 GraphQL 元数据读取器；无此读取器时仅 `partial_verification` |
| AFFiNE 空 workspace | GraphQL `createWorkspace` 不初始化根协作文档；MCP 创建会先拒绝无根 workspace | 部署必须初始化 workspace。不能把未初始化失败当成创建成功 |
| 原 Docmost 运行态 | 3020 页面在线；旧 cookie 调 pages/info 为 401；按用户授权资料尝试登录同样 401。只读核对确认其 7 个用户中有 1 个匹配授权邮箱 | 保留旧账号、密码和全部数据；没有绕过认证或重置密码，不宣称恢复原实例登录 |
| 新 Docmost 运行态 | 经授权启动独立 3021 实例，官方 setup 注册、创建专用 space，两篇新合成文档真实创建、更新、正文/标题读回和重复执行通过 | 双下游同步获得运行证据；新实例不等于旧 3020 已迁移 |
| 目标 ACL | 旧实现使用固定 AFFiNE workspace 和 Docmost 第一个数据库 space；没有人机群权限映射 | 新配置要求明确 namespace、审批来源、单主写入控制，拒绝自动选第一个空间 |
| 跨平台事务 | 两家当前写 API 都未提供本适配器可使用的版本 CAS/原生幂等创建键 | 写前读后校验、保存未知状态；不能声称跨系统原子提交 |

运行态接口、参数、写入限制以当前容器源码和实际 HTTP 回包核对，未使用猜测出来的供应商 API。

## 3. 新代码与职责

代码位于 `services/collaboration`，Go module 为 `github.com/huapohen/active-agent/services/collaboration`。本模块只使用 Go 标准库。

| 文件 | 职责 |
| --- | --- |
| `internal/documents/projection.go` | Source/Target/Store/Guard 接口、审批映射、同步状态机、源版本检查、冲突和未知结果处理 |
| `internal/documents/http.go` | Doc Free 成员读取、AFFiNE MCP 与可选 GraphQL 元数据、Docmost pages API；禁止跳转携带凭据到另一地址 |
| `internal/documents/journal.go` | 私有 JSONL 回执、先落盘后外部请求、fsync、哈希链、串行化、损坏日志拒绝继续 |
| `internal/documents/journal_unix.go` | macOS/Linux 等平台的进程级文件锁；进程退出后由操作系统释放锁 |
| `internal/documents/journal_other.go` | 未实现相同锁语义的平台拒绝文件存储，要求接入事务 Store；不伪装跨平台可靠锁 |
| `cmd/document-sync/main.go` | 一次同步命令；每个 effect 前重读审批配置；不扫描/导出所有群 |

正式 PG Outbox/目录/权限服务可以实现同一接口接入。当前文件 journal 是本地可验证实现，不是已建成 PG Worker、Temporal 持久任务或百万文档目录的证明。正文没有另存成独立可编辑副本；回执只记录标识、版本、指纹、状态和错误码。

## 4. 操作链路和可恢复边界

1. 配置指定 source principal、room、document，以及单一目标 endpoint/namespace。
2. 验证服务端受控配置中的 enabled、审批主体、审批依据、generation 和 gateway-only namespace 声明。此配置是部署人员的受控输入，不接受普通客户端提交。
3. 用该成员的独立凭据读取 `/api/im/me`，核对 principal；再读取其群文档，核验 source revision 和 SHA-256。
4. 已有映射先读下游，与上次确认的内容和可读标题指纹比较。发现外部改动则进入 conflict，不覆盖对方编辑。
5. 在写入前 fsync `prepared` 意图。每次外部效果前重读源文档和当前配置，拒绝已撤权、停止/配置变化或源版本变化。
6. 创建返回的外部 ID 先作为 submitted 回执落盘；随后实际读回验证。AFFiNE 分别写正文、标题，两次调用之间也重新检查源权限和版本。
7. 超时/失联/未知创建不会被当作“没有执行”。无 ID 的 unknown 创建禁止自动重试；有 ID 的未知写只允许读后对账，不自动重发旧正文。
8. 目标正文仅规范化 CRLF 和结尾换行；不忽略内部空白、段落顺序或内容差异。标题单独核验。

| 状态 | 精确含义 |
| --- | --- |
| `prepared` | 意图已经持久化，外部效果尚未有完成证据 |
| `not_sent` | 写前的最后检查失败，已证明本次没有发出目标请求，可重新检查后尝试 |
| `submitted` | 目标返回了可保存的 ID/写回执，尚未完成内容读回 |
| `verified` | 本次目标 ID、正文、标题均由读取接口核验；仍是该源版本的投影回执 |
| `partial_verification` | 正文已验证，但没有可靠标题读取通道；不是“全部同步完成” |
| `unknown` | 请求/结果或读回仍不确定；可能是下游滞后、部分成功或冲突，保留意图等待对账 |
| `conflict` | 写入前发现目标偏离上次已确认投影；需要明确处理冲突 |

命令对 partial/unknown/conflict 或错误返回非零退出码。AF​​FiNE 补充元数据读取后，可以将已存在的 partial 回执经读取升级为 verified，过程中不重写正文或标题。

### AFFiNE 的 H1 保真

当前 create 工具会移除请求正文开头的一个 H1。同步器在传输层为这种正文加一个空行，Markdown 解析器消除此传输空行而保留真正正文中的 H1。Doc Free 原文不变，最终仍按原文指纹读取核验。此行为已在实际 AFFiNE 创建和更新路径验证，不只依赖 mock。

复杂数据库块、图片、附件及非无损 Markdown 表达尚未完成保真矩阵。任何读回差异都不会被标记成功。

## 5. 权限、撤权和归档必须如实说明

- 当前 Source 复用 Doc Free 的真实成员、群范围和 docs app 检查。人和 Agent 均可作为独立成员，不借用管理员身份读取源文档。
- 新 `Guard` 是可替换接口；当前 CLI 的 Guard 重读受控配置。它还没有接入 Clerk 新身份映射、人机多维策略、委派链和群停止代次，不能把此 CLI 当作最终权限服务。
- `gateway_only_namespace` 是必须由部署证明的控制条件。当前合成 workspace 在验收期间只有本任务写入；这不是生产网络隔离或供应商侧只读授权已经完成的证据。
- 外部平台没有版本 CAS。因此写前检查与真正写入之间存在竞态；生产需要封闭目标独立编辑/公开访问入口或由具备强一致条件写的适配器替换。
- AFFiNE 配置元数据读取时同时要求返回的 ID/namespace 精确匹配且 `public=false`。未配置时无法证明该下游页面的公开属性，只能保留 partial 状态。
- 撤销 source 成员权限或撤销配置后，后续请求被拒绝。已经发出的外部请求仍可能完成，记录为在途/unknown。平台不支持取消正在提交的写入时，不能承诺瞬时撤回外部效果。
- 撤权后删除/取消分享既有 AFFiNE/Docmost 副本，以及所有 WebSocket、搜索、缓存和旧编辑入口的实时撤权，仍未闭环。
- 群归档不会由此模块级联删除下游文档或回执。独立长期原始档案、密级/标签交集、保留与删除政策仍需平台层实现；哈希 journal 不能代替完整执行档案。
- 现有 Doc Free 管理 API 与协作直达入口仍需部署网关封闭；本轮没有改动该服务的权限内核。

## 6. 配置与运行

配置、源 token、目标 token/cookie、journal 均放 Git 忽略的私有目录，文件权限为 `0600`。源凭据文件可为原始 token，或 `{"token":"<secret>"}`。AFFiNE MCP 凭据也可读取现有 integration-auth JSON 格式。Docmost 可读取含 authToken 的 Netscape cookie 文件。AFFiNE 可选元数据文件保存专用元数据会话 cookie，不把它发送给 MCP 写接口。

以下仅为停用的模板；真实 namespace、审批和隔离验证后再启用。

```json
{
  "journal": "/absolute/private/document-projections.jsonl",
  "bindings": [
    {
      "id": "document-to-affine",
      "principal_id": "principal-source-member",
      "source_endpoint": "http://127.0.0.1:3218",
      "room_id": "room-explicit-source",
      "document_id": "explicit-source-document",
      "target": "affine",
      "target_endpoint": "http://127.0.0.1:3010",
      "namespace_id": "explicit-approved-workspace",
      "approved_by": "principal-administrator",
      "approval_reference": "deployment approval reference",
      "generation": 1,
      "enabled": false,
      "gateway_only_namespace": false,
      "source_credential_file": "/absolute/private/member-token.json",
      "target_credential_file": "/absolute/private/affine-token.json",
      "target_metadata_credential_file": "/absolute/private/affine-metadata-cookie.json"
    }
  ]
}
```

Docmost 使用独立 binding，`target=docmost`、明确 `namespace_id=spaceId`，并配置自己的 credential 文件。它没有 AFFiNE 专用的 target_metadata_credential_file 字段。两个下游使用不同回执和状态，不能把一边成功汇总成双边成功。

从仓库根目录执行：

```sh
go -C services/collaboration run ./cmd/document-sync -config /absolute/private/config.json
```

该命令只运行一轮，不安装后台常驻任务。非 loopback 连接必须使用 HTTPS；不会跟随重定向传送凭据。输出和 journal 不包含正文、Cookie、Authorization 或供应商原始错误内容。

现有 Doc Free 开发服务的启动方式保持：

```sh
python3 scripts/dev_office.py --doc-free ../doc_free --no-worker
```

本轮启动前确认 3218/1238 无监听，当前启动会话为 `31482`，服务 Node PID 为 `53740`，日志 `/tmp/renji-startup-document-sync-office.log`。不因已有会话输出观察超时而重复启动服务。Agent Worker 未启动。

### 新 Docmost 本地隔离实例

旧 3020 的授权邮箱存在，但已有合法凭据无法登录。经授权，在保留原实例的同时复用本机缓存镜像建立新实例，未拉取大镜像或注册付费服务。

| 项目 | 本轮运行值 |
| --- | --- |
| 容器 / 地址 | `renji-startup-docmost` / `http://127.0.0.1:3021` |
| 镜像 | `sha256:41c8d777cf23c74e78f94e676aec328b7d7856f48df5e573543dac68d371e37c` |
| 资源上限 | 512 MiB 内存、1 CPU；验证时 Running=true、OOMKilled=false |
| PostgreSQL | 复用已有服务，仅新增数据库 `renji_startup_docmost`；旧 `docmost` 数据库保留 |
| Redis | 复用已有服务，仅使用启动前未占用的 DB 14 |
| 存储卷 | `renji_startup_docmost_storage` |
| 网络 / 重启策略 | `doc_free_docmost` / restart=no；只映射 loopback 地址 |
| 注册与凭据 | 官方 `/api/auth/setup` 使用已授权资料；会话及本地配置保存在 Git 忽略、0600 文件中 |

当前本地私有文件位于 `data/startup/docmost/` 与 `data/startup/document-sync/`。不要输出、复制进报告或提交其中的账号密码、Cookie、token、APP_SECRET、数据库连接串。合成映射配置已固定四个 source→target binding，可执行：

```sh
go -C services/collaboration run ./cmd/document-sync -config "$PWD/data/startup/document-sync/config.json"
```

实例重启可使用 `docker start renji-startup-docmost`；需要先保持既有 Docmost PostgreSQL/Redis 容器运行。不要重新执行本轮一次性 provision/setup 脚本，也不要将新实例当作原实例的迁移结果。

## 7. 当前真实验收结果

### 自动化

执行 `go test -race ./internal/documents ./cmd/document-sync`，覆盖 23 个顶层测试、30 个含子测试的案例；另执行对应 `go vet`。测试覆盖实际 httptest HTTP 协议交互，不只比较构造出的请求对象：

- 创建后真实读取、同源版本重复调用、更新到同一个目标 ID。
- 创建响应未知后重开 journal，不重复创建；已知 ID 未知写经读回恢复，不重发写操作。
- 下游编辑冲突、源权限撤销、错误 principal/namespace、审批在请求前变化。
- AFFiNE 分离的正文/标题调用之间撤权；无元数据时 partial，配置有效元数据后只读升级 verified；公开页面或错误 namespace 拒绝。
- H1 保真传输、正文内部空白不被误归一化、源 hash 错误拒绝。
- 凭据不随跳转、供应商错误正文不进入 journal、私有文件权限、损坏/截断 journal、独占锁和并发 Engine 去重。

测试日志：`/tmp/renji-startup-document-gateway-tests-final.jsonl`。测试数是当前模块范围，不等于整个平台商业验收数。

### 真正运行的 Doc Free + AFFiNE + 新 Docmost

| 资源 | ID / 状态 |
| --- | --- |
| 新合成群 | `room-1de8fc2a-eed0-438b-98c3-b79c8997859e` |
| 普通正文源文档 | `25ae13fb`，r3；由 Agent 成员更新，人/Agent 读取对象相同 |
| H1 源文档 | `f6b5ff58`，r2；H1 创建、Agent 标题/正文更新均保真 |
| 专用 AFFiNE workspace | `a901cbc0-59ac-40b6-86bf-fcca7ff7b619` |
| 普通正文投影 | `2T4haLdQHZ5IkzU2mSJBG`，正文和标题均 verified |
| H1 投影 | `pLxvvvqAYXsM7iuxUGIeR`，正文和标题均 verified |
| 新 Docmost workspace | `01a08286-d2d8-76ee-857e-6c2923907b69`，位于独立 3021 实例 |
| 新 Docmost space | `01a08286-d2ee-75a6-82b2-cb68157cd32a`，显式受控合成空间 |
| Docmost 普通正文投影 | `01a08286-d73b-76c5-922f-7e1204ba8b2d`，跟随源 r3，正文和标题均 verified |
| Docmost H1 投影 | `01a08286-d78b-7621-ba89-e26e5c6fbb10`，跟随源 r2，正文和标题均 verified |
| 非群成员实际尝试 | 成员凭据有效，但群文档返回 access_denied；没有进入外部写意图 |
| 原 Docmost 3020 | 继续在线，原 users/pages/workspaces 的计数和全部行指纹与前值相同；未迁移、未重置密码 |

真实链路为：Agent 使用自己的 Doc Free 群成员 API 修改源文档，单次同步命令分别调用两个平台的真实 HTTP 写接口，再读取目标正文和标题。源文档 `25ae13fb` 从 r2 到 r3 后，两端均更新到原 external ID。随后两次重复命令仍返回完全相同的四条回执；持久 journal SHA 未变化，没有新增写意图或重复创建。源正文 SHA 为 `8370a0f0d4c504b0eb15e1601b02749aff59bedac69f6b4c77a1c3b2fa9ae2e2`。

H1 文档 `f6b5ff58` 当前正文 SHA 为 `a29c4f01f8d8185304feef4163c396f3b35f5075340f2322f5a1a7e70737ee43`，两端均读取确认。四条回执全部为 verified，而不是仅凭写入接口返回 200 判定成功。

本机证据均在忽略的 `output/startup-document-sync-20260909/` 下，主要文件：

- `affine-create-initialized-result.json`、`affine-repeat-result.json`：重复调用保持相同 ID 与回执，未再次创建。
- `agent-source-update.json`、`h1-agent-source-update.json`：真实 Agent 成员 API 修改源文档。
- `affine-body-title-verified.jsonl`、`affine-h1-update-verified.jsonl`：CLI 原始读回结果，两篇已 verified。
- `denied-member-result.json`：真实未入群成员无法同步该群文档。
- `final-readback-receipt.json`：早先仅 AFFiNE 阶段的 40/40 项证据；保留其当时 Docmost 未验证状态，不用它代表最后双平台结果。
- `docmost-instance-receipt.json`、`docmost-official-setup-receipt.json`：新隔离实例、官方 setup 与专用 space 的实际回执。
- `dual-provider-initial-result.jsonl`、`dual-source-update.json`、`dual-provider-update-result.jsonl`：双端真实创建、Agent 源更新、双端原 ID 更新结果。
- `dual-provider-repeat-result.jsonl`、`dual-provider-final-live-result.jsonl`：再次访问源和目标后，四条回执仍完全相同；未新增 journal 意图。
- `docmost-original-data-before.json`、`docmost-original-data-after.json`：旧 3020 数据库 users/pages/workspaces 的计数和全部行指纹完全一致，没有导出原始账号或页面内容。
- `dual-provider-final-readback-receipt.json`：最终 **69/69** 项通过，覆盖两份源文档、人/Agent 一致读取、四个真实目标投影、更新 ID 稳定、重复执行、历史 26 篇业务文档保护、旧 Docmost 数据保护及新实例运行边界。该数量仅是本轮范围，不代表全量商业平台验收。

### 首次失败、恢复与历史文档保护

首次专用 AFFiNE workspace 未初始化，create 返回工具失败。Worker 保存 unknown 并停止，未重试。随后用该账号已认证的 `space:load-doc-timestamps` 验证新 namespace 为零文档；使用原生 sync 协议仅初始化其新根文档。人工恢复决策另存 `initialization-recovery-decision.json`，保留首次 unknown journal，再创建初始化后的新合成 binding。该一次性的恢复证明仅适用于这个已验证为空的新 namespace，不能用于一般 unknown 创建；生产恢复仍需专门对账/审批流程。

启动基线 26 篇历史文档全部保留原正文、标题、版本和所有原有字段。25 篇对象 SHA 完全一致；`5ddcd4f4` 仅补齐 `applied_operations: {}` 空运行元数据。移除这个新增字段后可精确重算出启动基线整对象 SHA。其正文仍等于原提交正文（去掉服务端原有的末尾一个 LF），SHA 为 `6341a59edad8094046fe35cd665318acb25e9c27d6adaec4f7f4c94236ee4cc7`，revision 仍为 1。

保留了首次严格对象比较的 `initial-full-object-comparison.json`（39/40）以及随后逐字段重建的 `historical-projection-metadata-readback.json`，没有把这个元数据差异抹掉或称为对象字节完全相同。

## 8. 后续工作与停止点

本轮按主任务要求完成证据收尾后停止扩展。接续项：

1. 恢复原 Docmost 3020 的合法登录或制定显式迁移方案。当前新 3021 只验证了专用合成空间；原实例 14 篇页面和历史账号并未迁移。下游真实冲突与撤权的完整生产验收仍待扩展，当前这部分有自动化协议测试及源非成员真实拒绝证据。
2. 将当前独立命令接入人机 Go 协作内核的 PG Outbox、资源目录与策略，覆盖人、Agent、委派、停止代次和 UI/API/MCP/A2A；保持一个写入权威。
3. 补齐生产级 AFFiNE 写接口策略、服务身份轮换、目标空间权限映射、直达入口封闭和撤权后的既有副本处置。
4. 建设显式 unknown/conflict 处理流程、归档与目录重建、可分页存量导入，不通过清空 journal 或更换 binding ID 绕过一般未知结果。
5. 验证复杂文档结构、附件、长文、多人多 Agent CRDT 协作和下游格式兼容。不能用当前两个合成 Markdown 文档证明全部 Doc Free 内容无损同步。
