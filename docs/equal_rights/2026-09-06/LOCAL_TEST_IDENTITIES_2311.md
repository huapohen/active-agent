# 人机 · 管理员、员工与 Agent 独立测试身份

- 文档建立时间：2026-09-06 23:11（Asia/Shanghai）。
- 分支：Active Agent 与 Doc Free 均为 `equal_rights`。
- Active Agent 基线：`9cd1f613bdc63a5b4f3b27d6dfb06d4d63842145`，2026-09-06 22:38:40 +08:00，`feat(office): align native message menus and complete source work actions`。
- Doc Free 基线：`4dcbf7e47acf0f9eca91c3df5e507e84ca6d4e5f`，2026-09-06 22:35:53 +08:00，`feat(im): add personal message actions and atomic source workflows`。

本批最终实现已提交，并于 2026-09-06 23:44 用 `git show` 核对：

| 仓库 | 实现 commit | Git 提交时间 | 描述 |
| --- | --- | --- | --- |
| Active Agent | `cd34da4d28be4e92111b201b96a96caa0e6aedcc` | `2026-09-06T23:43:40+08:00` | `feat(office): add personal sidebar collapse and native message attention` |
| Doc Free | `f6de1e1122493eb156b105db796a3d5e3a0c7cf8` | `2026-09-06T23:43:40+08:00` | `feat(im): add independent highlights and private urgency workflows` |

账号改动包含在上表的最终实现中，前述两个旧哈希仅为基线。跨功能最终检查、Mac 三身份实际登录和本机工作空间名称修正见同目录新批次记录 `SIDEBAR_ATTENTION_IDENTITIES_DELIVERY_2340.md`。

## 交付范围

在本机 `http://127.0.0.1:3218` 的「人机共创公司 · 演示」中建立三种明确的测试身份，加入原有「人机共创公司 · 全员协作」群。

| 登录用户名 | 身份种类 | 企业角色 | 验收目的 |
| --- | --- | --- | --- |
| `test.admin` | human | admin | 可查看企业管理接口，独立登录和协作文档 |
| `test.employee` | human | member | 员工拥有协作能力，不能获得企业管理权限 |
| `test.agent` | agent | member | Agent 使用自己的账号和会话，按企业角色授权 |

原有 `huapohen` 保持 owner。Agent 与 human 使用相同的账号、会话和企业权限规则；`agent` 类型本身不授予管理特权。这是三个真实的本地身份，并非 UI 切换标签。

密码沿用用户已指定的本机测试口令，从已忽略的 `data/office/access.json` 读取。完整账号凭据只保存至已被 Git 忽略、权限为 `0600` 的 `data/office/test-accounts.json`。本文、命令参数和输出均不记录完整口令或 token。

## 本机口令策略

Doc Free 默认创建账号仍要求至少 10 个字符。为兼容当前用户已指定的本机测试口令，新增服务器端配置桥：

```text
HOST=127.0.0.1
NODE_ENV=development
DOC_FREE_LOCAL_PASSWORD_MIN_LENGTH=6
```

Active Agent 的 `scripts/dev_office.py` 显式提供以上配置。服务器在初始化账号组件时校验策略；只有明确的 development 环境与 loopback 监听地址同时成立，才能将最小长度设为 6–9。通配监听、非本机地址、production 环境、缺失开发标识或非法最小长度会拒绝短口令策略。客户端请求中的策略字段不能更改服务器规则。

策略控制新建与修改口令，不迁移或重写既有密码哈希。恢复默认策略后，既有合法会话及已注册账号继续工作。部署到云端时应移除本机例外并按部署要求配置认证；本批不是生产身份系统验收。

实现文件：

- Doc Free：`native-accounts.js`、`native-im.js` 的配置透传、`server.js` 环境桥。
- Active Agent：`scripts/dev_office.py`、`scripts/provision_office_test_accounts.py`。

## 创建与恢复边界

测试脚本先检查凭据文件权限及 Git 忽略状态，再将计划用户名、种类、角色、稳定 client_id 和凭据写入私有清单。成员创建和角色调整使用现有 human owner 身份；初始化口令专用的 provisioning token 仅用于 `/admin/accounts`。

