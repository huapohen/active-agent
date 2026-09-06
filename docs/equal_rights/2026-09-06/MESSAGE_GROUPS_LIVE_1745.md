# 人机消息分组：Mac、iPhone、Web 与 Agent MCP 实测

- 时间：2026-09-06T17:45:00+08:00；真实页面验收约 17:36–17:44。
- 分支：`equal_rights`。
- Active Agent 实现前基线：`3beae3137c3193555360145300f81a0b5a1c888c`，2026-09-06T12:49:59+08:00，`docs: record office 0.5 release and verified native workflows`。当前实现提交由 `VERSION_0_6.json` 关联。
- Doc Free 最新配套：`5618e90e370bb43ee7c4cd5b2cfd86156b1366a5`，2026-09-06T17:39:33+08:00，`fix: expose optional participation revision checks through MCP`；包含 `f14be827` 分组提交。
- 描述：把用户指出的“消息旁三条杠”从旧未读开关补成真实分组，以下均在本项目的虚构工作空间操作，未修改真实飞书。

## 实际界面与持久化

Mac Flutter Debug 热重载保留 huapohen 登录。点击消息标题右侧三条杠，应用导航与会话列表之间出现独立分组列，含齿轮、消息/未读/标记/@我/标签/单聊/群聊/已完成。iPhone 同一账号热重载后，消息快捷项左侧三条杠打开约 78% 宽侧滑抽屉。没有重装 App 或重新登录这两个客户端。

Web 构建成功后，使用同一 huapohen 账号从真实 UI 创建“人机共创”标签。编辑规则为会话名称包含“人机共创”，自动匹配“人机共创公司 · 全员协作”；从标签菜单“添加会话”勾选“原生办公 · 产品共创”，真实保存后总计两个工作群，两者均包含人和 Agent。

- 标签 ID：`label-329dd855-0696-4a9e-b188-5c6324173bc6`。
- 独立 API 读回个人 revision 4、规则 `人机共创`、room_count 2。
- Mac 与手机无需重登录均看到该标签；点击后准确显示两个群。
- 手机齿轮打开“编辑分组”，展示常用分组、侧栏分组、标签顺序和隐藏区域。常用加号选择“人机共创”并保存，消息页快捷 chips 实际增加该标签。
- 侧栏内置分组和标签各自排序；标签分区位置固定，不把 API order 描述成任意跨区拖动。

Flutter Web 表单自动化需等待真实焦点更新，再填文字并移出焦点后保存。首次同一脚本立即 click/fill 使规则未进入 Dart 状态，API 返回 null；已通过再次聚焦、实际填入、确认字段计数、保存与独立读回确认规则生效。没有把 DOM 临时值当成业务成功。

读回证据：ignored `output/live-human-groups-1741.json`。保存的个人标签和常用项留在演示工作空间，便于用户继续体验；不改变群成员、消息和任务内容。

## Agent 使用原生协议

使用原有 activate-agent 的独立机器凭据，调用当前服务 `/api/im/mcp`：先 `im_message_groups`，再 `im_create_message_group`，创建其自己的“共同协作”标签，规则“原生办公”。实际返回一个匹配群。没有使用鼠标、键盘或代用人类身份。

操作前后分别读取 huapohen 分组，结果完全相同，证明 Agent 没有修改人类的个人导航。证据为 ignored `output/live-agent-groups-1731.json`。这里证明了原生接口可用；不声称模型自动规划了此次 API 调用。

## 默认好友与人格入口

手机 Agent 列表实看：第一个 `activate-agent`，第二个“机伴”，之后仍保留可见的共享 Agent 同事。列表排序依据服务端真实 system_agent_key，没有前端伪造身份。机伴显示独立电脑/指针图标。

点击默认同事成员操作→人格与参与→选择工作会话，可见“主动参与”和“允许主动执行”两个独立开关。非会话所有者只读，界面明确说明权限和当前会话范围；所有 Agent 均有同一入口。该实看没有修改用户会话参与策略。

## 对应代码与验证边界

- 分组 UI/接口详情：[MESSAGE_GROUPS_UI_1739.md](MESSAGE_GROUPS_UI_1739.md)。
- 真实飞书只读观察：[FEISHU_MESSAGE_GROUPS_1714.md](FEISHU_MESSAGE_GROUPS_1714.md)。
- 独立 UI 回归：[MESSAGE_GROUPS_UI_TESTS_1737.md](MESSAGE_GROUPS_UI_TESTS_1737.md)。
- Doc Free 最新全量 218/218 通过，包含默认同事、妙记、分组、权限与 MCP CAS。
- Mac、iPhone 为热重载调试客户端；Web 本地 release 构建已完成。五端 CI 产物按最终版本台账另外记录，旧 0.5 产物不是本批证据。

当前分组未提供参考产品的全部云文档会话、话题、服务台、标签通知高级策略和复杂规则组合。已完成的入口均基于真实数据，不用空按钮表示完整飞书复刻。

## 重启与五人低资源演示

17:47 左右重启至最新配套提交后，human 分组 revision 5、两个标签内会话、四个常用快捷项全部读回；activate-agent 的个人 revision 2 和单独标签同样保留。Mac/iOS 热重载成功，最新 Web release 再构建成功。

保留用户 Mac 和 iPhone 上的 huapohen，另在同一个 Chromium 的四个隔离 BrowserContext 中登录工程、设计、运营、产品账号。产品上下文使用 430px 移动布局，其他三个为桌面布局；各自通过实际登录表单鉴权。这样五位人类身份同时在线，只有一台手机模拟器，未新增虚假身份或启动五台设备。临时用于跨端验收的 Web huapohen 已恢复为原工程成员。
