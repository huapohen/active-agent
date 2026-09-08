# 人机 Electron 桌面

记录日期：2026-09-09，分支 `startup`。当前客户端从 Active Agent `acee8003c7c55694716778189179ec272da44347` 开始新增；尚未发布桌面商业版本。Web/业务迁移详见 [Web 说明](../web/README.md)。

## 热开发

仓库根目录先运行 `npm run dev:web`。Electron 官方安装器下载会校验发行物；先按本机 AGENTS.md 短测 GitHub 和当前网络路线，不在无进展线路反复下载。

```sh
node node_modules/electron/install.js
npm run dev:desktop
```

`npm run dev:desktop` 会构建受限产品预载和独立融云通信窗口，再启动 Electron。默认渲染 `http://127.0.0.1:5173`。`RENJI_WEB_DEV_URL` 仅接受本机 HTTP 地址，不接受远程页面；应用 UI 修改由 Vite 热更新，主进程/预载修改需要重启 Electron。

当前开发记录：2026-09-09 已安装 Electron 44.2.0、已启动 Vite 和新桌面；日志分别是 `/tmp/renji-startup-web-20260909.log`、`/tmp/renji-startup-desktop-20260909.log`。这两处是临时开发日志，运行状态以当前进程为准，不保证一直在线。

原生融云连接需要在启动环境提供公开的 `RENJI_RONGCLOUD_APP_KEY`，必须与 Go 会话接口返回的公开 App Key 一致。不要把融云 App Secret、Clerk Secret 或用户 Token 放入启动参数、文档或源码。首次 UI 验证先通过显式“现有数据迁移”连接既有 3218 数据；这不等于新融云消息链已验收。

## 桌面能力边界

- 产品 renderer 保持 `contextIsolation: true`、`nodeIntegration: false`、`sandbox: true`、`webSecurity: true`；没有键盘/鼠标全局 Hook、输入回放、任意 Shell、文件或通用 IPC。
- 产品 preload 只暴露具名融云连接/断开和受限状态通知。
- 融云官方 Electron SDK 5.46.0 的 preload 暴露通用 SDK IPC。它被放在独立隐藏传输窗口，这个窗口不加载用户消息、Clerk 登录页或远程 HTML。业务 renderer 不拿到该 SDK 通用桥。
- 原生 SDK 的 App Key 固定于进程；账号切换必须等待断连/关闭数据库回执。结果未知时冻结新的传输会话，显示不可用，不能把超时当成已断开。
- 传输窗口只向业务页发送连接状态或“需要重新读取”通知，不传递消息正文或 Token。读取/发消息仍走 Go 的当前身份授权。
- 新窗口、非受信顶层导航、webview 和权限请求默认关闭；外部文档窗口/系统通知/会议权限将在各自模块明确实现后开放。

正式桌面打包、macOS 签名/公证、Windows 安装包与签名、安全更新、缓存加密、系统通知、独立 Runner、多窗口资源隔离和真实原生融云多端验收仍未完成。打包配置也须重新验证 Clerk 登录跳转及生产内容安全策略；开发壳可运行不能作为上线证明。

安全依据：[Electron 安全指南](https://www.electronjs.org/docs/latest/tutorial/security)、[上下文隔离](https://www.electronjs.org/docs/latest/tutorial/context-isolation)、[进程沙箱](https://www.electronjs.org/docs/latest/tutorial/sandbox)、[融云 Electron 集成](https://docs.rongcloud.cn/web-imlib/electron/integration)。
