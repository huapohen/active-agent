# 本阶段 Docmost 原生投影校验诊断（只读）

诊断时间：2026-09-09T03:07:36.046650+00:00。目标 ID `01a08419-805c-7585-b968-98329277c32c`。源 Doc Free `5a9aa3fa` r1，冻结来源 commit `a58f429f9276a3fc4862fb71d6fba78d90b2a61c`；读取的源 Markdown SHA `521a8a9fea4227da08830163b8a26d856df3791e4923757cc9f12366a67a21c3` 与 frozen plan 的 `server_trimmed_body_sha256` 完全相等。未修改来源、目标、journal 或生产代码。

拒绝由 `/content/22/attrs/type: null` 唯一触发。该节点为 `orderedList`，`start=1`；现有 `docmostTreeVersion` 只消费 start，并在最终未知属性检查拒绝 type。原始原生 JSON 严格 v2 返回 `unsupported_native_document`。

`docmost-candidate-content.json` 只删除这一处 null 属性。逐树验证其他所有字段完全相同。用现有、未修改的 Go `CompareDocmostNativeProfile` 执行严格 v2 比较后，source/target canonical hash 均为 `d3fd186277707d68b6c3c72050151c5057687a702f04482b6815a3888bc01b9d`，48 项既有链接平台默认行为仍由原 profile 显式计数与哈希。没有忽略列表、段落、表格、代码或链接。

候选不是目标修复完成的回执。实际部署容器 `renji-startup-docmost` 使用 Tiptap ordered-list 3.27.1；只读加载其模块确认默认值就是 `{start:1,type:null}`。对缺少 type 的最小列表执行纯内存 `schema.nodeFromJSON(...).toJSON()` 会补回 type:null。因此如果目标更新接口再次经过该 schema，写回仍可能不满足旧 v2。此风险已实测，不能依据离线候选相等而标记目标 verified。官方 [Tiptap OrderedList 源码](https://github.com/ueberdosis/tiptap/blob/main/packages/extension-list/src/ordered-list/ordered-list.ts) 也将 type 默认值定义为 null；实际部署证明另存 `docmost-deployed-schema-defaults.json`。

只读再次读取同一目标，确认 updatedAt `2026-09-09T02:57:38.845Z`、原始 native SHA `7dcfbe5a4feee19dd79b2e0f72114508dae97f8dc48f2b17bcf1ee27fac5e30d` 和标题 hash 全部未变。本次独立诊断只增加一次 pages/info 读取。共享 journal 未动；Docmost 正式验证状态保留原 unknown，即本阶段原生校验 pending；同一目标 ID 保留，不将离线候选计作成功。

候选 SHA：`ac8b4bade7bed8ae894a5bad39a1cc95985f979930f0014ab31861d03c6c29b5`。变更清单、离线 Go 严格比较与版本围栏分别保存在 `docmost-candidate-diff.json`、`docmost-offline-canonical-comparison.json`、`docmost-readonly-version-fence.json`。未来如获准进行原 ID 单次修复，必须重新验证前像与实际原生读回；不能删非 null 编号类型、放宽/改名旧 profile、修改冻结源或手工补 verified。

本轮仅诊断与准备，完成后停止。
