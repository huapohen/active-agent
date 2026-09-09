package store

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"reflect"
	"sort"
	"strings"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/jackc/pgx/v5"
)

const invitationCreate = "workspace.invitation.create"
const invitationRevoke = "workspace.invitation.revoke"
const invitationAccept = "workspace.invitation.accept"

type invitationAuthority struct {
	Context         harness.RunContext `json:"context"`
	WorkspaceID     string             `json:"workspace_id"`
	ExecutorVersion int64              `json:"executor_version"`
	PolicyVersion   int64              `json:"policy_version"`
	Issuer          string             `json:"issuer"`
	Subject         string             `json:"subject"`
}
type invitationRow struct {
	domain.WorkspaceInvitation
	CodeHash    string
	CreatorRole string
	Authority   *invitationAuthority
}
type invitationActionRecord struct {
	Kind    string                   `json:"kind"`
	RunID   string                   `json:"run_id,omitempty"`
	Receipt domain.InvitationReceipt `json:"receipt"`
}
type invitationActor struct {
	ID      string
	Binding *ExecutorBinding
	Run     *ExecutionRun
}

func invitationCodeHash(code string) (string, error) {
	code = strings.TrimSpace(code)
	if len(code) != 47 || !strings.HasPrefix(code, "rji_") {
		return "", domain.ErrInvalid
	}
	raw, e := base64.RawURLEncoding.DecodeString(code[4:])
	if e != nil || len(raw) != 32 || base64.RawURLEncoding.EncodeToString(raw) != code[4:] {
		return "", domain.ErrInvalid
	}
	h := sha256.Sum256([]byte(code))
	return hex.EncodeToString(h[:]), nil
}
func validInvitationAction(action string) bool {
	return validAction(action) && singleLine(action, 160, 160)
}

const invitationColumns = `id::text,workspace_id::text,created_by::text,create_action_id,role,
 CASE WHEN accepted_at IS NOT NULL THEN 'accepted' WHEN revoked_at IS NOT NULL THEN 'revoked' WHEN expires_at<=clock_timestamp() THEN 'expired' ELSE 'pending' END,
 created_at,expires_at,coalesce(accepted_by::text,''),accepted_at,revoked_at,coalesce(issued_run_id::text,''),code_hash,issued_authority,creator_role`

func scanInvitation(row pgx.Row) (invitationRow, error) {
	var v invitationRow
	var authority []byte
	e := row.Scan(&v.ID, &v.WorkspaceID, &v.CreatedBy, &v.CreateActionID, &v.Role, &v.Status, &v.CreatedAt, &v.ExpiresAt, &v.AcceptedBy, &v.AcceptedAt, &v.RevokedAt, &v.IssuedRunID, &v.CodeHash, &authority, &v.CreatorRole)
	if errors.Is(e, pgx.ErrNoRows) {
		return v, domain.ErrInvitationNotFound
	}
	if e != nil {
		return v, e
	}
	if len(authority) > 0 {
		var a invitationAuthority
		if json.Unmarshal(authority, &a) != nil {
			return v, domain.ErrForbidden
		}
		v.Authority = &a
	}
	return v, nil
}
func loadInvitation(ctx context.Context, tx pgx.Tx, id string, lock bool) (invitationRow, error) {
	sql := "SELECT " + invitationColumns + " FROM workspace_invitations WHERE id=$1"
	if lock {
		sql += " FOR UPDATE"
	}
	return scanInvitation(tx.QueryRow(ctx, sql, id))
}

