# 生产签名、公证与预检 · 2026-09-06

- 记录时间：2026-09-06 15:10 Asia/Shanghai；分支 `equal_rights`。本阶段签名脚本尚未形成最终实现 commit，以对应 RELEASE/最终提交记录为准。
- 文档基线：`3beae3137c3193555360145300f81a0b5a1c888c`（2026-09-06T12:49:59+08:00）。上一阶段五端构建实际实现 commit：`2fad0ac68a05a39cf7d6abe55624b771bfa3ae62`。
- 描述：新增可配置生产发布脚本 `scripts/office_release.py`、Android release keystore 接线及只读预检。当前未执行生产签名、证书导入、Apple 公证提交或商店上传。

后续记录：**2026-09-06T16:07:16+08:00** 增加明确 Flutter 可执行路径、统一子进程工具解析及无效路径/plist 预检，发行专项测试更新为 7 项。当前 0.6 五端与签名状态见[独立待验台账](RELEASE_0_6_PENDING_1605.md)；下文 15:10 的 4 项测试结果保留为当时记录。

## 用法与产物

```sh
python3 scripts/office_release.py macos
python3 scripts/office_release.py ios
python3 scripts/office_release.py android
python3 scripts/office_release.py windows
```

默认仅只读预检：输出配置是否存在、证书类别/数量/指纹、工具与前提缺口。缺配置退出 `2`，不能自动改用开发证书。`ready_for_attempt` 仅表示基本前提满足，绝不等于 `distribution_verified` 或线上发行已经通过。

Flutter 不在 PATH 时，可通过 `OFFICE_FLUTTER` 指定可执行文件绝对路径（Windows 可指向 `flutter.bat`）。预检与执行按同一环境解析工具；覆盖路径不可用时直接失败，不自动使用其他 SDK。

只有显式加 `--execute` 才构建、签名；macOS 同时向 Apple 提交公证。执行前要求 Git 工作树干净且已提交。脚本不会创建证书、导入私钥、解锁 Keychain 或变更系统安全设置。用系统 Keychain/证书存储及部署环境配置供应凭据；禁止把 keystore、PFX/P12、密码、Apple API 私钥或客户端密钥放入 Git。把环境配置放入已忽略的 `.env.*` 也不会自动被此脚本读取，调用方必须安全注入环境。

产物位于 `output/production/<完整commit>/<target>/`，不会覆盖旧目录。成功才写 `PRODUCTION-MANIFEST.json`，记录源 commit、UTC 构建时间、验证项目、文件尺寸/SHA-256。失败目录没有成功 manifest，不能作为已验证发行包使用。工具原始 stdout/stderr 被捕获，避免工具打印证书个人信息或秘密；错误只报告失败步骤。供应链与商店发布审批由实际发行流程管理；这里不会自动上传应用商店。

## macOS

| 配置 | 来源/含义 |
| --- | --- |
| `APPLE_SIGNING_IDENTITY_SHA1` | 当前 Keychain 内 **Developer ID Application** 证书的 40 位 SHA-1 指纹 |
| `NOTARYTOOL_PROFILE` | 已配置在 Keychain 的 notarytool profile 名称；预检不联系 Apple，不因此证明该 profile 有效 |

执行：Flutter macOS release 构建 → 复制独立发布目录 → 内嵌 framework/dylib/bundle 从内到外签名 → 主 App 使用 `Release.entitlements`、hardened runtime 和可信时间戳签名 → `codesign --verify --deep --strict` → ZIP 提交 `notarytool` 并要求 `Accepted` → staple/validate → Gatekeeper `spctl --assess` → 重新打包含票据的 ZIP。

只有全部步骤通过才写 manifest。该流程不会把 adhoc、Apple Development 或未公证 ZIP 标记为 macOS 正式发行包。脚本使用现有产品 `Active Office.app` 名称；如以后重命名，需要同步构建产物路径。新增嵌套 helper 若需要自己的 entitlement，必须补充对应签名配置并实际验证。

## iOS

| 配置 | 来源/含义 |
| --- | --- |
| `APPLE_SIGNING_IDENTITY_SHA1` | 已安装 **Apple Distribution / iPhone Distribution** 证书指纹 |
| `APPLE_TEAM_ID` | 10 位团队 ID |
| `IOS_EXPORT_OPTIONS_PLIST` | 仓库之外的真实 Xcode export options plist 绝对路径 |

plist 必须选择同一 teamID 和发行方式（App Store Connect、release-testing/ad-hoc、enterprise 等）。**Runner target 的 archive signing、团队和有效 provisioning profile 仍须在 Xcode 中正确配置**；仅设置 shell 变量不会替你注册 bundle ID、安装 profile 或授权开发者账号。预检对该项明确标注尚需 Xcode 验证。

