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

const machineIssuer = "https://synthetic-issuer.invalid"
const machineSubject = "machine-test-agent"

type executionFixture struct {
	s                                 *Store
	owner, agent, employee, workspace string
	source, target                    domain.Room
	b                                 ExecutorBinding
}

func newExecutionFixture(t *testing.T, ownerKind string) executionFixture {
	t.Helper()
	s := testStore(t)
	ctx := context.Background()
	f := executionFixture{s: s, owner: actor(t, s, ownerKind), agent: actor(t, s, "agent"), employee: actor(t, s, "human")}
	var err error
	f.workspace, err = s.CreateWorkspace(ctx, f.owner, "execution-workspace", "执行测试组织")
	require.NoError(t, err)
	for _, id := range []string{f.agent, f.employee} {
		_, err = s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", f.workspace, id)
		require.NoError(t, err)
	}
	f.source, err = s.CreateRoom(ctx, f.owner, "execution-source-room", f.workspace, "来源", []string{f.agent, f.employee})
	require.NoError(t, err)
	f.target, err = s.CreateRoom(ctx, f.owner, "execution-target-room", f.workspace, "目标", []string{f.agent, f.employee})
	require.NoError(t, err)
	// Source sorts after target, allowing the transaction race test to hold the
	// first lock and stop an as-yet-unlocked source deterministically.
	if f.source.ID < f.target.ID {
		f.source, f.target = f.target, f.source
	}
	f.b, err = s.RegisterExecutor(ctx, f.owner, RegisterExecutorCommand{ActionID: "register-executor", WorkspaceID: f.workspace, AgentPrincipalID: f.agent, Issuer: machineIssuer, MachineSubject: machineSubject, Enabled: true})
	require.NoError(t, err)
	require.False(t, f.b.ProactiveEnabled)
	_, err = s.SetAgentExecutionPolicy(ctx, f.owner, AgentExecutionPolicyCommand{ActionID: "enable-proactive", WorkspaceID: f.workspace, AgentPrincipalID: f.agent, ProactiveEnabled: true, ExpectedVersion: 1})
	require.NoError(t, err)
	f.b, err = s.ResolveExecutor(ctx, machineIssuer, machineSubject)
	require.NoError(t, err)
	return f
}
func (f executionFixture) run(t *testing.T, room domain.Room, parent string) ExecutionRun {
	t.Helper()
	r, err := f.s.CreateExecutionRun(context.Background(), f.agent, CreateExecutionRunCommand{ActionID: "create-run-" + uuid.NewString(), ExecutorID: f.b.ExecutorID, RoomID: room.ID, ScopeEpoch: room.ScopeEpoch, ParentRunID: parent, Goal: "合成测试，不调用模型"})
	require.NoError(t, err)
	return r
}
func messageAction(run ExecutionRun, key, content string) harness.Action {
	b, _ := json.Marshal(map[string]string{"content": content})
	return harness.Action{ID: harness.StableID(run.Context.RunID, key), Type: "message.send", Payload: b}
}
func executionCount(t *testing.T, s *Store, table string) int {
	t.Helper()
	var count int
	require.NoError(t, s.Pool.QueryRow(context.Background(), "SELECT count(*) FROM "+table).Scan(&count))
	return count
}

func TestExecutionBindingRequiresCurrentWorkspaceAdministrationAndMachineIdentity(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	cmd := RegisterExecutorCommand{ActionID: "unauthorized-binding", WorkspaceID: f.workspace, AgentPrincipalID: f.agent, Issuer: machineIssuer, MachineSubject: "another-machine", Enabled: true}
	_, err := f.s.RegisterExecutor(ctx, f.employee, cmd)
	require.ErrorIs(t, err, domain.ErrForbidden)
	cmd.AgentPrincipalID = f.employee
	_, err = f.s.RegisterExecutor(ctx, f.owner, cmd)
	require.ErrorIs(t, err, domain.ErrForbidden)
	other := actor(t, f.s, "agent")
	cmd.AgentPrincipalID = other
	_, err = f.s.RegisterExecutor(ctx, f.owner, cmd)
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.ResolveExecutor(ctx, "other-issuer", machineSubject)
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.ResolveExecutor(ctx, machineIssuer, "user_human_session")
	require.ErrorIs(t, err, domain.ErrForbidden)
	human, err := f.s.ResolveIdentity(ctx, machineIssuer, machineSubject)
	require.NoError(t, err)
	require.Equal(t, "human", human.Kind)
	require.NotEqual(t, f.agent, human.ID)
	b, err := f.s.ResolveExecutor(ctx, machineIssuer, machineSubject)
	require.NoError(t, err)
	require.Equal(t, f.agent, b.Principal.ID)
	_, err = f.s.CreateExecutionRun(ctx, f.employee, CreateExecutionRunCommand{ActionID: "employee-start-run", ExecutorID: b.ExecutorID, RoomID: f.source.ID, ScopeEpoch: f.source.ScopeEpoch, Goal: "unauthorized"})
	require.ErrorIs(t, err, domain.ErrForbidden)
}

