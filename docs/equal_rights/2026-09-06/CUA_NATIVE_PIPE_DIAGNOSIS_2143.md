# 飞书与手机镜像实机控制的官方管道诊断

- 记录时间：2026-09-06 21:42:51 +08:00。
- 分支：`equal_rights`。
- 已提交基础：`345bfad`，2026-09-06 20:40:31 +08:00，`docs: record folded conversation and broadcast delivery`。
- 本文是基准提交后的独立诊断记录，不是飞书实机操作验收。

## 结论

官方 CUA 的 native pipe 在建立认证连接时失败。服务可自动启动，磁盘及运行中签名均有效，但 ChatGPT 宿主无法读取管道对端的签名身份，服务端随后拒绝发送方认证。问题发生在进入应用和屏幕读取之前，本轮未能读取或操作桌面飞书、已连接的手机镜像。

## 实际证据

1. 主集成端此前已对唯一服务进程 65622 执行 TERM，再通过官方 app 启动，并执行 `js_reset`；`getState/getApp Lark` 仍返回 `Sky Computer Use native pipe startup failed`。这是主集成端已完成的动作，本次诊断没有重复该手动重启。
2. 本诊断首次进程检查时没有 SkyComputerUseService。21:39:43 再调用一次官方 `cua.getState()`，21:39:46 自动产生服务进程 73990，父进程为 launchd；调用仍失败。这个进程由官方控制调用拉起，不是本次诊断用 `open` 手动产生。
3. 同时间 macOS unified log 中，SkyComputerUseService 73990 反复输出 `Sender process is not authenticated`，伴随 Security `UNIX error exception: 2`。
4. ChatGPT 宿主同一秒的日志给出更精确错误：`browser-use native pipe peer authorization failed`，原因 `failed to read peer code signing identity`。21:22 与 21:38 也存在同类记录，不能将问题归因于本次自动启动。
5. `codesign --verify --strict` 确认磁盘上的服务、客户端、ChatGPT.app、内置 Codex、npm 安装的 Codex 都有效，官方 TeamIdentifier 为 `2DC432GLL2`。`codesign --verify <pid>` 进一步确认旧/新客户端、当前服务及两套 Codex 运行中的代码均动态有效，且满足自身指定要求。

版本记录：

| 组件 | 版本 |
| --- | --- |
| ChatGPT / Codex 桌面宿主 | `26.901.51231`，build `8109` |
| SkyComputerUseService | `26.831.1000926`，build `1000926` |
| SkyComputerUseClient | `26.831.1000926`，build `1000926` |

发现部分旧客户端仍映射更新前 inode，而新版客户端映射当前磁盘 inode；两组的动态签名验证都成功。仅凭文件 inode 不同不足以证明旧客户端损坏，因此没有为了猜测性修复终止任何旧客户端。

当天另有三份早前服务崩溃报告，时间为 10:17、11:00 与 17:11，包含 SIGSEGV/SIGABRT。它们只说明此前服务存在崩溃历史，不能用于证明本次认证失败由同一缺陷引起。

## 已执行与后续恢复边界

本次仅执行官方 CUA 一次连接重试、进程/版本读取、日志筛选和 macOS 官方静态/动态签名验证。没有修改服务文件、权限、授权数据库、代码签名或安全策略，没有终止 ChatGPT、Codex、飞书、手机镜像或用户其他任务，也没有通过 AppleScript、CGEvent 或自建接口替代 CUA 操作 UI。

自动拉起服务后错误仍然发生，重复重启 helper 已无新增诊断价值。下一步建议在项目改动保存完成后，由用户正常退出并重新打开 ChatGPT/Codex 桌面宿主，使宿主管道及身份认证状态重新建立，然后通过官方 `cua.getState()` 验证恢复。这是剩余的恢复尝试，不保证重启必然解决。当前运行任务依赖该宿主，因此本诊断不自行结束它。

若重启后仍复现，应携带上述组件版本、错误时间和脱敏日志向官方报告。不得绕过 `Sender process is not authenticated` 校验来取得屏幕或应用控制能力。

## 证据位置

- 宿主日志：`~/Library/Logs/com.openai.codex/2026/09/06/codex-desktop-98ad69f8-16e8-44ab-9965-ec5d60e1de68-65504-t0-i1-125332-0.log`，21:39:46 对应 UTC `13:39:46` 的记录。
- 服务日志：macOS unified log，按 process `SkyComputerUseService` / `SkyComputerUseClient` 与上述时间过滤。
- 早前崩溃：`~/Library/Logs/DiagnosticReports/SkyComputerUseService-2026-09-06-*.ips`。

本文不复制整个宿主日志或任何用户聊天内容。办公 IM 的组件测试与构建结果需在各自交付记录中查看，不能替代此次尚未完成的飞书与手机镜像实机观察。
