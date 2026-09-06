# 设置与账号状态隔离 · 2026-09-06 19:43

记录时间：2026-09-06 19:43:23 +08:00（Asia/Shanghai）。工具读取 UTC 为 `2026-09-06 11:43:23`。

分支：`equal_rights`。写本文时 Active 已提交基线：`392eb80c86127b75a092e7316d17c4ddd23937aa`，提交时间 `2026-09-06T18:59:09+08:00`，描述 `docs: record group chat delivery with live evidence and remaining parity gaps`。这是本批开发基线，本批功能由主线程后续统一提交；本基线 commit 不包含以下尚在工作区的实现。

本记录补充 [18:28 设置对齐记录](SETTINGS_ALIGNMENT_1828.md)，描述状态与底栏编辑身份保护。设置分类、账号表单、新偏好消费者由并行的界面批次记录，本文不将其归为自身实现。没有操作真实账号、飞书设置、真实企业成员或 3218 服务。

## 问题与修复

### 账号和设置的迟到响应

原 `getAccount`、`loadAccountSessions`、`saveSettings` 在请求完成后直接写入共享 OfficeState。由于底层通用请求并不对所有成功响应统一抛出身份失效异常，A 身份的延迟响应可能在 B 登录后回填 A 的账号、登录会话或设置。

新增只读 `identityGeneration`。身份快照同时包含 generation、endpoint、principal ID；generation 在断开、连接和释放时变化，能够识别相同服务与成员 ID 的 A → B → A 回切。以下操作在发起时捕获快照，响应后复核，不匹配抛出 401，禁止回填或进行后续操作：

- `getAccount()`：读取当前账号；
- `loadAccountSessions()`：读取登录会话；
- 新 `reloadSettings()`：读取完整设置，供用户明确采用最新设置时同步全局状态；
- `saveSettings()`：提交设置后回填；
- `revokeSession()`：撤销完成后再决定退出自身会话或重读列表。

没有把 `_request` 全局改成新的异常语义。其他业务已有 connect、refresh、已读等 generation 丢弃逻辑，本批以明确受影响的账号与设置链路为边界，避免扩大回归面。

### 密码修改的三阶段身份保护

原 `setAccount` 在账号 POST 后调用 `loginWithPassword(endpoint, ...)`，其 `endpoint` 是可变共享状态。现在账号修改捕获原身份与服务地址，POST 完成后复核；后续密码登录固定使用原地址，在登录响应回来时再次复核；新连接完成后，只有该次连接 generation 仍然有效才记录登录 session ID。

因此，在账号 POST、密码登录或新连接任意阶段切换到 B，都不能由 A 的迟到响应重新接管 B，也不能把 A 输入的密码带到 B 的服务地址。正常修改密码仍能在原端点重新登录，并更新自身 generation。

### 底栏编辑的身份与离线行为

底栏编辑器在 `initState` 同时捕获 owner OfficeState、generation、endpoint、principal ID、排序与 revision，并监听状态变化。

- 真正身份变化：永久锁定该次编辑器，隐藏旧排序与冲突预览，停止保存；切回相同 ID/revision 也不会复活旧表单。
- 同一身份短暂离线：保留排序草稿，不进入永久失效状态；禁用保存与读取最新设置。
- 409：仍保留选择与排序，先读取最新设置，再明确选择“使用服务器底栏”或“保留我的排序继续编辑”；冲突未处理时禁用保存。
- 旧读取/保存晚到：既不展示其他身份的冲突资料，也不自动关闭当前显示的锁定对话框。

原有底栏条目、最多四项、至少一项、排序、恢复默认和企业管理权限过滤继续生效。

## 文件

本批自有实现：

- `apps/office/lib/office_state.dart`；
- `apps/office/lib/ui/mobile_navigation.dart`；
- `apps/office/test/settings_identity_test.dart`；
- 本文档。

`office_state.dart` 中根代理原有的 `retractMessage(..., sourceRoomId: ...)` 修改完整保留。没有修改其他代理负责的 settings、账号表单、shell、main 或 Doc Free 后端。

## 验证

新增 `settings_identity_test.dart` **14 条**，通过真实 OfficeState 账号/设置 transport 加 MockClient 控制延迟响应；启动业务目录以 fixture 省略，未请求真实网络。

| 场景 | 结果 |
| --- | --- |
| account/sessions/reload/save 的 A 迟到响应，B 已在另一端点登录 | 4 条全部拒绝，B 的账号、会话、设置保持 |
| 同端点 A → B → A 且设置 revision 相同 | 原 PATCH 仍被拒绝 |
| 真实 HTTP 设置 409 → reload → 显式 revision 10 PATCH | 旧值保留，最终 revision 11，实际提交基准为 7/10 |
| 密码修改 POST、login、connect 三阶段分别延迟 | 3 条均不能重新接管 B，登录请求只去原端点 |
| 正常密码修改与旧会话撤销晚到 | 正常重登录成功；旧撤销不登出 B，随后 B 主动撤销自身会话仍正常退出 |
| 390/1512 底栏编辑 | 离线禁写保留排序；同 revision 的 A → B → A 永久锁定 |
| 冲突预览迟到、保存迟到 | 隐藏旧资料，不误关当前对话框、不产生 B 的新写入 |

```sh
flutter test --no-pub test/settings_identity_test.dart \
  test/office_state_test.dart test/read_receipts_test.dart
```

结果：**25/25 通过**（新增 14、原状态 6、已读 5）。

```sh
dart analyze lib/office_state.dart lib/ui/mobile_navigation.dart \
  test/settings_identity_test.dart
```

结果：**No issues found**；`git diff --check` 通过。

另补跑 `profile_navigation_test.dart` 与 `auth_providers_test.dart`：底栏/妙记 4 条及 OIDC 2 条通过；2 条头像→设置测试停在旧的“文字大小”文本断言，新设置页面已调整标签，已交给界面代理同步。这个中间结果不等于全量测试通过，最终合并后的验证由主线程记录。

本批没有构建发布安装包、启动设备、重启服务或提交/推送代码。
