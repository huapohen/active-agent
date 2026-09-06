# 企业成员目录、实时详情与部门层级 · 2026-09-06 19:18

记录时间：2026-09-06 19:18:06 +08:00（Asia/Shanghai）。

本记录独立于早期企业管理初版文档，描述 `equal_rights` 本轮成员目录交互实现与 fixture 验证。时间由工具读取的 `2026-09-06 11:18:06 UTC` 换算；没有操作真实企业成员。

## Commit 与本批范围

| 仓库 | 分支 | 写本文时的基准 commit | commit 时间 | 描述 |
| --- | --- | --- | --- | --- |
| Active Agent | `equal_rights` | `392eb80c86127b75a092e7316d17c4ddd23937aa` | 2026-09-06 18:59:09 +08:00 | `docs: record group chat delivery with live evidence and remaining parity gaps` |
| Doc Free | `equal_rights` | `eb1f7b9b558aa9745dd154376b82b76c1c043e1c` | 2026-09-06 18:56:42 +08:00 | `feat: add versioned group profiles announcements and personal pinning` |

上述是本批开发时读取的已提交基线，不能把它们当成本批功能已经进入该 commit 的证明。本批由主线程统一审查、提交；后续交付记录应补充实际功能 commit。

本批只修改 Active 的 `enterprise_state.dart`、`ui/enterprise.dart`，新增 `ui/enterprise_directory.dart`、`test/enterprise_directory_test.dart` 与本文档。没有修改 Doc Free 后端、IM 群聊、消息、登录、Office 共享状态或公共对话框。既有服务 3218 未被停止、重启或写入。

## 参考与设计依据

继承 [企业参考与范围](ENTERPRISE_REFERENCE_AND_SCOPE.md)，并结合主线程本轮只读观察的飞书企业成员页：左侧组织/部门树、右侧成员搜索与状态筛选、直属成员语义、详情入口及底部分页。观察到的手机号等人类专属个人字段，没有照搬到人机共同目录。

契约依据：Doc Free `native-enterprise.js` 与 `docs/equal_rights/2026-09-06/ENTERPRISE_ADMINISTRATION.md`。成员的 `kind` 仅表达 Human/Agent，管理权限来自企业角色与后端 capability；UI 没有给某一种身份额外管理权。

## 已实现的真实交互

### 1. 成员详情独立读取

点击桌面姓名或“详情”、移动成员行，调用 `GET /enterprise/admin/members/:principal-id`。详情显示真实响应中的名称、身份标识、管理角色、账号状态、完整部门路径、任职组织、职业、职位、来源组织、加入时间与成员编号。刷新按钮重新读取；编辑按钮使用这次详情返回的记录与 revision。

详情加载不使用列表行直接充当最终数据。控制器校验返回对象及 principal ID，防止错误响应混入当前详情。请求序号避免较早的刷新结果覆盖较晚结果。复制入口仅复制成员编号。

390 宽度使用可滚动的全屏详情；桌面使用固定宽度、受视口高度约束的详情对话框。底部编辑入口在滚动正文外，避免长资料掩埋主要操作。

### 2. 服务端组织筛选与分页

现有搜索、账号状态、管理角色、部门筛选新增任职组织条件。组织选择发送 `organization_id`，与 `q/status/role/department_id/page/page_size` 同时参与服务端过滤。翻页和搜索保留组织条件，切换过滤条件从第一页开始，数量取后端 `total`，不只过滤已经载入的一页。

搜索提示对应当前后端实际支持的姓名、成员 ID、职业与组织。请求序号保护继续生效，旧搜索即使后返回，也不会替换新列表、页码或总数。筛选头在高度受限时自身滚动，给成员列表和分页保留空间。

### 3. 真正的部门树

部门树按 `parent_id` 递归构建，输入顺序不要求父节点在前。父节点支持展开/收起；搜索命中子部门时保留祖先路径，并显示命中的完整层级。部门管理页复用同一层级浏览组件，保留新建、编辑与后端允许的空部门删除入口。

`member_count` 是后端直属人数，界面明确标注“直属成员”，不累加子部门人数。成员页选择部门保留当前其他筛选；从“部门管理”点击部门进入成员页时，按界面说明重置搜索、状态、角色和组织条件，显示该部门直属成员。搜索输入与下拉框同步复位。

### 4. 版本冲突保留草稿

