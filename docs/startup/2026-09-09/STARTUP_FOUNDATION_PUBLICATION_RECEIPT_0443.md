# startup 第一阶段交付文档：实际发布与读回回执

记录时间：2026-09-09T04:43:00+08:00，Asia/Shanghai；最终核实更新：2026-09-09T04:50:10+08:00。实际首次发布为 04:30:08；后续只读诊断时间见各证据。本文不修改已冻结的交付正文。

**当前结果：Doc Free 正式源文档已创建且源权限检查通过；AFFiNE、Docmost 两个投影已创建，但严格 Markdown 正文读回均未通过。两条 Go journal 仍为 `unknown / readback_mismatch`，没有重试创建或改写目标。整篇原生检查证实 Docmost 要求的内容结构保留，同时发现 AFFiNE 表格语义和行内代码的保真缺口；因此没有签收双端无损同步。**

## 1. 冻结正文与真实提交

| 内容 | commit / 时间 | 描述 |
| --- | --- | --- |
| 桌面与 Web 实施 | `71b80f8181fa243b7477ebac0c35c6ce13e2c960`，2026-09-09T04:11:17+08:00 | `feat(desktop): introduce Electron React workspace and isolated RongCloud adapter` |
| 协作、执行与文档内核实施 | `a9005c01ee059b3f093d877ae1eb13828075d692`，2026-09-09T04:15:30+08:00 | `feat(core): add Clerk-bound agent runs, RongCloud outbox, and document projections` |
| 本次发布的源文档提交 | `bd78b7db263c439c3163263f9c77215ca6a1c8a2`，2026-09-09T04:29:46+08:00 | `docs: record startup foundation evidence and manual launch guide` |

发布时 `publication_head` 为 `bd78b7db263c439c3163263f9c77215ca6a1c8a2`；这是文档提交，不冒充实施提交。脚本验证上述两枚实施提交均为当时 HEAD 的祖先，并核对交付正文包含其准确 SHA、Git 时间和描述。

