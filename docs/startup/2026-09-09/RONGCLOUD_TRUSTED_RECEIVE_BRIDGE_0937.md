# 融云可信接收桥：商业客户端治理与真实收包验收

记录时间：2026-09-09 09:37（Asia/Shanghai）。本阶段范围为既有受控合成群的一条真实文本运输与接收，不扩展历史文档同步或全量客户端功能。

| 归属 | Commit | 时间 | 描述 |
| --- | --- | --- | --- |
| 调查开始时基线 | `ddd947c7c3f74168ad1a17b11d4b04b5eb4599ad` | 2026-09-09T08:34:06+08:00 | docs(startup): preserve message phase publication and native repair receipts |
| 本阶段实施 | `e975e94e900cc892e39ed52ac0ce94ccd71c6ea1` | 2026-09-09T09:35:36+08:00 | feat(startup): onboard colleagues and relay verified RongCloud arrivals |

08:51—09:34 的观察、外部验收和回归运行发生在本阶段源码尚未提交时；上表实施提交收录其最终代码，不改写当时的历史状态。Clerk 新账号资料、工作空间和建群由本阶段其他报告记录，本文件聚焦融云。

## 1. 本阶段实际结果

Go 保存并授权 canonical 消息，经指定 outbox 一次发送到融云；独立可信接收进程使用官方 Web IMLib 真正收到同一 provider UID，再向 Go 提交接收观察。Go 在确认已受理 outbox、群、发送人、消息正文和规范指针完全匹配后记录 durable inbox。商业 Web/Electron 页面只轮询 Go 的当前授权事件，不获得融云 token。

这已经有真实 SDK 收包证据，超出了单纯 HTTP 发送成功的验证范围。但它仍是**本机可信开发接收桥**，不是已部署的云端消息路由，也不是所有商业账号都已开通接收。

证据固定于 [MANIFEST.json](evidence/rongcloud-receive-bridge/MANIFEST.json)。清单保留实际文件字节数和 SHA-256；哈希用于回执对账，不是数字签名。

## 2. 为什么没有直接给普通客户端发 token

原生 SDK token 会把 provider 写入能力交给调用方，仅在界面隐藏按钮不能保证所有写入经过 Go。官方能力调查得到以下边界。

| 官方能力 | 可用用途与实际边界 |
| --- | --- |
| 发送前审核回调 | 可以按会话、消息类型等筛选，但超时重试后有默认放行行为，不能独自构成全面 fail-closed 写入闸门；Server API 消息是否参与审核还需要相应配置。 |
| 群全员禁言与白名单 | 可限制 SDK 普通群消息，Server API 不受同样限制；群白名单必须单独核验。不能据此证明撤回、反应、扩展、托管群修改等全部路径被关闭。 |
| 私聊禁言 | 另有独立接口，群政策不能覆盖私聊。 |
| 撤回权限 | 官方错误码 25107 说明默认可通过 SDK 撤回其他用户消息，限制为仅本人需联系供应商；这是不能仅靠前端限制的具体例子。 |
| 消息全量路由 | 可成为服务端真实接收来源，但 Server API 消息默认不参与该路由；需要开启相应路由服务和服务端消息实时路由，本阶段没有改配置。 |

