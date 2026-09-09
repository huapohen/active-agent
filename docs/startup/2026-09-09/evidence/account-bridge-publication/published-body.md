# 人机商业阶段交付：Clerk 开户协作与融云真实接收桥

记录时间：`2026-09-09T09:43:30+08:00`（Asia/Shanghai）。阶段分支：`startup`。

实施提交：`e975e94e900cc892e39ed52ac0ce94ccd71c6ea1`。提交时间：`2026-09-09T09:35:36+08:00`。描述：`feat(startup): onboard colleagues and relay verified RongCloud arrivals`。

阶段开始基线：`ddd947c7c3f74168ad1a17b11d4b04b5eb4599ad`，`2026-09-09T08:34:06+08:00`，`docs(startup): preserve message phase publication and native repair receipts`。DocFree 仓库保持 `equal_rights` 的 `dc728ddc99ce3bc7346bb4dc364824bbb32b1101`，本阶段没有修改其实现。

## 1. 这一阶段交付了什么

用户亲自完成 Clerk 真人验证与邮箱验证码后，电脑端已经进入正式 Human 身份。新账号最初没有任何工作空间、群或特权。本阶段补上真实的个人资料、工作空间列表、创建工作空间、成员读取和建群入口；所有写入由 Go 服务鉴权并保存。

在运行的人机 Electron 中实际完成：昵称改为 `huapohen`，创建“人机共创工作空间”，创建“人机 · 新账号协作验收”。本人是该工作空间和群的所有者，当前群只有本人。随后发送一条中文消息、引用它发送一条回复，并通过完整表情面板添加一个 OK 回应。界面刷新后记录仍在，独立数据库读回确认只有一个空间、一个群、两个消息和一个激活回应。

融云是必用的消息运输组件。本阶段另在既有受控合成群完成真实发送、官方 SDK 接收、Go 持久入站对账和重连去重。它与上述新 Human 的单人群是两组明确区分的验收，不把合成接收人的成功当成新账号已接入融云接收。

## 2. 新账号如何使用

已注册用户用 Clerk 登录，进入“个人资料”设置同事能看到的昵称。“工作空间”显示当前合法成员身份；可以选择已加入的空间，也可以创建自己拥有的新空间。“创建群聊”只列出该空间真实可选择的成员，Human 与 Agent 都按各自 principal ID 提交。只有本人时也允许先建一个群。

头像菜单现有“个人资料”“工作空间”；头像旁和消息标题旁的加号进入建群。原先迁移模式的接口继续独立存在，不能当作 Clerk 商业身份。普通启动、客户端登录和建群均不会启动通用模型 Worker 或自动派发历史 Outbox。

