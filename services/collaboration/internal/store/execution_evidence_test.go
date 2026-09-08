package store

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/stretchr/testify/require"
)

func machineEvidenceReader() EvidenceReader {
	return EvidenceReader{MachineIssuer: machineIssuer, MachineSubject: machineSubject}
}
func appendEvidence(t *testing.T, f executionFixture, run ExecutionRun, key, typ string, data json.RawMessage) {
	t.Helper()
	require.NoError(t, f.s.AppendExecutionEvent(context.Background(), machineIssuer, machineSubject, run.Context, harness.Event{ID: harness.StableID(run.Context.RunID, key), Type: typ, Stage: 1, Data: data}))
}

func TestExecutionEvidenceCompleteStablePaginationAndRawFacts(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	run := f.run(t, f.source, "")
	a := messageAction(run, "evidence-message", "真实动作内容")
	receipt, err := f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, a)
	require.NoError(t, err)
	data := json.RawMessage(`{"content":"模型声称已发成功，但这只是模型文字","nested":{"keep":[1,2,"原始值"]}}`)
	appendEvidence(t, f, run, "visible-model", "model.output", data)
	rj, _ := json.Marshal(receipt)
	appendEvidence(t, f, run, "actual-result", "action.succeeded", rj)
	first, err := f.s.ReadExecutionEvidence(ctx, machineEvidenceReader(), run.Context.RunID, EvidenceQuery{Limit: 1})
	require.NoError(t, err)
	require.True(t, first.HasMore)
	through := first.Through
	require.Equal(t, int64(4), through)
	appendEvidence(t, f, run, "later-output", "agent.output", json.RawMessage(`{"content":"追加事件不能漏页或挤入旧snapshot"}`))
	entries := append([]ExecutionEvidenceEntry{}, first.Entries...)
	cursor := first.Cursor
	for cursor < through {
		page, err := f.s.ReadExecutionEvidence(ctx, machineEvidenceReader(), run.Context.RunID, EvidenceQuery{After: cursor, Through: &through, Limit: 1})
		require.NoError(t, err)
		require.Equal(t, through, page.Through)
		require.NotEmpty(t, page.Entries)
		entries = append(entries, page.Entries...)
		cursor = page.Cursor
	}
	require.Len(t, entries, 4)
	require.Equal(t, []string{"action", "transport", "event", "event"}, []string{entries[0].Kind, entries[1].Kind, entries[2].Kind, entries[3].Kind})
	require.JSONEq(t, string(data), string(func() json.RawMessage {
		var x struct {
			Event harness.Event `json:"event"`
		}
		require.NoError(t, json.Unmarshal(entries[2].Data, &x))
		return x.Event.Data
	}()))
	for i, e := range entries {
		require.Equal(t, int64(i+1), e.Seq)
		require.False(t, e.LegacySnapshot)
	}
	current, err := f.s.ReadExecutionEvidence(ctx, EvidenceReader{PrincipalID: f.owner}, run.Context.RunID, EvidenceQuery{})
	require.NoError(t, err)
	require.Equal(t, int64(5), current.Through)
	_, err = f.s.ReadExecutionEvidence(ctx, machineEvidenceReader(), run.Context.RunID, EvidenceQuery{Through: func() *int64 { x := int64(999); return &x }()})
	require.ErrorIs(t, err, domain.ErrInvalid)
}
func TestExecutionEvidenceAuditAfterStopAndRevocationAcrossAllScopes(t *testing.T) {
	f := newExecutionFixture(t, "agent")
	ctx := context.Background()
	parent := f.run(t, f.source, "")
	run := f.run(t, f.target, parent.Context.RunID)
	appendEvidence(t, f, run, "before-stop", "model.output", json.RawMessage(`{"content":"持久历史"}`))
	stopped, err := f.s.SetStopped(ctx, f.owner, f.source.ID, "evidence-stop", f.source.Version, true)
	require.NoError(t, err)
	_, err = f.s.ReadExecutionEvidence(ctx, machineEvidenceReader(), run.Context.RunID, EvidenceQuery{Mode: "execution"})
	require.ErrorIs(t, err, domain.ErrStopped)
	for _, reader := range []EvidenceReader{machineEvidenceReader(), {PrincipalID: f.owner}, {PrincipalID: f.employee}} {
		page, e := f.s.ReadExecutionEvidence(ctx, reader, run.Context.RunID, EvidenceQuery{Mode: "audit"})
		require.NoError(t, e)
		require.Len(t, page.Entries, 1)
	}
	_, err = f.s.SetStopped(ctx, f.owner, f.source.ID, "evidence-resume", stopped.Version, false)
	require.NoError(t, err)
	_, err = f.s.ReadExecutionEvidence(ctx, machineEvidenceReader(), run.Context.RunID, EvidenceQuery{Mode: "execution"})
	require.ErrorIs(t, err, domain.ErrStopped)
	_, err = f.s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", f.source.ID, f.employee)
	require.NoError(t, err)
	_, err = f.s.ReadExecutionEvidence(ctx, EvidenceReader{PrincipalID: f.employee}, run.Context.RunID, EvidenceQuery{})
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.Pool.Exec(ctx, "UPDATE executors SET enabled=false WHERE id=$1", f.b.ExecutorID)
	require.NoError(t, err)
	_, err = f.s.ReadExecutionEvidence(ctx, machineEvidenceReader(), run.Context.RunID, EvidenceQuery{})
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.ReadExecutionEvidence(ctx, EvidenceReader{PrincipalID: f.owner}, run.Context.RunID, EvidenceQuery{})
	require.NoError(t, err)
}
func TestExecutionEvidenceMachineWorkspaceAndEqualAuditRoles(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	run := f.run(t, f.source, "")
	other := actor(t, f.s, "agent")
	_, err := f.s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", f.workspace, other)
	require.NoError(t, err)
	_, err = f.s.Pool.Exec(ctx, "INSERT INTO room_members VALUES($1,$2,'member')", f.source.ID, other)
	require.NoError(t, err)
	b, err := f.s.RegisterExecutor(ctx, f.owner, RegisterExecutorCommand{ActionID: "bind-audit-colleague", WorkspaceID: f.workspace, AgentPrincipalID: other, Issuer: machineIssuer, MachineSubject: "audit-colleague", Enabled: true})
	require.NoError(t, err)
	require.NotEqual(t, f.b.ExecutorID, b.ExecutorID)
	reader := EvidenceReader{MachineIssuer: machineIssuer, MachineSubject: "audit-colleague"}
	_, err = f.s.ReadExecutionEvidence(ctx, reader, run.Context.RunID, EvidenceQuery{Mode: "audit"})
	require.NoError(t, err)
	_, err = f.s.ReadExecutionEvidence(ctx, reader, run.Context.RunID, EvidenceQuery{Mode: "execution"})
	require.ErrorIs(t, err, domain.ErrForbidden)
	w, err := f.s.CreateWorkspace(ctx, f.owner, "another-evidence-workspace", "隔离组织")
	require.NoError(t, err)
	_, err = f.s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", w, f.agent)
	require.NoError(t, err)
	room, err := f.s.CreateRoom(ctx, f.owner, "another-evidence-room", w, "其他组织", []string{f.agent})
	require.NoError(t, err)
	foreign, err := f.s.RegisterExecutor(ctx, f.owner, RegisterExecutorCommand{ActionID: "bind-foreign-executor", WorkspaceID: w, AgentPrincipalID: f.agent, Issuer: machineIssuer, MachineSubject: "foreign-executor", Enabled: true})
	require.NoError(t, err)
	_, err = f.s.SetAgentExecutionPolicy(ctx, f.owner, AgentExecutionPolicyCommand{ActionID: "foreign-proactive", WorkspaceID: w, AgentPrincipalID: f.agent, ProactiveEnabled: true, ExpectedVersion: 1})
	require.NoError(t, err)
	r, err := f.s.CreateExecutionRun(ctx, f.agent, CreateExecutionRunCommand{ActionID: "foreign-run", ExecutorID: foreign.ExecutorID, RoomID: room.ID, ScopeEpoch: 1, Goal: "separate"})
	require.NoError(t, err)
	_, err = f.s.ReadExecutionEvidence(ctx, machineEvidenceReader(), r.Context.RunID, EvidenceQuery{})
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.ReadExecutionEvidence(ctx, EvidenceReader{PrincipalID: f.owner, MachineIssuer: machineIssuer, MachineSubject: machineSubject}, run.Context.RunID, EvidenceQuery{})
	require.ErrorIs(t, err, domain.ErrInvalid)
}
func TestExecutionEvidenceConcurrentAppendHasNoCursorHoles(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	run := f.run(t, f.source, "")
	var wg sync.WaitGroup
	errs := make(chan error, 12)
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs <- f.s.AppendExecutionEvent(ctx, machineIssuer, machineSubject, run.Context, harness.Event{ID: harness.StableID(run.Context.RunID, uuid.NewString()), Type: "agent.output", Data: json.RawMessage(`{"ok":true}`)})
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		require.NoError(t, err)
	}
	page, err := f.s.ReadExecutionEvidence(ctx, machineEvidenceReader(), run.Context.RunID, EvidenceQuery{})
	require.NoError(t, err)
	require.Len(t, page.Entries, 12)
	for i, e := range page.Entries {
		require.Equal(t, int64(i+1), e.Seq)
	}
}
func TestExecutionEvidenceReadWaitsForCurrentScopeRevocation(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	run := f.run(t, f.source, "")
	tx, err := f.s.Pool.Begin(ctx)
	require.NoError(t, err)
	_, err = tx.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", f.source.ID, f.employee)
	require.NoError(t, err)
	done := make(chan error, 1)
	go func() {
		_, err := f.s.ReadExecutionEvidence(ctx, EvidenceReader{PrincipalID: f.employee}, run.Context.RunID, EvidenceQuery{})
		done <- err
	}()
	select {
	case err := <-done:
		t.Fatalf("read escaped uncommitted revocation: %v", err)
	case <-time.After(100 * time.Millisecond):
	}
	require.NoError(t, tx.Commit(ctx))
	require.ErrorIs(t, <-done, domain.ErrForbidden)
}
