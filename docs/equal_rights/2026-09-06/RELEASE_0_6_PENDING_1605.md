# 0.6 五端构建与生产签名待验台账

- 记录时间：**2026-09-06T16:07:16+08:00**（Asia/Shanghai；同日 08:07:16 UTC）。
- 分支：两仓均为 `equal_rights`。
- Active Agent 基线：`3beae3137c3193555360145300f81a0b5a1c888c`，提交时间 `2026-09-06T12:49:59+08:00`，描述 `docs: record office 0.5 release and verified native workflows`。
- Doc Free 基线：`862609f45d7d4e61c1b2a9c4d33fe527fd31b5e1`，提交时间 `2026-09-06T12:49:59+08:00`，描述 `docs: publish equal-rights 0.5 protocol and acceptance ledger`。
- 当前候选版本：Active Agent Python **0.6.0**；Flutter **0.6.0+3**；Doc Free **0.6.0**。本台账建立时实现仍在工作树中，**最终实现 commit 尚未形成**；上述 SHA 只是起点，不能成为 0.6 构建来源。
- 描述：为原生动作执行、企业认证入口、组织目录、原生会话富文本协作及“人机”客户端更新建立新的验收边界。记录当前测试、待构建项目和发行凭据缺口，避免沿用旧工件证明新功能。

## 五端证据状态

下表是建立台账时的快照。后续应在独立最终发布清单填写准确实现 commit、配套 Doc Free commit、CI run URL、版本、UTC 构建时间、每个工件文件名/尺寸/SHA-256、签名类别与实际启动验证。不能仅将状态文字改成“通过”。

| 平台 | 0.6 构建/工件证据 | CI 默认产物边界 | 正式发行仍需 |
| --- | --- | --- | --- |
| Web | 待精确提交的 CI 构建和摘要 | `/office/` 路径的 Flutter Web 静态包 | 对配套服务验证认证、业务动作、文档协作；实际部署另记来源 |
| Android | 待精确提交的 CI 构建和摘要 | 开发签名 preview APK | release/upload keystore、明确证书指纹、签名 AAB 校验及设备验证；商店提交另记 |
| macOS | 待精确提交的 CI 构建和摘要 | 未公证开发预览 | Developer ID Application、有效公证凭据、Accepted/stapled/Gatekeeper 验证及实际运行 |
| iOS | 待精确提交的 CI 构建和摘要 | `--no-codesign` unsigned App | Apple Distribution、团队和有效 provisioning/export、IPA 签名校验及设备验证；商店提交另记 |
| Windows | 待精确提交的 CI 构建和摘要 | Windows runner 构建的开发预览 ZIP | Windows 签名 host、代码签名证书私钥、RFC3161 时间戳、Authenticode 验证及实际运行 |

旧 [RELEASE.md](RELEASE.md) 与 [VERSION.json](VERSION.json) 记录 **0.5.0+2**。旧五端 CI run `34011406113` 的来源是 `2fad0ac68a05a39cf7d6abe55624b771bfa3ae62`，它们继续作为历史证据保留，不属于本轮 0.6。旧包解压或启动成功，也不证明本轮代码已构建、签名或通过业务验收。

当前 `.github/workflows/office-clients.yml` 能记录 Active Agent 源 commit、UTC 时间、目标、Flutter 版本及工件摘要，但尚未自动记录 App 版本与配套 Doc Free commit。最终发布清单必须补齐这两项配对信息。五个 runner 执行的同一 Flutter 测试集只算一组不同用例，不能把重复运行次数相加为测试数量。CI 构建成功不替代原生设备运行验证。

## 生产预检实测

本轮执行下列命令，均为只读预检，未加 `--execute`：

```sh
python3 scripts/office_release.py macos
python3 scripts/office_release.py ios
python3 scripts/office_release.py android
python3 scripts/office_release.py windows
```

四项均退出 **2**，`ready_for_attempt:false`、`distribution_verified:false`。本进程未设置各平台所需签名变量，普通 PATH 未找到 Flutter；Mac 检出 **1 个 Apple Development** 身份，**0 个 Developer ID Application、0 个 Apple Distribution**，notarytool 已安装。未建立任何未指定 Keychain notary profile 的存在性或有效性结论。Android release keystore 未配置；Windows 正式签名需在 Windows host 执行。

完整配置见 [生产签名说明](PRODUCTION_SIGNING_1510.md)。没有执行证书导入、私钥导出、签名、公证上传或商店上传。

本轮为 `office_release.py` 补充以下可用性修正：

- `OFFICE_FLUTTER` 可以指定 Flutter 可执行文件的绝对路径，含空格路径按单个 argv 传递；Windows 可以指向 `flutter.bat`。未指定时按子进程的 PATH 解析。预检与执行使用同一个解析函数，不读取其他项目的 `.env`。
- 相对 Flutter 覆盖路径直接拒绝，不悄悄回退到其他 SDK。iOS export options 与 Android keystore 要求可用绝对路径，避免调用目录与 Gradle/Xcode 目录差异。
- 非字典 iOS plist 作为无效配置返回预检缺口，避免抛出未处理异常。
- 实際 macOS `PRODUCT_NAME` 仍为 `Active Office`，`Active Office.app` 构建路径有效；“人机”是显示名称。将来改产品构建名称时，需同步 CI 与签名脚本。

示例仅说明路径变量，不含发行凭据：

```sh
OFFICE_FLUTTER="/absolute/path/to/flutter/bin/flutter" python3 scripts/office_release.py macos
```

本机未执行 Windows SDK 的实际调用；Windows 路径解析的实现修正不能宣称已经通过 Windows 原生签名验收。

## 本轮审查与验证

- 工作树保密模式扫描覆盖 Active Agent **243**、Doc Free **100** 个当时的 tracked 与未忽略 untracked 候选文件。发现两个类型的误报：`task-UUID` 后缀被无左边界的 `sk-` 模式匹配；旧 compose 数据库 URL 为环境占位模板。未发现上述模式所识别的实际完整密钥、私钥、数据库密码 URL、GitHub token 或 JWT。此结论只覆盖扫描规则与当时内容，不等于通用安全认证。
- 已为 `scripts/check_secrets.py` 的密钥模式增加左边界，并用隔离 Git index 验证：真实 `sk-` 形式仍拒绝且不打印值；`task-UUID` 不再误报。compose 环境占位模板保持原样。
- `python3 -m unittest tests.test_office_release tests.test_check_secrets -v`：**9/9 通过**（签名预检 7 项，保密扫描 2 项）。真实发行凭据和生产签名操作不在这些测试中。
- 最终入库前仍应对最终 Git index 执行保密检查，并把最终全套 Python、Node、Flutter 结果归入新的发布记录。本文不把并行工作中的中间测试数当作最终精确提交的总验收数。

企业 OIDC 已有可配置适配层和本地协议测试，真实企业身份提供方尚未连接；组织目录仍不是多租户隔离。原生富文本协作与动作执行的完整证据应链接本轮对应实现/验收文档。当前 README 或文档入口中的旧“仅 Markdown / SSO 尚无适配”描述，应由最终发布入口更新；历史 0.5 文档保持时间语义，不覆盖旧版本事实。
