package store

import (
	"context"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/stretchr/testify/require"
)

func TestRoomPreviewsReadRealLatestMessageAndBoundUnicode(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	rooms, err := f.s.Rooms(ctx, f.owner, "")
	require.NoError(t, err)
	require.Len(t, rooms, 2)
	for _, room := range rooms {
		require.Nil(t, room.LastMessage)
	}
	_, err = f.s.Send(ctx, f.owner, f.source.ID, domain.SendMessage{ActionID: "preview-first-message", Content: "较早消息"})
	require.NoError(t, err)
	content := strings.Repeat("中🙂", 130)
	last, err := f.s.Send(ctx, f.agent, f.source.ID, domain.SendMessage{ActionID: "preview-second-message", Content: content, ScopeEpoch: &f.source.ScopeEpoch})
	require.NoError(t, err)
	_, err = f.s.UpdateProfile(ctx, f.agent, domain.UpdateProfile{ActionID: "preview-author-nickname", DisplayName: "架构同事", ExpectedVersion: 1})
	require.NoError(t, err)
	rooms, err = f.s.Rooms(ctx, f.owner, "")
	require.NoError(t, err)
	for _, room := range rooms {
		if room.ID != f.source.ID {
			require.Nil(t, room.LastMessage)
			continue
		}
		p := room.LastMessage
		require.NotNil(t, p)
		require.Equal(t, last.Message.ID, p.ID)
		require.Equal(t, f.source.ID, p.RoomID)
		require.Equal(t, f.agent, p.AuthorID)
		require.Equal(t, "架构同事", p.AuthorName)
		require.Equal(t, "agent", p.AuthorKind)
		require.Equal(t, "text", p.ContentKind)
		require.Equal(t, strings.Repeat("中🙂", 120), p.Excerpt)
		require.Equal(t, 240, utf8.RuneCountInString(p.Excerpt))
		require.Equal(t, last.Message.Seq, p.Seq)
		require.True(t, last.Message.CreatedAt.Equal(p.CreatedAt))
	}
	outsider := actor(t, f.s, "human")
	rooms, err = f.s.Rooms(ctx, outsider, "")
	require.NoError(t, err)
	require.Empty(t, rooms)
	_, err = f.s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", f.source.ID, f.owner)
	require.NoError(t, err)
	rooms, err = f.s.Rooms(ctx, f.owner, "")
	require.NoError(t, err)
	require.Len(t, rooms, 1)
	require.Equal(t, f.target.ID, rooms[0].ID)
	require.Nil(t, rooms[0].LastMessage)
}

func TestRunRoomPreviewsKeepAllInheritedSources(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	parent := f.run(t, f.source, "")
	run := f.run(t, f.target, parent.Context.RunID)
	unrelated, err := f.s.CreateRoom(ctx, f.owner, "preview-unrelated-room", f.workspace, "另一群", []string{f.agent})
	require.NoError(t, err)
	for _, room := range []domain.Room{f.source, f.target, unrelated} {
		_, err := f.s.Send(ctx, f.owner, room.ID, domain.SendMessage{ActionID: "preview-seed-" + room.ID, Content: room.Title})
		require.NoError(t, err)
	}
	rooms, err := f.s.ExecutionRooms(ctx, machineIssuer, machineSubject, run.Context.RunID, "")
	require.NoError(t, err)
	require.Len(t, rooms, 2)
	for _, room := range rooms {
		require.NotEqual(t, unrelated.ID, room.ID)
		require.NotNil(t, room.LastMessage)
		require.Equal(t, room.ID, room.LastMessage.RoomID)
		require.Equal(t, room.Title, room.LastMessage.Excerpt)
	}
	_, err = f.s.SetStopped(ctx, f.owner, f.source.ID, "preview-stop-origin", f.source.Version, true)
	require.NoError(t, err)
	rooms, err = f.s.ExecutionRooms(ctx, machineIssuer, machineSubject, run.Context.RunID, "")
	require.ErrorIs(t, err, domain.ErrStopped)
	require.Empty(t, rooms)
	history, err := f.s.ExecutorRooms(ctx, machineIssuer, machineSubject, "")
	require.NoError(t, err)
	require.Len(t, history, 3)
	for _, room := range history {
		require.NotNil(t, room.LastMessage)
	}
}

func TestRoomPreviewReadRetainsMembershipUntilSummaryReadCompletes(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, err := f.s.Send(ctx, f.owner, f.source.ID, domain.SendMessage{ActionID: "preview-lock-message", Content: "授权期间可见的摘要"})
	require.NoError(t, err)
	gate, err := f.s.Pool.Begin(ctx)
	require.NoError(t, err)
	defer gate.Rollback(context.Background())
	_, err = gate.Exec(ctx, "LOCK TABLE messages IN ACCESS EXCLUSIVE MODE")
	require.NoError(t, err)
	readDone := make(chan error, 1)
	readResult := make(chan []domain.Room, 1)
	go func() {
		rooms, err := f.s.Rooms(ctx, f.employee, "")
		readResult <- rooms
		readDone <- err
	}()
	require.Eventually(t, func() bool {
		var waiting bool
		err := f.s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_stat_activity a JOIN pg_locks l ON a.pid=l.pid WHERE l.relation='messages'::regclass AND a.wait_event_type='Lock' AND a.query LIKE '%JOIN LATERAL (SELECT id,author_id,content%' AND a.pid<>pg_backend_pid())`).Scan(&waiting)
		return err == nil && waiting
	}, 3*time.Second, 20*time.Millisecond)
	revoked := make(chan error, 1)
	go func() {
		_, err := f.s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", f.source.ID, f.employee)
		revoked <- err
	}()
	// The current read owns SHARE on the real membership row while its batch
	// summary query waits. Revocation can commit only after this read completes.
	select {
	case err := <-revoked:
		t.Fatalf("revocation escaped read transaction: %v", err)
	case <-time.After(100 * time.Millisecond):
	}
	require.NoError(t, gate.Commit(ctx))
	require.NoError(t, <-readDone)
	require.Len(t, <-readResult, 2)
	require.NoError(t, <-revoked)
	rooms, err := f.s.Rooms(ctx, f.employee, "")
	require.NoError(t, err)
	require.Len(t, rooms, 1)
	require.Equal(t, f.target.ID, rooms[0].ID)
}
