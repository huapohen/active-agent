# AFFiNE 原生修复独立审查

时间：2026-09-09 05:36 +08:00。分支 `startup`；本轮改动未提交。

本轮只读部署版本的官方源码、检查本地修复快照并新增独立回归；没有 GUI 操作、远端写入或 journal 状态修改。实现修复由 document_gateway 完成。

## 发现并已修复

1. **P1：Node 子进程继承服务凭据与注入参数。** `exec.CommandContext` 未设置 Env 时继承父环境。现为配置的绝对 Node 可执行路径、解析符号链接、最小 `LANG/LC_ALL` 环境；不继承 Clerk/Rong/OpenAI 等凭据及 `NODE_OPTIONS/NODE_PATH`。独立复跑真实 Go→wrapper→Node 测试成功。
2. **P2：富文本原生类型被普通结构冒充。** 替换一个 `Y.Text` 为同形 `Y.Map{text,delta}`，旧 canonical 仍通过，但官方 rich-text schema 只接受 `Text/Y.Text`。现验证实际共享类型及不可由 Yjs 数据伪造的 Symbol 来源；数据库嵌套 `Y.Array/Y.Map` 也校验。
3. **P2：未知字段与身份被忽略。** page/surface/note 未校验未知属性，任意 `sys:*` 被放行，view ID 为数字也被接受。现全部经过明确白名单与字符串 ID 校验。根任务此前指出的 block map key / `sys:id` 一致及固定 `sys:version` 也已核实补齐。
4. **P2：保留列 ID 可改变实际显示语义。** 首列 ID 改为 `type`，并同步 view/header 引用后，旧 canonical 仍签同一标题/文本。官方 `DatabaseBlockDataSource.propertyNameGet('type')` 强制返回 Block Type，`propertyTypeGet('type')` 强制为 image。现拒绝保留列名；原修复候选没有这些 ID，无须改其数据。

## 不依赖 codec 反解的独立正向证明

测试直接解码 `testdata/native/affine-original.bin` 与 `affine-database.bin`，没有用 `canonicalSnapshot` 作为该项证明器：

- 原 54 个非表格块逐对象、逐原生类型相等，包括原页面与 note 的子节点顺序。
- 4 个原表格块保留原 ID 与位置，变为官方 database v3；总块 79，新增 21 个行段落。
- 4 张表的表头、行列数量与顺序逐项核对独立 source；所有单元格逐字符及该字符上的 marks 核对，全部一致。
- 46 个非 title 单元格确为真实 `Y.Text`；title 列读取其行 paragraph 的真实富文本。

整个 canonical 比较还使用冻结的 marked 源树，Go Goldmark 与该树的独立一致性测试由原实现覆盖。因此不是仅拼接全文或用写入器自己的少数节点证明整篇。

## 官方模型及视图依据

固定部署提交：`b4c8548c0`，本机源码在 `output/startup-affine-native-model-20260909/blocksuite/`。

- `affine/model/src/blocks/database/{database-model,types}.ts`：database 版本 3、columns/cells/views、row child 类型。
- `affine/blocks/database/src/properties/rich-text/define.ts`：真实 Text/Y.Text 类型；cell-renderer.ts 使用富文本渲染。
- `affine/blocks/database/src/adapters/markdown.ts`：columns.name 输出表头，title 行内容与其余 cell delta 输出正文。
- `affine/blocks/database/src/data-source.ts`、`affine/data-view/src/view-presets/table/table-view-manager.ts`：行按 children、列按视图顺序，未声明的 fixed property 会补入。显式 title 类型已消除重复 title；内置 properties/index 不注册 type，created-time 的 model/renderer 均无 fixed 声明。没有据此宣称已完成浏览器视觉验收。

## 读取与进程边界

`stableNative` 通过合法 metadata credential 读取 binary→title/export→binary，要求 ETag、原始快照、标题及导出状态稳定。Engine 的 native reconciliation 在验证前后均重读来源权限、revision、content hash 和 title；失败不写 `native_verified`。

离线 repair 报告中的 sameDocumentId 不能单独证明远端 ID；实际目标同 ID 必须由已有 binding/manifest 与 authenticated HTTP 回读证明。本轮未进行该远端动作。

## 复验

- `node --test codec.test.mjs codec.review.test.mjs`：**14/14** 通过，其中独立 review **9 项**。
- `go test ./internal/documents -run 'TestAffineNative|TestNativeProfile' -count=1`：**4 个顶层测试**通过，包括真实子进程凭据隔离、合法/失败 HTTP 读取、旧有损表拒绝。
- 本轮唯一新增测试文件：`services/collaboration/internal/documents/affinecodec/codec.review.test.mjs`。
- 最终日志：`/tmp/renji-affine-native-independent-review-final-20260909.log`、`/tmp/renji-affine-go-independent-review-final-20260909.log`。
- 原失败复现保留：`/tmp/renji-affine-native-independent-review-20260909.log`、`/tmp/renji-affine-reserved-column-review-20260909.log`。

## 冻结后的新版来源保护追加复验

独立审读 `projection.go` 新 guard，并执行 `go test ./internal/documents -run '^TestAffineNativeNewSourceRevisionCannotUseMarkdownWriter$' -count=1 -json`：**1 个顶层测试、3 个子测试通过**。同版本保持只读幂等；内容、标题、仅修订号变化均返回 `affine_native_write_plan_required`，0 次目标写入，journal 字节不变。日志：`/tmp/renji-affine-native-update-guard-independent-20260909.log`。

根任务已报告完成实际同 ID 修复与正式原生对账；这不属于本子任务亲自执行的证据。本报告的原生模型、Yjs、子进程和源码更新保护结论来自独立本地验证，GUI 仍未由本子任务验证。
