# 媒体 SDK 真实 HTTP 复核 · 2026-09-07T12:54:42+08:00

本记录对应本轮媒体 SDK 的独立审查、修复和真实 Node HTTP 验证。Active Agent 基准为 `1774c284ba41d5db71ed77a4b905bd3db1c0369f`，Git 时间 `2026-09-07T12:18:30+08:00`，描述 `docs(office): record mobile group fidelity and native verification limits`；Doc Free 基准为 `55967f5234568d80cee36d836f06b942cb3db0b1`，同一 Git 时间，描述 `docs(im): publish mobile group fidelity protocol and delivery receipt`。两库均处于 `equal_rights`，本轮语音实现尚待主任务统一提交，基准并非语音实现 commit。

## 发现并修复的真实问题

`IMClient.request` 此前只读取 `{error: {code}}` 形式，而 Doc Free `server.js` 实际 HTTP 错误为 `{error: "说明", code: "机器标识"}`。因此媒体上传和下载前的元数据鉴权丢失真实错误码，退化为 `request_failed`。原有媒体二进制分支支持平铺格式，造成相同权限错误在两条路径上行为不一致。

先使用当前 Node 源码启动独立服务复现，新增两条 HTTP 集成测试均因这一问题失败：外部成员下载的实际 `403 not_a_member` 被转成 `403 request_failed`，伪造 WAV 上传的实际 `422 invalid_voice_audio` 被转成 `422 request_failed`。其它上传、语音发送、字节下载以及隐藏 / 撤回链路已在真实服务上走通。

修复后 `active_agent/im.py` 的 JSON 与二进制请求共用 `_http_error_code`。读取最多 4096 字节，同时兼容平铺与嵌套格式，仅保留 `[a-z_]{1,64}` 的有界机器标识，并关闭错误响应；任意远端错误文本不进入异常消息。不能据此声称已增加音频识别或合成能力。

## SDK 媒体边界

`upload_attachment` 使用当前身份、当前会话和稳定 `client_id` 上传 1 字节至 12 MiB 的数据，并核验服务端回包的房间、附件 ID、状态、字节数与 SHA。上传不等于发送消息，也不会录制设备。

`download_attachment` 根据当前会话与附件 ID 构造固定相对路径，不采用服务端提供的下载 URL。下载前核对元数据、当前身份和上限，禁止自动重定向；收到字节后检查长度与 SHA，再进行一次当前成员鉴权元数据读取，确认身份与文件标识没有变化。媒体字节不受普通 JSON 8 MB 回包上限限制，仍受独立附件边界保护。

`send_voice` 只提交已有附件坐标及稳定消息意图，音频格式与时长由服务端真实文件推导；支持纯文本附言、mentions 和 reply_to。标准模型 worker 自动生成音频不在此次 SDK 验证范围内。

## 真实 HTTP 与回归结果

新增 `tests/test_im_media_node.py`。测试将当前 Doc Free 顶层 JS、emoji 目录数据和 HTML 精确复制到临时目录，仅链接已安装的 `node_modules`；不复制本机 `.env`、认证文件或业务数据。子进程只获得测试所需的最小环境、随机临时凭据、随机本地端口和独立数据路径，明确排除 3218。结束后停止子进程并清理对应临时目录。

两个集成案例实际使用 Python SDK 经 HTTP 调用新的 `server.js`：

1. Human 上传真实 16 kHz 单声道 PCM16 WAV，核验服务端 100 ms 时长、MIME 和 SHA；稳定上传及稳定语音发送重试保持幂等；Agent 下载的字节与原始音频完全一致；外部成员被拒绝并保留真实 `not_a_member`。
2. Agent 上传并发送语音，Human 通过当前授权下载；本人隐藏后下载返回 `message_hidden`，恢复可见再由作者撤回后返回 `attachment_recalled`；伪造 WAV 上传返回 `invalid_voice_audio`。

测试默认发现兄弟目录 `doc_free`，也可通过 `DOC_FREE_TEST_ROOT` 指定源码；若测试环境没有 Node、Doc Free 源码或已安装依赖则明确 skip。本次本机运行两项实际执行，**没有 skip**。

```text
python3 -m unittest tests.test_im_media tests.test_im_media_node -v
13 tests, OK

python3 -m unittest discover -s tests -p 'test_im*.py'
38 tests, OK

git diff --check
通过
```

11 项 SDK HTTP 夹具测试还覆盖超过 JSON 限制的 9 MB 下载、错误 SHA、短流 / 长流、身份切换、重定向、客户端更小上限、删除与撤权后的再次鉴权、非法 ID 和不可信错误文本。它们与两个真实 Node 服务测试分别提供异常流控制和跨语言实际合同证据。

## 已捕获原生页面截图复核

另对主任务捕获的原生 iOS Simulator 与真实 iPhone Mirror 图片做只读归一比对，未操作 GUI。原生窗口为 336×732，display 裁剪 `[22,75,315,714)`；Mirror 为 318×701，按可见设备边界裁剪 `[8,38,310,694)`，排除窗口白边；均使用 LANCZOS 归一为 402×874。已实际查看所有原图、full 并排和 focused 并排。

产物位于 `output/renji-feishu-mobile-{group-editor,group-rules,groups-verified}-native-unlocked-live-{full,focused}-comparison.png`。这些是实际原生捕获的对照，不是 widget 渲染；水印、指针阴影、系统状态和不同聊天数据不算作产品 UI 差异，也不据此给出无掩码整图像素相似率。

编辑分组页的常用分组 chip、显示项目、红减号、齿轮及拖动手柄已齐；捕获时原生列表比参考约下移 4 px，累积至底部约 9 px。飞书底端显示“隐藏”标题，原生直接露出“标签顺序”，需主任务检查空隐藏区的显示。显示规则副标题值不同属于各自当前配置，不直接认定为缺陷。

消息展示设置页捕获时原生比参考多一行“完成后应用当前选项”，使四选项卡约下移 22 px；已交主任务修正。最新可信分组列表的抽屉宽、选中框和项目顺序接近，云文档、话题、已完成图标仍有轮廓差异。以上观察只对应这些具体截图；之后的 UI 修复应以新原生截图另行验收，不覆盖历史证据。