// Both participants' Run locks and the union of inherited source rooms are
// acquired in stable order. The invitee's new grant never alters either context.
func invitationAdmission(ctx context.Context, tx pgx.Tx, reader AccountReader, runID string, issued *invitationAuthority, requireIssuer bool, action string) (invitationActor, error) {
	var a invitationActor
	machine := reader.MachineIssuer != "" || reader.MachineSubject != ""
	if machine {
		if reader.PrincipalID != "" || reader.MachineIssuer == "" || reader.MachineSubject == "" || !executionUUIDs(runID) {
			return a, domain.ErrInvalid
		}
		b, e := executorByMachine(ctx, tx, reader.MachineIssuer, reader.MachineSubject)
		if e != nil {
			return a, e
		}
		a.ID = b.Principal.ID
		a.Binding = &b
	} else {
		if !executionUUIDs(reader.PrincipalID) || runID != "" {
			return a, domain.ErrInvalid
		}
		p, e := lockPrincipal(ctx, tx, reader.PrincipalID)
		if e != nil {
			return a, e
		}
		// Machine credentials must retain issuer/subject and Run admission, not use
		// a bare Agent UUID through this human account form.
		if p.Kind != "human" {
			return a, domain.ErrForbidden
		}
		a.ID = p.ID
	}
	ids := []string{}
	if machine {
		ids = append(ids, runID)
	}
	if requireIssuer && issued != nil {
		ids = append(ids, issued.Context.RunID)
	}
	sort.Strings(ids)
	runs := map[string]ExecutionRun{}
	for _, id := range ids {
		if _, ok := runs[id]; ok {
			continue
		}
		r, e := loadExecutionRun(ctx, tx, id)
		if e != nil {
			return a, e
		}
		runs[id] = r
	}
	type check struct {
		run   ExecutionRun
		actor string
	}
	checks := []check{}
	if machine {
		r := runs[runID]
		b := *a.Binding
		if r.Context.Validate() != nil || r.Context.PrincipalID != a.ID || r.Context.ExecutorID != b.ExecutorID || r.WorkspaceID != b.WorkspaceID {
			return a, domain.ErrForbidden
		}
		if r.Status != "running" || executionPolicyStale(b, r) {
			return a, domain.ErrStopped
		}
		a.Run = &r
		checks = append(checks, check{r, a.ID})
	}
	if requireIssuer && issued != nil {
		r := runs[issued.Context.RunID]
		if !reflect.DeepEqual(r.Context, issued.Context) || r.WorkspaceID != issued.WorkspaceID || r.ExecutorVersion != issued.ExecutorVersion || r.PolicyVersion != issued.PolicyVersion {
			return a, domain.ErrForbidden
		}
		b, e := executorByID(ctx, tx, issued.Context.ExecutorID, false)
		if e != nil {
			return a, e
		}
		if b.Issuer != issued.Issuer || b.MachineSubject != issued.Subject || b.Principal.ID != r.Context.PrincipalID || b.WorkspaceID != r.WorkspaceID {
			return a, domain.ErrForbidden
		}
		if (r.Status != "running" && r.Status != "completed") || executionPolicyStale(b, r) {
			return a, domain.ErrStopped
		}
		checks = append(checks, check{r, b.Principal.ID})
	}
	// Existing Send/ExecuteAction lock action before rooms (and execution
	// locks Run before action). Keep the same order across this shared namespace.
	if action != "" {
		if _, e := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", a.ID+"/"+action); e != nil {
			return a, e
		}
	}
	type scopeCheck struct {
		room, actor, workspace string
		epoch                  int64
	}
	all := []scopeCheck{}
	for _, c := range checks {
		scopes, e := executionScopes(c.run.Context)
		if e != nil {
			return a, e
		}
		for _, s := range scopes {
			all = append(all, scopeCheck{s.RoomID, c.actor, c.run.WorkspaceID, s.Epoch})
		}
	}
	sort.Slice(all, func(i, j int) bool {
		if all[i].room == all[j].room {
			return all[i].actor < all[j].actor
		}
		return all[i].room < all[j].room
	})
	for _, s := range all {
		r, _, e := roomAccess(ctx, tx, s.actor, s.room)
		if e != nil {
			return a, e
		}
		if r.WorkspaceID != s.workspace {
			return a, domain.ErrForbidden
		}
		if r.Stopped || r.ScopeEpoch != s.epoch {
			return a, domain.ErrStopped
		}
	}
	return a, nil
}
func invitationAdmin(ctx context.Context, tx pgx.Tx, actor, workspace string) error {
	role, e := workspaceAccess(ctx, tx, actor, workspace)
	if e != nil {
		return e
	}
	if !adminRole(role) {
		return domain.ErrForbidden
	}
	return nil
}
func (s *Store) CreateWorkspaceInvitation(ctx context.Context, reader AccountReader, workspace string, cmd domain.CreateWorkspaceInvitation) (domain.InvitationReceipt, error) {
	if cmd.ExpiresInSeconds == 0 {
		cmd.ExpiresInSeconds = 86400
	}
	if !executionUUIDs(workspace) || cmd.ExpiresInSeconds < 60 || cmd.ExpiresInSeconds > 604800 {
		return domain.InvitationReceipt{}, domain.ErrInvalid
	}
	return s.invitationAction(ctx, reader, cmd.RunID, cmd.ActionID, invitationCreate, workspace, "", "", cmd.ExpiresInSeconds)
}
func (s *Store) RevokeWorkspaceInvitation(ctx context.Context, reader AccountReader, workspace, id string, cmd domain.RevokeWorkspaceInvitation) (domain.InvitationReceipt, error) {
	if !executionUUIDs(workspace, id) {
		return domain.InvitationReceipt{}, domain.ErrInvalid
	}
	return s.invitationAction(ctx, reader, cmd.RunID, cmd.ActionID, invitationRevoke, workspace, id, "", 0)
}
func (s *Store) AcceptWorkspaceInvitation(ctx context.Context, reader AccountReader, cmd domain.AcceptWorkspaceInvitation) (domain.InvitationReceipt, error) {
	hash, e := invitationCodeHash(cmd.Code)
	if e != nil {
		return domain.InvitationReceipt{}, e
	}
	return s.invitationAction(ctx, reader, cmd.RunID, cmd.ActionID, invitationAccept, "", "", hash, 0)
}

