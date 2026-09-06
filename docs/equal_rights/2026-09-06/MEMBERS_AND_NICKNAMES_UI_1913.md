# 群成员管理、群昵称与手机详情 · 2026-09-06 19:13 CST

## 本批记录

- 分支：`equal_rights`。
- 实现与定向验证记录时间：2026-09-06 19:13，Asia/Shanghai（UTC+08:00）。
- 开发基线 commit：`392eb80`，2026-09-06T18:59:09+08:00，`docs: record group chat delivery with live evidence and remaining parity gaps`。
- 本文记录该基线之后的前端工作区变更；最终实现 commit 由主任务统一提交，本文不把基线 commit 当作实现交付 commit。
- 前一批详情入口记录保留于 `GROUP_DETAILS_UI_1850.md`，本文单独追加新的实现范围与验证结果。

## 办公群成员管理

`OfficeDialogs.members` 增加可选 `roomId` 参数，保留原调用方式。成员面板由独立 StatefulWidget 持有打开时的房间和工作身份，从 `GET /rooms/:id` 读取真实房间及成员。

```dart
OfficeDialogs.members(context, state, roomId: targetRoomId);
```

成员姓名优先使用共同 `officeDisplayName` helper，保留 Agent 标识与负责人角色。当群昵称和工作本名不同时，本名出现在成员副标题中。搜索支持姓名、群昵称及主体 ID。添加区域只列出当前真实主体列表中尚未加入本群的同事，并提供搜索。

负责人可添加或移除普通成员。人类负责人和 Agent 负责人使用相同入口和规则；普通成员仍可维护自己的群昵称。单聊保持固定成员，不显示添加、移除或群昵称入口。

### 真实移除与明确确认

移除按钮不出现在当前自己、其他负责人或会话创建者旁。点击目标后展示群名、目标群内显示名、工作本名及主体 ID，确认之前不会写入服务端。

确认后重新读取当前群成员，重新检查操作者仍为负责人、目标仍在群内且并非自己或负责人，然后执行：

```text
DELETE /rooms/:roomId/members/:principalId
body: {}
```

该既有协议没有 CAS 参数，界面不假装提交版本号。服务端在实际提交点继续执行权限与受保护成员校验。移除后重新读取成员并刷新工作空间；本批后端同步加强了自己、负责人及创建者保护。

邀请执行 `POST /rooms/:roomId/members`，仅传 `principal_id`。添加和移除都使用捕获的显式房间 ID，不会因为另一个会话被选中而漂移到其他群。

## 本人群昵称

新增 `apps/office/lib/ui/room_nickname.dart`，由群详情「我在本群的昵称」和成员面板的同名入口调用。昵称仅作用于本群，保留工作身份本名与主体 ID。人类和 Agent 都只能修改当前登录本人的昵称，负责人不会获得替他人改名的界面。

```text
GET /rooms/:roomId/membership-profile
PATCH /rooms/:roomId/membership-profile
body: {nickname, base_revision}
```

读写均使用 `membership_profile.revision`，与 room、群资料和公告的 revision 分离。响应中的 `permissions.can_edit` 控制实际编辑能力。昵称最多 40 字符，首尾空白移除后保存；空值表示恢复工作身份本名。请求不携带 `principal_id`，由当前认证身份确定操作对象。

409 时保留用户输入并锁定直接保存。用户先读取最新昵称，点击「采用最新版本号，保留我的昵称」，再保存当前草稿。不会自动拿新 revision 覆盖另一端编辑。

昵称弹窗和成员面板在初始化阶段捕获身份。身份变化后隐藏原内容、锁定草稿和移除确认按钮。异步请求返回后校验身份和 mounted 状态，旧身份响应不会继续操作当前会话。

## 手机群详情布局

手机仍采用完整页面。成员区域改为可横向滚动的头像预览，默认显示前 8 位真实成员，保留人类/Agent 标识。点击 Agent 头像进入已有「人格与参与」；点击成员或「查看全部」进入完整成员管理。负责人在群聊看到真实添加入口。

群应用区域使用图标入口呈现已有公告、群文档、任务、工作记录。只有数据或回调实际可用时才展示对应图标；导航执行真实既有功能。桌面继续保留成员搜索与列表式详情抽屉。

群昵称显示统一接入 `officeDisplayName`，与主任务的消息作者、引用与相关显示更新保持一致。未加入未实现的群机器人、成员日历或翻译开关。

## 定向验证

```text
flutter test --no-pub test/member_management_test.dart test/room_details_test.dart test/agent_execution_ui_test.dart test/agent_personality_test.dart
结果：28/28 通过。

flutter analyze --no-pub lib/ui/room_nickname.dart lib/ui/room_details.dart lib/ui/office_dialogs.dart test/member_management_test.dart test/room_details_test.dart
结果：No issues found。
```

新增 `member_management_test.dart` 的 13 项回归覆盖：

- 人类和 Agent 负责人移除明确目标，验证实际 DELETE 房间与主体。
- 人类与 Agent 只能修改本人昵称，使用独立 revision，不携带其他主体 ID。
- 取消移除不发请求；自己和其他负责人不出现移除按钮。
- 确认期间目标变为负责人时，不执行删除。
- 确认期间切换身份，目标隐藏且确认按钮锁定。
- 单聊不出现成员变更及群昵称能力。
- 普通成员能够编辑本人昵称，无法添加或移除同事。
- 按昵称搜索仍保留工作本名，邀请请求使用固定房间。
- 昵称冲突保留草稿并显式采用新 revision。
- 空昵称恢复本名，身份变化锁定未提交昵称草稿。
- 手机横向成员区和真实群应用导航，无布局异常。

前一批 10 项群详情测试以及 5 项 Agent 人格与参与测试继续通过。本记录只描述代码级定向验证；全量回归、实机效果与最终 commit 由主任务另行记录，不混用先前批次的实机或测试证据。
