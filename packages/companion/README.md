# 机伴：隔离浏览器执行服务（原型 0.1）

机伴在独立 Chrome BrowserContext 中执行固定浏览器动作。两个会话可以并行，每个会话内按提交顺序执行。页面内的紫色“机伴”光标会移动到目标并显示点击位置；系统鼠标不受控制。

这是可运行的执行服务。IM 插件需要通过受信任的本地后端适配器调用它，并把任务状态与结果挂到人机可见的消息/文档中。当前包没有自动安装 IM 插件，也没有操作原生应用或手机其他 App 的能力。

## 启动

需要 Node.js 22+ 和已安装的 Chrome/Chromium。依赖为锁定版本 `playwright-core@1.62.1`，安装不会下载浏览器。先按本机网络约定确认 npm 线路；缓存完整时可以离线安装：

```sh
cd packages/companion
npm ci --offline --ignore-scripts --no-audit --no-fund
```

首次启动可在当前终端生成随机 token；请由本机密钥管理或已忽略的 `.env.local` 保存实际凭据。不要把凭据放入消息、任务 JSON、URL 或截图链接。

```sh
export COMPANION_TOKEN="$(node -e 'process.stdout.write(require("node:crypto").randomBytes(32).toString("base64url"))')"
export COMPANION_ALLOWED_ORIGINS='http://127.0.0.1:3000'
npm start
```

实际本地页面端口不是 3000 时须相应修改。服务默认只监听 `127.0.0.1:3780`，日志只打印服务名、监听地址与 headless 状态，不打印 token。按 Ctrl+C 会关闭服务及全部上下文。包不注册常驻服务。

| 环境变量 | 行为 |
| --- | --- |
| `COMPANION_TOKEN` | 必填；至少 32 字符的随机 bearer token |
| `COMPANION_PORT` | 默认 3780，固定绑定 127.0.0.1 |
| `COMPANION_CHROME_PATH` | 可选，Chrome 可执行文件的绝对路径；默认探测常规安装位置 |
| `COMPANION_ALLOWED_ORIGINS` | 逗号分隔精确 HTTP(S) origin，包含协议和端口，不含路径；建议显式设置到所需页面 |

省略 allowlist 时允许 `localhost`、`127.0.0.1`、`[::1]` 的 HTTP(S) origin，端口不限。显式空字符串拒绝所有页面。`localhost` 固定连接 127.0.0.1；IPv6 本地服务可使用 `[::1]`。远程允许域名仍必须只解析到公共单播地址，不能借域名或显式 origin 访问内网/元数据地址。

程序不自动加载 dotenv。使用本地环境文件时可显式执行 `node --env-file=.env.local server.js`；`.env` 和 `.env.*` 均被 Git 忽略。

## API 合同

所有请求（包括 health、capabilities、PNG）必须包含 `Authorization: Bearer <token>`。POST 使用 `Content-Type: application/json`。所有响应 `Cache-Control: no-store`。不支持 query 参数、CORS 或带 `Origin` 的浏览器请求，Host 必须是实际的 `127.0.0.1:<port>`；应通过后端适配器调用，不能把 token 打包到网页客户端。

| 方法和路径 | 输入 / 输出 |
| --- | --- |
| `GET /health` | `{ok:true,service:"active-companion",version:"0.1.0"}` |
| `GET /capabilities` | 固定动作、allowlist、限制与能力边界 |
| `POST /sessions` | `{}` 或 `{viewport:{width:1100,height:760}}` → 201 `{session:{id,created_at,viewport,isolated:true}}` |
| `POST /sessions/:session_id/jobs` | `{actions:[...]}` → 202 `{job:{id,session_id,status,submitted_at,started_at,finished_at,results,error}}` |
| `GET /jobs/:job_id` | `{job:{...}}`，状态 queued/running/succeeded/failed/cancelled |
| `GET /screenshots/:image_id` | 认证 PNG；具体路径由 screenshot 动作结果返回 |
| `DELETE /sessions/:session_id` | `{closed:true}`，关闭上下文并移除关联任务和截图 |

执行示例。选择器应依据该会话中 `inspect` 返回的实际 DOM 再确定；以下只是合成页面的合同示例：