func (s *Store) invitationAction(ctx context.Context, reader AccountReader, runID, action, kind, workspace, id, codeHash string, ttl int64) (domain.InvitationReceipt, error) {
	var out domain.InvitationReceipt
	if !validInvitationAction(action) || ((reader.MachineIssuer != "" || reader.MachineSubject != "") && !validExecutionID(action)) {
		return out, domain.ErrInvalid
	}
	tx, e := s.Pool.Begin(ctx)
	if e != nil {
		return out, e
	}
	defer tx.Rollback(ctx)
	var initial invitationRow
	if kind == invitationAccept {
		initial, e = scanInvitation(tx.QueryRow(ctx, "SELECT "+invitationColumns+" FROM workspace_invitations WHERE code_hash=$1", codeHash))
		if errors.Is(e, domain.ErrInvitationNotFound) {
			return out, domain.ErrForbidden
		}
		if e != nil {
			return out, e
		}
		id = initial.ID
		workspace = initial.WorkspaceID
	} else if kind == invitationRevoke {
		initial, e = loadInvitation(ctx, tx, id, false)
		if errors.Is(e, domain.ErrInvitationNotFound) {
			return out, domain.ErrForbidden
		}
		if e != nil {
			return out, e
		}
		if initial.WorkspaceID != workspace {
			return out, domain.ErrForbidden
		}
	}
	// Only an unconsumed grant derives new authority from the issuer. Replaying
	// an already committed acceptance does not reissue a grant after origin stop.
	a, e := invitationAdmission(ctx, tx, reader, runID, initial.Authority, kind == invitationAccept && initial.Status == "pending", action)
	if e != nil {
		return out, e
	}
	if kind != invitationAccept {
		if a.Binding != nil && a.Binding.WorkspaceID != workspace {
			return out, domain.ErrForbidden
		}
		if e = invitationAdmin(ctx, tx, a.ID, workspace); e != nil {
			return out, e
		}
	}
	canonical, _ := json.Marshal(struct {
		WorkspaceID  string `json:"workspace_id"`
		InvitationID string `json:"invitation_id,omitempty"`
		CodeHash     string `json:"code_hash,omitempty"`
		TTL          int64  `json:"expires_in_seconds,omitempty"`
	}{workspace, id, codeHash, ttl})
	digest := actionDigest(kind, struct {
		RunID   string
		Payload json.RawMessage
	}{runID, canonical})
	var prior invitationActionRecord
	replay, e := readAction(ctx, tx, a.ID, action, digest, &prior)
	if e != nil {
		return out, e
	}
	if replay {
		if prior.Kind != kind || prior.RunID != runID {
			return out, domain.ErrConflict
		}
		current, e := loadInvitation(ctx, tx, prior.Receipt.Invitation.ID, true)
		if e != nil {
			return out, e
		}
		if kind == invitationAccept {
			if current.AcceptedBy != a.ID {
				return out, domain.ErrForbidden
			}
			if _, e = workspaceAccess(ctx, tx, a.ID, current.WorkspaceID); e != nil {
				return out, e
			}
		}
		out = prior.Receipt
		out.Invitation = current.WorkspaceInvitation
		out.Replayed = true
		out.Code = ""
		out.CodeAvailable = false
		return out, tx.Commit(ctx)
	}
	// The action ID namespace also spans older execution routes.
	var collision bool
	if e = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM execution_actions x JOIN execution_runs r ON r.id=x.run_id WHERE r.principal_id=$1 AND x.action_id=$2)`, a.ID, action).Scan(&collision); e != nil {
		return out, e
	}
	if collision {
		return out, domain.ErrConflict
	}
	var current invitationRow
	if kind != invitationCreate {
		current, e = loadInvitation(ctx, tx, id, true)
		if e != nil {
			return out, e
		}
		if current.WorkspaceID != workspace || current.CodeHash != initial.CodeHash || !reflect.DeepEqual(current.Authority, initial.Authority) {
			return out, domain.ErrConflict
		}
	}
	out = domain.InvitationReceipt{WorkspaceID: workspace, PrincipalID: a.ID, Role: "member"}
	switch kind {
	case invitationCreate:
		random := make([]byte, 32)
		if _, e = rand.Read(random); e != nil {
			return out, e
		}
		code := "rji_" + base64.RawURLEncoding.EncodeToString(random)
		hash, _ := invitationCodeHash(code)
		var authority any
		issuedRun := ""
		if a.Run != nil {
			issuedRun = a.Run.Context.RunID
			authority = invitationAuthority{a.Run.Context, a.Run.WorkspaceID, a.Run.ExecutorVersion, a.Run.PolicyVersion, a.Binding.Issuer, a.Binding.MachineSubject}
		}
		rawAuthority, _ := json.Marshal(authority)
		if authority == nil {
			rawAuthority = nil
		}
		id = uuid.NewString()
		current, e = scanInvitation(tx.QueryRow(ctx, `INSERT INTO workspace_invitations(id,workspace_id,created_by,create_action_id,code_hash,expires_at,issued_run_id,issued_authority,creator_role) VALUES($1,$2,$3,$4,$5,clock_timestamp()+($6::bigint*interval '1 second'),NULLIF($7,'')::uuid,$8,(SELECT role FROM workspace_members WHERE workspace_id=$2 AND principal_id=$3)) RETURNING `+invitationColumns, id, workspace, a.ID, action, hash, ttl, issuedRun, rawAuthority))
		if e != nil {
			return out, e
		}
		out.Invitation = current.WorkspaceInvitation
		out.Code = code
		out.CodeAvailable = true
	case invitationRevoke:
		if current.Status == "accepted" {
			return out, domain.ErrInvitationUsed
		}
		if current.Status == "revoked" {
			return out, domain.ErrInvitationRevoked
		}
		current, e = scanInvitation(tx.QueryRow(ctx, `UPDATE workspace_invitations SET revoked_at=clock_timestamp(),revoked_by=$2 WHERE id=$1 RETURNING `+invitationColumns, id, a.ID))
		if e != nil {
			return out, e
		}
		out.Invitation = current.WorkspaceInvitation
	case invitationAccept:
		if current.Status == "accepted" {
			return out, domain.ErrInvitationUsed
		}
		if current.Status == "revoked" {
			return out, domain.ErrInvitationRevoked
		}
		if current.Status == "expired" {
			return out, domain.ErrInvitationExpired
		}
		if e = invitationAdmin(ctx, tx, current.CreatedBy, workspace); e != nil {
			return out, e
		}
		if current.Authority != nil && (current.Authority.Context.PrincipalID != current.CreatedBy || current.Authority.WorkspaceID != workspace || current.Authority.Context.RunID != current.IssuedRunID) {
			return out, domain.ErrForbidden
		}
		grant, e := tx.Exec(ctx, `INSERT INTO workspace_members(workspace_id,principal_id,role) VALUES($1,$2,'member') ON CONFLICT DO NOTHING`, workspace, a.ID)
		if e != nil {
			return out, e
		}
		out.AlreadyMember = grant.RowsAffected() == 0
		out.Role, e = workspaceAccess(ctx, tx, a.ID, workspace)
		if e != nil {
			return out, e
		}
		current, e = scanInvitation(tx.QueryRow(ctx, `UPDATE workspace_invitations SET accepted_by=$2,accepted_at=clock_timestamp(),accepted_run_id=NULLIF($3,'')::uuid WHERE id=$1 AND expires_at>clock_timestamp() RETURNING `+invitationColumns, id, a.ID, runID))
		if errors.Is(e, domain.ErrInvitationNotFound) {
			return out, domain.ErrInvitationExpired
		}
		if e != nil {
			return out, e
		}
		out.Invitation = current.WorkspaceInvitation
	default:
		return out, domain.ErrInvalid
	}
	stored := out
	stored.Code = ""
	stored.CodeAvailable = false
	record := invitationActionRecord{kind, runID, stored}
	if e = saveAction(ctx, tx, a.ID, action, digest, record); e != nil {
		return out, e
	}
	if e = event(ctx, tx, "", a.ID, action, map[string]string{invitationCreate: "workspace.invitation.created", invitationRevoke: "workspace.invitation.revoked", invitationAccept: "workspace.invitation.accepted"}[kind], map[string]any{"workspace_id": workspace, "issued_run_id": current.IssuedRunID, "accepting_run_id": runID, "receipt": stored}, false); e != nil {
		return out, e
	}
	if a.Run != nil {
		result, _ := json.Marshal(stored)
		result, e = executionJSON(result)
		if e != nil {
			return out, e
		}
		receipt := harness.Receipt{ActionID: action, Status: "succeeded", Result: result}
		raw, _ := json.Marshal(receipt)
		_, e = tx.Exec(ctx, `INSERT INTO execution_actions(run_id,action_id,request_hash,action_type,payload,receipt) VALUES($1,$2,$3,$4,$5,$6)`, runID, action, digest, kind, canonical, raw)
		if e != nil {
			return out, e
		}
		if e = event(ctx, tx, a.Run.Context.RoomID, a.ID, action, "execution.action.committed", map[string]any{"run_id": runID, "executor_id": a.Binding.ExecutorID, "receipt": receipt}, false); e != nil {
			return out, e
		}
	}
	if e = tx.Commit(ctx); e != nil {
		return domain.InvitationReceipt{}, e
	}
	return out, nil
}

func (s *Store) WorkspaceInvitations(ctx context.Context, reader AccountReader, workspace string, q AccountQuery) (domain.InvitationPage, error) {
	out := domain.InvitationPage{Invitations: []domain.WorkspaceInvitation{}}
	if (reader.MachineIssuer != "" || reader.MachineSubject != "") && !executionUUIDs(q.RunID) {
		return out, domain.ErrInvalid
	}
	if !executionUUIDs(workspace) {
		return out, domain.ErrInvalid
	}
	q, e := normalizeAccountQuery(q)
	if e != nil {
		return out, e
	}
	tx, e := s.Pool.Begin(ctx)
	if e != nil {
		return out, e
	}
	defer tx.Rollback(ctx)
	actor, bound, _, e := accountAccess(ctx, tx, reader, q.RunID)
	if e != nil {
		return out, e
	}
	if bound != "" && bound != workspace {
		return out, domain.ErrForbidden
	}
	if e = invitationAdmin(ctx, tx, actor, workspace); e != nil {
		return out, e
	}
	rows, e := tx.Query(ctx, "SELECT "+invitationColumns+" FROM workspace_invitations WHERE workspace_id=$1 AND id>$2 ORDER BY id LIMIT $3 FOR SHARE", workspace, q.After, q.Limit+1)
	if e != nil {
		return out, e
	}
	for rows.Next() {
		v, e := scanInvitation(rows)
		if e != nil {
			rows.Close()
			return out, e
		}
		out.Invitations = append(out.Invitations, v.WorkspaceInvitation)
	}
	rows.Close()
	if e = rows.Err(); e != nil {
		return out, e
	}
	if len(out.Invitations) > q.Limit {
		out.Invitations = out.Invitations[:q.Limit]
		out.Cursor = out.Invitations[q.Limit-1].ID
	}
	return out, tx.Commit(ctx)
}

func (s *Store) ReadWorkspaceInvitationAction(ctx context.Context, reader AccountReader, action, runID string) (domain.InvitationActionReceipt, error) {
	var out domain.InvitationActionReceipt
	if !validInvitationAction(action) {
		return out, domain.ErrInvalid
	}
	tx, e := s.Pool.Begin(ctx)
	if e != nil {
		return out, e
	}
	defer tx.Rollback(ctx)
	a, e := invitationAdmission(ctx, tx, reader, runID, nil, false, "")
	if e != nil {
		return out, e
	}
	var raw []byte
	e = tx.QueryRow(ctx, "SELECT receipt FROM actions WHERE principal_id=$1 AND action_id=$2", a.ID, action).Scan(&raw)
	if errors.Is(e, pgx.ErrNoRows) {
		return out, domain.ErrInvitationNotFound
	}
	if e != nil {
		return out, e
	}
	var r invitationActionRecord
	if json.Unmarshal(raw, &r) != nil || (r.Kind != invitationCreate && r.Kind != invitationAccept && r.Kind != invitationRevoke) || r.RunID != runID {
		return out, domain.ErrInvitationNotFound
	}
	v, e := loadInvitation(ctx, tx, r.Receipt.Invitation.ID, false)
	if e != nil {
		return out, e
	}
	if r.Kind == invitationAccept {
		if v.AcceptedBy != a.ID {
			return out, domain.ErrForbidden
		}
		_, e = workspaceAccess(ctx, tx, a.ID, v.WorkspaceID)
	} else {
		if a.Binding != nil && a.Binding.WorkspaceID != v.WorkspaceID {
			return out, domain.ErrForbidden
		}
		e = invitationAdmin(ctx, tx, a.ID, v.WorkspaceID)
	}
	if e != nil {
		return out, e
	}
	r.Receipt.Invitation = v.WorkspaceInvitation
	r.Receipt.Code = ""
	r.Receipt.CodeAvailable = false
	r.Receipt.Replayed = true
	out = domain.InvitationActionReceipt{ActionID: action, Kind: r.Kind, Receipt: r.Receipt}
	return out, tx.Commit(ctx)
}
