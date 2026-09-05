# 运行教程与文档协议

> 文档序列：`evolve / 2026-09-06 / v0.2`
>
> 编写时间：`2026-09-06T02:50:08+08:00`（Asia/Shanghai）
>
> Active Agent 实现：[`c05f904`](https://github.com/huapohen/active-agent/commit/c05f904f0ec11d680d5527e37519e1836ccba0af) · `2026-09-06T02:41:10+08:00` · feat: evolve proactive agents around visible collaborative documents
>
> Doc Free 实现：[`f5c3b6f`](https://github.com/huapohen/doc-free/commit/f5c3b6f0cdbf03b74895d6e3884154578b8ceb3f) · `2026-09-06T02:41:11+08:00` · feat: add document-native workspace for proactive agent collaboration
>
> Doc Free 源码排版：`b182142` · `2026-09-06T02:42:03+08:00`
>
> 旧版资料保留，新版结论以本序列的实现、验证和限制为准。

## 1. 本地快速启动

```bash
git clone --branch evolve https://github.com/huapohen/active-agent.git
git clone --branch evolve https://github.com/huapohen/doc-free.git
cd doc-free
npm ci
cd ../active-agent
python -m pip install -e .
cp .env.example .env
active-agent configure-model-key
python scripts/dev_workspace.py --doc-free ../doc-free
```

已有 `.env` 时不要覆盖。配置模型端点、模型名称、API 风格以及默认 `medium`。临时配置只用于本地调试；生产应通过运行环境或秘密管理服务注入配置，不复制本机 `.env`。

本机原始目录名是 `doc_free`，启动时使用 `--doc-free ../doc_free`。脚本默认端口为 3217 / 1237；可通过 `--port`、`--collab-port` 调整。

访问 `http://127.0.0.1:3217/workbench`，输入名字和本机 `.env` 中的 `AA_DOC_FREE_TOKEN`。第一次运行没有工作空间令牌时，启动器会生成并保存在该忽略文件中。启动日志不输出令牌。

脚本使用 `active-agent/data/workspace/` 保存演示空间，不改写 Doc Free 旧的 `data.json` 和 `yjs-data/`。Ctrl-C 结束该组合进程。若服务无法启动，先核对 Node 依赖、端口占用和 Doc Free 分支。

## 2. 第一次协作

点击“体验一次协作”，得到一份上线方案和一份持续任务。无需再点击运行：后台会在正文安静后调用模型。

打开提案，检查原文依据和前后文本。接受时，正文更新并记录 actor 与结果版本；拒绝时，正文不变。若你在模型运行期间编辑来源，旧结果会被丢弃或在审阅时标记冲突。

任务卡支持暂停和继续；任务文档的“查看原文”允许直接修改目标或安静窗口。原文保存使用进入编辑时的版本；如果别的客户端更新了任务，保存失败会保留你的草稿供手动协调。

## 3. 连接已有 Doc Free

分别运行 Doc Free：

```bash
npm run build
npm run start:collab
npm start
```

在 Active Agent 的忽略配置中设置 `AA_DOC_FREE_URL` 与 `AA_DOC_FREE_TOKEN`，然后执行：

```bash
active-agent documents
```

`active-agent documents-tick` 只执行一次观察/评估，用于诊断；自动协作应运行持续 worker。修改 `.env` 后重启进程。

Doc Free 支持 `DOC_FREE_DATA`、`DOC_FREE_CRDT_DIR`、`DOC_FREE_TOKEN`、`COLLAB_URL`、`COLLAB_PORT`。服务默认绑定 loopback；只有计划好访问边界后才配置其他监听地址。

## 4. 文档格式

任务是一份普通文档，例如：

````markdown
# 任务 · 上线方案

```active-agent
{
  "protocol": "active-doc/v1",
  "kind": "mission",
  "objective": "检查验收条件是否可以实际验证",
  "source_document_id": "source-id",
  "status": "active",
  "quiet_seconds": 8
}
```

## 工作约定
Agent 根据当前来源提出建议，人工审阅后写入。
````

契约中的 `status` 支持 `active / paused / completed`。`source_document_id` 必须指向普通来源正文，不能把任务或提案作为新的监控来源，避免自激循环。

## 5. REST 接口

前缀 `/api/workspace`，使用 `Authorization: Bearer <workspace-token>`。actor 放在 `X-Actor-Id`；包含中文时使用 URI 编码，服务端解码后保存标签。

| 方法与路径 | 输入与作用 |
|---|---|
| `GET /api/workspace` | 返回全部可见文档和游标 |
| `POST /documents` | `title, content`；创建来源 |
| `GET /documents/{id}` | 读取最新 CRDT 投影与 revision |
| `PUT /documents/{id}` | `base_revision, content, title?`；版本检查后更新 |
| `POST /missions` | `source_document_id, objective, quiet_seconds?` |
| `PATCH /missions/{id}` | `base_revision, status` |
| `POST /runs` | 发布模型结果，引用任务/来源基线 |
| `POST /proposals/{id}` | `base_revision, decision: accept/reject` |
| `GET /events?after=N` | 获取游标之后最多 200 条文档事件 |
| `GET /worker` | 最近心跳，用于显示后台状态 |
| `POST /worker` | 更新心跳；是运行状态，不是任务语义 |

除第一行外，表中路径都拼接前缀 `/api/workspace`。

发布结果的核心请求：

```json
{
  "mission_id": "mission-id",
  "mission_revision": 1,
  "source_revision": 3,
  "source_hash": "sha256-of-the-source-content",
  "action": "propose",
  "rationale": "验收条件缺少明确可验证的观察结果。",
  "evidence_quotes": ["系统应该足够快。"],
  "replacement": "完整的新正文……",
  "model": "your-model",
  "reasoning_effort": "medium"
}
```

提案必须有来源中真实存在的逐字引用。模型不得编造 evidence，API 也不会仅凭“模型说有依据”就接受。

事件响应包含 `events, cursor, high_watermark, reset_required`。消费后推进到本批返回的 cursor，不跳到 high_watermark，否则可能跳过分页。当游标高于恢复后的服务序列时，`reset_required=true`，应重新读取工作空间快照。

## 6. MCP 接入

`POST /mcp`，与原有 Doc Free MCP 共用鉴权。先 `initialize`，再 `tools/list`。新增工具：

| 工具 | 作用 |
|---|---|
| `active_doc_workspace` | 所有可见文档 |
| `active_doc_read` | 读取一个最新文档 |
| `active_doc_create` | 创建普通正文 |
| `active_doc_write` | 带 base_revision 写正文或任务 |
| `active_doc_assign` | 创建可见持续目标 |
| `active_doc_status` | 暂停、继续、完成 |
| `active_doc_review` | 明确接受或拒绝提案 |

这些工具共用 Workspace API 业务逻辑，不触发旧版的 AFFiNE/Docmost 自动同步。内置 worker 通过 REST 发布提案；外部 Agent 也能通过相同文档协议参与。

## 7. 诊断

- `401`：核对工作空间令牌，避免误用模型 Key。
- `409 conflict / stale_run`：重新读取文档；不应该通过去掉版本字段强行覆盖。
- `422 invalid_evidence`：模型引用与正文不匹配，等待重试或修改任务范围。
- `503`：检查 Doc Free / Hocuspocus 是否同时运行，`COLLAB_URL` 是否匹配。
- 模型 HTTP 500 且通道不支持 Chat：使用 `AA_MODEL_API_STYLE=responses`，保持 Key、端点与模型匹配。
- 持续失败：本轮最多自动尝试三次，随后形成 blocked 文档；修正配置并更新任务约定，或暂停后继续。

本机日志只记录错误类型、HTTP 状态和协议错误码；不记录供应商响应正文、模型 Key 或认证请求头。
