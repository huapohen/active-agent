package store

import (
	"context"
	"testing"
	"time"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/stretchr/testify/require"
)

func TestExecutionReadsStayInsideInheritedScopeAndUseCurrentEpoch(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	parent := f.run(t, f.source, "")
	run := f.run(t, f.target, parent.Context.RunID)
	unrelated, err := f.s.CreateRoom(ctx, f.owner, "unrelated-read-room", f.workspace, "不相关的房间", []string{f.agent})
	require.NoError(t, err)
	for _, r := range []domain.Room{f.source, f.target, unrelated} {
		_, err = f.s.Send(ctx, f.owner, r.ID, domain.SendMessage{ActionID: "seed-read-" + r.ID, Content: "用于读取的合成记录"})
		require.NoError(t, err)
	}
	rooms, err := f.s.ExecutionRooms(ctx, machineIssuer, machineSubject, run.Context.RunID, "")
	require.NoError(t, err)
	require.Len(t, rooms, 2)
	require.Equal(t, f.target.ID, rooms[0].ID)
	require.Equal(t, f.source.ID, rooms[1].ID)
	page, err := f.s.ExecutionRooms(ctx, machineIssuer, machineSubject, run.Context.RunID, f.target.ID)
	require.NoError(t, err)
	require.Len(t, page, 1)
	require.Equal(t, f.source.ID, page[0].ID)
	messages, err := f.s.ExecutionMessages(ctx, machineIssuer, machineSubject, run.Context.RunID, f.source.ID, 0)
	require.NoError(t, err)
	require.Len(t, messages, 1)
	messages, err = f.s.ExecutionMessages(ctx, machineIssuer, machineSubject, run.Context.RunID, f.source.ID, 1)
	require.NoError(t, err)
	require.Empty(t, messages)
	_, err = f.s.ExecutionMessages(ctx, machineIssuer, machineSubject, run.Context.RunID, unrelated.ID, 0)
	require.ErrorIs(t, err, domain.ErrForbidden)
	stopped, err := f.s.SetStopped(ctx, f.owner, f.source.ID, "stop-reading-origin", f.source.Version, true)
	require.NoError(t, err)
	_, err = f.s.ExecutionRooms(ctx, machineIssuer, machineSubject, run.Context.RunID, "")
	require.ErrorIs(t, err, domain.ErrStopped)
	_, err = f.s.ExecutionMessages(ctx, machineIssuer, machineSubject, run.Context.RunID, f.target.ID, 0)
	require.ErrorIs(t, err, domain.ErrStopped)
	// Stopping a task is not revoking the account's authorized history access.
	history, err := f.s.ExecutorMessages(ctx, machineIssuer, machineSubject, f.source.ID, 0)
	require.NoError(t, err)
	require.Len(t, history, 1)
	all, err := f.s.ExecutorRooms(ctx, machineIssuer, machineSubject, "")
	require.NoError(t, err)
	require.Len(t, all, 3)
	_, err = f.s.SetStopped(ctx, f.owner, f.source.ID, "resume-reading-origin", stopped.Version, false)
	require.NoError(t, err)
	_, err = f.s.ExecutionMessages(ctx, machineIssuer, machineSubject, run.Context.RunID, f.target.ID, 0)
	require.ErrorIs(t, err, domain.ErrStopped)
	_, err = f.s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", f.source.ID, f.agent)
	require.NoError(t, err)
	_, err = f.s.ExecutionRooms(ctx, machineIssuer, machineSubject, run.Context.RunID, "")
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.ExecutionMessages(ctx, machineIssuer, machineSubject, run.Context.RunID, f.target.ID, 0)
	require.ErrorIs(t, err, domain.ErrForbidden)
}