- 标题：**人机 startup 第一阶段交付 · a9005c0 · 2026-09-09**。
- 冻结 Markdown 文件 SHA-256：`34b76dcae212510d4035348e30e77e399311a1a43c3eb53633d64765558ca8c2`。
- Doc Free r1 正文 SHA-256：`44d5f1a1f25b256dd2aef7e80e81b7b6b47d0677b856519f4a1a79d16cfc8844`。
- 两者仅相差服务端移除的末尾 LF。未放宽 CRLF、内部空白、段落、表格、链接或代码标记的源正文比较。
- 固定版本链接：[交付正文](https://github.com/huapohen/active-agent/blob/bd78b7db263c439c3163263f9c77215ca6a1c8a2/docs/startup/2026-09-09/STARTUP_FOUNDATION_DELIVERY_0424.md)、[手动启动教程](https://github.com/huapohen/active-agent/blob/bd78b7db263c439c3163263f9c77215ca6a1c8a2/docs/startup/2026-09-09/MANUAL_STARTUP_GUIDE.md)。源提交已推送到 GitHub `startup`，根任务通过 `git ls-remote --heads origin startup` 核对远端提交一致；链接固定到该源提交。

## 2. 新资源、版本和真实入口

| 系统 | 本次新资源 | 当前验收结果 |
| --- | --- | --- |
| Doc Free | 文档 `a74679d5`，r1；源群 `room-1de8fc2a-eed0-438b-98c3-b79c8997859e` | 源正文核验通过；人和 Agent 读取对象一致；非成员 403 |
| AFFiNE 3010 | workspace `a901cbc0-59ac-40b6-86bf-fcca7ff7b619`；文档 `SLrA9aXyZV-vehgtC91W-` | 标题一致，Markdown 正文不一致；原生表格存在 63 处结构差异；journal unknown |
| 新 Docmost 3021 | space `01a08286-d2ee-75a6-82b2-cb68157cd32a`；page `01a082b6-bade-7ef2-8bfc-02b75fcd97de`；slugId `gsZSY3HjJU` | 标题一致，Markdown 正文不一致；journal unknown |

已核对的本地入口：[Doc Free 成员读取接口](http://127.0.0.1:3218/api/im/rooms/room-1de8fc2a-eed0-438b-98c3-b79c8997859e/documents/a74679d5)、[AFFiNE 文档](http://127.0.0.1:3010/workspace/a901cbc0-59ac-40b6-86bf-fcca7ff7b619/SLrA9aXyZV-vehgtC91W-)、[Docmost 文档](http://127.0.0.1:3021/p/gsZSY3HjJU)。均需对应合法登录身份；源成员接口使用 Bearer 身份。这里没有嵌入访问令牌、Cookie 或临时编辑票据。

AFFiNE 路由来自当前部署 `core/doc-renderer/controller.ts`。Docmost `/p/:pageSlug` 路由、slugId 解析与跳转来自当前部署的客户端；用真实 `slugId` 调 pages/info 已解析回上述同一 page ID。两页面壳 GET 为 200 只证明路由可达，文档授权结论来自独立认证 API 读回。

**源正文中原有的相对 Markdown 链接保持原样，尚未验证它们在 AFFiNE、Docmost 内可正确跨应用解析。** 本回执上方的 GitHub 固定链接用于直接查阅交付正文及教程，不代表源内全部链接迁移完成。

## 3. 为什么没有签收双端 Markdown 同步

| 项目 | AFFiNE | Docmost |
| --- | --- | --- |
| 期望正文 SHA | `44d5f1a1f25b256dd2aef7e80e81b7b6b47d0677b856519f4a1a79d16cfc8844` | 同左 |
| 实际 Markdown 正文 SHA（仅忽略末尾 LF） | `1645c92c0f148ca771637f16ce9b62bc7df84d47330646e6c95666a83daba61f` | `a0c19559b3286e8f5918b93d3c35147fab511b680127f7da75e004b7c481780a` |
| 标题 SHA | `b2a1ad8b6dd1974d70422e4e0dc9c1f8123bb3924563d44ef8753326c2f34f4e` | 同左 |
| Go 原始状态 | `unknown`，sequence 3，`readback_mismatch` | `unknown`，sequence 3，`readback_mismatch` |

AFFiNE 将无序列表的 `-` 改为 `*`，压缩表格周边空格，并移除部分列表尾空行。独立 Markdown AST 对比还发现第 6 节列表后的独立段落“本交付文档会作为新的共享文档发布……”成为最后一个列表项的 lazy continuation，段落数量从 27 变为 26。因此它不仅是字节不同，导出结构也发生变化。

Docmost 对标题中的数字句点加转义。四张表的 Markdown 导出出现空表头，并把真正表头作为第一个正文行输出；这同样不能通过忽略空白或无条件丢弃空表头来签收。

没有把 `unknown` 改成 `verified`，没有清除 journal、替换 binding ID、重新创建文档或反向改写 Doc Free 正文。

## 4. 整篇原生结构与版本围栏：本篇的实际结论

### AFFiNE

原生 Yjs 快照中，第 6 节目标句确实是独立 `affine:paragraph` / `type=text` block，父节点为 `affine:note`，与之前的列表项同级。此项证明这处列表粘连来自 Markdown 导出器，不能由它推断所有原生结构都已保真。

随后完成的独立整篇递归对比访问了全部 58/58 个原生 blocks，未知/未覆盖内容类型为 0。非表格的标题层级、段落、列表从属、文字、粗体、行内代码和链接全部为 0 diff；全部 **63 处要求结构差异均在 4 张表内**：

- 4 张表共 25 行、80 个单元格的位置和行列顺序保留。
- **13 个表头角色未保留**。原生模型没有 header 属性，当前部署 `TableCell.render()` 的两条分支都使用 `td`，无 `th` 分支。
- 全篇行内代码 span 从源 39 处变为目标 21 处；表格中的 **18 处行内代码成为含 36 个字面反引号的字符串**，分布于 13 个单元格。
- 重新离线解码同一正式 HTTP Yjs binary，80 个 `cell.text` 全部为原生 `string`，0 个为 `Y.Text`，逐格与原先 Socket 快照一致。本次 JSON serializer 会先检测 `Y.Text` 并保留 delta，因此不是诊断导出过程丢弃格式。这里不把字符串重新当 Markdown 解析，以掩盖原生标记缺失。

这证明 AFFiNE 不仅有 Markdown 导出问题，还存在真实的表格表头语义与行内代码保真缺口。本检查不声称浏览器中的字体、像素布局或显示期 Markdown 行为已经验收。完整路径差异见 [AFFiNE 结构差异](evidence/affine-structure-diff.json)，输入和统计见 [AFFiNE 原生对比摘要](evidence/affine-structure-summary.json)。

官方 `space:load-doc` 只读诊断在 `read_document` 前后得到相同 timestamp `1788899408474`、state vector 与快照 update。随后核实了可直接使用的正式 HTTP 读取接口：`GET /api/workspaces/:id/docs/:guid`。该接口使用当前身份检查 `Doc.Read` 后返回 `application/octet-stream`；并非无条件公开。

HTTP 当前元数据会话 Cookie 读取为 200，匿名为 403，workspace MCP 写入 token 直接用于该 HTTP 入口也为 403。前后两份原生二进制都是 40,752 字节，SHA-256 为 `ae1cc01f9e5b2ce812a8ec329b96e907c2d95870d0927c54fef9c2d1e77456e6`，与前述 Socket 快照字节相同；使用现有官方 Yjs 库解码得到完全相同的 58 个 blocks。

正式 HTTP 返回稳定 ETag，但没有 `x-doc-timestamp`。`/rpc/workspaces/:workspaceId/docs/:docId` 虽可返回时间戳，属于 `@Internal` 入口，未拿普通凭据尝试绕过。GraphQL 当前 DocType 只有元数据与 updatedAt，没有原生快照字段。

### Docmost

pages/info 不带 format 返回原生 ProseMirror JSON。四张表首行实际均为 `tableHeader`，行数分别为 5、6、6、8，真正表头仍在首行。其 Markdown 导出器的空表头与下移不等于原生表头被删除。

markdown → native → markdown → native 四次交替读取的 ID、spaceId、标题指纹和 `updatedAt=2026-09-08T20:30:08.605Z` 相同；每种正文表示自身的指纹也前后相同。此为版本与稳定性围栏，不冒充跨请求原子快照。

独立客户端审查对本篇要求的原生结构递归比较得到 **0 diff**：4 张表、25 行、80 个单元格、13 个表头角色、3 处粗体、39 处行内代码和 9 个链接全部逐项保留。只合并同一段落/单元格内具有相同 marks 的相邻 text runs，没有跨节点拼接全文。10/10 内存变异控制能识别额外空表头、标题级别、列表从属、单元格重排、文字、格式与链接目标变化。

源与 Docmost 规范化原生树文件 SHA-256 均为 `2abdc9b04e24736d890a292d333db25c1d1fc86bcdd0cc1b6aca81b6336ffb44`。另有 **27 项平台链接行为属性差异**：9 个链接的 target/rel/internal 使用供应商默认值，源 Markdown 没有指定，单独保留在 [链接行为差异](evidence/docmost-platform-link-diff.json)。这不是对浏览器实际跳转的验收。

详情见 [Docmost 原生对比摘要](evidence/docmost-structure-summary.json)。上述结论仅针对这份文档及记录的版本，不改变 Markdown 字节/AST 失败事实，也不将当前 Go journal 自动升级为成功。

## 5. 权限、旧数据和执行边界

- 源群现有合法人类与 Agent 共 2 名成员；未变更成员、角色、群范围或共享对象。
- 新源文档由真实人类成员凭据创建。人类与 Agent 分别从同一群成员接口读取到完全相同的 r1 对象。
- 原有非成员凭据 `/api/im/me` 有效；读取新文档仍返回 403。
- 发布前的 **28 篇 Doc Free 文档全部整对象指纹保持相同**；其中包含之前 26 篇历史业务文档和 2 篇合成验收文档。此处以本次发布前快照为准，不覆盖之前 `5ddcd4f4` 的空运行元数据补齐记录。
- **4 个既有 AFFiNE/Docmost 投影** 的 ID、正文与标题读回指纹保持相同；原同步 config 和 journal 文件 SHA 均未变化。
- 源群 ACL 和消息计数不变；没有发送聊天消息，没有启动 Worker，没有重跑旧 publisher、provision 或 setup。该保护声明针对列出的文档、投影、配置、ACL 与消息范围，不包含全局登录 session 不变：根任务随后为 Electron 验收进行了正常重新登录。
- 新绑定只处理 `a74679d5`，使用独立私有 config/journal。原 Docmost 3020 未接入本次写请求，也未迁移或重置账号。
- `gateway_only_namespace` 是当前隔离配置约束，不是已完成生产入口封闭、持续自动同步、撤权副本清除或全格式保真的证明。

## 6. 可复核证据与当前停止点

关键规范化树、逐路径差异、摘要和只读鉴权/版本证据已持久保存于 [证据 manifest](evidence/PUBLICATION_EVIDENCE_MANIFEST.json)，其中列出每个文件的 SHA-256、大小与原始采集位置，便于清理临时 output 后继续复核。完整独立比较文字报告另保存在本机 `output/startup-publication-native-structure-comparison-20260909.md`；本回执已记录它的最终结论与受限范围。

所有本机详细证据位于 Git 忽略目录 `output/startup-stage-publication-20260909-0418/`，凭据另在 0600 私有目录，未放入报告。

- `latest-sync-result.json`：首次两端 unknown 原始脱敏回执。
- `publication-independent-readback.json`：源权限、28 旧文档、4 旧投影、旧 config/journal 与新目标哈希的独立读回。
- `affine-new-document-readback.md`、`docmost-new-document-readback.md`、对应 `*-format-diff.json`：实际 Markdown 导出与差异。
- `affine-new-document-native.json`、`affine-native-markdown-version-fence.json`：原生结构与只读版本围栏。
- `affine-http-native-snapshot.bin`、`affine-http-native-structure.json`、`affine-http-native-snapshot-receipt.json`、`affine-http-native-equivalence.json`：正式 HTTP 原生读取、鉴权与解码对照。
- `docmost-new-document-structure.json`、`docmost-native-markdown-version-fence.json`：原生结构及交替读取的版本围栏。
- `target-route-evidence.json`：目标路由、真实元数据与 slugId 解析证据。
- `affine-table-native-value-types.json`、`affine-table-renderer-excerpt.txt`：同一 HTTP binary 的实际单元格值类型，以及当前部署表格渲染器证据。

发布后另有根任务的 Electron 文档目录修复：`5629a84749c72a6c8a8237aad547a0f8827ac0b6`，2026-09-09T04:45:28+08:00，`fix(web): map authorized library rooms and document timestamps`。根任务记录 API 定向 12/12 与 TypeScript 检查通过，重新登录后在 GUI 中看到了 `a74679d5` 的 r1 / 04:30，点击进入准确的源群（2 名成员）。这验证目录与房间入口，尚非正文 viewer/editor；不回写已冻结的交付文档。详情由 [原生目录修复补充](LIBRARY_CONTEXT_NATIVE_FIX_0445.md) 记录。

本阶段到此停止，不继续修改供应商源码、扩展页面或尝试目标重写。保留同一源文档、两个已创建目标和两条未知 journal，交由用户验收。下一阶段若处理同步保真，应修复已确认的 AFFiNE 表格写入缺口，并建立正式、带版本且不放宽结构的整篇原生验证；不得通过重新创建或模糊正文比较冒充本阶段无损同步成功。
