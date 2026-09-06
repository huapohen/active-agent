# 会话个人偏好与离线恢复 · 2026-09-06 20:16

记录时间：2026-09-06 20:16:03 +08:00（Asia/Shanghai）；工具读取 UTC 为 `2026-09-06 12:16:03`。

本批对应 `equal_rights` 的飞书群聊详情对齐续轮，独立于 18:45 群聊审查和 19:43 设置隔离记录。

## Commit 基线与实现边界

| 仓库 | 写本文时已提交 HEAD | 时间 | 描述 |
| --- | --- | --- | --- |
| Active Agent | `7a18e1c0141ba14404300182a0c1c5bcc5f1d44a` | 2026-09-06 20:00:38 +08:00 | `docs: record settings and group delivery with commit evidence` |
| Doc Free | `0dd7556b7c17a10f271ffbffb0a75807b21b5cb5` | 2026-09-06 19:48:11 +08:00 | `fix: isolate nested author snapshots from message views` |

以上是开发时读取的基线，不代表本批未提交工作区实现已经包含在上述 commit 中。功能由主线程统一审查、提交；最终交付记录补充实际功能 commit。

本批仅修改 Active `apps/office/lib/ui/room_details.dart`、`apps/office/lib/ui/office_dialogs.dart` 的成员管理部分，新增 `apps/office/test/room_preferences_test.dart` 与本文。没有修改 shell、折叠列表、message_groups、OfficeState 或 Doc Free 后端；没有操作 CUA、真实会话、账号、设备或既有 3218 服务。

## 个人会话偏好

依据主线程本轮真实飞书参照，在会话详情加入两项当前工作身份的偏好：

| 界面 | 真实请求 | 适用范围 |
| --- | --- | --- |
| 移入“折叠的会话” | `PATCH /rooms/:rid/preferences`，`{"folded": true/false}` | 单聊、群聊 |
| @所有人的消息不提示 | 同一 endpoint，`{"mute_all_mentions": true/false}` | 群聊 |

开关顺序为：消息免打扰 → 移入折叠的会话 → @所有人的消息不提示 → 置顶聊天。原“收藏会话”保留独立收藏语义；没有把 `is_favorite` 改名或误接为“标记”，没有重复实现已有会话标记控制。

折叠说明使用：**“移入后不再接收消息提醒，可在折叠的会话中查看”**。后端团队已确认本轮折叠会话 `notification_count` 始终为 0，折叠汇总仍可展示真实未读与 @ 摘要；这部分列表与计数由后端和主线程另行验证。折叠设置不修改 Agent 的参与 mode、autonomy、cursor 或 read_seq。

@所有人开关说明：**“仅关闭 @所有人提醒，直接 @你的消息仍会提示。”** 单聊完全不显示该开关，也不请求群资料、群公告或群昵称接口。

两字段默认 false。详情优先读取 room 顶层字段，也兼容 `room.preferences`；保存后采用服务端回传 room，通知外层刷新。请求只提交用户刚改变的一个布尔字段，roomId 固定为打开详情时的会话，不随全局选中会话变化。

保存期间暂停其他偏好提交与详情刷新。失败不乐观伪造开关成功值，保留服务端原值；错误紧邻个人会话设置展示，支持重试。Human 与 Agent、普通成员与负责人使用相同本人偏好入口，无额外群资料管理权限要求。

## 临时离线与身份切换

此前详情、群资料编辑器与成员管理把 `connected` 拼入身份快照，一次网络断开就永久判定身份切换。本批统一改为 generation + endpoint + principal ID，并保留永久失效标志。

- 同身份暂时 `connected=false`：详情、成员资料、成员搜索条件与群资料草稿保留。偏好、群资料/公告保存、成员邀请/移除等写入暂停，界面说明暂时离线。恢复连接后重新读取必要数据并恢复操作。
- A → B → A：即使服务、成员 ID、revision 最终相同，新的 identityGeneration 仍锁定旧页面与草稿，迟到响应不能恢复旧内容。
- 成员移除确认：离线时保留确认目标并禁用确认；执行前继续重新读取成员和权限，固定目标及原会话。
- 已发出的写入在同身份短暂离线后返回成功，仍可呈现真实服务端结果；未发出的写入保持禁用。

修复范围为本文件中的会话详情/群文本编辑器以及 `OfficeDialogs.members`。昵称和 Agent 自主性等独立子对话框的内部逻辑没有在此批扩大修改；离线时从本页进入这些可编辑对话框的动作被拦住。

## 验证

```sh
flutter test --no-pub test/room_preferences_test.dart \
  test/room_details_test.dart test/member_management_test.dart
```

结果：**35/35 通过**，其中新增 **12 条**。

| 场景 | 验证证据 |
| --- | --- |
| 人机同权与顺序 | 390/1512 宽度 × Human/Agent，普通成员无群资料权限仍可保存本人偏好；验证开关顺序 |
| 会话与本人范围 | 每次 PATCH 只有指定布尔字段，路径始终为打开的 room-1；全局另选会话不影响目标；另一身份偏好保持 |
| 核心状态不变 | fixture 成员/角色、Agent mode/autonomy、read_seq、房间 revision、既有 is_marked 与收藏值保持 |
| 单聊 | Human/Agent 两条验证可折叠，无 @所有人开关和群专用请求 |
| 响应兼容 | 顶层字段缺失时读取 nested preferences，成功响应准确更新相应开关 |
| 失败恢复 | 保存失败保留服务端原值，区内显示错误，重试成功后才改变开关 |
| 迟到写入 | PATCH 等待期间 A → B → A，旧结果不能恢复详情或触发外层变更回调 |
| 离线详情 | 内容不清空、两开关禁用，恢复后可真实提交 |
| 离线群草稿 | 群资料输入保留、保存暂停；恢复后发送原草稿及原 revision；之后同 ID 代次切换锁定旧草稿 |
| 离线成员确认 | 搜索和目标保留，不发 DELETE；恢复后重新确认并移除精确成员 |
| 原功能回归 | 已有个人置顶/收藏/免打扰、群资料/公告 CAS、成员删除保护、昵称、群应用等 23 条继续通过 |

```sh
dart analyze lib/ui/room_details.dart lib/ui/office_dialogs.dart \
  test/room_preferences_test.dart
```

结果：**No issues found**；`git diff --check` 通过。

以上是合成 Flutter 界面与请求契约验证，不等同于服务器通知计算、真实账号群设置写入或五端安装包发布。折叠聚合、主导航提醒、后端协议测试与最终整体验证由对应批次记录。

## 集成提交补记

2026-09-06T20:37:51+08:00：实际前端实现 `49d6115f5bd0ea15e3e9437f060e3ade503bf545`（2026-09-06T20:35:29+08:00），后端实现 `b8747976dc37a68eedd199a76054a33a53a1d978`（2026-09-06T20:35:03+08:00）。完整交付和验证边界见 [FOLDED_BROADCAST_DELIVERY_2035.md](FOLDED_BROADCAST_DELIVERY_2035.md)。
