package store

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/jackc/pgx/v5"
)

type CreateExecutionRunCommand struct {
	ActionID    string `json:"action_id"`
	ExecutorID  string `json:"executor_id"`
	RoomID      string `json:"room_id"`
	ScopeEpoch  int64  `json:"scope_epoch"`
	ParentRunID string `json:"parent_run_id,omitempty"`
	Goal        string `json:"goal"`
}

type ExecutionRun struct {
	Context         harness.RunContext `json:"context"`
	WorkspaceID     string             `json:"workspace_id"`
	ExecutorVersion int64              `json:"executor_version"`
	PolicyVersion   int64              `json:"policy_version"`
	ParentRunID     string             `json:"parent_run_id,omitempty"`
	Goal            string             `json:"goal"`
	Status          string             `json:"status"`
	CreatedBy       string             `json:"created_by"`
	CreatedAt       time.Time          `json:"created_at"`
}

func loadExecutionRun(ctx context.Context, tx pgx.Tx, id string) (ExecutionRun, error) {
	var run ExecutionRun
	var raw []byte
	err := tx.QueryRow(ctx, `SELECT context,workspace_id::text,executor_version,policy_version,coalesce(parent_run_id::text,''),goal,status,created_by::text,created_at FROM execution_runs WHERE id=$1 FOR UPDATE`, id).Scan(&raw, &run.WorkspaceID, &run.ExecutorVersion, &run.PolicyVersion, &run.ParentRunID, &run.Goal, &run.Status, &run.CreatedBy, &run.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return run, domain.ErrForbidden
	}
	if err != nil {
		return run, err
	}
	err = json.Unmarshal(raw, &run.Context)
	return run, err
}

func executionScopes(rc harness.RunContext) ([]harness.Scope, error) {
	if err := rc.Validate(); err != nil {
		return nil, domain.ErrInvalid
	}
	byRoom := map[string]int64{rc.RoomID: rc.ScopeEpoch}
	for _, scope := range rc.OriginScopes {
		byRoom[scope.RoomID] = scope.Epoch
	}
	out := make([]harness.Scope, 0, len(byRoom))
	for room, epoch := range byRoom {
		if !executionUUIDs(room) {
			return nil, domain.ErrInvalid
		}
		out = append(out, harness.Scope{RoomID: room, Epoch: epoch})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].RoomID < out[j].RoomID })
	return out, nil
}

// Lock every source room in a stable order. The locks are retained through the
// action transaction (or one provider request); a source cannot stop between
// this admission and the protected effect.
func lockExecutionScopes(ctx context.Context, tx pgx.Tx, run ExecutionRun, actor string) (bool, map[string]string, error) {
	scopes, err := executionScopes(run.Context)
	if err != nil {
		return false, nil, err
	}
	stale := false
	roles := map[string]string{}
	for _, scope := range scopes {
		r, role, e := roomAccess(ctx, tx, actor, scope.RoomID)
		if e != nil {
			return false, nil, e
		}
		if r.WorkspaceID != run.WorkspaceID {
			return false, nil, domain.ErrForbidden
		}
		roles[r.ID] = role
		if r.Stopped || r.ScopeEpoch != scope.Epoch {
			stale = true
		}
	}
	return stale, roles, nil
}

func executionPolicyStale(b ExecutorBinding, run ExecutionRun) bool {
	return !b.ProactiveEnabled || b.Version != run.ExecutorVersion || b.PolicyVersion != run.PolicyVersion || b.RuntimeVersion != run.Context.RuntimeVersion || b.WorkflowVersion != run.Context.WorkflowVersion
}