来源：[审核回调](https://docs.rongcloud.cn/platform-chat-api/moderation/msgcb)、[回调鉴权](https://docs.rongcloud.cn/platform-chat-api/auth-callback)、[群禁言](https://docs.rongcloud.cn/platform-chat-api/group/mute/ban-group)、[私聊禁言](https://docs.rongcloud.cn/platform-chat-api/one-to-one/ban)、[官方错误码](https://docs.rongcloud.cn/platform-chat-api/code)、[全量消息路由](https://docs.rongcloud.cn/platform-chat-api/message/sync)。

另外核对了官方 [撤回](https://docs.rongcloud.cn/web-imlib/message/recall)、[反应](https://docs.rongcloud.cn/web-imlib/message/reaction)、[扩展](https://docs.rongcloud.cn/web-imlib/message/expansion) 和 [托管群能力](https://docs.rongcloud.cn/platform-chat-api/group/overview)。本阶段没有伪造只读 token，没有因为普通发送路径有限制就放开原商业 session 白名单。

### 2.1 四次定向政策读取

实际观察时间为 08:51:09 +08，顺序是指定群禁言状态、指定群白名单、再次禁言状态、再次白名单，共 **4 次只读查询 POST**，未调用设置接口。两轮结果一致：`group_muted=false`、`whitelist_ids=[]`，`direct_client_safe=false`。重复一致只说明两个观察点一致，不构成原子政策快照。

CLI 只提交完整 `groupId`，不混入会令 `groupId` 失效的分页参数；记录四份原响应哈希，未输出应用密钥。详见 [group-policy-read.json](evidence/rongcloud-receive-bridge/group-policy-read.json) 和官方 [禁言查询](https://docs.rongcloud.cn/platform-chat-api/group/mute/query-banned-state-or-list)、[白名单查询](https://docs.rongcloud.cn/platform-chat-api/group/mute/query-group-ban-whitelist)。

### 2.2 当前控制台和 SDK

只读控制台显示既有 `First application`、北京、开发环境、IM 免费套餐已购买；运营管理页提示转到嵌入式控制台。未创建 AccessKey、改服务设置或购买新套餐。[嵌入式控制台官方说明](https://docs.rongcloud.cn/guides/imbedded-console/quick-start)。

最初官方 native Electron SDK 连接返回 `31003`，保留 [原失败状态](evidence/rongcloud-receive-bridge/native-sdk-31003-state.json)。官方定义为相关桌面/小程序服务未开通，不能当成 token 失效或成功连接。本阶段改用已经安装的官方 `@rongcloud/imlib-next 5.46.0` Web SDK，在隔离 Electron 接收进程内建立真正的 Web SDK 连接，复用同一 receiver token。[Web SDK 错误码](https://docs.rongcloud.cn/web-imlib/code)、[快速开始](https://docs.rongcloud.cn/web-imlib/quickstart)、[接收事件](https://docs.rongcloud.cn/web-imlib/message/receive)。

## 3. 已实现的接收与权限契约

1. 0600 私有配置固定 `bridge_id / receiver_id / room_id`、应用身份、内网 ingress 和本阶段精确消息白名单。商业 renderer 不能取得该 token 或调用桥的发送功能。
2. 隐藏接收窗口使用独立 profile、受限协议页面、隔离上下文和精确 IPC 来源检查。SDK 返回的 user ID 必须等于配置接收人，身份确认前不能投递队列。
3. 实际 SDK 收包先 fsync 原始观察，再原子保存待处理队列；仅处理受控群及指定消息 ID。接收程序没有 publish/recall/reaction 写入入口。
4. 本机 ingress 只接受 loopback、无浏览器 Origin、精确 bridge secret 的请求，解析范围限定为 `RC:TxtMsg` 或明确的 canonical reaction 命令。
5. Store 严格核验当前接收人/发送人授权、消息源、事件、provider UID、目标群与已接受的 canonical outbox。acceptance 尚未落库返回 425，桥只重试本机入站，不重新向融云发送。
6. 按 receiver + provider UID / event 持久去重。相同实际接收观察重复提交返回原 cursor 和原 received_at。
7. `GET /v1/transport/events?after=0&limit=50` 返回当前身份可访问的事件游标；无该身份 bridge coverage 返回 unavailable，不泄露别人的最后收包时间。Machine/run-bound 原生接收本阶段仍明确拒绝，待后续实现。

事件 schema 为 `renji.transport.events.v1`，mode 为 `trusted_development_bridge`；事件包含整数 `cursor`、`event_id`，`room_id`、`message_id`、`kind`、`provider_uid`、`received_at`。已支持解析 `message.created` 和 `message.reaction_set`，本次真实网络验收只有前者。

`connected` 仅表示配置接收桥实际完成 SDK 连接且心跳有效，`last_received_at` 只来自 inbox。HTTP 服务存活、心跳、API 受理均不能冒充已收到消息。Agent 停止/来源版本限制继续生效；同一空间中合法 Human 的干预消息和接收不因 Agent 刹车被一并禁止。

## 4. 一次真实运输验收

| 字段 | 本次真实值 |
| --- | --- |
| 工作空间 | `736b5198-479b-4505-8dbb-8d54b0d5c697` |
| 既有受控群 | `63892e35-efbd-40cb-86e6-17c7cab37aa6` |
| 当前群版本/来源 epoch | `3 / 3`，stopped=false |
| 合成 Human 发送人 | `798eb3da-b217-4204-8baf-23ff2941a88c` |
| 合成 Human 接收人 | `19519294-3539-479b-8615-a9ee68709c2d` |
| 既有 Agent 成员 | `b49d2ffc-946c-4061-a6ef-5ed7e4308465` |
| canonical message | `f35e0e72-e008-437f-8d45-59b93413c2d0`，seq 4 |
| event / outbox | `22 / 7` |
| provider UID | `D0GE-T1V8-LGOE-75D4` |
| provider 受理 | 2026-09-09T09:13:28.122214+08:00 |
| Go 接收记录 | cursor `1`，2026-09-09T09:13:28.230111+08:00 |

既有 fixture manifest 仍保持原内容，不能把现在的 3/3 反写成旧验收版本。本轮新 [receive-plan.json](evidence/rongcloud-receive-bridge/receive-plan.json) 明确记录当前群版本、精确成员、旧 manifest hash 和旧 outbox 5/6 hash。

实际外部请求范围：政策只读查询 4 次；既有 receiver token 获取 1 次；**文本消息发送 1 次**。本轮没有创建群，没有发送 reaction，没有运行通用 outbox worker，也没有处理旧 outbox 5/6。发送前建立 fsync 单次 intent，provider 回执返回且群 UID 匹配才记录受理；未知结果不得再次 POST。

[provider-result.json](evidence/rongcloud-receive-bridge/provider-result.json) 是实际受理；[sdk-received.jsonl](evidence/rongcloud-receive-bridge/sdk-received.jsonl) 是实际 SDK 收包；[ingress-repeat-readback.json](evidence/rongcloud-receive-bridge/ingress-repeat-readback.json) 证明重复本机入站仍返回原 cursor/time。本条真实 SDK 接收证据只覆盖该合成 receiver，不说明其他客户端送达或用户已读。

## 5. 独立审查与修复记录

- 初版恢复队列没有绑定原 receiver/app/endpoint，复用旧目录可能把 A 的旧观察当成 B。现已为目录、队列、每条 journal 固定同一 scope fingerprint，身份验证前禁止 drain。无 manifest 的非空历史目录直接拒绝。保留旧实际证据原样，未静默补造历史身份。
- 用同 token、同 receiver/group 的新空绑定目录启动后，官方 SDK 再次交付原 UID。新绑定目录原始观察与回执已保存，canonical inbox 仍为原 cursor 1；这不是第二次 provider 发送。
- heartbeat 同 bridge ID 改 receiver/room 时，旧 SQL 更新 0 行却返回成功。现在明确返回冲突，必须使用新的 bridge ID；不覆盖旧 tuple。
- 并发心跳可能使旧 connected 晚于 disconnected 落库。现在客户端串行发送、退出等待最后 disconnected；每次先持久化递增安全整数 sequence，服务端只接受更大值。同目录序列可跨重启继续；无有效前序的新目录若时钟倒退会被服务端拒绝。
- 迁移 00008 已应用，因此 sequence 使用独立 **00009**，不修改旧迁移。关闭前运行的是旧心跳进程；提交后需先迁移 9，再同 scope 重启，实际结果在本报告尾部追加。

回归覆盖：scope A/B 互换、无 manifest 旧队列、记录指纹错误、连接身份、旧 heartbeat 倒序/同序/rebind、队列重放、撤权、Agent stop 与 Human 干预。Node **8/8**；Go 四个定向包全部通过。独立真实 PostgreSQL race 运行 Store/HTTP **6 个顶层测试 + 2 个子测试通过、0 skip**，见 [independent-race-tests.jsonl](evidence/rongcloud-receive-bridge/independent-race-tests.jsonl)。

## 6. 验收启动与当前边界

本机 API 从私有 `data/startup/rongcloud-receive-20260909-0905/bindings.json` 加载 binding。接收程序使用同目录 `bridge.json`（0600），不把该文件复制进 Git。必须先启用已迁移到 9 的 API，再启动：

```sh
cd /Users/lwblx/huapohen/agent/execute/enterprise_work/active_agent
node services/rongcloud-bridge/build.cjs
env -i HOME="$HOME" PATH="$PATH" TMPDIR="$TMPDIR" LANG="${LANG:-en_US.UTF-8}" \
  node_modules/electron/dist/Electron.app/Contents/MacOS/Electron \
  services/rongcloud-bridge/main.cjs \
  "$PWD/data/startup/rongcloud-receive-20260909-0905/bridge.json"
```

这条启动命令只连接接收；不要把 `prepare` 或 `publish-once` 当作日常启动步骤。状态目录已绑定，不允许为了绕过错误清空或改绑历史证据。启动同 scope 的第二实例会被锁拒绝。

本阶段明确仍未完成：生产云端回调/路由、所有商业账号的 receiver 部署、机器 run-bound 接收、reaction 的真实 SDK 入站验收、原生桌面供应商服务开通。普通商业账号显示“未接入”是真实覆盖状态。后续生产实现必须保留权限/撤权、身份路由、幂等入站和真实 provider 收包证明，不能改成 Go 自己宣称融云已收到。


## 7. 提交后运行态收尾

核验时间：2026-09-09T09:43:43.081050+08:00。API 已加载实施提交 `e975e94e900cc892e39ed52ac0ce94ccd71c6ea1`，真实 PostgreSQL `goose_db_version=9`、`heartbeat_seq` 列存在。旧桥 PID 3351 正常退出（exit 0），用第 6 节同一 0600 配置、同 token、同 receiver/group、同绑定目录启动新桥 **PID 6521**（开发终端 session 50570）。桥保持运行供本阶段验收；PID 是本次观察值，不是日常启动应写死的配置。

官方 Web SDK 完成连接，Go 当前记录 `connected`，序列观察值为 **1788918221613000**；序列是持续递增的运行数据，后续变化正常。绑定指纹仍为 `02090f42dc95a6a60a44a5cb02e37bfb2ee8c201ac882b9aa8830a2cf51b5e6e`。数据库该消息 inbox 数量仍为 **1**，原 cursor 1、provider UID、event 22 和 09:13:28 的首次接收时间均保留。

重启过程没有调用 provider 发送或 token 获取。原 plan、单次发送 intent、provider 回执和绑定目录的真实 SDK journal 字节哈希保持；没有为了重启构造新的接收事实。随后通过既有只读 inspect 再次确认旧 outbox 5/6 不变。详见 [重启前围栏](evidence/rongcloud-receive-bridge/heartbeat9-restart-before.json)、[数据库和本地序列读回](evidence/rongcloud-receive-bridge/heartbeat9-restart-readback.json)、[canonical 只读对账](evidence/rongcloud-receive-bridge/heartbeat9-canonical-readback.json)。

本阶段接收桥源码、独立回归与上述证据完成收尾，后续不再新增外部测试消息，等待用户阶段验收。
