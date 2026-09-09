package store

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/stretchr/testify/require"
)

func TestProfileConcurrentIdempotencyVersionAndIdentity(t *testing.T) {
	s := testStore(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	p, err := s.ResolveIdentity(ctx, "profile-fixture", "new-human")
	require.NoError(t, err)
	reader := AccountReader{PrincipalID: p.ID}
	first, err := s.ReadProfile(ctx, reader, "")
	require.NoError(t, err)
	require.Equal(t, int64(1), first.Version)
	workspaces, err := s.Workspaces(ctx, reader, AccountQuery{})
	require.NoError(t, err)
	require.Empty(t, workspaces.Workspaces)
	cmd := domain.UpdateProfile{ActionID: "profile-human-one", DisplayName: "  花破痕  ", ExpectedVersion: 1}
	var wg sync.WaitGroup
	errs := make(chan error, 12)
	receipts := make(chan domain.ProfileReceipt, 12)
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); out, e := s.UpdateProfile(ctx, p.ID, cmd); errs <- e; receipts <- out }()
	}
	wg.Wait()
	close(errs)
	close(receipts)
	for err := range errs {
		require.NoError(t, err)
	}
	freshCount := 0
	for receipt := range receipts {
		require.Equal(t, "花破痕", receipt.Principal.DisplayName)
		require.Equal(t, p.ID, receipt.Principal.ID)
		require.Equal(t, "human", receipt.Principal.Kind)
		require.Equal(t, int64(2), receipt.Version)
		if !receipt.Replayed {
			freshCount++
		}
	}
	require.Equal(t, 1, freshCount)
	require.Equal(t, 1, executionCount(t, s, "actions"))
	require.Equal(t, 1, executionCount(t, s, "events"))
	require.Zero(t, executionCount(t, s, "transport_outbox"))
	changed := cmd
	changed.DisplayName = "another payload"
	_, err = s.UpdateProfile(ctx, p.ID, changed)
	require.ErrorIs(t, err, domain.ErrConflict)
	changed.ActionID = "profile-stale-version"
	_, err = s.UpdateProfile(ctx, p.ID, changed)
	require.ErrorIs(t, err, domain.ErrProfileVersionConflict)
	changed.ExpectedVersion = 2
	next, err := s.UpdateProfile(ctx, p.ID, changed)
	require.NoError(t, err)
	require.Equal(t, int64(3), next.Version)
	replay, err := s.UpdateProfile(ctx, p.ID, cmd)
	require.NoError(t, err)
	require.True(t, replay.Replayed)
	require.Equal(t, "花破痕", replay.Principal.DisplayName, "replay is the old receipt, not a new mutation")
	again, err := s.ResolveIdentity(ctx, "profile-fixture", "new-human")
	require.NoError(t, err)
	require.Equal(t, p.ID, again.ID)
	require.Equal(t, "another payload", again.DisplayName)
	_, err = s.Pool.Exec(ctx, "UPDATE principals SET disabled=true WHERE id=$1", p.ID)
	require.NoError(t, err)
	_, err = s.UpdateProfile(ctx, p.ID, cmd)
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = s.ReadProfile(ctx, reader, "")
	require.ErrorIs(t, err, domain.ErrForbidden)
}

