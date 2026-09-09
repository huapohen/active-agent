# 本轮发布前历史 native profile 不匹配诊断与修复

本次仅只读诊断、修改本轮新 publisher 和离线回归；未执行 prepare/publish，没有源/目标写入、旧配置或 journal 修改。

六份旧源 Human/Agent 全对象相同、nonmember 均 403。十二份旧目标的保护观察（标题、原生内容 hash、版本及可见性/namespace）均与上次固定回执相同；五份配置及 journal 字节未变。

唯一不匹配为 a74679d5 的两个历史正式 v1 profile：

- affine `SLrA9aXyZV-vehgtC91W-`：既有 `affine.database-v3.rich-text.b4c8548c0.v1`，新脚本误要求 `affine.database-v3.code-v1.rich-text.b4c8548c0.v2`。native raw 和 target_version 均完全匹配旧 proof。
- docmost `01a082b6-bade-7ef2-8bfc-02b75fcd97de`：既有 `docmost.prosemirror.gfm.goldmark-1.8.6.v1`，新脚本误要求 `docmost.prosemirror.gfm-code.goldmark-1.8.6.v2`。native raw 和 target_version 均完全匹配旧 proof。

当前 canonical hash 取自既有严格证明，当前原生字节与该证明的 target_native_raw_hash 完全相等；本次没有伪称重新运行原生解码器，也没有追加对账记录。

仅本轮 publish.py 新增 historical_native_profiles：先校验上轮三个 artifact 固定 SHA，再从其 baseline/receipt 确认每个 config+journal 固定 SHA；重新读取和解析 pinned journal，并要求 caller 中 latest 与原字节解析结果相同，最后才取对应 provider 的历史 v1/v2 profile。未知 profile 拒绝。新投影不传历史参数，仍默认严格 v2。所有 source/title/native raw/version/canonical 对账保持。

15 项离线回归通过，覆盖八份 native 历史证明、四份 legacy 不升级、新默认拒绝 v1、v2 正例、修改 pin/已解析 record、任意或跨 provider profile、原生 raw、版本、canonical、标题、源版本及正文变更拒绝。只读 `publish.py --inspect` 返回 inspection_only / old_docs 6 / old_projections 12 / external_writes 0。

详细脱敏字段和 hash 见 historical-native-diagnosis.json；回归代码为 test-historical-profiles.py。后续 prepare/publish 由根任务在独立审查后执行。
