# 本轮完整 Flutter 回归记录

- 记录时间：2026-09-07 15:19:37 +08:00。
- 分支：`equal_rights`。
- 验证时的历史基准提交：`1774c284ba41d5db71ed77a4b905bd3db1c0369f`。
- 基准提交时间：2026-09-07 12:18:30 +08:00。
- 基准描述：`docs(office): record mobile group fidelity and native verification limits`。
- 该 SHA 是当前工作树继承的历史基准，不是本轮实现提交。当前源码和测试修改由主任务统一提交。

## 最终结果

在 `apps/office` 执行完整 `flutter test --reporter expanded`，最终 **825/825 通过**，共 71 个测试文件，测试输出耗时 42 秒。随后执行 `flutter analyze`，**No issues found**，耗时 2.2 秒。`git diff --check` 无输出、退出码 0。

| 证据 | 日志 |
| --- | --- |
| 最终完整 Flutter 测试 | `/tmp/renji-mobile-fidelity-full-flutter-20260907.log` |
| 最终 Flutter 静态分析 | `/tmp/renji-mobile-fidelity-full-analyze-20260907.log` |
| 首轮完整测试，818 通过、6 失败 | `/tmp/renji-mobile-fidelity-full-flutter-20260907-first.log` |
| 失败相关四文件修正后，48/48 通过 | `/tmp/renji-mobile-fidelity-failed-group-retest.log` |

首轮总数 824；最终总数 825，包含并行任务在此期间补入的一项测试。总数采用各次实际完整输出，没有以文件数或人工估计代替。

## 本次修正的测试

本次验证只修改以下四个测试文件，未修改生产源码、原生工程或构建配置。

1. `folded_conversations_test.dart`：原测试把“收藏”等同于消息顶部置顶栏。更新合成数据明确置顶，继续验证折叠会话不会漏入置顶栏、默认列表和通知摘要；手机搜索改为实际全局搜索入口，保留搜索折叠会话、打开来源房间及返回列表的行为断言。桌面保留会话搜索框，手机和桌面都继续覆盖分组切换。
2. `office_dialog_lifecycle_test.dart`：群创建入口使用 `quick-create-group` 稳定键，替换改版前的完整菜单文案。保留群名称、目标、成员、创建/取消、退出动画中的输入框生命周期断言。
3. `office_ui_test.dart`：手机更多入口使用实际 `OfficeMobileMorePanel` 网格和应用键；手机设置经头像“我的”进入。保留应用路由、可点击状态、真实 `OfficeSettings` 页面和布局无异常的断言。
4. `enterprise_directory_test.dart`：滚动到手机 Agent 成员后先完成布局，再核验命中与点击。首轮测试在滚动前旧坐标点击，未发送成员详情 GET；修正后继续核验最新详情请求、角色/组织修改、版本与人/Agent 相同行为。

没有删除失败场景、降低原操作成功断言，也没有为通过测试改动生产 UI。

## 验证范围与保留项

这次完整测试覆盖当前 Flutter 仓库的状态、业务协议边界与组件交互回归。真正的飞书/macOS/iPhone 截图对比、按钮点击和原生录音由主任务独立验收；825 项测试通过不等于已经完成全量飞书复刻。

最终日志仍有两条 `conversation_composer_alignment_test.dart` 既有快捷键菜单文字 `tap()` 命中警告，相关测试行为断言均通过。这次没有修改该测试或将警告隐藏，日志保留原始证据。

未提交、未推送，没有登录生产身份或访问模型凭据。