脚本调用 `flutter build ipa --release --export-options-plist ...`，没有 `--no-codesign` 回退。导出后验证 App 签名和 embedded.mobileprovision 存在，检查 entitlement 中团队相同、`get-task-allow` 关闭，并提取公开签名证书计算 SHA-1，要求等于配置的 distribution 证书。成功得到 `active-office-ios-signed.ipa`；没有 App Store 上传或上架承诺。

## Android

| 配置 | 来源/含义 |
| --- | --- |
| `ANDROID_KEYSTORE_PATH` | 真实 release keystore 的绝对路径 |
| `ANDROID_KEY_ALIAS` | 发布 key alias |
| `ANDROID_KEYSTORE_PASSWORD` | 环境注入 keystore 密码 |
| `ANDROID_KEY_PASSWORD` | 环境注入 key 密码 |
| `ANDROID_CERT_SHA256` | 本次发行明确允许的证书 SHA-256，64 位十六进制，无冒号 |

预检通过 `keytool -storepass:env` 读取公开证书指纹，密码不会出现在 argv。拒绝 Android Debug 证书以及与配置不一致的证书。执行时仅向构建子进程增加 `OFFICE_ANDROID_PRODUCTION_SIGNING=1`；Gradle 必須从上述环境取得 keystore/密码，缺少任何项直接失败。既有五端 CI 未设置该变量，仍是明确命名的 preview APK。

生产执行构建 **AAB**，通过 jarsigner 校验完整签名，再读公开证书要求指纹匹配，输出 `active-office-android-signed.aab`。使用 Google Play App Signing 时，此证书通常是 upload key；Play 分发证书由商店管理，应在实际发布管理中另外记录。脚本不会创建或替换 release/upload key，也不会上传 Google Play。

## Windows

| 配置 | 来源/含义 |
| --- | --- |
| `WINDOWS_CERT_SHA1` | Windows 证书存储中的 40 位代码签名证书指纹 |
| `WINDOWS_CERT_STORE_LOCATION` | `CurrentUser`（默认）或 `LocalMachine`，My store |
| `WINDOWS_TIMESTAMP_URL` | 正式配置的 HTTPS RFC3161 时间戳地址 |

需要 Windows host、Flutter、Windows SDK signtool，以及可用私钥的未过期 code-signing EKU 证书。预检只输出匹配证书数量/指纹，不读取或导出私钥。执行构建 WebRTC/Flutter Windows release，将发布目录复制到独立 output 后，使用配置的证书与 SHA-256 时间戳签署目录下 exe/dll，并逐一做 `signtool verify /pa /all`。结果为 `active-office-windows-signed.zip`。没有 PFX 密码 argv，也不会建立 Windows Store 应用身份。

## 本机只读检查结果

2026-09-06，本次执行 `security find-identity -v -p codesigning` 后仅保留脱敏元数据：

| 项目 | 实测结果 |
| --- | --- |
| 有效签名身份数量 | **1** |
| 身份类别 | **Apple Development** |
| SHA-1 指纹 | `4B3310C685527AC42F0E32B1A1DCAAB6F8051DC5` |
| Developer ID Application 数量 | **0** |
| Apple Distribution 数量 | **0** |
| notarytool | 已安装 |
| `NOTARYTOOL_PROFILE` 等签名脚本所需环境配置 | 本检查进程未设置 |
| Keychain 内是否存在未指定的 notary profile | **未确认**，不能据环境变量缺失断言不存在 |
| Flutter PATH | 当前普通检查进程未找到；本机其他构建使用的独立 SDK 路径应在发行进程正确设置 |

因此 macOS 正式签名、公证、iOS distribution export 当前均不满足已验证前提。Android release keystore 与 Windows production signing 配置也未提供，不能把此前的开发签名/unsigned 工件当作正式发行包。

## 已执行验证与边界

- `python3 -m py_compile scripts/office_release.py` 通过。
- `python3 -m unittest tests.test_office_release`：**4/4 通过**，验证全平台无凭据失败关闭、开发身份不得替代 Developer ID、Android 密码只通过环境引用/拒绝 debug key、工具失败内容不向输出转发。
- macOS 只读 preflight 实际执行，按预期退出 `2` 并列出缺口。
- 未执行真实 production signing、notarization、App Store/Play/Windows Store 上传；未在此 Mac 上声称通过 Windows 运行验证。

这一脚本提供可执行的配置入口和成功证据格式。只有真正提供发行凭据并运行对应平台的完整验证，才会产生新的生产签名成功证据。
