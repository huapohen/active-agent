# 人机本机手动启动教程

2026-09-09 开户与受控接收桥更新：本机 Go 数据库已升级到 **schema 9**。已注册的 Clerk 账号可在 Electron / Web 进入“个人资料”“工作空间”“创建群聊”，新工作空间只有本人时也可以创建群聊。第 4.1 节补充实际操作，第 4.2 节补充独立接收桥的手动恢复步骤。本次教程依据工作区代码更新，新增实现的最终提交归属以本阶段主交付记录为准；下列已有提交保留为历史，不代表新增代码已经归入旧提交。

2026-09-09 消息交互阶段历史记录：当时实施提交为 `50570cac03b1314c831fc856e6ed826f60486fa8`（`2026-09-09T07:55:18+08:00`，`feat(startup): deliver native replies reactions and authenticated emoji`）。当时本机已应用迁移 `00006_message_interactions.sql`，schema 为 6。第 3 节增加真实表情目录配置；商业注册已改为同源 Clerk 页面，用户已亲自完成 Cloudflare 和邮箱验证，随后 Electron 商业登录及持久 Human 身份已验证；当时新账号无工作空间或会话，客户端建群与昵称编辑尚待接通；这一限制已由本页新增的开户操作取代。以下旧时点记录保留为历史。

2026-09-09 06:39 历史记录：当时实施提交为 `2fc663150ec66fa2c402e1a38668264f0d961e5a`（06:37:12+08:00，`feat(startup): automate execution archives and add native message actions`）。下列普通服务、电脑与模拟器启动步骤仍适用；本轮没有新增数据库迁移。Worker 增加 `RENJI_RUN_ARCHIVE_CONFIG` 私有部署配置，终态自动归档的启动条件、结果查询与有限重试见 [0621 专题](AUTOMATIC_TERMINAL_ARCHIVE_0621.md)。当前验收使用专用归档队列并已停止该 Worker；它不是打开电脑界面的前提。不要直接重跑验收工作流 start、旧 publisher 或 provisioning 来启动界面。

记录时间：2026-09-09 04:25（Asia/Shanghai）。适用于本机 `startup` 分支，客户端实现提交 `71b80f8181fa243b7477ebac0c35c6ce13e2c960`（04:11:17），内核提交 `a9005c01ee059b3f093d877ae1eb13828075d692`（04:15:30）。依据当前根 `package.json`、`services/collaboration/README.md`、`apps/desktop/README.md` 和旧 Flutter 启动脚本编写。

## 先分清现在的两套客户端

| 要打开的内容 | 客户端 | 需要的服务 | 登录方式 |
| --- | --- | --- | --- |
| 新电脑端，查看已有账号和聊天数据 | Electron + React | 旧 IM 3218、Vite 5173 | 明确选择“现有数据迁移”入口，使用已有本地账号 |
| 浏览器查看同一个新界面 | React Web | 旧 IM 3218、Vite 5173 | 同上 |
| 新工作空间、昵称与群聊 | React / Electron 的 Clerk 入口 | PostgreSQL、Go API 3318、Vite 5173 | 已注册的 Clerk 账号；按第 4.1 节设置昵称、选择或创建工作空间与群聊 |
| iPhone 模拟器的人机 | `apps/office` Flutter | 旧 IM 3218 与文档协作 1238 | 已有本地账号 |

手机目前仍是旧 Flutter 栈；手机登录成功不代表已经迁入 Go、Clerk、融云的新栈。新版 Mac 桌面以 Electron 为主；旧 Flutter Mac 客户端仍可单独启动用于对照。

## 1. 先检查，避免重复启动

打开终端进入项目：

```sh
cd /Users/lwblx/huapohen/agent/execute/enterprise_work/active_agent
git branch --show-current
lsof -nP -iTCP:3218 -iTCP:1238 -iTCP:3318 -iTCP:5173 -sTCP:LISTEN
```

当前阶段使用 `startup`。若相应端口已由本项目服务监听，就复用正在运行的服务，不再启动第二份。没有输出表示这些端口没有监听进程；不要因某端口占用就随意杀掉进程。

| 端口 | 用途 |
| --- | --- |
| 3218 | 原 Doc Free / IM HTTP 服务，当前已有账号和数据在这里 |
| 1238 | 原文档实时协作服务 |
| 3318 | 新 Go 协作 API |
| 5173 | 新 React 页面与开发代理 |
| 55434 | 本机新栈 PostgreSQL 容器 |

