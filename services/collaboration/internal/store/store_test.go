package store

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/jackc/pgx/v5"
	"github.com/stretchr/testify/require"
)

func testStore(t *testing.T) *Store {
	t.Helper()
	dsn := os.Getenv("RENJI_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set RENJI_TEST_DATABASE_URL for real PostgreSQL integration")
	}
	ctx := context.Background()
	admin, err := pgx.Connect(ctx, dsn)
	require.NoError(t, err)
	schema := "test_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	_, err = admin.Exec(ctx, "CREATE SCHEMA "+schema)
	require.NoError(t, err)
	u, err := url.Parse(dsn)
	require.NoError(t, err)
	q := u.Query()
	q.Set("search_path", schema)
	u.RawQuery = q.Encode()
	s, err := Open(ctx, u.String())
	require.NoError(t, err)
	t.Cleanup(func() { s.Close(); admin.Exec(ctx, "DROP SCHEMA "+schema+" CASCADE"); admin.Close(ctx) })
	require.NoError(t, s.Migrate(ctx))
	return s
}
func actor(t *testing.T, s *Store, kind string) string {
	id := uuid.NewString()
	_, err := s.Pool.Exec(context.Background(), "INSERT INTO principals(id,kind,display_name) VALUES($1,$2,$3)", id, kind, "测试"+kind)
	require.NoError(t, err)
	return id
}
func TestIdentityIsolation(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	a, err := s.ResolveIdentity(ctx, "issuer-a", "same-sub")
	require.NoError(t, err)
	b, err := s.ResolveIdentity(ctx, "issuer-b", "same-sub")
	require.NoError(t, err)
	require.NotEqual(t, a.ID, b.ID)
	again, err := s.ResolveIdentity(ctx, "issuer-a", "same-sub")
	require.NoError(t, err)
	require.Equal(t, a, again)
	_, err = s.Pool.Exec(ctx, "UPDATE principals SET disabled=true WHERE id=$1", a.ID)
	require.NoError(t, err)
	_, err = s.ResolveIdentity(ctx, "issuer-a", "same-sub")
	require.ErrorIs(t, err, domain.ErrForbidden)
}
func TestConcurrentMessageReceiptAndRevocation(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	owner := actor(t, s, "agent")
	human := actor(t, s, "human")
	outsider := actor(t, s, "human")
	w, err := s.CreateWorkspace(ctx, owner, "create-workspace", "同权集成测试")
	require.NoError(t, err)
	_, err = s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", w, human)
	require.NoError(t, err)
	r, err := s.CreateRoom(ctx, owner, "create-room", w, "人和Agent", []string{human})
	require.NoError(t, err)
	epoch := r.ScopeEpoch
	cmd := domain.SendMessage{ActionID: "stable-message-1", Content: "同一个动作只落一条消息", ScopeEpoch: &epoch}
	var wg sync.WaitGroup
	errs := make(chan error, 12)
	ids := make(chan string, 12)
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			receipt, e := s.Send(ctx, owner, r.ID, cmd)
			errs <- e
			ids <- receipt.Message.ID
		}()
	}
	wg.Wait()
	close(errs)
	close(ids)
	for e := range errs {
		require.NoError(t, e)
	}
	seen := map[string]bool{}
	for id := range ids {
		seen[id] = true
	}
	require.Len(t, seen, 1)
	var messages, actions, audit, outbox int
	for _, q := range []struct {
		sql string
		out *int
	}{{"SELECT count(*) FROM messages", &messages}, {"SELECT count(*) FROM actions WHERE action_id='stable-message-1'", &actions}, {"SELECT count(*) FROM events WHERE type='message.created'", &audit}, {"SELECT count(*) FROM transport_outbox WHERE event_id IN(SELECT id FROM events WHERE type='message.created')", &outbox}} {
		require.NoError(t, s.Pool.QueryRow(ctx, q.sql).Scan(q.out))
	}
	require.Equal(t, []int{1, 1, 1, 1}, []int{messages, actions, audit, outbox})
	changed := cmd
	changed.Content = "不能借重试换正文"
	_, err = s.Send(ctx, owner, r.ID, changed)
	require.ErrorIs(t, err, domain.ErrConflict)
	_, err = s.Send(ctx, outsider, r.ID, domain.SendMessage{ActionID: "outsider-send", Content: "无权限"})
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = s.SetStopped(ctx, human, r.ID, "deny-stop", r.Version, true)
	require.ErrorIs(t, err, domain.ErrForbidden)
	stopped, err := s.SetStopped(ctx, owner, r.ID, "stop-agent-room", r.Version, true)
	require.NoError(t, err)
	_, err = s.Send(ctx, owner, r.ID, domain.SendMessage{ActionID: "new-after-stop", Content: "应阻止", ScopeEpoch: &epoch})
	require.ErrorIs(t, err, domain.ErrStopped)
	replayed, err := s.Send(ctx, owner, r.ID, cmd)
	require.NoError(t, err)
	require.True(t, replayed.Replayed)
	_, err = s.Send(ctx, human, r.ID, domain.SendMessage{ActionID: "human-after-stop", Content: "人仍可干预"})
	require.NoError(t, err)
	resumed, err := s.SetStopped(ctx, owner, r.ID, "resume-agent-room", stopped.Version, false)
	require.NoError(t, err)
	require.Greater(t, resumed.ScopeEpoch, epoch)
	_, err = s.Send(ctx, owner, r.ID, domain.SendMessage{ActionID: "stale-after-resume", Content: "旧代次不能复活", ScopeEpoch: &epoch})
	require.ErrorIs(t, err, domain.ErrStopped)
	_, err = s.Send(ctx, owner, r.ID, domain.SendMessage{ActionID: "fresh-after-resume", Content: "新代次", ScopeEpoch: &resumed.ScopeEpoch})
	require.NoError(t, err)
	_, err = s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", r.ID, owner)
	require.NoError(t, err)
	_, err = s.Send(ctx, owner, r.ID, cmd)
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = s.Messages(ctx, owner, r.ID, 0)
	require.ErrorIs(t, err, domain.ErrForbidden)
	list, err := s.Messages(ctx, human, r.ID, 0)
	require.NoError(t, err)
	require.Len(t, list, 3)
	for i, m := range list {
		require.Equal(t, int64(i+1), m.Seq, fmt.Sprint(m))
	}
}
