# Clerk 机器认证适配器：opaque M2M 首轮实现

- 记录时间：2026-09-09 03:43 +08:00。
- 分支：`startup`。
- 基线提交：`acee8003c7c55694716778189179ec272da44347`，2026-09-09T01:22:28+08:00，`docs: close equal-rights stage and prepare major-version handoff`。
- 本文代码目前未提交；上面的 SHA 是基线，不是新实现提交。
- 范围：新增 `services/collaboration/internal/auth/machine.go`、`machine_test.go`。本子任务没有改 router、store、go.mod、桌面或 Web，没有重启已登录的 Electron。

## 结论与来源核实

本轮提供独立的、可调用官方验证端点的 **opaque M2M token 验证器**。它证明一个 Clerk machine 执行器的身份。Agent 是人机自己的稳定 principal；调用方附带的 `agent_id`、自定义 token claims 或共享 key 都不能替代服务端的执行器绑定。

已阅读用户实施蓝图 16.2：人的身份、Agent 身份、执行器身份分别记录；动态群权限、委派撤销与停止代次在动作网关再次读取。

已于本轮核实以下官方事实：

1. Clerk 支持 opaque 和 JWT 两种 M2M 格式，默认 opaque。接收方使用**自己的** machine secret 验证调用方 token。M2M scopes 是可以通信的接收方 machine ID。修改 machine scopes 不追溯改变已有 token；opaque 支持撤销，JWT 不支持同样的即时撤销。[Clerk M2M 指南](https://clerk.com/docs/guides/development/machine-auth/m2m-tokens)
2. 官方 opaque 验证路径是 `POST /v1/m2m_tokens/verify`，认证要求 machine secret，而不是普通 Clerk BAPI secret。[Clerk verify 参考](https://clerk.com/docs/reference/backend/m2m-tokens/verify)
3. 本机固定的 `clerk-sdk-go/v2@v2.7.0` 已提供该 HTTP API，请求为 `{"token":"…"}`，响应使用 snake_case。它的 `jwt.Verify` 注释明确是 session JWT。其 `M2MToken` 的 `revoked`、`expired` 使用 Go bool，直接用零值无法区分字段缺失，因此本适配器额外验证字段存在性。[Go SDK M2M client](https://github.com/clerk/clerk-sdk-go/blob/v2.7.0/m2m_token/client.go)、[Go SDK M2M response](https://github.com/clerk/clerk-sdk-go/blob/v2.7.0/m2m_token.go)、[Go SDK session JWT verifier](https://github.com/clerk/clerk-sdk-go/blob/v2.7.0/jwt/jwt.go)
4. 官方 JavaScript 实现将机器 JWT 交给单独的 machine JWT verifier；本轮不将机器 JWT 塞入 Go session verifier，也不构造一个假的机器 JWT 验证假定。[官方 M2M API 分流实现](https://github.com/clerk/javascript/blob/main/packages/backend/src/api/endpoints/M2MTokenApi.ts)、[官方机器 JWT verifier](https://github.com/clerk/javascript/blob/main/packages/backend/src/jwt/verifyMachineJwt.ts)

## 给动作网关的契约

```go
type MachineVerifier interface {
    VerifyMachine(context.Context, string) (MachineIdentity, error)
}

type MachineIdentity struct {
    Issuer         string
    MachineSubject string
    TokenID        string
    Audience       string
    Scopes         []string
    ExpiresAt      *time.Time
}

verifier, err := auth.NewClerkMachine(auth.ClerkMachineConfig{
    Issuer:            configuredClerkIssuer,
    ReceiverMachineID: configuredReceiverMachineID,
    MachineSecretKey:  configuredReceiverMachineSecret,
    AllowNonExpiring:  false,
})
```

配置失败必须阻止该机器认证入口启用，不得退回旧账号、匿名身份或从请求头读取自报 principal。适配器不读取环境变量、不签发 token、不创建 Agent，不修改数据库。环境配置和路由接线由调用层实现。

| 返回字段 | 来自哪里 | 允许做什么 |
| --- | --- | --- |
| `Issuer` | 管理员登记的固定 Clerk 实例命名空间 | 与已验证 machine subject 组成执行器映射键 |
| `MachineSubject` | Clerk 验证响应的 `subject`，必须为 `mch_` 标识 | 定位服务端登记的 executor，不能直接当 Agent ID |
| `TokenID` | Clerk 验证响应的 `id` | 审计凭据 ID，不能记录 token 原文 |
| `Audience` | 服务端固定的接收方 machine ID | 表示已在响应 scopes 中验证接收方范围 |
| `Scopes` | Clerk 返回的 machine ID 列表 | 仅表达机器间通信范围，不赋予群、文档或管理权限 |
| `ExpiresAt` | Clerk 的毫秒时间戳；显式策略允许时可为 nil | 记录凭据期限，不替代每次动作的当前权限判断 |

**Issuer 的信任边界：** opaque 验证响应没有 JWT 的 `iss`、`aud` 字段。本实现不会声称校验了一个不存在的 issuer claim。部署管理员必须把 issuer、接收方 machine ID、该 machine 的 secret 作为同一个 Clerk 实例的受信配置登记；官方端点通过该 secret 验证调用方。实例与密钥的配置配对尚需真实 Dashboard 建机/签发验收，不能根据任意请求字段推导。Audience 使用官方接收方 machine scope 语义验证。

自定义 `claims` 完全不提升为身份或授权，包括 `claims.agent_id`、`claims.aud`、组织角色等。主体验证通过后，调用层仍必须读取服务端 executor→Agent 绑定、当前成员和对象权限、委派链、Run 范围、停止代次和预算。Clerk 的 scopes 不能代替这些判断。

## 具体失败关闭规则

- 只接受有界的 `mt_` opaque 输入。JWT、API key、OAuth、含控制字符或超长 token 均在发网前拒绝；`ErrMachineTokenFormatUnsupported` 同时匹配 `ErrUnauthenticated`。
- 固定请求 `https://api.clerk.com/v1/m2m_tokens/verify`；外部调用方不能配置目标 URL。API 版本与已核实的 Go SDK 一致：`2026-05-12`。
- HTTP 最长 8 秒，并服从调用方更短的 context。禁止全部重定向，包括同源跳转，避免 Authorization secret 或 JSON token 被再投递。响应读取最多 64 KiB。非 200、HTML、异常和错误体均返回脱敏认证失败。
- `object` 必须为 `machine_to_machine_token`；token ID、machine subject、scope ID 必须合法；scopes 必须含固定接收方 ID。重复 scope 和非 machine scope 拒绝。
- `revoked`、`expired` 必须**存在且显式 false**。缺失、null 或 true 都拒绝。
- `expiration` 必须存在。默认拒绝 null；只有部署显式 `AllowNonExpiring: true` 才支持 Clerk 的永不过期 opaque token。字段缺失不会当成 null 接受。
- 时间戳按官方文档的**毫秒**解释；检查创建/更新时间合理性和实际过期时间，不把秒猜成毫秒，不延长已过期 token。创建/更新时间最多容忍 5 秒时钟偏差；过期时间没有延长宽限。
- 拒绝重复顶层 JSON 安全字段、大小写别名覆盖、尾随 JSON 和畸形字段，同时允许未来添加不被用作授权的响应字段。
- 不缓存验证成功，后续请求会重新查询 Clerk 的当前撤销状态。上游不可用时不使用上次成功的身份兜底。

## 验证记录

已执行 `go test ./internal/auth -count=1`；通过。最终源码（包含 API 版本固定和 JSON 大小写别名防护）执行 `go test -race ./internal/auth -count=1` 通过，用时约 2.83 秒。

新增测试使用本地真实 TLS HTTP server，通过实际请求/响应链验证以下行为：

- 官方方法、路径、接收方 Authorization、token-only JSON、版本头；返回真实 wire 字段和毫秒期限。
- 被撤销、过期、缺失/null 状态、错误类型、错误主体、错误 scope/audience、时间单位错误、时间越界；全部返回空身份。
- 自定义 agent_id/aud 无法变成主体或替代接收方 scope。
- 允许无期限的显式策略与缺失期限字段的区别。
- 两次请求间撤销会在第二次生效，验证成功不缓存。
- JWT/API key/OAuth 等不支持格式不会发给 opaque 端点。
- 401、403 HTML、404、429、500、空体、截断、超大体、重复字段、大小写别名和尾随 JSON。
- 301/302/303/307/308 × 同源/跨源，接收跳转的端点收到 **0 次请求**。
- context 取消、网络错误、nil verifier；配置中拒绝普通 BAPI secret 和非法 receiver。

这些是协议实现与拒绝路径的本地自动验证，**不是 Clerk 线上机器认证验收**。本子任务没有使用两份候选 BAPI secret 再次调用服务，没有读取或输出完整凭据，没有签发真实机器 token。

## 尚待完成

1. Dashboard 创建接收方和执行器 machine，登记同实例配置，签发有限期限 opaque token；不要将真实 secret/token 写入文档或 Git。
2. 动作网关接入 `MachineVerifier`，服务端绑定 executor→Agent；使用同一套当前成员、委派与停止策略。
3. 真实验证通信 scope、过期、撤销、错误接收方、禁用执行器和群停止，记录脱敏回执与最终实现 SHA。
4. API key 委派和 M2M JWT 都是独立后续适配器，不属于本轮已支持能力；JWT 接入需按实际官方 machine header/claims/signature 分类实现，并设计应用层撤销边界。

本阶段完成验证器代码，不宣称 API/MCP/A2A 全部接通，也不宣称人机同权的执行控制或生产认证已经验收。
