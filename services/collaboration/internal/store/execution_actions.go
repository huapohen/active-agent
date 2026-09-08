package store

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"reflect"
	"strings"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/jackc/pgx/v5"
)

func validExecutionID(id string) bool {
	b, err := hex.DecodeString(id)
	return err == nil && len(b) == 32
}
func executionJSON(raw json.RawMessage) (json.RawMessage, error) {
	if len(raw) == 0 || !json.Valid(raw) {
		return nil, domain.ErrInvalid
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	var value any
	if err := d.Decode(&value); err != nil {
		return nil, domain.ErrInvalid
	}
	out, err := json.Marshal(value)
	return out, err
}

// Effects are typed and canonicalized before admission. All source scopes,
// the action, its reaction/message mutation and Outbox link commit together.
func (s *Store) ExecuteAction(ctx context.Context, issuer, subject string, rc harness.RunContext, a harness.Action) (harness.Receipt, error) {
	var out harness.Receipt
	if !validExecutionID(a.ID) || len(a.Payload) > 60000 {
		return out, domain.ErrInvalid
	}
	var sendPayload struct {
		RoomID  string `json:"room_id,omitempty"`
		Content string `json:"content"`
		ReplyTo string `json:"reply_to,omitempty"`
	}
	var reactionPayload struct {
		RoomID    string `json:"room_id,omitempty"`
		MessageID string `json:"message_id"`
		Emoji     string `json:"emoji"`
		Active    *bool  `json:"active"`
	}
	var canonical []byte
	var room string
	d := json.NewDecoder(bytes.NewReader(a.Payload))
	d.DisallowUnknownFields()
	switch a.Type {
	case "message.send":
		if d.Decode(&sendPayload) != nil || d.Decode(new(any)) != io.EOF || strings.TrimSpace(sendPayload.Content) == "" || len(sendPayload.Content) > 8192 || (sendPayload.ReplyTo != "" && !executionUUIDs(sendPayload.ReplyTo)) {
			return out, domain.ErrInvalid
		}
		if sendPayload.RoomID == "" {
			sendPayload.RoomID = rc.RoomID
		}
		room = sendPayload.RoomID
		canonical, _ = json.Marshal(sendPayload)
	case "reaction.set":
		if d.Decode(&reactionPayload) != nil || d.Decode(new(any)) != io.EOF || reactionPayload.Active == nil || !executionUUIDs(reactionPayload.MessageID) || !s.validReactionEmoji(reactionPayload.Emoji) {
			return out, domain.ErrInvalid
		}
		if reactionPayload.RoomID == "" {
			reactionPayload.RoomID = rc.RoomID
		}
		room = reactionPayload.RoomID
		canonical, _ = json.Marshal(reactionPayload)
	default:
		return out, domain.ErrInvalid
	}
	if room != rc.RoomID {
		return out, domain.ErrForbidden
	}
	digest := actionDigest("execution.action", struct {
		RunID, Type string
		Payload     json.RawMessage
	}{rc.RunID, a.Type, canonical})
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	b, run, err := executionIdentity(ctx, tx, issuer, subject, rc)
	if err != nil {
		return out, err
	}
	// Same lock used by Send: an action submitted through a different native
	// route cannot race or be laundered into a new execution receipt.
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", b.Principal.ID+"/"+a.ID); err != nil {
		return out, err
	}
	stale, _, err := lockExecutionScopes(ctx, tx, run, b.Principal.ID)
	if err != nil {
		return out, err
	}
	if stale || executionPolicyStale(b, run) || run.Status != "running" {
		return out, domain.ErrStopped
	}
	var prior string
	var raw []byte
	err = tx.QueryRow(ctx, "SELECT request_hash,receipt FROM execution_actions WHERE run_id=$1 AND action_id=$2", rc.RunID, a.ID).Scan(&prior, &raw)
	if err == nil {
		if prior != digest {
			return out, domain.ErrConflict
		}
		if err = json.Unmarshal(raw, &out); err != nil {
			return out, err
		}
		// PostgreSQL jsonb reorders keys and whitespace. Return the same canonical
		// receipt bytes as the original commit across process restarts/retries.
		out.Result, err = executionJSON(out.Result)
		if err != nil {
			return out, err
		}
		return out, tx.Commit(ctx)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return out, err
	}
	var collision bool
	if err = tx.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM actions WHERE principal_id=$1 AND action_id=$2)", b.Principal.ID, a.ID).Scan(&collision); err != nil {
		return out, err
	}
	if collision {
		return out, domain.ErrConflict
	}
	var result []byte
	var messageID, eventType string
	switch a.Type {
	case "message.send":
		receipt, sendErr := sendTx(ctx, tx, b.Principal.ID, rc.RoomID, domain.SendMessage{ActionID: a.ID, Content: sendPayload.Content, ScopeEpoch: &rc.ScopeEpoch, ReplyTo: sendPayload.ReplyTo})
		if sendErr != nil {
			return out, sendErr
		}
		messageID = receipt.Message.ID
		eventType = "message.created"
		result, _ = json.Marshal(map[string]any{"message_id": messageID, "room_id": receipt.Message.RoomID, "seq": receipt.Message.Seq, "canonical_status": "committed", "transport_status": "pending"})
	case "reaction.set":
		receipt, reactionErr := s.reactionSetTx(ctx, tx, b.Principal.ID, rc.RoomID, reactionPayload.MessageID, domain.SetReaction{ActionID: a.ID, Emoji: reactionPayload.Emoji, Active: *reactionPayload.Active, ScopeEpoch: &rc.ScopeEpoch})
		if reactionErr != nil {
			return out, reactionErr
		}
		messageID = receipt.MessageID
		eventType = "message.reaction_set"
		result, _ = json.Marshal(map[string]any{"reaction": receipt, "message_id": messageID, "room_id": receipt.RoomID, "canonical_status": "committed", "transport_status": "pending"})
	}
	// Success is canonical PostgreSQL commit, not provider acknowledgement.
	result, err = executionJSON(result)
	if err != nil {
		return out, err
	}
	out = harness.Receipt{ActionID: a.ID, Status: "succeeded", Result: result}
	raw, _ = json.Marshal(out)
	_, err = tx.Exec(ctx, `INSERT INTO execution_actions(run_id,action_id,request_hash,action_type,payload,receipt,message_id) VALUES($1,$2,$3,$4,$5,$6,$7)`, rc.RunID, a.ID, digest, a.Type, canonical, raw, messageID)
	if err != nil {
		return out, err
	}
	updated, err := tx.Exec(ctx, `UPDATE transport_outbox o SET execution_run_id=$1 FROM events e WHERE o.event_id=e.id AND e.principal_id=$2 AND e.action_id=$3 AND e.type=$4`, rc.RunID, b.Principal.ID, a.ID, eventType)
	if err != nil {
		return out, err
	}
	if updated.RowsAffected() != 1 {
		return out, domain.ErrConflict
	}
	if err = event(ctx, tx, rc.RoomID, b.Principal.ID, a.ID, "execution.action.committed", map[string]any{"run_id": rc.RunID, "executor_id": b.ExecutorID, "receipt": out}, false); err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}