func TestProfileInputBoundariesAndEmptyAccountOnboarding(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	id := actor(t, s, "human")
	for _, name := range []string{"", " \n ", "a\nb", "a\x00b", "a\u202eb", "a\u2028b", strings.Repeat("中", 81), string([]byte{0xff, 0xfe})} {
		_, err := s.UpdateProfile(ctx, id, domain.UpdateProfile{ActionID: "invalid-profile-" + uuid.NewString(), DisplayName: name, ExpectedVersion: 1})
		require.ErrorIs(t, err, domain.ErrInvalid)
	}
	require.Zero(t, executionCount(t, s, "actions"))
	out, err := s.UpdateProfile(ctx, id, domain.UpdateProfile{ActionID: "profile-eighty-runes", DisplayName: strings.Repeat("🚀", 80), ExpectedVersion: 1})
	require.NoError(t, err)
	require.Equal(t, int64(2), out.Version)
	workspace, err := s.CreateWorkspace(ctx, id, "onboard-workspace", "自己的工作空间")
	require.NoError(t, err)
	room, err := s.CreateRoom(ctx, id, "onboard-first-room", workspace, "第一群", nil)
	require.NoError(t, err)
	members, err := s.RoomMembers(ctx, AccountReader{PrincipalID: id}, room.ID, AccountQuery{})
	require.NoError(t, err)
	require.Equal(t, []domain.Member{{PrincipalID: id, Kind: "human", DisplayName: out.Principal.DisplayName, Role: "owner"}}, members.Members)
	_, err = s.CreateRoom(ctx, id, "no-invented-colleague", workspace, "不能造人", []string{uuid.NewString()})
	require.ErrorIs(t, err, domain.ErrForbidden)
	for _, title := range []string{"hello\nworld", "a\x00b", "a\u202eb", string([]byte{0xff})} {
		_, err = s.CreateWorkspace(ctx, id, "invalid-title-"+uuid.NewString(), title)
		require.ErrorIs(t, err, domain.ErrInvalid)
		_, err = s.CreateRoom(ctx, id, "invalid-room-title-"+uuid.NewString(), workspace, title, nil)
		require.ErrorIs(t, err, domain.ErrInvalid)
	}
}

func TestWorkspaceAndMemberPaginationUseCurrentRolesAndACL(t *testing.T) {
	f := newExecutionFixture(t, "agent")
	ctx := context.Background()
	reader := AccountReader{PrincipalID: f.owner}
	second, err := f.s.CreateWorkspace(ctx, f.owner, "second-owned-workspace", "第二空间")
	require.NoError(t, err)
	seen := map[string]bool{}
	q := AccountQuery{Limit: 1}
	for {
		page, err := f.s.Workspaces(ctx, reader, q)
		require.NoError(t, err)
		require.Len(t, page.Workspaces, 1)
		require.Equal(t, "owner", page.Workspaces[0].Role)
		require.False(t, seen[page.Workspaces[0].ID])
		seen[page.Workspaces[0].ID] = true
		if page.Cursor == "" {
			break
		}
		q.After = page.Cursor
	}
	require.Equal(t, map[string]bool{f.workspace: true, second: true}, seen)
	seen = map[string]bool{}
	q = AccountQuery{Limit: 1}
	for {
		page, err := f.s.WorkspaceMembers(ctx, reader, f.workspace, q)
		require.NoError(t, err)
		require.Len(t, page.Members, 1)
		require.False(t, seen[page.Members[0].PrincipalID])
		seen[page.Members[0].PrincipalID] = true
		if page.Cursor == "" {
			break
		}
		q.After = page.Cursor
	}
	require.Len(t, seen, 3)
	outsider := actor(t, f.s, "human")
	_, err = f.s.WorkspaceMembers(ctx, AccountReader{PrincipalID: outsider}, f.workspace, AccountQuery{})
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.RoomMembers(ctx, AccountReader{PrincipalID: outsider}, f.target.ID, AccountQuery{})
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.Pool.Exec(ctx, "UPDATE principals SET disabled=true WHERE id=$1", f.employee)
	require.NoError(t, err)
	page, err := f.s.RoomMembers(ctx, reader, f.target.ID, AccountQuery{})
	require.NoError(t, err)
	require.Len(t, page.Members, 2)
	_, err = f.s.Pool.Exec(ctx, "DELETE FROM workspace_members WHERE workspace_id=$1 AND principal_id=$2", f.workspace, f.agent)
	require.NoError(t, err)
	_, err = f.s.RoomMembers(ctx, AccountReader{PrincipalID: f.agent}, f.target.ID, AccountQuery{})
	require.ErrorIs(t, err, domain.ErrForbidden)
	for _, q := range []AccountQuery{{Limit: -1}, {Limit: 101}, {After: "bad"}, {RunID: "bad"}} {
		_, err := f.s.Workspaces(ctx, reader, q)
		require.ErrorIs(t, err, domain.ErrInvalid)
	}
}

