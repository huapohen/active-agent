# 顶部置顶与应用内加急：独立 UI 组件交付

- 记录时间：2026-09-06 23:11:00 +08:00。
- 同批补充：23:18:28 +08:00 起，按主集成转交的真实飞书加急弹窗观察，对齐渠道、未读选择与快捷发送。
- 分支：`equal_rights`。
- Active-Agent 基准 commit：`9cd1f613bdc63a5b4f3b27d6dfb06d4d63842145`，2026-09-06 22:38:40 +08:00，`feat(office): align native message menus and complete source work actions`。
- doc_free 基准 commit：`4dcbf7e47acf0f9eca91c3df5e507e84ca6d4e5f`，2026-09-06 22:35:53 +08:00，`feat(im): add personal message actions and atomic source workflows`。
- 本文记录上述基准之后新增的组件、协议接法与专项验证；最终提交及会话集成、真实后端、原生构建验收由主集成交付记录补充。本文不把基准 commit 误写成新增实现已提交的证据。

## 本批范围与参考依据

此前实际飞书手机长按菜单已确认 `Pin`、`置顶消息`、`加急` 是不同入口，本批把顶部置顶和加急实现为独立业务组件。后续后端 Agent 实际打开飞书加急弹窗，主集成转交的观察包括搜索、全选未读成员、成员复选框、已选人数、三种发送方式、取消及带 `⌘+Enter` 提示的发送按钮；本组件按这些可核对的功能对齐。顶部置顶深层页面尚无本批新增实际观察，两者都未在本子任务中取得原生人机渲染截图，不能笼统称为逐像素复刻。

新增文件为 `message_highlights.dart`、`message_urgency.dart` 及各自的 widget 测试。本子任务没有修改会话、动作菜单、状态对象或原生宿主，没有占用 CUA、重启服务或自行提交。主集成同时把这些公共接口接入消息菜单和会话顶部。

## 顶部置顶

`OfficeMessageHighlightsBanner` 读取当前会话的顶部置顶，显示消息正文、当前来源状态、查看入口、个人收起和管理入口。正文预览最多两行并省略，经典表情复用共享 `OfficeEmojiText` 渲染，不暴露 `:feishu:...:` 编码。管理面板提供刷新、关闭、完整预览、查看原消息、个人收起/展开和取消共享置顶。

```dart
OfficeMessageHighlightsBanner(
  key: /* 当前工作身份与会话共同限定的 key */,
  state: state,
  roomId: roomId,
  onOpenMessage: (String messageId) { /* 定位来源 */ },
  onManage: /* 可选；省略则使用内置管理面板 */,
)

Future<bool?> showOfficeMessageHighlight(
  context, state, roomId, {
  Json? message, // 提供候选消息则进入设置/替换预览；省略则管理当前置顶
  ValueChanged<String>? onOpenMessage,
})
```

手机为可关闭底部面板，桌面为对话框。管理面板的“查看原消息”先关闭本面板，带回真实 `_changed` 结果，再回调定位一次；重复执行保留的旧按钮回调不会误弹底层页面。banner 的查看入口直接定位，不执行导航 pop。

| 操作 | 协议与约束 |
| --- | --- |
| 加载 | `GET /rooms/:rid/highlights`，返回裸 snapshot |
| 设置/替换 | `PATCH /rooms/:rid/highlights`，`base_revision` 为共享置顶版本；`message_id` 与新 GET 取得的 `message_revision` 指定来源 |
| 取消 | 同一 PATCH，`message_id:null`；明确说明 Pin 集合不受影响 |
| 本人收起 | `PATCH /rooms/:rid/highlights/preferences`，发送共享 `base_revision` 与 `collapsed` |

当前最多一条共享置顶；个人收起仅针对所见共享版本。其他成员更新顶部置顶后，新版本重新展开。UI 显示服务端返回的最新正文；来源编辑显示“消息内容已更新”，已撤回显示安全占位，个人隐藏来源不显示旧正文。

