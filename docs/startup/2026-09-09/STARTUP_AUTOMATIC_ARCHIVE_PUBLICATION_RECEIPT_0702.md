# 人机 startup 06:39 阶段报告发布回执

记录时间：2026-09-09T07:02:30+08:00。本回执补充已冻结的主报告，不改其原文、历史证据或旧投影。

阶段报告已新建为 Doc Free `7e81ae07`，版本 `1`，并在 AFFiNE、Docmost 各创建一个新投影。两端达到 **`native_verified`**：在指定版本化 profile 内，完整原生结构与源结构一致；两端 Markdown 导出仍是 **`readback_mismatch`**，没有声称导出字节一致或界面像素一致。

## 提交归属与正文来源

| 归属 | 实际提交 | 提交时间（+08:00） | 描述 |
| --- | --- | --- | --- |
| 实施 | `2fc663150ec66fa2c402e1a38668264f0d961e5a` | 2026-09-09 06:37:12 | feat(startup): automate execution archives and add native message actions |
| 冻结文档、发布时 HEAD | `ae128f4871937e7fc5c3a10bdf6c31692deca47d` | 2026-09-09 06:50:59 | docs(startup): record archive and message interaction phase evidence |

[冻结主报告](https://github.com/huapohen/active-agent/blob/ae128f4871937e7fc5c3a10bdf6c31692deca47d/docs/startup/2026-09-09/STARTUP_AUTOMATIC_ARCHIVE_DELIVERY_0639.md)保留原 H1 和日期。新文档标题为“人机 startup 阶段交付：自动归档、双端代码保真与消息交互 · 2026-09-09 06:39”。发布前仅将 6 个相对文件链接转为上述 docs commit 的 GitHub 不可变链接，已检查对应 Git blob；独立逆变换能还原冻结原文。六项映射见 [publication-receipt.json](evidence/automatic-archive-publication/publication-receipt.json)。

| 正文阶段 | SHA-256 |
| --- | --- |
| 冻结 Markdown | `2948d1f9a8c81b8e2f07ac8ff1775419221aa66a618bfda2066499c01c1ec6d8` |
| 替换链接后的派生正文 | `caa2a0daa326e144bb62bc7a05d74c99fc6f1ba141e46de4ef7fb988e70ad3c2` |
| Doc Free 实际正文（服务端仅 trim 末尾 LF） | `a3f858deb4def1f0767f4ed51bd54f6357d48ae576e33e901b0df665d44fd7d1` |

## 实际发布与读回

Doc Free 创建时间为 **2026-09-09 06:56:34+08:00**，发布核验完成时间为 **06:56:35.674753+08:00**。源会话为 `room-1de8fc2a-eed0-438b-98c3-b79c8997859e`，包含已授权 Human 与 Agent 两名成员。两次独立 HTTP 读回均得到 Human `200`、Agent `200`、相同完整文档对象，非成员 `403`。继承源会话可见性，未发布聊天消息。

| 目标 | 实际新 ID / 链接 | 原生核验时间（+08:00） |
| --- | --- | --- |
| AFFiNE | [pos1eudO5AYgYiEVx146t](http://127.0.0.1:3010/workspace/a901cbc0-59ac-40b6-86bf-fcca7ff7b619/pos1eudO5AYgYiEVx146t) | 06:56:34.654473 |
| Docmost | [01a0833c-cc3a-71aa-83f4-b29474708ce6](http://127.0.0.1:3021/p/GzQBbzDiOT) | 06:56:35.078114 |

目标映射分别固定在 AFFiNE workspace `a901cbc0-59ac-40b6-86bf-fcca7ff7b619` 和 Docmost space `01a08286-d2ee-75a6-82b2-cb68157cd32a`；AFFiNE `public=false`。这证明当前受控映射内的访问与投影，不代表源群 ACL 已自动跨供应商完全映射或撤权传播。以上链接是本机服务地址，需相应登录；Docmost 使用 3021 的独立 startup 实例，未迁移或覆盖原 3020。

两端及源完整 canonical SHA-256 均为 `496f4be4df4262477d98fec5732e8310c2f472eb81be25752d9d40cd4663a4d0`。AFFiNE 使用 `affine.database-v3.code-v1.rich-text.b4c8548c0.v2`，原生 snapshot hash 为 `4c0e8329e00123dceba4d598a4d8d95d4b112ddadb086c49405f04750c9b9936`；Docmost 使用 `docmost.prosemirror.gfm-code.goldmark-1.8.6.v2`，原生 raw JSON hash 为 `e32512c5952f7a0e1473b7bc0ccec16ea59a99089ad5a26d9a0d0893bfae038f`，版本 `updatedAt=2026-09-08T22:56:34.872Z`。

**06:57:58+08:00 的独立原生再读**与已验证回执的两端 raw hash 一致，源仍为 r1，journal hash 不变。这是哈希与版本对账，不是数字签名验证。主线程又在 **06:58:00+08:00** 独立 HTTP 复核源对象与 6 个不可变链接，并通过 Electron 云文档列表实际打开新报告，核对版本 1、06:56:34 时间、实施 SHA 与主要正文；[实际截图](evidence/automatic-archive-publication/desktop-stage-report-open.png)已留存，账号保持登录，正文为只读展示。

## 保真结论的边界

两供应商重新导出 Markdown 的序列化结果与源正文不同，原始导出 hash 和 `readback_mismatch` 均保留在回执中；此次通过的是独立的完整原生结构比较，没有把导出错误清空或升级为 byte-exact。AFFiNE 已分类平台差异为 0。Docmost 的 **24 项**平台行为差异是 **8 个链接 × 3 项**固定属性：`target=_blank`、`rel=noopener noreferrer nofollow`、`internal=false`；`class/title` 为 null。这些是明确列出的链接行为差异，不是正文缺失，也不与源等价冒充。

本次报告原生树包含 7 个 heading、33 个 paragraph、8 个 listItem、19 处 inline code，**没有 fenced code / codeBlock，也没有表格**。v2 profile 保留代码验证能力，但本次报告发布不能替代此前真实执行档案的 6 代码块验收；此前证据由正文不可变链接引用。

## 历史保护与交付证据

发布前后，4 份旧源文档（`25ae13fb`、`9d62380a`、`a74679d5`、`f6b5ff58`）完整对象指纹、8 份旧投影的标题/原生内容/版本，以及 3 套旧 config/journal 哈希均保持不变。新发布使用独立 intent、binding 与 journal，每处创建预算 1；未重跑旧 publisher、setup 或 worker，未改旧目标，未调用模型，未发送聊天消息。正常 GUI 登录可新增 session，因此本回执不宣称全局运行元数据不变。

新 journal 共 8 行，SHA-256 为 `de683e338d01b5be1ee3680754e931bb4e5cc24b0dddb76621c02cf7f3dcc0da`。对两个新 binding 的第二次核验返回原记录，没有追加或目标写入。原始中间 `unknown/readback_mismatch` 历史保留；最终追加的状态为 `native_verified`。

[本次独立证据清单](evidence/automatic-archive-publication/MANIFEST.json)保存冻结计划、结构化发布回执、派生与实际正文、两端原生快照、子任务及主线程独立读回、Electron 截图。清单逐项记录字节数与 SHA-256；配置凭据和发布 journal 原文件仍只保留在 ignored 私有目录。本回执和该清单为新文件，不修改已冻结主报告及任何旧 manifest。
