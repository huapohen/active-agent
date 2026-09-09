# 人机 startup 消息交互阶段：文档同步与最终验收回执

记录时间：2026-09-09T08:31:32+08:00。分支 `startup`。本回执记录已发生的发布、表格修复和独立读回，不覆盖之前的失败记录，也不把未完成的商业消息界面验收写成通过。

实施提交为 `50570cac03b1314c831fc856e6ed826f60486fa8`，时间 `2026-09-09T07:55:18+08:00`，描述 `feat(startup): deliver native replies reactions and authenticated emoji`。主文档与附件的冻结提交为 `28187632b76bce6d0f45a6c1b3f8fb1755b9773a`，时间 `2026-09-09T08:19:20+08:00`，描述 `docs(startup): record message phase and verified Clerk login`。本次没有新增运行代码变更。

## 已发布文档

[主交付文档](STARTUP_MESSAGE_INTERACTIONS_DELIVERY_0817.md)已在 Doc Free 创建 `31bb33b9`，版本 1，所属受控会话 `room-1de8fc2a-eed0-438b-98c3-b79c8997859e`。源文档创建时间为 08:19:48 +08:00。全部 18 处相对链接转换为冻结文档提交的不可变 Git 链接；逆转换后恢复原始 Markdown 字节。

| 位置 | 本次结果 |
| --- | --- |
| Doc Free | `31bb33b9` r1；人类与 Agent 读取完整 JSON 相同，非成员 HTTP 403 |
| AFFiNE | [阶段文档](http://127.0.0.1:3010/workspace/a901cbc0-59ac-40b6-86bf-fcca7ff7b619/bGCK2yAAKIJTKrJDgZId0)；同一新 ID 完成表格修复与原生结构核验 |
| Docmost | [阶段文档](http://127.0.0.1:3021/p/8kdEVzWuIf)；目标 ID `01a0838f-b37f-75b2-8f7c-3d3b603ccb4e`，原生结构核验通过 |

这些是本机服务链接，继续受现有账号与命名空间权限约束，没有改成公共分享。本轮只新增 1 份源文档、1 份 AFFiNE 投影和 1 份 Docmost 投影；没有重建旧文档或发送聊天消息。

原始主文档 SHA-256：`d7631c24500acee1f40caf6194f33ab3f070bc3efe06f8889e260b1f624e91c5`。链接展开后的正文 SHA-256：`c5437c9b9ccf409feac46a077f186b48e70bd5d807a1fd9925d5e386bc0e8716`。Doc Free 去掉末尾换行后的实际正文 hash：`f6510b3ba5a4d2503b14ea1f28d185961372e5902fe0a2da1356fc574ad630d8`。不同 hash 对应明确的不同字节形态，没有将它们混作同一个值。

## AFFiNE 两张表的同 ID 修复

第一次同步明确失败并停止：官方 Markdown 导入产生 `affine:table` v1，两张表共出现 67 处 canonical 路径差异，涉及 8 个表头角色和 33 个行内代码标记。18 个普通链接（包括 PNG 文件链接）和全部非表格正文一致。失败记录保留在本次 journal，不改写成最初即成功。

复用已有表格修复能力，先离线生成 database-v3 候选并验证完整原生结构。仅向本次 AFFiNE 目标上传一次固定 17,455 bytes 的 Yjs delta，时间为 08:26:32 +08:00；保留两张表的 block ID、54 个原非表格块，增加 19 个行块。执行前校验源 r1、正文、权限、目标版本、旧范围和原 journal，写入前持久化单次意图。没有重新创建目标或放宽结构比较。

写前原生快照 SHA-256 为 `56dc99ac3a86738b426e9279bdc7c941f89df3c671f22224fcc439fcb0fc9276`；固定 delta 为 `4c7d1f7fc7dbae1b4cd043e2b627fce1d0403217c88112a414d7eed934a1b07d`；写后为 `d111014af0a3b3ab2585eb35be6aa3c1e7017cbc67ed71dd244a67b57cb88efd`，与离线候选逐字节相等。严格访问 75/75 个块，无未访问或未知块。修复本身没有写 Go journal；后续同步程序只读核对已有 AFFiNE ID，再首次创建 Docmost 投影。

## 独立验证与保留差异

两端原生 canonical 均与源相等，SHA-256 为 `523d8984a1367ed954e9df89cf6a5fdfbe944221eeddb4d079f6cd8f46d61fc3`。采用 `affine.database-v3.code-v1.rich-text.b4c8548c0.v2` 与 `docmost.prosemirror.gfm-code.goldmark-1.8.6.v2` 的既有严格规则，没有因本次发布改变规则。

Docmost 原生内容 SHA-256 为 `510fd7ad5e342fd969ffe124c210c06d8fea911f8761b31fb7bec987580b64d9`，版本 `2026-09-09T00:27:08.026Z`。54 个平台差异来自 18 条链接各自的 `target=_blank`、`rel=noopener noreferrer nofollow`、`internal=false`；平台字段单列，没有删除或误当源作者内容。

两个平台的 Markdown 导出仍为 `readback_mismatch`，导出字节不等于源 Markdown。具体包括 AFFiNE 两表前导出空 `###`，Docmost 导出插入空表头并将实际表头移为下一行。通过的是原生文档结构、文本、格式、表格和链接模型的比较；没有声称导出 Markdown 字节完全保真。原生目标版本、标题和原始内容 hash 又与最终回执精确比对，避免把较早验证结果用于后来变化的文档。

旧 5 份 Doc Free 源、10 份目标投影、4 组配置及 journal、受控会话成员与权限均保持。第二次同步只读幂等，没有追加 journal。最终本轮 journal 共 8 行，SHA-256 为 `ee8907190a3c6462c8c8831ebeb965288a58744a33bec5927b411736a2f8bb53`。主线程 08:28 再次按人类、Agent、非成员分别读取源，确认 200/200/403；子任务 08:29 独立读取两端原生内容及导出，确认与回执和冻结正文一致。

[全部发布与修复证据清单](evidence/message-interactions-publication/MANIFEST.json)包含原始 journal、失败差异、固定 delta、原生快照、脚本审计副本、独立读回和实际截图。归档脚本仅供审计，不能从 docs 目录直接运行；完整凭据和单次操作状态仍只存在于被 Git 忽略的私有目录。

## 人类可见结果与阶段边界

主线程在 Chrome 中用原有真实人类账号进入“现有数据迁移 → 云文档”，打开本次标题、r1 正文、两张表和 18 处不可变链接，并保留[实际阅读页截图](evidence/message-interactions-publication/source-document-native.png)。这是 Doc Free 源文档的真实人类阅读验收。Chrome 当前会话无 AFFiNE 私有命名空间访问权，故未宣称 AFFiNE 浏览器画面已验收；没有为了查看而改变共享权限。

用户已亲自完成 Clerk 真人与邮箱验证；Electron 新商业账号的登录和持久 Human 身份已验证，桌面保持登录。新账号昵称仍为“新同事”，尚无工作空间或会话；商业建群、昵称设置、商业消息 GUI 实测、普通客户端的融云连接，以及完整跨端办公能力仍待后续阶段。机器真实只读验收、受控融云命令受理和代码测试不能代替这些尚未完成的项目。

本阶段至此收尾，供用户验收。完整技术目标继续保留，未标记为全量飞书复刻完成。[更新后的手动启动教程](MANUAL_STARTUP_GUIDE.md)包含服务、Electron、Flutter 模拟器与表情目录配置。