本机依赖已经安装，不需要每次重新安装。根项目要求 Node.js 24.15.0 或以上。只有依赖缺失或锁文件变化时再依据相应 README 安装：根 npm workspace 使用锁文件；Flutter 使用 `flutter pub get --enforce-lockfile`。下载前按本机 `AGENTS.md` 检查线路，不要清空缓存或重装整个 SDK 来解决普通启动错误。

## 2. 启动已有数据服务

如果 3218 和 1238 尚未运行，在一个独立终端执行：

```sh
cd /Users/lwblx/huapohen/agent/execute/enterprise_work/active_agent
python3 scripts/dev_office.py --doc-free ../doc_free --no-worker
```

保持这个终端打开。脚本会检查 Doc Free 路径、依赖和端口，构建所需服务并保留 `data/office` 中的账号与业务数据。`--no-worker` 适合 UI 预览，不启动主动模型工作进程。启动手机和原生 Mac 预览不需要先执行 `flutter build web`。

可以在另一个终端检查服务：

```sh
curl --noproxy '*' --fail --silent --show-error http://127.0.0.1:3218/health
```

已有账号配置在 Git 忽略的 `data/office/access.json`。请在本机安全查看，需要时只在登录界面输入；不要把整个文件贴进聊天、日志或文档。本教程不复制账号密码。

## 3. 启动新 Go 服务（需要验证新商业栈时）

仅查看旧数据迁移页面或手机旧客户端时，可以跳过本节。需要新 Go API 时，先确认 Docker 已打开，检查已有数据库容器：

```sh
docker ps -a --filter 'name=^/renji-startup-postgres$' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

如果已有容器显示停止，启动它：

```sh
docker start renji-startup-postgres
```

如果列表中不存在该容器，先按服务部署说明配置数据库，不要随意创建同名空库代替现有数据。当前本机数据库已经迁移，正常启动无需再次初始化。

在新的独立终端加载已有私有配置，再启动 Go：

```sh
cd /Users/lwblx/huapohen/agent/execute/enterprise_work/active_agent
set -a
source data/startup/api.env
source data/startup/clerk.env
source data/startup/rongcloud.env
source data/startup/clerk-machine.env
set +a
export RENJI_EMOJI_DIR="$PWD/apps/office/assets/emoji"
export RENJI_RONGCLOUD_BRIDGE_CONFIG="$PWD/data/startup/rongcloud-receive-20260909-0905/bindings.json"
cd services/collaboration
go run ./cmd/api
```

这些文件仅在本机保存。不要开启 shell 的 `set -x`，不要打印环境变量，也不要将其中值复制到前端。融云是新服务的必需配置。`clerk-worker.env` 是短期机器测试凭证，不是打开桌面所需配置。

`RENJI_RONGCLOUD_BRIDGE_CONFIG` 指向本机已经存在的私有 `bindings.json`，由 Go API 读取接收桥的身份与范围绑定；它与桥进程使用的 `bridge.json` 是两个不同文件。该 JSON 包含机密，文件权限应为 `0600`，目录为 `0700`，不能是符号链接，不能复制内容到前端、日志或教程。API 对不合法的文件、权限或内容会拒绝启动。修改绑定后需重启 API。此处使用的是本机既有受控配置；其他部署没有该文件时，应先由部署人员配置，不能复制验收身份、重新运行 probe 来补文件。不启用受控桥的部署可不设置此变量，普通 API 仍可运行，但不会因此获得桥接收能力。

**加载绑定不等于启动 SDK 接收桥。** `go run ./cmd/api` 只启动 API，不启动模型 Worker 或 Outbox 派发；桥的独立恢复步骤见第 4.2 节。打开桌面和设置昵称不需要启动任何派发进程。

`RENJI_EMOJI_DIR` 必须是包含目录、manifest 和经典 PNG 的绝对路径；上面的命令在项目根目录解析它。服务启动时核验资源并持有快照，修改该目录后需要重启服务。未配置时表情目录和添加/取消回应能力不会开放，配置后资源损坏则启动失败；不要用迁移服务的表情地址替代商业鉴权路径。

```sh
curl --noproxy '*' --fail --silent --show-error http://127.0.0.1:3318/healthz
```

首次部署或升级到带有新数据库迁移的版本时，按服务 README 使用 `--migrate`，只应用未执行的迁移。本机目前已应用至 `00009_transport_heartbeat_sequence.sql`，schema 为 9，其中 `00007_profile_version.sql` 增加资料版本，00008 增加传输接收记录，00009 为心跳增加递增序号以拒绝迟到状态。普通重启不要加 `--migrate`，无需重复初始化。正常开机不要执行 probe、fixture provision、publisher、文档实例 setup、模型 Worker 或 `transport-worker`；尤其不要以派发历史 Outbox 的方式检查界面是否启动。

## 4. 启动新版 Mac 电脑端与 Web

先在一个终端启动 React 开发服务：

```sh
cd /Users/lwblx/huapohen/agent/execute/enterprise_work/active_agent
npm run dev:web
```

看到 Vite 就绪后，在浏览器打开 `http://127.0.0.1:5173`。Vite 固定使用 5173 并启用严格端口检查，占用时会报错，不会偷偷换端口。

