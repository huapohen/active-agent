package store

import (
	"context"
	"sort"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/transport"
)

const maxTransportCursor int64 = 9007199254740991

func emptyTransportArrivalPage(after int64) TransportArrivalPage {
	return TransportArrivalPage{Schema: "renji.transport.events.v1", Transport: "rongcloud", Mode: "trusted_development_bridge", Events: []TransportArrival{}, NextCursor: after, Status: TransportBridgeStatus{BridgeState: "unavailable"}}
}

// ExecutionTransportArrivals is a live execution read, not a history/audit
// bypass. All original scopes and the current machine binding remain locked
// through cursor admission and reads, including an empty/unconfigured result.
func (s *Store) ExecutionTransportArrivals(ctx context.Context, issuer, subject, runID string, after int64, limit int, bindings []transport.BridgeBinding) (TransportArrivalPage, error) {
	if after < 0 || after > maxTransportCursor || limit < 1 || limit > 100 || len(bindings) > 100 {
		return TransportArrivalPage{}, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return TransportArrivalPage{}, err
	}
	defer tx.Rollback(ctx)
	b, run, err := executionReadRun(ctx, tx, issuer, subject, runID)
	if err != nil {
		return TransportArrivalPage{}, err
	}
	scopes, err := executionScopes(run.Context)
	if err != nil {
		return TransportArrivalPage{}, err
	}
	inRun := make(map[string]bool, len(scopes))
	for _, scope := range scopes {
		inRun[scope.RoomID] = true
	}
	// Fixed deployment coverage must intersect this receiver's canonical Run.
	// A human bridge or the same Agent in another room/workspace adds nothing.
	ids, rooms := []string{}, []string{}
	covered, tuples := map[string]bool{}, map[string]bool{}
	for _, binding := range bindings {
		if !binding.Valid() || binding.ReceiverID != b.Principal.ID || !inRun[binding.RoomID] {
			continue
		}
		key := binding.ID + "/" + binding.RoomID
		if tuples[key] {
			continue
		}
		tuples[key] = true
		ids, rooms = append(ids, binding.ID), append(rooms, binding.RoomID)
		covered[binding.RoomID] = true
	}
	if after > 0 {
		var current bool
		err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM transport_inbox i JOIN rooms r ON r.id=i.room_id
WHERE i.id=$1 AND i.receiver_id=$2 AND NOT r.stopped AND i.observed_scope_epoch=r.scope_epoch
AND EXISTS(SELECT 1 FROM unnest($3::text[],$4::uuid[]) AS coverage(bridge_id,room_id)
WHERE coverage.bridge_id=i.bridge_id AND coverage.room_id=i.room_id))`, after, b.Principal.ID, ids, rooms).Scan(&current)
		if err != nil {
			return TransportArrivalPage{}, err
		}
		if !current {
			return TransportArrivalPage{}, domain.ErrInvalid
		}
	}
	out := emptyTransportArrivalPage(after)
	if len(ids) > 0 {
		out, err = readTransportArrivalPage(ctx, tx, b.Principal.ID, after, limit, ids, rooms, false)
		if err != nil {
			return TransportArrivalPage{}, err
		}
	}
	out.ReceiverID, out.RunID = b.Principal.ID, run.Context.RunID
	for room := range covered {
		out.CoveredRoomIDs = append(out.CoveredRoomIDs, room)
	}
	sort.Strings(out.CoveredRoomIDs)
	if err := tx.Commit(ctx); err != nil {
		return TransportArrivalPage{}, err
	}
	return out, nil
}
