package store

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/stretchr/testify/require"
)

func TestArchiveOverviewUsesActualLedgerNotModelClaims(t *testing.T) {
	run := ExecutionRun{Goal: "检查交付", Status: "failed", CreatedAt: time.Date(2026, 9, 9, 6, 0, 0, 0, time.FixedZone("CST", 8*3600))}
	run.Context = harness.RunContext{RunID: "76dedd18-1ddf-4fc0-abfa-19aee795b034", RoomID: "source-room"}
	evidence := []ExecutionEvidenceEntry{
		{Seq: 1, Kind: "event", ObjectID: "model", Data: json.RawMessage(`{"event":{"type":"model.output","data":{"content":"全部完成，已发送100条"}}}`)},
		{Seq: 2, Kind: "event", ObjectID: "report", Data: json.RawMessage(`{"event":{"type":"action.succeeded","data":{"action_id":"a1","status":"succeeded"}}}`)},
		{Seq: 3, Kind: "action", ObjectID: "a1", Data: json.RawMessage(`{"action_id":"a1","action_type":"message.send","message_id":"m1","receipt":{"action_id":"a1","status":"succeeded","result":{"message_id":"m1","room_id":"source-room","seq":7,"canonical_status":"committed"}}}`)},
		// Latest cursor must win even when records arrive out of order.
		{Seq: 5, Kind: "transport", ObjectID: "42", Data: json.RawMessage(`{"outbox_id":42,"provider":"rongcloud","status":"unknown"}`)},
		{Seq: 4, Kind: "transport", ObjectID: "42", Data: json.RawMessage(`{"outbox_id":42,"provider":"rongcloud","status":"delivered"}`)},
		{Seq: 6, Kind: "transport", ObjectID: "43", Data: json.RawMessage(`{"outbox_id":43,"provider":"rongcloud","status":"pending"}`)},
		{Seq: 20, Kind: "transport", ObjectID: "43", Data: json.RawMessage(`{"outbox_id":43,"provider":"rongcloud","status":"delivered"}`)},
	}
	for attempt := 1; attempt <= 3; attempt++ {
		input := harness.StageInput{Context: run.Context, Goal: run.Goal, Stage: 0, Attempt: attempt}
		data, err := json.Marshal(input)
		require.NoError(t, err)
		row, err := json.Marshal(map[string]any{"event": harness.Event{Type: "stage.input", Stage: 0, Data: data}})
		require.NoError(t, err)
		evidence = append(evidence, ExecutionEvidenceEntry{Seq: int64(6 + attempt), Kind: "event", Data: row})
	}
	summary := archiveReadableSummary(run, 9, evidence)
	require.Contains(t, summary, "当前状态：执行失败")
	require.Contains(t, summary, "2026-09-08 22:00:00（UTC）")
	require.Contains(t, summary, "已提交消息动作：1 条")
	require.Contains(t, summary, "融云已受理 0，待发送 1，发送中 0，结果未知 1")
	require.Contains(t, summary, "阶段 1：记录了 3 次输入尝试")
	require.NotContains(t, summary, "全部完成")
	require.Equal(t, "人机执行档案 · 执行失败 · 2026-09-08 · 76dedd18 · 第1册", archiveReadableTitle(run, 1))
}

