# 迁移说明、文件清单与交接

> 文档序列：`evolve / 2026-09-06 / v0.2`
>
> 编写时间：`2026-09-06T02:50:08+08:00`（Asia/Shanghai）
>
> Active Agent 实现：[`c05f904`](https://github.com/huapohen/active-agent/commit/c05f904f0ec11d680d5527e37519e1836ccba0af) · `2026-09-06T02:41:10+08:00` · feat: evolve proactive agents around visible collaborative documents
>
> Doc Free 实现：[`f5c3b6f`](https://github.com/huapohen/doc-free/commit/f5c3b6f0cdbf03b74895d6e3884154578b8ceb3f) · `2026-09-06T02:41:11+08:00` · feat: add document-native workspace for proactive agent collaboration
>
> Doc Free 源码排版：`b182142` · `2026-09-06T02:42:03+08:00`
>
> 旧版资料保留，新版结论以本序列的实现、验证和限制为准。

## 1. 分支与历史

Active Agent 原目录没有 Git。先清理示例凭据并将原型导入 `main`，再创建 `evolve` 承载新实现。Doc Free 从已有 `main` 创建 `evolve`，其原有公开默认分支不作合并。

Active Agent 新公开仓库使用 `active-agent` 名称；本机目录继续叫 `active_agent`。本轮没有对 quantum-entanglement 进行修改、提交或部署。

## 2. 旧文档与新文档的区分

旧 `docs/architecture.md` 和 `docs/technical-architecture.md/.html` 保留原样，描述 0.1 的会话事件、任务、outbox 等架构。它们不是本轮文档协作实现的验收依据。

新文档统一放在 `docs/evolve/2026-09-06/`，每篇都带编写时间、实现 commit、提交时间和描述。`VERSION.json` 提供机器可读版本关系，`report.html` 提供可离线打开的概要。Doc Free 仓库也提供同日期的集成说明。

文档在实现提交之后编写，因此可以引用真实实现 SHA。不要在文档中伪造“该文档自身所在提交”的 hash；获取文档提交请用 `git log -1 -- <path>` 或 GitHub History。

## 3. 新增和改动文件

| 仓库 | 关键文件 | 作用 |
|---|---|---|
| Active Agent | `active_agent/documents.py` | 持续观察、版本去重、预算、退避和恢复 |
| Active Agent | `active_agent/llm.py` | 明确区分 Responses / Chat，拒绝中断输出 |
| Active Agent | `active_agent/config.py`、`cli.py` | 本机模型与文档配置、持续 worker 命令 |
| Active Agent | `scripts/dev_workspace.py` | 启动隔离开发工作空间 |
| Active Agent | `scripts/check_secrets.py` | 检查实际 Git 索引中的运行文件和疑似凭据 |
| Active Agent | `tests/test_documents.py`、`test_responses.py` | 调度、证据、模型协议回归 |
| Doc Free | `work-protocol.js`、`workspace.js` | 可见任务、提案与审阅契约 |
| Doc Free | `workspace-mcp.js` | 新工作流的七个 MCP 工具 |
| Doc Free | `workbench.*` | 纯文档工作台、在线编辑和审阅 |
| Doc Free | `collab-server.js` | CRDT 比较写入、状态摘要、提交回执 |
| Doc Free | `server.js` | Workspace 路由、最新投影、事件与静态资源 |
| Doc Free | `tests/workspace.test.js` | 真实 HTTP/CRDT/重启集成测试 |

共同增加开源许可、CI 和环境排除配置；Doc Free 移除了从无关项目目录读取模型凭据的隐式行为。

## 4. 本机数据隔离与恢复

组合启动器保存：

```text
active-agent/data/workspace/
  data.json       文档投影、历史、事件和运行心跳
  crdt/           协作文档的 Yjs 持久化
  worker.db       操作性调度检查点与租约
```

这些文件不进入 Git。已有 Active Agent 原型的 `data/active_agent.db` 以及 Doc Free 原来的文档数据都保留。

恢复时必须一起保留 Doc Free 文档数据和 CRDT 数据。仅删除 worker.db 可以从文档恢复；删除来源文档与 CRDT 文件不是“可无损重建”。模型配置与访问令牌独立保存在忽略的 `.env`。

更改配置或切换代码分支前停止相关进程。0.1 没有新工作台语义，不应让它在运行中接管这套新演示数据。回滚代码时保留数据备份，按原有路径启动原型即可。

## 5. 交接建议

先按教程运行真实示例，再阅读产品定位和技术架构；最后用测试文件检查故障路径。开源评审应重点看正文与 CRDT 状态的新鲜度、提案回执恢复、模板是否隐藏了真实限制，以及是否存在跨项目凭据依赖。

没有进行云端部署、生产环境变量写入、IM 接入或自动对外发送。GitHub 发布的是可自托管的代码、公开文档、测试与已检查的示例截图。
