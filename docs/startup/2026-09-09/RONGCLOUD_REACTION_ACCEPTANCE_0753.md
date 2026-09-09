# 融云 reaction 命令真实受理验收 · 2026-09-09

记录时间：2026-09-09T07:53:24+08:00。本阶段实现尚未提交；开始验收时 HEAD 是 `c3a6f2697544d6c9784c9d6e49da658c19736c78`，2026-09-09 07:03:54+08:00，`docs(startup): preserve three-platform phase publication receipts`。该 SHA 是上一阶段文档提交，不冒充本次实现提交；实际源码快照与 probe 二进制哈希见[新证据清单](evidence/reaction-transport-acceptance/MANIFEST.json)。

**07:50:05+08:00，真实融云服务已受理一次 `RC:CmdMsg` 反应变更通知**，返回 `code=200`、匹配群 UID **`D0GD-MSGD-GO4E-75D4`**。这证明服务端命令 API 的受理和本地 Outbox 记录；没有验证客户端收到、已读或界面端到端效果。

## 受控范围与两次预检事实

复用此前已注册的三名“合成验收”身份及群 `63892e35-efbd-40cb-86e6-17c7cab37aa6`，工作区 `736b5198-479b-4505-8dbb-8d54b0d5c697`。发送者为合成 Agent `b49d2ffc-946c-4061-a6ef-5ed7e4308465`，没有冒充真实用户或使用飞书账号。

第一次执行 `reaction-transport-20260909-074313` 在任何网络请求之前被版本围栏阻止：旧 fixture 记录 v1/epoch1，当前受控群已是 v3/epoch3、未停止。该次 journal 长度 0、外部请求 0、未创建临时 schema；[阻断证据](evidence/reaction-transport-acceptance/initial-preflight-stop.json)保留，旧 invocation、manifest 和 journal 未覆盖。

随后创建独立 `reaction-transport-20260909-074313-attempt2`，按当前状态冻结[新计划](evidence/reaction-transport-acceptance/plan.json)，逐项核对群 ID、工作区、标题、三名成员的 ID、显示名与 principal.kind；官方成员查询也返回完全相同的三个测试 ID。命令发送前再次读取并确认当前 v3/epoch3、未停止。这是首次零外发后的当前状态新验收，不是对未知发送结果的重试。

## 实际请求和原生事实

| 请求类型 | 实际次数 | 结果 |
| --- | --- | --- |
| `POST /group/user/query.json`（只读查询） | 1 | 三个受控测试成员完全匹配 |
| `POST /message/group/publish.json`，`RC:CmdMsg` | 1 | `code=200`，同群非空 UID 匹配 |
| 普通文字发送 / 注册 / 建群 | 0 / 0 / 0 | 未调用 |

临时 PostgreSQL schema `reaction_probe_dc566034964140e29cdba801d762edb2` 仅镜像这组已授权身份和群设置，没有操作持久 public 业务 Outbox。真实 `Store.Send` 生成一条本地合成文本 `d04e00c1-7307-41cd-93b8-59892a04bc20`；真实 `Store.SetReaction` 由合成 Agent 设置 `feishu:OK`、`active=true`，得到 reaction version 1、count 1。

本地文本**未外发**。scoped Messenger 为保证本次只发命令，故意对 `Publish` 返回 `ErrForbidden`；Store 将这条本地文本 Outbox 记录为 `blocked`，其通用错误码 `membership_revoked` 在这里来自测试发送范围限制，**不表示真实群成员被撤销**。反应事件由 `NotifyReaction` 精确核对本次 message ID、actor、room 和 version 后放行。

发送前已 fsync 唯一 intent；随后 Store 记录两个 action、两个 event、一条 message、一条 reaction，以及两条 Outbox：文本 `blocked`，反应通知 `delivered`，各尝试 1 次。这里的 `delivered` 是现有 Outbox 枚举，含义限定为融云受理。重复执行同一 reaction action 返回原持久回执；之后 `DispatchOne` 没有可执行任务，没有新事件或网络请求。状态及回执见[canonical-after.json](evidence/reaction-transport-acceptance/canonical-after.json)。临时 schema 已删除。

命令内容仅为 `name=renji.message.reaction`，`data` 是包含 `schema=renji.reaction.v1`、`room_id`、`message_id`、`version` 的 JSON 字符串。设定 `isPersisted=0`、`isIncludeSender=1`、`disablePush=true`、`disableUpdateLastMsg=true`、`needReadReceipt=0`；没有附上文本正文、表情明细或用户已读声明。完整非鉴权请求字段在[request-wire.json](evidence/reaction-transport-acceptance/request-wire.json)，其表单哈希与实际网络观察一致。

## 字节证据、保护范围与限制

实际命令 HTTP 响应为 114 bytes，SHA-256 `d8bf49ee5357ce22fbbce1aee4681c3aba3c4fed0f9fecb2578a9e3a8a66f33e`。[provider-response.raw.json](evidence/reaction-transport-acceptance/provider-response.raw.json)从解析字段恢复键顺序，并通过实际响应原始字节哈希验证完全一致。请求与响应观察日志 SHA-256 为 `40f7d416eb0b0398a9cd65e643b5ca548199f4903e51ff7e13c492cf4df7bb18`；鉴权头、token 与 secret 不记录。

旧四份 probe 文件哈希均未改变；public 中该受控群、成员、既有消息、事件及 Outbox 的前后快照一致，哈希 `dc44110a37ed6b5a13620cbd2f6de0077634142623616752d6b2ce02ca15e685`。这不是全局 public 数据不变的声明，其他线程仍可进行已授权工作。新 journal 保留在独立 ignored 私有目录；本证据只移除已删除 schema 的两个 claim token 字段，原始输出哈希仍登记。

这个合成 message 不存在于 public 业务 schema，测试 schema 也已清理，因此本次通知不能称为客户端 canonical 刷新端到端验收。真实客户端必须凭自身当前权限重新读取 canonical 数据，不能把命令指针直接当成消息或反应事实。

官方依据：[命令消息类型](https://docs.rongcloud.cn/platform-chat-api/message-about/objectname-callback)、[发送群消息参数及回执](https://docs.rongcloud.cn/platform-chat-api/message/send-group)、[查询群成员](https://docs.rongcloud.cn/platform-chat-api/group/query-group-member)。`RC:CmdMsg` 默认不在界面显示、不计未读、不入本地消息库；`isPersisted=0` 控制云端历史存储，不据此宣称没有离线传输。

## 最终实施提交归属

本阶段实施已归入提交 `50570cac03b1314c831fc856e6ed826f60486fa8`，提交时间 `2026-09-09T07:55:18+08:00`，描述为 `feat(startup): deliver native replies reactions and authenticated emoji`。以上三项已与 Git 提交元数据逐项核对。

前文的基线、实际请求时间及“观察时尚未提交”状态保留为历史记录；既有证据与 manifest 不重写。本段仅补充最终实施归属，不增加任何外部请求，也不把融云受理扩大为客户端送达、已读或 canonical 刷新端到端验收。