设置/取消权限完全采用服务端 `permissions.can_set` / `can_clear`。本批后端规则为真实当前会话成员可操作，Human 与 Agent 同权；不从企业管理员、Agent 商店或作者身份推导额外跨会话权限。版本冲突要求先刷新，不能用旧版本连续覆盖。此模块不调用原 `/pin`，也不改 Pin 集合。

## 应用内加急

```dart
Future<Json?> showOfficeMessageUrgency(context, state, roomId, Json message)
Future<bool?> showOfficeMessageUrgencyDetail(context, state, roomId, String urgencyId)
Future<void> showOfficeRoomUrgencies(context, state, roomId)
```

相应公共 widget 为 `OfficeMessageUrgencyComposer`、`OfficeMessageUrgencyDetail` 与 `OfficeRoomUrgencies`。所有面板具有明确的关闭入口，手机/桌面共用身份和业务规则。

### 发起

发起页重新 GET 原消息与会话真实成员，依据当前后端合同仅允许消息作者创建。接收人排除作者本人，Human 与 Agent 在同一真实成员列表中可搜索、可多选，最多 100 人。不用全局 principal 列表、Agent 商店或虚构联系人填补接收人。

发送前再次核对来源版本及已选成员。来源编辑或成员离开要求先查看更新后的内容/名单，再显式发送。发送方式以三项单选结构显示：默认“仅应用内”，另外两项“应用内 + 短信”与“应用内 + 电话”明确标注渠道未配置、禁用选择。只有 `in_app` 会进入真实请求，未来接入可配置渠道后需同时增加服务端能力，不能只解除 UI 禁用。

发送按钮显示已选人数对应的可用状态，底部保留取消入口。桌面支持 `⌘+Enter` 和 `Ctrl+Enter`；快捷键与按钮走同一发送守卫，未选成员、离线、发送中、旧身份和待核对状态均不能绕过限制。

“全选未读成员”额外读取 `GET /rooms/:rid/messages/:mid/readers` 并重新读取当前来源与成员。仅采用 `receipt_summary.known:true`、`basis:explicit_read_ack` 的快照；每个接收人还必须 `status:unread`、`read:false`、`current_member:true`、`same_membership:true` 并仍在本次真实成员名单。已读、离开后重入、发送后新加入而无原接收快照、未知状态与名单外 ID 都不纳入自动选择。

全选把符合证据的未读成员加入现有选择，超过 100 人要求手动分批，不静默截断。旧消息没有阅读证据或读取失败时，不自动选择任何新成员，展示原因与重试入口；原消息编辑后先展示新内容，要求重新确认未读选择。整个读取过程仅 GET，不写消息阅读 ACK，也不写加急确认。

```text
POST /rooms/:rid/messages/:mid/urgencies
{
  client_id: OfficeState.newClientId(),
  base_revision: 当前实际来源版本,
  recipient_ids: [真实当前会话成员 ID],
  channel: in_app
}
=> { urgency, duplicate }
```

第一次 POST 前保存完整发送意图。网络结果不确定或回包丢失时，草稿锁定；重试和重新打开同一来源都复用同一 `client_id`、来源版本、接收人和渠道，避免重试时另生成一条加急。保存范围为内存中的 OfficeState、身份代次、服务端地址、principal、会话及来源消息组合；应用重启后的持久化恢复尚未实现。

确定性 4xx（除 `idempotency_conflict`）要求重新核对，UI 不自动生成新请求；幂等冲突仍保留原意图并提示检查已发送记录。后端同批明确保持“来源状态与成员授权先于 client ID 恢复”的规则，因此首次已提交但响应丢失、随后来源或成员变更的重试可能返回 409/422，需通过已发送列表核对。未来按 client ID 查询原意图回执需要保留原成员周期与授权校验；不能把 UI 保留 client ID 当作所有跨版本恢复都已验证的证据。

创建成功后显示服务端实际返回的加急与确认统计，可进入确认详情。

