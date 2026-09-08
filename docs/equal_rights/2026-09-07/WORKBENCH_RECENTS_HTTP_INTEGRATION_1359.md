# 工作台最近使用：Flutter 状态、真实 HTTP 与导航接入

- 记录时间：2026-09-07 13:59:38 +08:00。
- 分支：`equal_rights`。
- 开始验证时的历史基准提交：`1774c284ba41d5db71ed77a4b905bd3db1c0369f`。
- 该提交时间：2026-09-07 12:18:30 +08:00。
- 该提交描述：`docs(office): record mobile group fidelity and native verification limits`。
- 以上 SHA 是本轮开始时的历史基准，不是本轮实现提交。当前实现与本文由主任务统一集成、提交；本子任务没有 commit/push。

## 结果

工作台最近使用已连接 Doc Free 的真实工作身份合同。人和 Agent 使用同一套 `OfficeState` 接口，最近使用由服务端按当前鉴权身份保存；Flutter 不从常用应用、页面数组、默认首页或展示顺序推断历史。

`OfficeState` 增加 `appRecents`、`recordWorkbenchVisit(appId)`、`clearWorkbenchRecents()`。初始化、`refresh()` 和 `refreshOffice()` 接收服务返回的 `recents`；注销与工作台权限拒绝清空当前展示状态。旧服务未返回 `recents` 时兼容为空数组。

| 操作 | 服务合同 | Flutter 行为 |
| --- | --- | --- |
| 获取工作台 | `GET /api/im/workbench` | 接收 `apps`、`favorites`、`recents` |
| 编辑常用应用 | `PATCH /api/im/workbench`，`{favorites}` | 采用服务返回的完整工作台状态 |
| 实际访问应用 | `POST /api/im/workbench/recents`，`{app_id}` | 服务确认后更新个人最近使用 |
| 清空最近使用 | `DELETE /api/im/workbench/recents` | 采用服务返回的空历史，保留常用应用 |

后端合同由并行任务提供并冻结：MRU 顺序、去重、上限 32、空历史为空数组、按应用当前权限过滤。对应 API/MCP/A2A 的后端实现和验证归属 Doc Free 任务，本文不把 Flutter 合同测试冒充后端全链路验收。

## 身份与并发

工作台个人修改串行提交。快速打开文档、日历时，后一条请求在前一条完成后发送，避免网络执行顺序与用户点击顺序相反。常用应用和清空最近使用进入同一队列，服务返回的完整状态不会彼此覆盖。

每条操作在排队时捕获 `generation + endpoint + principalId`，发送前和回包后均检查。切换身份后，新身份使用新队列；旧队列的尚未发送请求直接拒绝，不借用新账号令牌发送。已发送的旧请求可以完成其原账号操作，但不能写入新账号内存；A→B→A 也通过 generation 区分。

刷新携带读取序号与修改版本。旧刷新不能覆盖已成功记录的最近使用，较新的刷新优先于较早的迟到回包。修改进行中跳过工作台背景读取，直接采用修改响应。请求失败向发起方返回错误，同时不阻断后续个人操作。

## 实际页面访问

`OfficeWorkbenchNavigator` 在页面首帧之后确认当前页面仍处于前台、身份未变化、路由受支持、应用已注册且可用，才提交最近使用记录。工作台内打开应用、导航到其他应用及返回已有页面实例的显式导航沿用原有返回/关闭栈。

以下情况不产生记录：

- 首次打开工作台但没有使用应用。
- 再次点击当前已打开的同一路由。
- 一个页面在首帧前被另一个页面替换。
- 未知应用、外部 URL、无权限页面。
- 能展示内建页面但当前应用目录没有注册对应 `app_id`。

访问记录失败不阻塞真实应用页面，也不在本地补造历史。主任务另行负责左侧/底部导航的入口记录和“最近使用”展示，本文不对该并行修改独立声称完整 UI 验收。

## 验证

执行以下 Flutter 回归，共 **28/28 通过**：

```text
flutter test test/office_state_workbench_http_test.dart \
  test/workbench_navigation_test.dart \
  test/office_state_test.dart --reporter expanded
```

结果文件：`/tmp/renji-workbench-recents-tests.log`。

新增 `office_state_workbench_http_test.dart` 使用本机 `HttpServer.bind(loopbackIPv4, 0)` 与真实 HTTP Client，使用合成身份鉴权和可控响应闸门，无 MockClient、生产账号、生产令牌或定时 sleep：

1. 人和 Agent 历史隔离，真实请求后 MRU 更新，编辑常用与清空互不覆盖。
2. 旧身份迟到响应和排队意图不会写到新身份；新身份无需等待旧响应。
3. A→B→A 的旧 generation 回包被拒绝。
4. 全量刷新早于访问记录时不能覆盖新历史。
5. 办公刷新早于访问记录时不能覆盖新历史。
6. 较新刷新优先于较早刷新回包。
7. 连续修改严格保持点击顺序，修改中不读取陈旧快照。
8. 未知或不可用应用不发送记录；服务拒绝后可恢复使用，队列不会损坏。
9. 旧合同缺字段兼容、注销清空个人历史。

工作台导航补充真实首帧记录测试，并保留 390px/1512px、人/Agent、返回/关闭保留页面、未知页面、权限限制、身份切换与旧回调的既有回归。

`dart analyze` 检查 `office_state.dart`、`workbench_navigation.dart` 与上述两个工作台测试文件，结果 **No issues found**。过程中修复了混合 `Future<void>` 导致 `Future.wait` 推断错误的问题，当前 `refresh` 与 `refreshOffice` 显式声明结果类型。

本文验证范围是 Flutter 状态与工作台导航，不等于本轮已完成全量飞书复刻，也不替代主任务对 macOS/iPhone 实际界面的截图、点击和像素对比。
