# 商业消息回复、回应与鉴权表情：客户端阶段记录

- 时间：2026-09-09 07:34 +08:00。
- 分支：`startup`。
- 实施起点：`c3a6f2697544d6c9784c9d6e49da658c19736c78`。本文对应的客户端变更在记录时尚未提交；该 SHA 是已提交起点，不是本次实施 SHA。
- 范围：`apps/web` 的共享 React 客户端。没有修改 Electron 壳、Flutter、Go 服务、运行配置或真实数据；没有调用模型或操作 GUI。

## 实际能力

Clerk 对应的 StartupClient 在 `/v1/me` 成功后读取 `/v1/capabilities`。只识别 `renji.capabilities.v1` 内版本 `1`、API 为 true 且显式声明 `available:true` 的四项声明：`message.reply`、`message.reaction.set`、`message.reaction.read`、`emoji.read`。未知版本或能力不开放入口。反应依赖 set、read、emoji 三者齐备。商业认证失败不回退到迁移认证。

回复只向服务器提交 `reply_to` 消息 ID。消息中的引用使用服务器返回的 `reply` 摘要，检查原消息 ID、所属会话、作者种类、先于当前消息的序号和最多 240 Unicode 字符。原消息不在已加载历史中时仍可读摘要；缺少摘要时明确显示不可用，不拿旧缓存拼出新的商业摘要。

表情回应发送 `{action_id,emoji,active,scope_epoch?}`。快速重复点击不会创建第二个动作。未知结果保留原始 ID 和目标状态；“核对原动作”重放完全相同的意图。回执检查会话、消息、认证操作者、表情及状态。回执可能来自较早的幂等动作，因此它不直接覆盖画面：确认后再 GET 单条当前消息。该读取失败时仍保留原动作，避免误生成新反应。切换身份或会话会取消请求并丢弃迟到结果。

消息先展示服务器前 20 类回应。更多回应通过独立对话框读取实际分页；后页携带首屏版本，409 清空旧列表并允许从头读取。完整列表中的回应也可明确添加或取消自己的选择。它没有插入鼠标悬浮工具栏的消息排版。

表情目录直接访问 Go provider，沿用分页、分类、搜索及 revision。经典图片仅接受目录给出的 `/v1/emoji/assets/feishu/<安全文件名>.png`，使用 Bearer 和 If-Match 请求；不在 URL 放凭据，也不请求旧服务或外站图片。返回必须是匹配 ETag 的 PNG，实际字节 SHA-256 也必须匹配目录固定的 ETag，并有 1 MiB 流式大小上限。图片转成当前组件的 blob URL，卸载、换身份或离开表情面板时撤销。消息已有回应的经典图片也先从当前目录查询精确 ID，再读取图片。

商业消息列表显式 `before=0` 读取最新页；较早页使用最旧已接收序号作为 exclusive before。客户端核验 direction、has_more、cursor、数量上限、所属会话、递增序号、重复 ID 与 before 边界。事件/房间 cursor 不混入消息分页。

## 保留与差距

- LegacyClient 继续使用原 `/api/im` 鉴权、真实数据、回复和 toggle 协议。该 toggle 不具备幂等 ID，未知结果仍先人工刷新确认，不自动重试。
- 浮层 portal、离开关闭、键盘可达、来源时间和固定页面高度保持原实现；本阶段自动回归覆盖，尚没有新增真实 GUI 对比。
- 商业栈的 Agent 成员目录未开放。Agent 入口禁用并解释原因，不从迁移成员或全局目录拼出成员。
- 商业栈未读锚点、已读人数和未读筛选仍未实现。历史多页窗口在新增消息后整体刷新，最旧边界可能前移；旧内容仍可继续向前加载。
- 当前 182 张经典图与既有目录范围保持一致，不宣称覆盖飞书所有原生经典图或自定义图片能力。
- 本记录证明客户端适配及本地测试，不证明真实 Clerk 人类登录、商业 UI 或融云接收已经验收。实际商业 HTTP/GUI 验收由主线程另记。
- 现有构建仍有大于 500 kB 的 bundle 提示，构建成功；本阶段没有拆包。

## 可复核验证

2026-09-09 07:32 执行：

```sh
npm run check --workspace=@renji/web
npm run test --workspace=@renji/web -- --reporter=dot
npm run build --workspace=@renji/web
```

结果：TypeScript 通过；Web **11 个测试文件、79/79** 通过；Vite 生产构建通过。相对阶段起点 61 项新增 18 项，既有 Legacy 原生 HTTP 合成测试仍保留。新增测试使用合成 fixture/mock HTTP 形状，不使用真实商业账号或外部消息。

- [商业协议测试](../src/startup-message-api.test.ts)：运行时能力、摘要、显式状态、回执归属、before/点读、完整回应分页、资产边界、撤销身份。
- [交互与旧行为回归](../src/MessageActions.test.tsx)：原动作核对、点读失败、撤权清除、完整列表版本冲突、迟到身份、原有 hover/右键/中文组合输入。
- [图片生命周期](../src/emoji-assets.test.tsx)：URL 释放、身份切换和迟到图像。
- 本机测试日志：`/tmp/renji-commercial-message-client-tests-20260909.log`。
- 本机构建日志：`/tmp/renji-commercial-message-client-build-20260909.log`。

上述 `/tmp` 日志为本机证据，不是远程仓库附件。最终实施提交归属由主线程在提交后补充。

## 07:38 独立审查后补强

主线程复核后，客户端点读增加显式 `room_id` 和正整数序号校验；能力缺少 `available:true` 时关闭；资产实际字节 SHA-256 与目录固定 ETag 比较，损坏字节即使携带原 ETag 也拒绝。对应反例已加入上述协议测试。07:38 再次运行 TypeScript、79/79 Web 测试和生产构建通过。Go domain/store/outbox 的独立源码审查结果已另报主线程；此客户端记录不代替后端运行验收。

## 最终实施提交归属

以上保留初次记录时的观察和边界。最终实施已纳入 `50570cac03b1314c831fc856e6ed826f60486fa8`，提交时间 `2026-09-09T07:55:18+08:00`，描述 `feat(startup): deliver native replies reactions and authenticated emoji`。后续集成测试、真实服务与注册状态以本阶段主交付文档为准，不将这里的早期测试数量重复计入最终总数。
