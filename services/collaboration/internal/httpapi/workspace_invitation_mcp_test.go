package httpapi

import (
	"context"
	"net/http"
	"testing"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/stretchr/testify/require"
)

func invitationMCPError(t *testing.T, h http.Handler, token, name string, args map[string]any, want string) {
	t.Helper()
	out := call(t, h, token, name, args)
	require.Equal(t, true, out["isError"])
	require.Equal(t, want, out["structuredContent"].(map[string]any)["error"])
}

func TestWorkspaceInvitationMCPHTTPHumanReceiptParity(t *testing.T) {
	s := httpStore(t)
	h := New(s, fixtureVerifier{}, nil, nil)
	status, space := request(t, h, "human-test", "POST", "/v1/workspaces", map[string]any{"action_id": "mcp-invitation-space", "title": "协议共用邀请"})
	require.Equal(t, 201, status)
	workspace := space["workspace"].(map[string]any)["id"].(string)
	path := "/v1/workspaces/" + workspace + "/invitations"
	args := map[string]any{"workspace_id": workspace, "action_id": "mcp-create-invitation", "expires_in_seconds": 3600}
	created := structured(t, call(t, h, "human-test", "workspace_invitation_create", args))
	secret := created["code"].(string)
	require.True(t, created["code_available"].(bool))
	status, replay := request(t, h, "human-test", "POST", path, map[string]any{"action_id": args["action_id"], "expires_in_seconds": 3600})
	require.Equal(t, 200, status)
	require.NotContains(t, replay, "code")
	require.Equal(t, false, replay["code_available"])
	require.Equal(t, true, replay["replayed"])
	require.Equal(t, replay, structured(t, call(t, h, "human-test", "workspace_invitation_create", args)))
	status, action := request(t, h, "human-test", "GET", "/v1/workspace-invitation-actions/mcp-create-invitation", nil)
	require.Equal(t, 200, status)
	require.Equal(t, "workspace.invitation.create", action["kind"])
	require.Equal(t, replay, action["receipt"])
	require.Equal(t, action, structured(t, call(t, h, "human-test", "workspace_invitation_action_read", map[string]any{"action_id": args["action_id"]})))
	status, listed := request(t, h, "human-test", "GET", path+"?limit=1", nil)
	require.Equal(t, 200, status)
	require.Equal(t, listed, structured(t, call(t, h, "human-test", "workspace_invitation_list", map[string]any{"workspace_id": workspace, "limit": 1})))
	require.NotContains(t, listed["invitations"].([]any)[0], "code")
	accept := map[string]any{"action_id": "mcp-accept-invitation", "code": secret}
	joined := structured(t, call(t, h, "outsider-test", "workspace_invitation_accept", accept))
	require.Equal(t, workspace, joined["workspace_id"])
	require.Equal(t, "member", joined["role"])
	require.Equal(t, false, joined["execution_scope_extended"])
	status, replay = request(t, h, "outsider-test", "POST", "/v1/workspace-invitations/accept", accept)
	require.Equal(t, 200, status)
	joined["replayed"] = true
	require.Equal(t, joined, replay)
	status, action = request(t, h, "outsider-test", "GET", "/v1/workspace-invitation-actions/mcp-accept-invitation", nil)
	require.Equal(t, 200, status)
	require.Equal(t, "workspace.invitation.accept", action["kind"])
	require.Equal(t, action, structured(t, call(t, h, "outsider-test", "workspace_invitation_action_read", map[string]any{"action_id": accept["action_id"]})))
	invitationMCPError(t, h, "agent-test", "workspace_invitation_accept", map[string]any{"action_id": "other-accept", "code": secret}, "invitation_used")
	status, other := request(t, h, "agent-test", "POST", "/v1/workspace-invitations/accept", map[string]any{"action_id": "other-accept", "code": secret})
	require.Equal(t, 409, status)
	require.Equal(t, "invitation_used", other["error"])
	created = structured(t, call(t, h, "human-test", "workspace_invitation_create", map[string]any{"workspace_id": workspace, "action_id": "mcp-revokable-invite"}))
	id := created["invitation"].(map[string]any)["id"].(string)
	revoked := structured(t, call(t, h, "human-test", "workspace_invitation_revoke", map[string]any{"workspace_id": workspace, "invitation_id": id, "action_id": "mcp-revoke-invite"}))
	require.Equal(t, "revoked", revoked["invitation"].(map[string]any)["status"])
	status, replay = request(t, h, "human-test", "POST", path+"/"+id+"/revoke", map[string]any{"action_id": "mcp-revoke-invite"})
	require.Equal(t, 200, status)
	revoked["replayed"] = true
	require.Equal(t, revoked, replay)
	invitationMCPError(t, h, "outsider-test", "workspace_invitation_accept", map[string]any{"action_id": "revoked-mcp-accept", "code": created["code"]}, "invitation_revoked")
	invitationMCPError(t, h, "outsider-test", "workspace_invitation_action_read", map[string]any{"action_id": "revoked-mcp-accept"}, "invitation_not_found")
}

