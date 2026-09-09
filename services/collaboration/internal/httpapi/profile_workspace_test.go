package httpapi

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/cloudwego/eino/schema"
	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
	"github.com/stretchr/testify/require"
	"go.temporal.io/sdk/activity"
	"go.temporal.io/sdk/testsuite"
	"go.temporal.io/sdk/workflow"
)

func TestProfileWorkspaceEmptyAccountAPIAndMCPOnboarding(t *testing.T) {
	s := httpStore(t)
	h := New(s, fixtureVerifier{}, nil, nil)
	code, profile := request(t, h, "human-test", "GET", "/v1/profile", nil)
	require.Equal(t, 200, code)
	id := profile["principal"].(map[string]any)["id"]
	require.EqualValues(t, 1, profile["version"])
	require.Equal(t, profile, structured(t, call(t, h, "human-test", "profile_read", map[string]any{})))
	code, empty := request(t, h, "human-test", "GET", "/v1/workspaces", nil)
	require.Equal(t, 200, code)
	require.Equal(t, []any{}, empty["workspaces"])
	require.Equal(t, empty, structured(t, call(t, h, "human-test", "workspace_list", map[string]any{})))
	change := map[string]any{"action_id": "human-profile-action", "display_name": "  花破痕  ", "expected_version": 1}
	code, receipt := request(t, h, "human-test", "POST", "/v1/profile", change)
	require.Equal(t, 200, code)
	require.Equal(t, id, receipt["principal"].(map[string]any)["id"])
	require.Equal(t, "花破痕", receipt["principal"].(map[string]any)["display_name"])
	require.EqualValues(t, 2, receipt["version"])
	replay := structured(t, call(t, h, "human-test", "profile_update", change))
	receipt["replayed"] = true
	require.Equal(t, receipt, replay)
	code, me := request(t, h, "human-test", "GET", "/v1/me", nil)
	require.Equal(t, 200, code)
	require.Equal(t, receipt["principal"], me["principal"])
	create := map[string]any{"action_id": "human-first-workspace", "title": "我的工作空间"}
	code, created := request(t, h, "human-test", "POST", "/v1/workspaces", create)
	require.Equal(t, 201, code)
	require.Equal(t, created, structured(t, call(t, h, "human-test", "workspace_create", create)))
	workspace := created["workspace"].(map[string]any)["id"].(string)
	code, page := request(t, h, "human-test", "GET", "/v1/workspaces?limit=1", nil)
	require.Equal(t, 200, code)
	require.Equal(t, page, structured(t, call(t, h, "human-test", "workspace_list", map[string]any{"limit": 1})))
	require.Len(t, page["workspaces"], 1)
	require.Equal(t, "owner", page["workspaces"].([]any)[0].(map[string]any)["role"])
	code, members := request(t, h, "human-test", "GET", "/v1/workspaces/"+workspace+"/members", nil)
	require.Equal(t, 200, code)
	require.Equal(t, members, structured(t, call(t, h, "human-test", "workspace_member_list", map[string]any{"workspace_id": workspace})))
	require.Len(t, members["members"], 1)
	require.Equal(t, id, members["members"].([]any)[0].(map[string]any)["principal_id"])
	createRoom := map[string]any{"action_id": "human-first-room", "workspace_id": workspace, "title": "我的第一群", "members": []string{}}
	code, room := request(t, h, "human-test", "POST", "/v1/rooms", createRoom)
	require.Equal(t, 201, code)
	require.Equal(t, room, structured(t, call(t, h, "human-test", "room_create", createRoom)))
	idRoom := room["room"].(map[string]any)["id"].(string)
	code, members = request(t, h, "human-test", "GET", "/v1/rooms/"+idRoom+"/members", nil)
	require.Equal(t, 200, code)
	require.Equal(t, members, structured(t, call(t, h, "human-test", "room_member_list", map[string]any{"room_id": idRoom})))
	require.Len(t, members["members"], 1)
	code, rooms := request(t, h, "human-test", "GET", "/v1/rooms", nil)
	require.Equal(t, 200, code)
	require.Equal(t, workspace, rooms["rooms"].([]any)[0].(map[string]any)["workspace_id"])
	_, stranger := request(t, h, "outsider-test", "GET", "/v1/workspaces", nil)
	require.Empty(t, stranger["workspaces"])
	code, _ = request(t, h, "outsider-test", "GET", "/v1/workspaces/"+workspace+"/members", nil)
	require.Equal(t, 403, code)
	code, _ = request(t, h, "outsider-test", "GET", "/v1/rooms/"+idRoom+"/members", nil)
	require.Equal(t, 403, code)
}