func TestExecutionAgentOwnerHasEqualAdministrationAndProactiveSelfControl(t *testing.T) {
	f := newExecutionFixture(t, "agent")
	ctx := context.Background()
	run := f.run(t, f.source, "")
	require.NoError(t, f.s.CheckExecution(ctx, machineIssuer, machineSubject, run.Context))
	policy, err := f.s.SetAgentExecutionPolicy(ctx, f.agent, AgentExecutionPolicyCommand{ActionID: "agent-self-stop-proactive", WorkspaceID: f.workspace, AgentPrincipalID: f.agent, ExpectedVersion: f.b.PolicyVersion, ProactiveEnabled: false})
	require.NoError(t, err)
	require.False(t, policy.ProactiveEnabled)
	require.ErrorIs(t, f.s.CheckExecution(ctx, machineIssuer, machineSubject, run.Context), domain.ErrStopped)
	_, err = f.s.SetAgentExecutionPolicy(ctx, f.owner, AgentExecutionPolicyCommand{ActionID: "agent-owner-resume-proactive", WorkspaceID: f.workspace, AgentPrincipalID: f.agent, ExpectedVersion: policy.Version, ProactiveEnabled: true})
	require.NoError(t, err)
	require.ErrorIs(t, f.s.CheckExecution(ctx, machineIssuer, machineSubject, run.Context), domain.ErrStopped)
}

func TestExecutionPersistedContextRejectsImpersonationAndScopeReduction(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	parent := f.run(t, f.source, "")
	child := f.run(t, f.target, parent.Context.RunID)
	require.Equal(t, []harness.Scope{{RoomID: f.source.ID, Epoch: f.source.ScopeEpoch}}, child.Context.OriginScopes)
	require.NoError(t, f.s.CheckExecution(ctx, machineIssuer, machineSubject, child.Context))
	for name, mutate := range map[string]func(*harness.RunContext){
		"principal": func(r *harness.RunContext) { r.PrincipalID = f.owner }, "executor": func(r *harness.RunContext) { r.ExecutorID = uuid.NewString() }, "run": func(r *harness.RunContext) { r.RunID = parent.Context.RunID }, "root": func(r *harness.RunContext) { r.RoomID = f.source.ID }, "epoch": func(r *harness.RunContext) { r.ScopeEpoch++ }, "origins_deleted": func(r *harness.RunContext) { r.OriginScopes = nil }, "origin_epoch": func(r *harness.RunContext) { r.OriginScopes[0].Epoch++ }, "runtime": func(r *harness.RunContext) { r.RuntimeVersion = "caller-selected" }, "workflow": func(r *harness.RunContext) { r.WorkflowVersion = "caller-selected" },
	} {
		t.Run(name, func(t *testing.T) {
			bad := child.Context
			bad.OriginScopes = append([]harness.Scope(nil), bad.OriginScopes...)
			mutate(&bad)
			require.Error(t, f.s.CheckExecution(ctx, machineIssuer, machineSubject, bad))
		})
	}
	_, err := f.s.ExecuteAction(ctx, "forged-issuer", machineSubject, child.Context, messageAction(child, "denied", "不可发送"))
	require.ErrorIs(t, err, domain.ErrForbidden)
	grandchild := f.run(t, f.source, child.Context.RunID)
	require.Equal(t, []harness.Scope{{RoomID: f.target.ID, Epoch: f.target.ScopeEpoch}}, grandchild.Context.OriginScopes)
	third, err := f.s.CreateRoom(ctx, f.owner, "third-inherited-room", f.workspace, "第三层目标", []string{f.agent})
	require.NoError(t, err)
	thirdRun := f.run(t, third, child.Context.RunID)
	require.Equal(t, []harness.Scope{{RoomID: f.target.ID, Epoch: f.target.ScopeEpoch}, {RoomID: f.source.ID, Epoch: f.source.ScopeEpoch}}, thirdRun.Context.OriginScopes)
	_, err = f.s.SetStopped(ctx, f.owner, f.source.ID, "stop-grandparent-scope", f.source.Version, true)
	require.NoError(t, err)
	require.ErrorIs(t, f.s.CheckExecution(ctx, machineIssuer, machineSubject, thirdRun.Context), domain.ErrStopped)
}

