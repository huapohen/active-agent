# iOS 系统键盘发送与热加载连接边界 · 2026-09-07 10:52

记录时间：2026-09-07T10:52:00+08:00；分支 `equal_rights`。Active Agent 当前基准 commit `5a38f7fd42e2264f4896043cd35177aa9a8eb2ab`，Doc Free 当前 commit `6f4f8be7b43075a93db8d30a441d34508eef9276`。手机工具栏固定及键盘发送补丁仍等待主任务统一提交；本记录不新增源码修改。

实现落点补记：`c28c5422fa67b5b6490d206f3f05b26a70e9286d`，提交时间 `2026-09-07T10:59:56+08:00`，描述 `fix(office): relocate group toggle and stabilize mobile composer tools`。主整合的 662 / 662 全量测试和 analyze 已通过；本篇原生验收与该实现对应，不以热加载旧连接的状态代替重建后行为。

## 原生发现

主任务热加载补丁后，手机普通／Aa 工具栏已经固定，但此前处于焦点中的原生输入连接仍显示普通 return 键，点击后换行，未发送。此时组件测试通过不足以证明该旧连接可直接使用新配置。现场证据为 `output/renji-mobile-keyboard-typing-1050.png`。

只读核对本机 Flutter 3.47.2（framework `d3b14c8769`）发现：`EditableTextState.didUpdateWidget` 对已建立的输入连接在 `obscureText` 或 `keyboardType` 变化时调用 `updateConfig`，这一分支没有监听 `textInputAction`。本次热加载仅把显式 action 改为 send，输入类型仍是 multiline，因此旧焦点连接可能继续使用之前的 newline 配置。

新连接的 `textInputConfiguration` 会优先使用显式 `widget.textInputAction`，只有该值为空时才把 multiline 默认解析为 newline。故本问题属于开发时保留旧输入连接的热加载边界，不是 multiline 必然无法使用系统发送。

## 重建后的实际验收

主任务退出会话并重新进入，重建输入框与原生连接后，系统键盘显示蓝色向上发送箭头。点击后，`Stable toolbar 0907` 实际发送到本机合成验证会话，消息出现在会话记录中；输入草稿清空、输入焦点与软件键盘仍保留，常用工具行没有插入发送按钮。

- `output/renji-mobile-native-send-ready-1051.png`：重建连接后的蓝色发送键和待发送草稿。
- `output/renji-mobile-native-send-done-1051.png`：真实消息到达、草稿清空、键盘仍在。

两张原生截图已经由组件实现子任务只读复核。这次验收仅操作本机合成会话，没有向真实飞书企业会话发消息。记录中的消息文字是验证用固定文本，不包含凭据。

## 使用与验证边界

开发时更改 `textInputAction` 后，应使旧输入连接结束并重新建立，例如离开会话再进入；不能只依据已聚焦 TextField 的一次热加载判断最终系统键盘配置。此次不通过改业务逻辑或每次输入强制重建来绕过该现象。

`MOBILE_COMPOSER_SEND_STABILITY_1044.md` 中的 43 / 43 组件／截图验证与本记录的 iOS 原生实点互为补充。生产签名、其他系统键盘和其他平台实机仍需独立证据，本次不据此声明五端全部完成。
