package store

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/transport"
	"github.com/stretchr/testify/require"
)

func executionArrival(t *testing.T, f executionFixture, room domain.Room, receiver string) (transport.BridgeBinding, TransportArrival) {
	t.Helper()
	ctx := context.Background()
	b := transport.BridgeBinding{ID: "read-" + uuid.NewString(), RoomID: room.ID, ReceiverID: receiver, Secret: strings.Repeat("fixture", 8)}
	sent, err := f.s.Send(ctx, f.owner, room.ID, domain.SendMessage{ActionID: uuid.NewString(), Content: "隔离接收观察", ScopeEpoch: &room.ScopeEpoch})
	require.NoError(t, err)
	uid := uuid.NewString()
	accepted, _ := json.Marshal(map[string]any{"code": 200, "messageUIDs": []map[string]string{{"groupId": room.ID, "messageUID": uid}}})
	_, err = f.s.Pool.Exec(ctx, `UPDATE transport_outbox SET status='delivered',provider_receipt=$2
WHERE event_id IN(SELECT id FROM events WHERE type='message.created' AND data->>'id'=$1)`, sent.Message.ID, accepted)
	require.NoError(t, err)
	pointer, _ := json.Marshal(map[string]any{"schema": "renji.message.v1", "room_id": room.ID, "message_id": sent.Message.ID, "seq": sent.Message.Seq})
	content, _ := json.Marshal(map[string]string{"content": sent.Message.Content, "extra": string(pointer)})
	raw, _ := json.Marshal(transport.SDKReceived{Schema: "renji.rongcloud.sdk-received.v1", MessageUID: uid, ConversationType: 3, TargetID: room.ID, SenderID: f.owner, MessageType: "RC:TxtMsg", Content: content, ReceivedTime: 123})
	a, err := f.s.RecordTransportIngress(ctx, b, raw)
	require.NoError(t, err)
	return b, a
}

func TestExecutionTransportReadScopesReceiverAndCursor(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	parent := f.run(t, f.source, "")
	run := f.run(t, f.target, parent.Context.RunID)
	rootBinding, rootArrival := executionArrival(t, f, f.target, f.agent)
	humanBinding, humanArrival := executionArrival(t, f, f.target, f.employee)
	sourceBinding, sourceArrival := executionArrival(t, f, f.source, f.agent)
	otherRoom, err := f.s.CreateRoom(ctx, f.owner, "transport-other-room", f.workspace, "Run以外", []string{f.agent})
	require.NoError(t, err)
	otherBinding, otherArrival := executionArrival(t, f, otherRoom, f.agent)
	otherWorkspace, err := f.s.CreateWorkspace(ctx, f.owner, "transport-other-workspace", "其他组织")
	require.NoError(t, err)
	_, err = f.s.Pool.Exec(ctx, `INSERT INTO workspace_members VALUES($1,$2,'member')`, otherWorkspace, f.agent)
	require.NoError(t, err)
	foreignRoom, err := f.s.CreateRoom(ctx, f.owner, "transport-foreign-room", otherWorkspace, "其他组织同Agent", []string{f.agent})
	require.NoError(t, err)
	foreignBinding, foreignArrival := executionArrival(t, f, foreignRoom, f.agent)
	for _, b := range []transport.BridgeBinding{humanBinding, otherBinding, foreignBinding} {
		require.NoError(t, f.s.RecordTransportHeartbeat(ctx, b, "connected", 1))
	}
	require.NoError(t, f.s.RecordTransportHeartbeat(ctx, rootBinding, "disconnected", 1))
	bindings := []transport.BridgeBinding{foreignBinding, rootBinding, humanBinding, otherBinding, sourceBinding, rootBinding}
	page, err := f.s.ExecutionTransportArrivals(ctx, machineIssuer, machineSubject, run.Context.RunID, 0, 1, bindings)
	require.NoError(t, err)
	require.Equal(t, f.agent, page.ReceiverID)
	require.Equal(t, run.Context.RunID, page.RunID)
	require.Equal(t, []TransportArrival{rootArrival}, page.Events)
	require.Equal(t, rootArrival.Cursor, page.NextCursor)
	require.True(t, page.HasMore)
	require.Equal(t, "disconnected", page.Status.BridgeState, "foreign connected bridges must not affect this Run")
	require.Equal(t, sourceArrival.ReceivedAt, *page.Status.LastReceivedAt)
	rooms := []string{f.source.ID, f.target.ID}
	sort.Strings(rooms)
	require.Equal(t, rooms, page.CoveredRoomIDs)
	page, err = f.s.ExecutionTransportArrivals(ctx, machineIssuer, machineSubject, run.Context.RunID, page.NextCursor, 1, bindings)
	require.NoError(t, err)
	require.Equal(t, []TransportArrival{sourceArrival}, page.Events)
	require.False(t, page.HasMore)
	last := page.NextCursor
	page, err = f.s.ExecutionTransportArrivals(ctx, machineIssuer, machineSubject, run.Context.RunID, last, 1, bindings)
	require.NoError(t, err)
	require.Empty(t, page.Events)
	require.Equal(t, last, page.NextCursor)
	for _, after := range []int64{humanArrival.Cursor, otherArrival.Cursor, foreignArrival.Cursor, maxTransportCursor, -1, maxTransportCursor + 1} {
		page, err = f.s.ExecutionTransportArrivals(ctx, machineIssuer, machineSubject, run.Context.RunID, after, 1, bindings)
		require.ErrorIs(t, err, domain.ErrInvalid)
		require.Empty(t, page.Events)
	}
	for _, limit := range []int{0, 101, -1} {
		_, err = f.s.ExecutionTransportArrivals(ctx, machineIssuer, machineSubject, run.Context.RunID, 0, limit, bindings)
		require.ErrorIs(t, err, domain.ErrInvalid)
	}
	// Only human/outside-Run coverage is equivalent to no configured receiver.
	page, err = f.s.ExecutionTransportArrivals(ctx, machineIssuer, machineSubject, run.Context.RunID, 0, 10, []transport.BridgeBinding{humanBinding, otherBinding, foreignBinding})
	require.NoError(t, err)
	require.Equal(t, "unavailable", page.Status.BridgeState)
	require.Nil(t, page.Status.LastHeartbeatAt)
	require.Nil(t, page.Status.LastReceivedAt)
	require.Empty(t, page.Events)
	require.Empty(t, page.CoveredRoomIDs)
	// Rebinding an ID to another room cannot expose the old row/status tuple.
	rebound := rootBinding
	rebound.RoomID = f.source.ID
	page, err = f.s.ExecutionTransportArrivals(ctx, machineIssuer, machineSubject, run.Context.RunID, 0, 10, []transport.BridgeBinding{rebound})
	require.NoError(t, err)
	require.Equal(t, "unavailable", page.Status.BridgeState)
	require.Empty(t, page.Events)
	require.Nil(t, page.Status.LastReceivedAt)
}