`/admin/accounts` 可以重置已有账号，因此脚本必须先用目标成员自己的凭据读取 `/auth/account`，只有返回无账号时才调用初始化接口。既有用户名冲突、清单身份不匹配、组织不匹配或创建回执丢失且不能安全恢复时，停止处理，不重置未知账号，不将未知身份提升为管理员。

测试身份的登录会话在私有清单中短暂记录，以便中断后只清理本脚本创建的会话。注销时再次验证身份，并明确拒绝注销 owner 会话。三个验证会话会同时在线，完成验证后逐个注销；原有 Mac 登录及其他会话保持原样。

测试 Agent 在该演示群设为 paused，避免权限验收触发后台模型工作；不改变其他 Agent 的参与模式。账号创建和验证不发送聊天消息、不调用模型、不启动更多模拟器。

## 验证记录

截至 2026-09-06 23:11，已完成配置及鉴权定向检查：

- `node --test tests/native-accounts.test.js tests/native-auth.test.js`：46/46 通过。其中新增 5 项覆盖默认最小长度、客户端不能降级、人类与 Agent 的短口令独立会话、无效环境拒绝、恢复默认策略保留账号和会话。
- `python -m pytest tests/test_office_launcher.py -q`：3/3 通过。
- 测试账号脚本通过 `py_compile` 语法检查。

2026-09-06 23:23:14（Asia/Shanghai），在统一重启后的真实 3218 服务完成创建和验收；23:24:14 完成可恢复重跑验证。

| 用户名 | 独立账号登录 | `/enterprise/admin/members?limit=1` | 共享群 | 共享文档 |
| --- | --- | --- | --- | --- |
| `test.admin` | 通过 | HTTP 200 | 通过 | 12/12，内容与 revision 一致 |
| `test.employee` | 通过 | HTTP 403 | 通过 | 12/12，内容与 revision 一致 |
| `test.agent` | 通过 | HTTP 403 | 通过 | 12/12，内容与 revision 一致 |

三者同时持有三个不同的真实登录会话。脚本验证后逐个注销，并再次调用 `/me` 确认会话已不可用。原有 owner 角色及全部既有会话记录均保留。演示群由 8 位成员增至 11 位，测试 Agent 的该群参与模式为 paused。

重跑前另外建立一个 `test.employee` 会话，保持在线后再次执行整套脚本：三个账号记录完全不变、未增加成员、既有员工会话仍可访问 `/me`。随后仅注销本次建立的探针会话，确认其失效。这证明重复执行不会重置已有测试账号或连带注销其他客户端。

脱敏机器证据：

- `output/test-accounts-verification.json`：三账号权限、12 份文档的 id/revision、三个同时独立会话、注销及 owner 会话保留结果。
- `output/test-accounts-resume-verification.json`：3 个账号记录不变、重跑新增成员数为 0、11 位群成员、既有员工会话保留及探针注销结果。

以上验证只使用本机原生 API，没有聊天消息、模型调用、额外模拟器或真实飞书写操作。私有凭据文件实测权限为 `0600`，并由 Git 忽略。界面账号密码登录的渲染与设备交互仍由客户端验收记录单独说明，不能用本批 API 结果替代 UI 验收。

兼容性说明：当前 Python IMClient 不能解析服务端顶层 `code` 错误字段，因而本脚本根据实际 HTTP 401/403 识别登录失败与权限拒绝；本批没有扩大修改通用客户端。三账号首次创建前的预检因该解析差异曾安全停止，当时尚未创建成员；修正测试脚本判定后完成上述真实验收。

## 本机复验

在 Doc Free 已由本批配置启动后，从 Active Agent 项目执行：

```sh
python scripts/provision_office_test_accounts.py
```

同一私有清单可重复执行；脚本复核现有账号与组织归属，不重置已开户的密码。通过三个独立 Web 会话与已有 Mac/模拟器即可查看多身份效果；本批先用三个同时存在的真实 API 登录会话验证身份隔离，避免额外模拟器消耗。
