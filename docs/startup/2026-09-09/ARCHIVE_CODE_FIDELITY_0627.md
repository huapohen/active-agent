# 执行档案代码块：v2 原生保真与双目标真实投影

记录时间：2026-09-09 06:27，Asia/Shanghai。本轮原生 code profile 与 CLI 修复在本文写入时尚未提交；最终实施提交号、时间、描述将在提交后追加。既有 `a639a8843093bed98b04b375d361de6e2c2129c9`（2026-09-09T05:56:24+08:00，`feat(core): add native document verification and durable agent archives`）是 v1 实现基线，不是本轮 v2 的实施提交。

## 1. 本轮完成的真实结果

既有 Doc Free 执行档案 **`9d62380a` r1** 已分别创建一个新的 AFFiNE 和 Docmost 投影，两个目标均完成完整 v2 原生对账，状态为 `native_verified`。该档案记录的是 Run `76dedd18-1ddf-4fc0-abfa-19aee795b034` 的 **failed** 事实及证据游标 5；同步成功不会把失败执行改写为成功。

| 项目 | 实际值 |
| --- | --- |
| 源标题 | 人机执行档案 · 76dedd18-1ddf-4fc0-abfa-19aee795b034 · 游标 5 · 1 |
| 源 ID / revision | `9d62380a` / `1` |
| 源 exact SHA-256 | `e37f8cacc7f3e26a53c66be9b0c89e90273e98ca1efc5da44109b980aa5d9fe9` |
| 源标题 SHA-256 | `68f797beab2c5ded0e2e757b45e5054fda3deb1bcd2bb619f010295c2090d887` |
| 整篇 canonical SHA-256 | `2d6a46b05fac3ee69e3bc9ad3ae23f1b132ff7fd786ef5de779dd26c29f75230`；源与两个目标一致 |
| 源权限 | 创建前人类与 Agent 均 HTTP 200、文档全对象一致；真实非成员 HTTP 403。写入及签收前后仍校验当前合法来源、ID、revision、hash、title |
| 源修改 / 聊天 / 模型调用 | 均为 0；使用既有归档，没有重跑原 Run |