### 详情、确认与隐私

```text
GET  /rooms/:rid/urgencies/:uid     => { urgency }
POST /rooms/:rid/urgencies/:uid/ack {} => { urgency, duplicate }
```

打开详情只 GET，不发送 ACK。只有当前实际指定接收人且服务端 `can_ack` 为 true 时，才显示“我已知晓”；显式点击发送空对象 `{}`，不允许代其他人确认。消息阅读游标、消息已读与加急确认保持独立。

发送者可以查看所有接收人的确认情况；普通接收人只看本人。客户端再次按 `summary_scope` 和当前 principal 过滤接收列表并重算本人统计，避免不符合合同的数据把其他人的姓名或总数露出。Agent 接收者使用同一规则。

来源改变、撤回、缺失、个人隐藏，以及原成员关系失效都会阻止不适用的确认。`source_missing` 的 `message:null` 以安全 ID 占位接纳；隐藏/撤回不渲染旧正文。发送者离开导致 `sender_unavailable` 时，即使正文还在，也尊重 `can_ack:false`。已存在的确认时间由服务端状态展示。

确认时收到 403/404 会清除已加载的私有正文与名单；暂时错误要求刷新后再确认。离线禁用确认，不把用户打开页面误记为已经知晓。

### 会话加急记录

```text
GET /rooms/:rid/urgencies?box=inbox|sent|all&status=pending|all&limit=50&before=seq
=> { items, has_more, next_before }
```

列表提供“收到 / 发出 / 全部”及“仅看待确认”，游标按序号递减并去重。打开真实详情后返回刷新列表。分页遇到权限撤销会清空此前缓存的私有条目，不能继续把旧页面留给失权身份查看。

## 身份、异步与集成边界

全部组件绑定创建时的 OfficeState、identityGeneration、endpoint、稳定 principal ID 和会话。工作身份或来源作用域变化后，旧组件永久失效，迟到 GET/PATCH/POST 不恢复旧正文、不回填旧草稿、不向新身份报告旧操作。banner 被保留但传入其他 room/state 时也失效，应由集成方按会话和身份提供 key 创建新组件。

主集成负责把页面打开/关闭纳入现有阅读报告暂停机制，并把查看原消息连接到真实定位方法。顶部 banner 自身不增加占位加载高度，成功加载后才显示；这一行为不等同于整个会话滚动定位已经验证。

## 验证

```text
flutter test --no-pub test/message_highlights_test.dart test/message_urgency_test.dart
37/37 PASS = 顶部置顶 14 + 加急 23
/tmp/active-office-highlights-urgency-final-test.log

flutter analyze --no-pub lib/ui/message_highlights.dart lib/ui/message_urgency.dart test/message_highlights_test.dart test/message_urgency_test.dart
No issues found
/tmp/active-office-highlights-urgency-final-analyze.log
```

置顶 12 项覆盖两行表情预览、banner 查看与本人折叠、桌面/手机管理面板关闭后单次定位、新共享版本展开、Human/Agent 真实来源版本设置、服务端权限取消、CAS 冲突、离线锁定、隐藏/撤回、身份/保留 room 变更与迟到响应。

加急 21 项覆盖 Human/Agent 作者和实际成员、非作者拒绝、来源撤回、来源/成员变化复核、提交成功但响应丢失后的同 client ID 重开重试、身份切换、Human/Agent 显式本人 ACK、接收人隐私、来源改变/缺失/隐藏及发送者失效、分页过滤、离线与迟到响应、ACK 失权清除私有详情。后续新增四项覆盖真实未读证据与成员周期筛选、未知/失败后重试、迟到未读响应的身份隔离、短信/电话禁用及桌面快捷键不能绕过选人限制。

以上为 mock OfficeState 的组件和协议调用测试。本文件不将其称为真实生产网络、真实飞书子页视觉验收、原生 macOS/iOS/Android 运行验证或完整飞书办公功能复刻。全局集成和原生构建结果以本轮主交付报告为准。
