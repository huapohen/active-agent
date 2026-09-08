package store

import (
	"context"
	"errors"
	"strings"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/jackc/pgx/v5"
)

type ExecutorBinding struct {
	Principal        domain.Principal `json:"principal"`
	ExecutorID       string           `json:"executor_id"`
	WorkspaceID      string           `json:"workspace_id"`
	Issuer           string           `json:"issuer"`
	MachineSubject   string           `json:"machine_subject"`
	Enabled          bool             `json:"enabled"`
	Version          int64            `json:"version"`
	ProactiveEnabled bool             `json:"proactive_enabled"`
	PolicyVersion    int64            `json:"policy_version"`
	RuntimeVersion   string           `json:"runtime_version"`
	WorkflowVersion  string           `json:"workflow_version"`
}

type RegisterExecutorCommand struct {
	ActionID         string `json:"action_id"`
	WorkspaceID      string `json:"workspace_id"`
	AgentPrincipalID string `json:"agent_principal_id"`
	Issuer           string `json:"issuer"`
	MachineSubject   string `json:"machine_subject"`
	Enabled          bool   `json:"enabled"`
	ExpectedVersion  int64  `json:"expected_version"` // zero creates; positive updates this exact binding
}

type AgentExecutionPolicyCommand struct {
	ActionID         string `json:"action_id"`
	WorkspaceID      string `json:"workspace_id"`
	AgentPrincipalID string `json:"agent_principal_id"`
	ProactiveEnabled bool   `json:"proactive_enabled"`
	ExpectedVersion  int64  `json:"expected_version"`
}

type AgentExecutionPolicy struct {
	PrincipalID      string `json:"principal_id"`
	WorkspaceID      string `json:"workspace_id"`
	ProactiveEnabled bool   `json:"proactive_enabled"`
	Version          int64  `json:"version"`
}

func executionUUIDs(ids ...string) bool {
	for _, id := range ids {
		if _, err := uuid.Parse(id); err != nil {
			return false
		}
	}
	return true
}
func adminRole(role string) bool { return role == "owner" || role == "admin" }

// Registration is a workspace administration action. Machine subjects never
// self-select an existing Agent by submitting agent_principal_id to login.
func (s *Store) RegisterExecutor(ctx context.Context, actor string, cmd RegisterExecutorCommand) (ExecutorBinding, error) {
	var out ExecutorBinding
	if !validAction(cmd.ActionID) || !executionUUIDs(actor, cmd.WorkspaceID, cmd.AgentPrincipalID) || cmd.Issuer == "" || len(cmd.Issuer) > 2048 || cmd.MachineSubject == "" || len(cmd.MachineSubject) > 512 || strings.ContainsAny(cmd.Issuer+cmd.MachineSubject, "\r\n\x00") || cmd.ExpectedVersion < 0 {
		return out, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	role, err := workspaceAccess(ctx, tx, actor, cmd.WorkspaceID)
	if err != nil {
		return out, err
	}
	if !adminRole(role) {
		return out, domain.ErrForbidden
	}
	target, err := lockPrincipal(ctx, tx, cmd.AgentPrincipalID)
	if err != nil {
		return out, err
	}
	if target.Kind != "agent" {
		return out, domain.ErrForbidden
	}
	if _, err = workspaceAccess(ctx, tx, cmd.AgentPrincipalID, cmd.WorkspaceID); err != nil {
		return out, err
	}
	digest := actionDigest("executor.register", cmd)
	replay, err := readAction(ctx, tx, actor, cmd.ActionID, digest, &out)
	if err != nil {
		return out, err
	}
	if replay { // Return current binding facts, never an old enabled assertion.
		out, err = executorByID(ctx, tx, out.ExecutorID, true)
		if err != nil {
			return out, err
		}
		return out, tx.Commit(ctx)
	}
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", "executor/"+cmd.Issuer+"\x1f"+cmd.MachineSubject); err != nil {
		return out, err
	}
	var id, principal, workspace string
	var version int64
	err = tx.QueryRow(ctx, "SELECT id::text,principal_id::text,workspace_id::text,version FROM executors WHERE issuer=$1 AND machine_subject=$2 FOR UPDATE", cmd.Issuer, cmd.MachineSubject).Scan(&id, &principal, &workspace, &version)
	if errors.Is(err, pgx.ErrNoRows) {
		if cmd.ExpectedVersion != 0 {
			return out, domain.ErrConflict
		}
		id = uuid.NewString()
		_, err = tx.Exec(ctx, `INSERT INTO agent_execution_policies(principal_id,workspace_id) VALUES($1,$2) ON CONFLICT DO NOTHING`, cmd.AgentPrincipalID, cmd.WorkspaceID)
		if err != nil {
			return out, err
		}
		_, err = tx.Exec(ctx, `INSERT INTO executors(id,issuer,machine_subject,principal_id,workspace_id,enabled,runtime_version,workflow_version,created_by) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)`, id, cmd.Issuer, cmd.MachineSubject, cmd.AgentPrincipalID, cmd.WorkspaceID, cmd.Enabled, harness.RuntimeVersion, harness.WorkflowVersion, actor)
	} else if err == nil {
		if principal != cmd.AgentPrincipalID || workspace != cmd.WorkspaceID {
			return out, domain.ErrForbidden
		}
		if version != cmd.ExpectedVersion {
			return out, domain.ErrConflict
		}
		_, err = tx.Exec(ctx, "UPDATE executors SET enabled=$2,version=version+1 WHERE id=$1", id, cmd.Enabled)
	}
	if err != nil {
		return out, err
	}
	out, err = executorByID(ctx, tx, id, true)
	if err != nil {
		return out, err
	}
	if err = saveAction(ctx, tx, actor, cmd.ActionID, digest, out); err != nil {
		return out, err
	}
	if err = event(ctx, tx, "", actor, cmd.ActionID, "executor.registered", out, false); err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}

