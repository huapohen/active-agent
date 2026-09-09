# Clerk 开户与融云接收阶段：文档发布回执

记录时间：`2026-09-09T09:58:43+08:00`（Asia/Shanghai）。分支 `startup`。本记录只归档已发生的发布，不修改交付正文。

实施提交：`e975e94e900cc892e39ed52ac0ce94ccd71c6ea1`，`2026-09-09T09:35:36+08:00`，`feat(startup): onboard colleagues and relay verified RongCloud arrivals`。

冻结正文提交：`3705fb59266ddaa25414fb0794ec292e6ff20239`，`2026-09-09T09:53:05+08:00`，`docs(startup): archive Clerk onboarding and RongCloud receive evidence`。该提交及实施提交已推送到 GitHub。正文为 [Clerk 开户协作与融云真实接收桥](STARTUP_ACCOUNT_BRIDGE_DELIVERY_0943.md)；[手动启动教程](MANUAL_STARTUP_GUIDE.md) 和 25 份实施证据均已入库，包括被通用 `*.log` 忽略规则覆盖、此次精确纳入的验收日志。

## 发布结果

实际核验时间：`2026-09-09T09:56:51.656403+08:00`。在既有受控协作群 `room-1de8fc2a-eed0-438b-98c3-b79c8997859e` 创建一个新的 DocFree 文档 `eb826242`，revision `1`。标题为“人机商业阶段 · 开户协作与融云接收桥 · 2026-09-09 09:43 · e975e94”。Human 和 Agent 读取的完整文档 JSON 相同，非群成员请求返回 `403`。正文读取、标题和 source revision 均与冻结计划一致。

- [AFFiNE 投影](http://127.0.0.1:3010/workspace/a901cbc0-59ac-40b6-86bf-fcca7ff7b619/0MDttZyU_BqyjzQMKqVLW)，ID `0MDttZyU_BqyjzQMKqVLW`，按本项目 v2 校验规则，原生文档核验通过。
- [Docmost 投影](http://127.0.0.1:3021/p/2W94X6bqjJ)，ID `01a083e1-d4f7-7af2-a4d8-e537c7a14f69`，按本项目 v2 校验规则，原生文档核验通过。

两投影的 canonical hash 均与源一致：`af2f2130e8e6361e5f0a4c5e5b6934341e89e3419a170de64b3170be71c5702d`。AFFiNE 原生 raw hash 为 `61d5cd7b3439a1433e3e2af3a81c65a27912744ba046e261d468cb86fcc552b3`；Docmost 原生 raw hash 为 `a56d503ca8df8891e0f8269128a3bc90eaf29b15cac533e1fe39cd8461223065`，版本 `2026-09-09T01:56:50.548Z`。发布后重新读取原生内容和版本，与最终 native receipt 一致。

源 Markdown 的 SHA-256 为 `2364e3f62a0914d2ada94502febdc9b0ad7f1ffb05b7885bb68c128cdf532091`。将十个相对文件链接改为上述冻结 Git 提交链接后，发布体 SHA-256 为 `7d68387b21d2dca9e6fe19f255c6ac6d1806760a986a69763774907e65cd6813`；DocFree 去除末尾换行后的正文 hash 为 `f19e67759e98c94bfdab0961ee4ae3584cfa10eb588adb37b98e49bb32aa56d5`。这三个不同哈希各有明确含义，未用原文件哈希冒充发布后的内容哈希。

两端 Markdown 导出均仍返回 `readback_mismatch`；本次证明是原生文档树按既定 codec 的 canonical 一致，不是 Markdown 字节往返无损。Docmost 记录 30 处该 codec 接受的平台差异，AFFiNE 为 0；原始回执全部保留。本轮没有进行页面修补或放宽 native 判定，也未声称浏览器画面像素一致。

## 历史保护与重复执行

发布前后的六份旧源文档、十二个旧投影、五套旧配置及 journal 均保持原始哈希和版本。本次新增的文档同步 journal 为 8 行，SHA-256 `576bb50b0d661a7dbee3c4be0169808811848aa509ae90cbc960ed994c4271cd`；第二次同步读到相同结果，journal 未追加。发布没有发送聊天消息，也没有调用大模型。

发布前首次只读检查发现，本轮脚本将当前 v2 profile 误用于历史 `a74679d5` 的两个 v1 native receipt。独立对账确认历史 raw 内容、版本、标题、来源和配置均未变化。修复只作用于本轮发布器：历史版本由已钉住 SHA 的旧 artifact、配置和 journal 确定，重新解析的 record 必须逐项相同；本轮新目标仍要求 v2，所有 source、canonical、raw、version、title 检查保留。15 项离线回归通过，随后只读检查通过；没有修改旧源、旧投影或旧回执。

最终发布器 SHA-256：`b3cfafd5895ac7a1586be02bb0204f5fb973ae951605361870b234e2e9ba80ef`。新源 POST 前已持久化唯一发送意图；未知结果只允许读取匹配，不能重建第二份文档。已知 ID 在校验正文前先保存。所有文件链接锁定 `3705fb5`，不跟随未来 branch HEAD 变化。

下一阶段应累计保护七份源文档、十四个投影和六套配置。本次 [保护交接](evidence/account-bridge-publication/next-stage-preservation.json) 保存新配置、journal、源 JSON 和发布回执的哈希。不要复用旧发布脚本来重新创建同一标题。

## 发布后独立复核

独立审查于 `2026-09-09T09:58:52+08:00` 至 `09:58:53+08:00` 完成 45 次实际只读请求：38 次成功，7 次非成员请求如预期返回 403。新源完整 JSON 的 Human/Agent 读回相同；新投影的原生 raw、version、canonical、title 均符合最终 v2 回执。旧六源、十二投影、五套配置及日志保持；源目录严格为旧六份加本次一份，新 journal 仍为 8 行且哈希不变。没有调用同步程序、追加 journal 或作外部写入。

参见[独立审查](evidence/account-bridge-publication/independent-publisher-review.md)及[独立读回](evidence/account-bridge-publication/independent-postflight.json)。两个架构边界仍明确：本轮历史 profile 匹配只信已固定的旧证明；当前校验器没有用 v1 接受任何新投影。

## 可见性与验收范围

电脑端仍使用用户亲自完成验证的 Clerk Human，已打开“人机 · 新账号协作验收”群。该账号的商业文档入口与融云接收覆盖尚未接通；本回执发布在既有 DocFree 受控协作群，不能当作新账号已经获得该群权限。两种身份体系没有自动合并或提权。

本阶段已经重新读取并确认 Electron 中的昵称、两条中文消息、回复和表情回应。浏览器文档验收尝试遇到控制连接未附着，随后用户切换到飞书，故停止桌面点击。本次没有补记新的 DocFreeReader 浏览器画面，也没有修改 AFFiNE/Docmost 访问设置来绕过权限；投影结论来自实际原生内容和授权 API 读回。

独立复核与发布证据列于 [本回执证据清单](evidence/account-bridge-publication/MANIFEST.json)。本阶段收尾后停下供用户验收；完整商用、全量飞书复刻、五端和 Agent 主动协作目标继续保留，详见主交付中的未完成项。
