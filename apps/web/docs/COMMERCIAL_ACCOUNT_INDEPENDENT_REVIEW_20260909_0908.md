# 工作身份与创建操作：客户端独立复核

复核整理时间：`2026-09-09T09:10:47+08:00`。当前 Git 基线：`ddd947c7c3f74168ad1a17b11d4b04b5eb4599ad`。本阶段变更尚未提交。主线程编写 App、API 和 useCommercialAccount；本子任务对它们作独立只读审查，只新增 Hook 测试，并维护独占的入门组件。没有操作真实 GUI、读取真实浏览器存储、修改后端或发送生产请求。

## 审查范围

- [useCommercialAccount.ts](../src/useCommercialAccount.ts)：原意图保存、重放、当前读取、切换与失效。
- [api.ts](../src/api.ts)：profile / workspace / member / room 接口适配、输入、目录分页与鉴权继承。API 契约测试由主线程维护，本复核没有重复编写它们。
- [App.tsx](../src/App.tsx)：会话 key 重挂、头像/工作空间/+菜单集成，以及弹窗中的工作空间选择。
- [useCommercialAccount.test.tsx](../src/useCommercialAccount.test.tsx)：16 项独立测试，使用真实 React Query / Hook 和可控测试适配器，不连接后端。
- [入门组件及 39 项测试说明](COMMERCIAL_ONBOARDING_COMPONENTS_20260909_0850.md)：这是自有组件的实现/回归，和对主线程源码的独立审查区分记录。

## 确认及修正的边界

| 边界 | 最终行为与证明 |
| --- | --- |
| 第一次发送 | 上层先保存 action ID 和完整意图，再发 POST；保存失败则零写入 |
| 请求未知 / 确认后读取失败 | 保留原 ID、payload、预期版本；核对不会生成新动作；原操作未解决时不能提交替换意图 |
| 幂等回执与当前事实 | profile 重新读当前资料；workspace 重新读当前目录；room 重新读当前房间及本人权限，旧回执不直接当当前状态 |
| 昵称精确版本冲突 | 首次 POST 的 `409 profile_version_conflict` 且尚未确认提交时，读取当前 profile 后释放原意图，显示可纠正错误；新确认动作使用当前版本和新 ID |
| 其他 409 / 提交后读失败 | 普通 `action_conflict` 或已经确认 POST 后的任何 fresh-read 冲突不按未提交处理，仍保留原动作 |
| 原建群工作空间恢复 | 优先恢复 pending room 指定且仍可访问的工作空间，避免掉到第一项后无法核对 |
| 建群中切换工作空间 | Hook 集中拦截 pending / unknown room 的切换；App 弹窗 select 同时禁用，保持可见状态和实际行为一致 |
| 原来源缺失或撤权 | 组件不显示旧标题/成员，仍可向上层请求核对原动作；不会将旧意图改成当前工作空间的新任务 |
| A → B → A | 按实际 SessionProvider key 重挂，B 看不到 A 的意图；A 再登录恢复自身原 ID，旧实例迟到结果不会写入新会话 |
| 成员变化 | 请求前只接受当前工作空间目录中的真实 ID；创建后再次检查当前本人仍是会话成员 |
| 确认后删除本地记录失败 | 不把清理失败当可重建；保留已有记录，下一次继续使用原动作核对 |
| 后台旧 GET | 保存期间启动的后台旧资料请求也可能晚到；发布新事实前再次取消对应 query、检查当前 signal，防止旧版本覆盖 fresh read |

昵称首次版本冲突、恢复来源工作空间与弹窗切换限制在协作审查中确认后由主线程修复。缓存旧 GET 的发布顺序在审查后补强；独立延迟回包测试确认了最终行为，不能将它描述为真实生产事故。组件也修复了成功群聊表单的重复 Enter 提交：原意图不变时不能创建第二个群，改变名称或成员后才可提交新意图。

接口使用现有 Bearer 获取与永久 retire 的 client，不新增 header 自报身份、任意代理目标或 token 存储。当前目录分页通过已验证 UUID 游标连续读取，遇到重复、非递增或异常页失败，不把部分读取冒充完整列表。业务成员权限仍由服务端检查，组件选择器不是授权来源。

## 测试与范围

最终聚焦命令：

```sh
npm run test --workspace @renji/web -- --run src/CommercialOnboarding.test.tsx src/useCommercialAccount.test.tsx
npm run check --workspace @renji/web
```

最终两个文件 **55 项（组件 39 + 独立 Hook 16）全部通过**，TypeScript 检查通过。执行结果与最终源码摘要由本机 `output/startup-onboarding-client-review-20260909.json` 记录，测试日志为 `/tmp/renji-account-components-independent-final-20260909.log`，类型检查日志为 `/tmp/renji-account-components-independent-check-20260909.log`。没有运行或宣称完整客户端、真实 Clerk、Go 数据库、融云和 GUI 验收；这些由主线程分别记录。

本地意图采用当前窗口 sessionStorage，按端点和 principal 分开，只保存意图及 action ID，不含凭据。它不是跨设备/跨窗口的共享任务服务，也不承诺清空浏览器存储后的恢复。Hook 的 A-B-A 测试按 App 当前 key 重挂行为执行；不能据此宣称不重挂而原地替换身份也已受测。

本复核最后另向主线程报告 App 弹窗分支：无工作空间时不能将已有 pending / unknown room 退回工作空间创建表单，否则原操作核对被隐藏。独立 RoomForm 已支持 workspace 缺失的安全核对；主线程需保留原操作的 RoomForm 分支。该集成条件不属于上述 55 项组件 / Hook 测试的证明范围。原生像素布局、真实账号改名/建工作空间/建群、提供商外部派发仍待主线程验收。

## 阶段提交归属（2026-09-09T09:50:44+08:00）

上文“尚未提交”和“待主线程验收”描述的是各次复核发生时的状态。本阶段最终实施提交为 `e975e94e900cc892e39ed52ac0ce94ccd71c6ea1`，提交时间 `2026-09-09T09:35:36+08:00`，描述 `feat(startup): onboard colleagues and relay verified RongCloud arrivals`。实际 Clerk Human 的昵称、工作空间、单人成员群、中文消息、回复与表情回应已在 Electron 操作并由数据库读回；详见[本阶段主交付](../../../docs/startup/2026-09-09/STARTUP_ACCOUNT_BRIDGE_DELIVERY_0943.md)。这不补作原生窄窗口或物理键盘的验收。

末项空工作空间隐藏核对入口的集成问题已关闭：最终 `App.tsx` 只有在空间为空且 roomState 既非 pending 也非 unknown 时才回到创建空间；存在原操作时保留 RoomForm。此项通过最终代码条件复核关闭，仍不把它累计成上述 55 项之外的新增自动测试。