再开一个终端启动 Electron：

```sh
cd /Users/lwblx/huapohen/agent/execute/enterprise_work/active_agent
npm run dev:desktop
```

这个命令会先调用 `apps/desktop/scripts/build-preload.cjs` 构建桌面桥接与隔离的融云 worker，然后启动新电脑端，**无需另跑 `prepare:preload`**。保留 Vite 与 Electron 两个终端。新桌面当前是开发版本，不是已签名、公证的正式安装包。

查看原有聊天记录时，选择“现有数据迁移”入口，使用原本地账号。该入口经固定开发代理访问 3218，不会绕过 Clerk 商业登录。前端本机配置位于 Git 忽略且已经存在的 `apps/web/.env.local`；`npm run dev:web` 在 Web workspace 内启动 Vite，自动读取该文件，**不需要手动 `source`**。修改 Vite 环境变量或代理配置后，需要停止并重启 Vite。

React 页面代码通常通过 Vite 自动热更新；修改 Electron 主进程、preload 或 worker 启动代码时，退出并重新执行 `npm run dev:desktop`。无需因为普通页面修改就重启后端。构建生产 Web 的命令为 `npm run build:web`，日常热更新不必每次执行。

## 4.1 已注册账号登录后，设置昵称、工作空间和单人群

先完成第 3、4 节，使用同一个 `http://127.0.0.1:5173` 页面或新 Electron 桌面。在登录页选择“商业工作空间”，使用**已注册的 Clerk 账号**登录，不选择“现有数据迁移”。若 Clerk 会话仍有效，页面会直接进入工作空间。需要邮箱验证码或真人验证时，在当前登录页面正常完成；本地迁移账号的密码与 Clerk 账号不是同一套认证。

没有会话的新账号会看到开户页面，可以依次完成以下操作：

1. **个人资料：**填写“昵称”，点击“保存昵称”，等待“昵称已更新为…”后再继续。昵称去除首尾空白后为 1–80 个 Unicode 字符，不能含控制字符或换行。这里修改的是人机工作身份的显示名称，不会修改 Clerk 的邮箱、登录密码或账号用户名。
2. **工作空间：**如果已经加入团队，直接选择列表中的真实工作空间。如果列表为空，在“工作空间名称”中输入公司或团队名称，点击“创建工作空间”，等待它出现在列表。新建者为所有者；系统不会为了填满页面而自动创建公司成员或 Agent。
3. **创建群聊：**确认当前工作空间，输入“群聊名称”。成员列表由服务端读取，你本人已经包含在内。新工作空间只有你时，直接点击“创建群聊”即可，**无需再注册第二个账号**。其他人或 Agent 只有实际加入此工作空间后才可选择；看到“当前身份不在此工作空间的成员列表中”时先重新读取，不能手填成员 ID 绕过检查。
4. **进入群聊：**等待“已创建群聊…”后点击“进入群聊”。此时会话才是已确认创建的真实记录，后续可从消息列表打开。普通手动聊天经 Go 保存；是否已送达融云接收端，要另看对应会话的实际接收能力，不能仅凭创建成功判断跨端收包已完成。

