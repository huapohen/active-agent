# 人机商业阶段交付：工作空间邀请、Agent 接收读取与真实会话摘要

冻结时间：`2026-09-09T10:51:37+08:00`（Asia/Shanghai）；阶段编号 1035。本阶段在 `startup` 分支实施，已完成本阶段验证与收尾。按用户要求，本阶段后停止，等待验收，不把全部商业化目标标为完成。

## 实施归属

| 类型 | Commit | 提交时间 | 描述 |
| --- | --- | --- | --- |
| 本阶段主要实现 | `30c6c22ce3ff24676d9d5a43bf1b3ce0cf14aafa` | `2026-09-09T10:33:54+08:00` | `feat(startup): invite human and agent colleagues with scoped arrival reads` |
| 原生验收修复 | `313572c6881b488cccc6b943918d5598f2f9b5ae` | `2026-09-09T10:49:01+08:00` | `fix(desktop): support scoped invitation copy and accessible dialogs` |
| 上阶段交付基线 | `1ea4685b4df3f0a9e9bffd0400c295b2bfb723e1` | `2026-09-09T10:00:39+08:00` | `docs(startup): preserve account phase publication and independent receipts` |
| Doc Free 保持不变 | `dc728ddc99ce3bc7346bb4dc364824bbb32b1101` | `2026-09-09T01:22:28+08:00` | 本阶段不修改 Doc Free 源码，继续通过现有文档与投影网关归档 |

主要实现包含 43 个文件、3,652 行新增和 101 行删除。原生验收修复另有 13 个文件、140 行新增和 11 行删除，归属独立修复提交。

## 本阶段交付的行为

### 1. 人与 Agent 可通过同一邀请核心加入工作空间

电脑端的头像、加号和空工作空间页面提供邀请或加入入口。所有者/管理员可创建仅授予普通成员身份的一次性邀请，选择 1 小时、24 小时或 7 天有效期，查看实际邀请记录并明确撤销。加入时使用当前已验证的身份；客户端不能通过填写姓名、邮箱、角色或 principal ID 冒充另一位同事。

服务端生成 256 位随机邀请码，只存 SHA-256。明文只在首次创建响应返回，动作重放、动作查询、邀请列表、事件表及执行审计均不返回它。客户端仅在当前实例内存保存明文；本地持久化原 action ID、目标与用于匹配原邀请码的 SHA-256，不把明文放进 URL、查询缓存或 sessionStorage。复制问题见下方原生验收记录。

结果未知时核对原 action，不自动生成第二份邀请。接受请求发生超时、换身份或刷新后，原意图仍被保护；重新输入不同邀请码不能替代原来的未决意图。明确收到过期、撤销或已使用的错误后，才允许开始新接受意图。服务器 action 查询不表示可以从历史回执恢复明文；丢失明文的邀请需明确撤销后另建。

Agent 使用真实机器认证与明确 Run，创建、列表、撤销、接受、原动作查询均经过权限核验。Agent 接受跨工作空间邀请仅增加 member 成员关系，不改变 executor 注册工作空间、原 Run 或任何继承来源。Agent 发出的未消费邀请在另一身份接受时再次核验发行者角色、机器绑定、策略版本、来源群的权限/停止状态/epoch；已完成的发行 Run 可以保持邀请有效，但停止、撤权、旧 epoch 或失效绑定不能继续发放新权限。

邀请码不会自动加群，不会授予管理员，不会开通融云 SDK，也不会发邮件或真实飞书消息。管理台、公司域验证、大规模邀请和完整成员生命周期仍不在本阶段完成声明中。

### 2. Agent 原生读取融云到达事件

`GET /v1/transport/events` 和 MCP `transport_arrival_read` 使用相同读取核心。机器必须提交当前 Run；服务器确定接收身份、固定 executor 与当前桥覆盖，模型不能指定或借用别人的 receiver。每页在同一个事务内检查全部来源、成员关系、停止状态、epoch、策略与 Run 终态；游标必须属于该接收身份和当前 Run 覆盖。

Eino 增加 `im_transport_arrival_read`，模型只给 `after` 和 `limit`，Run 来自执行上下文。可替换工具的返回也经过来源、预算和分页校验，读取前后再次检查授权，迟到的已撤权结果不进入后续模型和工具结果归档。

