# 原生区域截图桥接 · 2026-09-07 09:11

- 记录时间：2026-09-07T09:11:38+08:00。
- 分支：`equal_rights`。
- 基线 commit：`09fe83f19cdee6d242fd4903d1a76d4c451b491d`。
- 本文描述该基线后的未提交截图实现；最终实现 commit 在集成交付中补记。

## 实际能力

macOS 客户端新增 `renji/native_screenshot` MethodChannel，由 `OfficeScreenshotCapture.swift` 调用系统 `/usr/sbin/screencapture -i -s -x -t png`。用户使用系统十字光标选择区域，按 Escape 取消。这是原生交互截图，未使用文件选择器模拟截图，没有自动截取整个桌面。

图片先输出到应用临时目录下的唯一、权限为 0700 的子目录，检查普通文件类型、12 MiB 上限、PNG 标记和实际图片解码，然后通过 Flutter 字节通道读回。成功、用户取消、输出失败和子进程启动失败均清理该次临时目录。截图桥本身没有网络请求、附件上传或消息发送。

可选择“截图时隐藏人机窗口”。只有该次截图会隐藏当前应用；完成、取消或失败后恢复。系统区域选择器负责用户输入，未伪造鼠标点击。

## Flutter 合同

`lib/office_screenshot.dart` 提供：

- `OfficeScreenshotService().capture({bool hideWindow = false})` → `Future<OfficeScreenshot?>`。
- 成功对象包含 `filename`、`bytes` 和固定 `mimeType = image/png`。
- 用户取消返回 `null`，不会生成待上传附件。
- 失败为 `OfficeScreenshotException(code, message)`，保留权限不足、截图忙、未支持平台、原生组件未加载、无效图片和系统失败的区别。
- `capability()` 只读取是否可用及是否需要权限，不触发系统授权。
- `requestPermission()` 只能在用户主动操作后调用，用于展示系统屏幕录制授权；程序不能授予或绕过同意。

调用方仍须绑定发起截图时的身份、房间与草稿，等待选择结束后再次核对，再接入已有附件上传入口。不能把旧身份截图上传到用户后来切换的房间。

`OFFICE_SCREENSHOT_ENABLED=false` Dart 构建配置可以关闭客户端入口；macOS `Info.plist` 的 `RenjiScreenshotEnabled=false` 可关闭原生实现。其他平台返回明确未支持结果，未假称已具备 iPhone、Android、Windows 或 Web 系统截图。

系统截图若因用户按住 Control 进入剪贴板而没有输出文件，返回明确 `clipboard_only`，不会默默读取剪贴板或把不存在的图片当作成功。

## 验证与重启

- `python3 scripts/check_office_screenshot_native.py`：15 项原生参数、取消、权限拒绝、缺失文件、无效 PNG、成功 PNG 和超限检查通过；没有发起真实截图或系统授权。
- `flutter test test/office_screenshot_test.dart`：8/8，通过 MethodChannel 验证平台隔离、能力读取不触发授权、用户拒绝、隐藏窗口参数、取消、错误保留、组件缺失及非法输出。
- `plutil -lint`：Xcode 项目结构通过。
- 测试日志：`/tmp/renji-screenshot-native-checks.log`、`/tmp/renji-screenshot-flutter-tests.log`。

Swift 文件和新通道必须完整重建并重启 macOS 应用；Flutter 热重载不能给旧原生二进制添加截图组件。真实系统屏幕录制授权、区域选择、取消、隐藏窗口效果和截图上传仍需在重建后的客户端实点验证，本文没有将纯参数/输出测试当作实屏完成证据。

保留原有应用沙箱和权限设置，没有自动接受系统隐私权限，没有新增第三方依赖或启动额外模拟器。


## 最终实现提交索引

| 仓库 | 最终实现 commit | 实际 Git 时间 | 描述 |
| --- | --- | --- | --- |
| Active Agent | `7570ac2d81b119f14280fc4bf9866151b57e1059` | `2026-09-07T10:27:19+08:00` | `feat(office): align native composers and share rich conversation records` |
| Doc Free | `c34de6ac2e3ec67c7f10f3ef6e2090438d2598a0` | `2026-09-07T10:18:02+08:00` | `feat(im): preserve rich text across native actions and merged forwards` |

本文件中的早期专项或草稿状态按其记录时间保留。最终验证、原生实点与发布范围统一见 `COMPOSER_RICH_TEXT_MERGED_DELIVERY_1027.md`；本批最后Flutter全量为636/636，静态分析无问题。
