package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/transport"
	"github.com/jackc/pgx/v5"
)

type Messenger interface {
	Session(context.Context, domain.Principal) (transport.Session, error)
	CreateGroup(context.Context, domain.Room, []string) error
	Publish(context.Context, domain.Message) (transport.Delivery, error)
}

const (
	deliveryLease     = 30 * time.Second
	deliveryHeartbeat = 5 * time.Second
	// A group can register 101 members. Bound the whole operation rather than
	// assuming its duration equals one provider HTTP request's timeout.
	deliveryTimeout = 15 * time.Minute
)

var ErrDeliveryClaimLost = errors.New("transport delivery claim lost")

type deliveryClaim struct {
	ID             int64
	Token          string
	Room           string
	Actor          string
	Kind           string
	Data           []byte
	ScopeEpoch     *int64
	ExecutionRunID string
}

func (s *Store) claimDelivery(ctx context.Context) (deliveryClaim, error) {
	var claim deliveryClaim
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return claim, err
	}
	defer tx.Rollback(ctx)
	err = tx.QueryRow(ctx, `SELECT o.id,e.room_id::text,e.principal_id::text,e.type,e.data,o.admitted_scope_epoch,coalesce(o.execution_run_id::text,'')
FROM transport_outbox o JOIN events e ON e.id=o.event_id
WHERE o.status='pending' AND NOT EXISTS(
 SELECT 1 FROM transport_outbox old JOIN events prior ON prior.id=old.event_id
 WHERE prior.room_id=e.room_id AND old.id<o.id AND old.status<>'delivered'
 AND NOT (old.status='blocked' AND prior.type='message.created'))
ORDER BY o.id FOR UPDATE OF o SKIP LOCKED LIMIT 1`).Scan(&claim.ID, &claim.Room, &claim.Actor, &claim.Kind, &claim.Data, &claim.ScopeEpoch, &claim.ExecutionRunID)
	if err != nil {
		return claim, err
	}
	claim.Token = uuid.NewString()
	_, err = tx.Exec(ctx, `UPDATE transport_outbox SET status='in_flight',claim_token=$2,
lease_expires_at=now()+($3 * interval '1 second'),attempts=attempts+1,updated_at=now() WHERE id=$1`, claim.ID, claim.Token, int(deliveryLease/time.Second))
	if err != nil {
		return claim, err
	}
	return claim, tx.Commit(ctx)
}

// Renewals cannot resurrect expired or quarantined claims. A new attempt gets a
// different token; the former worker must not issue another provider request.
func (s *Store) renewDeliveryClaim(ctx context.Context, claim deliveryClaim) error {
	updated, err := s.Pool.Exec(ctx, `UPDATE transport_outbox SET lease_expires_at=now()+($3 * interval '1 second'),updated_at=now()
WHERE id=$1 AND claim_token=$2 AND status='in_flight' AND lease_expires_at>now()`, claim.ID, claim.Token, int(deliveryLease/time.Second))
	if err != nil {
		return err
	}
	if updated.RowsAffected() != 1 {
		return ErrDeliveryClaimLost
	}
	return nil
}

func (s *Store) keepDeliveryClaim(ctx context.Context, cancel context.CancelFunc, claim deliveryClaim) func() error {
	done := make(chan struct{})
	finished := make(chan struct{})
	var heartbeatErr error
	go func() {
		defer close(finished)
		ticker := time.NewTicker(deliveryHeartbeat)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ctx.Done():
				return
			case <-ticker.C:
				renewCtx, stop := context.WithTimeout(ctx, deliveryLease/2)
				err := s.renewDeliveryClaim(renewCtx, claim)
				stop()
				if err != nil {
					heartbeatErr = err
					cancel()
					return
				}
			}
		}
	}()
	return func() error { close(done); <-finished; return heartbeatErr }
}