`unavailable`、已连接心跳和实际收到消息是不同事实。本机 Human 受控桥仍存活，未自动扩展给新账号或 Agent。本轮真实机器使用新短期 Clerk 凭证，在原工作空间原根群 epoch3 建立验收 Run；HTTP/MCP 返回逐字段相等，receiver 是该 Agent，未配置覆盖时返回空事件和 unavailable。验证后通过正常生命周期接口终结为 stopped，停止后执行读取 409、审计 200，原群状态未改。Agent 实际接受 Human 邀请未执行；不将隔离测试或 Human 创建邀请说成这条链路的现场成功。详见 [机器读取专题](AGENT_RUN_ARRIVAL_NATIVE_READ_1042.md)。

### 3. 会话列表显示实际最后一条消息及时间

正式 Go 消息表按会话批量查询最后序号、作者、最多 240 个 Unicode 字符的摘要和实际时间，不逐行额外发消息请求。HTTP/MCP 使用同一列表结果；Run 列表保持全部来源限制，普通账户列表与撤权操作按事务锁序一致。

`last_message: null` 表示经过查询确认没有消息；缺字段表示该响应未提供摘要。创建/停止等元数据回执不会伪造空摘要覆盖已有消息。客户端将二者分别显示“暂无消息”和“消息摘要暂未提供”。原有会话排序与 ID 游标没有改为未实现的活动时间排序。

## 本机运行与原生验收

- 用户已亲自完成 Clerk 真人验证和邮箱验证码。电脑端刷新后自动恢复已验证账号，保留原昵称、工作空间、群聊、中文消息、引用回复与表情回应；没有重新注册或重置密码。
- 10:36:22 实际运行新版 Go API，3318 健康返回 `transport=rongcloud`，数据库 schema 10，旧受控接收桥仍存活。新进程仅启动 API，不启动模型 Worker 或历史 Outbox 派发。
- 升级前已做 PostgreSQL public schema 自定义格式备份，并用 `pg_restore --list` 核验。备份仅在 Git 忽略的私有目录中；完整连接串和凭据不进入报告。
- API 从实施提交的干净 detached worktree 构建。该本机 Go 产物没有嵌入 VCS metadata，因此构建回执记录实际源提交、干净工作区和产物 SHA-256，不声称二进制包含 commit 字段。
- 电脑端刷新会话后，已显示 09:15 和真实的最后回复摘要。
- 10:38 原生点击创建一次性邀请成功，记录为“待使用”；复制按钮真实返回失败，随后通过 UI 撤销并读到“已撤销”。该邀请未分享或消费。发现的 Electron 剪贴板限制、重复弹窗标题和底部可达性问题已在独立修复提交中解决，保留首次失败证据。

末轮原生复验：

1. Electron 只增加一个受限文本写剪贴板接口，校验当前窗口、main frame、可信 origin 和文本边界；不增加读取剪贴板能力，不放宽整体权限策略。实际点击显示“已复制”。
2. 在同一应用打开加入表单，将剪贴板直接粘贴进密码式邀请码输入框；提交后显示“已加入 人机共创工作空间，成员列表已更新”。没有读取、打印或截取明文。
3. 此次由已经是 owner 的本人接受，服务回执 `already_member=true`。数据库回读：角色仍为 owner，成员仍为 1，消息仍为 2；两份邀请分别已撤销和已接受，不存在此次遗留的待消费邀请。不声称第二名真实用户或 Agent 已加入。
4. 邀请窗口只有一个标题，正文可滚动，顶部角落与底部关闭按钮在当前实际视口可达；点击关闭返回正常页面。电脑端最终保持 Clerk 登录并停留在原群聊。
5. 恢复桌面窗口识别时，曾短暂停止与业务窗口共用 Electron 应用标识的受控后台桥；随后使用同一配置和队列恢复。10:50:28 回读 connected、心跳更新，inbox 仍为 1，没有新派发。此处不把进程存活当作新收包。

