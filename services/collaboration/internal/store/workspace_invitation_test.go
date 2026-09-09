package store

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/stretchr/testify/require"
)

func inviteHuman(id string) AccountReader { return AccountReader{PrincipalID: id} }
func issueHuman(t *testing.T, s *Store, owner, w string) domain.InvitationReceipt {
	t.Helper()
	out, e := s.CreateWorkspaceInvitation(context.Background(), inviteHuman(owner), w, domain.CreateWorkspaceInvitation{ActionID: "invite-" + uuid.NewString()})
	require.NoError(t, e)
	return out
}
func TestWorkspaceInvitationHumanGrantOneTimeCodeAndRecovery(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	owner := actor(t, s, "human")
	human := actor(t, s, "human")
	stranger := actor(t, s, "human")
	w, e := s.CreateWorkspace(ctx, owner, "invitation-workspace", "协作团队")
	require.NoError(t, e)
	room, e := s.CreateRoom(ctx, owner, "invitation-old-room", w, "非自动加入的群", nil)
	require.NoError(t, e)
	cmd := domain.CreateWorkspaceInvitation{ActionID: "first-invitation-action"}
	first, e := s.CreateWorkspaceInvitation(ctx, inviteHuman(owner), w, cmd)
	require.NoError(t, e)
	require.True(t, first.CodeAvailable)
	require.Len(t, first.Code, 47)
	require.Equal(t, "member", first.Invitation.Role)
	replay, e := s.CreateWorkspaceInvitation(ctx, inviteHuman(owner), w, cmd)
	require.NoError(t, e)
	require.True(t, replay.Replayed)
	require.Empty(t, replay.Code)
	require.False(t, replay.CodeAvailable)
	require.Equal(t, first.Invitation.ID, replay.Invitation.ID)
	var hash, creatorRole string
	require.NoError(t, s.Pool.QueryRow(ctx, "SELECT code_hash,creator_role FROM workspace_invitations WHERE id=$1", first.Invitation.ID).Scan(&hash, &creatorRole))
	expected, e := invitationCodeHash(first.Code)
	require.NoError(t, e)
	require.Equal(t, expected, hash)
	require.Equal(t, "owner", creatorRole)
	accept := domain.AcceptWorkspaceInvitation{ActionID: "accept-first-invitation", Code: first.Code}
	accepted, e := s.AcceptWorkspaceInvitation(ctx, inviteHuman(human), accept)
	require.NoError(t, e)
	require.Equal(t, "accepted", accepted.Invitation.Status)
	require.Equal(t, human, accepted.Invitation.AcceptedBy)
	require.Equal(t, "member", accepted.Role)
	require.False(t, accepted.ExecutionScopeExtended)
	again, e := s.AcceptWorkspaceInvitation(ctx, inviteHuman(human), accept)
	require.NoError(t, e)
	require.True(t, again.Replayed)
	require.Equal(t, accepted.Invitation, again.Invitation)
	action, e := s.ReadWorkspaceInvitationAction(ctx, inviteHuman(human), accept.ActionID, "")
	require.NoError(t, e)
	require.Equal(t, invitationAccept, action.Kind)
	require.True(t, action.Receipt.Replayed)
	_, e = s.ReadWorkspaceInvitationAction(ctx, inviteHuman(stranger), accept.ActionID, "")
	require.ErrorIs(t, e, domain.ErrInvitationNotFound)
	_, e = s.AcceptWorkspaceInvitation(ctx, inviteHuman(stranger), domain.AcceptWorkspaceInvitation{ActionID: "another-acceptor-action", Code: first.Code})
	require.ErrorIs(t, e, domain.ErrInvitationUsed)
	_, e = s.RoomMembers(ctx, inviteHuman(human), room.ID, AccountQuery{})
	require.ErrorIs(t, e, domain.ErrForbidden)
	spaces, e := s.Workspaces(ctx, inviteHuman(human), AccountQuery{})
	require.NoError(t, e)
	require.Len(t, spaces.Workspaces, 1)
	list, e := s.WorkspaceInvitations(ctx, inviteHuman(owner), w, AccountQuery{Limit: 1})
	require.NoError(t, e)
	require.Len(t, list.Invitations, 1)
	require.Equal(t, cmd.ActionID, list.Invitations[0].CreateActionID)
	for _, table := range []string{"workspace_invitations", "actions", "events", "execution_actions"} {
		var raw string
		require.NoError(t, s.Pool.QueryRow(ctx, "SELECT coalesce(json_agg(x)::text,'[]') FROM "+table+" x").Scan(&raw))
		require.NotContains(t, raw, first.Code)
	}
	_, e = s.Pool.Exec(ctx, "DELETE FROM workspace_members WHERE workspace_id=$1 AND principal_id=$2", w, human)
	require.NoError(t, e)
	_, e = s.ReadWorkspaceInvitationAction(ctx, inviteHuman(human), accept.ActionID, "")
	require.ErrorIs(t, e, domain.ErrForbidden)
	_, e = s.AcceptWorkspaceInvitation(ctx, inviteHuman(human), accept)
	require.ErrorIs(t, e, domain.ErrForbidden)
}
func TestWorkspaceInvitationCurrentAdministrationAndCollision(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	owner := actor(t, s, "human")
	member := actor(t, s, "human")
	recipient := actor(t, s, "human")
	w, e := s.CreateWorkspace(ctx, owner, "invite-authority-w", "权限")
	require.NoError(t, e)
	_, e = s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", w, member)
	require.NoError(t, e)
	cmd := domain.CreateWorkspaceInvitation{ActionID: "create-collision-action", ExpiresInSeconds: 3600}
	_, e = s.CreateWorkspaceInvitation(ctx, inviteHuman(member), w, cmd)
	require.ErrorIs(t, e, domain.ErrForbidden)
	_, e = s.WorkspaceInvitations(ctx, inviteHuman(member), w, AccountQuery{})
	require.ErrorIs(t, e, domain.ErrForbidden)
	first, e := s.CreateWorkspaceInvitation(ctx, inviteHuman(owner), w, cmd)
	require.NoError(t, e)
	cmd.ExpiresInSeconds = 86400
	_, e = s.CreateWorkspaceInvitation(ctx, inviteHuman(owner), w, cmd)
	require.ErrorIs(t, e, domain.ErrConflict)
	_, e = s.RevokeWorkspaceInvitation(ctx, inviteHuman(owner), w, first.Invitation.ID, domain.RevokeWorkspaceInvitation{ActionID: cmd.ActionID})
	require.ErrorIs(t, e, domain.ErrConflict)
	_, e = s.Pool.Exec(ctx, "UPDATE workspace_members SET role='member' WHERE workspace_id=$1 AND principal_id=$2", w, owner)
	require.NoError(t, e)
	_, e = s.AcceptWorkspaceInvitation(ctx, inviteHuman(recipient), domain.AcceptWorkspaceInvitation{ActionID: "accept-revoked-admin", Code: first.Code})
	require.ErrorIs(t, e, domain.ErrForbidden)
	cmd.ExpiresInSeconds = 3600
	_, e = s.CreateWorkspaceInvitation(ctx, inviteHuman(owner), w, cmd)
	require.ErrorIs(t, e, domain.ErrForbidden)
	for _, ttl := range []int64{-1, 59, 604801} {
		_, e = s.CreateWorkspaceInvitation(ctx, inviteHuman(owner), w, domain.CreateWorkspaceInvitation{ActionID: "bad-ttl-action", ExpiresInSeconds: ttl})
		require.ErrorIs(t, e, domain.ErrInvalid)
	}
	for _, code := range []string{"", first.Code + "=", strings.Repeat("x", 47), "rji_" + strings.Repeat("!", 43)} {
		_, e = s.AcceptWorkspaceInvitation(ctx, inviteHuman(recipient), domain.AcceptWorkspaceInvitation{ActionID: "invalid-code-action", Code: code})
		require.ErrorIs(t, e, domain.ErrInvalid)
	}
}
func TestWorkspaceInvitationExpiryRevocationAndUsedArePreCommitErrors(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	owner := actor(t, s, "human")
	joiner := actor(t, s, "human")
	w, e := s.CreateWorkspace(ctx, owner, "invites-revocation-workspace", "撤销过期")
	require.NoError(t, e)
	expired := issueHuman(t, s, owner, w)
	_, e = s.Pool.Exec(ctx, "UPDATE workspace_invitations SET created_at=clock_timestamp()-interval '2 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE id=$1", expired.Invitation.ID)
	require.NoError(t, e)
	_, e = s.AcceptWorkspaceInvitation(ctx, inviteHuman(joiner), domain.AcceptWorkspaceInvitation{ActionID: "expired-not-committed", Code: expired.Code})
	require.ErrorIs(t, e, domain.ErrInvitationExpired)
	revoked := issueHuman(t, s, owner, w)
	revoke := domain.RevokeWorkspaceInvitation{ActionID: "revoke-single-invitation"}
	r, e := s.RevokeWorkspaceInvitation(ctx, inviteHuman(owner), w, revoked.Invitation.ID, revoke)
	require.NoError(t, e)
	require.Equal(t, "revoked", r.Invitation.Status)
	r, e = s.RevokeWorkspaceInvitation(ctx, inviteHuman(owner), w, revoked.Invitation.ID, revoke)
	require.NoError(t, e)
	require.True(t, r.Replayed)
	_, e = s.AcceptWorkspaceInvitation(ctx, inviteHuman(joiner), domain.AcceptWorkspaceInvitation{ActionID: "revoked-not-committed", Code: revoked.Code})
	require.ErrorIs(t, e, domain.ErrInvitationRevoked)
	for _, action := range []string{"expired-not-committed", "revoked-not-committed"} {
		_, e = s.ReadWorkspaceInvitationAction(ctx, inviteHuman(joiner), action, "")
		require.ErrorIs(t, e, domain.ErrInvitationNotFound)
	}
	valid := issueHuman(t, s, owner, w)
	_, e = s.AcceptWorkspaceInvitation(ctx, inviteHuman(joiner), domain.AcceptWorkspaceInvitation{ActionID: "successful-before-expiry", Code: valid.Code})
	require.NoError(t, e)
	_, e = s.Pool.Exec(ctx, "UPDATE workspace_invitations SET created_at=clock_timestamp()-interval '2 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE id=$1", valid.Invitation.ID)
	require.NoError(t, e)
	r, e = s.AcceptWorkspaceInvitation(ctx, inviteHuman(joiner), domain.AcceptWorkspaceInvitation{ActionID: "successful-before-expiry", Code: valid.Code})
	require.NoError(t, e)
	require.True(t, r.Replayed)
}
func TestWorkspaceInvitationConcurrentSingleConsumerAndSameAction(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	owner := actor(t, s, "human")
	w, e := s.CreateWorkspace(ctx, owner, "concurrent-invite-workspace", "并发")
	require.NoError(t, e)
	issued := issueHuman(t, s, owner, w)
	actors := []string{actor(t, s, "human"), actor(t, s, "human")}
	var wg sync.WaitGroup
	errs := make(chan error, 12)
	success := make(chan string, 12)
	for i := 0; i < 12; i++ {
		id := actors[i%2]
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, e := s.AcceptWorkspaceInvitation(ctx, inviteHuman(id), domain.AcceptWorkspaceInvitation{ActionID: "same-consumer-action", Code: issued.Code})
			errs <- e
			if e == nil {
				success <- id
			}
		}()
	}
	wg.Wait()
	close(errs)
	close(success)
	for e := range errs {
		if e != nil {
			require.ErrorIs(t, e, domain.ErrInvitationUsed)
		}
	}
	winner := ""
	for id := range success {
		if winner == "" {
			winner = id
		}
		require.Equal(t, winner, id)
	}
	require.NotEmpty(t, winner)
	var count int
	require.NoError(t, s.Pool.QueryRow(ctx, "SELECT count(*) FROM workspace_members WHERE workspace_id=$1", w).Scan(&count))
	require.Equal(t, 2, count)
	require.NoError(t, s.Pool.QueryRow(ctx, "SELECT count(*) FROM actions WHERE action_id='same-consumer-action'").Scan(&count))
	require.Equal(t, 1, count)
}
func machineInviteReader() AccountReader {
	return AccountReader{MachineIssuer: machineIssuer, MachineSubject: machineSubject}
}
func issueAgent(t *testing.T, f executionFixture, run ExecutionRun) domain.InvitationReceipt {
	t.Helper()
	out, e := f.s.CreateWorkspaceInvitation(context.Background(), machineInviteReader(), f.workspace, domain.CreateWorkspaceInvitation{ActionID: harness.StableID(run.Context.RunID, "invite-"+uuid.NewString()), RunID: run.Context.RunID})
	require.NoError(t, e)
	return out
}
func TestWorkspaceInvitationAgentIssuerInheritedAuthorityAndCompletedRun(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	_, e := f.s.Pool.Exec(ctx, "UPDATE workspace_members SET role='admin' WHERE workspace_id=$1 AND principal_id=$2", f.workspace, f.agent)
	require.NoError(t, e)
	parent := f.run(t, f.source, "")
	run := f.run(t, f.target, parent.Context.RunID)
	allowed := issueAgent(t, f, run)
	blocked := issueAgent(t, f, run)
	recipient := actor(t, f.s, "human")
	_, e = f.s.Pool.Exec(ctx, "UPDATE execution_runs SET status='completed' WHERE id=$1", run.Context.RunID)
	require.NoError(t, e)
	_, e = f.s.AcceptWorkspaceInvitation(ctx, inviteHuman(recipient), domain.AcceptWorkspaceInvitation{ActionID: "accept-completed-grant", Code: allowed.Code})
	require.NoError(t, e)
	_, e = f.s.SetStopped(ctx, f.owner, f.source.ID, "stop-invitation-parent", f.source.Version, true)
	require.NoError(t, e)
	_, e = f.s.AcceptWorkspaceInvitation(ctx, inviteHuman(actor(t, f.s, "human")), domain.AcceptWorkspaceInvitation{ActionID: "blocked-by-issuer-origin", Code: blocked.Code})
	require.ErrorIs(t, e, domain.ErrStopped)
	var authority []byte
	var role string
	require.NoError(t, f.s.Pool.QueryRow(ctx, "SELECT issued_authority,creator_role FROM workspace_invitations WHERE id=$1", allowed.Invitation.ID).Scan(&authority, &role))
	require.Equal(t, "admin", role)
	var proof invitationAuthority
	require.NoError(t, json.Unmarshal(authority, &proof))
	require.Equal(t, run.Context, proof.Context)
	for _, table := range []string{"actions", "events", "execution_actions"} {
		var raw string
		require.NoError(t, f.s.Pool.QueryRow(ctx, "SELECT json_agg(x)::text FROM "+table+" x").Scan(&raw))
		require.NotContains(t, raw, allowed.Code)
		require.NotContains(t, raw, blocked.Code)
	}
}
func TestWorkspaceInvitationAgentAcceptCrossWorkspaceRetainsExecutionScope(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	parent := f.run(t, f.source, "")
	run := f.run(t, f.target, parent.Context.RunID)
	externalOwner := actor(t, f.s, "human")
	other, e := f.s.CreateWorkspace(ctx, externalOwner, "explicit-invited-workspace", "明确邀请的新团队")
	require.NoError(t, e)
	issued := issueHuman(t, f.s, externalOwner, other)
	action := harness.StableID(run.Context.RunID, "accept-other-team")
	cmd := domain.AcceptWorkspaceInvitation{ActionID: action, Code: issued.Code, RunID: run.Context.RunID}
	wrong := machineInviteReader()
	wrong.MachineIssuer = "wrong-issuer"
	_, e = f.s.AcceptWorkspaceInvitation(ctx, wrong, cmd)
	require.ErrorIs(t, e, domain.ErrForbidden)
	missing := cmd
	missing.RunID = ""
	_, e = f.s.AcceptWorkspaceInvitation(ctx, machineInviteReader(), missing)
	require.ErrorIs(t, e, domain.ErrInvalid)
	out, e := f.s.AcceptWorkspaceInvitation(ctx, machineInviteReader(), cmd)
	require.NoError(t, e)
	require.Equal(t, f.agent, out.PrincipalID)
	require.False(t, out.ExecutionScopeExtended)
	b, e := f.s.ResolveExecutor(ctx, machineIssuer, machineSubject)
	require.NoError(t, e)
	require.Equal(t, f.workspace, b.WorkspaceID)
	current, e := f.s.GetExecutionRun(ctx, f.agent, run.Context.RunID)
	require.NoError(t, e)
	require.Equal(t, run.Context, current.Context)
	spaces, e := f.s.Workspaces(ctx, machineInviteReader(), AccountQuery{})
	require.NoError(t, e)
	require.Len(t, spaces.Workspaces, 1)
	require.Equal(t, f.workspace, spaces.Workspaces[0].ID)
	_, e = f.s.WorkspaceMembers(ctx, machineInviteReader(), other, AccountQuery{})
	require.ErrorIs(t, e, domain.ErrForbidden)
	recovered, e := f.s.ReadWorkspaceInvitationAction(ctx, machineInviteReader(), action, run.Context.RunID)
	require.NoError(t, e)
	require.Equal(t, other, recovered.Receipt.WorkspaceID)
	var raw string
	require.NoError(t, f.s.Pool.QueryRow(ctx, "SELECT receipt::text||payload::text FROM execution_actions WHERE run_id=$1 AND action_id=$2", run.Context.RunID, action).Scan(&raw))
	require.NotContains(t, raw, issued.Code)
	require.Contains(t, raw, other)
	_, e = f.s.SetStopped(ctx, f.owner, f.source.ID, "stop-acceptor-origin", f.source.Version, true)
	require.NoError(t, e)
	_, e = f.s.ReadWorkspaceInvitationAction(ctx, machineInviteReader(), action, run.Context.RunID)
	require.ErrorIs(t, e, domain.ErrStopped)
	_, e = f.s.AcceptWorkspaceInvitation(ctx, machineInviteReader(), cmd)
	require.ErrorIs(t, e, domain.ErrStopped)
}
func TestWorkspaceInvitationIssuerCredentialOrRoleRevocationInvalidatesPendingGrant(t *testing.T) {
	for _, change := range []string{"executor", "policy", "role"} {
		t.Run(change, func(t *testing.T) {
			f := newExecutionFixture(t, "human")
			ctx := context.Background()
			_, e := f.s.Pool.Exec(ctx, "UPDATE workspace_members SET role='admin' WHERE workspace_id=$1 AND principal_id=$2", f.workspace, f.agent)
			require.NoError(t, e)
			run := f.run(t, f.source, "")
			issued := issueAgent(t, f, run)
			switch change {
			case "executor":
				_, e = f.s.Pool.Exec(ctx, "UPDATE executors SET enabled=false,version=version+1 WHERE id=$1", f.b.ExecutorID)
			case "policy":
				_, e = f.s.Pool.Exec(ctx, "UPDATE agent_execution_policies SET version=version+1 WHERE principal_id=$1", f.agent)
			case "role":
				_, e = f.s.Pool.Exec(ctx, "UPDATE workspace_members SET role='member' WHERE workspace_id=$1 AND principal_id=$2", f.workspace, f.agent)
			}
			require.NoError(t, e)
			_, e = f.s.AcceptWorkspaceInvitation(ctx, inviteHuman(actor(t, f.s, "human")), domain.AcceptWorkspaceInvitation{ActionID: "revoked-authority-accept", Code: issued.Code})
			require.Error(t, e)
			require.True(t, e == domain.ErrForbidden || e == domain.ErrStopped)
		})
	}
}

