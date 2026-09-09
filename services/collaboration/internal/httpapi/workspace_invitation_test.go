package httpapi

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/stretchr/testify/require"
)

func TestWorkspaceInvitationHTTPAuthenticatedJoinAndSecretRecovery(t *testing.T) {
	s := httpStore(t)
	h := New(s, fixtureVerifier{}, nil, nil)
	code, w := request(t, h, "human-test", "POST", "/v1/workspaces", map[string]any{"action_id": "invitation-http-workspace", "title": "真实认证邀请"})
	require.Equal(t, 201, code)
	workspace := w["workspace"].(map[string]any)["id"].(string)
	path := "/v1/workspaces/" + workspace + "/invitations"
	body := map[string]any{"action_id": "http-first-invitation", "expires_in_seconds": 3600}
	code, created := request(t, h, "human-test", "POST", path, body)
	require.Equal(t, 200, code)
	inviteCode := created["code"].(string)
	id := created["invitation"].(map[string]any)["id"].(string)
	require.True(t, created["code_available"].(bool))
	code, replay := request(t, h, "human-test", "POST", path, body)
	require.Equal(t, 200, code)
	require.NotContains(t, replay, "code")
	require.Equal(t, false, replay["code_available"])
	require.Equal(t, true, replay["replayed"])
	code, action := request(t, h, "human-test", "GET", "/v1/workspace-invitation-actions/http-first-invitation", nil)
	require.Equal(t, 200, code)
	require.Equal(t, "workspace.invitation.create", action["kind"])
	require.NotContains(t, action["receipt"], "code")
	code, _ = request(t, h, "outsider-test", "GET", path, nil)
	require.Equal(t, 403, code)
	code, _ = request(t, h, "", "POST", "/v1/workspace-invitations/accept", map[string]any{"action_id": "unauthenticated-join", "code": inviteCode})
	require.Equal(t, 401, code)
	accept := map[string]any{"action_id": "http-authenticated-accept", "code": inviteCode}
	code, joined := request(t, h, "outsider-test", "POST", "/v1/workspace-invitations/accept", accept)
	require.Equal(t, 200, code)
	require.Equal(t, workspace, joined["workspace_id"])
	require.Equal(t, "member", joined["role"])
	require.Equal(t, false, joined["execution_scope_extended"])
	code, me := request(t, h, "outsider-test", "GET", "/v1/me", nil)
	require.Equal(t, 200, code)
	require.Equal(t, me["principal"].(map[string]any)["id"], joined["principal_id"])
	code, action = request(t, h, "outsider-test", "GET", "/v1/workspace-invitation-actions/http-authenticated-accept", nil)
	require.Equal(t, 200, code)
	require.Equal(t, "workspace.invitation.accept", action["kind"])
	code, spaces := request(t, h, "outsider-test", "GET", "/v1/workspaces", nil)
	require.Equal(t, 200, code)
	require.Len(t, spaces["workspaces"], 1)
	code, _ = request(t, h, "human-test", "POST", path+"/"+id+"/revoke", map[string]any{"action_id": "revoke-already-consumed"})
	require.Equal(t, 409, code)
	raw, _ := json.Marshal(body)
	r := httptest.NewRequest("POST", path, strings.NewReader(string(raw)))
	r.Header.Set("Authorization", "Bearer human-test")
	r.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, r)
	require.Equal(t, "no-store", rec.Header().Get("Cache-Control"))
}
func TestWorkspaceInvitationHTTPStrictBodyAndSafeErrors(t *testing.T) {
	s := httpStore(t)
	h := New(s, fixtureVerifier{}, nil, nil)
	code, w := request(t, h, "human-test", "POST", "/v1/workspaces", map[string]any{"action_id": "strict-invitation-space", "title": "严格参数"})
	require.Equal(t, 201, code)
	workspace := w["workspace"].(map[string]any)["id"].(string)
	path := "/v1/workspaces/" + workspace + "/invitations"
	for _, extra := range []string{"principal_id", "email", "role", "code"} {
		code, _ = request(t, h, "human-test", "POST", path, map[string]any{"action_id": "strict-create-invite", extra: "forged"})
		require.Equal(t, 400, code)
	}
	code, _ = request(t, h, "human-test", "GET", path+"?limit=1&limit=2", nil)
	require.Equal(t, 400, code)
	code, _ = request(t, h, "human-test", "POST", path+"?code=never-in-url", map[string]any{"action_id": "strict-query-invite"})
	require.Equal(t, 400, code)
	code, created := request(t, h, "human-test", "POST", path, map[string]any{"action_id": "to-revoke-invitation"})
	require.Equal(t, 200, code)
	id := created["invitation"].(map[string]any)["id"].(string)
	code, _ = request(t, h, "human-test", "POST", path+"/"+id+"/revoke", map[string]any{"action_id": "explicit-revoke-invite"})
	require.Equal(t, 200, code)
	code, err := request(t, h, "outsider-test", "POST", "/v1/workspace-invitations/accept", map[string]any{"action_id": "revoked-accept-attempt", "code": created["code"]})
	require.Equal(t, 410, code)
	require.Equal(t, "invitation_revoked", err["error"])
	code, err = request(t, h, "outsider-test", "GET", "/v1/workspace-invitation-actions/revoked-accept-attempt", nil)
	require.Equal(t, 404, code)
	require.Equal(t, "invitation_not_found", err["error"])
}
func TestWorkspaceInvitationHTTPMachineIssuerAndInheritedStop(t *testing.T) {
	f := newHarnessInteractionFixture(t, false)
	ctx := context.Background()
	_, e := f.s.Pool.Exec(ctx, "UPDATE workspace_members SET role='admin' WHERE workspace_id=$1 AND principal_id=$2", f.workspace, f.agent)
	require.NoError(t, e)
	h := New(f.s, fixtureVerifier{}, nil, nil, WithMachineVerifier(fixtureMachineVerifier{}))
	path := "/v1/workspaces/" + f.workspace + "/invitations"
	body := map[string]any{"action_id": harness.StableID(f.run.Context.RunID, "http-machine-invite"), "run_id": f.run.Context.RunID}
	code, _ := request(t, h, "mt_unbound", "POST", path, body)
	require.Equal(t, 403, code)
	code, out := request(t, h, "mt_fixture", "POST", path, body)
	require.Equal(t, 200, code)
	require.Equal(t, f.agent, out["principal_id"])
	require.True(t, out["code_available"].(bool))
	_, e = f.s.SetStopped(ctx, f.owner, f.source.ID, "http-stop-issued-origin", f.source.Version, true)
	require.NoError(t, e)
	code, stopped := request(t, h, "outsider-test", "POST", "/v1/workspace-invitations/accept", map[string]any{"action_id": "human-accept-agent-origin", "code": out["code"]})
	require.Equal(t, 409, code)
	require.Equal(t, domain.ErrStopped.Error(), stopped["error"])
	code, _ = request(t, h, "mt_fixture", "POST", path, body)
	require.Equal(t, 409, code)
	code, _ = request(t, h, "mt_fixture", "GET", "/v1/workspace-invitation-actions/"+body["action_id"].(string)+"?run_id="+f.run.Context.RunID, nil)
	require.Equal(t, 409, code)
}