var executionEventTypes = map[string]bool{
	"stage.input": true, "stage.planned": true, "model.output": true, "agent.output": true, "tool.result": true,
	"action.succeeded": true, "action.rejected": true, "action.running": true, "action.unknown": true,
	"run.stopped": true, "run.completed": true, "run.failed": true, "run.reconciliation_required": true,
}

// Appending evidence never invokes an action. It may describe a late result
// after stop, but keeps identity/current membership checks and cannot revive a
// stopped run. Action results must match an existing canonical receipt exactly.
func (s *Store) AppendExecutionEvent(ctx context.Context, issuer, subject string, rc harness.RunContext, e harness.Event) error {
	if !validExecutionID(e.ID) || !executionEventTypes[e.Type] || e.Stage < 0 || e.Stage > 32 || len(e.AgentPath) > 1024 || len(e.Data) > 1100000 {
		return domain.ErrInvalid
	}
	if len(e.Data) == 0 {
		e.Data = json.RawMessage(`{}`)
	}
	canonical, err := executionJSON(e.Data)
	if err != nil {
		return err
	}
	e.Data = canonical
	digest := actionDigest("execution.event", e)
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	b, run, err := executionIdentity(ctx, tx, issuer, subject, rc)
	if err != nil {
		return err
	}
	stale, _, err := lockExecutionScopes(ctx, tx, run, b.Principal.ID)
	if err != nil {
		return err
	}
	postStop := stale || executionPolicyStale(b, run) || run.Status != "running"
	if e.Type == "stage.input" {
		if postStop {
			return domain.ErrStopped
		}
		var input harness.StageInput
		d := json.NewDecoder(bytes.NewReader(e.Data))
		d.DisallowUnknownFields()
		if d.Decode(&input) != nil || d.Decode(new(any)) != io.EOF || input.Stage != e.Stage || input.Stage < 0 || input.Stage >= 32 || input.Attempt < 1 || input.Attempt > 1000 || len(input.PreviousSummary) > 8000 || len(input.Receipts) > 128 {
			return domain.ErrInvalid
		}
		if !reflect.DeepEqual(input.Context, run.Context) {
			return domain.ErrForbidden
		}
		if input.Goal != run.Goal {
			return domain.ErrConflict
		}
		seen := map[string]bool{}
		for _, receipt := range input.Receipts {
			if !validExecutionID(receipt.ActionID) || seen[receipt.ActionID] {
				return domain.ErrInvalid
			}
			seen[receipt.ActionID] = true
			var stored []byte
			if err = tx.QueryRow(ctx, "SELECT receipt FROM execution_actions WHERE run_id=$1 AND action_id=$2", rc.RunID, receipt.ActionID).Scan(&stored); errors.Is(err, pgx.ErrNoRows) {
				return domain.ErrForbidden
			} else if err != nil {
				return err
			}
			raw, _ := json.Marshal(receipt)
			expected, _ := executionJSON(stored)
			actual, _ := executionJSON(raw)
			if !bytes.Equal(expected, actual) {
				return domain.ErrConflict
			}
		}
	}
	var prior string
	err = tx.QueryRow(ctx, "SELECT request_hash FROM execution_events WHERE run_id=$1 AND event_id=$2", rc.RunID, e.ID).Scan(&prior)
	if err == nil {
		if prior != digest {
			return domain.ErrConflict
		}
		return tx.Commit(ctx)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	if strings.HasPrefix(e.Type, "action.") {
		var receipt harness.Receipt
		if json.Unmarshal(e.Data, &receipt) != nil || e.Type != "action."+receipt.Status {
			return domain.ErrInvalid
		}
		var stored []byte
		err = tx.QueryRow(ctx, "SELECT receipt FROM execution_actions WHERE run_id=$1 AND action_id=$2", rc.RunID, receipt.ActionID).Scan(&stored)
		if errors.Is(err, pgx.ErrNoRows) {
			return domain.ErrForbidden
		}
		if err != nil {
			return err
		}
		normalized, _ := executionJSON(stored)
		if !bytes.Equal(normalized, e.Data) {
			return domain.ErrConflict
		}
	}
	raw, _ := json.Marshal(e)
	_, err = tx.Exec(ctx, "INSERT INTO execution_events(run_id,event_id,request_hash,event) VALUES($1,$2,$3,$4)", rc.RunID, e.ID, digest, raw)
	if err != nil {
		return err
	}
	if err = event(ctx, tx, rc.RoomID, b.Principal.ID, e.ID, "execution.evidence", map[string]any{"run_id": rc.RunID, "executor_id": b.ExecutorID, "post_stop": postStop, "event": e}, false); err != nil {
		return err
	}
	next := run.Status
	if run.Status == "running" {
		if postStop {
			next = "stopped"
		} else if strings.HasPrefix(e.Type, "run.") {
			next = strings.TrimPrefix(e.Type, "run.")
		}
	}
	if next != run.Status {
		if _, err = tx.Exec(ctx, "UPDATE execution_runs SET status=$2 WHERE id=$1", rc.RunID, next); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}