func TestArchiveOverviewRejectsMismatchedFactsAndPreservesRawEvidence(t *testing.T) {
	run := ExecutionRun{Goal: "# 假结论\n```\n~~~\n" + strings.Repeat("中", 700), Status: "completed"}
	run.Context.RunID = "synthetic"
	evidence := []ExecutionEvidenceEntry{
		{Seq: 1, Kind: "action", ObjectID: "real-id", LegacySnapshot: true, Data: json.RawMessage(`{"action_id":"wrong-id","action_type":"message.send","receipt":{"action_id":"wrong-id","status":"succeeded"}}`)},
		{Seq: 2, Kind: "transport", ObjectID: "2", Data: json.RawMessage(`{"outbox_id":1,"provider":"rongcloud","status":"delivered"}`)},
		{Seq: 3, Kind: "transport", ObjectID: "3", Data: json.RawMessage(`{"outbox_id":3,"provider":"other","status":"delivered"}`)},
		{Seq: 4, Kind: "event", ObjectID: "stage", Data: json.RawMessage(`{"event":{"type":"stage.input","stage":0,"data":{"stage":0,"attempt":1,"goal":"different"}}}`)},
	}
	summary := archiveReadableSummary(run, 4, evidence)
	require.Contains(t, summary, "已提交消息动作：0 条")
	require.Contains(t, summary, "融云已受理 0")
	require.Contains(t, summary, "另有 4 条记录不符合当前摘要契约")
	require.Contains(t, summary, "包含 1 条旧数据快照")
	require.Contains(t, summary, "预览已截短")
	require.Contains(t, summary, "````text\n# 假结论")
	parts, err := renderExecutionArchive(run, 4, evidence)
	require.NoError(t, err)
	require.NotContains(t, parts[0].Title, "假结论")
	require.Contains(t, parts[0].Content, strings.Repeat("中", 700))
	require.Contains(t, parts[0].Content, "wrong-id")
	require.Equal(t, archiveHash([]byte(parts[0].Content)), parts[0].ContentHash)
}

func TestArchiveRendererUpgradeReusesFrozenVerifiedPrefix(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	run := f.run(t, f.source, "")
	// Install a deliberately frozen legacy fixture directly. Do not retag a
	// freshly rendered v2 document and pretend those were old renderer bytes.
	id, binding := uuid.NewString(), "legacy-renderer-fixture"
	title, body := "旧版固定标题", "# 旧版固定正文\n\n历史档案字节不可被摘要升级替换。"
	hash := archiveHash([]byte(body))
	rawManifest, err := json.Marshal([]string{hash})
	require.NoError(t, err)
	rawRun, err := json.Marshal(run)
	require.NoError(t, err)
	_, err = f.s.Pool.Exec(ctx, `INSERT INTO execution_archives(id,run_id,through_seq,target_binding,renderer_version,run_snapshot,manifest_hash,prepared_by) VALUES($1,$2,0,$3,'renji-run-markdown-v1',$4,$5,$6)`, id, run.Context.RunID, binding, rawRun, archiveHash(rawManifest), f.owner)
	require.NoError(t, err)
	_, err = f.s.Pool.Exec(ctx, `INSERT INTO execution_archive_parts(archive_id,part,title,content,content_hash,state,external_id,observed_content_hash,observed_title_hash) VALUES($1,1,$2,$3,$4,'verified','legacy-known-id',$4,$5)`, id, title, body, hash, archiveHash([]byte(title)))
	require.NoError(t, err)
	_, err = f.s.Pool.Exec(ctx, `INSERT INTO execution_archive_cursors(run_id,target_binding,verified_through,archive_id) VALUES($1,$2,0,$3)`, run.Context.RunID, binding, id)
	require.NoError(t, err)
	before, err := f.s.ReadExecutionArchive(ctx, machineEvidenceReader(), id)
	require.NoError(t, err)
	again, err := f.s.PrepareExecutionArchive(ctx, machineEvidenceReader(), run.Context.RunID, binding)
	require.NoError(t, err)
	require.Equal(t, before, again)
	require.Equal(t, "renji-run-markdown-v1", again.Renderer)
	var actual string
	require.NoError(t, f.s.Pool.QueryRow(ctx, `SELECT content FROM execution_archive_parts WHERE archive_id=$1`, id).Scan(&actual))
	require.Equal(t, body, actual)
	appendEvidence(t, f, run, "new-evidence", "model.output", json.RawMessage(`{"content":"新证据"}`))
	newer, err := f.s.PrepareExecutionArchive(ctx, machineEvidenceReader(), run.Context.RunID, binding)
	require.NoError(t, err)
	require.NotEqual(t, id, newer.ID)
	require.Equal(t, "renji-run-markdown-v2", newer.Renderer)
	old, err := f.s.ReadExecutionArchive(ctx, machineEvidenceReader(), id)
	require.NoError(t, err)
	require.Equal(t, before, old)
}
