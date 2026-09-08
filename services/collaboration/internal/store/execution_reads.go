package store

import (
	"context"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/jackc/pgx/v5"
)

const roomReadColumns = `r.id::text,r.workspace_id::text,r.title,r.kind,r.version,r.scope_epoch,r.stopped`

func executionReadRun(ctx context.Context, tx pgx.Tx, issuer, subject, runID string) (ExecutorBinding, ExecutionRun, error) {
	var b ExecutorBinding
	var run ExecutionRun
	if !executionUUIDs(runID) {
		return b, run, domain.ErrInvalid
	}
	// Authenticate before looking up execution metadata. Load the canonical
	// context, then reuse exactly the gateway identity and live-scope checks.
	var err error
	b, err = executorByMachine(ctx, tx, issuer, subject)
	if err != nil {
		return b, run, err
	}
	run, err = loadExecutionRun(ctx, tx, runID)
	if err != nil {
		return b, run, err
	}
	b, run, err = executionIdentity(ctx, tx, issuer, subject, run.Context)
	if err != nil {
		return b, run, err
	}
	stale, _, err := lockExecutionScopes(ctx, tx, run, b.Principal.ID)
	if err != nil {
		return b, run, err
	}
	if stale || executionPolicyStale(b, run) || run.Status != "running" {
		return b, run, domain.ErrStopped
	}
	return b, run, nil
}

func readExecutionMessages(ctx context.Context, tx pgx.Tx, room string, after int64) ([]domain.Message, error) {
	rows, err := tx.Query(ctx, `SELECT id::text,room_id::text,author_id::text,content,seq,created_at FROM messages WHERE room_id=$1 AND seq>$2 ORDER BY seq LIMIT 101`, room, after)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domain.Message{}
	for rows.Next() {
		var m domain.Message
		if err = rows.Scan(&m.ID, &m.RoomID, &m.AuthorID, &m.Content, &m.Seq, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}
func scanExecutionRooms(rows pgx.Rows) ([]domain.Room, error) {
	defer rows.Close()
	out := []domain.Room{}
	for rows.Next() {
		var r domain.Room
		if err := rows.Scan(&r.ID, &r.WorkspaceID, &r.Title, &r.Kind, &r.Version, &r.ScopeEpoch, &r.Stopped); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// Reads made on behalf of a Run retain all original authorization locks until
// the data has been read. A separate Check followed by Messages is insufficient.
func (s *Store) ExecutionMessages(ctx context.Context, issuer, subject, runID, roomID string, after int64) ([]domain.Message, error) {
	if !executionUUIDs(roomID) || after < 0 {
		return nil, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	_, run, err := executionReadRun(ctx, tx, issuer, subject, runID)
	if err != nil {
		return nil, err
	}
	scopes, err := executionScopes(run.Context)
	if err != nil {
		return nil, err
	}
	inside := false
	for _, scope := range scopes {
		if scope.RoomID == roomID {
			inside = true
		}
	}
	if !inside {
		return nil, domain.ErrForbidden
	}
	out, err := readExecutionMessages(ctx, tx, roomID, after)
	if err != nil {
		return nil, err
	}
	return out, tx.Commit(ctx)
}

func (s *Store) ExecutionRooms(ctx context.Context, issuer, subject, runID, after string) ([]domain.Room, error) {
	if after == "" {
		after = "00000000-0000-0000-0000-000000000000"
	}
	if !executionUUIDs(after) {
		return nil, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	_, run, err := executionReadRun(ctx, tx, issuer, subject, runID)
	if err != nil {
		return nil, err
	}
	scopes, err := executionScopes(run.Context)
	if err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(scopes))
	for _, scope := range scopes {
		ids = append(ids, scope.RoomID)
	}
	rows, err := tx.Query(ctx, "SELECT "+roomReadColumns+" FROM rooms r WHERE r.id=ANY($1::uuid[]) AND r.id>$2 ORDER BY r.id LIMIT 101", ids, after)
	if err != nil {
		return nil, err
	}
	out, err := scanExecutionRooms(rows)
	if err != nil {
		return nil, err
	}
	return out, tx.Commit(ctx)
}

// Unscoped account/history reads are allowed after a Run stops, but only in
// the workspace whose administrator admitted this executor. Sharing one Agent
// principal across workspaces must not expand a machine binding's authority.
func (s *Store) ExecutorMessages(ctx context.Context, issuer, subject, roomID string, after int64) ([]domain.Message, error) {
	if !executionUUIDs(roomID) || after < 0 {
		return nil, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	b, err := executorByMachine(ctx, tx, issuer, subject)
	if err != nil {
		return nil, err
	}
	room, _, err := roomAccess(ctx, tx, b.Principal.ID, roomID)
	if err != nil {
		return nil, err
	}
	if room.WorkspaceID != b.WorkspaceID {
		return nil, domain.ErrForbidden
	}
	out, err := readExecutionMessages(ctx, tx, roomID, after)
	if err != nil {
		return nil, err
	}
	return out, tx.Commit(ctx)
}

func (s *Store) ExecutorRooms(ctx context.Context, issuer, subject, after string) ([]domain.Room, error) {
	if after == "" {
		after = "00000000-0000-0000-0000-000000000000"
	}
	if !executionUUIDs(after) {
		return nil, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	b, err := executorByMachine(ctx, tx, issuer, subject)
	if err != nil {
		return nil, err
	}
	rows, err := tx.Query(ctx, "SELECT "+roomReadColumns+` FROM rooms r JOIN room_members m ON m.room_id=r.id
 WHERE r.workspace_id=$1 AND m.principal_id=$2 AND r.id>$3 ORDER BY r.id LIMIT 101 FOR SHARE OF r,m`, b.WorkspaceID, b.Principal.ID, after)
	if err != nil {
		return nil, err
	}
	out, err := scanExecutionRooms(rows)
	if err != nil {
		return nil, err
	}
	return out, tx.Commit(ctx)
}