func TestWorkspaceInvitationActionLockPrecedesAllSourceRooms(t *testing.T) {
	f := newExecutionFixture(t, "human")
	ctx := context.Background()
	_, e := f.s.Pool.Exec(ctx, "UPDATE workspace_members SET role='admin' WHERE workspace_id=$1 AND principal_id=$2", f.workspace, f.agent)
	require.NoError(t, e)
	run := f.run(t, f.source, "")
	issued := issueAgent(t, f, run)
	joiner := actor(t, f.s, "human")
	action := "shared-native-action-lock"
	blocker, e := f.s.Pool.Begin(ctx)
	require.NoError(t, e)
	defer blocker.Rollback(ctx)
	var pid int
	require.NoError(t, blocker.QueryRow(ctx, "SELECT pg_backend_pid()").Scan(&pid))
	_, e = blocker.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", joiner+"/"+action)
	require.NoError(t, e)
	finished := make(chan error, 1)
	go func() {
		_, e := f.s.AcceptWorkspaceInvitation(ctx, inviteHuman(joiner), domain.AcceptWorkspaceInvitation{ActionID: action, Code: issued.Code})
		finished <- e
	}()
	require.Eventually(t, func() bool {
		var waiting bool
		e := f.s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_locks w JOIN pg_locks h ON w.locktype='advisory' AND h.locktype=w.locktype AND w.classid=h.classid AND w.objid=h.objid WHERE h.pid=$1 AND h.granted AND NOT w.granted)`, pid).Scan(&waiting)
		return e == nil && waiting
	}, 2*time.Second, 10*time.Millisecond)
	probe, e := f.s.Pool.Begin(ctx)
	require.NoError(t, e)
	defer probe.Rollback(ctx)
	_, e = probe.Exec(ctx, "SELECT id FROM rooms WHERE id=$1 FOR UPDATE NOWAIT", f.source.ID)
	require.NoError(t, e, "waiting for action must not retain a source room lock")
	require.NoError(t, probe.Rollback(ctx))
	require.NoError(t, blocker.Commit(ctx))
	require.NoError(t, <-finished)
}
