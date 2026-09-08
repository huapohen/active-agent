# 人机本机手动启动教程

2026-09-09 06:39 更新：当前实施提交为 `2fc663150ec66fa2c402e1a38668264f0d961e5a`（06:37:12+08:00，`feat(startup): automate execution archives and add native message actions`）。下列普通服务、电脑与模拟器启动步骤仍适用；本轮没有新增数据库迁移。Worker 增加 `RENJI_RUN_ARCHIVE_CONFIG` 私有部署配置，终态自动归档的启动条件、结果查询与有限重试见 [0621 专题](AUTOMATIC_TERMINAL_ARCHIVE_0621.md)。当前验收使用专用归档队列并已停止该 Worker；它不是打开电脑界面的前提。不要直接重跑验收工作流 start、旧 publisher 或 provisioning 来启动界面。

记录时间：2026-09-09 04:25（Asia/Shanghai）。适用于本机 `startup` 分支，客户端实现提交 `71b80f8181fa243b7477ebac0c35c6ce13e2c960`（04:11:17），内核提交 `a9005c01ee059b3f093d877ae1eb13828075d692`（04:15:30）。依据当前根 `package.json`、`services/collaboration/README.md`、`apps/desktop/README.md` 和旧 Flutter 启动脚本编写。

## 先分清现在的两套客户端

| 要打开的内容 | 客户端 | 需要的服务 | 登录方式 |
| --- | --- | --- | --- |
| 新电脑端，查看已有账号和聊天数据 | Electron + React | 旧 IM 3218、Vite 5173 | 明确选择“现有数据迁移”入口，使用已有本地账号 |
| 浏览器查看同一个新界面 | React Web | 旧 IM 3218、Vite 5173 | 同上 |
| 新商业工作空间的开发验证 | React / Electron 的 Clerk 入口 | PostgreSQL、Go API 3318、Vite 5173 | Clerk；真人商业登录闭环尚未验收 |
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
cd services/collaboration
go run ./cmd/api
```

这些文件仅在本机保存。不要开启 shell 的 `set -x`，不要打印环境变量，也不要将其中值复制到前端。融云是新服务的必需配置。`clerk-worker.env` 是短期机器测试凭证，不是打开桌面所需配置。

```sh
curl --noproxy '*' --fail --silent --show-error http://127.0.0.1:3318/healthz
```

首次部署或升级到带有新数据库迁移的版本时，按服务 README 使用 `--migrate`，只应用未执行的迁移。本阶段新增的 00004、00005 已在本机应用，普通重启无需重复初始化。正常开机不要重新执行 probe、fixture provision、文档实例 setup 或 transport worker；这些不是启动界面的必要步骤。

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

- **正常停止：**Flutter 终端按 `q`，Electron、Vite、Go 和旧服务分别在所属终端按 `Ctrl-C`。先停客户端，再停服务。当前未安装开机自启，关闭开发终端后需按上述顺序重启。
- **端口已占用：**先用第 1 节的 `lsof` 找到服务，检查现有终端。健康且属于本项目就复用；需要重启时停止原终端，不要 `killall node` 或批量结束无关进程。
- **登录显示网络错误：**先检查 3218，再检查 5173 和迁移入口；新商业模式则检查 3318 与 Clerk 配置。修改密码不能解决后端未启动的问题，也不要将两套登录模式混用。
- **应用打开但页面白屏：**检查 Vite 终端是否就绪，以及 `http://127.0.0.1:5173` 能否打开；Electron 开发壳需要它持续运行。
- **模拟器未列出：**先打开并等待已有模拟器完成启动，再运行 `flutter devices`；不必重装 Flutter 或创建多台设备。
- **修改配置未生效：**重启读取该配置的对应服务。Vite 的 `.env.local`、Go 的 `data/startup/*.env` 与旧服务配置各自独立，不能只热重载页面。
- **需要释放资源：**正常退出不用的模拟器和开发客户端。保留 `data/office`、`data/startup`、数据库容器及数据卷；不要通过删除业务数据、凭据或 `docker ... -v` 来恢复启动。

本次运行日志可参考 `/tmp/renji-startup-web-20260909.log` 和 `/tmp/renji-startup-desktop-20260909.log`。手动执行上述命令时，日志默认出现在所属终端；新手动运行不会自动沿用这些历史日志文件。

本阶段尚未完成 Clerk 真人跨端登录、融云客户端真实收包和断线恢复、手机新栈迁移、完整飞书页面以及生产签名发布。当前能够启动和预览，不等于这些项目已经验收。

2026-09-09 05:59 补记：新文档正文阅读器及执行档案代码在 `a639a8843093bed98b04b375d361de6e2c2129c9`（Git 时间 05:56:24+08:00）提交，启动电脑端的顺序不变。当前本机另有 Temporal 持久开发服务，但打开界面无需启动模型 worker。短期机器 token 有期限；不要把归档/模型凭证复制到登录框，也不要因它过期重置人类账号密码。
