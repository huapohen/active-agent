# 原生结构对账协议

当供应商的 Markdown 导出不能保留结构时，网关可以核对同一源版本、同一目标 ID 的完整原生文档。该能力是显式启用的校验路径；原 `unknown/readback_mismatch` 记录保留，新回执状态为 `native_verified`。它不意味着 Markdown 字节相同、像素布局相同、相对链接在另一应用中可用，或所有文档类型都已支持。

## 单主与回执

Doc Free 的源文档正文、标题、revision 和 exact SHA-256 是唯一主源。既有 `BodyHash` 只用于既有 Markdown 比对；新增 `observed_raw_body_hash` 保留未经规范化的下游导出指纹。`native` 保存 profile、目标版本/原生字节指纹、源/目标 canonical 指纹、平台行为差异指纹和原始 `readback_mismatch`。

`Record` 的新字段必须位于结构末尾并带 `omitempty`，零值序列化必须逐字兼容旧 journal。对账只追加一条回执，不改写旧 `prepared/submitted/unknown`。第二次读取同一版本不追加、不发送目标写请求。无外部 ID 的未知创建、源版本不一致、当前撤权、目标独立编辑、未知结构或不完整证明均不能签收。

原生基线必须再次经授权读取。Docmost 的 `updatedAt` 与原生 JSON 指纹、AFFiNE 的完整 Yjs snapshot 指纹变化，都会阻止使用旧证明继续。并发稳定性围栏是有界多次读取，不是供应商数据库事务或跨应用 CAS。

## 当前 profile

| profile | 支持的部署与原生读取 | 完整性条件 |
| --- | --- | --- |
| `docmost.prosemirror.gfm.goldmark-1.8.6.v1` | 当前 Docmost `pages/info` 的 ProseMirror JSON；源使用 Goldmark 1.8.6 的 GFM AST | markdown/native/markdown/native 四次读取必须同 ID、space、title、`updatedAt`；两份 Markdown raw hash 和两份 native JSON raw hash 分别相同；完整 canonical AST 相同 |
| `affine.database-v3.rich-text.b4c8548c0.v1` | AFFiNE 部署源码 `b4c8548c0`；官方受鉴权 HTTP Yjs snapshot，配合 MCP 正文与 GraphQL 私有页面元数据 | 两份 snapshot 的字节与 ETag 相同；读取前后正文/标题一致；整棵原生树可识别且每个 block 都访问；源/目标 canonical AST 相同 |

v1 源 canonical 支持段落、标题、普通/有序列表、GFM 表格、强调、粗体、删除线、行内代码、链接及换行。图片、HTML、任务框、引用、代码块等尚未纳入 v1，遇到即拒绝。下节 v2 单独扩展 fenced code；v1 的解释不改变。节点/属性/marks 白名单、UTF-8/JSON 重复键与 UTF-16 转义检查，以及正文大小、递归深度、节点数量上限均不能被“导出格式差异”绕开。

Docmost 会附加链接的浏览器行为属性。仅当前已审计的默认组合可以单独记录为平台差异；不能因此忽略新的链接地址、标题、非默认属性或结构。只在同一容器中合并相邻、marks 完全相同的文本叶子，不压平段落、列表或表格。

AFFiNE 必须使用真实 Yjs shared types。形如 `{text, delta}` 的普通对象/Y.Map 不能冒充 Y.Text。块 ID 必须等于 map key；固定 profile 校验 page v2、surface v5、note v1、paragraph/list v1、旧 table v1、database v3。未知版本、未知 `sys:*`/props、未访问块、错误父子关系、未知 marks、视图/filter 或隐藏列均拒绝。

AFFiNE 数据库投影使用第一列 `title` 类型与其余 `rich-text` 类型，列名称表示表头，行段落及其他单元格使用 Y.Text 保存行内格式。列 ID 不能占用官方数据源的 `type`、`title`、`created-time`、`created-by` 保留名；这些名称会覆盖实际属性的渲染行为。这里的数据库模型不等同于旧 `affine:table` 的 primitive string 单元格。

## 运行依赖与隔离

Go 依赖固定 Goldmark 1.8.6。AFFiNE codec 在独立 `affinecodec/package.json` 与 lockfile 中固定 Yjs 13.6.32、官方 Socket.IO client 4.8.3；不修改客户端根 npm 依赖。Node 版本要求 22 或以上。

首次安装前遵循仓库的网络约定，短测官方源与可验证镜像，随后在 codec 目录执行 `npm ci --ignore-scripts --no-audit --no-fund`。lockfile 的 integrity 不能省略。普通 Go 单测若本机未安装 Node/codec 会跳过相关集成用例，因此正式启用时必须确认 Node 集成用例真实运行。

Go verifier 要求 `-native-node` 是明确的绝对可执行路径；不从 PATH 任意选择 Node。子进程环境只有 `LANG=C.UTF-8`、`LC_ALL=C.UTF-8`，不继承模型、Clerk、RongCloud、文档凭据以及 `NODE_OPTIONS`、`NODE_PATH`。正文/native snapshot 只经 stdin 传入；codec 不联网、不读取凭据；stdout 仅输出有界证明，stderr 不传播内容。父进程同时验证 codec 返回的 source canonical 与 native raw hash。Node 内存上限 256 MiB，HTTP、stdio 和证明都有大小/超时限制。

## 定向对账命令

从 `services/collaboration` 运行，使用已经存在且经管理员核对过的 binding/config/journal。示例中的绝对路径与 ID 必须换成对应部署的合法资源。不要复制旧 publisher、重新 setup 或为未知写创建第二个目标 ID。