新 AFFiNE 页面：[执行档案](http://127.0.0.1:3010/workspace/a901cbc0-59ac-40b6-86bf-fcca7ff7b619/KfTj5XXxNr39dXMML9eff)，doc `KfTj5XXxNr39dXMML9eff`，在原受控 workspace 中创建。06:22:59.611068+08:00 对账为 seq4 `native_verified`；native snapshot SHA-256 `cf74c54fa53229483523c2b296babdbe2bf6a6a3b96fe63f4d771af81be2224d`。Markdown 导出仍 `readback_mismatch`，保留该差异，不将原生校验说成字节导出已无差异。

新 Docmost 页面：[执行档案](http://127.0.0.1:3021/p/l8xzi5wOsi)，page `01a0831e-38e3-76d9-8c34-0466c871bb42`，在原明确受控 space 中创建；URL 的 `l8xzi5wOsi` 来自服务端 `slugId`。06:23:11.239387+08:00 对账为 seq3 `native_verified`；四次原生/Markdown 读取对应相同 `updatedAt=2026-09-08T22:23:11.073Z`，native JSON raw SHA-256 `f23d48a2f4dbe551643587d38699f5ef55d3b792df1a26018400a90e226bfd72`。其 Markdown 导出本次也与源 exact hash 一致，因此 `markdown_export_error` 为空，不虚构不存在的导出错误。

两个 provider 各调用一次创建；没有调用更新或原生 delta。第二次定向执行均返回同一记录、同一目标 ID，不再写入或追加。

## 2. 为什么需要 v2

v1 profile 明确拒绝 fenced code，不能拿上一份交付文档 `a74679d5` 的校验结果替执行档案签收。本轮增加两个显式版本：

- `docmost.prosemirror.gfm-code.goldmark-1.8.6.v2`
- `affine.database-v3.code-v1.rich-text.b4c8548c0.v2`

v1 profile、旧原生回执与旧 journal 的解释保持不变。v2 继承已有完整树、权限与版本围栏，并增加 canonical `codeBlock` 的精确 `language` 与 `text`。语言、中文/Unicode、CRLF、内部空行、尾换行数量和 EOF 没有换行均分别比较；不把代码文字当 Markdown 再解析，不以整段 trim 或压平文本掩盖变化。

语言必须是明确的有限标识；未知 fence metadata 无法由当前原生语言字段表达，因此拒绝。Docmost 只接受普通无 marks 的 code text children；AFFiNE 只接受官方 `affine:code` schema v1 和真实 Y.Text，无嵌入子块，禁止未知属性、伪造 shared text、隐藏/预览/非默认 caption 行为。已有表格、节点版本、sys/props、保留列 ID 等严格检查没有删除。

v2 **即使现有 Markdown 比较通过，也必须完成原生结构证明**。回归已复现“Markdown 相同但原生 code 丢尾 LF”，结果保持 unknown、没有 native proof，已知 ID 重试只读不再创建。旧 profile 无法自动复用 v2 receipt；AFFiNE 后续源 revision 仍受 `affine_native_write_plan_required` 保护。

## 3. 官方导入器离线验证与真实读取是两组证据

先在当前部署中调用纯转换函数，不写服务数据：AFFiNE MCP 实际使用 Rust `createDocWithMarkdown`；Docmost 使用 `markdownToHtml → htmlToJson`。二者都能保留本档案 6 个 JSON fenced blocks 的语言和尾 LF，因此无需再对新目标发送原生修复 delta。AFFiNE 保留既有开头 H1 的传输空行保护，Doc Free 正文没有变化。

离线生成的 fixture 与真实创建后的页面 snapshot 分别保存。Go 比较完整源树与两组离线原生结构；实际创建后又取得同版本 native proof，随后独立读取两个目标，将全部六个代码块与源 fence 直接切片逐字比较。AFFiNE 真实整棵树访问 **24/24 blocks**，canonical 与源一致。

| 代码块序号（从 0 开始） | 语言 | UTF-8 字节数 | 尾 LF | 源与两目标 |
| --- | --- | ---: | --- | --- |
| 0 | json | 1759 | 保留 | 逐字 / hash 一致 |
| 1 | json | 2234 | 保留 | 逐字 / hash 一致 |
| 2 | json | 2234 | 保留 | 逐字 / hash 一致 |
| 3 | json | 2234 | 保留 | 逐字 / hash 一致 |
| 4 | json | 707 | 保留 | 逐字 / hash 一致 |
| 5 | json | 249 | 保留 | 逐字 / hash 一致 |

逐块完整 hash 在 [live-code-byte-proof.json](evidence/archive-code-fidelity/live-code-byte-proof.json)。没有把离线 fixture 的 ID/hash 写成实际创建目标的 ID/hash。

## 4. 冻结计划与历史保护

先冻结了 [新投影计划](evidence/archive-code-fidelity/frozen-plan.json)，明确源 ID/revision/hash、合法身份、两个 namespace、单次创建意图及新 config/journal；经独立审查后才执行。两份旧配置、旧 journal 与既有 **6 个投影** 在执行前后分别读取 native/title/version，均保持相同。前后对比见 [before](evidence/archive-code-fidelity/old-targets-before.json) / [after](evidence/archive-code-fidelity/old-targets-after.json)。

新配置为私有 `data/startup/publications/archive-code-20260909-0618/config.json`，0600，SHA-256 `26001902b95c5531852e5ca744167c1df9db744e3fb36b57c9e705d5bc231d58`；使用新的 `receipts.jsonl`。原配置和旧 publisher/provision/setup/worker 均未重新执行。

新 journal 最终 **7 行**，SHA-256 `5b73e016d09508eda0756475f32f498b7a26aeafca45f84fa320abc2a386dce0`。第二次对两 binding 执行后，字节与行数完全不变。AFFiNE 本次原始 `unknown/readback_mismatch` 行保留，随后追加 native proof；Docmost 因导出也一致，直接从 submitted 追加 native_verified，没有捏造失败历史。

## 5. 验证与操作边界

本轮 `go test -race ./internal/documents ./cmd/document-sync` 通过。新增定向测试覆盖真实档案的整篇官方导入、语言/中文/换行、原生错误不得由 Markdown 通过绕过、错误/未知 profile 与 provider 不匹配。CLI 审查发现并修复了入口仍仅放行 v1 的遗漏；`TestCLIV2ProfilesReachRealNativeVerification` 的 5 子例从实际 `runSelected` 走到 HTTP 创建和原生校验，两个 wrong-provider 和 unknown 保持 0 HTTP。Node codec 全部 **18/18** 通过，其中原 14 项严验保持通过。

原生读取证明的是当前 profile 的完整结构，不代替新页面 GUI/像素验收。本次真实档案的六个闭合 JSON code fences 已通过两种实际导入器；不能由此宣称所有语言插件、嵌入、代码执行、HTML、图片、附件或任意不闭合 EOF 输入在供应商导入时都能无损。未来新源版本、ACL 映射和副本撤销仍须遵守网关保护，不能盲重试已创建目标或把 projection 改成第二主源。

源码说明与定向 CLI 参数见 [NATIVE_PROFILES.md](../../../../services/collaboration/internal/documents/NATIVE_PROFILES.md)。证据清单为 [MANIFEST.json](evidence/archive-code-fidelity/MANIFEST.json)，包含冻结意图、离线 proof、真实回执、逐代码块 proof、旧目标前后保护、实际 native snapshot/JSON，并引用源码中的独立 fixture。没有凭据、Cookie、请求头或账号密码。

## 6. 实施提交归属补记

本轮实现已于 **2026-09-09T06:37:12+08:00** 提交至 Active Agent 的 `startup` 分支：

- 提交：`2fc663150ec66fa2c402e1a38668264f0d961e5a`
- 描述：`feat(startup): automate execution archives and add native message actions`
- 本文对应范围：文档原生 code v2 profiles、严格代码块及完整树校验、CLI v2 分发和回归测试；该提交同时包含本阶段其他 startup 改动。

提交 SHA、时间与描述已通过本地 Git 对象核对。前文 06:27 初稿“尚未提交”的记录保持原样，本节仅补记实际实施归属；源 `9d62380a` r1、两端真实投影与校验时间、旧 manifest 均未因此改写。
