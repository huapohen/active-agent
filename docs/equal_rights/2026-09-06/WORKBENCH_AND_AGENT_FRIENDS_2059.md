# 工作台应用返回容器与 Agent 好友分类树

- 记录时间：2026-09-06 20:59:26 +08:00。
- 分支：`equal_rights`。
- 当前已提交基础：`345bfad`，2026-09-06 20:40:31 +08:00，`docs: record folded conversation and broadcast delivery`。
- 前一个功能提交：`49d6115`，2026-09-06 20:35:29 +08:00，`feat(office): add folded chat UI and native everyone mentions`。
- 本文记录上述 HEAD 之后的工作区增量；最终功能提交由集成记录补充，不将基础提交冒充本轮实现提交。

## 工作台应用容器

新增 `apps/office/lib/ui/workbench_navigation.dart`，提供 `OfficeWorkbenchNavigator(state, pageBuilder)`。`pageBuilder` 接收原生路由编号、页面内返回回调及继续导航回调，集成端负责装入真实业务页面。

容器固定提供左侧返回和右侧关闭：返回上一应用，最底层返回工作台；关闭清空应用栈并回到工作台。桌面与手机使用相同语义。系统返回也逐层回退。工作台本体持续挂载，返回后保留搜索内容和滚动位置。

每个路由在栈中只有一个页面实例：再次进入当前路由不重复创建，进入更早的路由回退到已有实例，保留其草稿并避免重复 GlobalKey。隐藏页面使用 TickerMode 与焦点隔离；业务状态和真实会议会话仍由业务页面及集成端持有，容器不执行加入、退出会议或消息读写。

路由覆盖消息、Agent、通讯录、云文档、任务、工作台、会议、日历、邮箱、考勤、审批、设置、企业管理、人机妙记，并兼容 documents/docs、approval/approvals 等已有路径。外部 URL 或未知路径显示可返回、可关闭的未接入说明；模块策略、显式不可用应用及无企业管理权限场景不构造受限业务页面。

作用域绑定 state 实例、身份 generation、端点和 principal。任何身份变化清空旧栈并重置工作台；旧页及隐藏页回调不能导航当前应用。临时离线保留栈与草稿，返回和关闭仍可使用。

集成标识：`workbench-app-back`、`workbench-app-close`；提示文本为“返回工作台”或“返回上一应用名称”，以及“关闭应用并返回工作台”。

## Agent 好友分类树

新增 `apps/office/lib/ui/agent_friend_directory.dart`，接入 `people.dart` 的 Agent 好友分支，保留原有同事卡片、发消息和添加好友行为。人类通讯录继续使用原有目录流程。

三个维度可以与名称、职业、职位、组织、技能搜索组合：

1. 公司 / 组织 → 该组织好友任职记录中的部门。
2. 职业 → 该职业好友实际填写的职位。
3. 工作分类。

组织节点来自真实 `organization_id/name`，部门来自 `department_id/name`。这是好友任职信息的分布分组，不宣称数据库存在公司与部门的正式父子目录。后端确认 `/agents` 不提供部门祖先链；本轮没有调用管理员目录接口，也没有编造父部门。`source_organization_name/source_department_name` 保持“来源”语义，可用于搜索和原有卡片展示，不会被提升为所属公司。缺少字段的好友明确进入未分配组织、未分配部门、未填写职业/职位或未分类入口。

桌面提供 246 像素分类树；手机通过筛选底部面板展开同样的组织、职业层级。节点计数按搜索及其他维度条件计算，当前结果显示匹配数与好友总数。已选条件以 chip 展示并可移除，重置同时清除条件和搜索。工作空间中的其他 Agent 也遵循当前搜索及分类条件。好友列表使用惰性构建，千人列表可准确检索并打开目标身份。

身份变化关闭旧筛选面板、清除旧查询及分类；旧选择回调失效。临时离线保留本地筛选。筛选不执行身份创建、组织编辑或商店安装。

## 验证证据

```text
flutter test --no-pub test/agent_friend_directory_test.dart test/workbench_navigation_test.dart
25/25 PASS

flutter analyze --no-pub lib/ui/workbench_navigation.dart lib/ui/agent_friend_directory.dart lib/ui/people.dart test/workbench_navigation_test.dart test/agent_friend_directory_test.dart
No issues found
```

其中工作台 12 项，Agent 好友 13 项。测试使用真实工作台、好友列表、选择树、底部面板及原有发消息入口，API 状态以合成 fixture 替代；覆盖手机/桌面、人类/Agent 同权、返回与关闭、重复页面、未知与禁用应用、跨身份回调、离线保留、来源组织不冒充任职组织、组合计数、千人检索。千人用例确认最后一位匹配同事使用其真实测试 ID 发起私聊。

本记录不声称已完成真实 App、真实后端或真实模型验证。壳层集成、隐藏会话可见性处理、全量回归和实机验证由集成负责人另行记录。