// A current Agent may configure its own proactive personality; human and Agent
// workspace administrators have exactly the same authority over their workspace.
func (s *Store) SetAgentExecutionPolicy(ctx context.Context, actor string, cmd AgentExecutionPolicyCommand) (AgentExecutionPolicy, error) {
	var out AgentExecutionPolicy
	if !validAction(cmd.ActionID) || !executionUUIDs(actor, cmd.AgentPrincipalID, cmd.WorkspaceID) || cmd.ExpectedVersion < 1 {
		return out, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	role, err := workspaceAccess(ctx, tx, actor, cmd.WorkspaceID)
	if err != nil {
		return out, err
	}
	if actor != cmd.AgentPrincipalID && !adminRole(role) {
		return out, domain.ErrForbidden
	}
	p, err := lockPrincipal(ctx, tx, cmd.AgentPrincipalID)
	if err != nil {
		return out, err
	}
	if p.Kind != "agent" {
		return out, domain.ErrForbidden
	}
	if _, err = workspaceAccess(ctx, tx, p.ID, cmd.WorkspaceID); err != nil {
		return out, err
	}
	digest := actionDigest("agent.execution_policy", cmd)
	replay, err := readAction(ctx, tx, actor, cmd.ActionID, digest, &out)
	if err != nil {
		return out, err
	}
	if replay {
		return out, tx.Commit(ctx)
	}
	out = AgentExecutionPolicy{PrincipalID: p.ID, WorkspaceID: cmd.WorkspaceID, ProactiveEnabled: cmd.ProactiveEnabled}
	err = tx.QueryRow(ctx, `UPDATE agent_execution_policies SET proactive_enabled=$3,version=version+1 WHERE principal_id=$1 AND workspace_id=$2 AND version=$4 RETURNING version`, p.ID, cmd.WorkspaceID, cmd.ProactiveEnabled, cmd.ExpectedVersion).Scan(&out.Version)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, domain.ErrConflict
	}
	if err != nil {
		return out, err
	}
	if err = saveAction(ctx, tx, actor, cmd.ActionID, digest, out); err != nil {
		return out, err
	}
	if err = event(ctx, tx, "", actor, cmd.ActionID, "agent.execution_policy_changed", out, false); err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}

const executorSelect = `SELECT e.id::text,e.workspace_id::text,e.issuer,e.machine_subject,e.enabled,e.version,e.runtime_version,e.workflow_version,p.id::text,p.kind,p.display_name,ep.proactive_enabled,ep.version
 FROM executors e JOIN principals p ON p.id=e.principal_id
 JOIN workspace_members wm ON wm.workspace_id=e.workspace_id AND wm.principal_id=e.principal_id
 JOIN agent_execution_policies ep ON ep.principal_id=e.principal_id AND ep.workspace_id=e.workspace_id
 WHERE NOT p.disabled AND p.kind='agent' AND `

func scanExecutor(row pgx.Row, allowDisabled bool) (ExecutorBinding, error) {
	var b ExecutorBinding
	err := row.Scan(&b.ExecutorID, &b.WorkspaceID, &b.Issuer, &b.MachineSubject, &b.Enabled, &b.Version, &b.RuntimeVersion, &b.WorkflowVersion, &b.Principal.ID, &b.Principal.Kind, &b.Principal.DisplayName, &b.ProactiveEnabled, &b.PolicyVersion)
	if errors.Is(err, pgx.ErrNoRows) || (!b.Enabled && !allowDisabled && err == nil) {
		return b, domain.ErrForbidden
	}
	return b, err
}
func executorByID(ctx context.Context, tx pgx.Tx, id string, allowDisabled bool) (ExecutorBinding, error) {
	return scanExecutor(tx.QueryRow(ctx, executorSelect+"e.id=$1 FOR SHARE OF e,p,wm,ep", id), allowDisabled)
}
func executorByMachine(ctx context.Context, tx pgx.Tx, issuer, subject string) (ExecutorBinding, error) {
	if issuer == "" || subject == "" {
		return ExecutorBinding{}, domain.ErrForbidden
	}
	return scanExecutor(tx.QueryRow(ctx, executorSelect+"e.issuer=$1 AND e.machine_subject=$2 FOR SHARE OF e,p,wm,ep", issuer, subject), false)
}

// Call only with issuer/subject returned by the machine-token verifier. Human
// sessions use ResolveIdentity, which cannot create or resolve these bindings.
func (s *Store) ResolveExecutor(ctx context.Context, issuer, machineSubject string) (ExecutorBinding, error) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return ExecutorBinding{}, err
	}
	defer tx.Rollback(ctx)
	out, err := executorByMachine(ctx, tx, issuer, machineSubject)
	if err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}
