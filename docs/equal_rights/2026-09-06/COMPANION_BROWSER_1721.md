# 机伴浏览器执行原型实现记录

- 记录时间：**2026-09-06T17:21:00+08:00**（Asia/Shanghai）。
- 分支：`equal_rights`。
- Active Agent 基线 commit：`3beae3137c3193555360145300f81a0b5a1c888c`，`2026-09-06T12:49:59+08:00`，`docs: record office 0.5 release and verified native workflows`。
- 配套 Doc Free 当前 commit：`b068445dfa0f5f8f388035b71c3bb93654894e60`，`2026-09-06T17:04:19+08:00`，`feat: add personal navigation, shared minutes and default agent colleagues`。
- 描述：新增可独立运行的本地“机伴”浏览器执行服务，为后续 IM 插件提供受限动作、异步任务和认证截图接口。本文是本轮工作区实现记录，以上 commit 是实现前可引用基线；本轮最终合入 commit 由汇总提交记录补充。

## 实现与使用

代码位于 `packages/companion`，Node.js 22+，锁定 `playwright-core@1.62.1`，使用本机已安装 Chrome。依赖从现有 npm 缓存离线安装并使用 lockfile integrity 校验，没有下载浏览器或使用真实登录 profile。

接口、启动配置、状态和限制以 [包 README](../../../packages/companion/README.md) 为准。服务默认 `127.0.0.1:3780`、headless、强制 bearer token；支持 navigate/click/type/inspect/screenshot。会话使用独立 BrowserContext，各自串行、跨会话并行。紫色“机伴”光标仅是网页内视觉标记，不控制系统鼠标。

网络转发覆盖页面和子资源 HTTP。origin 必须匹配 allowlist；远程 DNS 全结果必须为公共单播地址，连接固定到已校验地址，保留 Host/TLS 验证；literal loopback 是本地开发的明确例外。重定向每跳检查，WebSocket 阻断。服务未宣称系统级防火墙或任意恶意网页沙箱。

## 本轮验证证据

`cd packages/companion && npm test`：**6/6 通过**，约 **3.8 秒**。本次合成 Chrome 流程进行了 **113** 次认证/拒绝 HTTP 检查（轮询次数可随机器速度变化）。

| 场景 | 验证结果 |
| --- | --- |
| 两个会话并行 | 合成服务器等待两个初始导航都到达才返回；两者通过，排除全局串行队列 |
| 同会话串行 | 第一个响应被门闩拦住时，第二 job 保持 queued；释放后按顺序完成 |
| 存储隔离 | 不同会话分别保留自己的 localStorage，Cookie 不泄露给另一会话 |
| 压缩与 Cookie | gzip 页面真实解码渲染，两个 Set-Cookie 后续均随原会话请求发送 |
| 禁用网络 | 禁用 origin 的导航、302、image、script、iframe、fetch、WebSocket 全部没有到达目标合成服务器 |
| DNS 地址固定 | 私网/元数据/IPv4 映射与特殊地址拒绝；混合公私 DNS 结果拒绝；模拟重绑定时只解析一次，连接回调始终得到已检查公共地址 |
| 超时 | 700 毫秒测试 job 关闭上下文、取消后续 job；服务 health 继续可用 |
| 截图 | PNG 签名与 SHA-256 一致；无 token 请求返回 401，关闭会话后返回 404 |

本轮测试捕获并修复了两个真实传输问题：Playwright fulfill 需要先解压响应体；IPv6 文档地址 `2001:db8::/32` 需显式拒绝。真实浏览器回归在修正后通过。

已查看合成截图 `output/companion/synthetic-virtual-pointer.png`，能看到紫色“机伴”光标停在实际点击按钮，页面包含合成数据。当前 SHA-256：`ce23efe02ed0ad9dcf0fc5c68e581071167d495270605f3c2df59afe51ef4a11`。该目录被忽略，不包含真实账户截图。

## 交付边界

没有留下常驻服务，没有连接或停止现有 3218 服务，没有控制原生应用、手机或系统键盘鼠标，没有写入真实用户网页。当前服务本身已实现并测试；IM 插件适配、消息权限关联、长任务持久化、跨机器服务、安全容器和 iOS 跨 App 操作均不在本包已完成能力中。