```sh
go run ./cmd/document-sync \
  -config /absolute/private/projection-config.json \
  -binding exact-existing-docmost-binding \
  -native-profile docmost.prosemirror.gfm.goldmark-1.8.6.v1
```

```sh
go run ./cmd/document-sync \
  -config /absolute/private/projection-config.json \
  -binding exact-existing-affine-binding \
  -native-profile affine.database-v3.rich-text.b4c8548c0.v1 \
  -native-codec /absolute/services/collaboration/internal/documents/affinecodec \
  -native-node /absolute/trusted/node
```

`-binding` 限制本次只处理指定映射，profile 与供应商不匹配会在外部效果前拒绝。`native_verified` 返回成功退出码，其含义仍受上述 profile 约束；未启用正确 profile 无法继续使用原生证明。

## AFFiNE 修复与后续版本

2026-09-09 已知同 ID 文档的修复分为两步：先离线构造并冻结官方 database v3 Yjs delta，独立反解完整文章并检查原有非表格 blocks/顺序/标题不变；经审阅后，用官方 Socket.IO client 发出一次受 Doc.Update 权限检查的更新。更新前再次读取源 ACL/版本、目标 ID/私有状态和原生版本，写后对同 ID 完整读回。冻结更新的单次执行脚本有 fsync effect state、未知结果阻断和禁止自动重发；它不是后台通用 writer。

正式 `document-sync` 只在上述更新完成且严格原生证明通过后追加对账。供应商旧 Markdown MCP 明确不支持 database 更新，因此已经 `native_verified` 的 AFFiNE 数据库投影若源 revision 推进，网关返回 `affine_native_write_plan_required`，保留原回执且不发出 Markdown 更新。后续需在同样版本/权限围栏内生成并审阅新的原生写计划，不能降级覆盖已修复表格。

采用相同 block ID 切换 flavour 后，已打开的供应商页面可能仍缓存旧模型；真实布局验收必须重新加载页面。此代码只证明原生结构，不代替 GUI 观察。目标编辑、模型升级、额外数据库视图、外部分享和撤权后的副本删除等仍需相应治理能力；不能以一次严格对账覆盖这些边界。

## 验证

```sh
go test -race ./internal/documents ./cmd/document-sync
npm --prefix internal/documents/affinecodec test
```

测试包含真实本地 HTTP 协议、多次版本围栏、旧 journal 字节兼容、禁止跨 provider profile、同形伪 Y.Text、未知 props/sys/version、保留列 ID、parent secrets/Node 注入隔离、真实冻结整篇 fixture 的反解，以及 AFFiNE 源版本推进时 0 写入/0 journal 变动。运行验收需要另记录实际 ID、版本、hash、时间和单次副作用数。

## v2：执行档案的 fenced code

新增显式版本：

- Docmost：`docmost.prosemirror.gfm-code.goldmark-1.8.6.v2`
- AFFiNE：`affine.database-v3.code-v1.rich-text.b4c8548c0.v2`

v2 延续 v1 全部结构限制，并增加 canonical `codeBlock`，仅保存精确 `language` 和 `text`。带围栏的代码块从源行读取，保留中文、Unicode、CRLF、内部空行、末尾换行数以及 EOF 没有换行的区别。Goldmark 为未闭合 EOF 代码块渲染时补的合成 LF 不进入本档案 profile。缺省语言为 null；明确语言为不超过 80 个 ASCII 字母/数字或 `_-.+#` 的标识。额外 fence metadata 不可由两个目标原生语言字段表达，故拒绝；缩进式 code block、HTML 与其他未支持格式仍拒绝。

Docmost 只接受 `codeBlock` 的语言属性和普通、无 marks 的 text children；禁止用 paragraph、hardBreak、行内样式或隐藏属性替代代码正文。AFFiNE 只接受 `affine:code` schema v1、真实 Y.Text、无嵌入子块、无格式 delta；wrap/caption/preview/lineNumber/collapsed/comments 只接受当前明确的默认显示值，未知字段及非默认隐藏/预览行为拒绝。官方缺省语言的 `plain text`/空字符串映射为 null，不把明确语言名相互合并。

**v2 即使既有 Markdown 比较通过，也必须获取完整原生证明。** `native_verified` 中的 `markdown_export_error` 反映实际比较结果：若 Markdown 比较仍失败则保留 `readback_mismatch`；若通过则为空字符串，不能捏造此前不存在的导出错误。源 exact hash、目标 raw hash 仍分别保存。旧 v1 journal 没有被迁移或重新解释，profile 不匹配不能复用旧原生证明。

本阶段使用既有真实 Doc Free 档案 `9d62380a` r1 的只读快照建立独立 fixture。调用同部署 AFFiNE Rust `createDocWithMarkdown` 与 Docmost `markdownToHtml → htmlToJson` 的纯转换函数，生成的离线文档均通过完整 v2 canonical 比较；这不是目标页面已经创建的证据。6 个 JSON code blocks 的语言、每个 UTF-8 字节与尾 LF 均与源 fence 直接切片比较。AFFiNE 继续使用已有 H1 传输空行保护，没有修改源正文。

运行 v2 的方式与上面的定向命令相同，只替换 profile 字符串。真实新投影必须使用单独、明确批准的 binding/config/journal，先冻结源 ID/revision/hash、namespace、身份与单次创建意图，再执行创建和读取核验。旧两个交付目标不会用于此新档案。针对 code-only 文档，当前 AFFiNE Markdown 导入可以表达 code blocks；已原生签收后的下一源 revision 仍受 `affine_native_write_plan_required` 保护，不因为本次成功就放开未经审阅的新版本写入。
