# 人机 Web / Electron 共用客户端

记录日期：2026-09-09，Asia/Shanghai。当前分支 `startup`；本次工作从 Active Agent `acee8003c7c55694716778189179ec272da44347`（2026-09-09T01:22:28+08:00，阶段交接文档）出发。本文记录新客户端实现边界，不能作为商业上线或全量飞书复刻完成证明。

## 启动

在 Active Agent 仓库根目录使用 Node 24.15.0 或更高兼容版本：

```sh
ELECTRON_SKIP_BINARY_DOWNLOAD=1 npm ci --ignore-scripts
cp apps/web/.env.example apps/web/.env.local
npm run dev:web
```

浏览器打开 `http://127.0.0.1:5173`。配置值修改需要 Vite 重启；React 页面修改支持热更新。当前本机配置已写入被 Git 忽略的 `apps/web/.env.local`，不要覆盖它来重复设置。秘密凭据不可进入任何 `VITE_` 变量；它们会被打进客户端资产。

| 配置 | 作用 |
| --- | --- |
| `VITE_API_BASE` | 新 Go 服务，当前开发地址 `http://127.0.0.1:3318` |
| `VITE_CLERK_PUBLISHABLE_KEY` | Clerk **公开**应用标识；只能放 publishable key，不能放 secret key |
| `VITE_ENABLE_LEGACY` | 默认 false；显式 true 才显示“现有数据迁移”入口 |
| `VITE_LEGACY_API_BASE` | 既有 doc_free 办公服务，当前开发地址 `http://127.0.0.1:3218` |

旧服务对跨域登录预检的处理无法直接支持本次浏览器登录。因此开发服务固定把 `/legacy/api/im/*` 转发到 `127.0.0.1:3218`。只有开发模式且用户选择的源严格等于该地址时采用这条路由，界面仍标示真实源地址；没有任意目标代理，不改变旧服务权限，不关闭 Electron Web 安全。生产构建没有该代理，部署迁移入口须另行配置可信反向代理或源服务 CORS。

## 真实页面和边界

- 商业工作空间使用 Clerk 登录，由 Go `GET /v1/me` 得到稳定 Principal。认证失败不会退回旧密码认证。
- Go 会话和消息页通过 `/v1/rooms`、`/v1/rooms/:id/messages` 读取真实资源；发送使用持久动作 ID、内容和停止代次。当前未开放的新业务不能由客户端伪造。
- 迁移模式读取既有会话、置顶、未读、免打扰、消息窗口、真实 Agent 目录及文档列表；支持发送、@ 当前成员、创建群、打开单聊、置顶和免打扰。创建群后的成员管理继续由旧客户端承担。
- 文档页当前读取可见文档并打开所属会话，未声称已经迁移完整编辑器、AFFiNE/Docmost 同步状态。完整编辑、归档、权限及下游同步继续由 Document Gateway 任务实现。
- 桌面消息栏采用固定发送按钮位置，中文输入法组合期间不拦截 Enter；没有全局键盘监听、输入事件回放或自动输入。这只能证明新客户端输入处理边界，不能证明整个电脑的历史重复输入问题已根治。
- 服务端回执未知时不显示伪造的已读数；旧 `receipt_summary.known/eligible_count/read_count` 正确映射。
- 左键打开会话；右键显示真实置顶和免打扰动作。主头像圆形，“+” 菜单有图标且先本地弹出，再触发网络动作。

人机业务适配器仅在运行内存持有访问令牌，不把 Token 写进 localStorage、query key 或业务日志；Clerk SDK 自身的登录会话由其认证机制管理。身份切换会取消旧请求并清 Query 缓存；旧异步响应不能进入新会话。写入成功与后续刷新独立，未知结果的重复提交复用同一个动作 ID。

## 融云是必须接入的传输组件

用户最新纠正优先于蓝图的旧建议：本期融云必须接入并验证，Centrifugo 不替代它。

新服务提供 `POST /v1/transport/rongcloud/session → {app_key,user_id,token}`。客户端先完成业务身份认证，再使用服务端绑定的融云用户连接。React 接入 `@rongcloud/engine` 和 `@rongcloud/imlib-next` 5.46.0；Electron 两个附加包也固定为 5.46.0。四包版本不能独立漂移。