func TestWorkspaceInvitationMCPMachineRunAndIssuerStopParity(t *testing.T) {
	f := newHarnessInteractionFixture(t, false)
	ctx := context.Background()
	_, e := f.s.Pool.Exec(ctx, "UPDATE workspace_members SET role='admin' WHERE workspace_id=$1 AND principal_id=$2", f.workspace, f.agent)
	require.NoError(t, e)
	h := New(f.s, fixtureVerifier{}, nil, nil, WithMachineVerifier(fixtureMachineVerifier{}))
	path := "/v1/workspaces/" + f.workspace + "/invitations"
	actionID := harness.StableID(f.run.Context.RunID, "mcp-agent-invitation")
	args := map[string]any{"workspace_id": f.workspace, "action_id": actionID, "run_id": f.run.Context.RunID}
	status, _ := request(t, h, "mt_unbound", "POST", "/v1/mcp", map[string]any{"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": map[string]any{"name": "workspace_invitation_create", "arguments": args}})
	require.Equal(t, 403, status) // Unknown machine is denied before MCP dispatch.
	invitationMCPError(t, h, "mt_fixture", "workspace_invitation_list", map[string]any{"workspace_id": f.workspace}, "invalid_request")
	status, _ = request(t, h, "mt_fixture", "GET", path, nil)
	require.Equal(t, 400, status)
	created := structured(t, call(t, h, "mt_fixture", "workspace_invitation_create", args))
	require.Equal(t, f.agent, created["principal_id"])
	status, replay := request(t, h, "mt_fixture", "POST", path, map[string]any{"action_id": actionID, "run_id": f.run.Context.RunID})
	require.Equal(t, 200, status)
	require.NotContains(t, replay, "code")
	require.Equal(t, false, replay["code_available"])
	status, list := request(t, h, "mt_fixture", "GET", path+"?run_id="+f.run.Context.RunID, nil)
	require.Equal(t, 200, status)
	require.Equal(t, list, structured(t, call(t, h, "mt_fixture", "workspace_invitation_list", map[string]any{"workspace_id": f.workspace, "run_id": f.run.Context.RunID})))
	status, action := request(t, h, "mt_fixture", "GET", "/v1/workspace-invitation-actions/"+actionID+"?run_id="+f.run.Context.RunID, nil)
	require.Equal(t, 200, status)
	require.Equal(t, action, structured(t, call(t, h, "mt_fixture", "workspace_invitation_action_read", map[string]any{"action_id": actionID, "run_id": f.run.Context.RunID})))
	_, e = f.s.SetStopped(ctx, f.owner, f.source.ID, "mcp-issued-origin-stop", f.source.Version, true)
	require.NoError(t, e)
	invitationMCPError(t, h, "outsider-test", "workspace_invitation_accept", map[string]any{"action_id": "mcp-human-agent-invite", "code": created["code"]}, domain.ErrStopped.Error())
	status, stopped := request(t, h, "outsider-test", "POST", "/v1/workspace-invitations/accept", map[string]any{"action_id": "mcp-human-agent-invite", "code": created["code"]})
	require.Equal(t, 409, status)
	require.Equal(t, domain.ErrStopped.Error(), stopped["error"])
	invitationMCPError(t, h, "mt_fixture", "workspace_invitation_list", map[string]any{"workspace_id": f.workspace, "run_id": f.run.Context.RunID}, domain.ErrStopped.Error())
	invitationMCPError(t, h, "mt_fixture", "workspace_invitation_create", args, domain.ErrStopped.Error())
}

