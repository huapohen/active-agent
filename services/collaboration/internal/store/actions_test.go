package store

import (
	"context"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/stretchr/testify/require"
	"sync"
	"testing"
)

func TestCreateAndStopActionsAreDurableAndCurrentlyAuthorized(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	owner := actor(t, s, "agent")
	peer := actor(t, s, "human")
	var wg sync.WaitGroup
	ids := make(chan string, 8)
	errs := make(chan error, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			id, e := s.CreateWorkspace(ctx, owner, "workspace-action", "同权工作区")
			ids <- id
			errs <- e
		}()
	}
	wg.Wait()
	close(ids)
	close(errs)
	for e := range errs {
		require.NoError(t, e)
	}
	found := map[string]bool{}
	var workspace string
	for id := range ids {
		found[id] = true
		workspace = id
	}
	require.Len(t, found, 1)
	_, err := s.CreateWorkspace(ctx, owner, "workspace-action", "不同意图")
	require.ErrorIs(t, err, domain.ErrConflict)
	_, err = s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", workspace, peer)
	require.NoError(t, err)
	rooms := make(chan domain.Room, 8)
	errs = make(chan error, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r, e := s.CreateRoom(ctx, owner, "room-create-action", workspace, "共同办公", []string{peer, owner, peer})
			rooms <- r
			errs <- e
		}()
	}
	wg.Wait()
	close(rooms)
	close(errs)
	for e := range errs {
		require.NoError(t, e)
	}
	found = map[string]bool{}
	var room domain.Room
	for r := range rooms {
		found[r.ID] = true
		room = r
	}
	require.Len(t, found, 1)
	replay, err := s.CreateRoom(ctx, owner, "room-create-action", workspace, "共同办公", []string{peer})
	require.NoError(t, err)
	require.Equal(t, room, replay)
	_, err = s.CreateRoom(ctx, owner, "workspace-action", workspace, "同权工作区", nil)
	require.ErrorIs(t, err, domain.ErrConflict)
	stops := make(chan domain.Room, 8)
	errs = make(chan error, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r, e := s.SetStopped(ctx, owner, room.ID, "stop-once-action", 1, true)
			stops <- r
			errs <- e
		}()
	}
	wg.Wait()
	close(stops)
	close(errs)
	for e := range errs {
		require.NoError(t, e)
	}
	for r := range stops {
		require.Equal(t, int64(2), r.ScopeEpoch)
		require.Equal(t, int64(2), r.Version)
	}
	var count int
	for _, query := range []string{"SELECT count(*) FROM workspaces", "SELECT count(*) FROM rooms", "SELECT count(*) FROM events WHERE type='room.execution_policy_changed'", "SELECT count(*) FROM transport_outbox"} {
		require.NoError(t, s.Pool.QueryRow(ctx, query).Scan(&count))
		require.Equal(t, 1, count)
	}
	_, err = s.SetStopped(ctx, owner, room.ID, "stop-once-action", 2, true)
	require.ErrorIs(t, err, domain.ErrConflict)
	_, err = s.SetStopped(ctx, owner, room.ID, "stop-once-action", 1, false)
	require.ErrorIs(t, err, domain.ErrConflict)
	resumed, err := s.SetStopped(ctx, owner, room.ID, "resume-once-action", 2, false)
	require.NoError(t, err)
	require.Equal(t, int64(3), resumed.ScopeEpoch)
	old, err := s.SetStopped(ctx, owner, room.ID, "stop-once-action", 1, true)
	require.NoError(t, err)
	require.Equal(t, int64(2), old.ScopeEpoch)
	var epoch int64
	require.NoError(t, s.Pool.QueryRow(ctx, "SELECT scope_epoch FROM rooms WHERE id=$1", room.ID).Scan(&epoch))
	require.Equal(t, int64(3), epoch)
	_, err = s.Pool.Exec(ctx, "UPDATE room_members SET role='member' WHERE room_id=$1 AND principal_id=$2", room.ID, owner)
	require.NoError(t, err)
	_, err = s.SetStopped(ctx, owner, room.ID, "stop-once-action", 1, true)
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", room.ID, owner)
	require.NoError(t, err)
	_, err = s.CreateRoom(ctx, owner, "room-create-action", workspace, "共同办公", []string{peer})
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = s.Pool.Exec(ctx, "DELETE FROM workspace_members WHERE workspace_id=$1 AND principal_id=$2", workspace, owner)
	require.NoError(t, err)
	_, err = s.CreateWorkspace(ctx, owner, "workspace-action", "同权工作区")
	require.ErrorIs(t, err, domain.ErrForbidden)
}
