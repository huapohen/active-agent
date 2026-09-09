package store

import (
	"context"
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/jackc/pgx/v5"
)

// Construct only from verified server authentication, never a request body.
// One form must be populated; a machine cannot supply an alternate principal.
type AccountReader struct {
	PrincipalID    string
	MachineIssuer  string
	MachineSubject string
}

type AccountQuery struct {
	After string
	Limit int
	RunID string
}

func singleLine(value string, maxRunes, maxBytes int) bool {
	if value == "" || !utf8.ValidString(value) || len(value) > maxBytes || utf8.RuneCountInString(value) > maxRunes {
		return false
	}
	for _, r := range value {
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) || r == '\u2028' || r == '\u2029' {
			return false
		}
	}
	return true
}

func normalizeProfileCommand(cmd domain.UpdateProfile) (domain.UpdateProfile, error) {
	cmd.DisplayName = strings.TrimSpace(cmd.DisplayName)
	if !validAction(cmd.ActionID) || !singleLine(cmd.DisplayName, 80, 320) || cmd.ExpectedVersion < 1 {
		return cmd, domain.ErrInvalid
	}
	return cmd, nil
}

func lockProfile(ctx context.Context, tx pgx.Tx, actor string) (domain.Profile, error) {
	var out domain.Profile
	var disabled bool
	err := tx.QueryRow(ctx, `SELECT id::text,kind,display_name,profile_version,disabled
FROM principals WHERE id=$1 FOR UPDATE`, actor).Scan(&out.Principal.ID, &out.Principal.Kind,
		&out.Principal.DisplayName, &out.Version, &disabled)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && disabled) {
		return out, domain.ErrForbidden
	}
	return out, err
}

// Profile effects take the principal write lock before Run/room locks. Merely
// upgrading the execution identity's SHARE lock after taking a room lock can
// deadlock with a message waiting for that room while holding the same principal.
// This lookup does not grant authority: executionIdentity subsequently rechecks
// the full current binding and exact persisted Run under its normal locks.
func lockMachineProfile(ctx context.Context, tx pgx.Tx, issuer, subject, expectedActor string) error {
	var actor string
	err := tx.QueryRow(ctx, `SELECT principal_id::text FROM executors WHERE issuer=$1 AND machine_subject=$2`, issuer, subject).Scan(&actor)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && actor != expectedActor) {
		return domain.ErrForbidden
	}
	if err != nil {
		return err
	}
	_, err = lockProfile(ctx, tx, actor)
	return err
}

func updateProfileTx(ctx context.Context, tx pgx.Tx, actor string, cmd domain.UpdateProfile) (domain.ProfileReceipt, error) {
	var out domain.ProfileReceipt
	var err error
	cmd, err = normalizeProfileCommand(cmd)
	if err != nil {
		return out, err
	}
	current, err := lockProfile(ctx, tx, actor)
	if err != nil {
		return out, err
	}
	digest := actionDigest("profile.update", struct {
		DisplayName     string
		ExpectedVersion int64
	}{cmd.DisplayName, cmd.ExpectedVersion})
	replay, err := readAction(ctx, tx, actor, cmd.ActionID, digest, &out)
	if err != nil {
		return out, err
	}
	if replay {
		out.Replayed = true
		return out, nil
	}
	if current.Version != cmd.ExpectedVersion {
		return out, domain.ErrProfileVersionConflict
	}
	out.Profile = current
	out.Principal.DisplayName = cmd.DisplayName
	err = tx.QueryRow(ctx, `UPDATE principals SET display_name=$2,profile_version=profile_version+1
WHERE id=$1 RETURNING profile_version`, actor, cmd.DisplayName).Scan(&out.Version)
	if err != nil {
		return out, err
	}
	if err = saveAction(ctx, tx, actor, cmd.ActionID, digest, out); err != nil {
		return out, err
	}
	// Name updates are canonical profile state; this event does not claim that
	// a transport provider has propagated or acknowledged the new name.
	if err = event(ctx, tx, "", actor, cmd.ActionID, "profile.updated", out.Profile, false); err != nil {
		return out, err
	}
	return out, nil
}