func (s *Store) CreateExecutionRun(ctx context.Context, actor string, cmd CreateExecutionRunCommand) (ExecutionRun, error) {
	var out ExecutionRun
	var parentRun *ExecutionRun
	if !validAction(cmd.ActionID) || !executionUUIDs(actor, cmd.ExecutorID, cmd.RoomID) || cmd.ScopeEpoch < 1 || strings.TrimSpace(cmd.Goal) == "" || len(cmd.Goal) > 60000 || (cmd.ParentRunID != "" && !executionUUIDs(cmd.ParentRunID)) {
		return out, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	if _, err = lockPrincipal(ctx, tx, actor); err != nil {
		return out, err
	}
	b, err := executorByID(ctx, tx, cmd.ExecutorID, false)
	if err != nil {
		return out, err
	}
	if !b.ProactiveEnabled {
		return out, domain.ErrStopped
	}
	digest := actionDigest("execution.run.create", cmd)
	replay, err := readAction(ctx, tx, actor, cmd.ActionID, digest, &out)
	if err != nil {
		return out, err
	}
	if replay {
		out, err = loadExecutionRun(ctx, tx, out.Context.RunID)
		if err != nil {
			return out, err
		}
	} else {
		out = ExecutionRun{Context: harness.RunContext{PrincipalID: b.Principal.ID, ExecutorID: b.ExecutorID, RunID: uuid.NewString(), RoomID: cmd.RoomID, ScopeEpoch: cmd.ScopeEpoch, RuntimeVersion: b.RuntimeVersion, WorkflowVersion: b.WorkflowVersion}, WorkspaceID: b.WorkspaceID, ExecutorVersion: b.Version, PolicyVersion: b.PolicyVersion, ParentRunID: cmd.ParentRunID, Goal: cmd.Goal, Status: "running", CreatedBy: actor}
		if cmd.ParentRunID != "" {
			parent, e := loadExecutionRun(ctx, tx, cmd.ParentRunID)
			if e != nil {
				return out, e
			}
			if parent.WorkspaceID != b.WorkspaceID || parent.Status != "running" {
				return out, domain.ErrForbidden
			}
			parentBinding, e := executorByID(ctx, tx, parent.Context.ExecutorID, false)
			if e != nil {
				return out, e
			}
			if executionPolicyStale(parentBinding, parent) {
				return out, domain.ErrStopped
			}
			parentRun = &parent
			inherited, e := executionScopes(parent.Context)
			if e != nil {
				return out, e
			}
			for _, scope := range inherited {
				if scope.RoomID == cmd.RoomID {
					if scope.Epoch != cmd.ScopeEpoch {
						return out, domain.ErrStopped
					}
					continue
				}
				out.Context.OriginScopes = append(out.Context.OriginScopes, scope)
			}
		}
	}
	if out.Context.Validate() != nil {
		return out, domain.ErrInvalid
	}
	// Both the requesting administrator and the executing Agent must currently
	// belong to every inherited source, preventing delegation from laundering ACLs.
	stale, roles, err := lockExecutionScopes(ctx, tx, out, actor)
	if err != nil {
		return out, err
	}
	if actor != b.Principal.ID && !adminRole(roles[cmd.RoomID]) {
		return out, domain.ErrForbidden
	}
	if parentRun != nil {
		if actor != parentRun.Context.PrincipalID && !adminRole(roles[parentRun.Context.RoomID]) {
			return out, domain.ErrForbidden
		}
		parentStale, _, e := lockExecutionScopes(ctx, tx, *parentRun, parentRun.Context.PrincipalID)
		if e != nil {
			return out, e
		}
		if parentStale {
			return out, domain.ErrStopped
		}
	}
	agentStale, _, err := lockExecutionScopes(ctx, tx, out, b.Principal.ID)
	if err != nil {
		return out, err
	}
	if stale || agentStale || executionPolicyStale(b, out) || out.Status != "running" {
		return out, domain.ErrStopped
	}
	if replay {
		return out, tx.Commit(ctx)
	}
	raw, _ := json.Marshal(out.Context)
	var parent any
	if cmd.ParentRunID != "" {
		parent = cmd.ParentRunID
	}
	err = tx.QueryRow(ctx, `INSERT INTO execution_runs(id,executor_id,principal_id,workspace_id,executor_version,policy_version,parent_run_id,context,goal,created_by) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING created_at`, out.Context.RunID, b.ExecutorID, b.Principal.ID, b.WorkspaceID, b.Version, b.PolicyVersion, parent, raw, out.Goal, actor).Scan(&out.CreatedAt)
	if err != nil {
		return out, err
	}
	if err = saveAction(ctx, tx, actor, cmd.ActionID, digest, out); err != nil {
		return out, err
	}
	if err = event(ctx, tx, out.Context.RoomID, actor, cmd.ActionID, "execution.run.created", out, false); err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}

func executionIdentity(ctx context.Context, tx pgx.Tx, issuer, subject string, rc harness.RunContext) (ExecutorBinding, ExecutionRun, error) {
	var b ExecutorBinding
	var run ExecutionRun
	if rc.Validate() != nil || !executionUUIDs(rc.PrincipalID, rc.ExecutorID, rc.RunID, rc.RoomID) {
		return b, run, domain.ErrInvalid
	}
	b, err := executorByMachine(ctx, tx, issuer, subject)
	if err != nil {
		return b, run, err
	}
	if b.ExecutorID != rc.ExecutorID || b.Principal.ID != rc.PrincipalID {
		return b, run, domain.ErrForbidden
	}
	run, err = loadExecutionRun(ctx, tx, rc.RunID)
	if err != nil {
		return b, run, err
	}
	if run.WorkspaceID != b.WorkspaceID || !reflect.DeepEqual(rc, run.Context) {
		return b, run, domain.ErrForbidden
	}
	return b, run, nil
}

func (s *Store) CheckExecution(ctx context.Context, issuer, subject string, rc harness.RunContext) error {
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
	if stale || executionPolicyStale(b, run) || run.Status != "running" {
		return domain.ErrStopped
	}
	return tx.Commit(ctx)
}

// ExecutionRun reads are separately authorized from writes and remain useful
// after stop. They disclose no events or receipts after any scope revocation.
func (s *Store) GetExecutionRun(ctx context.Context, actor, id string) (ExecutionRun, error) {
	var out ExecutionRun
	if !executionUUIDs(actor, id) {
		return out, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	if _, err = lockPrincipal(ctx, tx, actor); err != nil {
		return out, err
	}
	out, err = loadExecutionRun(ctx, tx, id)
	if err != nil {
		return out, err
	}
	if _, _, err = lockExecutionScopes(ctx, tx, out, actor); err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}
