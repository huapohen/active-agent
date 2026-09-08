# 消息展示设置：移除多余可见提示行

记录时间：2026-09-07 12:56（Asia/Shanghai）。分支：`equal_rights`。记录时已提交基准为 `1774c284ba41d5db71ed77a4b905bd3db1c0369f`，时间 `2026-09-07T12:18:30+08:00`，描述 `docs(office): record mobile group fidelity and native verification limits`。本修改仍是工作区增量，最终提交由主交付文档补记。

主任务在用户解锁设备后重新操作真实Mirror与人机模拟器，生成 `output/renji-feishu-mobile-group-rules-native-unlocked-live-full-comparison.png` 和 `output/renji-feishu-mobile-group-rules-native-unlocked-live-focused-comparison.png`。本子任务已实际打开两张并排图后修改：飞书的说明下直接接四个单选项，人机多出“完成后应用当前选项”，使选项卡整体下移约22个归一像素。

本次仅删除该可见Text及其底部8px留白，将原说明保留为页面描述的 `Semantics.hint`，供辅助技术读取。描述下仍保留5px间距；不改规则值、不改“完成/取消/保存”提交层级，也不扩大调整编辑页其他行。

`message_group_editor_native_test.dart` **18/18通过**，日志 `/tmp/renji-group-rule-hint-removal-tests.log`。既有“完成无改动时确认always”和“取消保留继承”两条回归新增：提示不能以Text渲染，描述末端到首个radio间距为5px，辅助语义仍包含提示。其余顺序、嵌套标签、CAS和身份保护回归通过。

对应源码与测试两个文件静态分析 **No issues found**，日志 `/tmp/renji-group-rule-hint-removal-analyze.log`；`git diff --check`通过。

本文件记录“原生参考发现 → 单行修复 → 专项验证”。修复后的原生截图与同状态并排复验由主任务完成，不将修前截图当成修后结果。真实参考含账户水印，仅留本机被忽略的output，不公开嵌图。