func (s *Store) UpdateProfile(ctx context.Context, actor string, cmd domain.UpdateProfile) (domain.ProfileReceipt, error) {
	if !executionUUIDs(actor) {
		return domain.ProfileReceipt{}, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return domain.ProfileReceipt{}, err
	}
	defer tx.Rollback(ctx)
	out, err := updateProfileTx(ctx, tx, actor, cmd)
	if err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}

// Current workspace and all requested Run source checks remain locked through
// the read. Run-less history/directory access does not depend on old Run status.
func accountAccess(ctx context.Context, tx pgx.Tx, reader AccountReader, runID string) (actor, workspace string, scopes map[string]bool, err error) {
	if reader.MachineIssuer != "" || reader.MachineSubject != "" {
		if reader.PrincipalID != "" || reader.MachineIssuer == "" || reader.MachineSubject == "" {
			return "", "", nil, domain.ErrInvalid
		}
		var binding ExecutorBinding
		if runID != "" {
			var run ExecutionRun
			binding, run, err = executionReadRun(ctx, tx, reader.MachineIssuer, reader.MachineSubject, runID)
			if err != nil {
				return "", "", nil, err
			}
			// The map comes only from canonical server-loaded context.
			scopes = map[string]bool{}
			storedScopes, e := executionScopes(run.Context)
			if e != nil {
				return "", "", nil, e
			}
			for _, origin := range storedScopes {
				scopes[origin.RoomID] = true
			}
		} else {
			binding, err = executorByMachine(ctx, tx, reader.MachineIssuer, reader.MachineSubject)
			if err != nil {
				return "", "", nil, err
			}
		}
		return binding.Principal.ID, binding.WorkspaceID, scopes, nil
	}
	if !executionUUIDs(reader.PrincipalID) || runID != "" {
		return "", "", nil, domain.ErrInvalid
	}
	_, err = lockPrincipal(ctx, tx, reader.PrincipalID)
	return reader.PrincipalID, "", nil, err
}

func (s *Store) ReadProfile(ctx context.Context, reader AccountReader, runID string) (domain.Profile, error) {
	var out domain.Profile
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	actor, _, _, err := accountAccess(ctx, tx, reader, runID)
	if err != nil {
		return out, err
	}
	err = tx.QueryRow(ctx, `SELECT id::text,kind,display_name,profile_version FROM principals WHERE id=$1 FOR SHARE`, actor).
		Scan(&out.Principal.ID, &out.Principal.Kind, &out.Principal.DisplayName, &out.Version)
	if err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}

func normalizeAccountQuery(q AccountQuery) (AccountQuery, error) {
	if q.Limit == 0 {
		q.Limit = 100
	}
	if q.After == "" {
		q.After = "00000000-0000-0000-0000-000000000000"
	}
	if !executionUUIDs(q.After) || q.Limit < 1 || q.Limit > 100 || (q.RunID != "" && !executionUUIDs(q.RunID)) {
		return q, domain.ErrInvalid
	}
	return q, nil
}