func TestWorkspaceInvitationMCPAgentCrossWorkspaceGrantKeepsRunScope(t *testing.T) {
	f := newHarnessInteractionFixture(t, false)
	h := New(f.s, fixtureVerifier{}, nil, nil, WithMachineVerifier(fixtureMachineVerifier{}))
	status, space := request(t, h, "outsider-test", "POST", "/v1/workspaces", map[string]any{"action_id": "mcp-foreign-invite-space", "title": "受邀团队"})
	require.Equal(t, 201, status)
	foreign := space["workspace"].(map[string]any)["id"].(string)
	created := structured(t, call(t, h, "outsider-test", "workspace_invitation_create", map[string]any{"workspace_id": foreign, "action_id": "mcp-foreign-invitation"}))
	actionID := harness.StableID(f.run.Context.RunID, "mcp-join-foreign")
	invitationMCPError(t, h, "mt_fixture", "workspace_invitation_accept", map[string]any{"action_id": actionID, "code": created["code"]}, "invalid_request")
	args := map[string]any{"action_id": actionID, "run_id": f.run.Context.RunID, "code": created["code"]}
	joined := structured(t, call(t, h, "mt_fixture", "workspace_invitation_accept", args))
	require.Equal(t, f.agent, joined["principal_id"])
	require.Equal(t, foreign, joined["workspace_id"])
	require.Equal(t, false, joined["execution_scope_extended"])
	status, replay := request(t, h, "mt_fixture", "POST", "/v1/workspace-invitations/accept", args)
	require.Equal(t, 200, status)
	joined["replayed"] = true
	require.Equal(t, joined, replay)
	var bound, role string
	require.NoError(t, f.s.Pool.QueryRow(context.Background(), "SELECT workspace_id::text FROM executors WHERE id=$1", f.binding.ExecutorID).Scan(&bound))
	require.Equal(t, f.workspace, bound)
	require.NoError(t, f.s.Pool.QueryRow(context.Background(), "SELECT role FROM workspace_members WHERE workspace_id=$1 AND principal_id=$2", foreign, f.agent).Scan(&role))
	require.Equal(t, "member", role)
	invitationMCPError(t, h, "mt_fixture", "workspace_invitation_list", map[string]any{"workspace_id": foreign, "run_id": f.run.Context.RunID}, "forbidden")
}

func TestWorkspaceInvitationMCPHTTPRejectExplicitNullAndAuthorityFields(t *testing.T) {
	s := httpStore(t)
	h := New(s, fixtureVerifier{}, nil, nil)
	status, space := request(t, h, "human-test", "POST", "/v1/workspaces", map[string]any{"action_id": "mcp-invalid-invite-space", "title": "参数拒绝"})
	require.Equal(t, 201, status)
	workspace := space["workspace"].(map[string]any)["id"].(string)
	path := "/v1/workspaces/" + workspace + "/invitations"
	for _, tc := range []struct {
		name  string
		field string
		value any
	}{
		{"null_ttl", "expires_in_seconds", nil}, {"zero_ttl", "expires_in_seconds", 0},
		{"null_run", "run_id", nil}, {"extra_role", "role", "admin"},
		{"null_action", "action_id", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := map[string]any{"action_id": "mcp-invalid-invite"}
			body[tc.field] = tc.value
			status, _ := request(t, h, "human-test", "POST", path, body)
			require.Equal(t, 400, status)
			body["workspace_id"] = workspace
			mcpRejectArguments(t, h, "human-test", "workspace_invitation_create", body)
		})
	}
	for _, runID := range []string{"", uuid.NewString()} {
		body := map[string]any{"action_id": "mcp-human-run-field", "run_id": runID}
		status, _ := request(t, h, "human-test", "POST", path, body)
		require.Equal(t, 400, status)
		body["workspace_id"] = workspace
		invitationMCPError(t, h, "human-test", "workspace_invitation_create", body, "invalid_request")
		for _, read := range []struct {
			path, tool string
			args       map[string]any
		}{
			{path, "workspace_invitation_list", map[string]any{"workspace_id": workspace, "run_id": runID}},
			{"/v1/workspace-invitation-actions/mcp-invalid-invite", "workspace_invitation_action_read", map[string]any{"action_id": "mcp-invalid-invite", "run_id": runID}},
		} {
			status, _ := request(t, h, "human-test", "GET", read.path+"?run_id="+runID, nil)
			require.Equal(t, 400, status)
			invitationMCPError(t, h, "human-test", read.tool, read.args, "invalid_request")
		}
	}
	status, _ = request(t, h, "human-test", "POST", "/v1/workspace-invitations/accept", map[string]any{"action_id": "null-code", "code": nil})
	require.Equal(t, 400, status)
	mcpRejectArguments(t, h, "human-test", "workspace_invitation_accept", map[string]any{"action_id": "null-code", "code": nil})
	var n int
	require.NoError(t, s.Pool.QueryRow(context.Background(), "SELECT count(*) FROM workspace_invitations").Scan(&n))
	require.Zero(t, n)
}
