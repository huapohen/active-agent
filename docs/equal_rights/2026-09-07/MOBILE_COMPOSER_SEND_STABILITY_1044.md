# 手机输入时工具栏跳动修复 · 2026-09-07 10:44

记录时间：2026-09-07T10:44:00+08:00。分支 `equal_rights`。Active Agent 当前基准 commit `5a38f7fd42e2264f4896043cd35177aa9a8eb2ab`，Doc Free 当前 commit `6f4f8be7b43075a93db8d30a441d34508eef9276`。此补丁记录时尚未提交，最终功能提交号由主交付记录补充。本文独立记录用户在 10:22 专项之后新发现的问题，不把早期全量通过当作本次修复验证。

实现落点补记：`c28c5422fa67b5b6490d206f3f05b26a70e9286d`，提交时间 `2026-09-07T10:59:56+08:00`，描述 `fix(office): relocate group toggle and stabilize mobile composer tools`。主整合完成 662 / 662 全量测试及 analyze；本文件保留的 43 / 43 是此前专项结果，两个范围不混写。

## 问题、参考与处理

用户发现手机输入文字后发送图标挤进工具行，导致其他图标同时移动。代码根因是 `_mobileComposerTools` 对同一条 `spaceBetween` Row 动态增加发送按钮，普通和 Aa 格式工具行的子项数都从 7 增到 8，所有间隔重算。

先补独立回归再修改实现：320／390 逻辑宽、键盘开／关、普通／Aa 工具行的 8 种组合全部复现失败。320 宽下第二个图标中心偏移 6.38 逻辑像素，390 宽下偏移 8.05，后续图标偏移更大。红测日志为 `/tmp/renji-mobile-send-stability-before.log`。

主任务在已恢复的 iPhone Mirror 实点真实飞书：输入 `test` 后工具行仍为 emoji、@、麦克风、图片、Aa、+，不插入发送按钮；Aa 格式行同样没有额外发送。参考证据为 `output/feishu-mobile-typing-stability-1036.png`。据此移除人机手机工具行里的动态发送按钮，保留 + 和 Agent 入口；没有用空槽、替换 + 或新增一条工具栏掩盖问题。

## 发送通路

手机紧凑输入框改用系统键盘 `TextInputAction.send`，`onSubmitted` 调用原有 `_send`。桌面发送按钮和展开编辑器的固定发送入口保持既有行为。手机硬件键盘仍执行用户配置的 Enter 或修饰键 + Enter 设置，系统键盘的发送动作独立可用。

自定义 `onEditingComplete` 保留焦点与 IME composing 范围；否则 Flutter 默认完成行为会先清除 composing，随后 `onSubmitted` 无法判断是否仍在候选词输入中。提交回调拒绝尚未结束的有效组合区，候选词真正确认后才发送。成功后保留输入焦点，方便继续对话。

所有发送继续共用现有身份／会话检查、连接检查、附件完成检查、幂等意图及同步发送锁。硬件 Enter 与系统发送动作同时抵达时只创建一次待确认发送；成功清空后迟到发送动作不会再次提交。空白、离线和未完成附件不会绕过原有校验。

## 验证

最终组合 43 / 43 通过，日志 `/tmp/renji-mobile-send-stability-final.log`：输入区 41、真实组件截图脚本 2。相关源码和测试 analyze 无问题，日志 `/tmp/renji-mobile-send-stability-analyze.log`。

- 8 条位置回归由红转绿：逐个记录空输入时常用图标中心，输入及清空后所有中心偏移均小于 0.1 逻辑像素，覆盖 320／390、键盘开／关、普通／Aa 行。
- 系统键盘发送成功、清空后不重发、焦点保留。
- IME 候选词未确认不发送且 composing 不被提前清空，确认后正常发送。
- 硬件 Enter 与系统发送共用一个待确认请求。
- 空白和离线草稿不提交，恢复连接后可以发送。
- 修饰键发送配置保持有效，普通 Enter 不错误发送。
- 既有富文本、展开标题、Agent 协作返回和原生截图回归继续通过。

重新捕获的真实组件证据：

- `output/composer-mobile-typing-render-1040.png`：输入 `test` 后普通工具行。
- `output/composer-mobile-cleared-render-1040.png`：清空后的普通工具行。
- `output/composer-mobile-format-typing-render-1040.png`：输入后的 Aa 格式行。
- `output/composer-mobile-format-cleared-render-1040.png`：清空后的 Aa 格式行。

文件名中的 1040 为运行标签，实际最终采集在本记录之前完成。截图没有伪造系统键盘；原生 iOS 键盘与客户端热加载后的实际点击验收由主交付记录说明。麦克风仍明确未接入，没有扩展语音功能。
