package store

import (
	"context"
	"fmt"
	"testing"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/stretchr/testify/require"
)

func TestMessageSelectionTraversesMoreThanOneHundredWithoutGaps(t *testing.T) {
	f, first := reactionFixture(t)
	ctx := context.Background()
	for i := 2; i <= 205; i++ {
		_, err := f.s.Send(ctx, f.owner, f.target.ID, domain.SendMessage{ActionID: fmt.Sprintf("history-%03d", i), Content: fmt.Sprintf("消息 %d", i)})
		require.NoError(t, err)
	}
	before := int64(0)
	seen := map[int64]bool{}
	for page := 0; page < 3; page++ {
		rows, err := f.s.MessagesBefore(ctx, f.employee, f.target.ID, before, 100)
		require.NoError(t, err)
		if len(rows) > 100 {
			rows = rows[len(rows)-100:]
		}
		require.NotEmpty(t, rows)
		for i, m := range rows {
			require.False(t, seen[m.Seq], "exclusive cursor repeated %d", m.Seq)
			if i > 0 {
				require.Equal(t, rows[i-1].Seq+1, m.Seq)
			}
			seen[m.Seq] = true
		}
		before = rows[0].Seq
	}
	require.Len(t, seen, 205)
	require.EqualValues(t, 1, before)
	rows, err := f.s.MessagesBefore(ctx, f.employee, f.target.ID, before, 100)
	require.NoError(t, err)
	require.Empty(t, rows)
	_, err = f.s.SetReaction(ctx, f.employee, f.target.ID, first.ID, domain.SetReaction{ActionID: "selected-by-reader", Emoji: "feishu:OK", Active: true})
	require.NoError(t, err)
	for _, actor := range []string{f.employee, f.owner} {
		m, e := f.s.Message(ctx, actor, f.target.ID, first.ID)
		require.NoError(t, e)
		require.Equal(t, first.ID, m.ID)
		require.Len(t, m.Reactions, 1)
		require.Equal(t, actor == f.employee, m.Reactions[0].Selected)
	}
	for _, bad := range []struct{ room, message string }{{f.source.ID, first.ID}, {f.target.ID, uuid.NewString()}} {
		_, e := f.s.Message(ctx, f.employee, bad.room, bad.message)
		require.ErrorIs(t, e, domain.ErrForbidden)
	}
	_, err = f.s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", f.target.ID, f.employee)
	require.NoError(t, err)
	_, err = f.s.Message(ctx, f.employee, f.target.ID, first.ID)
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.MessagesBefore(ctx, f.employee, f.target.ID, 0, 100)
	require.ErrorIs(t, err, domain.ErrForbidden)
}

func TestMessageSelectionMachineRetainsAllSourcesAndWorkspaceBoundary(t *testing.T) {
	f, m := reactionFixture(t)
	ctx := context.Background()
	parent := f.run(t, f.source, "")
	run := f.run(t, f.target, parent.Context.RunID)
	got, err := f.s.ExecutionMessage(ctx, machineIssuer, machineSubject, run.Context.RunID, f.target.ID, m.ID)
	require.NoError(t, err)
	require.Equal(t, m.ID, got.ID)
	rows, err := f.s.ExecutionMessagesBefore(ctx, machineIssuer, machineSubject, run.Context.RunID, f.target.ID, 0, 10)
	require.NoError(t, err)
	require.Len(t, rows, 1)
	w, err := f.s.CreateWorkspace(ctx, f.owner, "other-read-workspace", "另一组织")
	require.NoError(t, err)
	_, err = f.s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", w, f.agent)
	require.NoError(t, err)
	room, err := f.s.CreateRoom(ctx, f.owner, "other-read-room", w, "其他组织同一Agent", []string{f.agent})
	require.NoError(t, err)
	sent, err := f.s.Send(ctx, f.owner, room.ID, domain.SendMessage{ActionID: "other-read-message", Content: "其他组织"})
	require.NoError(t, err)
	_, err = f.s.ExecutorMessage(ctx, machineIssuer, machineSubject, room.ID, sent.Message.ID)
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.ExecutorMessagesBefore(ctx, machineIssuer, machineSubject, room.ID, 0, 10)
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.ExecutionMessage(ctx, machineIssuer, machineSubject, run.Context.RunID, room.ID, sent.Message.ID)
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.SetStopped(ctx, f.owner, f.source.ID, "stop-selection-source", f.source.Version, true)
	require.NoError(t, err)
	_, err = f.s.ExecutionMessage(ctx, machineIssuer, machineSubject, run.Context.RunID, f.target.ID, m.ID)
	require.ErrorIs(t, err, domain.ErrStopped)
	_, err = f.s.ExecutionMessagesBefore(ctx, machineIssuer, machineSubject, run.Context.RunID, f.target.ID, 0, 10)
	require.ErrorIs(t, err, domain.ErrStopped)
	_, err = f.s.ExecutorMessage(ctx, machineIssuer, machineSubject, f.target.ID, m.ID)
	require.NoError(t, err)
	_, err = f.s.ExecutorMessagesBefore(ctx, machineIssuer, machineSubject, f.target.ID, 0, 10)
	require.NoError(t, err)
	_, err = f.s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", f.source.ID, f.agent)
	require.NoError(t, err)
	_, err = f.s.ExecutionMessage(ctx, machineIssuer, machineSubject, run.Context.RunID, f.target.ID, m.ID)
	require.ErrorIs(t, err, domain.ErrForbidden)
}