成员编辑继续使用后端 `base_revision` 乐观锁。发生 409 后，输入的名称、职业、职位、角色、状态、部门和组织保留，保存按钮暂停，提供以下真实恢复流程：

1. 点击“读取最新成员资料”，读取同一个成员的当前记录。
2. 展示最新 revision、名称、角色、状态、部门、任职组织、职业和职位。
3. 点击“保留输入并采用最新版本”，只采用新的基准记录/revision，保留当前输入。
4. 用户再次“保存变更”，发送保留的字段和最新 `base_revision`；再次冲突仍回到此流程。

读取最新记录后若当前角色不能继续编辑该成员，不提供采用按钮。没有自动合并、自动覆盖或静默重复提交。

### 5. 人机同权与身份边界

Human 和 Agent 使用同一套企业角色、部门、任职组织和职业字段。人类 owner 能编辑 Agent，Agent owner 也能编辑人类；管理员不能编辑其他所有者。后端仍负责角色授权、账号状态和最后一位有效 owner 等约束。

详情和成员表单监听 EnterpriseState 及 Office 身份。身份/端点或企业管理能力改变后，原详情资料、草稿字段、访问凭据和保存按钮隐藏，显示重新打开管理页提示。异步响应仍受控制器的身份检查约束。新建成员凭据处理沿用既有一次性流程，不进入成员集合。

## 验证记录

执行时间：本文记录前完成，Flutter 本地测试，无真实网络企业写入。

```sh
/Users/lwblx/development/flutter/bin/flutter test --no-pub \
  test/enterprise_directory_test.dart \
  test/enterprise_ui_test.dart \
  test/enterprise_organizations_test.dart
```

结果：**20/20 通过**，其中新目录测试 **11 条**。

| 验证面 | 证据 |
| --- | --- |
| 组织筛选与分页 | 32 个 fixture 成员；指定组织 31 条，第一页 25、第二页 6；组合过滤后服务端总数正确 |
| 请求乱序 | 新搜索返回 1 条后，旧搜索返回 99 条/第 7 页，不能覆盖当前结果 |
| 详情响应边界 | principal ID 不匹配返回 502；身份切换后的延迟详情返回 401 |
| 部门层级 | 390/1512 两种宽度；乱序输入的 3 层树、缩进、折叠、子节点搜索保留祖先、无匹配反馈、直属计数 |
| 人机双向管理 | 390/1512 两种宽度各验证人类/Agent 详情；列表旧名称与详情新名称不同，编辑从新数据开始；真实修改任职组织、角色和部门，身份类型保持 |
| 移动筛选与跳转 | 组织 + 状态 + 文本组合请求；从部门管理进入直属列表时重置其他条件与输入 |
| 冲突恢复 | 390 宽度、300 键盘 inset；revision 1 冲突，读取 revision 2、明确采用；两次 PATCH 除 revision 外所有草稿字段相同 |
| 权限/身份 | admin 看 owner 无编辑按钮；切换身份后旧详情、草稿与保存入口隐藏；没有 PATCH |
| 原有企业功能 | 390/943/1512 控制台、普通 Agent 权限、企业应用策略、组织创建、成员创建字段等既有测试继续通过 |

```sh
/Users/lwblx/development/flutter/bin/dart analyze \
  lib/enterprise_state.dart \
  lib/ui/enterprise.dart \
  lib/ui/enterprise_directory.dart \
  test/enterprise_directory_test.dart
```

结果：**No issues found**。首轮测试发现桌面部门侧栏 `ListTile` 背景与水波纹被中间装饰层遮挡的 Flutter 诊断，已为“全部成员”行补充独立 Material 后重跑通过。

## 当前能力边界

- 部门筛选严格显示直属成员。没有“包含所有子部门”的后端查询，因此不提供虚假的开关或递归总数。
- 当前后端没有独立的 `kind` 查询参数，因此没有仅对当前分页做 Human/Agent 的伪全量筛选。
- 没有实现手机号、邮箱检索、邀请链接、批量导入、批量角色修改、HR 字段或第三方组织同步。
- 本批验证是 Flutter fixture 合约与交互测试；没有宣称真实飞书账号写入、真实企业成员变更或线上部署完成。
- 部门接口当前提供完整合法树；客户端处理父节点乱序、祖先查询和访问循环保护，不把异常的完全闭环部门图修复成新组织结构。
