# Flutter 语音集成审查与会议退出重试修复 · 2026-09-07T13:09:27+08:00

本记录保存本轮独立源码审查和测试结果，接续语音后端及媒体 SDK 文档，不覆盖既有调查、截图或交付回执。Active Agent 基准 commit 为 `1774c284ba41d5db71ed77a4b905bd3db1c0369f`，Git 时间 `2026-09-07T12:18:30+08:00`，描述 `docs(office): record mobile group fidelity and native verification limits`。Doc Free 基准为 `55967f5234568d80cee36d836f06b942cb3db0b1`，同一 Git 时间，描述 `docs(im): publish mobile group fidelity protocol and delivery receipt`。两库均为 `equal_rights`；这些基准不冒充本轮尚待统一提交的语音实现 commit。

## 审查范围与确认

独立阅读了 `voice_audio*.dart`、`voice_composer.dart`、`voice_message.dart`、OfficeState 的语音上传 / 发送 / 播放接线，以及 `meeting_controller.dart`。此审查未构建客户端、未启动 GUI、未使用麦克风或真实企业数据。

录音草稿绑定身份 generation、endpoint、principal、来源 room 和 conversation selection。迟到的权限、stop 和 upload 回包不能把旧录音发送到新身份或重新打开的同名会话。上传意图与消息意图分别使用稳定 ID；已尝试发送但回执不明时，不自动删除可能已经关联消息的附件。后台、换身份和关闭面板会终止录音或试听。

消息播放先通过当前成员鉴权接口获取字节，再交给本进程临时文件或当前页面 Blob；不会把带凭据的远端 URL 交给播放器。OfficeState 的 scope 和 operation 编号排除迟到回包；气泡不可见、被替换或销毁时触发停止，播放设备本身也周期性检查当前 scope。插件权限撤销后 IM 模块清空房间与 selection，进而使原播放 scope 失效。该机制不等于服务器能追回已经传给设备的字节，本文也不宣称离线撤权能瞬时清除远端缓存。

音频 focus 用单一协调器互斥会议、录音及播放。会议先持有自己的 lease，再等待旧录音 / 播放停止；旧会议不能释放后来的 lease。关闭设备失败时保留占用，避免新录音抢占尚未关闭的设备。会议 join、leave、设备开关共用串行生命周期队列，迟到的麦克风权限回包先清理再允许下一次加入。

已直接阅读本机安装包源码，核对 `record 6.2.1` 的 `hasPermission(request:)`、`start(RecordConfig, path:)`、`isEncoderSupported`、录音状态与音量流，以及 `audioplayers 6.8.1` 的 `play`、`setReleaseMode`、position / duration / state / event streams，调用签名与当前依赖兼容。macOS Debug / Release entitlement 均包含 `com.apple.security.device.audio-input`；权限声明不能证明运行时已经授予麦克风权限。

## 已修复：设备关闭失败后丢失远端退出意图

原 `MeetingMediaController._leaveCurrent` 在设备关闭前将 `localSessionId`、`activeMeeting` 和 `_office` 清空。若 `_stopCapture` 或 peer 关闭抛错，音频 lease 会正确保留，但精确的远端 session 只存在于已经失败的局部调用中；第二次 leave 能释放设备，却不会再提交原 session 的退出，只能等待服务端 TTL。

先给既有故障测试加入“重试成功后必须发送原 session leave”的断言，实际得到 `Expected: session-a; Actual: []`，日志 `/tmp/renji-meeting-leave-before-fix-20260907.log`。随后新增 `_MeetingLeaveIntent`：在 join 回包时保留 OfficeState、原 identity generation / endpoint / principal，以及准确 meeting ID 与 session ID。可见会议状态仍及时清空；只有本机设备及 peer 清理成功后，才消耗 pending leave。原身份仍匹配时发送原 session 的 leave；身份或服务地址已变化时丢弃旧网络退出意图，不借用新身份 token。网络退出本身失败仍沿用既有 TTL 回退，不增加后台重试器。

`test/meeting_audio_focus_test.dart` 的原失败重试案例现确认：第一次失败不发 leave、focus 保留；第二次设备关闭成功后恰好发原 meeting/session 的 leave。新增三项分别覆盖同一 principal 重新登录但 generation 变化、endpoint 变化、principal 变化；这些情况下不提交旧 session，之后新会议仍能正常退出。

本轮会议变更只在 `lib/meeting_controller.dart` 与 `test/meeting_audio_focus_test.dart`。定向会议与语音 service 共 **29 项通过**，日志 `/tmp/renji-meeting-leave-after-fix-20260907.log`，`git diff --check` 通过；这两文件再次冻结。

## 全量测试与后续边界

在上述会议修复前、客户端两项并行任务确认冻结后，使用 `/Users/lwblx/development/flutter/bin/flutter` 实际运行：

```text
flutter test --no-pub
736 tests passed, 37 seconds
日志：/tmp/renji-voice-independent-full-flutter-20260907.log

flutter analyze --no-pub
No issues found, 3.0 seconds
日志：/tmp/renji-voice-independent-flutter-analyze-20260907.log
```

会议修复后的证据是上述 29 项定向测试，不将修复前 736 项全量结果冒充最新源码全量验收。

审查另发现 `voice_composer` 若对可能失败的 close / cancel / stop 直接调用 `unawaited`，设备关闭与 dispose 同时失败时可能产生未捕获 Future 异常，已向客户端负责人定位反馈。主任务同时在真实 Mac 验收中遇到录音启动泛化失败，客户端负责人正在增加安全阶段诊断；此记录不声称该运行时问题已修复或已通过真实麦克风验收。

随后用户要求优先修正 **100% 字号与圆形头像**，主任务已调整并行范围：Flutter 两个客户端任务优先处理 typography / shape，并以同宽原生截图指导。该最新用户要求属于本轮交付范围，本文仅记录优先级变化，不声称字体和头像修改已完成。按主任务安排暂停重复全量测试，待这批新 UI 修改及语音诊断冻结后统一运行最终全量检查；不拿现有语音测试替代原生字号、头像和截图验收。