func TestExecutionTransportReadEveryPageRetainsAllOriginalAuthority(t *testing.T) {
	for _, mode := range []string{"source_stop", "root_stop", "old_epoch_after_resume", "source_membership", "workspace_membership", "principal_disabled", "executor_disabled", "policy_changed", "terminal_run"} {
		t.Run(mode, func(t *testing.T) {
			f := newExecutionFixture(t, "human")
			ctx := context.Background()
			parent := f.run(t, f.source, "")
			run := f.run(t, f.target, parent.Context.RunID)
			binding, first := executionArrival(t, f, f.target, f.agent)
			bindings := []transport.BridgeBinding{binding}
			_, err := f.s.ExecutionTransportArrivals(ctx, machineIssuer, machineSubject, run.Context.RunID, 0, 1, bindings)
			require.NoError(t, err)
			want := domain.ErrStopped
			switch mode {
			case "source_stop", "old_epoch_after_resume":
				stopped, e := f.s.SetStopped(ctx, f.owner, f.source.ID, "read-stop-source", f.source.Version, true)
				require.NoError(t, e)
				if mode == "old_epoch_after_resume" {
					_, err = f.s.SetStopped(ctx, f.owner, f.source.ID, "read-resume-source", stopped.Version, false)
				}
			case "root_stop":
				_, err = f.s.SetStopped(ctx, f.owner, f.target.ID, "read-stop-root", f.target.Version, true)
			case "source_membership":
				_, err = f.s.Pool.Exec(ctx, `DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2`, f.source.ID, f.agent)
				want = domain.ErrForbidden
			case "workspace_membership":
				_, err = f.s.Pool.Exec(ctx, `DELETE FROM workspace_members WHERE workspace_id=$1 AND principal_id=$2`, f.workspace, f.agent)
				want = domain.ErrForbidden
			case "principal_disabled":
				_, err = f.s.Pool.Exec(ctx, `UPDATE principals SET disabled=true WHERE id=$1`, f.agent)
				want = domain.ErrForbidden
			case "executor_disabled":
				_, err = f.s.Pool.Exec(ctx, `UPDATE executors SET enabled=false WHERE id=$1`, f.b.ExecutorID)
				want = domain.ErrForbidden
			case "policy_changed":
				_, err = f.s.SetAgentExecutionPolicy(ctx, f.owner, AgentExecutionPolicyCommand{ActionID: "read-policy-change", WorkspaceID: f.workspace, AgentPrincipalID: f.agent, ProactiveEnabled: false, ExpectedVersion: f.b.PolicyVersion})
			case "terminal_run":
				_, err = f.s.Pool.Exec(ctx, `UPDATE execution_runs SET status='completed' WHERE id=$1`, run.Context.RunID)
			}
			require.NoError(t, err)
			for _, configured := range [][]transport.BridgeBinding{bindings, nil} {
				page, err := f.s.ExecutionTransportArrivals(ctx, machineIssuer, machineSubject, run.Context.RunID, first.Cursor, 1, configured)
				require.ErrorIs(t, err, want)
				require.Empty(t, page.ReceiverID)
				require.Empty(t, page.Events)
				require.Nil(t, page.Status.LastReceivedAt)
			}
		})
	}
}