证据：[复制和修复布局](evidence/workspace-invitation-stage/invitation-copy-fixed-native.png)、[粘贴后接受成功](evidence/workspace-invitation-stage/invitation-accept-fixed-native.png)、[最终登录群聊](evidence/workspace-invitation-stage/desktop-final-logged-in-native.png)、[数据库回读](evidence/workspace-invitation-stage/native-final-readback.json)、[受控桥恢复](evidence/workspace-invitation-stage/bridge-restored.json)。

## 接口与配置范围

| 能力 | HTTP | MCP |
| --- | --- | --- |
| 创建邀请 | `POST /v1/workspaces/:workspace/invitations` | `workspace_invitation_create` |
| 邀请列表 | `GET /v1/workspaces/:workspace/invitations` | `workspace_invitation_list` |
| 撤销邀请 | `POST /v1/workspaces/:workspace/invitations/:invitation/revoke` | `workspace_invitation_revoke` |
| 接受邀请 | `POST /v1/workspace-invitations/accept` | `workspace_invitation_accept` |
| 原动作查询 | `GET /v1/workspace-invitation-actions/:action` | `workspace_invitation_action_read` |
| 融云到达读取 | `GET /v1/transport/events` | `transport_arrival_read` |

Clerk 负责认证，资源权限在服务端执行。融云继续是必须配置，任何测试中的 unavailable 都不能解释成已绕过融云或融云可选。API/MCP 返回 `Cache-Control: no-store`；邀请有效期的省略默认与显式 null/0 区分，Human 显式 Run、Machine 缺 Run、伪造身份/角色及未知参数均拒绝。邀请写入与普通消息写入使用一致的 Run→action→来源群锁序，避免同动作编号并发时倒序死锁。

当前没有把带明文邀请码的写操作接入通用 Eino 工具轨迹，避免普通 tool.result/model transcript 保存能力凭据。邀请通过受控 API/MCP 可用；这不等于所有高层代理运行时已完成秘密管理。A2A、Flutter 商业认证与商业融云接收、全部 Agent 好友/商店/组织 UI 等继续是后续范围。

## 验证与相关文档

Go 最终生产回归使用真实隔离 PostgreSQL 与 `-race`：**267 个顶层用例 + 316 个子用例通过，0 失败、0 测试跳过**。5 个无测试文件包单独记录。 [完整日志](evidence/workspace-invitation-stage/go-production-tests.jsonl) 与 [汇总](evidence/workspace-invitation-stage/go-production-summary.json) 可复核；邀请、接收读取专题的定向计数与此重叠，不重复累加。剪贴板修复后的最终 Web **206/206**、桌面 **10/10**，TypeScript、preload 与生产 Web 构建通过。单包体积提示仍保留，不代表打包优化或正式安装包已完成。 [Web 日志](evidence/workspace-invitation-stage/web-final-tests.txt)、[桌面日志](evidence/workspace-invitation-stage/desktop-final-tests.txt)、[构建日志](evidence/workspace-invitation-stage/web-final-build.txt)。旧临时 `services/collaboration/output` 含两份同包 main 验收脚本，不是生产包；生产 Go 回归明确检查 `./cmd/... ./internal/...`。干净实施 worktree 的 `./...` 也编译运行；其中本地 AFFiNE codec 的 Node 依赖不随 Git worktree复制，出现的依赖缺失跳过会由主工作区的真实依赖回归补验，不能删去跳过记录伪装全通过。

- [本机手动启动教程](MANUAL_STARTUP_GUIDE.md)
- [邀请核心与权限专题](WORKSPACE_INVITATION_KERNEL_1025.md)
- [电脑端复制与弹窗修复专题](../../../apps/web/docs/INVITATION_NATIVE_COPY_DIALOG_FIX_20260909_1045.md)
- [客户端邀请与会话摘要专题](../../../apps/web/docs/WORKSPACE_INVITATIONS_AND_ROOM_PREVIEWS_20260909_1031.md)
- [上一阶段交付](STARTUP_ACCOUNT_BRIDGE_DELIVERY_0943.md)

本报告冻结后使用唯一新发布器归档到 Doc Free，并建立独立 AFFiNE/Docmost 投影；发布结果以随后独立回执为准。发布器保护既有 7 份源文档、14 份投影、6 组配置与 journal，不覆盖上阶段记录。全量飞书像素级复刻、五端生产签名/分发、全面自主执行等未在本阶段完成。
