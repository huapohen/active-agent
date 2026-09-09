# 工作空间邀请阶段：归档回执与暂停交接

记录时间：`2026-09-09T11:08:31+08:00`（Asia/Shanghai）。分支 `startup`。本阶段应用实现及验收完成；按用户要求收尾后停止，等待验收。全量飞书复刻、五端商业迁移和全部 Agent 自主协作仍未完成。文档投影是部分通过：DocFree 源文档与 AFFiNE 已验证，Docmost 保留原 ID，严格原生校验待处理。

## 已交付代码与运行状态

- `30c6c22ce3ff24676d9d5a43bf1b3ce0cf14aafa`，`2026-09-09T10:33:54+08:00`，`feat(startup): invite human and agent colleagues with scoped arrival reads`：工作空间邀请、同一权限核心的 HTTP/MCP、Agent Run 范围内读取融云到达事件、实际会话摘要与时间。
- `313572c6881b488cccc6b943918d5598f2f9b5ae`，`2026-09-09T10:49:01+08:00`，`fix(desktop): support scoped invitation copy and accessible dialogs`：Electron 受限剪贴板写入、邀请弹窗单标题、滚动与关闭按钮可达性。
- `a58f429f9276a3fc4862fb71d6fba78d90b2a61c`，`2026-09-09T10:54:36+08:00`，`docs(startup): archive workspace invitation and native desktop acceptance`：冻结阶段报告、原生截图、测试与机器验收证据。以上提交均已推送。

[阶段报告](WORKSPACE_INVITATION_STAGE_DELIVERY_1035.md) 保存完整行为、权限和验证边界；[手动启动教程](MANUAL_STARTUP_GUIDE.md) 说明服务、电脑版与旧版手机模拟器启动方法。DocFree 源码保持 `dc728ddc99ce3bc7346bb4dc364824bbb32b1101`，本阶段未改动。

最终生产验证为 Go 267 个顶层用例与 316 个子用例通过、0 失败、0 测试跳过；Web 206/206、桌面 10/10，TypeScript、preload 和生产 Web 构建通过。各专题的定向测试与上述计数重叠，不累加。原生实际复制、粘贴、接受邀请成功；此次是已有 owner 接受本工作空间邀请，成员仍为 1、消息仍为 2，不能当作第二名真实同事已加入。

收尾时 API 3318 健康返回 `transport=rongcloud`，商业 Electron 保持 Clerk 登录，5173 和旧 DocFree 3218 服务仍运行。融云是必需依赖。受控 Human 桥已使用原配置恢复；本次 Agent 验收 Run 已按正常生命周期停止，没有留下模型 Worker 或新增 Outbox 派发。Agent HTTP/MCP 的实际读取一致，但没有配置 Agent SDK 接收覆盖，也未现场执行 Agent 接受邀请。最后一次原生登录画面见[截图](evidence/workspace-invitation-stage/desktop-final-logged-in-native.png)。

## 本次文档归档结果

唯一新源 DocFree `5a9aa3fa`，revision `1`，所属受控群 `room-1de8fc2a-eed0-438b-98c3-b79c8997859e`。标题为“人机商业阶段 · 工作空间邀请、Agent 接收读取与真实会话摘要 · 2026-09-09 10:51 · 30c6c22”。正文引用上述冻结 docs commit 中的文件，不跟随分支未来变化。

原报告 SHA-256 为 `88a74ec192c4144dd68018ba38800c50cd5ccb6dfa8689a5598bcea354471c54`；将 16 个相对链接转换为冻结 Git 链接后，发布体 SHA-256 为 `c0f329640b51519eb41eb07ec25b72a050b1e37217edfafa65243ce6c4b8813c`；DocFree 去除末尾换行后的正文 SHA-256 为 `521a8a9fea4227da08830163b8a26d856df3791e4923757cc9f12366a67a21c3`。冻结源没有为适配投影而重写。