func TestExecutionReadHoldsAllScopeChecksInTheReadingTransaction(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	parent := f.run(t, f.source, "")
	run := f.run(t, f.target, parent.Context.RunID)
	_, err := f.s.Send(ctx, f.owner, f.target.ID, domain.SendMessage{ActionID: "seed-protected-read", Content: "不能由停止中的任务继续取走"})
	require.NoError(t, err)
	require.NoError(t, f.s.CheckExecution(ctx, machineIssuer, machineSubject, run.Context))
	lock, err := f.s.Pool.Begin(ctx)
	require.NoError(t, err)
	defer lock.Rollback(context.Background())
	_, err = lock.Exec(ctx, "UPDATE rooms SET title=title WHERE id=$1", f.target.ID)
	require.NoError(t, err)
	result := make(chan error, 1)
	read := make(chan []domain.Message, 1)
	go func() {
		messages, err := f.s.ExecutionMessages(ctx, machineIssuer, machineSubject, run.Context.RunID, f.target.ID, 0)
		read <- messages
		result <- err
	}()
	require.Eventually(t, func() bool {
		var waiting bool
		err := f.s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_stat_activity a JOIN pg_locks l ON l.pid=a.pid WHERE l.relation='rooms'::regclass AND a.wait_event_type='Lock' AND a.query LIKE '%FOR UPDATE OF r FOR SHARE OF m,wm%' AND a.pid<>pg_backend_pid())`).Scan(&waiting)
		return err == nil && waiting
	}, 3*time.Second, 20*time.Millisecond)
	_, err = f.s.SetStopped(ctx, f.owner, f.source.ID, "stop-during-scope-read", f.source.Version, true)
	require.NoError(t, err)
	require.NoError(t, lock.Commit(ctx))
	require.ErrorIs(t, <-result, domain.ErrStopped)
	require.Empty(t, <-read)
}

func TestExecutorBindingCannotReadAnotherWorkspaceOfSameAgent(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	ownerB := actor(t, f.s, "human")
	workspaceB, err := f.s.CreateWorkspace(ctx, ownerB, "other-owned-workspace", "其他管理员的组织")
	require.NoError(t, err)
	for _, p := range []string{f.agent, f.owner} {
		_, err = f.s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", workspaceB, p)
		require.NoError(t, err)
	}
	roomB, err := f.s.CreateRoom(ctx, ownerB, "other-workspace-room", workspaceB, "另一工作区记录", []string{f.agent, f.owner})
	require.NoError(t, err)
	_, err = f.s.Send(ctx, ownerB, roomB.ID, domain.SendMessage{ActionID: "seed-other-workspace-history", Content: "B 工作区合成数据"})
	require.NoError(t, err)
	// The Agent account itself is a legitimate member of both A and B.
	ordinary, err := f.s.Messages(ctx, f.agent, roomB.ID, 0)
	require.NoError(t, err)
	require.Len(t, ordinary, 1)
	rooms, err := f.s.ExecutorRooms(ctx, machineIssuer, machineSubject, "")
	require.NoError(t, err)
	require.Len(t, rooms, 2)
	for _, r := range rooms {
		require.Equal(t, f.workspace, r.WorkspaceID)
	}
	_, err = f.s.ExecutorMessages(ctx, machineIssuer, machineSubject, roomB.ID, 0)
	require.ErrorIs(t, err, domain.ErrForbidden)
	cmd := RegisterExecutorCommand{ActionID: "attempt-bind-other-workspace", WorkspaceID: workspaceB, AgentPrincipalID: f.agent, Issuer: machineIssuer, MachineSubject: "other-workspace-machine", Enabled: true}
	_, err = f.s.RegisterExecutor(ctx, f.owner, cmd)
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.RegisterExecutor(ctx, ownerB, cmd)
	require.NoError(t, err)
	// B's administrator can separately admit an executor, without enabling
	// proactive execution or granting it A's history.
	history, err := f.s.ExecutorMessages(ctx, machineIssuer, cmd.MachineSubject, roomB.ID, 0)
	require.NoError(t, err)
	require.Len(t, history, 1)
	_, err = f.s.ExecutorMessages(ctx, machineIssuer, cmd.MachineSubject, f.source.ID, 0)
	require.ErrorIs(t, err, domain.ErrForbidden)
	rooms, err = f.s.ExecutorRooms(ctx, machineIssuer, cmd.MachineSubject, "")
	require.NoError(t, err)
	require.Len(t, rooms, 1)
	require.Equal(t, roomB.ID, rooms[0].ID)
	_, err = f.s.Pool.Exec(ctx, "DELETE FROM workspace_members WHERE workspace_id=$1 AND principal_id=$2", f.workspace, f.agent)
	require.NoError(t, err)
	_, err = f.s.ExecutorRooms(ctx, machineIssuer, machineSubject, "")
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.ExecutorMessages(ctx, machineIssuer, machineSubject, f.source.ID, 0)
	require.ErrorIs(t, err, domain.ErrForbidden)
}
