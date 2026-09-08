# Doc Free 双投影原生保真修复与正式对账

记录时间：2026-09-09 05:44，Asia/Shanghai。本文追加到本阶段交付与首次发布记录，不改写被冻结的交付正文或最初的 `unknown/readback_mismatch` 证据。

## 1. 结果与提交状态

同一份 Doc Free 文档 `a74679d5` r1 的 Docmost 与 AFFiNE 投影，现已分别通过完整原生结构校验并追加正式 `native_verified` 回执。Docmost 对账没有目标写入；AFFiNE 经离线完整反解和独立审查后，向原目标 ID 发出一次官方 Yjs 更新，再只读对账。两个 binding 再次执行均不追加回执、不重复写入。

**本文写入时，本轮原生 codec、版本围栏、journal 演进和新版写保护尚未提交。以下旧提交仅标识冻结源文档，不能当作本轮实现提交。最终实现 SHA、时间与描述由阶段实施提交后补充。**

| 冻结资源 | 提交 / 时间 / 描述 |
| --- | --- |
| 原交付正文 | `bd78b7db263c439c3163263f9c77215ca6a1c8a2`；2026-09-09T04:29:46+08:00；`docs: record startup foundation evidence and manual launch guide` |
| 原 desktop 实施 | `71b80f8181fa243b7477ebac0c35c6ce13e2c960`；2026-09-09T04:11:17+08:00；`feat(desktop): introduce Electron React workspace and isolated RongCloud adapter` |
| 原 core 实施 | `a9005c01ee059b3f093d877ae1eb13828075d692`；2026-09-09T04:15:30+08:00；`feat(core): add Clerk-bound agent runs, RongCloud outbox, and document projections` |

原冻结文件为 [STARTUP_FOUNDATION_DELIVERY_0424.md](STARTUP_FOUNDATION_DELIVERY_0424.md)，其 SHA-256 保持 `34b76dcae212510d4035348e30e77e399311a1a43c3eb53633d64765558ca8c2`。服务端仅去掉末尾换行后的 source exact hash 为 `44d5f1a1f25b256dd2aef7e80e81b7b6b47d0677b856519f4a1a79d16cfc8844`。

## 2. 原缺口与实际修复

首次发布发现两个供应商 Markdown 导出均有结构失真，因此不能签收字节保真。后续原生整篇审查证明 Docmost 的源层级完整，27 处差异属于已明确列出的链接平台行为属性；AFFiNE 除导出问题外，原 `affine:table` 还丢失 13 个表头角色，并将 18 个表格内代码片段变成 36 个字面反引号。

本轮没有放宽表格检查，也没有把表格替换成图片或纯文本。AFFiNE 使用同部署 `b4c8548c0` 官方 database v3 模型：列名表示表头，首列为 title 类型，其余为 rich-text 类型，单元格使用真实 Y.Text 保存格式。保留四个原表格 block ID、原有 54 个非表格 blocks、顺序和标题；新增 21 个数据行段落，最终完整访问 79/79 blocks，未识别或未访问的 blocks 为 0。

冻结 delta SHA-256：`6d0eb416f297116d93c28dd88f21c8885b2ad454ab40bbc0d788218333401ee6`。官方 Socket.IO client 在每次实际更新时仍受服务端 `Doc.Update` 权限检查；没有改动 AFFiNE 实例源码或 Doc Free CRDT 内核。

## 3. 实际资源与时间

标题保持：**人机 startup 第一阶段交付 · a9005c0 · 2026-09-09**。