工作空间名和群名均限制为 240 个 UTF-8 字节，中文通常占多个字节；输入过长时缩短名称再提交。页面中的人和 Agent 都来自真实成员列表，不会添加虚构同事。

已有会话后，点击左上角头像 →“个人资料”可修改昵称，头像 →“工作空间”可管理当前空间；头像旁或消息标题旁的“+”→“创建群聊”可打开建群表单。已有多个工作空间时，先在表单中选中正确的空间，再选择其中的真实同事。当前暂未接通的能力会保持不可用，不表示已经执行成功。

如果出现“操作结果待确认”，点击**“核对原操作”**。页面会用原操作编号对账并重新读取结果；不要反复换名称、切工作空间或清空浏览器存储来重试创建。资料版本冲突时，按页面提示重新读取当前资料后再修改。身份切换或成员权限变化后，旧资料与成员不可继续展示，原操作未确认前也不能把它改成另一个空间的新建任务。

## 4.2 单独恢复受控的融云 Web SDK 接收桥

这一桥接步骤用于本机指定的验收接收身份、原验收群和允许的消息集合。当前官方 **Web SDK** 桥已建立真实连接，收包验证应以本阶段交付证据为准；它**没有自动覆盖新注册账号或新建群**，也没有开放普通账号的直接 SDK 写入能力。当前融云应用的原生桌面 SDK 返回 `31003`，对应应用能力未开通；不要通过更换人机账号密码、关闭 Electron 安全策略或改为原生模式来解决。Machine 接收链路和 Flutter 商业接收尚未完成。相关权限范围见 [资料、工作空间与传输专题](PROFILE_WORKSPACE_CORE_0910.md)。

先检查是否已经存在桥进程，存在时复用，不要重复启动：

```sh
pgrep -fl 'services/rongcloud-bridge/main[.]cjs'
```

本阶段桥已经单独运行；只有它停止、需要恢复且第 3 节 API 已加载同一目录的 `bindings.json` 时，才在独立终端执行以下命令。`bridge.json` 与既有队列状态必须保留，不能重新运行 `transport-receive-probe`、prepare 或 dispatch 生成另一套资源：

```sh
cd /Users/lwblx/huapohen/agent/execute/enterprise_work/active_agent
node services/rongcloud-bridge/build.cjs
renji_bridge_dir="$PWD/data/startup/rongcloud-receive-20260909-0905"
umask 077
touch "$renji_bridge_dir/manual-receive.log"
chmod 600 "$renji_bridge_dir/manual-receive.log"
env -i HOME="$HOME" PATH="$PATH" TMPDIR="$TMPDIR" LANG="${LANG:-en_US.UTF-8}" \
  "$PWD/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron" \
  "$PWD/services/rongcloud-bridge/main.cjs" "$renji_bridge_dir/bridge.json" \
  >> "$renji_bridge_dir/manual-receive.log" 2>&1
```

上述构建使用本机已安装依赖，不下载或签发凭据。启动参数只有配置路径；不要 `cat`、截图或粘贴配置中的 token、桥密钥。桥在后台隐藏窗口中运行，保留这个终端，停止时按 `Ctrl-C`。它重新连接既有 Web SDK 身份，并从持久化的真实 SDK 接收记录恢复、幂等提交 Go 的接收记录；**不会调用融云发送接口，也不会派发历史 Outbox**。这与消息发送方的 `transport-worker` 是不同进程。

若遇到 `bridge_configuration_unavailable` 或 `bridge_queue_requires_review`，停止恢复尝试，检查原配置、权限、接收身份和队列范围。不要删除队列、覆盖身份或换一组 token 强行启动。已有队列绑定了原接收范围，重新登录桌面不会使它变成当前用户的接收队列。

## 5. 启动 iPhone 模拟器并保持 Flutter 热更新

先完成第 2 节。打开已经安装的 Simulator：

```sh
open -a Simulator
```

只保留一个主 iPhone 模拟器；在 Simulator 的设备菜单选择已有设备，不要同时新开多个模拟器。本阶段使用过 iPhone 17，但设备 ID 必须以本机当次列表为准。手机镜像是实际 iPhone 的参考画面，与模拟器是两个不同窗口；启动模拟器中的人机不依赖镜像连接。

在新终端查看可用设备：

```sh
cd /Users/lwblx/huapohen/agent/execute/enterprise_work/active_agent/apps/office
/Users/lwblx/development/flutter/bin/flutter devices
```

