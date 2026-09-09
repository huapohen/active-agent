# 本轮文档发布器独立只读审查

记录时间：2026-09-09 09:56，Asia/Shanghai。审查者只读取代码与已有证据，没有执行网络请求、prepare、publish 或重复离线测试，没有改动任何实现或历史文件。

审查冻结脚本：`publish.py`，SHA-256 `b3cfafd5895ac7a1586be02bb0204f5fb973ae951605361870b234e2e9ba80ef`。

文档提交：`3705fb59266ddaa25414fb0794ec292e6ff20239`；实施提交：`e975e94e900cc892e39ed52ac0ce94ccd71c6ea1`。独立本地读取 Git blob 确认主文档与工作区逐字一致，原始 Markdown SHA-256 为 `2364e3f62a0914d2ada94502febdc9b0ad7f1ffb05b7885bb68c128cdf532091`。

## 结论

在当前固定源空间、目标 namespace 和人工冻结发布范围内，未发现新增确定 P1/P2。历史 v1 兼容没有降低本轮新 v2 投影要求。此结论只认可脚本的保护与核验路径，不提前声明发布完成；首次只读 inspect 成功也不等于 prepare/publish 已执行。

## 源 POST 未知结果恢复

脚本在唯一非幂等源 POST 之前 fsync 保存 intent；网络、HTTP 或返回体不确定后，保留该 intent，不存在自动再次 POST 的分支。下一次只读查找不在旧六份 baseline 中、标题和精确正文一致且 revision 为 1 的唯一候选；零个或多个候选都失败并禁止重建。

已知目标 ID 先保存，再核对正文。因此正文或读取失败不会丢弃已知 ID 另造源文档。恢复采用受控空间中的唯一内容对账，不宣称来源 API 具有请求级幂等键，也不声称可在任意并发作者环境中证明某一次 POST 的归属。

发布过程由固定私有目录的非阻塞 flock 排斥并发进程，state 绑定完整 freeze hash。新映射 config 若已存在必须对象一致；CLI 的原 journal 保留已知 ID 和 unknown 状态。目标再次运行使用既有投影引擎的持久对账，不由发布器自行发起另一次目标创建。

## 旧 6 源、12 投影、5 配置与 journal

固定 source ID/provider 矩阵和数量防止漏项；六源完整对象哈希、Human/Agent 精确相等和非成员 403 均重新检查。已有 ACL、成员角色、禁用状态、房间种类和消息数保持前次基线。

保护链从上轮三个 artifact 的固定字节 SHA 出发，覆盖前五源/十投影/四配置原 baseline，加上上轮新源/双投影和第五份配置的独立 pins。五份 config 和 journal 都进行精确原始字节 hash 比较，旧 journal 不补写、不升级。

新增 `historical_native_profiles()` 只在固定 artifact/config/journal 哈希验证通过后，从再次读取并重新解析一致的旧记录中提取 profile；每个 provider 仅允许已知 v1/v2。provider 当前响应和调用者随意指定的字符串不能选用弱 profile。

旧 native 证明仍要求 source ID/revision/content hash、标题 hash、source/target canonical hash 相等、当前 native 原始字节 hash 和 target version 精确一致。Docmost 原生 JSON 内容使用 `raw_json_field` 提取原始字节，未用排序重序列化替代 Go 记录的 raw hash。AFFiNE 原生二进制 hash 与 sha256 version 对应。四个较早仅 verified 的投影保留原保护表示，不被静默升级成 native_verified。

## 新 v2 与冻结提交边界

`snapshot` 是显式传入历史 expected_profile 的调用点。新 `sync_once` 仍传固定 `PROFILES` v2，新目标最终 `match_native_receipt` 不传覆盖参数，因此继续严格要求 v2。源/目标 canonical、native raw、版本、标题和源修订检查全部保留。

`derive` 要求完整提交 SHA、实施提交为文档提交祖先、文档提交为 HEAD 祖先；用 `git show` 读取已提交正文并与工作区精确比较；实施提交的 SHA/时间/描述以及文档标题/记录时间必须存在。相对链接只允许已提交 blob，并改为同一个文档提交下的 immutable GitHub 链接；未支持的 Markdown 链接语法直接拒绝。

prepare 固定 original Markdown hash、链接改写后 body hash、source commit 元数据、原资源保护和 v2 profile。已有 state 后禁止重新 freeze。publish 必须同时提供已批准的原文和派生正文两个 hash，并匹配 freeze.delivery 与 state.freeze_hash。该保护固定的是所审发布正文及其协议，不能宣传为跨服务原子提交或长期阻止其他合法编辑者修改目标。

## 他方证据与本审查边界

实现者报告离线 15/15 回归通过；已读测试源码，覆盖旧八份 native proof、四份 legacy 不升级、新默认拒绝两份 v1、旧 pins/解析记录篡改和 raw/version/canonical/title/source/provider 不匹配。此审查者未重复运行，避免把同批检查再次累加。

已读 `read-only-inspection.json`：2026-09-09T01:55:22.020095+00:00，6 源、12 目标、5 配置保护通过，Human/Agent 同文档、6 次非成员拒绝、external_writes 为 0。仅引用该实际 inspect 回执，未以离线测试代替现场数据核验。

下一步应仍由根任务使用明确的文档提交和人工核对的两个正文 hash 执行 prepare/publish。任何核验失败保留 intent、ID、旧资源与 unknown 事实，不能手工改为 verified。

## 09:58 独立发布后只读复核

根任务随后完成唯一 prepare/publish，并授权本审查者做一次只读 postflight。以下是实际读取结果，和前述发布前源码审查分开记录；没有改写前文检查时的状态。

- 新源 `eb826242`，revision 1，Human 与 Agent 读取的整个文档对象相同，非成员为 HTTP 403；正文 SHA-256 为 `f19e67759e98c94bfdab0961ee4ae3584cfa10eb588adb37b98e49bb32aa56d5`，精确匹配冻结派生正文经服务端尾部 LF 处理后的 hash。
- 新 AFFiNE `0MDttZyU_BqyjzQMKqVLW` 和 Docmost `01a083e1-d4f7-7af2-a4d8-e537c7a14f69` 的当前原生 raw hash、版本、标题与 v2 native 回执逐项一致；两端 canonical hash 相同。没有用旧 v1 兼容选项核验新投影。
- 旧 6 份源文档、12 个旧投影、5 组 config/journal 与 freeze 保护基线一致；当前源目录精确为旧六份加本轮一份。
- 本轮 state、config、protection 与 journal 字节未变化。新 journal 仍为 8 行，SHA-256 `576bb50b0d661a7dbee3c4be0169808811848aa509ae90cbc960ed994c4271cd`。
- 共 45 次只读请求：38 次正常读取与 7 次预期非成员 403。调用 wrapper 只允许源 GET、AFFiNE 原生 GET/GraphQL query、Docmost pages/info 读取；禁止源 POST、同步 CLI 与状态写 helper。没有 sync、append 或外部写入。

实际起止时间：2026-09-09T09:58:52.799850+08:00 至 09:58:53.151720+08:00。独立结果 [independent-postflight.json](independent-postflight.json)，SHA-256 `c2531d665cbd990fd48c903067e15e7479b7194a19480c7043e0c2cf65901ce6`。本审查任务到此停止，不再次运行发布器。
