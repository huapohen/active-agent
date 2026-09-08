package store

import (
	"context"
	"encoding/json"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/jackc/pgx/v5"
	"time"
)

// Construct only from authenticated HTTP/machine-verifier context, never JSON.
// Audit shares the same current role/membership rules for human and Agent.
// Execution reads additionally require this exact live executor and old scopes.
type EvidenceReader struct {
	PrincipalID    string
	MachineIssuer  string
	MachineSubject string
}
type EvidenceQuery struct {
	After   int64  `json:"after"`
	Through *int64 `json:"through,omitempty"`
	Limit   int    `json:"limit,omitempty"`
	Mode    string `json:"mode,omitempty"`
}
type ExecutionEvidenceEntry struct {
	Seq            int64           `json:"seq"`
	Kind           string          `json:"kind"`
	ObjectID       string          `json:"object_id"`
	Data           json.RawMessage `json:"data"`
	RecordedAt     time.Time       `json:"recorded_at"`
	LegacySnapshot bool            `json:"legacy_snapshot"`
}
type ExecutionEvidencePage struct {
	Run     ExecutionRun             `json:"run"`
	Mode    string                   `json:"mode"`
	Through int64                    `json:"through"`
	Cursor  int64                    `json:"cursor"`
	HasMore bool                     `json:"has_more"`
	Entries []ExecutionEvidenceEntry `json:"entries"`
}

func evidenceAccess(ctx context.Context, tx pgx.Tx, reader EvidenceReader, runID, mode string) (ExecutionRun, string, error) {
	var out ExecutionRun
	if !executionUUIDs(runID) || (mode != "audit" && mode != "execution") {
		return out, "", domain.ErrInvalid
	}
	var b ExecutorBinding
	actor := reader.PrincipalID
	machine := reader.MachineIssuer != "" || reader.MachineSubject != ""
	if machine {
		if actor != "" || reader.MachineIssuer == "" || reader.MachineSubject == "" {
			return out, "", domain.ErrInvalid
		}
		var err error
		b, err = executorByMachine(ctx, tx, reader.MachineIssuer, reader.MachineSubject)
		if err != nil {
			return out, "", err
		}
		actor = b.Principal.ID
	} else {
		if !executionUUIDs(actor) || mode == "execution" {
			return out, "", domain.ErrInvalid
		}
		if _, err := lockPrincipal(ctx, tx, actor); err != nil {
			return out, "", err
		}
	}
	var err error
	out, err = loadExecutionRun(ctx, tx, runID)
	if err != nil {
		return out, "", err
	}
	if machine && out.WorkspaceID != b.WorkspaceID {
		return out, "", domain.ErrForbidden
	}
	stale, _, err := lockExecutionScopes(ctx, tx, out, actor)
	if err != nil {
		return out, "", err
	}
	if mode == "execution" {
		if out.Context.ExecutorID != b.ExecutorID || out.Context.PrincipalID != b.Principal.ID {
			return out, "", domain.ErrForbidden
		}
		if stale || executionPolicyStale(b, out) || out.Status != "running" {
			return out, "", domain.ErrStopped
		}
	}
	return out, actor, nil
}

// The run lock serializes its evidence cursor with all actions/events and
// transport snapshots. Each continuation rechecks all source memberships.
// Through freezes entries, not the separately labelled current Run status.
func (s *Store) ReadExecutionEvidence(ctx context.Context, reader EvidenceReader, runID string, q EvidenceQuery) (ExecutionEvidencePage, error) {
	var out ExecutionEvidencePage
	if q.Mode == "" {
		q.Mode = "audit"
	}
	if q.Limit == 0 {
		q.Limit = 100
	}
	if q.After < 0 || q.Limit < 1 || q.Limit > 100 || (q.Through != nil && (*q.Through < q.After || *q.Through < 0)) {
		return out, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	out.Run, _, err = evidenceAccess(ctx, tx, reader, runID, q.Mode)
	if err != nil {
		return out, err
	}
	var latest int64
	if err = tx.QueryRow(ctx, "SELECT evidence_seq FROM execution_runs WHERE id=$1", runID).Scan(&latest); err != nil {
		return out, err
	}
	out.Through = latest
	if q.Through != nil {
		out.Through = *q.Through
	}
	if out.Through > latest || q.After > out.Through {
		return out, domain.ErrInvalid
	}
	out.Mode = q.Mode
	out.Cursor = q.After
	out.Entries = []ExecutionEvidenceEntry{}
	rows, err := tx.Query(ctx, `SELECT seq,kind,object_id,data,recorded_at,legacy_snapshot FROM execution_evidence_entries WHERE run_id=$1 AND seq>$2 AND seq<=$3 ORDER BY seq LIMIT $4`, runID, q.After, out.Through, q.Limit+1)
	if err != nil {
		return out, err
	}
	size := 0
	for rows.Next() {
		var e ExecutionEvidenceEntry
		if err = rows.Scan(&e.Seq, &e.Kind, &e.ObjectID, &e.Data, &e.RecordedAt, &e.LegacySnapshot); err != nil {
			rows.Close()
			return out, err
		}
		// Never truncate an event; one maximum-size event always fits a page.
		if len(out.Entries) == q.Limit || (len(out.Entries) > 0 && size+len(e.Data) > 1500000) {
			out.HasMore = true
			break
		}
		e.Data, err = executionJSON(e.Data)
		if err != nil {
			rows.Close()
			return out, err
		}
		size += len(e.Data)
		out.Entries = append(out.Entries, e)
		out.Cursor = e.Seq
	}
	if err = rows.Err(); err != nil {
		rows.Close()
		return out, err
	}
	rows.Close()
	return out, tx.Commit(ctx)
}
