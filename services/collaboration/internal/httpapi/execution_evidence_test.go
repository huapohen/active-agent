package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
	"github.com/stretchr/testify/require"
)

func TestExecutionEvidenceRESTAndMCPShareCurrentAllSourceAuthorization(t *testing.T) {
	ctx := context.Background()
	s := httpStore(t)
	owner, err := s.ResolveIdentity(ctx, "test-only-issuer", "human-test")
	require.NoError(t, err)
	agent := uuid.NewString()
	_, err = s.Pool.Exec(ctx, "INSERT INTO principals(id,kind,display_name) VALUES($1,'agent','档案同事')", agent)
	require.NoError(t, err)
	w, err := s.CreateWorkspace(ctx, owner.ID, "evidence-http-workspace", "档案组织")
	require.NoError(t, err)
	_, err = s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", w, agent)
	require.NoError(t, err)
	source, err := s.CreateRoom(ctx, owner.ID, "evidence-http-source", w, "来源", []string{agent})
	require.NoError(t, err)
	target, err := s.CreateRoom(ctx, owner.ID, "evidence-http-target", w, "目标", []string{agent})
	require.NoError(t, err)
	b, err := s.RegisterExecutor(ctx, owner.ID, store.RegisterExecutorCommand{ActionID: "evidence-http-bind", WorkspaceID: w, AgentPrincipalID: agent, Issuer: "https://fixture.clerk.accounts.dev", MachineSubject: "mch_fixture", Enabled: true})
	require.NoError(t, err)
	_, err = s.SetAgentExecutionPolicy(ctx, owner.ID, store.AgentExecutionPolicyCommand{ActionID: "evidence-http-proactive", WorkspaceID: w, AgentPrincipalID: agent, ProactiveEnabled: true, ExpectedVersion: 1})
	require.NoError(t, err)
	parent, err := s.CreateExecutionRun(ctx, agent, store.CreateExecutionRunCommand{ActionID: "evidence-http-parent", ExecutorID: b.ExecutorID, RoomID: source.ID, ScopeEpoch: 1, Goal: "权限继承"})
	require.NoError(t, err)
	run, err := s.CreateExecutionRun(ctx, agent, store.CreateExecutionRunCommand{ActionID: "evidence-http-child", ExecutorID: b.ExecutorID, RoomID: target.ID, ScopeEpoch: 1, ParentRunID: parent.Context.RunID, Goal: "完整档案"})
	require.NoError(t, err)
	require.NoError(t, s.AppendExecutionEvent(ctx, b.Issuer, b.MachineSubject, run.Context, harness.Event{ID: harness.StableID(run.Context.RunID, "model"), Type: "model.output", Data: json.RawMessage(`{"content":"原始模型报告","extra":[1,2,3]}`)}))
	h := New(s, fixtureVerifier{}, nil, nil, WithMachineVerifier(fixtureMachineVerifier{}))

	stage := harness.StageInput{Context: run.Context, Goal: run.Goal, Stage: 0, Attempt: 1}
	stageRaw, _ := json.Marshal(stage)
	stageEvent := harness.Event{ID: harness.StableID(run.Context.RunID, "http-stage-input"), Type: "stage.input", Stage: 0, Data: stageRaw}
	status, _ := request(t, h, "mt_fixture", "POST", "/internal/harness/events", map[string]any{"context": run.Context, "event": stageEvent})
	require.Equal(t, 204, status)
	// Replaying the identical real gateway request persists exactly one event.
	status, _ = request(t, h, "mt_fixture", "POST", "/internal/harness/events", map[string]any{"context": run.Context, "event": stageEvent})
	require.Equal(t, 204, status)
	var stageCount int
	require.NoError(t, s.Pool.QueryRow(ctx, "SELECT count(*) FROM execution_events WHERE run_id=$1 AND event->>'type'='stage.input'", run.Context.RunID).Scan(&stageCount))
	require.Equal(t, 1, stageCount)
	bad := stage
	bad.Context.OriginScopes = nil
	badRaw, _ := json.Marshal(bad)
	badEvent := stageEvent
	badEvent.ID = harness.StableID(run.Context.RunID, "bad-stage-scope")
	badEvent.Data = badRaw
	status, _ = request(t, h, "mt_fixture", "POST", "/internal/harness/events", map[string]any{"context": run.Context, "event": badEvent})
	require.Equal(t, 403, status)
	bad = stage
	bad.Stage = 1
	badRaw, _ = json.Marshal(bad)
	badEvent.Data = badRaw
	status, _ = request(t, h, "mt_fixture", "POST", "/internal/harness/events", map[string]any{"context": run.Context, "event": badEvent})
	require.Equal(t, 400, status)
	bad = stage
	bad.Receipts = []harness.Receipt{{ActionID: harness.StableID(run.Context.RunID, "invented-action"), Status: "succeeded"}}
	badRaw, _ = json.Marshal(bad)
	badEvent.Data = badRaw
	status, _ = request(t, h, "mt_fixture", "POST", "/internal/harness/events", map[string]any{"context": run.Context, "event": badEvent})
	require.Equal(t, 403, status)

	action := harness.Action{ID: harness.StableID(run.Context.RunID, "input-real-receipt"), Type: "message.send", Payload: json.RawMessage(`{"content":"下一阶段只引用真实回执"}`)}
	status, committed := request(t, h, "mt_fixture", "POST", "/internal/harness/actions", map[string]any{"context": run.Context, "action": action})
	require.Equal(t, 200, status)
	committedRaw, _ := json.Marshal(committed)
	var actualReceipt harness.Receipt
	require.NoError(t, json.Unmarshal(committedRaw, &actualReceipt))
	nextStage := stage
	nextStage.Stage = 1
	nextStage.Receipts = []harness.Receipt{actualReceipt}
	nextStage.PreviousSummary = "前一阶段模型总结（不替代真实回执）"
	nextRaw, _ := json.Marshal(nextStage)
	nextEvent := harness.Event{ID: harness.StableID(run.Context.RunID, "next-stage-input"), Type: "stage.input", Stage: 1, Data: nextRaw}
	status, _ = request(t, h, "mt_fixture", "POST", "/internal/harness/events", map[string]any{"context": run.Context, "event": nextEvent})
	require.Equal(t, 204, status)
	nextStage.Receipts[0].Status = "unknown"
	nextRaw, _ = json.Marshal(nextStage)
	nextEvent.ID = harness.StableID(run.Context.RunID, "tampered-receipt")
	nextEvent.Data = nextRaw
	status, _ = request(t, h, "mt_fixture", "POST", "/internal/harness/events", map[string]any{"context": run.Context, "event": nextEvent})
	require.Equal(t, 409, status)
	url := "/v1/runs/" + run.Context.RunID + "/evidence?limit=1"
	code, rest := request(t, h, "mt_fixture", "GET", url, nil)
	require.Equal(t, 200, code)
	require.Len(t, rest["entries"], 1)
	mcp := structured(t, call(t, h, "mt_fixture", "run_evidence", map[string]any{"run_id": run.Context.RunID, "limit": 1}))
	require.Equal(t, rest, mcp)
	code, human := request(t, h, "human-test", "GET", url, nil)
	require.Equal(t, 200, code)
	require.Equal(t, rest, human)
	code, _ = request(t, h, "mt_fixture", "GET", url+"&mode=execution", nil)
	require.Equal(t, 200, code)
	_, err = s.SetStopped(ctx, owner.ID, source.ID, "evidence-http-stop", 1, true)
	require.NoError(t, err)
	stageEvent.ID = harness.StableID(run.Context.RunID, "after-stop-stage")
	status, _ = request(t, h, "mt_fixture", "POST", "/internal/harness/events", map[string]any{"context": run.Context, "event": stageEvent})
	require.Equal(t, 409, status)
	code, rest = request(t, h, "mt_fixture", "GET", url, nil)
	require.Equal(t, 200, code)
	code, _ = request(t, h, "mt_fixture", "GET", url+"&mode=execution", nil)
	require.Equal(t, 409, code)
	require.Equal(t, true, call(t, h, "mt_fixture", "run_evidence", map[string]any{"run_id": run.Context.RunID, "mode": "execution"})["isError"])
	for _, suffix := range []string{"&after=-1", "&limit=0x99", "&through=999", "&mode=forged"} {
		code, _ = request(t, h, "mt_fixture", "GET", url+suffix, nil)
		require.Equal(t, 400, code, fmt.Sprint(suffix))
	}
	_, err = s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", source.ID, agent)
	require.NoError(t, err)
	code, _ = request(t, h, "mt_fixture", "GET", url, nil)
	require.Equal(t, 403, code)
	require.Equal(t, true, call(t, h, "mt_fixture", "run_evidence", map[string]any{"run_id": run.Context.RunID})["isError"])
	code, _ = request(t, h, "human-test", "GET", url, nil)
	require.Equal(t, 200, code)
}
