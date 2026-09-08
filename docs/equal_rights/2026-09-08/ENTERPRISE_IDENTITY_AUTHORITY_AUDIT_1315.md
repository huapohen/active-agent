# 企业身份与管理权限审计（2026-09-08 13:15 +0800）

## 范围

审计 `equal_rights` 分支中“我的/设置/企业管理”入口，覆盖企业管理员与普通成员身份切换、身份状态变化，以及人类和 Agent 共用同一企业权限模型。IM 登录核心未改动。

## 本次实现

- `OfficeState.canManageEnterprise` 继续以服务端返回的 `capabilities.access_admin` 为准，并新增成员状态闸门。成员状态为 `disabled` 或 `revoked` 时，即使旧摘要仍残留管理员能力，也不会显示或打开企业管理入口；未知状态仅在服务端未返回状态字段的兼容场景下保留能力。
- “我的”个人面板在桌面和手机身份区显示企业角色与状态：企业所有者、企业管理员、普通成员，以及正常/已停用/已撤销。这样切换成都花破痕科技有限公司管理员与万联易达控股集团有限公司普通员工后，人眼可以直接核对当前身份。

## 证据

- 基线实现提交：`025fd560110c912e134520d41fd65b7a88c4a71f`（2026-09-07 12:11:05 +0800，移动消息分组与原生群聊编辑器）。
- 基线文档提交：`1774c284ba41d5db71ed77a4b905bd3db1c0369f`（2026-09-07 12:18:30 +0800，移动分组视觉与原生验证记录）。
- 本次实现截至本文时间仍在工作树，尚未形成新提交；提交时应把本文与对应实现一起提交，并把最终 SHA 回填到交付记录。
- Flutter 测试：`flutter test test/profile_mobile_panel_test.dart test/profile_navigation_test.dart`，26/26 通过。
- Flutter 静态分析：`flutter analyze lib/office_state.dart lib/ui/profile_menu.dart`，无问题。
- 新增回归用例 `disabled or revoked membership cannot expose enterprise admin entry`，覆盖停用/撤销状态下的权限收紧与入口隐藏。

## 当前仍需验证

运行时仍需在已登录客户端逐一切换两个真实企业身份，确认服务端返回的 `membership.role/status` 与 `capabilities.access_admin` 和本地 fixture 一致；企业管理后台的完整页面能力继续由 `EnterpriseState` 的服务端权限控制。钱包、二维码、多账号持久化等未接入项不应在交付中宣称已完成。