| 资源 / 操作 | 实际标识与结果 |
| --- | --- |
| Doc Free | `a74679d5` r1；源群 `room-1de8fc2a-eed0-438b-98c3-b79c8997859e`；读取时仍通过当前成员授权、源 revision、内容及标题围栏 |
| Docmost | [原页面](http://127.0.0.1:3021/p/gsZSY3HjJU)，page `01a082b6-bade-7ef2-8bfc-02b75fcd97de`，space `01a08286-d2ee-75a6-82b2-cb68157cd32a` |
| Docmost 原生签收 | 2026-09-09T05:15:20.583567+08:00；binding `startup-stage-publication-20260909-0418-docmost`，seq4，`native_verified`；0 目标写入 |
| AFFiNE | [原页面](http://127.0.0.1:3010/workspace/a901cbc0-59ac-40b6-86bf-fcca7ff7b619/SLrA9aXyZV-vehgtC91W-)，workspace `a901cbc0-59ac-40b6-86bf-fcca7ff7b619`，doc `SLrA9aXyZV-vehgtC91W-` |
| AFFiNE 单次修复 | 2026-09-09T05:37:51.370+08:00 开始记录；服务端 accepted timestamp `1788903471386`；向原 ID 发出 1 次 delta，实际 post snapshot 与离线冻结结果一致 |
| AFFiNE 原生签收 | 2026-09-09T05:40:50.388053+08:00；binding `startup-stage-publication-20260909-0418-affine`，seq4，`native_verified`；签收命令 0 目标写入 |

源与两个目标的完整 canonical SHA-256 均为：

`903e9410dfa7c2d7945546fe4001f2ee2b34f1eb12d1b1a733fd269787b1e320`

| 校验项目 | Docmost | AFFiNE |
| --- | --- | --- |
| profile | `docmost.prosemirror.gfm.goldmark-1.8.6.v1` | `affine.database-v3.rich-text.b4c8548c0.v1` |
| 目标版本 | `2026-09-08T20:30:08.605Z`，四次读取相同 | `sha256:a2bd6b60de16733706bde2ffccbe4301c2b6d4e15c7ef1b1a16d798b971dc8fc`，多次 HTTP snapshot/ETag 相同 |
| 原生 raw hash | `57428f0f86d5b55e03e768a791141f49e14b17960d0155be45a5b7b848a9bd72` | `a2bd6b60de16733706bde2ffccbe4301c2b6d4e15c7ef1b1a16d798b971dc8fc` |
| 另列平台行为差异 | 27 处已审计链接默认属性；保存独立 hash | 0；此数不代表 GUI 像素差异为零 |
| Markdown 导出状态 | 仍为 `readback_mismatch` | 仍为 `readback_mismatch` |
| 同版本再次执行 | 相同回执，无新增行、无目标写入 | 相同回执，无新增行、无目标写入 |

## 4. journal 与历史保护

既有字段的顺序和零值序列化保持兼容，新 `observed_raw_body_hash` 与 `native` 字段位于 Record 末尾且使用 `omitempty`。真实原六行完整逐字保留，第七行为 Docmost 原生对账，第八行为 AFFiNE 原生对账；旧 unknown 记录没有被覆盖或改成成功。

| 阶段 | 行数 / SHA-256 |
| --- | --- |
| 原首次发布 journal | 6 行；`e1fb4caaf78684140c16a75412cf3939ea54f1ba11470db223e24a7adcb9b46e` |
| Docmost 对账后 | 7 行，6192 bytes；`7095123139869a35d08c826711223780abef3890829f93ad2c33355802ac9ac4` |
| AFFiNE 对账后及重复执行 | 8 行，7779 bytes；`8c11808d31b561b2b530853fc46351be7e75345da3d84e6449acb7160fec4abf` |
| 原配置不变 | 2488 bytes；`87def3b98f0b703faa210b34a00839f192c148c3b916801db798180d9ce922df` |

本轮真实操作硬绑定新交付 source ID、原两个 target ID 和既定受控 namespace；没有重新创建文档、重跑旧 publisher/provision/setup/worker 或发送聊天消息。首次发布时的 28 份旧文档与 4 份旧投影保护证据仍在 [原发布回执](STARTUP_FOUNDATION_PUBLICATION_RECEIPT_0443.md)；本子阶段不将“未向旧资源发出写入”夸大为重新遍历所有历史数据或全局 session 元数据不变。

## 5. 实现保护与验证

正式能力、部署命令和边界见 [NATIVE_PROFILES.md](../../../../services/collaboration/internal/documents/NATIVE_PROFILES.md)。本轮已完成：

- Source exact hash、目标导出 raw hash、原生 raw hash 和 canonical hash 分别保存，避免把规范化后的结果称成原字节。
- 只有同 source revision/ID/title、当前合法 source ACL、目标 namespace 和完整原生结构证明齐备时才对账。版本、公开属性、未知节点/属性、错误 shared type、隐藏/filter/额外块均拒绝。
- AFFiNE Node codec 使用明确可信绝对路径、仅含 locale 的最小环境，不继承模型/Clerk/RongCloud/文档 secrets 或 NODE_OPTIONS/NODE_PATH。独立 synthetic secret 与注入回归通过。
- 块 map key/sys:id、所有已采样 schema version、sys/props 白名单、真实 Y.Text、非空字符串 view/column ID、官方保留列 ID 均已纳入反例校验。
- 已签收的 AFFiNE 数据库投影遇到新的源 revision 时返回 `affine_native_write_plan_required`；内容改变、标题改变和仅 revision 推进三种回归均证明 0 目标写入、journal 逐字不变。当前旧 Markdown MCP 不能被拿来覆盖原生数据库。

本轮冻结前运行 `go test -race ./internal/documents ./cmd/document-sync` 通过；独立 npm codec `node --test` 14/14，通过且 0 skip。测试包含独立审查者新增的真实 raw Yjs 整篇反解、伪造 Y.Text、未知属性与保留 `type` 列反例；没有只用自己的 canonical 结果验证自己。

## 6. 保留边界

这次签收适用于该冻结文档与明确 profile 支持的结构，不是所有 Markdown、嵌入、图片、附件、数据库视图、跨应用链接或像素布局已经完成。AFFiNE profile 固定当前部署版本，供应商升级或新的原生写计划必须重新检查。原生模型更换后已有页面可能缓存旧 flavour，真实界面验收应重新加载；本回执不以结构 hash 代替 GUI 观察。

Doc Free 源仍是唯一正式正文；两个下游不是第二正文主源。当前已有读写与对账接口，但实时撤权后的历史副本删除、公开分享治理、跨服务原子提交和全部新格式的自动原生 writer 尚未由此回执证明完成。后续源版本必须在相同权限/版本保护下执行受控更新，不得盲重试本次 frozen delta。

## 7. 可保留的精简证据

[原生修复证据清单](evidence/native-reconciliation/MANIFEST.json) 保存 9 个新证据文件，合计 32,953 bytes，并引用已入源码的四个真实 fixture 与冻结原文：两份正式 native 回执、两份重复执行/历史前缀证明、AFFiNE 冻结计划、离线证明、真实单次写后读回、官方同部署源码 hash 清单和冻结 delta。

证据不包含凭据、Cookie、请求头或本机账户密码。保留 fixture 中的正文是已授权发布的本阶段交付文档；运行目录 output 后续清理不会让核心证明仅剩不可查的日志路径。原始发布差异证据保持独立，用于说明这次修复解决了什么，而非擦除最初失败。

## 8. 实施提交归属补记

本轮实现已于 2026-09-09T05:56:24+08:00 提交至 Active Agent 的 `startup` 分支：

- 提交：`a639a8843093bed98b04b375d361de6e2c2129c9`
- 描述：`feat(core): add native document verification and durable agent archives`
- 本文对应范围：原生文档 codec、Docmost/AFFiNE 同版本验证、`native_verified` 回执演进、AFFiNE 后续源版本写保护及相关测试；该提交同时包含本阶段其他 core 改动。

以上 SHA、提交时间和描述已通过本地 Git 对象核对。第 1 节“本文写入时尚未提交”保留为 05:44 的真实状态；本节补记实际实施提交，不将旧冻结源提交冒充本轮实现，也不改写首次发布、原生修复和对账的实际时间。
