package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/transport"
	"github.com/jackc/pgx/v5"
)

var ErrIngressAwaitingAcceptance = errors.New("transport_ingress_awaiting_acceptance")

type TransportArrival struct {
	Cursor      int64     `json:"cursor"`
	EventID     int64     `json:"event_id"`
	RoomID      string    `json:"room_id"`
	MessageID   string    `json:"message_id"`
	Kind        string    `json:"kind"`
	ProviderUID string    `json:"provider_uid"`
	ReceivedAt  time.Time `json:"received_at"`
}
type TransportBridgeStatus struct {
	BridgeState     string     `json:"bridge_state"`
	LastHeartbeatAt *time.Time `json:"last_heartbeat_at"`
	LastReceivedAt  *time.Time `json:"last_received_at"`
}
type TransportArrivalPage struct {
	Schema     string                `json:"schema"`
	Transport  string                `json:"transport"`
	Mode       string                `json:"mode"`
	Events     []TransportArrival    `json:"events"`
	NextCursor int64                 `json:"next_cursor"`
	HasMore    bool                  `json:"has_more"`
	Status     TransportBridgeStatus `json:"status"`
}

// RecordTransportIngress never makes a new canonical message or modifies an
// outbox outcome. A received SDK envelope must match the same accepted message
// UID, source event, payload, room, author and current authorization.
func (s *Store) RecordTransportIngress(ctx context.Context, binding transport.BridgeBinding, raw []byte) (TransportArrival, error) {
	var out TransportArrival
	if !binding.Valid() {
		return out, domain.ErrInvalid
	}
	in, err := transport.DecodeSDKReceived(raw)
	if err != nil || in.RoomID != binding.RoomID {
		return out, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	var claim deliveryClaim
	var eventID int64
	var status string
	var receiptRaw []byte
	selector := map[string]any{"id": in.MessageID}
	if in.Kind == "message.reaction_set" {
		selector = map[string]any{"message_id": in.MessageID, "version": in.Version}
	}
	selectorRaw, _ := json.Marshal(selector)
	rows, err := tx.Query(ctx, `SELECT o.id,e.id,e.room_id::text,e.principal_id::text,e.type,e.data,o.admitted_scope_epoch,COALESCE(o.execution_run_id::text,''),o.status,o.provider_receipt
FROM transport_outbox o JOIN events e ON e.id=o.event_id WHERE o.provider='rongcloud' AND e.room_id=$1 AND e.principal_id=$2 AND e.type=$3 AND e.data @> $4::jsonb ORDER BY o.id LIMIT 2 FOR SHARE OF o,e`, in.RoomID, in.AuthorID, in.Kind, selectorRaw)
	if err != nil {
		return out, err
	}
	count := 0
	for rows.Next() {
		count++
		err = rows.Scan(&claim.ID, &eventID, &claim.Room, &claim.Actor, &claim.Kind, &claim.Data, &claim.ScopeEpoch, &claim.ExecutionRunID, &status, &receiptRaw)
		if err != nil {
			break
		}
	}
	rows.Close()
	if err != nil {
		return out, err
	}
	if rows.Err() != nil {
		return out, rows.Err()
	}
	if count != 1 {
		return out, domain.ErrInvalid
	}
	if err = executionDeliveryAdmission(ctx, tx, claim); err != nil {
		return out, err
	}
	actor, epoch, stopped, err := deliveryMember(ctx, tx, in.RoomID, in.AuthorID)
	if err != nil {
		return out, err
	}
	if actor.Kind == "agent" && (stopped || claim.ScopeEpoch == nil || *claim.ScopeEpoch != epoch) {
		return out, domain.ErrStopped
	}
	receiver, _, stopped, err := deliveryMember(ctx, tx, in.RoomID, binding.ReceiverID)
	if err != nil {
		return out, err
	}
	if receiver.Kind == "agent" && stopped {
		return out, domain.ErrStopped
	}
	if in.Kind == "message.created" {
		var message domain.Message
		if json.Unmarshal(claim.Data, &message) != nil || message.ID != in.MessageID || message.RoomID != in.RoomID || message.AuthorID != in.AuthorID || message.Seq != in.Seq {
			return out, domain.ErrConflict
		}
		h := sha256.Sum256([]byte(message.Content))
		if hex.EncodeToString(h[:]) != in.ContentSHA256 {
			return out, domain.ErrConflict
		}
	} else {
		var reaction domain.ReactionReceipt
		if json.Unmarshal(claim.Data, &reaction) != nil || reaction.MessageID != in.MessageID || reaction.RoomID != in.RoomID || reaction.PrincipalID != in.AuthorID || reaction.Version != in.Version {
			return out, domain.ErrConflict
		}
	}
	if status == "pending" || status == "in_flight" || status == "unknown" {
		return out, ErrIngressAwaitingAcceptance
	}
	if status != "delivered" {
		return out, domain.ErrConflict
	}
	var receipt transport.Delivery
	if json.Unmarshal(receiptRaw, &receipt) != nil || receipt.Code != 200 || len(receipt.MessageUIDs) != 1 || receipt.MessageUIDs[0].GroupID != in.RoomID || receipt.MessageUIDs[0].MessageUID != in.ProviderUID {
		return out, domain.ErrConflict
	}
	// Serialize the stable receiver/UID tuple, including cross-event replay.
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, binding.ReceiverID+"/rongcloud/"+in.ProviderUID); err != nil {
		return out, err
	}
	err = tx.QueryRow(ctx, `SELECT id,event_id,room_id::text,message_id::text,kind,provider_uid,received_at FROM transport_inbox WHERE receiver_id=$1 AND (provider_uid=$2 OR event_id=$3)`, binding.ReceiverID, in.ProviderUID, eventID).Scan(&out.Cursor, &out.EventID, &out.RoomID, &out.MessageID, &out.Kind, &out.ProviderUID, &out.ReceivedAt)
	if err == nil {
		if out.EventID != eventID || out.RoomID != in.RoomID || out.MessageID != in.MessageID || out.Kind != in.Kind || out.ProviderUID != in.ProviderUID {
			return out, domain.ErrConflict
		}
		return out, tx.Commit(ctx)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return out, err
	}
	out = TransportArrival{EventID: eventID, RoomID: in.RoomID, MessageID: in.MessageID, Kind: in.Kind, ProviderUID: in.ProviderUID}
	err = tx.QueryRow(ctx, `INSERT INTO transport_inbox(bridge_id,receiver_id,room_id,message_id,event_id,provider_uid,kind,observed_scope_epoch,sdk_received_time,envelope_sha256) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING id,received_at`, binding.ID, binding.ReceiverID, in.RoomID, in.MessageID, eventID, in.ProviderUID, in.Kind, epoch, in.SDKReceivedTime, in.EnvelopeSHA256).Scan(&out.Cursor, &out.ReceivedAt)
	if err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}

