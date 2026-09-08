# 语音缓存父目录初始化修复 · 2026-09-07T13:16:13+08:00

本记录是对当天语音集成审查的新补充，保留历史文档。Active Agent 基准 commit `1774c284ba41d5db71ed77a4b905bd3db1c0369f`，Git 时间 `2026-09-07T12:18:30+08:00`，描述 `docs(office): record mobile group fidelity and native verification limits`。配套 Doc Free 基准 `55967f5234568d80cee36d836f06b942cb3db0b1`，同一 Git 时间，描述 `docs(im): publish mobile group fidelity protocol and delivery receipt`。两库分支均为 `equal_rights`；本修复等待主任务统一提交，不把基准冒充实现 commit。

主任务在真实 Mac 客户端点击“开始录音”，新诊断明确显示 **`VR-storage-filesystem`**，界面为“无法准备录音存储空间，请重试”。此前泛化失败没有指出阶段；本轮只处理已经确认的临时存储故障，不修改诊断源码、字体、头像或分组 UI。

## 原因与修复

直接阅读本机实际安装的 `path_provider_foundation 2.6.0` 源码：`getTemporaryPath()` 返回 `_getDirectoryPath(NSCachesDirectory)`，macOS 会在缓存路径附加应用 bundle ID，但这个方法并不创建该目录。与之不同，`getApplicationCachePath()` 明确调用目录创建。语音存储此前拿到路径后直接 `parent.createTemp('renji-voice-')`；当父目录尚不存在时会抛 `PathNotFoundException`，errno 2。

新增真实磁盘测试先复现该失败：缺少缓存父目录的录音路径、并发初始化和迟到关闭均失败；另发现初始化 Future 的失败会一直缓存在 `_creating`，即使文件系统已经修复，同一个存储实例仍不能重试。初次 5 项测试为 1 通过、4 失败，日志 `/tmp/renji-voice-storage-before-fix-20260907.log`。

`lib/voice_audio_storage_io.dart` 现在先 `await parent.create(recursive: true)`，再创建仅属于本次语音存储实例的随机 `renji-voice-` 子目录。初始化失败时清空 `_creating`，允许用户修复文件系统后在同一实例重试；并发成功初始化仍复用同一 Future 和目录。

清理范围保持精确：release 只接受本次实例登记的路径，close 只删除自己的随机子目录，不删除 path provider 返回的缓存父目录、不删除同级文件、不清理其它会话。父目录由本轮创建时，close 后仍保留父目录。为了直接验证这些真实文件系统行为，IO factory 增加可选的临时目录提供函数，默认仍为生产 `getTemporaryDirectory`，没有新依赖。

## 已验证

`test/voice_audio_storage_io_test.dart` 的 5 项真实磁盘检查全部通过：

1. 不存在的多层缓存父目录可初始化；录音文件实际写入、读取、删除，播放文件实际落盘且字节一致。
2. close 删除自己的语音目录，同时保留缓存父目录、无关文件和其它会话的文件；未登记路径不能读，也不会被误删。
3. 并发首次创建复用一个目录，生成不同文件名；读取超过调用方大小限制被拒绝。
4. 初次路径被普通文件阻塞时失败，移除该阻塞后，同一存储实例可以成功重试。
5. close 与迟到的 path-provider 查询交错时，返回的自有临时目录会清理，不留语音文件。

```text
flutter test --no-pub test/voice_audio_storage_io_test.dart test/voice_audio_service_test.dart
26 tests passed
日志：/tmp/renji-voice-storage-after-fix-20260907.log

flutter analyze --no-pub lib/voice_audio_storage_io.dart test/voice_audio_storage_io_test.dart
No issues found, 1.6 seconds
日志：/tmp/renji-voice-storage-analyze-20260907.log

git diff --check
通过
```

实际使用 SDK 为 `/Users/lwblx/development/flutter/bin/flutter`。本子任务没有构建、操作 GUI、读取现有业务数据或清理真实应用缓存；测试只创建并删除自己的临时测试根目录。

## 原生复测与当前优先级

修复已交主任务热更新复测。旧版已打开的语音面板可能仍持有失败的 `_creating` Future，hot reload 会保留这一对象，因此首次验收应关闭并重新打开语音面板，生成新的存储实例；新版初始化失败后的重试则不再永久缓存旧失败。此步骤无需重启后端。

上述结果证明临时存储初始化及磁盘读写修复，不冒充修复后真实麦克风、声音播放或发送已经验收；实际原生结果由主任务追加回执。用户最新的 **100% 字号与圆形头像** 调整仍由另外两项客户端任务优先推进，本文件只记录独立语音存储修复，不改变其 UI 分工和优先级。最终全量检查待这批修改冻结后统一进行。
