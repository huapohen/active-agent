# 群详情与个人会话设置 · 2026-09-06 18:50 CST

## 记录信息

- 分支：`equal_rights`。
- 本批实现与验证时间：2026-09-06 18:50，Asia/Shanghai（UTC+08:00）。
- 开发基线 commit：`6f44527`，2026-09-06T18:29:28+08:00，`docs: record settings alignment and verified capability limits`。
- 本文记录该基线之后的群详情前端工作区变更；最终功能 commit 由主任务统一提交并记录，不将基线伪称为本批实现 commit。
- 本文为独立追加文档，保留此前阶段报告与实机记录的原始验证范围。

## 办公 IM 的实际入口

新增 `apps/office/lib/ui/room_details.dart`。宽度小于 720 的设备使用完整页面；桌面使用右侧 400 像素详情抽屉。

详情包含当前会话的真实名称、人类与 Agent 数量、共同成员、成员角色、Agent 身份标识。默认预览前 8 位成员；输入名称或身份 ID 后搜索真实成员列表。完整成员管理交给已有成员入口。Agent 保留「人格与参与」操作，沿用当前会话内参与模式、暂停与主动执行策略。

群资料展示名称与介绍；群公告展示内容预览，点击可读取完整可选择文本。服务端授予编辑权限时才出现编辑按钮。人类负责人和 Agent 负责人使用相同编辑入口；当前主体的种类不会绕过服务端 `permissions.can_edit`。

查找聊天内容、群文档、任务和工作记录通过真实回调进入已有会话功能。未提供回调时不展示该项。个人设置提供三个彼此独立的能力：置顶聊天、收藏会话、消息免打扰。页尾展示可复制的会话 ID。

单聊复用会话详情、真实成员及个人设置。单聊不请求仅适用于群聊的资料和公告端点。

## 集成接口

```dart
showOfficeRoomDetails(
  context,
  state,
  roomId: roomId,
  onSearch: openRoomSearch,
  onDocuments: openDocuments,
  onTasks: openTasks,
  onRecords: openRecords,
  onMembers: openMembers,
  onChanged: refreshRoom,
);
```

导航回调执行前关闭详情路由。读写操作始终使用打开详情时指定的 `roomId`，不依赖可能已经改变的 `state.selectedRoomId`。

## 数据与并发编辑

读取使用当前成员认证的 `OfficeState.officeRequest`：

- `GET /rooms/:id`：会话信息、真实成员与个人设置。
- `GET /rooms/:id/profile`：群资料及编辑权限。
- `GET /rooms/:id/announcement`：完整群公告及编辑权限。
- `PATCH /rooms/:id/preferences`：单独提交 `pinned`、`favorite` 或 `muted` 布尔值，使用响应中的真实 room 更新开关。分别消费 `is_pinned`、`is_favorite`、`muted`。
- `PATCH /rooms/:id/profile`：`base_revision`、名称、介绍。名称为必填，100 字上限；介绍 4000 字上限。
- `PATCH /rooms/:id/announcement`：`base_revision`、公告内容，20000 字上限；空内容保存可清空公告。

资料与公告分别使用对应对象自己的 revision，不能使用 room revision 代替。遇到 409 时锁定直接保存，保留输入。用户先读取服务端最新内容，核对后点击「采用最新版本号，保留我的草稿」，然后再次保存。未静默覆盖服务端最新版本。

## 身份与路由生命周期

详情页与编辑表单在 `initState` 同步捕获 endpoint、主体 ID 和连接状态。身份发生变化后锁定旧页面并隐藏成员、公告及草稿。后台读取响应使用 generation 校验，旧身份或旧请求的迟到响应不能恢复已隐藏内容。资料读取发现 401、403 或 404 时清除缓存内容。

表单控制器由表单 State 持有，在路由实际移除时 dispose，避免弹窗关闭动画期间使用已销毁的控制器。人格与参与弹窗同步增加身份锁定，并明确在初始化阶段捕获 room revision，避免 Dart `late` 懒初始化在后续选房时读取错误版本。

## 验证记录

本批定向执行以下命令：

```text
flutter test --no-pub test/room_details_test.dart test/agent_execution_ui_test.dart test/agent_personality_test.dart
结果：15/15 通过。

flutter analyze --no-pub lib/ui/room_details.dart lib/ui/agent_autonomy.dart test/room_details_test.dart test/agent_execution_ui_test.dart test/agent_personality_test.dart
结果：No issues found。
```

新增 10 项群详情 widget 测试覆盖：桌面 400 像素抽屉、手机 390 像素页面、真实人机成员、固定会话下独立个人设置、人类与 Agent 负责人资料编辑、成员只读权限、公告冲突保留草稿并显式采用版本、成员搜索与路由回调、切换身份后草稿锁定、迟到响应丢弃、人格与参与弹窗的身份保护。

原有 Agent 参与与人格测试补全合成的已连接身份 fixture，保留实际界面对连接和身份的检查。

本批仅记录代码级定向验证。全量回归、桌面/iOS/Web 实机验证与最终 commit 归入主任务的集成记录；未在此混用历史批次的测试数量或实机结果。

## 当前边界

界面目前使用清晰的列表分组。飞书参考中的群机器人、群昵称、翻译、清空聊天记录、退出群和群成员日历未作为占位开关加入本批。成员管理、文档、任务和工作记录复用现有真实能力，后续可在保持相同协议的基础上改进头像区与快捷图标布局。