func TestExecutionConcurrentActionCommitsOneMessageAndPayloadCollisionConflicts(t *testing.T) {
	f := newExecutionFixture(t, "human")
	run := f.run(t, f.source, "")
	ctx := context.Background()
	a := messageAction(run, "one-action", "只产生一条消息")
	var wg sync.WaitGroup
	errs := make(chan error, 12)
	receipts := make(chan harness.Receipt, 12)
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			receipt, err := f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, a)
			errs <- err
			receipts <- receipt
		}()
	}
	wg.Wait()
	close(errs)
	close(receipts)
	for err := range errs {
		require.NoError(t, err)
	}
	var first harness.Receipt
	for receipt := range receipts {
		if first.ActionID == "" {
			first = receipt
		}
		require.Equal(t, first, receipt)
		require.NoError(t, receipt.Validate(a))
	}
	require.Equal(t, 1, executionCount(t, f.s, "messages"))
	require.Equal(t, 1, executionCount(t, f.s, "execution_actions"))
	var linked int
	require.NoError(t, f.s.Pool.QueryRow(ctx, "SELECT count(*) FROM transport_outbox WHERE execution_run_id=$1", run.Context.RunID).Scan(&linked))
	require.Equal(t, 1, linked)
	changed := a
	changed.Payload = json.RawMessage(`{"content":"changed"}`)
	_, err := f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, changed)
	require.ErrorIs(t, err, domain.ErrConflict)
	other := f.run(t, f.source, "")
	_, err = f.s.ExecuteAction(ctx, machineIssuer, machineSubject, other.Context, a)
	require.ErrorIs(t, err, domain.ErrConflict)
	unsupported := messageAction(run, "unsupported", "fake")
	unsupported.Type = "document.publish"
	_, err = f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, unsupported)
	require.ErrorIs(t, err, domain.ErrInvalid)
}

func TestExecutionStopAndResumeNeverRevivesInheritedEpoch(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	parent := f.run(t, f.source, "")
	child := f.run(t, f.target, parent.Context.RunID)
	stopped, err := f.s.SetStopped(ctx, f.owner, f.source.ID, "source-stop-run", f.source.Version, true)
	require.NoError(t, err)
	require.ErrorIs(t, f.s.CheckExecution(ctx, machineIssuer, machineSubject, child.Context), domain.ErrStopped)
	_, err = f.s.ExecuteAction(ctx, machineIssuer, machineSubject, child.Context, messageAction(child, "after-stop", "禁止"))
	require.ErrorIs(t, err, domain.ErrStopped)
	resumed, err := f.s.SetStopped(ctx, f.owner, f.source.ID, "source-resume-run", stopped.Version, false)
	require.NoError(t, err)
	require.ErrorIs(t, f.s.CheckExecution(ctx, machineIssuer, machineSubject, child.Context), domain.ErrStopped)
	_, err = f.s.CreateExecutionRun(ctx, f.agent, CreateExecutionRunCommand{ActionID: "child-from-stale-parent", ExecutorID: f.b.ExecutorID, RoomID: f.source.ID, ScopeEpoch: resumed.ScopeEpoch, ParentRunID: child.Context.RunID, Goal: "不能洗掉旧来源"})
	require.ErrorIs(t, err, domain.ErrStopped)
	fresh := f.run(t, resumed, "")
	require.NoError(t, f.s.CheckExecution(ctx, machineIssuer, machineSubject, fresh.Context))
}