func (s *Store) RecordTransportHeartbeat(ctx context.Context, b transport.BridgeBinding, state string, sequence int64) error {
	if !b.Valid() || (state != "connected" && state != "disconnected") || sequence < 1 || sequence > 9007199254740991 {
		return domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	receiver, _, stopped, err := deliveryMember(ctx, tx, b.RoomID, b.ReceiverID)
	if err != nil {
		return err
	}
	if receiver.Kind == "agent" && stopped {
		return domain.ErrStopped
	}
	updated, err := tx.Exec(ctx, `INSERT INTO transport_bridge_status(bridge_id,receiver_id,room_id,connection_state,heartbeat_seq) VALUES($1,$2,$3,$4,$5) ON CONFLICT(bridge_id) DO UPDATE SET connection_state=EXCLUDED.connection_state,heartbeat_at=clock_timestamp(),heartbeat_seq=EXCLUDED.heartbeat_seq WHERE transport_bridge_status.receiver_id=EXCLUDED.receiver_id AND transport_bridge_status.room_id=EXCLUDED.room_id AND transport_bridge_status.heartbeat_seq<EXCLUDED.heartbeat_seq`, b.ID, b.ReceiverID, b.RoomID, state, sequence)
	if err != nil {
		return err
	}
	if updated.RowsAffected() != 1 {
		return domain.ErrConflict
	}
	return tx.Commit(ctx)
}

// TransportArrivals only includes operator-configured bridges for this exact
// receiver, plus current source membership and an unchanged, unstopped epoch.
func (s *Store) TransportArrivals(ctx context.Context, actor string, after int64, limit int, bindings []transport.BridgeBinding) (TransportArrivalPage, error) {
	out := TransportArrivalPage{Schema: "renji.transport.events.v1", Transport: "rongcloud", Mode: "trusted_development_bridge", Events: []TransportArrival{}, NextCursor: after, Status: TransportBridgeStatus{BridgeState: "unavailable"}}
	if after < 0 || limit < 1 || limit > 100 || !executionUUIDs(actor) {
		return out, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	reader, err := lockPrincipal(ctx, tx, actor)
	if err != nil {
		return out, err
	}
	ids := []string{}
	rooms := []string{}
	for _, b := range bindings {
		if !b.Valid() || b.ReceiverID != actor {
			continue
		}
		_, _, stopped, e := deliveryMember(ctx, tx, b.RoomID, actor)
		if errors.Is(e, domain.ErrForbidden) || (reader.Kind == "agent" && stopped) {
			continue
		}
		if e != nil {
			return out, e
		}
		ids = append(ids, b.ID)
		rooms = append(rooms, b.RoomID)
	}
	if len(ids) == 0 {
		return out, tx.Commit(ctx)
	}
	rows, err := tx.Query(ctx, `SELECT i.id,i.event_id,i.room_id::text,i.message_id::text,i.kind,i.provider_uid,i.received_at FROM transport_inbox i JOIN rooms r ON r.id=i.room_id WHERE i.receiver_id=$1 AND EXISTS(SELECT 1 FROM unnest($2::text[],$5::uuid[]) AS coverage(bridge_id,room_id) WHERE coverage.bridge_id=i.bridge_id AND coverage.room_id=i.room_id) AND i.id>$3 AND ($6 OR (NOT r.stopped AND i.observed_scope_epoch=r.scope_epoch)) ORDER BY i.id LIMIT $4`, actor, ids, after, limit+1, rooms, reader.Kind == "human")
	if err != nil {
		return out, err
	}
	for rows.Next() {
		var a TransportArrival
		if err = rows.Scan(&a.Cursor, &a.EventID, &a.RoomID, &a.MessageID, &a.Kind, &a.ProviderUID, &a.ReceivedAt); err != nil {
			break
		}
		out.Events = append(out.Events, a)
	}
	rows.Close()
	if err != nil {
		return out, err
	}
	if rows.Err() != nil {
		return out, rows.Err()
	}
	if len(out.Events) > limit {
		out.HasMore = true
		out.Events = out.Events[:limit]
	}
	if len(out.Events) > 0 {
		out.NextCursor = out.Events[len(out.Events)-1].Cursor
	}
	var heartbeat *time.Time
	var connected bool
	err = tx.QueryRow(ctx, `SELECT max(heartbeat_at),COALESCE(bool_or(connection_state='connected' AND heartbeat_at>clock_timestamp()-interval '30 seconds'),false) FROM transport_bridge_status WHERE receiver_id=$1 AND EXISTS(SELECT 1 FROM unnest($2::text[],$3::uuid[]) AS coverage(bridge_id,room_id) WHERE coverage.bridge_id=transport_bridge_status.bridge_id AND coverage.room_id=transport_bridge_status.room_id)`, actor, ids, rooms).Scan(&heartbeat, &connected)
	if err != nil {
		return out, err
	}
	out.Status.LastHeartbeatAt = heartbeat
	if heartbeat != nil {
		out.Status.BridgeState = "disconnected"
	}
	if connected {
		out.Status.BridgeState = "connected"
	}
	err = tx.QueryRow(ctx, `SELECT max(i.received_at) FROM transport_inbox i JOIN rooms r ON r.id=i.room_id WHERE i.receiver_id=$1 AND EXISTS(SELECT 1 FROM unnest($2::text[],$3::uuid[]) AS coverage(bridge_id,room_id) WHERE coverage.bridge_id=i.bridge_id AND coverage.room_id=i.room_id) AND ($4 OR (NOT r.stopped AND i.observed_scope_epoch=r.scope_epoch))`, actor, ids, rooms, reader.Kind == "human").Scan(&out.Status.LastReceivedAt)
	if err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}