func TestExecutionTransportUnconfiguredStillAuthenticatesRun(t *testing.T) {
	f := newExecutionFixture(t, "human")
	run := f.run(t, f.target, "")
	ctx := context.Background()
	for _, identity := range [][2]string{{"other-issuer", machineSubject}, {machineIssuer, "human-subject"}, {"", ""}} {
		_, err := f.s.ExecutionTransportArrivals(ctx, identity[0], identity[1], run.Context.RunID, 0, 50, nil)
		require.ErrorIs(t, err, domain.ErrForbidden)
	}
	_, err := f.s.ExecutionTransportArrivals(ctx, machineIssuer, machineSubject, "", 0, 50, nil)
	require.ErrorIs(t, err, domain.ErrInvalid)
	_, err = f.s.ExecutionTransportArrivals(ctx, machineIssuer, machineSubject, uuid.NewString(), 0, 50, nil)
	require.ErrorIs(t, err, domain.ErrForbidden)
	page, err := f.s.ExecutionTransportArrivals(ctx, machineIssuer, machineSubject, run.Context.RunID, 0, 50, nil)
	require.NoError(t, err)
	require.Equal(t, f.agent, page.ReceiverID)
	require.Equal(t, run.Context.RunID, page.RunID)
	require.Equal(t, "unavailable", page.Status.BridgeState)
	require.Empty(t, page.Events)
}

func TestExecutionTransportReadCannotPassStopWhileWaitingForFirstScope(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	parent := f.run(t, f.source, "")
	run := f.run(t, f.target, parent.Context.RunID)
	bind, _ := executionArrival(t, f, f.target, f.agent)
	block, err := f.s.Pool.Begin(ctx)
	require.NoError(t, err)
	defer block.Rollback(ctx)
	var pid int
	require.NoError(t, block.QueryRow(ctx, `SELECT pg_backend_pid()`).Scan(&pid))
	_, err = block.Exec(ctx, `SELECT id FROM rooms WHERE id=$1 FOR UPDATE`, f.target.ID)
	require.NoError(t, err)
	type outcome struct {
		page TransportArrivalPage
		err  error
	}
	finished := make(chan outcome, 1)
	go func() {
		p, e := f.s.ExecutionTransportArrivals(ctx, machineIssuer, machineSubject, run.Context.RunID, 0, 50, []transport.BridgeBinding{bind})
		finished <- outcome{p, e}
	}()
	require.Eventually(t, func() bool {
		var waiting bool
		err := f.s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_stat_activity a WHERE a.pid<>$1 AND a.wait_event_type='Lock'
AND EXISTS(SELECT 1 FROM pg_locks l WHERE l.pid=a.pid AND l.relation='rooms'::regclass))`, pid).Scan(&waiting)
		return err == nil && waiting
	}, 2*time.Second, 10*time.Millisecond)
	_, err = f.s.SetStopped(ctx, f.owner, f.source.ID, "transport-read-race-stop", f.source.Version, true)
	require.NoError(t, err)
	require.NoError(t, block.Commit(ctx))
	result := <-finished
	require.ErrorIs(t, result.err, domain.ErrStopped)
	require.Empty(t, result.page.Events)
	require.Nil(t, result.page.Status.LastReceivedAt)
}
