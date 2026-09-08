# 2026-09-07 真实语音服务与会议音频占用

- 记录时间：2026-09-07 12:55:39 +08:00，Asia/Shanghai。
- 分支：`equal_rights`。
- 本轮基线 commit：`1774c284ba41d5db71ed77a4b905bd3db1c0369f`。
- 基线 commit 时间：2026-09-07 12:18:30 +08:00。
- 基线描述：`docs(office): record mobile group fidelity and native verification limits`。
- 本文描述：实现语音消息的设备录制、受控文件/Blob、真实 WAV 校验与波形、播放与会议占用协调；此文写入时本轮代码尚未提交，最终实现 commit 由整合提交记录补充，不使用基线冒充实现 commit。
- 关联调研：[VOICE_MEDIA_READONLY_SURVEY_1113.md](VOICE_MEDIA_READONLY_SURVEY_1113.md)。

## 本轮交付

`OfficeVoiceRecorder` 通过真实 `record` 插件录制 WAV，`OfficeVoicePlayback` 通过真实 `audioplayers` 插件播放鉴权下载后的字节。录制、播放、临时存储都有可注入接口，测试使用设备替身，产品默认使用平台插件。构造对象不会申请麦克风；仅 `startFromUserGesture()` 显式用户动作请求权限。

录制先占用音频、停止现有语音播放，再申请权限并启动设备。每个异步阶段重新检查会话身份与操作代数，权限弹窗或系统启动迟到时不会继续使用旧房间录音。系统中断、页面/账号退出、后台 hidden/paused/detached 都取消录制；计时到上限只停录生成待确认内容，不自动发送。录制时显示的振幅来自设备采样，停止后的波形来自真实 PCM 样本。

播放器只接收受控字节，不把带鉴权的远程 URL 交给媒体插件。新的播放先停止旧播放，暂停、恢复、拖动定位都绑定原消息操作代数；旧消息排队的控制不会影响新消息。完成、停止、身份退出、后台和设备异常都会释放受控临时源。

会议加入前取得 `OfficeVoiceMeetingLease`，等待正在申请权限或启动设备的语音录制完成取消，并停止语音播放。会议加入本身仍不开启麦克风、摄像头或共享；用户进会后另行开启。会议 `join / leave / capture` 共用生命周期队列，新的调用立即令旧 epoch 失效。迟到的 `getUserMedia` 返回必须先停轨并释放，后续会议才能继续。离开时在 capture、peer 音频关闭后释放 lease；旧 lease 不会解除新会议的占用。失败的 native stop + dispose 保留占用，防止另一个设备操作假定音频已经停止。已有会议未释放时，另一控制器无法取得第二个会议 lease。

## 真实音频契约

| 字段 | 本轮处理 |
| --- | --- |
| 容器/编码 | RIFF WAVE，PCM signed 16-bit little endian |
| 声道 | 1 |
| 请求采样率 | 16000 Hz；请求值不冒充设备实际值 |
| 实际采样率 | 按文件头，接受 8000–48000 Hz |
| 时长 | 从实际 PCM frame 数计算，默认上限 60 秒 |
| 大小 | 默认上限 12 MiB；存储读取前后均校验 |
| WAV fmt | 普通 PCM fmt16、fmt18（cbSize=0）、完整 extensible PCM GUID |
| 额外 RIFF chunk | 按长度和奇数 padding 跳过，拒绝溢出与截断 |
| 标准化 | 输出 44-byte 头的 PCM WAV，保留实际采样率 |
| 上限 overshoot | 只裁掉超出上限的真实尾部 frames，不伪造时长、不重新采样 |
| 波形 | 32 段实际 PCM 峰值 |

服务端由独立协议实现解析真实 WAV，建立 attachment 关联并计算消息音频元数据。客户端发送 voice attachment 关联，不以自己声明的采样率或时长代替服务端验证。转写能力不由此服务伪造。

## 平台处理与依赖

离线缓存解析成功：`flutter pub get --offline`。本轮未下载依赖、未请求外网代理、未开启真实麦克风。Pub 锁文件保留包管理器版本和完整性散列。

| 依赖 | 固定版本 | 用途 |
| --- | --- | --- |
| `record` | 6.2.1 | 录音、权限、振幅、状态 |
| `audioplayers` | 6.8.1 | 本地文件和 Blob 播放 |
| `path_provider` | 2.1.6 | 平台临时目录 |

- macOS/iOS 麦克风说明更新为：“仅在你主动录制语音消息，或加入会议并开启麦克风时采集声音。”
- Android 已有 `RECORD_AUDIO`，macOS Debug/Release 已有 audio-input entitlement，保持复用。
- macOS/Windows 生成插件注册已由依赖解析更新；iOS pod、native link、签名、公证与最终包仍须原生构建验证。
- IO 存储按实例创建 `renji-voice-*` 临时目录，记录精确拥有的路径；拒绝读取设备返回的任意外部路径，关闭只清理自己创建的目录。
- Web 仅接受当前 origin 的录音 Blob、创建自有播放 Blob，并在结束时 revoke。显式权限请求直接使用 getUserMedia，并总是停止权限探测轨道，避免部分浏览器不支持 Permissions API 的兼容性问题。Web 需 secure context；未通过真实浏览器麦克风与扬声器验证。
- Windows `record_windows 1.0.7` 的 PCM 写头实现使用 `WAVEFORMATEX`；fmt18 已兼容。其是否在本机 Windows 上实际生成正确头尚未验证，不能把静态插件检查写成 Windows 真机录音成功。

## 验证证据

2026-09-07 12:55 的定向验证：

- `flutter test --no-pub test/voice_audio_service_test.dart test/meeting_audio_focus_test.dart`：**26/26 通过**。
- 14 个本轮服务/会议/测试文件定向 `dart analyze`：**No issues found**。
- 已跟踪的本轮服务依赖、权限和会议文件 `git diff --check`：通过。
- 含最终会议整合的独立 Web debug 编译成功（19.5 秒），Wasm dry-run 成功。输出 `/tmp/renji-voice-web-20260907`，日志 `/tmp/renji-voice-web-build-final.log`；不覆盖当前运行客户端。

19 项语音服务测试覆盖真实 WAV 头/PCM/波形，截断与不支持格式，权限拒绝，迟到权限取消，迟到 native start，迟到 stop 身份变更，中断/后台，失败设备取消回退，单一播放与定位/恢复/完成，迟到播放，pause/resume/seek 错误，会议占用，严重 shutdown 失败保持占用，旧消息排队操作。

7 项会议测试覆盖 voice 权限取消等待且 join 不捕获设备；旧详情迟到时新 join 优先；迟到 join 的精确 session 清理；迟到麦克风与慢 stop 保持占用直到下一会议；stop 失败重试；join 失败释放；close 等待迟到设备且 renderer 只释放一次。会议测试没有创建真实 WebRTC peers 或连接远端会议。

测试异步说明：设备服务采用普通异步 `test`；`testWidgets` 的 fake clock 与已完成流取消 Future 组合会令驱动后续 Future 暂不推进，因此 UI 集成测试通过 `tester.runAsync` 运行真实服务异步，再用 pump 渲染。没有为测试修改生产状态机来跳过关闭设备。

## 尚未据此宣称完成的项目

本轮没有启动任何真实麦克风，没有向真实企业会话发送消息，没有验证原生五端听音、设备切换、通话路由或系统权限弹窗。自动化通过和 Web 编译成功，不能作为 macOS/iPhone/Android/Windows/Web 全部真机录音成功的证明。语音 UI、HTTP 消息协议、跨会话消息检验和最终原生构建由对应整合文档记录。