func (s *Store) Workspaces(ctx context.Context, reader AccountReader, q AccountQuery) (domain.WorkspacePage, error) {
	out := domain.WorkspacePage{Workspaces: []domain.Workspace{}}
	q, err := normalizeAccountQuery(q)
	if err != nil {
		return out, err
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	actor, workspace, _, err := accountAccess(ctx, tx, reader, q.RunID)
	if err != nil {
		return out, err
	}
	rows, err := tx.Query(ctx, `SELECT w.id::text,w.title,m.role,w.created_at
FROM workspaces w JOIN workspace_members m ON m.workspace_id=w.id
WHERE m.principal_id=$1 AND w.id>$2 AND ($3::text='' OR w.id=NULLIF($3,'')::uuid)
ORDER BY w.id LIMIT $4 FOR SHARE OF w,m`, actor, q.After, workspace, q.Limit+1)
	if err != nil {
		return out, err
	}
	for rows.Next() {
		var w domain.Workspace
		if err := rows.Scan(&w.ID, &w.Title, &w.Role, &w.CreatedAt); err != nil {
			rows.Close()
			return out, err
		}
		out.Workspaces = append(out.Workspaces, w)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return out, err
	}
	if len(out.Workspaces) > q.Limit {
		out.Workspaces = out.Workspaces[:q.Limit]
		out.Cursor = out.Workspaces[q.Limit-1].ID
	}
	return out, tx.Commit(ctx)
}

func (s *Store) WorkspaceMembers(ctx context.Context, reader AccountReader, workspace string, q AccountQuery) (domain.MemberPage, error) {
	return s.accountMembers(ctx, reader, workspace, "", q)
}

func (s *Store) RoomMembers(ctx context.Context, reader AccountReader, room string, q AccountQuery) (domain.MemberPage, error) {
	return s.accountMembers(ctx, reader, "", room, q)
}

func (s *Store) accountMembers(ctx context.Context, reader AccountReader, workspace, room string, q AccountQuery) (domain.MemberPage, error) {
	out := domain.MemberPage{Members: []domain.Member{}}
	if (workspace == "" && room == "") || (workspace != "" && !executionUUIDs(workspace)) || (room != "" && !executionUUIDs(room)) {
		return out, domain.ErrInvalid
	}
	q, err := normalizeAccountQuery(q)
	if err != nil {
		return out, err
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	actor, boundWorkspace, scopes, err := accountAccess(ctx, tx, reader, q.RunID)
	if err != nil {
		return out, err
	}
	if room != "" {
		if scopes != nil && !scopes[room] {
			return out, domain.ErrForbidden
		}
		r, _, e := roomAccess(ctx, tx, actor, room)
		if e != nil {
			return out, e
		}
		workspace = r.WorkspaceID
	}
	if boundWorkspace != "" && workspace != boundWorkspace {
		return out, domain.ErrForbidden
	}
	if _, err = workspaceAccess(ctx, tx, actor, workspace); err != nil {
		return out, err
	}
	var rows pgx.Rows
	if room != "" {
		rows, err = tx.Query(ctx, `SELECT p.id::text,p.kind,p.display_name,rm.role
FROM room_members rm JOIN principals p ON p.id=rm.principal_id
JOIN workspace_members wm ON wm.workspace_id=$2 AND wm.principal_id=p.id
WHERE rm.room_id=$1 AND p.id>$3 AND NOT p.disabled ORDER BY p.id LIMIT $4
FOR SHARE OF rm,p,wm`, room, workspace, q.After, q.Limit+1)
	} else {
		ids := []string{}
		for id := range scopes {
			ids = append(ids, id)
		}
		// Explicit Run directory reads do not enumerate colleagues unrelated to
		// its inherited rooms. Ordinary workspace reads retain full current ACL.
		rows, err = tx.Query(ctx, `SELECT p.id::text,p.kind,p.display_name,wm.role
FROM workspace_members wm JOIN principals p ON p.id=wm.principal_id
WHERE wm.workspace_id=$1 AND p.id>$2 AND NOT p.disabled
AND ($4::boolean OR EXISTS(SELECT 1 FROM room_members rm WHERE rm.principal_id=p.id AND rm.room_id=ANY($5::uuid[])))
ORDER BY p.id LIMIT $3 FOR SHARE OF wm,p`, workspace, q.After, q.Limit+1, scopes == nil, ids)
	}
	if err != nil {
		return out, err
	}
	for rows.Next() {
		var member domain.Member
		if err := rows.Scan(&member.PrincipalID, &member.Kind, &member.DisplayName, &member.Role); err != nil {
			rows.Close()
			return out, err
		}
		out.Members = append(out.Members, member)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return out, err
	}
	if len(out.Members) > q.Limit {
		out.Members = out.Members[:q.Limit]
		out.Cursor = out.Members[q.Limit-1].PrincipalID
	}
	return out, tx.Commit(ctx)
}
