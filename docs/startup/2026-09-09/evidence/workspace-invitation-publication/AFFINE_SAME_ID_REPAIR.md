# 本阶段 AFFiNE 同 ID 保真修复回执

源文档 `5a9aa3fa` r1，来自 docs commit `a58f429f9276a3fc4862fb71d6fba78d90b2a61c` 的已冻结报告。主实施提交 `30c6c22ce3ff24676d9d5a43bf1b3ce0cf14aafa`；本次不修改源报告、业务代码或旧发布记录。

首次 AFFiNE 创建得到目标 `RBOpVVG9dPUzZIOl6BWNN`，Go journal 保留 sequence3 unknown/readback_mismatch。全篇原生对比发现76处差异，全部集中于2个 `affine:table` 的表头角色及行内 code；46个非表格块与源结构相同。没有把差异归咎于读取迟到，也没有放宽校验器。

沿用既有标准 database v3 修复器，在同一文档、相同2个表格 block ID 上生成9,660字节固定 delta；新增10个行块，48→58块。离线重复应用到原快照后 strict v2 规范树与源相等，原非表格块逐字段不变。冻结方案为 `repair-frozen-manifest.json`，候选和变更明细保留在本目录。

2026-09-09 10:59:51+08:00，经过 source/git/title/namespace/public=false、HTTP原生快照与Socket版本、原配置与journal围栏后，仅发送 **1次** 官方 `space:push-doc-update`。执行前持久化并 fsync 唯一intent；该脚本拒绝再次apply。真实读回与冻结候选相同：

- 修复前 native SHA-256：`c1731142a6e7addf680146ffa07ccd7dd4e00403e3f37aa23d93df61bbd9e634`
- 固定 delta SHA-256：`d37a5609a0202c490932874a3fb2693f8637e1e2d0afd5af75e3ed0e65629202`
- 修复后 native SHA-256：`975dc8c456a655728f7fff65cbc97bd61f5fc9755d6e1c7b1766f99e66b91458`
- 源/目标 strict v2 canonical SHA-256：`d3fd186277707d68b6c3c72050151c5057687a702f04482b6815a3888bc01b9d`

正式原binding对账只追加 sequence4 `native_verified`，原6行journal前缀和Docmost3条记录不变；再次只读对账无追加，最终原生raw/version/hash与正式回执匹配。Markdown导出仍不与源字节相同，因此明确使用 native_verified，不宣称原Markdown字节保真。这里的结构证明不是原生页面布局验收或数字签名。

修复前后保护既有7份源文档、14份投影、6组私有配置和journal、原来源ACL，均与冻结baseline相同。没有新建第二份源或AFF目标、发送聊天、调用模型或派发Outbox。本条仅签收AFF；Docmost当时仍为已知ID的unknown，由独立任务诊断。

主要证据：`diagnostic-affine-source-diff.json`、`repair-candidate-report.json`、`repair-frozen-manifest.json`、`repair-live-readback.json`、`affine-formal-reconciliation.json`、`repair-before-old-scope-check.json`、`repair-after-old-scope-check.json`。
