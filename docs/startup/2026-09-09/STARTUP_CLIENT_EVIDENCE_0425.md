# Startup 客户端阶段证据审计

- 审计时间：2026-09-09 04:25（Asia/Shanghai）。
- 范围：只读检查源码、文档、现有测试记录、进程与 HTTP；没有 GUI 操作、服务重启、登录请求或整套测试重跑。
- 分支：`startup`。
- 客户端实现已提交：`71b80f8181fa243b7477ebac0c35c6ce13e2c960`，2026-09-09T04:11:17+08:00，`feat(desktop): introduce Electron React workspace and isolated RongCloud adapter`。
- 当前内核实现提交：`a9005c01ee059b3f093d877ae1eb13828075d692`，2026-09-09T04:15:30+08:00，`feat(core): add Clerk-bound agent runs, RongCloud outbox, and document projections`。

## 实际登录与交付范围

`apps/web` 与 `apps/desktop` 是已提交的 React/TypeScript 与 Electron 客户端。03:31:36 的原生 GUI 验收记录确认 Electron 使用**现有数据迁移登录**进入真实账号与会话列表；原数据来自 3218，通过固定的 Vite `/legacy/api/im/*` 代理访问。此结果不是 Clerk 真人商业登录验收。本次只读审计没有重新读取屏幕，不能仅凭进程存在断言此刻显示的页面。

实际页面包括迁移账号登录、真实会话与消息、成员及 Agent 标识、历史分页、会话置顶/免打扰/未读操作，以及已有 Agent、文档入口。Clerk 登录入口与新 Go API adapter 已存在；两种模式明确分开，Clerk 失败不会自动降级为旧账号认证。

浏览器原生 `fetch` 接收者修复已经包含在客户端提交中。原生 GUI 再次输入和登录成功只能证明该次操作正常，不能证明此前整机重复输入问题已经彻底修复。

## 测试与构建证据

最近一次完整客户端测试记录为 2026-09-09 03:31:25 起（npm 文件名使用 UTC）：

| 证据 | 实际内容 |
| --- | --- |
| `/Users/lwblx/.npm/_logs/2026-09-08T19_31_25_274Z-debug-0.log` | `npm run test:clients`，退出 0 |
| `/Users/lwblx/.npm/_logs/2026-09-08T19_31_25_373Z-debug-0.log` | Web workspace 测试，退出 0 |
| `/Users/lwblx/.npm/_logs/2026-09-08T19_31_26_844Z-debug-0.log` | Desktop workspace 测试，退出 0 |
| `/Users/lwblx/.npm/_logs/2026-09-08T19_31_27_035Z-debug-0.log` | `npm run build:web`，退出 0 |
| `apps/web/node_modules/.vite/vitest/da39a3ee5e6b4b0d3255bfef95601890afd80709/results.json` | `api.test.ts`、`App.test.tsx`、`rongcloud.test.ts` 均 `failed: false` |
| `apps/web/LOGIN_ACCEPTANCE_20260909.md` | 当时记录 Web 22/22、Desktop 6/6、类型检查及生产构建通过，包含真实 GUI 登录证据 |

当前未变更的测试源码分别有 11、7、4 个 Web 用例，合计 22；`apps/desktop/test/security.test.cjs` 有 6 个用例。npm debug 文件保留了命令与成功退出状态，并非完整逐条断言 stdout；22/22 与 6/6 数量由当时验收文档、源码计数和 Web 缓存交叉核实，本次未重跑以制造新证据。

`apps/web/README.md` 中更早的 21/21 是新增原生 fetch 回归用例前的历史结果。旧验收文档中的“尚未提交”描述对应其原始记录时间；当前实现已经进入上述 `71b80f8` 提交，不应沿用为当前状态。

## 当前运行检查

04:25 的端口检查仍发现：

| 服务 | 地址 | PID | 只读结果 |
| --- | --- | --- | --- |
| 旧 Doc Free / IM | `127.0.0.1:3218` | 53740 | 正在监听；约 04:20 经 `/legacy/api/im/auth/providers` 返回 HTTP 200 |
| React Vite | `127.0.0.1:5173` | 57911 | 正在监听；约 04:20 首页 HTTP 200、HTML 标题含“人机” |
| 新 Go API | `127.0.0.1:3318` | 63458 | 正在监听；约 04:20 `/healthz` 返回 HTTP 200 |
| Electron | 本机进程 | 58132 | 约 04:20 主进程、Helper 与 Renderer 均存在；未操作窗口 |

运行日志：`/tmp/renji-startup-web-20260909.log`、`/tmp/renji-startup-desktop-20260909.log`。它们是开发服务日志，不能替代测试日志。没有为本审计重启正在供用户查看的客户端。

## 留给下一阶段的明确差距

- Clerk 真人跨端登录、刷新与权限闭环尚未实际验收；Flutter 手机仍使用旧栈。
- 融云服务端合成群和消息已有真实回执，见 `docs/startup/2026-09-09/RONGCLOUD_OUTBOX_SYNTHETIC_PROBE_0356.md`；**Web/Electron/Flutter 的真实客户端收包、跨端同步和断线恢复尚未验收**。SDK adapter 单元测试不等于真实客户端接收成功。
- 新 React 页面尚未覆盖旧 Flutter 已有的全部分组、富文本、附件、语音、话题、设置、企业管理及办公模块，更未达到全量飞书页面像素级复刻。
- 生产签名、公证、Windows 安装包及更新流程尚未完成。当前 Electron 为开发模式。
- 全量 API/MCP/A2A、办公插件及外设能力尚未完成，应以 Go `/v1/capabilities` 的实际覆盖为准。

手动启动步骤另见 `docs/startup/2026-09-09/MANUAL_STARTUP_GUIDE.md`。本审计文件未包含账号密码、API Key、会话 token 或私有配置值。
