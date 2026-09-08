# 新 Electron 迁移登录修复与验收

记录时间：2026-09-09T03:31:36+08:00。分支 `startup`；实现尚未提交，基础提交为 `acee8003c7c55694716778189179ec272da44347`（2026-09-09T01:22:28+08:00）。

用户要求立即打开并登录新版电脑端。本次保留真实旧数据迁移入口，未将它标记为商业 Clerk/融云链路完成。

## 触发和修复

1. 旧服务 `3218` 对跨域 `OPTIONS /api/im/auth/login` 返回 401；真实浏览器登录被预检拦截。开发 Vite 现仅为精确 `http://127.0.0.1:3218` 源提供固定 `/legacy/api/im/*` 同源代理。实际代理 `GET /auth/providers` 返回 200；root 已验证代理密码登录 POST 返回 200 和有效会话结构，未在文档中保存令牌。
2. 代理登录成功后，`LegacyClient.me()` 仍失败。`HttpClient` 把浏览器 `fetch` 保存为成员后用 `this.fetcher(...)` 调用，接收者成为客户端实例，Chromium 拒绝为 `Illegal invocation`。构造函数现显式绑定 `globalThis`，同时覆盖旧协议和 Go 协议请求。
3. 新增严格 Window 接收者回归测试：修复前精确在 `LegacyClient.request` 复现同样异常；修复后读取工作身份通过。错误展示仅使用脱敏分类，不输出原始 URL、响应正文、密码或 Token。

## 实际验收

- root 在新版 Electron 真实 GUI 中输入账号和六位密码，输入内容未出现重复。
- fetch 修复热更新后，root 点击登录成功；AX 显示 `huapohen` 和真实“原生办公”、公司、合成验收等会话列表。
- 该 GUI 证据由主任务执行并确认；本子任务没有并行操控鼠标/输入，也未将单次正常输入推断为整机重复输入故障已根治。
- 2026-09-09T03:31:25+08:00 验证：Web **22/22**、桌面边界 **6/6**、TypeScript 检查、React production build 通过。构建保留已记录的融云 SDK browser `path` 外置和动态 chunk 体积提示。
- 当前停留于已登录界面给用户查看，不重启 Electron/Vite，不继续会导致页面重载的 capability 接线改造。

## 下一阶段接口备忘

主任务已确认 `GET /v1/capabilities` 返回：

```json
{
  "schema": "renji.capabilities.v1",
  "capabilities": [
    {
      "id": "message.read",
      "version": "1",
      "protocols": { "api": true, "mcp": true, "a2a": false },
      "exportable": true
    }
  ]
}
```

上面是结构示例，不代表实际接口的完整能力或特定项配置。已协调的稳定 ID 为 `identity.read`、`workspace.create`、`room.list`、`room.create`、`message.read`、`message.send`、`room.execution_policy`、`transport.session`。后续需把客户端能力清单与服务端实际声明对齐；本次没有为追赶进度将未开放能力显示为已完成。
