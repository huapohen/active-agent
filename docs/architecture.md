# 架构与演进边界

## 为什么同时提供 HTTP、MCP 和插件

这三者不互相替代：HTTP 是跨语言、跨 IM 的稳定接入协议；MCP 让其他 Agent 把 AA 当长期任务副驾驶；Python 插件用于同进程低延迟扩展。真正的产品核心是持久化主动循环，而不是某一种接口。

```text
IM webhook ──HTTP──┐
                   ├─> Event Store -> Evidence -> Mission Evaluator -> Decision
other Agent ──MCP──┘                                      │             │
                                                         silent      approval
                                                                       │
                                                         IM <── Outbox ┘
```

## 主动循环

1. `ingest` 幂等保存原始事件，并按任务目标关联证据。
2. worker 只负责唤醒到期 mission；周期到达不等于允许发言。
3. evaluator 仅查看新增证据，选择沉默、通知、完成或提议动作。
4. 每次判断都写 `decisions`；可见消息先写 outbox，发送失败可重试。
5. 高影响动作写 `approvals`，批准前不交给执行器。

## 安全边界

- 群聊文字是不可信输入，不能覆盖系统策略或凭据边界。
- 首版 AA 只生成建议和委派提案，不直接下单、付款、删除或更改企业资源。
- connector 必须校验平台签名；API 对公网部署时必须设置 `AA_API_TOKEN`。
- 模型调用失败会降级到保守规则，不因失败扩大权限。
- 决策应引用 evidence；后续 UI 可完整展示“为什么现在说”。

## 从 MVP 到生产

下一阶段按这个顺序推进：

1. 飞书事件验签、租户/群/成员身份映射、原生 mention 发送；
2. PostgreSQL + 分布式租约 + outbox worker，支持多实例；
3. 向量/全文混合检索和任务级摘要压缩，支撑百小时上下文；
4. 可插拔 observation source（代码、项目管理、行情、文档）；
5. Agent registry、预算、能力和信任等级，再开放真正的团队调度；
6. Web 控制台展示任务、证据、决策、成本、审批和暂停开关。

其中第 5 项不能仅靠 prompt 实现，必须由权限、预算、沙箱、审批和审计共同约束。
