# 云文档真实阅读页：版本、权限与身份隔离

记录时间：2026-09-09T05:10:00+08:00（Asia/Shanghai）。分支 `startup`，基线提交 `380d7bef5b8ce78f6dae38b812e8aa9931ca67d1`（2026-09-09T04:52:22+08:00，`docs: preserve native publication evidence and fidelity gaps`）。此前目录 `room_ids` 与更新时间修复已在 `5629a84`；本文新增阅读页尚未提交，不将基线冒充本次实现 commit。

## 现在能做什么

在 Electron 或 Web 的现有数据迁移模式登录后，进入「云文档」，点击共享文档会打开真实正文。页面显示服务返回的标题、版本、更新时间与只读状态，可返回云文档目录，也可单独打开所属会话。正文阅读不再以跳到群聊代替。

目录从真实 `/api/im/library` 的 `room_ids` 获取上下文，正文使用 `GET /api/im/rooms/:room_id/documents/:document_id`。服务先检查当前主体、群成员和文档共享范围；客户端不通过无鉴权文档管理接口读取，不将 token 放入 URL，也没有修改 doc_free 源码。

本次仍是原有 Doc Free / IM 数据的迁移阅读页。新 Go / Clerk 模式的文档能力尚未开放，`StartupClient.document` 明确返回未支持，不会自动降级到旧认证。客户端稳定能力 ID 为 `documents.list` 和 `documents.read`。

## 正文、版本与状态

- 校验返回文档 ID 与请求 ID 一致；正文必须是字符串且不超过既有 200000 字符上限，版本必须是非负安全整数，正文哈希必须符合服务的 SHA-256 形状。目录和正文的 epoch 毫秒更新时间均可正确显示。
- 初次加载显示「正在校验权限并读取正文」；手动刷新读取服务当前版本，不把目录缓存版本当作正文最终版本。
- 阅读期间每 15 秒、窗口重新聚焦及收到业务变化事件时重新检查。认证、权限、不存在或网络检查失败时，阅读区隐藏先前正文；403/404 不自动改走其他路径。401 仍由现有会话边界退出登录。
- 正文查询使用当前 adapter 实例的独立代次、room ID 和 document ID。切换身份立即换组件与查询键，旧请求被取消；晚到响应不能进入下一身份。无正文持久缓存，离开阅读页后查询缓存立即回收。现有会话令牌仅留在内存适配器中，没有写入 localStorage、sessionStorage、URL 或文件。

这些检查会在轮询/事件/聚焦时收敛，不能宣称离线状态能即时获知服务端撤权。重新检查失败后不会继续将旧正文展示成已授权内容。

## Markdown 可读性与安全

采用 marked 18.0.11 的 token 树，用 React 元素递归渲染；不生成 HTML 字符串，也不使用 `dangerouslySetInnerHTML`。保留标题级别、列表嵌套、表头/单元格顺序、粗体、行内代码、围栏代码和正常链接。表格与代码块可单独横向滚动，阅读页在窄屏使用剩余宽度，去除旧目录的 540px 最小宽度约束。

原始 HTML 作为可见字面文本处理，脚本、iframe、图片事件属性不会成为 DOM 可执行元素。文本实体由 entities 8.1.0 解码后交给 React 转义，代码中的实体保持字面值。外链仅允许无用户信息的 HTTP/HTTPS，使用新窗口、`noopener noreferrer` 和不发送 referrer；图片不自动联网，显示图片说明与可主动打开的安全链接。相对文件链接没有对应在线地址时明确标为「链接未绑定」，没有伪造可打开地址。

两项依赖均已有本机缓存。离线安装因缺少 marked 包元数据未完成后，使用短测更快的可信 npm 镜像完成安装，并逐项将锁文件 integrity 与官方 npm registry 精确版本 metadata 对比，一致。没有下载或重启 Electron。

官方 parser 方法参考：[Marked token/lexer 文档](https://marked.js.org/using_pro)。这里只使用 lexer/token 数据，不使用其 HTML 输出作为可信 DOM。

## 验证证据

- 05:06:41：Web 全套 **42/42** 用例通过，6 个测试文件；其中新增 19 项覆盖真实接口 shape、撤权、取消与身份切换、晚到结果、中文输入、Markdown 结构和脚本/链接边界。TypeScript 检查通过。
- 05:08:36：用 esbuild 仅转译实际 `apps/web/src/api.ts`，通过正在运行的 5173 固定代理执行真实 LegacyClient 读取，未调用 GUI、外部供应商或管理旁路。目录返回 28 篇文档，新交付文档 `a74679d5`、版本 1、正文 7401 字符；本机计算正文 SHA-256 与服务返回 `content_hash` 一致。adapter 退休后再读被拒绝。
- 真实只读回执：`output/startup-document-reader-live-api-20260909.json`，保存源适配器哈希、正常 GET 路径、文档 ID/版本与结果，不含令牌或正文。
- Web 生产构建通过，日志 `/tmp/renji-document-reader-build-20260909.log`。融云 SDK `path` browser 外置提示与较大 chunk 提示仍存在，未伪称包体优化完成。
- `git diff --check` 通过。仅最后清理 App 末尾空行，没有变更验证后的行为。

本子任务没有操作鼠标、键盘或 GUI。源码热更新会使现有 App 的 Fast Refresh 降级为整页重载，已提前通知主任务并在 05:09 冻结源码，由主任务重新登录和完成原生窗口验收。因此本记录不声称已完成实际屏幕像素验收。

## 编辑能力评估与下一步

既有 `PUT /api/im/rooms/:room_id/documents/:document_id` 支持 `base_revision`，运行记录/提案还具有不可直接覆盖的契约限制。本次没有把所有已读文档直接设成可编辑：需要补齐明确写权限/契约展示、编辑草稿、并发冲突、保存回执及受控提案流程后再开放。当前页面明确只读，没有假保存按钮。

下一步应在同一合法接口和身份边界上接编辑/提案，补充跨端实际操作验收与新 Go 文档网关；相对文档链接需按授权目录绑定真实在线文档，而不是重定向到本机文件或携带令牌的地址。

## 最终提交归属与原生阅读验收追加

本文实现最终纳入提交 `a639a8843093bed98b04b375d361de6e2c2129c9`，提交时间 **2026-09-09T05:56:24+08:00**，描述：`feat(core): add native document verification and durable agent archives`。该提交已在本机 Git 核实；开头“尚未提交”描述保留为 05:10 记录时的历史状态，本段为最终实现归属。

根任务随后完成 Electron 实际登录与原生阅读：打开交付文档 `a74679d5` **r1** 阅读完整正文，并确认「来源会话」按钮正确导航；另打开新执行档案 `9d62380a` **r1**，阅读其记录的失败事实，没有把失败档案展示成执行成功。

原生截图：[`desktop-native-archive.png`](../../../output/startup-runarchive-case2-20260909/desktop-native-archive.png)。这是根任务的实际窗口操作证据，与本子任务上文的单元测试、实际 API 读取证据分别记录。它确认已登录 Electron 的正文阅读与会话导航，不代表已经完成全量页面的像素级验收或开放文档编辑。
