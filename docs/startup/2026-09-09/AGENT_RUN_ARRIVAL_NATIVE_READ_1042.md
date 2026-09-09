# Agent Run 原生融云接收读取：本阶段交付与关闭

初稿时间：2026-09-09T10:42:08.207156+08:00。实施提交：`30c6c22ce3ff24676d9d5a43bf1b3ce0cf14aafa`，提交时间 `2026-09-09T10:33:54+08:00`，描述 `feat(startup): invite human and agent colleagues with scoped arrival reads`。本专题记录实际执行后的证据；不改变旧阶段记录。

## 完成范围

新增 Go Store 的 `ExecutionTransportArrivals`、共享 Domain DTO，以及可替换 `NativeTransportReader` 和 Eino 工具 `im_transport_arrival_read`。REST 与 MCP 通过同一 Store 内核读取：`GET /v1/transport/events` / `transport_arrival_read`。Machine 必须带真实 `run_id`；Human 禁止传 Run 参数，保留当前成员的历史读取语义。

Machine 从认证 issuer/subject 解析已有 executor，再从 PostgreSQL 加载原始 Run；所有根群与继承来源的成员权限、工作区、停止代次、主动式策略版本、executor 状态及 Run 状态在同一事务内检查并持锁读完。可见桥覆盖只能是部署配置、当前 Agent receiver 与原始 Run 来源的交集。同一个 Agent 在其他工作区/其他群的成员关系不会扩权。

分页限制 1–100；cursor 必须是该 receiver、当前桥绑定元组、当前来源 epoch 的真实 inbox cursor，范围不超过 JavaScript 安全整数。两页之间重新验权。未经配置的桥返回 unavailable，零事件和空时间；连接心跳仅代表连接状态，不能当作收包事实。原有 Provider UID、消息指针与接收记录保持原样。

Eino 工具参数只能提供 after/limit，不能提供 Run、principal、receiver、room 或端点。显式 null 拒绝。HTTP Reader 与替换式插件均在读取前后校验当前 Run，并验证响应身份、范围、顺序与时间；不合格或迟到的停止响应不会进入 `tool.result`。通过验证的观察与完整页进入既有执行证据，不产生消息动作。本轮未更改旧 Temporal Workflow/Runtime 版本或档案渲染版本。

## 隔离测试

| 检查范围 | 顶层用例 | 子用例 | 失败 / 跳过 | 说明 |
|---|---:|---:|---:|---|
| Store + Harness 受影响包 `-race` | 126 | 132 | 0 / 0 | 真实 PostgreSQL UUID 隔离 schema；含旧 Human 读取共享 helper 回归 |
| 最终 HTTP/MCP + Harness 定向 `-race` | 10 | 32 | 0 / 0 | HTTP/MCP 6 顶层 + 4 子；Harness 4 顶层 + 28 子，含新增 null 拒绝 |

两轮计数存在覆盖关系，**不得相加当作独立测试总数**。测试日志路径、精确 SHA 与子项计数见 [proof 索引](evidence/agent-run-arrival-native/test-and-live-index.json)。Run 停止/恢复旧 epoch、根与来源撤权、工作区与接收身份隔离、桥重绑、跨 Run 游标、无桥也认证，以及持首来源锁等待时另一个来源被停止，都有回归。Eino 使用真实工具构造与假模型测试，无真实模型调用。

额外独立审读邀请模块曾发现 action advisory 与 room 锁顺序倒置；已由模块负责人修正为所有 Run 锁 → action advisory → 全来源 room 锁，并增加确定性 PostgreSQL 并发回归。此处只记录复核结论，不重复计入上述测试。

## 真实机器验证

现有绑定仅被读取：Agent `b49d2ffc-946c-4061-a6ef-5ed7e4308465`，executor `65406456-48cf-4d57-83ee-6a90c206e7a1`，工作区 `736b5198-479b-4505-8dbb-8d54b0d5c697`，根群 `63892e35-efbd-40cb-86e6-17c7cab37aa6`。当前 executor v1、主动式 policy v2、群 epoch3，Agent 为 member。两份旧 Temporal 验收 Run 实际均 failed；另外两份历史 running Run 的 epoch1 已过时，均未复用。

已有私密 token 均已过期。本轮在同一 worker→receiver 范围单次签发 3600 秒 Clerk M2M token，HTTP 201，官方前后完整清单对账成功。完整响应只在 ignored 私密目录（0600）；旧 worker/env 校验未变，未更改或轮换绑定。官方契约参考 [Clerk 创建 M2M token](https://clerk.com/docs/reference/backend/m2m-tokens/create-token) 与 [M2M Token 字段](https://clerk.com/docs/reference/backend/types/backend-m2m-token)。

新 Run `d53224d3-9c19-4d60-9b87-7168ec5dce19` 由机器本人单次创建，使用原工作区根群 epoch3，origin scopes 为空，持久 readback 与当前 Check 均成功。新版 API 的 HTTP/MCP 返回逐字段相等：receiver 是该 Agent，covered rooms 为空、events 0、bridge state 为 unavailable、两个时间字段均为 null。**这验证了真实认证与原生读取链路，也如实证明当前没有 Agent 专属桥覆盖；不宣称收到真实 SDK 消息。** 既有 Human 桥未被借用。

未启动 Temporal 或通用 Worker，未调用模型，未新发消息或派发 Outbox。本轮 Agent 接受 Human 新工作区邀请码未执行；此能力仅有隔离 PostgreSQL / HTTP/MCP 实作测试，不把 Human UI 创建/撤销邀请当作 Agent 已接受。

## 阶段停止与审计保留

按用户“当前阶段做完就停”的要求，通过正常机器生命周期接口单次追加 `run.stopped`（HTTP 204），事件 `e31d9628db973f17ddf6e856d5d0e411e265e2ae4c65b8ae0f18748e2260d472`。Run 当前 stopped；随后执行态 arrival 返回 409，审计读取仍 200，完整停止事实已保留。原根群仍未停止、epoch3 未变；没有全群刹车，没有改写旧 Run，也没有新增业务动作。

临时 token 不接入 Worker/env，按本次目的留到自然过期：**2026-09-09T11:33:17.876+08:00**。此处不声称已过期，也不自动续签。阶段已停止，不启动下一项任务。

受控脚本和意图都保留。带 launch guard 的签发、建 Run、终结脚本不能直接重跑；未知结果先只读对账，不替换 action/event ID 或另建 Run。准备好的邀请码接受脚本本轮没有运行，不能在阶段停止后自行调用。

完整脱敏 proof： [清单](evidence/agent-run-arrival-native/MANIFEST.json)、[真实 Run 读取](evidence/agent-run-arrival-native/run-readiness.json)、[终结核验](evidence/agent-run-arrival-native/closure-verification.json)、[停止后审计](evidence/agent-run-arrival-native/closed-run-audit.json)。无凭据、邀请码或私有原始 HTTP 响应被复制进文档目录。