func TestProfileWorkspaceStrictInputsAndDistinctVersionConflict(t *testing.T) {
	s := httpStore(t)
	h := New(s, fixtureVerifier{}, nil, nil)
	base := map[string]any{"action_id": "profile-version-one", "display_name": "第一版", "expected_version": 1}
	code, _ := request(t, h, "human-test", "POST", "/v1/profile", base)
	require.Equal(t, 200, code)
	code, conflict := request(t, h, "human-test", "POST", "/v1/profile", map[string]any{"action_id": "profile-version-one", "display_name": "换正文", "expected_version": 1})
	require.Equal(t, 409, code)
	require.Equal(t, "action_conflict", conflict["error"])
	stale := map[string]any{"action_id": "profile-stale-version", "display_name": "第二版", "expected_version": 1}
	code, conflict = request(t, h, "human-test", "POST", "/v1/profile", stale)
	require.Equal(t, 409, code)
	require.Equal(t, "profile_version_conflict", conflict["error"])
	mcp := call(t, h, "human-test", "profile_update", stale)
	require.True(t, mcp["isError"].(bool))
	require.Equal(t, "profile_version_conflict", mcp["structuredContent"].(map[string]any)["error"])
	stale["expected_version"] = 2
	code, latest := request(t, h, "human-test", "POST", "/v1/profile", stale)
	require.Equal(t, 200, code)
	require.EqualValues(t, 3, latest["version"])
	code, replay := request(t, h, "human-test", "POST", "/v1/profile", base)
	require.Equal(t, 200, code)
	require.EqualValues(t, 2, replay["version"])
	require.Equal(t, true, replay["replayed"])
	code, latest = request(t, h, "human-test", "GET", "/v1/profile", nil)
	require.Equal(t, 200, code)
	require.EqualValues(t, 3, latest["version"])
	for _, body := range []map[string]any{
		{"action_id": "profile-spoof-person", "display_name": "坏", "expected_version": 3, "principal_id": uuid.NewString()},
		{"action_id": "profile-spoof-role", "display_name": "坏", "expected_version": 3, "role": "admin"},
		{"action_id": "profile-missing-version", "display_name": "坏"},
		{"action_id": "profile-null-version", "display_name": "坏", "expected_version": nil},
		{"action_id": "profile-newline-value", "display_name": "坏\n坏", "expected_version": 3},
		{"action_id": "profile-too-long-value", "display_name": strings.Repeat("中", 81), "expected_version": 3},
	} {
		code, _ := request(t, h, "human-test", "POST", "/v1/profile", body)
		require.Equal(t, 400, code)
	}
	for _, path := range []string{"/v1/workspaces?limit=0", "/v1/workspaces?limit=101", "/v1/workspaces?limit=1&limit=2", "/v1/workspaces?after=wrong", "/v1/workspaces?principal_id=" + uuid.NewString(), "/v1/profile?principal_id=" + uuid.NewString(), "/v1/profile?run_id=" + uuid.NewString()} {
		code, _ := request(t, h, "human-test", "GET", path, nil)
		require.Equal(t, 400, code, path)
	}
	for _, name := range []string{"workspace_list", "workspace_member_list", "room_member_list"} {
		mcpRejectArguments(t, h, "human-test", name, map[string]any{"limit": 0})
		mcpRejectArguments(t, h, "human-test", name, map[string]any{"after": nil})
	}
	for _, path := range []string{"/v1/workspaces", "/v1/rooms"} {
		code, _ := request(t, h, "human-test", "POST", path, map[string]any{"action_id": "spoof-bootstrap", "title": "bad", "principal_id": uuid.NewString()})
		require.Equal(t, 400, code)
	}
}