```json
{
  "actions": [
    {"type": "navigate", "url": "http://127.0.0.1:3000/"},
    {"type": "inspect"},
    {"type": "type", "selector": "#entry", "text": "Synthetic work note"},
    {"type": "click", "selector": "#apply"},
    {"type": "screenshot"}
  ]
}
```

`inspect` 可指定 `selector`，默认 body，返回当前 URL、最多 500 字符标题、20,000 字符可见文本和 100 个控件元数据；这些输出在浏览器内截断后才跨进程返回，不读取输入框 value。控件 label/placeholder 最多 160 字符，role/type/tag 最多 64 字符；超过 256 字符的 id/name 返回 null，避免把截断标识误用为选择器，并设置控件 truncated。`type` 用 fill 替换字段内容，不自动提交，结果仅含字符数。`click` 和 `type` 必须匹配单个可见目标。选择器为最多 500 字符 CSS，不接受 selector chaining 或代码执行参数。页面自身正常脚本仍会执行。

截图结果示例为 `{type:"screenshot",path:"/screenshots/image_<id>",bytes:36568,sha256:"..."}`。图片保存在服务内存，不能把 path 当成可公开访问的 URL；适配器应认证拉取图片后按当前 IM 会话权限展示。未完成 job 的 `results` 可能只有此前已完成动作。失败返回 `{code,message}`，不转发 Playwright 原始异常正文。

## 限制与网络行为

- 最多 2 个上下文；viewport 320–1920 × 240–1080。
- 每 job 1–20 个动作，整体最长 30 秒；超时关闭整个上下文并取消排队任务，不能在后台继续对该页面执行。
- 每会话最多 20 个排队任务，全服务保留 200 个任务。会话闲置、完成任务及截图 15 分钟过期。关闭会话提前清理其任务和截图。
- 排队容量和会话状态在请求体解析完成后再次验证；关闭中的上下文继续占用会话上限。超时后终态回执不接收晚到的动作结果。当前取消粒度是关闭整个会话，没有单个 job 取消或持久化重试接口；已发生的页面副作用不会因关闭而回滚。
- 全服务最多 20 张 PNG，每张最多 5 MiB；API body 最多 64 KiB，type 文本最多 16,000 字符。
- 每会话最多 32 个并行 HTTP 请求，请求体最多 1 MiB，响应原始与解压后均最多 16 MiB；不提供无限流式网络接口。
- 所有页面、子资源、fetch 和 frame HTTP 请求均经过 origin 检查和固定地址传输。域名所有解析结果须为公共单播地址，然后固定 socket 地址并保留原 Host 与 TLS 证书校验；重定向每一跳重新检查，不自动跟随到禁用 origin。
- HTTP(S) URL 最多 8,192 字符；程序不把控制服务的 bearer 凭据注入页面请求。
- gzip/deflate/br 受限解压，Cookie 在各自 BrowserContext 中隔离；不使用用户现有登录 profile、文件或缓存。
- 阻断 WebSocket；禁用 service workers，拒绝下载，关闭新 popup，取消 JS 弹窗，不授予浏览器权限。页面中的 WebRTC/WebTransport 被禁用，并采用 Chrome 的相应网络限制。

这是浏览器 HTTP 请求代理与操作限制，**不是操作系统级网络隔离或恶意代码沙箱**。Chrome 自身、worker 中未覆盖的传输及浏览器漏洞不在本原型验证范围。运行不受信任远程网页前应增加容器/操作系统网络策略。本服务需要本机 Chrome sandbox，未添加 `--no-sandbox`。

不提供 shell、任意 JavaScript/eval、原生键盘或系统鼠标控制、iOS 跨 App、录音、真实浏览器 profile 接管。`inspect` 和截图可能包含所浏览页面的内容，接入端应沿用当前会话的真实权限与保留策略。

## 验证

```sh
npm test
```

测试只启动临时端口和合成页面，退出时关闭全部服务与 Chrome；不会连接既有 3218 服务。当前 9 项验证包括真实 Chrome 双上下文并行门闩、同会话排队、localStorage/Cookie 隔离、压缩页面、截图鉴权与摘要、子资源/重定向/WebSocket 禁域零命中、超时关闭与终态回执不变、DNS 地址固定，以及慢请求关闭竞态、并发队列上限和浏览器内输出长度限制。

合成截图写入仓库已忽略的 `output/companion/synthetic-virtual-pointer.png`，供本机查看紫色光标。它不是用户真实页面截图或发行版截图。