func TestExecutionChecksAllScopesInsideMessageTransaction(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	parent := f.run(t, f.source, "")
	child := f.run(t, f.target, parent.Context.RunID)
	require.NoError(t, f.s.CheckExecution(ctx, machineIssuer, machineSubject, child.Context))
	lock, err := f.s.Pool.Begin(ctx)
	require.NoError(t, err)
	defer lock.Rollback(context.Background())
	_, err = lock.Exec(ctx, "UPDATE rooms SET title=title WHERE id=$1", f.target.ID)
	require.NoError(t, err)
	result := make(chan error, 1)
	go func() {
		_, err := f.s.ExecuteAction(ctx, machineIssuer, machineSubject, child.Context, messageAction(child, "concurrent-stop", "不允许穿透"))
		result <- err
	}()
	require.Eventually(t, func() bool {
		var waiting bool
		err := f.s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_stat_activity a JOIN pg_locks l ON l.pid=a.pid WHERE l.relation='rooms'::regclass AND a.wait_event_type='Lock' AND a.query LIKE '%FOR UPDATE OF r FOR SHARE OF m,wm%' AND a.pid<>pg_backend_pid())`).Scan(&waiting)
		return err == nil && waiting
	}, 3*time.Second, 20*time.Millisecond)
	_, err = f.s.SetStopped(ctx, f.owner, f.source.ID, "stop-during-admission", f.source.Version, true)
	require.NoError(t, err)
	require.NoError(t, lock.Commit(ctx))
	require.ErrorIs(t, <-result, domain.ErrStopped)
	require.Zero(t, executionCount(t, f.s, "messages"))
	require.Zero(t, executionCount(t, f.s, "execution_actions"))
}

func TestExecutionPendingTransportFencesSourceStopAndPolicyVersion(t *testing.T) {
	for _, cause := range []string{"source_stop", "policy_version", "executor_version"} {
		t.Run(cause, func(t *testing.T) {
			f := newExecutionFixture(t, "human")
			ctx := context.Background()
			provider := &recordingMessenger{}
			deliverCreatedRoom(t, f.s, provider)
			deliverCreatedRoom(t, f.s, provider)
			parent := f.run(t, f.source, "")
			child := f.run(t, f.target, parent.Context.RunID)
			_, err := f.s.ExecuteAction(ctx, machineIssuer, machineSubject, child.Context, messageAction(child, "pending-delivery", "先提交，再验证运输"))
			require.NoError(t, err)
			switch cause {
			case "source_stop":
				_, err = f.s.SetStopped(ctx, f.owner, f.source.ID, "stop-only-origin", f.source.Version, true)
			case "policy_version":
				_, err = f.s.SetAgentExecutionPolicy(ctx, f.owner, AgentExecutionPolicyCommand{ActionID: "reconfigure-agent", WorkspaceID: f.workspace, AgentPrincipalID: f.agent, ExpectedVersion: f.b.PolicyVersion, ProactiveEnabled: true})
			case "executor_version":
				_, err = f.s.RegisterExecutor(ctx, f.owner, RegisterExecutorCommand{ActionID: "reconfigure-executor", WorkspaceID: f.workspace, AgentPrincipalID: f.agent, Issuer: machineIssuer, MachineSubject: machineSubject, ExpectedVersion: f.b.Version, Enabled: true})
			}
			require.NoError(t, err)
			ok, err := f.s.DispatchOne(ctx, provider)
			require.NoError(t, err)
			require.True(t, ok)
			require.Empty(t, provider.messages)
			state, _ := transportState(t, f.s, f.target.ID, "message.created")
			require.Equal(t, "blocked", state)
		})
	}
}

func TestExecutionEvidenceAfterStopIsIdempotentButCannotInventSuccess(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	run := f.run(t, f.source, "")
	receipt, err := f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, messageAction(run, "committed-before-stop", "真实已提交"))
	require.NoError(t, err)
	_, err = f.s.SetStopped(ctx, f.owner, f.source.ID, "stop-before-evidence", f.source.Version, true)
	require.NoError(t, err)
	raw, _ := json.Marshal(receipt)
	e := harness.Event{ID: harness.StableID(run.Context.RunID, "receipt-event"), Type: "action.succeeded", Stage: 1, Data: raw}
	require.NoError(t, f.s.AppendExecutionEvent(ctx, machineIssuer, machineSubject, run.Context, e))
	require.NoError(t, f.s.AppendExecutionEvent(ctx, machineIssuer, machineSubject, run.Context, e))
	require.Equal(t, 1, executionCount(t, f.s, "execution_events"))
	altered := e
	altered.Data = json.RawMessage(`{"action_id":"invented","status":"succeeded"}`)
	require.ErrorIs(t, f.s.AppendExecutionEvent(ctx, machineIssuer, machineSubject, run.Context, altered), domain.ErrConflict)
	altered.ID = harness.StableID(run.Context.RunID, "new-fake-success")
	require.ErrorIs(t, f.s.AppendExecutionEvent(ctx, machineIssuer, machineSubject, run.Context, altered), domain.ErrForbidden)
	e.ID = harness.StableID(run.Context.RunID, "late-visible-output")
	e.Type = "model.output"
	e.Data = json.RawMessage(`{"content":"此前请求的迟到结果"}`)
	require.NoError(t, f.s.AppendExecutionEvent(ctx, machineIssuer, machineSubject, run.Context, e))
	stored, err := f.s.GetExecutionRun(ctx, f.owner, run.Context.RunID)
	require.NoError(t, err)
	require.Equal(t, "stopped", stored.Status)
	var afterStop bool
	require.NoError(t, f.s.Pool.QueryRow(ctx, "SELECT bool_and((data->>'post_stop')::boolean) FROM events WHERE type='execution.evidence'").Scan(&afterStop))
	require.True(t, afterStop)
}

func TestExecutionCompletedRunMayDeliverAlreadyCommittedAction(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	provider := &recordingMessenger{}
	deliverCreatedRoom(t, f.s, provider)
	deliverCreatedRoom(t, f.s, provider)
	run := f.run(t, f.source, "")
	_, err := f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, messageAction(run, "before-completion", "等待运输"))
	require.NoError(t, err)
	e := harness.Event{ID: harness.StableID(run.Context.RunID, "completed"), Type: "run.completed", Stage: 1, Data: json.RawMessage(`{"summary":"阶段结束"}`)}
	require.NoError(t, f.s.AppendExecutionEvent(ctx, machineIssuer, machineSubject, run.Context, e))
	require.ErrorIs(t, f.s.CheckExecution(ctx, machineIssuer, machineSubject, run.Context), domain.ErrStopped)
	ok, err := f.s.DispatchOne(ctx, provider)
	require.NoError(t, err)
	require.True(t, ok)
	require.Len(t, provider.messages, 1)
}

func TestExecutionRevocationDeniesChecksActionsEvidenceAndRunReads(t *testing.T) {
	for _, kind := range []string{"principal", "workspace", "origin_member", "executor"} {
		t.Run(kind, func(t *testing.T) {
			f := newExecutionFixture(t, "human")
			ctx := context.Background()
			parent := f.run(t, f.source, "")
			run := f.run(t, f.target, parent.Context.RunID)
			var err error
			switch kind {
			case "principal":
				_, err = f.s.Pool.Exec(ctx, "UPDATE principals SET disabled=true WHERE id=$1", f.agent)
			case "workspace":
				_, err = f.s.Pool.Exec(ctx, "DELETE FROM workspace_members WHERE workspace_id=$1 AND principal_id=$2", f.workspace, f.agent)
			case "origin_member":
				_, err = f.s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", f.source.ID, f.agent)
			case "executor":
				_, err = f.s.Pool.Exec(ctx, "UPDATE executors SET enabled=false,version=version+1 WHERE id=$1", f.b.ExecutorID)
			}
			require.NoError(t, err)
			require.ErrorIs(t, f.s.CheckExecution(ctx, machineIssuer, machineSubject, run.Context), domain.ErrForbidden)
			_, err = f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, messageAction(run, "revoked", "deny"))
			require.ErrorIs(t, err, domain.ErrForbidden)
			require.ErrorIs(t, f.s.AppendExecutionEvent(ctx, machineIssuer, machineSubject, run.Context, harness.Event{ID: harness.StableID(run.Context.RunID, "revoked-event"), Type: "run.stopped", Data: json.RawMessage(`{}`)}), domain.ErrForbidden)
			if kind != "executor" {
				_, err = f.s.GetExecutionRun(ctx, f.agent, run.Context.RunID)
				require.ErrorIs(t, err, domain.ErrForbidden)
			}
		})
	}
}