找到标记为 iOS **模拟器**的那一项，复制实际设备 ID，然后替换下面占位符：

```sh
/Users/lwblx/development/flutter/bin/flutter run -d '<实际 iPhone 模拟器 ID>' --no-pub
```

不要原样使用尖括号占位符，也不要误选同名的实际 iPhone。等待应用启动后，在模拟器里用已有本地账号登录。iOS 模拟器默认通过 `http://127.0.0.1:3218` 访问 Mac 上的旧服务。实际手机中的 `127.0.0.1` 指向手机自身，不能照搬；真机需要另行配置可访问的服务地址和网络。

保持 `flutter run` 终端打开，将焦点放到该终端时可输入：

| 按键 | 用途 |
| --- | --- |
| `r` | 热重载 Dart 页面，通常保留当前页面与状态 |
| `R` | 热重启 Dart 应用，状态会重新初始化，可能需要重新登录 |
| `q` | 停止当前调试运行 |

修改原生插件、系统权限或 iOS/macOS 原生配置时，需要退出后重新运行，单按 `r` 不够。如果界面没有跟随源码变化，先确认终端仍然连着正确设备，而不是再启动一份应用。

需要旧 Flutter Mac 客户端作对照时，可在 `apps/office` 执行：

```sh
/Users/lwblx/development/flutter/bin/flutter run -d macos --no-pub
```

它与第 4 节的 Electron 新桌面不同。电脑资源紧张时只运行当前需要的一套桌面客户端和一个手机模拟器。Android 日常默认设备为 `Pixel_10_Pro_XL_API_36`，仍应先查实际 AVD 与 `flutter devices`，不要写死 ADB 序列号，也不要与多个 iPhone 模拟器同时堆叠运行。

## 6. 停止、恢复与常见故障

- **正常停止：**Flutter 终端按 `q`，Electron、Vite、独立接收桥、Go 和旧服务分别在所属终端按 `Ctrl-C`。先停客户端和桥，再停服务。当前未安装开机自启，关闭开发终端后需按上述顺序重启。
- **端口已占用：**先用第 1 节的 `lsof` 找到服务，检查现有终端。健康且属于本项目就复用；需要重启时停止原终端，不要 `killall node` 或批量结束无关进程。
- **登录显示网络错误：**先检查 3218，再检查 5173 和迁移入口；新商业模式则检查 3318 与 Clerk 配置。修改密码不能解决后端未启动的问题，也不要将两套登录模式混用。
- **应用打开但页面白屏：**检查 Vite 终端是否就绪，以及 `http://127.0.0.1:5173` 能否打开；Electron 开发壳需要它持续运行。
- **模拟器未列出：**先打开并等待已有模拟器完成启动，再运行 `flutter devices`；不必重装 Flutter 或创建多台设备。
- **修改配置未生效：**重启读取该配置的对应服务。Vite 的 `.env.local`、Go 的 `data/startup/*.env` 与旧服务配置各自独立，不能只热重载页面。
- **需要释放资源：**正常退出不用的模拟器和开发客户端。保留 `data/office`、`data/startup`、数据库容器及数据卷；不要通过删除业务数据、凭据或 `docker ... -v` 来恢复启动。

本次运行日志可参考 `/tmp/renji-startup-web-20260909.log` 和 `/tmp/renji-startup-desktop-20260909.log`。手动执行上述命令时，日志默认出现在所属终端；新手动运行不会自动沿用这些历史日志文件。

当前商业新链路的登录与开户操作范围是 Electron / Web，Flutter 手机仍使用第 2、5 节的迁移服务。受控 Web SDK 桥的连接与接收证据不代表普通新账号、所有群、原生桌面 SDK 或所有移动端已打通。完整断线恢复、Machine 接收、手机新栈迁移、完整飞书页面以及生产签名发布仍不能视为完成。

2026-09-09 05:59 补记：新文档正文阅读器及执行档案代码在 `a639a8843093bed98b04b375d361de6e2c2129c9`（Git 时间 05:56:24+08:00）提交，启动电脑端的顺序不变。当前本机另有 Temporal 持久开发服务，但打开界面无需启动模型 worker。短期机器 token 有期限；不要把归档/模型凭证复制到登录框，也不要因它过期重置人类账号密码。