func TestMachineAccountReadsKeepWorkspaceAndAllRunScopes(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	reader := AccountReader{MachineIssuer: machineIssuer, MachineSubject: machineSubject}
	b, err := f.s.CreateWorkspace(ctx, f.owner, "machine-account-workspace-b", "不可跨入")
	require.NoError(t, err)
	_, err = f.s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", b, f.agent)
	require.NoError(t, err)
	otherRoom, err := f.s.CreateRoom(ctx, f.owner, "machine-account-room-b", b, "另一空间", []string{f.agent})
	require.NoError(t, err)
	page, err := f.s.Workspaces(ctx, reader, AccountQuery{})
	require.NoError(t, err)
	require.Len(t, page.Workspaces, 1)
	require.Equal(t, f.workspace, page.Workspaces[0].ID)
	_, err = f.s.WorkspaceMembers(ctx, reader, b, AccountQuery{})
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.RoomMembers(ctx, reader, otherRoom.ID, AccountQuery{})
	require.ErrorIs(t, err, domain.ErrForbidden)
	parent := f.run(t, f.source, "")
	run := f.run(t, f.target, parent.Context.RunID)
	q := AccountQuery{RunID: run.Context.RunID}
	_, err = f.s.ReadProfile(ctx, reader, q.RunID)
	require.NoError(t, err)
	_, err = f.s.Workspaces(ctx, reader, q)
	require.NoError(t, err)
	extra := actor(t, f.s, "human")
	_, err = f.s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", f.workspace, extra)
	require.NoError(t, err)
	unrelated, err := f.s.CreateRoom(ctx, f.owner, "machine-account-unrelated", f.workspace, "范围外", []string{f.agent, extra})
	require.NoError(t, err)
	_, err = f.s.RoomMembers(ctx, reader, unrelated.ID, q)
	require.ErrorIs(t, err, domain.ErrForbidden)
	scoped, err := f.s.WorkspaceMembers(ctx, reader, f.workspace, q)
	require.NoError(t, err)
	require.Len(t, scoped.Members, 3)
	all, err := f.s.WorkspaceMembers(ctx, reader, f.workspace, AccountQuery{})
	require.NoError(t, err)
	require.Len(t, all.Members, 4)
	stopped, err := f.s.SetStopped(ctx, f.owner, f.source.ID, "account-read-stop", f.source.Version, true)
	require.NoError(t, err)
	_, err = f.s.ReadProfile(ctx, reader, q.RunID)
	require.ErrorIs(t, err, domain.ErrStopped)
	_, err = f.s.Workspaces(ctx, reader, q)
	require.ErrorIs(t, err, domain.ErrStopped)
	_, err = f.s.RoomMembers(ctx, reader, f.target.ID, q)
	require.ErrorIs(t, err, domain.ErrStopped)
	_, err = f.s.ReadProfile(ctx, reader, "")
	require.NoError(t, err)
	_, err = f.s.WorkspaceMembers(ctx, reader, f.workspace, AccountQuery{})
	require.NoError(t, err)
	_, err = f.s.SetStopped(ctx, f.owner, f.source.ID, "account-read-resume", stopped.Version, false)
	require.NoError(t, err)
	_, err = f.s.Workspaces(ctx, reader, q)
	require.ErrorIs(t, err, domain.ErrStopped)
	_, err = f.s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", f.source.ID, f.agent)
	require.NoError(t, err)
	_, err = f.s.RoomMembers(ctx, reader, f.target.ID, q)
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.Pool.Exec(ctx, "UPDATE executors SET enabled=false WHERE id=$1", f.b.ExecutorID)
	require.NoError(t, err)
	_, err = f.s.ReadProfile(ctx, reader, "")
	require.ErrorIs(t, err, domain.ErrForbidden)
}

