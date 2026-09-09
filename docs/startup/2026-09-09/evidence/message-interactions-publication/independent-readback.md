# 本阶段文档发布独立读回与表格修复

独立读回时间：2026-09-09T00:29:23.835123+00:00。实施提交 `50570cac03b1314c831fc856e6ed826f60486fa8`（2026-09-09T07:55:18+08:00，`feat(startup): deliver native replies reactions and authenticated emoji`）；冻结主报告提交 `28187632b76bce6d0f45a6c1b3f8fb1755b9773a`（2026-09-09T08:19:20+08:00，`docs(startup): record message phase and verified Clerk login`）。

源 `31bb33b9` r1 的人类与 Agent 完整对象相等，非成员返回 403。原 Markdown SHA-256 为 `d7631c24500acee1f40caf6194f33ab3f070bc3efe06f8889e260b1f624e91c5`，18 处相对链接转为固定 Git 提交链接后为 `c5437c9b9ccf409feac46a077f186b48e70bd5d807a1fd9925d5e386bc0e8716`；逐链接逆变换完整还原 Git 原文字节。服务端仅去除末尾 LF，实际正文 hash 为 `f6510b3ba5a4d2503b14ea1f28d185961372e5902fe0a2da1356fc574ad630d8`。

## 实际投影与独立证明

- [AFFiNE 同 ID 投影](http://127.0.0.1:3010/workspace/a901cbc0-59ac-40b6-86bf-fcca7ff7b619/bGCK2yAAKIJTKrJDgZId0)：`bGCK2yAAKIJTKrJDgZId0`。最终 raw snapshot SHA-256 `d111014af0a3b3ab2585eb35be6aa3c1e7017cbc67ed71dd244a67b57cb88efd`。完整 75/75 blocks，0 unsupported。
- [Docmost 新投影](http://127.0.0.1:3021/p/8kdEVzWuIf)：`01a0838f-b37f-75b2-8f7c-3d3b603ccb4e`。原生 content raw SHA-256 `510fd7ad5e342fd969ffe124c210c06d8fea911f8761b31fb7bec987580b64d9`，原生/Markdown/再原生读取均对应 `2026-09-09T00:27:08.026Z`。

独立 HTTP 读取的原生字节与两端正式 `native_verified` 回执对应；再次离线调用生产严格 codec，比对完整原生树，要求结构差异 0。三个 canonical hash 都为 `523d8984a1367ed954e9df89cf6a5fdfbe944221eeddb4d079f6cd8f46d61fc3`。覆盖两张表、8 个表头、81 个行内代码片段、18 个链接；本报告没有 fenced code，不能称为新增代码块验收。

Docmost 的 54 项平台行为差异是 18 个链接 × 3：`target=_blank`、`rel=noopener noreferrer nofollow`、`internal=false`；`class/title` 为 null。这些不是正文缺失，完整必需结构仍相同。AFFiNE 平台行为差异 0。这里只证明版本围栏内的原生结构与回执哈希一致，不是数字签名、原子跨平台事务或像素布局验收。

## 本次 AFFiNE 表格修复

首次导入保留已知目标 ID，并因严格校验失败留下 `unknown/readback_mismatch`。离线全树分析发现 67 个路径差异全部位于两张 `affine:table` v1：8 个表头角色和 33 处行内 code 丢失。非表格树完全相同，普通 PNG 链接没有丢失。

08:26:32+08 按根任务明确授权，仅发送一次官方 Socket.IO `space:push-doc-update`，固定 delta 17,455 bytes，SHA-256 `4c7d1f7fc7dbae1b4cd043e2b627fce1d0403217c88112a414d7eed934a1b07d`。保留两张原 table block ID，以官方 database v3 表达表头和富文本，添加 19 个行块；54 个原非表格块完全不变。源未改、目标未重建、旧资源未写。单次锁和 fsync intent 在写入前持久化；写后 snapshot 字节与冻结候选精确一致。

修复脚本没有改 Go journal。根任务随后恢复原 publisher，对同 AFF ID 正式对账并首次创建 Docmost。原 journal 前 3 行逐字保留（SHA-256 `ad671560eb92eb4a01d4196628cb2506dab034eb8c826a648916015c693c3273`），保留原 unknown 历史；当前共 8 行。

## 导出差异与保护范围

两端 Markdown 导出仍为 `readback_mismatch`。AFFiNE database 导出在两张表前增加空三级标题，并压缩表格空格；Docmost 导出在两张表插入空表头行，把真实表头移至下一行。原生结构仍保留正确表头与代码标记，不能把这些导出错误写成无损 Markdown 同步。

独立读回期间，旧 5 份源文档、10 个投影、旧配置/journal、受控 room ACL 均与冻结基线一致；新配置与 8 行 journal 也未改变。独立验收全程只读，未再运行 publisher、未调用模型或发送聊天。原修复写入与之后的独立读取分别计数。详细 hash、版本、链接和文件清单见 [independent-readback.json](independent-readback.json)；写入回执见 [repair-live-readback.json](repair-live-readback.json)，导出差异见 [AFFiNE diff](independent-affine-markdown.diff) 与 [Docmost diff](independent-docmost-markdown.diff)。