func TestMachineProfileAPIAndMCPUseExactRunAndNoUnscopedBootstrap(t *testing.T) {
	f := newHarnessInteractionFixture(t, false)
	h := New(f.s, fixtureVerifier{}, nil, nil, WithMachineVerifier(fixtureMachineVerifier{}))
	ctx := context.Background()
	code, profile := request(t, h, "mt_fixture", "GET", "/v1/profile?run_id="+f.run.Context.RunID, nil)
	require.Equal(t, 200, code)
	require.Equal(t, f.agent, profile["principal"].(map[string]any)["id"])
	require.Equal(t, profile, structured(t, call(t, h, "mt_fixture", "profile_read", map[string]any{"run_id": f.run.Context.RunID})))
	body := map[string]any{"action_id": harness.StableID(f.run.Context.RunID, "profile-http"), "display_name": "原生昵称", "expected_version": 1, "run_id": f.run.Context.RunID}
	code, receipt := request(t, h, "mt_fixture", "POST", "/v1/profile", body)
	require.Equal(t, 200, code)
	require.Equal(t, receipt, structured(t, call(t, h, "mt_fixture", "profile_update", body)))
	require.Equal(t, "succeeded", receipt["status"])
	require.Equal(t, "committed", receipt["result"].(map[string]any)["canonical_status"])
	for _, body := range []map[string]any{
		{"action_id": harness.StableID(f.run.Context.RunID, "missing-run"), "display_name": "无Run", "expected_version": 2},
		{"action_id": "not-64hex", "display_name": "错误ID", "expected_version": 2, "run_id": f.run.Context.RunID},
		{"action_id": harness.StableID(f.run.Context.RunID, "spoof-principal"), "display_name": "冒充", "expected_version": 2, "run_id": f.run.Context.RunID, "principal_id": f.owner},
	} {
		code, _ := request(t, h, "mt_fixture", "POST", "/v1/profile", body)
		require.Equal(t, 400, code)
	}
	code, caps := request(t, h, "mt_fixture", "GET", "/v1/capabilities", nil)
	require.Equal(t, 200, code)
	for _, raw := range caps["capabilities"].([]any) {
		capability := raw.(map[string]any)
		if capability["id"] == "workspace.create" || capability["id"] == "room.create" {
			require.Equal(t, false, capability["available"])
			require.Equal(t, "machine_action_not_implemented", capability["unavailable_reason"])
		}
		if capability["id"] == "profile.update" {
			require.Equal(t, true, capability["available"])
			require.Equal(t, "run_required", capability["machine_access"])
		}
	}
	for _, path := range []string{"/v1/workspaces", "/v1/rooms"} {
		code, _ := request(t, h, "mt_fixture", "POST", path, map[string]any{"action_id": harness.StableID(f.run.Context.RunID, path), "title": "不准绕路", "run_id": f.run.Context.RunID})
		require.Equal(t, 403, code)
	}
	_, err := f.s.SetStopped(ctx, f.owner, f.source.ID, "profile-http-source-stop", f.source.Version, true)
	require.NoError(t, err)
	code, stopped := request(t, h, "mt_fixture", "POST", "/v1/profile", body)
	require.Equal(t, 409, code)
	require.Equal(t, "scope_stopped_or_stale", stopped["error"])
	code, _ = request(t, h, "mt_fixture", "GET", "/v1/profile?run_id="+f.run.Context.RunID, nil)
	require.Equal(t, 409, code)
	code, fresh := request(t, h, "mt_fixture", "GET", "/v1/profile", nil)
	require.Equal(t, 200, code)
	require.EqualValues(t, 2, fresh["version"])
}

