# 消息分组界面与身份隔离回归

- 记录时间：**2026-09-06T17:37:35+08:00**（Asia/Shanghai）。
- 分支：`equal_rights`。
- Active Agent 基线 commit：`3beae3137c3193555360145300f81a0b5a1c888c`，`2026-09-06T12:49:59+08:00`，`docs: record office 0.5 release and verified native workflows`。
- 配套 Doc Free 当前 commit：`f14be82746f2ecd31e79891b4734c5455c2a067b`，`2026-09-06T17:24:31+08:00`，`feat: add personal message groups and scoped conversation labels`。
- 描述：对本轮新增消息分组控制器、真实 OfficeShell、分组布局编辑器和标签对话框增加独立回归。本文为本轮工作区证据记录，最终合入 commit 由总台账补充。
- 参考产品的只读观察另见 [17:14 飞书分组记录](FEISHU_MESSAGE_GROUPS_1714.md)，不能将参考观察与本项目测试混用。

## 验证方式与结果

新增 [message_groups_test.dart](../../../apps/office/test/message_groups_test.dart)。只替换 `OfficeState.officeRequest` 的认证传输边界，使用严格合成数据与请求断言；真实控制器、Widget、选择器、输入框、对话框、冲突合并与 OfficeShell 均实际运行。这个测试不替代 Doc Free 的真实权限/持久化测试。

```sh
cd apps/office
flutter test --no-pub test/message_groups_test.dart
dart analyze test/message_groups_test.dart
```

最终 **8/8 通过**，该文件静态分析 **No issues found**。

| 回归 | 实际断言 |
| --- | --- |
| 390×844 手机 shell | 点击消息三横线打开真实左抽屉，宽为约 78% 屏宽；点击类别关闭抽屉并真实过滤会话 |
| 1512×982 桌面 shell | 打开独立分组侧栏，保留应用与会话框架；人类单聊、Agent 单聊和人机混合群分别得到正确列表 |
| 390 像素宽 + 300 像素键盘 | 标签名称和规则可输入；第一次保存返回 409 后输入保持；读取新版本并再次保存使用同一 client_id、base_revision 从 7 到 8；无布局异常 |
| 标签完整生命周期 | 新建后同时加入人类单聊、Agent 单聊与混合群，再改名、确认删除；只发送标签 DELETE，不发送删除会话请求，原会话保留 |
| 同版本跨身份编辑 | A 的编辑器打开并有隐藏单聊草稿；切换到同 revision 的 B 后，旧表单和保存入口撤下，旧私有标签不再显示，PATCH 次数为 0 |
| 服务器会话集合过滤 | 按真实响应的 room_ids 过滤消息/单聊/Agent 单聊/群聊/未读，不用名字或伪造用户类型猜分组 |
| 身份独立版本 | A revision 7 切到 B revision 1，立即清除 A 的标签与选中态；B 的较低版本正常接受。随后 B 保存快捷项不改变 A 的 fixture 记录 |
| 迟到响应与布局冲突 | A 的 revision 99 迟到响应无法覆盖 B；布局 409 后读取并显式保留本地编辑，隐藏项、Agent 快捷项保持，并合并另一设备新增标签，提交基线为 7、8 |

表格按行为列举；部分测试覆盖一整条多步骤流程，故行为行不等同于单个 assertion 数量。两个屏宽分别是独立 Widget 测试。

## 测试推动的实际修复

初始控制器只防止 revision 降级，没有绑定身份。切换到新身份后，旧高版本可能阻止新低版本读取，迟到响应也可能污染新身份。实现已加入 endpoint、principal id 与连接状态的身份边界，以及每次请求捕获 generation 的检查；身份变化立即清空旧分组、错误和选中态。

第二个问题在真实回归中复现：Dart 的 `late final identity = controller.identityKey` 是惰性初始化。如果首次读取在保存时，编辑器会把新身份当成草稿原始身份。本轮失败记录曾捕获以 B 身份发出、却包含 A 标签排序的 PATCH。修复后，编辑器和标签对话框在 initState 显式捕获身份、版本和草稿，所有 show 入口增加身份变化守卫；同版本跨身份测试确认不再发出 PATCH。

冲突恢复保留明确的读取与再次确认：没有在 409 后自动使用新版本覆盖服务器。标签创建重试保持同一 client_id，避免一次用户意图变成重复标签。

## 本轮范围

全部为本地 Flutter Widget 测试，未运行或重启手机/桌面客户端，未启动构建，未操作真实设备、飞书设置、账户或用户会话，未连接现有 3218 服务。既有妙记测试文件保持不变。

真实分组后端的个人权限、标签归类、持久化与 MCP/A2A 合同由 Doc Free 该轮实现和测试记录说明；本记录重点验证客户端能否正确呈现并操作这些合同。