[AFFiNE 投影](http://127.0.0.1:3010/workspace/a901cbc0-59ac-40b6-86bf-fcca7ff7b619/RBOpVVG9dPUzZIOl6BWNN) 保留首次创建 ID `RBOpVVG9dPUzZIOl6BWNN`。首次导入两个旧 table 块丢失表头角色和行内 code，未通过核验。使用既有 database v3 修复器，在原 ID 的两个表格块上只发送一次固定 delta；58 个原生块严格校验通过，46 个非表格块逐字段不变。没有创建第二份目标。

AFFiNE 原生 raw SHA-256 为 `975dc8c456a655728f7fff65cbc97bd61f5fc9755d6e1c7b1766f99e66b91458`，源/目标 canonical SHA-256 均为 `d3fd186277707d68b6c3c72050151c5057687a702f04482b6815a3888bc01b9d`。随后原 binding 正式对账只追加 sequence 4 `native_verified`；再次读取不追加。Markdown 导出仍不逐字相等，因此证明限于既定 v2 原生结构一致，不是 Markdown 字节往返或页面像素一致。详见[同 ID 修复回执](evidence/workspace-invitation-publication/AFFINE_SAME_ID_REPAIR.md)。

[Docmost 投影](http://127.0.0.1:3021/p/U5jo4yHLaW) 保留目标 `01a08419-805c-7585-b968-98329277c32c`，正式 journal 仍为 sequence 3 `unknown`、`readback_mismatch`；严格原生比较另返回 `unsupported_native_document`。唯一拒绝点为有序列表 `/content/22/attrs/type: null`，现有严格 v2 codec 不接受该属性。离线仅删除这一默认空值，其他字段保持，canonical 可相等；但实测部署 Tiptap 3.27.1 schema 往返会补回 `type: null`，不能以离线候选作为真实目标已修好的证据。

因此没有继续写 Docmost、创建替代目标、修改冻结正文或放宽原 profile。目标版本仍为 `2026-09-09T02:57:38.845Z`，native raw SHA-256 为 `7dcfbe5a4feee19dd79b2e0f72114508dae97f8dc48f2b17bcf1ee27fac5e30d`。该格式兼容问题明确留待用户验收后的新阶段。详见[只读诊断](evidence/workspace-invitation-publication/docmost-readonly-diagnosis.md)。

## 历史保护与继续工作的边界

原 7 份源文档、14 份投影、6 组配置与 journal、原来源 ACL 按冻结基线保护。本轮仅新增 1 份源和 2 个已知投影 ID，累计应保护 8 份源、16 个已知投影和 7 组配置；其中 15 个目标保持各自既有 verified/native_verified 证明，新增 Docmost 为明确未通过，不能将 16 个都当作成功。

11:08:56 最终只读核验确认：新源 Human/Agent 读取的完整 JSON 相同，非成员返回 403；源 hash 与冻结正文相等；AFFiNE raw/version 与正式证明一致；Docmost 原 ID、版本和 raw 保持。旧 7/14/6 及 ACL 均未变，新 journal 保持 7 行，收尾核验未调用同步程序或追加外部写入。

下一阶段须读取[保护交接](evidence/workspace-invitation-publication/next-stage-preservation.json)，保持旧 profile 版本与回执语义，先处理已知 Docmost ID 的状态。不要重跑旧发布器、盲目重建源或目标、直接把 unknown 改成 verified。最终只读结果见[收尾核验](evidence/workspace-invitation-publication/publication-closeout.json)，归档文件及实际哈希见[证据清单](evidence/workspace-invitation-publication/MANIFEST.json)。

本次归档没有发送聊天、邮件或飞书消息，没有模型调用，也未给新 Clerk 商业身份追加旧 DocFree 群权限。商业新账号与受控文档群身份没有自动合并。复制邀请成功也不代表用户此前报告的全局重复输入、中文输入法问题已经修复；本阶段没有作出该结论。

至此停止新增开发，保留服务和已登录桌面供用户验收。本回执如实保留 Docmost 未完成项，不将整体目标标为完成。