func TestProfileEinoReadsCurrentVersionAndCommitsThroughRealHTTPPG(t *testing.T) {
	f := newHarnessInteractionFixture(t, false)
	ctx := context.Background()
	run, err := f.s.CreateExecutionRun(ctx, f.agent, store.CreateExecutionRunCommand{ActionID: "profile-eino-run", ExecutorID: f.binding.ExecutorID, RoomID: f.target.ID, ScopeEpoch: f.target.ScopeEpoch, ParentRunID: f.run.Context.RunID, Goal: "读取自己资料并把自己昵称改为合成设计师"})
	require.NoError(t, err)
	require.Contains(t, f.gateway.AllowedActionTypes(), "profile.update")
	m := &harnessInteractionModel{messages: []*schema.Message{
		harnessInteractionTool("im_profile_read", `{}`),
		{Role: schema.Assistant, Content: `{"summary":"Read the actual profile version before changing my own name","done":true,"actions":[{"key":"self-profile-name","type":"profile.update","payload":{"display_name":"合成设计师","expected_version":1}}]}`},
	}}
	planner, err := harness.NewEinoPlanner(harness.PlannerConfig{Model: m, Gateway: f.gateway, AllowedActionTypes: f.gateway.AllowedActionTypes()})
	require.NoError(t, err)
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	activities := &harness.Activities{Gateway: f.gateway, Planner: planner}
	env.RegisterWorkflowWithOptions(harness.RunWorkflow, workflow.RegisterOptions{Name: harness.WorkflowName})
	env.RegisterActivityWithOptions(activities.Plan, activity.RegisterOptions{Name: "renji.agent.plan.v1"})
	env.RegisterActivityWithOptions(activities.Execute, activity.RegisterOptions{Name: "renji.agent.action.v1"})
	env.RegisterActivityWithOptions(activities.Terminal, activity.RegisterOptions{Name: "renji.agent.terminal.v1"})
	env.RegisterActivityWithOptions(activities.Archive, activity.RegisterOptions{Name: "renji.agent.archive.v1"})
	env.ExecuteWorkflow(harness.WorkflowName, harness.RunInput{Context: run.Context, Goal: run.Goal, MaxStages: 1})
	require.NoError(t, env.GetWorkflowError())
	var result harness.RunResult
	require.NoError(t, env.GetWorkflowResult(&result))
	require.Equal(t, "completed", result.Status)
	require.Len(t, result.Receipts, 1)
	require.True(t, m.seenTools["im_profile_read"])
	require.Equal(t, 2, m.calls)
	profile, err := f.s.ReadProfile(ctx, store.AccountReader{MachineIssuer: f.binding.Issuer, MachineSubject: f.binding.MachineSubject}, "")
	require.NoError(t, err)
	require.Equal(t, "合成设计师", profile.Principal.DisplayName)
	require.EqualValues(t, 2, profile.Version)
	var linked int
	require.NoError(t, f.s.Pool.QueryRow(ctx, "SELECT count(*) FROM transport_outbox WHERE execution_run_id=$1", run.Context.RunID).Scan(&linked))
	require.Zero(t, linked)
	var events []byte
	require.NoError(t, f.s.Pool.QueryRow(ctx, "SELECT jsonb_agg(event)::text FROM execution_events WHERE run_id=$1", run.Context.RunID).Scan(&events))
	require.Contains(t, string(events), "im_profile_read")
	// The completed Run cannot be reused as fresh profile execution authority.
	_, err = f.gateway.ReadProfile(ctx, run.Context)
	require.ErrorIs(t, err, harness.ErrStopped)
}

func TestProfileBodyRejectsTrailingObject(t *testing.T) {
	s := httpStore(t)
	h := New(s, fixtureVerifier{}, nil, nil)
	r := httptest.NewRequest("POST", "/v1/profile", strings.NewReader(`{"action_id":"profile-trailing-json","display_name":"bad","expected_version":1}{}`))
	r.Header.Set("Authorization", "Bearer human-test")
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	require.Equal(t, 400, w.Code)
	var failure map[string]any
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &failure))
	require.Equal(t, "invalid_request", failure["error"])
}
