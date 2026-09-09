# 工作空间邀请阶段：部分投影收尾

此回执明确为 **源文档已发布、AFFiNE 原生验证通过、Docmost 待处理**，不是双端全量同步成功。最终只读事实见 `publication-closeout.json`；后续保护清单为 `next-stage-preservation.json`。

冻结源报告来自 docs commit `a58f429f9276a3fc4862fb71d6fba78d90b2a61c`。新 Doc Free 文档 `5a9aa3fa` r1，Human 与 Agent 读取的整个 JSON 对象一致，非成员被拒绝（403）。正文与冻结派生正文只差服务端末尾 LF 归一化，内容 SHA-256 为 `521a8a9fea4227da08830163b8a26d856df3791e4923757cc9f12366a67a21c3`。

- AFFiNE 目标 `RBOpVVG9dPUzZIOl6BWNN`：同 ID 表格修复后，正式 strict v2 原生证明为 `native_verified`，再次读回 raw/version 与证明匹配。原 unknown 历史保留，修复详见 `AFFINE_SAME_ID_REPAIR.md`。
- Docmost 目标 `01a08419-805c-7585-b968-98329277c32c`：保留 sequence3 `unknown/readback_mismatch`，校验错误为 `unsupported_native_document`。实际 schema 在 orderedList 上补回默认 `type:null`，当前 strict profile 未覆盖；没有写目标、重建目标或放宽 profile。本次收尾两次只读检查其原 ID、版本、原生 hash 均保持不变。

保护范围累计 **8份源文档、16份已知投影、7组配置与 journal**。其中 **11份 native_verified + 4份历史 verified = 15份已验证；1份 Docmost unknown/pending**。新 journal 7行不再追加，既有7份源、14份投影、6组配置/journal及原来源 ACL 与 frozen plan 完全一致。整个最终核验没有外部写入、journal写入、同步/创建操作、聊天或模型调用。

后续不得把此 `publication-closeout.json` 当成声明全验证通过的 `publication-receipt.json`；不得以旧的“全部已 verified”发布器假设绕过这一 pending 目标。现有 Docmost ID 和原 unknown 记录必须保留，下一阶段只有在明确审核的解决方案下才能处理，不能以新建副本掩盖失败。