func profileAction(run ExecutionRun, key, name string, version int64) harness.Action {
	payload, _ := json.Marshal(map[string]any{"display_name": name, "expected_version": version})
	return harness.Action{ID: harness.StableID(run.Context.RunID, key), Type: "profile.update", Payload: payload}
}

func TestExecutionProfileSharesDurableActionAndNoTransport(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	parent := f.run(t, f.source, "")
	run := f.run(t, f.target, parent.Context.RunID)
	action := profileAction(run, "name-self", "机伴工程师", 1)
	beforeActions, beforeOutbox := executionCount(t, f.s, "actions"), executionCount(t, f.s, "transport_outbox")
	var wg sync.WaitGroup
	errs := make(chan error, 8)
	receipts := make(chan harness.Receipt, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r, e := f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, action)
			receipts <- r
			errs <- e
		}()
	}
	wg.Wait()
	close(errs)
	close(receipts)
	for err := range errs {
		require.NoError(t, err)
	}
	var canonical harness.Receipt
	for receipt := range receipts {
		if canonical.ActionID == "" {
			canonical = receipt
		}
		require.Equal(t, canonical, receipt)
	}
	require.Equal(t, "succeeded", canonical.Status)
	var result struct {
		Profile         domain.ProfileReceipt `json:"profile"`
		TransportStatus string                `json:"transport_status"`
	}
	require.NoError(t, json.Unmarshal(canonical.Result, &result))
	require.Equal(t, f.agent, result.Profile.Principal.ID)
	require.Equal(t, "机伴工程师", result.Profile.Principal.DisplayName)
	require.Equal(t, int64(2), result.Profile.Version)
	require.Equal(t, "not_applicable", result.TransportStatus)
	require.Equal(t, beforeActions+1, executionCount(t, f.s, "actions"))
	require.Equal(t, 1, executionCount(t, f.s, "execution_actions"))
	require.Equal(t, beforeOutbox, executionCount(t, f.s, "transport_outbox"))
	var nullMessage bool
	require.NoError(t, f.s.Pool.QueryRow(ctx, "SELECT message_id IS NULL FROM execution_actions WHERE run_id=$1", run.Context.RunID).Scan(&nullMessage))
	require.True(t, nullMessage)
	_, err := f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, profileAction(run, "name-self", "不能换正文", 1))
	require.ErrorIs(t, err, domain.ErrConflict)
	spoof := run.Context
	spoof.PrincipalID = f.owner
	_, err = f.s.ExecuteAction(ctx, machineIssuer, machineSubject, spoof, action)
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.ExecuteAction(ctx, "wrong-issuer", machineSubject, run.Context, action)
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = f.s.SetStopped(ctx, f.owner, f.source.ID, "profile-source-stop", f.source.Version, true)
	require.NoError(t, err)
	_, err = f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, action)
	require.ErrorIs(t, err, domain.ErrStopped)
	evidence, err := f.s.ReadExecutionEvidence(ctx, EvidenceReader{PrincipalID: f.owner}, run.Context.RunID, EvidenceQuery{Mode: "audit"})
	require.NoError(t, err)
	require.Len(t, evidence.Entries, 1)
	require.Equal(t, "action", evidence.Entries[0].Kind)
}

