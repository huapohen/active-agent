package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/auth"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
	"github.com/stretchr/testify/require"
)

type fixtureMachineVerifier struct{}

func (fixtureMachineVerifier) VerifyMachine(_ context.Context, token string) (auth.MachineIdentity, error) {
	if token == "mt_fixture" {
		return auth.MachineIdentity{Issuer: "https://fixture.clerk.accounts.dev", MachineSubject: "mch_fixture"}, nil
	}
	if token == "mt_unbound" {
		return auth.MachineIdentity{Issuer: "https://fixture.clerk.accounts.dev", MachineSubject: "mch_unbound"}, nil
	}
	return auth.MachineIdentity{}, errors.New("invalid test machine credential")
}
func TestMachineRoutesRequireServerRunAndInheritedStopScope(t *testing.T) {
	ctx := context.Background()
	s := httpStore(t)
	owner, err := s.ResolveIdentity(ctx, "test-only-issuer", "human-test")
	require.NoError(t, err)
	agent := uuid.NewString()
	_, err = s.Pool.Exec(ctx, "INSERT INTO principals(id,kind,display_name) VALUES($1,'agent','原生同事')", agent)
	require.NoError(t, err)
	w, err := s.CreateWorkspace(ctx, owner.ID, "machine-workspace-create", "机器执行验收")
	require.NoError(t, err)
	_, err = s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", w, agent)
	require.NoError(t, err)
	source, err := s.CreateRoom(ctx, owner.ID, "machine-source-create", w, "来源群", []string{agent})
	require.NoError(t, err)
	target, err := s.CreateRoom(ctx, owner.ID, "machine-target-create", w, "目标群", []string{agent})
	require.NoError(t, err)
	otherWorkspace, err := s.CreateWorkspace(ctx, owner.ID, "machine-other-workspace", "未授权给此机器的工作区")
	require.NoError(t, err)
	_, err = s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", otherWorkspace, agent)
	require.NoError(t, err)
	otherRoom, err := s.CreateRoom(ctx, owner.ID, "machine-other-room", otherWorkspace, "另一工作区", []string{agent})
	require.NoError(t, err)
	b, err := s.RegisterExecutor(ctx, owner.ID, store.RegisterExecutorCommand{ActionID: "machine-executor-bind", WorkspaceID: w, AgentPrincipalID: agent, Issuer: "https://fixture.clerk.accounts.dev", MachineSubject: "mch_fixture", Enabled: true})
	require.NoError(t, err)
	_, err = s.SetAgentExecutionPolicy(ctx, owner.ID, store.AgentExecutionPolicyCommand{ActionID: "machine-policy-enable", WorkspaceID: w, AgentPrincipalID: agent, ProactiveEnabled: true, ExpectedVersion: 1})
	require.NoError(t, err)
	h := New(s, fixtureVerifier{}, nil, nil, WithMachineVerifier(fixtureMachineVerifier{}))
	code, me := request(t, h, "mt_fixture", "GET", "/v1/me", nil)
	require.Equal(t, 200, code)
	require.Equal(t, agent, me["principal"].(map[string]any)["id"])
	code, visible := request(t, h, "mt_fixture", "GET", "/v1/rooms", nil)
	require.Equal(t, 200, code)
	require.Len(t, visible["rooms"], 2)
	code, _ = request(t, h, "mt_fixture", "GET", "/v1/rooms/"+otherRoom.ID+"/messages", nil)
	require.Equal(t, 403, code)
	require.Equal(t, true, call(t, h, "mt_fixture", "message_read", map[string]any{"room_id": otherRoom.ID})["isError"])
	code, _ = request(t, h, "mt_unbound", "GET", "/v1/me", nil)
	require.Equal(t, 403, code)
	binding := map[string]string{"principal_id": agent, "executor_id": b.ExecutorID}
	code, _ = request(t, h, "human-test", "POST", "/internal/harness/binding", binding)
	require.Equal(t, 401, code)
	code, ack := request(t, h, "mt_fixture", "POST", "/internal/harness/binding", binding)
	require.Equal(t, 200, code)
	require.Equal(t, true, ack["server_bound"])
	binding["principal_id"] = owner.ID
	code, _ = request(t, h, "mt_fixture", "POST", "/internal/harness/binding", binding)
	require.Equal(t, 403, code)
	code, _ = request(t, h, "mt_fixture", "POST", "/v1/workspaces", map[string]string{"action_id": "unscoped-workspace", "title": "无Run写"})
	require.Equal(t, 403, code)
	create := store.CreateExecutionRunCommand{ActionID: "machine-source-run", ExecutorID: b.ExecutorID, RoomID: source.ID, ScopeEpoch: 1, Goal: "在授权范围内协作"}
	code, data := request(t, h, "mt_fixture", "POST", "/v1/runs", create)
	require.Equal(t, 201, code)
	raw, err := json.Marshal(data["run"])
	require.NoError(t, err)
	var parent store.ExecutionRun
	require.NoError(t, json.Unmarshal(raw, &parent))
	create.ActionID = "machine-child-run"
	create.RoomID = target.ID
	create.ParentRunID = parent.Context.RunID
	code, data = request(t, h, "mt_fixture", "POST", "/v1/runs", create)
	require.Equal(t, 201, code)
	raw, err = json.Marshal(data["run"])
	require.NoError(t, err)
	var child store.ExecutionRun
	require.NoError(t, json.Unmarshal(raw, &child))
	require.Contains(t, child.Context.OriginScopes, harness.Scope{RoomID: source.ID, Epoch: 1})
	action := map[string]any{"action_id": harness.StableID(child.Context.RunID, "first-message"), "content": "经Run归档的消息"}
	code, _ = request(t, h, "mt_fixture", "POST", "/v1/rooms/"+target.ID+"/messages", action)
	require.Equal(t, 400, code)
	action["run_id"] = child.Context.RunID
	code, data = request(t, h, "mt_fixture", "POST", "/v1/rooms/"+target.ID+"/messages", action)
	require.Equal(t, 200, code)
	require.Equal(t, "succeeded", data["status"])
	action["room_id"] = target.ID
	replay := structured(t, call(t, h, "mt_fixture", "message_send", action))
	require.Equal(t, data, replay)
	tampered := child.Context
	tampered.OriginScopes = nil
	code, _ = request(t, h, "mt_fixture", "POST", "/internal/harness/check", map[string]any{"context": tampered})
	require.Equal(t, 403, code)
	_, err = s.SetStopped(ctx, owner.ID, source.ID, "machine-stop-source", 1, true)
	require.NoError(t, err)
	delete(action, "room_id") // room_id is the REST path, never a caller override in the strict body.
	action["action_id"] = harness.StableID(child.Context.RunID, "after-source-stop")
	code, data = request(t, h, "mt_fixture", "POST", "/v1/rooms/"+target.ID+"/messages", action)
	require.Equal(t, 409, code)
	require.Equal(t, "scope_stopped_or_stale", data["error"])
	code, data = request(t, h, "mt_fixture", "POST", "/internal/harness/check", map[string]any{"context": child.Context})
	require.Equal(t, 409, code)
	require.Equal(t, "scope_stopped", data["code"])
	code, _ = request(t, h, "mt_fixture", "GET", "/v1/rooms/"+target.ID+"/messages?run_id="+child.Context.RunID, nil)
	require.Equal(t, 409, code)
	code, _ = request(t, h, "mt_fixture", "GET", "/v1/rooms?run_id="+child.Context.RunID, nil)
	require.Equal(t, 409, code)
	require.Equal(t, true, call(t, h, "mt_fixture", "message_read", map[string]any{"room_id": target.ID, "run_id": child.Context.RunID})["isError"])
	code, historical := request(t, h, "mt_fixture", "GET", "/v1/rooms/"+target.ID+"/messages", nil)
	require.Equal(t, 200, code)
	require.Len(t, historical["messages"], 1)
	_, err = s.RegisterExecutor(ctx, owner.ID, store.RegisterExecutorCommand{ActionID: "machine-disable-binding", WorkspaceID: w, AgentPrincipalID: agent, Issuer: b.Issuer, MachineSubject: b.MachineSubject, Enabled: false, ExpectedVersion: b.Version})
	require.NoError(t, err)
	code, _ = request(t, h, "mt_fixture", "GET", "/v1/me", nil)
	require.Equal(t, 403, code)
}

func TestRongCloudSessionIsNotGenerallyIssuedBeforeWritePolicyVerification(t *testing.T) {
	s := httpStore(t)
	h := New(s, fixtureVerifier{}, nil, nil)
	code, out := request(t, h, "human-test", "POST", "/v1/transport/rongcloud/session", map[string]any{})
	require.Equal(t, 503, code)
	require.Equal(t, "rongcloud_client_write_policy_unverified", out["error"])
	require.NotContains(t, out, "token")
}
