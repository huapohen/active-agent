package store

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/transport"
	"github.com/jackc/pgx/v5"
	"github.com/stretchr/testify/require"
)

type recordingMessenger struct {
	mu           sync.Mutex
	sessions     []string
	groups       [][]string
	messages     []domain.Message
	sessionHook  func(context.Context, domain.Principal) error
	publishHook  func(context.Context, domain.Message) error
	deadlineSeen bool
}

func (p *recordingMessenger) Session(ctx context.Context, principal domain.Principal) (transport.Session, error) {
	p.mu.Lock()
	p.sessions = append(p.sessions, principal.ID)
	if deadline, ok := ctx.Deadline(); ok && time.Until(deadline) <= deliveryTimeout {
		p.deadlineSeen = true
	}
	hook := p.sessionHook
	p.mu.Unlock()
	if hook != nil {
		if err := hook(ctx, principal); err != nil {
			return transport.Session{}, err
		}
	}
	return transport.Session{UserID: principal.ID, Token: "synthetic-provider-token"}, nil
}
func (p *recordingMessenger) CreateGroup(_ context.Context, _ domain.Room, members []string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.groups = append(p.groups, append([]string(nil), members...))
	return nil
}
func (p *recordingMessenger) Publish(ctx context.Context, m domain.Message) (transport.Delivery, error) {
	p.mu.Lock()
	p.messages = append(p.messages, m)
	hook := p.publishHook
	p.mu.Unlock()
	if hook != nil {
		if err := hook(ctx, m); err != nil {
			return transport.Delivery{}, err
		}
	}
	return transport.Delivery{Code: 200}, nil
}

func deliveryFixture(t *testing.T, s *Store) (string, string, domain.Room) {
	t.Helper()
	ctx := context.Background()
	owner := actor(t, s, "human")
	agent := actor(t, s, "agent")
	w, err := s.CreateWorkspace(ctx, owner, "outbox-workspace-create", "运输回执测试")
	require.NoError(t, err)
	_, err = s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", w, agent)
	require.NoError(t, err)
	r, err := s.CreateRoom(ctx, owner, "outbox-room-create", w, "运输测试群", []string{agent})
	require.NoError(t, err)
	return owner, agent, r
}

func transportState(t *testing.T, s *Store, room, kind string) (string, string) {
	t.Helper()
	var state string
	var receipt []byte
	require.NoError(t, s.Pool.QueryRow(context.Background(), `SELECT o.status,o.provider_receipt FROM transport_outbox o JOIN events e ON e.id=o.event_id WHERE e.room_id=$1 AND e.type=$2 ORDER BY o.id DESC LIMIT 1`, room, kind).Scan(&state, &receipt))
	return state, string(receipt)
}

func deliverCreatedRoom(t *testing.T, s *Store, p Messenger) {
	t.Helper()
	ok, err := s.DispatchOne(context.Background(), p)
	require.NoError(t, err)
	require.True(t, ok)
}

func TestOutboxHeartbeatProtectsHealthyOldClaim(t *testing.T) {
	s := testStore(t)
	_, _, r := deliveryFixture(t, s)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	claim, err := s.claimDelivery(ctx)
	require.NoError(t, err)
	_, err = s.Pool.Exec(ctx, "UPDATE transport_outbox SET updated_at=now()-interval '10 minutes',lease_expires_at=now()+interval '8 seconds' WHERE id=$1", claim.ID)
	require.NoError(t, err)
	require.NoError(t, s.QuarantineStaleDeliveries(ctx))
	state, _ := transportState(t, s, r.ID, "room.created")
	require.Equal(t, "in_flight", state)
	stop := s.keepDeliveryClaim(ctx, cancel, claim)
	require.Eventually(t, func() bool {
		var renewed bool
		err := s.Pool.QueryRow(ctx, "SELECT lease_expires_at>now()+interval '20 seconds' FROM transport_outbox WHERE id=$1", claim.ID).Scan(&renewed)
		return err == nil && renewed
	}, 8*time.Second, 100*time.Millisecond)
	require.NoError(t, stop())
	require.NoError(t, s.QuarantineStaleDeliveries(ctx))
	state, _ = transportState(t, s, r.ID, "room.created")
	require.Equal(t, "in_flight", state)
}

func TestOutboxExpiredClaimCannotSendButCanRecordItsLateResponse(t *testing.T) {
	s := testStore(t)
	_, _, r := deliveryFixture(t, s)
	ctx := context.Background()
	claim, err := s.claimDelivery(ctx)
	require.NoError(t, err)
	_, err = s.Pool.Exec(ctx, "UPDATE transport_outbox SET lease_expires_at=now()-interval '1 second' WHERE id=$1", claim.ID)
	require.NoError(t, err)
	require.NoError(t, s.QuarantineStaleDeliveries(ctx))
	require.ErrorIs(t, s.renewDeliveryClaim(ctx, claim), ErrDeliveryClaimLost)
	p := &recordingMessenger{}
	_, err = s.deliver(ctx, claim, p)
	require.ErrorIs(t, err, ErrDeliveryClaimLost)
	require.Empty(t, p.sessions)
	ok, err := s.DispatchOne(ctx, p)
	require.NoError(t, err)
	require.False(t, ok)
	require.NoError(t, s.finishDelivery(ctx, claim, "delivered", map[string]int{"code": 200}))
	state, _ := transportState(t, s, r.ID, "room.created")
	require.Equal(t, "delivered", state)
}