客户端不调用融云 SDK 的发送接口。正式消息经 Go 写入 PG 与 Outbox，服务器可靠投递融云；SDK 连接后的消息通知仅让客户端重读 Go 权威会话/消息，传输消息正文不直接加入 UI。断线时 5 秒补拉是临时同步措施，不替代完整游标补拉、服务端版本、撤权和消息投递回执验收。

SDK 配置、用户绑定、连接确认、监听移除及身份切换已具备实现与测试；真实 Clerk 登录、融云套餐/多端连接、Go Outbox 投递、多用户多 Agent 端到端仍须用实际运行证明。Web 云历史需要相应服务配置；本文没有声称已开通任何套餐。

官方依据：[React 版本](https://react.dev/versions)、[Clerk React 快速开始](https://clerk.com/docs/react/getting-started/quickstart)、[融云 Web 接入](https://docs.rongcloud.cn/web-imlib/quickstart)、[融云事件监听](https://docs.rongcloud.cn/web-imlib/listener)、[融云 Electron 集成](https://docs.rongcloud.cn/web-imlib/electron/integration)。版本已从官方 npm registry 核实，锁文件保存包完整性。

## 迁移保留清单

| 领域 | 既有路径（继续保留） | React / Electron 路径与现状 |
| --- | --- | --- |
| Android/iOS 与旧端回退 | `apps/office/` | 不删除或修改；新桌面为 `apps/desktop/`，Web 为本目录 |
| 协作/认证协议 | `apps/office/lib/office_state.dart` | `src/types.ts` + `src/api.ts`；两个明确适配器，无静默降级 |
| 主导航/个人页 | `ui/office_shell.dart`、`ui/desktop_navigation.dart`、`ui/profile_menu.dart` | `src/App.tsx` 首个壳；完整设置、导航编辑、组织切换尚待迁移 |
| 会话及上下文菜单 | `ui/conversation_list.dart`、`ui/conversation_context_menu.dart` | 会话/置顶/免打扰已接旧 API；分组树、标签和批量管理未完整迁移 |
| 消息与输入 | `ui/conversation.dart`、`ui/message_hover_tools.dart` | 文本、成员 mention、分页历史、同意图重试；富文本、附件、语音、话题等继续迁移 |
| Agent 组织目录 | `ui/agent_friend_directory.dart`、`ui/agent_catalog.dart` | 真实目录与组织筛选；职业/分类树、商店安装与人格设置继续迁移 |
| 云文档 | `ui/document_editor_launcher.dart` | 真实授权目录；编辑器不能 iframe 绕过原 CSP，后续接受控单文档窗口 |
| 工作台/日历/会议/审批/邮箱/妙记/企业后台 | 各 Flutter 对应页面及已有协议 | 尚未在新 React 宣称完成；必须逐域迁移真实接口与页面 |
| 能力/插件边界 | 既有 `/api/im/capabilities` | `src/capabilities.ts` 稳定动作/导航 ID；Go 动作内核为权威 |
| 全局设备操作 | 既有机伴独立能力包 | 本产品 renderer 无键鼠/终端权限；后续独立 Runner，不往 UI 加任意命令入口 |

## 验证

```sh
npm run check:clients
npm run test:clients
npm run prepare:preload --workspace @renji/desktop
npm run build:web
```

测试覆盖真实协议字段、鉴权失败无降级、身份失效/迟到响应、明确的本地代理范围、重复动作 ID、中文组合输入、Agent 成员 ID、菜单点击、旧回执已知性和融云连接生命周期。它们不代替多端真机、截图像素对比、生产签名/更新、离线缓存/恢复或完整商业验收。

2026-09-09T03:26:36+08:00 本轮验证：Web 21/21、桌面边界测试 6/6、TypeScript/Node 语法检查、双预载/原生传输 Worker bundle 和 React production build 通过。该时间对应本次未提交实现的检查，代码提交 SHA 待主任务冻结时补到阶段交付记录。构建仍提示融云 SDK 包内的 Node `path` 分支被浏览器外置，以及 SDK 动态 chunk 约 790 KB；未宣称完成包体优化。