// Current member/principal rows are held through one bounded provider call.
// Revocation linearizes before this admission or after the in-flight request.
// Heartbeats update a different row and remain independent of these locks.
func (s *Store) withDeliveryAdmission(ctx context.Context, claim deliveryClaim, candidate string, call func(context.Context, pgx.Tx, domain.Principal) error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	// Renew before taking a transaction connection. This remains usable with
	// a small pool and cannot deadlock waiting for a second connection we hold.
	if err := s.renewDeliveryClaim(ctx, claim); err != nil {
		return err
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err = executionDeliveryAdmission(ctx, tx, claim); err != nil {
		return err
	}
	actor, epoch, stopped, err := deliveryMember(ctx, tx, claim.Room, claim.Actor)
	if err != nil {
		return err
	}
	if actor.Kind == "agent" && (stopped || claim.ScopeEpoch == nil || *claim.ScopeEpoch != epoch) {
		return domain.ErrStopped
	}
	p := actor
	if candidate != "" && candidate != claim.Actor {
		p, _, _, err = deliveryMember(ctx, tx, claim.Room, candidate)
		if err != nil {
			return err
		}
	}
	var current bool
	// Authorization locks may have waited: transaction-start now() would accept
	// a lease that expired while waiting. Fence against the actual call time.
	if err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM transport_outbox WHERE id=$1 AND claim_token=$2 AND status='in_flight' AND lease_expires_at>clock_timestamp())`, claim.ID, claim.Token).Scan(&current); err != nil {
		return err
	}
	if !current {
		return ErrDeliveryClaimLost
	}
	// This transaction only holds authorization locks. Its cleanup must not
	// turn an acknowledged provider success into an unknown outcome.
	return call(ctx, tx, p)
}

func deliveryMember(ctx context.Context, tx pgx.Tx, room, principal string) (domain.Principal, int64, bool, error) {
	var p domain.Principal
	var epoch int64
	var stopped, disabled bool
	err := tx.QueryRow(ctx, `SELECT p.id::text,p.kind,p.display_name,p.disabled,r.scope_epoch,r.stopped
FROM rooms r JOIN room_members m ON m.room_id=r.id JOIN principals p ON p.id=m.principal_id
JOIN workspace_members wm ON wm.workspace_id=r.workspace_id AND wm.principal_id=p.id
WHERE r.id=$1 AND p.id=$2 FOR SHARE OF r,m,p,wm`, room, principal).Scan(&p.ID, &p.Kind, &p.DisplayName, &disabled, &epoch, &stopped)
	if errors.Is(err, pgx.ErrNoRows) || disabled {
		return p, epoch, stopped, domain.ErrForbidden
	}
	return p, epoch, stopped, err
}

func currentDeliveryMembers(ctx context.Context, tx pgx.Tx, room string) ([]domain.Principal, error) {
	rows, err := tx.Query(ctx, `SELECT p.id::text,p.kind,p.display_name FROM rooms r
JOIN room_members m ON m.room_id=r.id JOIN principals p ON p.id=m.principal_id
JOIN workspace_members wm ON wm.workspace_id=r.workspace_id AND wm.principal_id=p.id
WHERE r.id=$1 AND NOT p.disabled ORDER BY p.id FOR SHARE OF r,m,p,wm`, room)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	members := []domain.Principal{}
	for rows.Next() {
		var p domain.Principal
		if err = rows.Scan(&p.ID, &p.Kind, &p.DisplayName); err != nil {
			return nil, err
		}
		members = append(members, p)
	}
	return members, rows.Err()
}

func (s *Store) deliver(ctx context.Context, claim deliveryClaim, provider Messenger) (any, error) {
	switch claim.Kind {
	case "message.created":
		var m domain.Message
		if err := json.Unmarshal(claim.Data, &m); err != nil || m.RoomID != claim.Room || m.AuthorID != claim.Actor {
			return nil, domain.ErrInvalid
		}
		var receipt transport.Delivery
		err := s.withDeliveryAdmission(ctx, claim, "", func(callCtx context.Context, _ pgx.Tx, _ domain.Principal) error {
			var err error
			receipt, err = provider.Publish(callCtx, m)
			return err
		})
		return receipt, err
	case "room.created":
		var r domain.Room
		if err := json.Unmarshal(claim.Data, &r); err != nil || r.ID != claim.Room {
			return nil, domain.ErrInvalid
		}
		var members []domain.Principal
		err := s.withDeliveryAdmission(ctx, claim, "", func(callCtx context.Context, tx pgx.Tx, _ domain.Principal) error {
			var err error
			members, err = currentDeliveryMembers(callCtx, tx, claim.Room)
			return err
		})
		if err != nil {
			return nil, err
		}
		registered := map[string]bool{}
		for _, p := range members {
			err = s.withDeliveryAdmission(ctx, claim, p.ID, func(callCtx context.Context, _ pgx.Tx, member domain.Principal) error {
				_, err := provider.Session(callCtx, member)
				return err
			})
			if err != nil {
				return nil, err
			}
			registered[p.ID] = true
		}
		err = s.withDeliveryAdmission(ctx, claim, "", func(callCtx context.Context, tx pgx.Tx, _ domain.Principal) error {
			current, err := currentDeliveryMembers(callCtx, tx, claim.Room)
			if err != nil {
				return err
			}
			if len(current) == 0 {
				return domain.ErrForbidden
			}
			ids := make([]string, 0, len(current))
			for _, p := range current {
				if !registered[p.ID] {
					return domain.ErrConflict
				}
				ids = append(ids, p.ID)
			}
			return provider.CreateGroup(callCtx, r, ids)
		})
		return map[string]any{"code": 200}, err
	default:
		return nil, domain.ErrInvalid
	}
}

func (s *Store) finishDelivery(ctx context.Context, claim deliveryClaim, status string, receipt any) error {
	raw, err := json.Marshal(receipt)
	if err != nil {
		return err
	}
	// The SAME attempt may resolve its quarantined unknown outcome with a late
	// real response, without issuing a new request. A new claim or an explicit
	// final reconciliation cannot be overwritten by the former worker.
	updated, err := s.Pool.Exec(ctx, `UPDATE transport_outbox SET status=$3,provider_receipt=$4,lease_expires_at=NULL,updated_at=now()
WHERE id=$1 AND claim_token=$2 AND status IN('in_flight','unknown')`, claim.ID, claim.Token, status, raw)
	if err != nil {
		return err
	}
	if updated.RowsAffected() != 1 {
		return ErrDeliveryClaimLost
	}
	return nil
}

// Unknown outcomes are never retried automatically. Confirmed blocked messages
// do not prevent human intervention; an uncreated/unknown group still blocks
// its dependent transport messages.
func (s *Store) DispatchOne(parent context.Context, provider Messenger) (bool, error) {
	claim, err := s.claimDelivery(parent)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	ctx, cancel := context.WithTimeout(parent, deliveryTimeout)
	stopHeartbeat := s.keepDeliveryClaim(ctx, cancel, claim)
	receipt, deliveryErr := s.deliver(ctx, claim, provider)
	heartbeatErr := stopHeartbeat()
	cancel()
	status := "delivered"
	if deliveryErr != nil {
		status = "unknown"
		var pe *transport.ProviderError
		switch {
		case errors.Is(deliveryErr, domain.ErrForbidden), errors.Is(deliveryErr, domain.ErrStopped):
			status = "blocked"
		case errors.Is(deliveryErr, domain.ErrInvalid), errors.Is(deliveryErr, domain.ErrConflict):
			status = "rejected"
		case errors.As(deliveryErr, &pe) && !pe.Unknown:
			status = "rejected"
		}
		code := "provider_outcome_unknown"
		if errors.Is(deliveryErr, domain.ErrStopped) {
			code = "scope_stopped_or_stale"
		}
		if errors.Is(deliveryErr, domain.ErrForbidden) {
			code = "membership_revoked"
		}
		if errors.Is(deliveryErr, ErrDeliveryClaimLost) {
			code = "claim_lost"
		}
		receipt = map[string]any{"state": status, "code": code}
	}
	// Persist actual observations even after request cancellation/later stop.
	saveCtx, stopSave := context.WithTimeout(context.WithoutCancel(parent), 5*time.Second)
	defer stopSave()
	if err = s.finishDelivery(saveCtx, claim, status, receipt); err != nil {
		return true, err
	}
	if heartbeatErr != nil {
		return true, fmt.Errorf("transport heartbeat failed: %w", heartbeatErr)
	}
	return true, nil
}

// Timeout quarantines a claim; it never schedules another attempt. Retaining
// the token lets its owner record a late, acknowledged result.
func (s *Store) QuarantineStaleDeliveries(ctx context.Context) error {
	_, err := s.Pool.Exec(ctx, `UPDATE transport_outbox SET status='unknown',updated_at=now()
WHERE status='in_flight' AND (lease_expires_at<now() OR (lease_expires_at IS NULL AND updated_at<now()-interval '5 minutes'))`)
	return err
}
