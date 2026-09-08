# Responses 与 NativeReader 独立审查及修复

- 记录时间：2026-09-09 05:26:02 +08:00。
- 已提交基线：`380d7bef5b8ce78f6dae38b812e8aa9931ca67d1`，2026-09-09 04:52:22 +08:00，`docs: preserve native publication evidence and fidelity gaps`。
- 本文对应的 Responses、原生读取及测试改动仍在工作区，尚未提交；上述 SHA 是基线，不是这些改动的交付 SHA。
- 审查方式：本地代码、已安装 Eino v0.9.19 源码、官方 Responses 文档及独立自动化回归；没有调用付费模型、没有修改 GUI、没有发送真实业务消息。

## 发现与修复

### Responses 最终答案阶段

独立测试复现两个问题：同一 `output` 数组的 `commentary` 与 `final_answer` 文本被拼接，使合法最终 JSON 在真实 Eino Planner 中报 `malformed stage output`；未识别的 `phase` 被当成最终内容接受。

根任务已在 `services/collaboration/internal/harness/responses_model.go` 修复。现在区分最终答案、中间说明和兼容旧协议的无 phase 内容，拒绝未知或歧义阶段；完整原始输出仍只存于每条消息的私有续接内存，保持 reasoning、function call 和 assistant phase 的顺序及内容。独立复验原来的 9 个顶层测试通过。

官方依据：[Responses 推理续接规则](https://developers.openai.com/api/docs/guides/reasoning)、[函数调用与工具结果续接](https://developers.openai.com/api/docs/guides/function-calling)、[assistant phase 协议说明](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-5.5)。最后一个链接核实的是通用 Responses phase 规则，本地模型配置保持 `gpt-6-astra`、`medium`，未进行模型替换。

### NativeReader 插件返回页

原 HTTPGateway 已检查请求及返回范围，但直接替换为其他 `NativeReader` 时，工具入口会信任插件返回页。独立审查未发现当前 HTTP 生产链越权，发现的是切换插件后的共同边界缺口。

本轮在 `services/collaboration/internal/harness/native_read.go` 集中实现 `validateRoomPage` 与 `validateMessagePage`，由 HTTPGateway 和 Eino 原生读取工具两层调用：

| 校验 | 房间页 | 消息页 |
| --- | --- | --- |
| 授权范围 | 每个房间属于当前 Run 的目标或来源范围 | 请求房间属于 Run；每条消息必须属于该请求房间 |
| 页数预算 | 最多 100 项 | 最多 100 项，恰好 100 项仍可用 |
| 前进顺序 | ID 严格递增且大于输入游标，拒绝重复与倒退 | seq 严格递增且大于输入 after，允许合法序号间隙 |
| 返回游标 | 非空游标必须等于最后一个房间 ID，空页不能声称继续 | cursor 等于最后 seq；空页保留输入 after，不能设置 has_more |
| 实时权限 | 读取前、返回后继续检查当前权限 | 读取前、返回后继续检查当前权限 |
| 失败行为 | 拒绝整页，不返回部分内容 | 拒绝整页，不返回部分内容 |

Run 身份仍由执行器提供，模型参数不能替换它。检查返回页不能代替服务端实时 ACL：HTTP 的读取接口仍带 `run_id`，服务端读取使用 canonical Run、执行器绑定和来源范围锁。

## 自动化证据

执行目录：`services/collaboration`。

```sh
go test ./internal/harness -run 'TestNative|TestEinoNative|TestReviewResponses|TestResponses' -count=1
```

结果：**12 个顶层测试通过**；本轮新增 20 个分页/范围子例、4 个真实 Eino 插件边界子例及 1 个 HTTP 房间游标测试。原 HTTP 消息读取与撤权测试保留并通过。`git diff --check` 在本轮改动路径通过。

- `services/collaboration/internal/harness/responses_review_test.go`：4 个独立回归。包含 commentary + final、未知 phase、工具续接逐项保持，以及由实际 24k 阈值触发的 Eino 摘要中间件。
- `services/collaboration/internal/harness/native_read_test.go`：分页预算、错房、重复/倒退游标、错误 seq 与空页继续标记。两种原生工具各测试插件返回错房内容，以及合法读取完成后被停止。
- 错房或读取后被停止的插件结果：下一次模型调用没有发生，没有 `tool.result` 档案，也没有测试正文出现在任何已收集执行事件中。
- 摘要测试：工具调用后的请求保留加密 reasoning 和对应 function_call_output；压缩后历史不保留悬挂私有续接；测试凭据与私有 reasoning 标记均未进入执行档案。

日志位于本机：

- 初始问题复现：`/tmp/renji-responses-independent-review-20260909.log`（两个预期失败，供前后对比）。
- Responses 修复后 9 项复验：`/tmp/renji-responses-native-independent-review-final-20260909.log`。
- 插件边界完成后的 12 项复验：`/tmp/renji-native-plugin-boundary-review-20260909.log`。

这些测试使用合成 HTTP 响应与真实 Eino 运行器，证明本地协议适配和权限边界行为；不代表外部模型服务或商业客户端已完成真实端到端验收。

## 最终提交归属追加

本文 Responses phase 修复、NativeReader 双层校验及独立回归最终纳入提交 `a639a8843093bed98b04b375d361de6e2c2129c9`，提交时间 **2026-09-09T05:56:24+08:00**，描述：`feat(core): add native document verification and durable agent archives`。该提交已在本机 Git 核实；开头“尚未提交”是 05:26 独立审查时的历史状态，本段为最终实现归属。

根任务还在已登录的 Electron 中实际打开交付文档 `a74679d5` **r1**，确认全文可读且「来源会话」按钮正确导航，并打开执行档案 `9d62380a` **r1** 阅读其失败事实。截图：[`desktop-native-archive.png`](../../../output/startup-runarchive-case2-20260909/desktop-native-archive.png)。此证据补充的是档案在原生客户端可读，不替代上文对 Responses 工具续接、私有推理隔离与读取权限的独立测试，也不将档案中的失败改写为成功。