详细操作与服务、电脑版、手机模拟器启动方式见 [手动启动教程](https://github.com/huapohen/active-agent/blob/3705fb59266ddaa25414fb0794ec292e6ff20239/docs/startup/2026-09-09/MANUAL_STARTUP_GUIDE.md)。原 Flutter 手机教程保留；本阶段商业新账号链路实际验收的是 Electron/Web，手机仍使用迁移服务。

## 3. 接口、Agent 与一致性

新增本人资料读取和版本化修改、工作空间分页、空间成员分页、群成员分页。HTTP、MCP 使用同一服务授权和实际数据。昵称为 trim 后 1–80 个 Unicode 字符，拒绝控制/格式控制及不合法字符；空间与群名称最多 240 个 UTF-8 字节。分页游标严格绑定合法 UUID 顺序，不把第一页当全量目录。

Agent 能通过 Run 原生读取和修改自己的昵称。机器身份来自已认证执行器绑定，修改必须携带已存 Run、正确来源范围和确定的 action ID；资料写入、执行动作回执及证据处于同一事务。Run 的停止、来源 epoch、权限撤回及执行器状态仍检查；没有让机器自行选择另一个 principal。

目前 registry 为 23 项能力。普通客户端的融云 token 入口如未在明确的测试身份名单中，能力声明即为不可用。接收事件 HTTP 对 Human 可读；Machine/run-bound 接收仍未开放，明确声明不可用。机器全局建空间、建群也仍待来源继承闭环，不能据现有接口数量宣称全部 IM 已 Agent 原生化。

表单在请求前保存原操作记录和 action ID。关闭弹窗、网络中断或刷新不会把未知结果换成新建意图；用户核对时重放原动作，再读取当前资料、空间或群成员。精确的昵称版本冲突允许读取新版本后修正；通用冲突、已提交后读回失败不能被当作没提交。切身份、切空间、成员撤销及迟到响应都受隔离；发布新数据前还会取消后台旧查询，避免旧结果覆盖已确认的新资料。

实现与真实 PostgreSQL/MCP/Eino 测试细节见 [资料与工作空间专题](https://github.com/huapohen/active-agent/blob/3705fb59266ddaa25414fb0794ec292e6ff20239/docs/startup/2026-09-09/PROFILE_WORKSPACE_CORE_0910.md)、[后端证据](https://github.com/huapohen/active-agent/blob/3705fb59266ddaa25414fb0794ec292e6ff20239/docs/startup/2026-09-09/PROFILE_WORKSPACE_CORE_EVIDENCE_0910.json) 和 [客户端独立复核](https://github.com/huapohen/active-agent/blob/3705fb59266ddaa25414fb0794ec292e6ff20239/apps/web/docs/COMMERCIAL_ACCOUNT_INDEPENDENT_REVIEW_20260909_0908.md)。

## 4. 融云真实运输与接收

Go 保有 canonical 消息和授权，精确 Outbox 调用融云 Server API。可信开发接收进程持有服务端配置的 token，使用官方 Web IMLib 真正监听 SDK 收包。商业 renderer 只读取 Go 当前授权的接收通知，不获得供应商 token。

本次仅向融云外发一条合成文本：message `f35e0e72-e008-437f-8d45-59b93413c2d0`，event `22`，outbox `7`，provider UID `D0GE-T1V8-LGOE-75D4`。融云受理时间为 `2026-09-09T09:13:28.122214+08:00`；Go 对实际 SDK 观察核验后记录 cursor `1`，接收时间 `2026-09-09T09:13:28.230111+08:00`。同一真实观察重复提交，以及同 token 重连再次收到原 UID，都保持原 cursor 和原时间。旧 Outbox 5/6 的原始行哈希保持不变。

本地入站必须匹配已受理 Outbox、来源事件、UID、群、发送人及正文/指针。当前成员和 Agent 来源停止策略同样检查。没有对应接收覆盖的新 Human 账号仍显示“融云接收桥未接入”；心跳不等于收包，`last_received_at` 只来自真实入站。

原生桌面 SDK 首次连接返回 31003，实际未开通该供应商服务；保留这条失败证据后，用同一身份和 token 验证官方 Web SDK 路径。没有修改融云控制台政策或重建群来掩盖原结果。这仍是本机受控开发桥，生产云端路由及所有账号的覆盖没有完成。

独立审查发现并修复三处问题：旧队列可能串接收身份、改绑心跳更新零行却返回成功、迟到 connected 覆盖新 disconnected。现在目录和逐条日志固定身份/应用/范围指纹，身份核验前不排队投递；改绑冲突明确失败；心跳持久递增序号、串行发送，服务端拒绝倒退。已应用的迁移 00008 原样保留，使用独立 00009 增加心跳序号。当前数据库已经实际升级到 schema 9。

官方依据、精确协议和原始脱敏回执见 [融云接收桥专题](https://github.com/huapohen/active-agent/blob/3705fb59266ddaa25414fb0794ec292e6ff20239/docs/startup/2026-09-09/RONGCLOUD_TRUSTED_RECEIVE_BRIDGE_0937.md) 及其 [证据清单](https://github.com/huapohen/active-agent/blob/3705fb59266ddaa25414fb0794ec292e6ff20239/docs/startup/2026-09-09/evidence/rongcloud-receive-bridge/MANIFEST.json)。

## 5. 验证范围与证据

- Go 全部生产包 `./cmd/... ./internal/...` 使用真实隔离 PostgreSQL 执行 race：235 个顶层测试与 264 个子测试通过，0 失败、0 跳过。历史 ignored output 中一个旧 probe 有两个 main，保留其证据并明确排除该临时目录；没有用该失败宣称生产包全通过。
- Web 155/155；Electron 6/6；接收桥 Node 8/8。TypeScript、Go vet、Web 生产构建通过。Web 仍有单个压缩包大于 500 kB 的构建提示，不属于功能验证。
- 独立接收审查的 1 个 P1 与 2 个 P2 已关闭，回归记录保留原发现与修复状态，不能把重叠测试数量累计冒充新增覆盖。
- 真人 Clerk：同一 principal 的昵称版本为 2；1 个空间、1 个群、1 位成员、2 个中文消息，其中 1 个回复；1 个 `feishu:OK` 激活回应。没有造其他用户、授予全局管理员或添加未经邀请的同事。
- 原生输入本次采用针对具体字段的一次赋值并核对，未出现重复字符串；这不证明全局物理键盘/输入法与电脑控制并用时的问题已经修复，也未重新验证镜像或模拟器中文输入。

[本阶段证据清单](https://github.com/huapohen/active-agent/blob/3705fb59266ddaa25414fb0794ec292e6ff20239/docs/startup/2026-09-09/evidence/account-onboarding/MANIFEST.json) 包含原生截图、独立数据库读回、测试记录摘要、升级前备份及运行版本记录。[新账号界面](https://github.com/huapohen/active-agent/blob/3705fb59266ddaa25414fb0794ec292e6ff20239/docs/startup/2026-09-09/evidence/account-onboarding/human-onboarding-created-native.png)、[表情面板](https://github.com/huapohen/active-agent/blob/3705fb59266ddaa25414fb0794ec292e6ff20239/docs/startup/2026-09-09/evidence/account-onboarding/human-emoji-catalog-native.png)、[消息与回复](https://github.com/huapohen/active-agent/blob/3705fb59266ddaa25414fb0794ec292e6ff20239/docs/startup/2026-09-09/evidence/account-onboarding/human-messages-reply-reaction-native.png) 可直接对照。

## 6. 尚未完成与下一阶段

完整目标仍是人机共生同权、主动式 Agent 原生办公 IM。当前阶段只推进其中一条真实链路，不能视为商业版、全量飞书像素复刻或五端验收完成。

下一阶段需要补合法邀请/加入空间流程与多人账号协作；将新 Human、Agent 及工作空间正当地接入融云接收，完成机器 Run 原生接收和派生群来源继承；扩展 Agent 主动执行与任务落盘，继续补齐 A2A/MCP/API 覆盖；把商业文档入口接通到 DocFree 并保留 AFFiNE、Docmost 两处可核验投影。现有新版会话列表摘要、未读、成员邀请、Agent 入口、设置/后台和移动端商业接入仍有明显缺口，不能用旧迁移客户端的功能覆盖来替代证明。

本交付正文将在独立发布记录中冻结到 Git，再作为新 DocFree 文档同步到 AFFiNE 和 Docmost。以发布回执和实际原生读回为准；正文不预先宣称同步成功，也不改写此前六份源文档与十二个投影。
