# Active Agent（AA）

AA 是面向企业 IM 和其他 Agent 的主动式运行时。它持续接收消息，但只在出现新的、相关且可行动的证据时介入；长期任务、判断依据、待发送消息与审批全部可恢复、可审计。

当前版本是一个能运行的纵向切片，不绑定飞书：

- IM 通过 HTTP 事件协议写入消息，发送侧消费 outbox；
- 其他 Agent 通过 MCP 分配、补充和检查长期任务；
- SQLite 保存事件、任务、证据、决策、审批和发送状态；
- 后台 worker 周期唤醒，但“到时间”本身不会触发发言；
- 连续相关消息会重置安静窗口，先合并上下文，再选择介入时机；
- OpenAI-compatible 模型负责语义判断，未配置模型时使用保守规则策略；
- 交易、付款、删除、企业资源变更、外部委派等动作必须经过审批闸门。

## 五种模式的落点

| 产品模式 | 内核 mode | 首版行为 |
|---|---|---|
| 上下文 Todo 管家 | `todo_steward` | 从相关增量中形成主动提醒，不按闹钟刷屏 |
| 模糊长期留意 | `watch` | 持续积累证据，满足条件后通知 |
| 私人资料研究 | `private_research` | 资料达到充分性阈值后给结论；阈值可配置 |
| 长程 Agent 副驾驶 | `agent_copilot` | 保存关键线索与进展，供主 Agent 恢复上下文 |
| 开放任务统帅 | `orchestrator` | 先形成委派提案，通过人工批准后才能调度 |

## 快速开始

要求 Python 3.9+。当前本机按 Conda `base` 环境运行，不需要项目 `.venv`；核心无第三方依赖，HTTP API 才需要 FastAPI。

```bash
cd execute/enterprise_work/active_agent
conda activate base
python -m pip install -e '.[api,dev]'
cp .env.example .env  # 已存在时不要覆盖
python -m uvicorn active_agent.api:app --reload --port 8090
```

浏览器打开 `http://127.0.0.1:8090/` 即可使用 AA 控制台；交互式 API 文档位于 `/docs`。

另开终端启动巡检 worker：

```bash
active-agent worker
```

IM 收消息时调用：

```bash
curl -X POST http://127.0.0.1:8090/v1/events \
  -H 'Content-Type: application/json' \
  -d '{"event_id":"im-event-1","conversation_id":"group-1","sender_id":"user-1","sender_name":"小王","text":"@AA 帮我持续留意支付服务上线是否被阻塞"}'
```

`event_id` 应使用 IM 平台原始事件 ID，以保证 webhook 重试幂等。读取 `/v1/outbox` 后，由 IM connector 完成真正的 `@人` 发送，再调用 `/v1/outbox/{id}/delivered`。

## 模型配置

本机 `.env` 已被 Git 忽略。`AA_MODEL_BASE_URL` 同时支持服务根地址和已经以 `/v1` 结尾的兼容地址，不会重复拼接版本路径。凭据不要写入命令、日志、示例文件或提交。

```text
AA_MODEL_API_KEY=<local-secret>
AA_MODEL_BASE_URL=https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1
AA_MODEL_NAME=qwen3.8-flash
```

建议用隐藏输入命令写入 Key，避免进入 shell history：

```bash
active-agent configure-model-key
```

## MCP 接入

MCP 使用 stdio，启动命令：

```bash
active-agent-mcp
```

提供五个工具：`active_agent_ingest`、`active_agent_assign`、`active_agent_status`、`active_agent_tick`、`active_agent_approve`。MCP 是 Agent-to-Agent 控制面；IM webhook 是消息数据面，两者共用同一个数据库和内核。

## 扩展 IM 与插件

- 接入飞书、钉钉、企业微信时，实现 `DeliveryAdapter.send()`，并把平台 webhook 映射到 `IncomingEvent`。
- 领域数据源、RAG、行情或项目系统通过 `ActiveAgentPlugin` 丰富事件和观察决策。
- 多实例生产部署应把 SQLite 换成 PostgreSQL，并为 `run_cycle` 加数据库租约；表结构里已经预留 `leases`。

详细边界见 [docs/architecture.md](docs/architecture.md)。

完整技术架构提供两种格式：[Markdown](docs/technical-architecture.md)（适合评审、检索与版本管理）和 [HTML](docs/technical-architecture.html)（适合可视化讲解与浏览器展示）。
服务启动后也可以直接访问 `http://127.0.0.1:8090/architecture`。

## 验证

```bash
python -m unittest discover -s tests -v
```