func TestExecutionProfileMessageLockOrderAndStopBeforeCommit(t *testing.T) {
	t.Run("profile_and_message_concurrent", func(t *testing.T) {
		f := newExecutionFixture(t, "human")
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		run := f.run(t, f.target, "")
		var wg sync.WaitGroup
		errs := make(chan error, 12)
		for i := 0; i < 12; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				a := profileAction(run, "same-profile", "并发更新", 1)
				if i%2 == 1 {
					a = messageAction(run, fmt.Sprintf("parallel-message-%d", i), "合成并发")
				}
				_, err := f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, a)
				errs <- err
			}(i)
		}
		wg.Wait()
		close(errs)
		for err := range errs {
			require.NoError(t, err)
		}
		require.Equal(t, 7, executionCount(t, f.s, "execution_actions"))
	})
	t.Run("source_stop_before_admission", func(t *testing.T) {
		f := newExecutionFixture(t, "human")
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		parent := f.run(t, f.source, "")
		run := f.run(t, f.target, parent.Context.RunID)
		block, err := f.s.Pool.Begin(ctx)
		require.NoError(t, err)
		defer block.Rollback(ctx)
		_, err = block.Exec(ctx, "SELECT id FROM rooms WHERE id=$1 FOR UPDATE", f.target.ID)
		require.NoError(t, err)
		finished := make(chan error, 1)
		go func() {
			_, e := f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, profileAction(run, "must-stop", "不能越过停止", 1))
			finished <- e
		}()
		_, err = f.s.SetStopped(ctx, f.owner, f.source.ID, "concurrent-profile-stop", f.source.Version, true)
		require.NoError(t, err)
		require.NoError(t, block.Commit(ctx))
		require.ErrorIs(t, <-finished, domain.ErrStopped)
		profile, err := f.s.ReadProfile(ctx, AccountReader{MachineIssuer: machineIssuer, MachineSubject: machineSubject}, "")
		require.NoError(t, err)
		require.Equal(t, int64(1), profile.Version)
		require.Zero(t, executionCount(t, f.s, "execution_actions"))
	})
}

func TestExecutionProfileRetriesConfirmedRollbackAcrossMemberAdmissionLocks(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	run := f.run(t, f.target, "")
	block, err := f.s.Pool.Begin(ctx)
	require.NoError(t, err)
	defer block.Rollback(ctx)
	var blockerPID int
	require.NoError(t, block.QueryRow(ctx, "SELECT pg_backend_pid()").Scan(&blockerPID))
	_, err = block.Exec(ctx, "SELECT id FROM rooms WHERE id=$1 FOR SHARE", f.target.ID)
	require.NoError(t, err)
	finished := make(chan error, 1)
	go func() {
		_, e := f.s.ExecuteAction(ctx, machineIssuer, machineSubject, run.Context, profileAction(run, "profile-member-admission", "与成员准入并发", 1))
		finished <- e
	}()
	// Observe the profile request waiting on this isolated schema's room lock,
	// after it has taken its principal write lock. No timing-only sleep asserts
	// that a lock was acquired, and unrelated schemas cannot satisfy this probe.
	require.Eventually(t, func() bool {
		var waiting bool
		e := f.s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_stat_activity a
WHERE a.pid<>$1 AND a.wait_event_type='Lock' AND EXISTS(SELECT 1 FROM pg_locks l
WHERE l.pid=a.pid AND l.relation='rooms'::regclass))`, blockerPID).Scan(&waiting)
		return e == nil && waiting
	}, 2*time.Second, 10*time.Millisecond)
	// This is the cross-member admission order used by a group transport.
	// The profile transaction must release its lock on confirmed rollback so
	// this read can finish, then retry the exact same durable action ID.
	_, err = block.Exec(ctx, "SELECT id FROM principals WHERE id=$1 FOR SHARE", f.agent)
	require.NoError(t, err)
	require.NoError(t, block.Commit(ctx))
	require.NoError(t, <-finished)
	profile, err := f.s.ReadProfile(ctx, AccountReader{MachineIssuer: machineIssuer, MachineSubject: machineSubject}, "")
	require.NoError(t, err)
	require.Equal(t, int64(2), profile.Version)
	require.Equal(t, 1, executionCount(t, f.s, "execution_actions"))
}
