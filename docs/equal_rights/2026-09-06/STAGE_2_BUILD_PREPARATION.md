# 第二阶段五端构建准备（未启动构建）

| 字段 | 本次记录 |
| --- | --- |
| 记录时间 | `2026-09-06T12:11:10+08:00` |
| 状态 | 构建前只读核对；没有启动新编译、依赖下载或 GitHub Actions |
| Active Agent 当前 HEAD | `1ae44da253a9f097b02a7335678d485b285796cf`，`2026-09-06T10:44:22+08:00` |
| Doc Free 当前 HEAD | `134e0a78fc51345689be377004e793dd6a7fd71d`，`2026-09-06T10:42:30+08:00` |
| 当前开发状态 | 第二阶段企业、应用策略、账号与办公模块修改仍在工作树；应以最终提交作为新构建输入 |
| 本次描述 | 核对版本、CI、第一阶段干净隔离 worktree、可复用缓存和新 commit 的最短发布流程 |

## 1. 已核对的现状

- [pubspec.yaml](../../../apps/office/pubspec.yaml) 仍是 `0.4.0+1`。第二阶段应在最终源码提交前更新版本号/构建号；建议 `0.5.0+2`，由最终实现者决定并提交，本文没有修改版本文件。
- pubspec、pubspec.lock、[Office clients workflow](../../../.github/workflows/office-clients.yml)、[Windows WebRTC 预备脚本](../../../scripts/build_office_webrtc.py) 与第一阶段隔离 worktree 内容一致。
- Flutter 本地 cache 元数据为 **3.47.2 stable / Dart 3.13.2**；CI 同样固定该版本。Android 仍固定 Java 21、SDK 36、Gradle 8.14.3（官方 SHA-256）、AGP 8.11.1、Kotlin 2.2.20。
- 第一阶段 detached worktree 位于 `data/office-build-snapshot/1ae44da`，HEAD 精确为 `1ae44da253a9f097b02a7335678d485b285796cf`，`git status --short` 为空。
- 第一阶段 7 个归档仍位于 `output/builds/1ae44da/`，本次核对存在且字节数匹配原清单；此前 SHA-256、签名/包结构和 CI 双层哈希验证见该目录 `BUILD-REPORT.md` 与 `BUILD-MANIFEST.json`。本次没有把“存在且大小匹配”重新宣称成完整哈希校验。
- 只读查询到最近 Office clients run 仍为 [34007336316](https://github.com/huapohen/active-agent/actions/runs/34007336316)，HEAD 为第一阶段提交，结论 success；没有第二阶段构建结果。

## 2. 可复用缓存

| 缓存 | 本次观察与使用方式 |
| --- | --- |
| Flutter / Dart | `/Users/lwblx/development/flutter/bin/cache` 与 `/Users/lwblx/.pub-cache` 已存在；新 worktree 重新生成自己的 `.dart_tool`，不复制旧绝对路径配置 |
| Android | `/Users/lwblx/Library/Android/sdk` 已存在；项目隔离缓存 `data/office-build-gradle` 含 wrapper、caches、native 等目录，可作为 `GRADLE_USER_HOME` 复用 |
| 全局 Gradle | `/Users/lwblx/.gradle/caches` 存在，但本机全局 init 脚本可能注入仓库；优先继续使用项目隔离 Gradle 目录，不修改全局设置或清空缓存 |
| Apple | 本机 Xcode DerivedData 和 CocoaPods cache 存在，第一阶段 macOS/iOS build 目录保留；该快照没有 ios/Pods 或 macos/Pods，不能把它写成已有 Pod 安装证据 |
| 各平台旧产物 | 旧 web、macOS release、iOS device/simulator、Android APK 目录存在，保留作为第一阶段证据；不能把旧产物复制成新 commit 产物 |
| Windows WebRTC | 脚本固定 flutter_webrtc 1.6.1，对上游 zip 校验 8,804,772 字节及 SHA-256；CI 在 Windows 构建前执行 |

新 worktree 使用共享依赖缓存即可。不要整体搬运旧 `.dart_tool` 或各平台 build 目录来制造新 commit 的“完成构建”；这些目录含绝对路径和旧源代码产物。无需 `flutter clean` 或清空 SDK/依赖缓存。

## 3. 最短可校验发布步骤

1. **冻结两仓实现。** 完成当前企业应用策略与 UI 验收、合适的回归、版本更新及秘密扫描，分别提交两仓。记录 Active Agent/Doc Free 的完整 SHA、commit 时间、描述与 tree SHA；本次待实现动作设计不算已经接入默认 worker。

2. **让一次 push 触发五端 CI。** 工作流对 `equal_rights` 上 `apps/office/**`、Windows 预备脚本或该 workflow 的修改自动启动 Web、Android、macOS、iOS unsigned、Windows 五任务。第二阶段有客户端文件修改，推送即会触发，不再重复 workflow_dispatch。只有源码已在远端、且路径过滤没有触发时才考虑手动触发。

3. **按精确 SHA 查 run。** 使用 `gh run list --workflow office-clients.yml --branch equal_rights --commit <ACTIVE_SHA>` 找对应 run，检查它的 `headSha` 等于最终源码 SHA。相同 ref 的新 run 会取消旧 run，因此构建期间不推无关改动造成重复消耗。

4. **以这一个五端 run 作为发行构建。** CI 每个平台均执行 locked pub get、静态分析、Flutter 测试及原生 build；Windows 由真正 Windows runner 编译。本机无需再重复所有 5 个 release。若需要立即本地交互验收，只补必要的 macOS/Web 预览、Android debug 或 iOS Simulator debug。

5. **本地补充构建使用新干净 worktree。** 在 `data/office-build-snapshot/<NEW_SHORT_SHA>` 创建 detached worktree，checkout 精确 `<ACTIVE_SHA>`，构建前后记录 clean status。固定 Flutter 路径；Android 使用上述隔离 `GRADLE_USER_HOME`。锁文件未变时可先使用 `flutter pub get --offline --enforce-lockfile` 验证已有缓存。需要下载时按本机 AGENTS.md 先短时测速、动态发现并验证代理或可信镜像，保留已有缓存并依赖官方校验和/包管理器完整性校验。

6. **下载并校验 CI 产物。** 保存 run 与 job 元数据、GitHub artifacts metadata、5 份原始下载 archive。外层 archive SHA-256 匹配 GitHub artifact digest；解包后各平台 `active-office-build-manifest.json` 的 commit/target 必须匹配 run，内层包的字节数和 SHA-256 必须匹配清单。`gh run download` 的解包目录本身不代替原始 archive digest 证据。

7. **单独记录第二阶段产物。** 在 `output/builds/<NEW_SHORT_SHA>/` 写新的 `BUILD-MANIFEST.json`、`BUILD-REPORT.md`，关联两仓 SHA、工具链、CI URL、实际通过的测试、签名状态、包 hash 和本地额外预览。不要覆盖 `output/builds/1ae44da/`，不要把第一阶段测试数量或 Windows 产物沿用成第二阶段证据。

## 4. 固定的构建/封装合同

准确命令以已提交 workflow 和 [客户端 README](../../../apps/office/README.md) 为准。当前 Web 必须使用 `/office/` base href 与本地 renderer 资源；macOS 封装 `Active Office.app`；iOS 真机产物为 unsigned `Runner.app`；Windows zip 必须同时包含程序及 Flutter/WebRTC DLL；Android release APK 仍使用开发签名。

工作流内嵌 provenance/封装步骤，仓库没有 `scripts/package_office.py`。本地需要封装时复用 workflow 中的实际 tar/ditto/zip 操作与清单 schema，不依赖不存在的脚本。

这些产物仍是开发预览：macOS 未 notarize，iOS 真机 app 未签名，Android 未配置发行签名。五端 build 成功不等于真实音视频采集、跨网络会议质量、企业规模或应用商店发布已验证。