func TestOutboxReplacementClaimRejectsOldReceiptAndReportsZeroRows(t *testing.T) {
	s := testStore(t)
	deliveryFixture(t, s)
	ctx := context.Background()
	claim, err := s.claimDelivery(ctx)
	require.NoError(t, err)
	_, err = s.Pool.Exec(ctx, "UPDATE transport_outbox SET claim_token=$2 WHERE id=$1", claim.ID, uuid.NewString())
	require.NoError(t, err)
	require.ErrorIs(t, s.renewDeliveryClaim(ctx, claim), ErrDeliveryClaimLost)
	require.ErrorIs(t, s.finishDelivery(ctx, claim, "delivered", map[string]int{"code": 200}), ErrDeliveryClaimLost)
}

func TestOutboxClaimExpiredWhileWaitingForAuthorizationCannotCallProvider(t *testing.T) {
	s := testStore(t)
	_, _, room := deliveryFixture(t, s)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	claim, err := s.claimDelivery(ctx)
	require.NoError(t, err)
	lock, err := s.Pool.Begin(ctx)
	require.NoError(t, err)
	defer lock.Rollback(context.Background())
	_, err = lock.Exec(ctx, "UPDATE rooms SET title=title WHERE id=$1", room.ID)
	require.NoError(t, err)
	result := make(chan error, 1)
	called := make(chan struct{}, 1)
	go func() {
		result <- s.withDeliveryAdmission(ctx, claim, "", func(context.Context, pgx.Tx, domain.Principal) error {
			called <- struct{}{}
			return nil
		})
	}()
	// Observe the actual blocked authorization query, not a guessed sleep.
	require.Eventually(t, func() bool {
		var waiting bool
		err := s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_stat_activity a JOIN pg_locks l ON l.pid=a.pid
WHERE l.relation='rooms'::regclass AND a.wait_event_type='Lock'
AND a.query LIKE '%FOR SHARE OF r,m,p,wm%' AND a.pid<>pg_backend_pid())`).Scan(&waiting)
		return err == nil && waiting
	}, 3*time.Second, 20*time.Millisecond)
	_, err = s.Pool.Exec(ctx, "UPDATE transport_outbox SET lease_expires_at=clock_timestamp()-interval '1 microsecond' WHERE id=$1", claim.ID)
	require.NoError(t, err)
	require.NoError(t, lock.Commit(ctx))
	require.ErrorIs(t, <-result, ErrDeliveryClaimLost)
	require.Empty(t, called)
}

func TestOutboxStopBlocksPendingAgentDeliveryAndHumanCanIntervene(t *testing.T) {
	s := testStore(t)
	owner, agent, r := deliveryFixture(t, s)
	p := &recordingMessenger{}
	ctx := context.Background()
	deliverCreatedRoom(t, s, p)
	require.True(t, p.deadlineSeen)
	_, err := s.Send(ctx, agent, r.ID, domain.SendMessage{ActionID: "outbox-before-stop", Content: "agent pending", ScopeEpoch: &r.ScopeEpoch})
	require.NoError(t, err)
	_, err = s.SetStopped(ctx, owner, r.ID, "outbox-stop", r.Version, true)
	require.NoError(t, err)
	deliverCreatedRoom(t, s, p)
	require.Empty(t, p.messages)
	state, receipt := transportState(t, s, r.ID, "message.created")
	require.Equal(t, "blocked", state)
	require.Contains(t, receipt, "scope_stopped_or_stale")
	_, err = s.Send(ctx, owner, r.ID, domain.SendMessage{ActionID: "outbox-human-intervention", Content: "human intervention"})
	require.NoError(t, err)
	deliverCreatedRoom(t, s, p)
	require.Len(t, p.messages, 1)
	require.Equal(t, owner, p.messages[0].AuthorID)
}

func TestOutboxResumeDoesNotReviveOldEpochAndMissingEpochFailsClosed(t *testing.T) {
	s := testStore(t)
	owner, agent, r := deliveryFixture(t, s)
	p := &recordingMessenger{}
	ctx := context.Background()
	deliverCreatedRoom(t, s, p)
	_, err := s.Send(ctx, agent, r.ID, domain.SendMessage{ActionID: "outbox-old-epoch", Content: "old epoch", ScopeEpoch: &r.ScopeEpoch})
	require.NoError(t, err)
	stopped, err := s.SetStopped(ctx, owner, r.ID, "outbox-stop-old", r.Version, true)
	require.NoError(t, err)
	resumed, err := s.SetStopped(ctx, owner, r.ID, "outbox-resume", stopped.Version, false)
	require.NoError(t, err)
	deliverCreatedRoom(t, s, p)
	require.Empty(t, p.messages)
	state, _ := transportState(t, s, r.ID, "message.created")
	require.Equal(t, "blocked", state)
	_, err = s.Send(ctx, agent, r.ID, domain.SendMessage{ActionID: "outbox-missing-epoch", Content: "legacy", ScopeEpoch: &resumed.ScopeEpoch})
	require.NoError(t, err)
	_, err = s.Pool.Exec(ctx, "UPDATE transport_outbox SET admitted_scope_epoch=NULL WHERE status='pending'")
	require.NoError(t, err)
	deliverCreatedRoom(t, s, p)
	require.Empty(t, p.messages)
	state, _ = transportState(t, s, r.ID, "message.created")
	require.Equal(t, "blocked", state)
}

func TestOutboxRevokedWorkspaceMemberCannotPublish(t *testing.T) {
	s := testStore(t)
	_, agent, r := deliveryFixture(t, s)
	p := &recordingMessenger{}
	ctx := context.Background()
	deliverCreatedRoom(t, s, p)
	_, err := s.Send(ctx, agent, r.ID, domain.SendMessage{ActionID: "outbox-before-revoke", Content: "pending", ScopeEpoch: &r.ScopeEpoch})
	require.NoError(t, err)
	_, err = s.Pool.Exec(ctx, "DELETE FROM workspace_members WHERE workspace_id=$1 AND principal_id=$2", r.WorkspaceID, agent)
	require.NoError(t, err)
	deliverCreatedRoom(t, s, p)
	require.Empty(t, p.messages)
	state, receipt := transportState(t, s, r.ID, "message.created")
	require.Equal(t, "blocked", state)
	require.Contains(t, receipt, "membership_revoked")
}

func TestOutboxGroupRegistrationRechecksEachMember(t *testing.T) {
	s := testStore(t)
	owner, _, r := deliveryFixture(t, s)
	ctx := context.Background()
	extra := actor(t, s, "human")
	_, err := s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", r.WorkspaceID, extra)
	require.NoError(t, err)
	_, err = s.Pool.Exec(ctx, "INSERT INTO room_members VALUES($1,$2,'member')", r.ID, extra)
	require.NoError(t, err)
	var revoked string
	called := false
	p := &recordingMessenger{sessionHook: func(ctx context.Context, current domain.Principal) error {
		if called {
			return nil
		}
		called = true
		err := s.Pool.QueryRow(ctx, "SELECT principal_id::text FROM room_members WHERE room_id=$1 AND principal_id<>$2 AND principal_id<>$3 ORDER BY principal_id LIMIT 1", r.ID, owner, current.ID).Scan(&revoked)
		if err != nil {
			return err
		}
		_, err = s.Pool.Exec(ctx, "DELETE FROM workspace_members WHERE workspace_id=$1 AND principal_id=$2", r.WorkspaceID, revoked)
		return err
	}}
	deliverCreatedRoom(t, s, p)
	require.NotContains(t, p.sessions, revoked)
	require.Empty(t, p.groups)
	state, _ := transportState(t, s, r.ID, "room.created")
	require.Equal(t, "blocked", state)
}

func TestOutboxUnknownPublishIsNotRetried(t *testing.T) {
	s := testStore(t)
	owner, _, r := deliveryFixture(t, s)
	p := &recordingMessenger{}
	ctx := context.Background()
	deliverCreatedRoom(t, s, p)
	_, err := s.Send(ctx, owner, r.ID, domain.SendMessage{ActionID: "outbox-unknown-publish", Content: "one logical send"})
	require.NoError(t, err)
	p.publishHook = func(context.Context, domain.Message) error { return &transport.ProviderError{Unknown: true} }
	deliverCreatedRoom(t, s, p)
	state, _ := transportState(t, s, r.ID, "message.created")
	require.Equal(t, "unknown", state)
	ok, err := s.DispatchOne(ctx, p)
	require.NoError(t, err)
	require.False(t, ok)
	require.Len(t, p.messages, 1)
}

func TestOutboxReceiptSurvivesCallerCancellationAfterProviderSuccess(t *testing.T) {
	s := testStore(t)
	owner, _, r := deliveryFixture(t, s)
	p := &recordingMessenger{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	deliverCreatedRoom(t, s, p)
	_, err := s.Send(ctx, owner, r.ID, domain.SendMessage{ActionID: "outbox-late-receipt", Content: "already externally accepted"})
	require.NoError(t, err)
	p.publishHook = func(context.Context, domain.Message) error { cancel(); return nil }
	ok, err := s.DispatchOne(ctx, p)
	require.True(t, ok)
	require.NoError(t, err)
	state, receipt := transportState(t, s, r.ID, "message.created")
	require.Equal(t, "delivered", state)
	var result transport.Delivery
	require.NoError(t, json.Unmarshal([]byte(receipt), &result))
	require.Equal(t, 200, result.Code)
}
