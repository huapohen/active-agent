package httpapi

import (
	"context"
	"fmt"
	"testing"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/stretchr/testify/require"
)

// These independent review regressions exercise real PostgreSQL in httpStore's
// disposable schema. They do not use the public schema or external transports.
func TestReviewWorkspaceCanonicalReceiptAcrossAPIAndMCP(t *testing.T) {
	s := httpStore(t)
	h := New(s, fixtureVerifier{}, nil, nil)
	body := map[string]any{"action_id": "review-workspace-canonical", "title": "  公司  "}
	status, first := request(t, h, "human-test", "POST", "/v1/workspaces", body)
	require.Equal(t, 201, status)
	workspace := first["workspace"].(map[string]any)
	var persistedTitle string
	require.NoError(t, s.Pool.QueryRow(context.Background(), "SELECT title FROM workspaces WHERE id=$1", workspace["id"]).Scan(&persistedTitle))
	require.Equal(t, persistedTitle, workspace["title"], "the response must describe the committed workspace, not raw request whitespace")
	body["title"] = "公司"
	replay := structured(t, call(t, h, "human-test", "workspace_create", body))
	require.Equal(t, first, replay, "equivalent requests must return the same durable receipt across protocols")
}

func TestReviewMCPExecutionErrorsCarrySameSafeCodeAsAPI(t *testing.T) {
	s := httpStore(t)
	h := New(s, fixtureVerifier{}, nil, nil)
	for _, tc := range []struct {
		name, path, tool string
		body, args       map[string]any
		status           int
	}{
		{"invalid", "/v1/workspaces", "workspace_create", map[string]any{"action_id": "review-invalid-workspace", "title": ""}, map[string]any{"action_id": "review-invalid-workspace", "title": ""}, 400},
		{"forbidden", "/v1/rooms", "room_create", map[string]any{"action_id": "review-unauthorized-room", "workspace_id": uuid.NewString(), "title": "未授权"}, nil, 403},
	} {
		t.Run(tc.name, func(t *testing.T) {
			status, api := request(t, h, "human-test", "POST", tc.path, tc.body)
			require.Equal(t, tc.status, status)
			args := tc.args
			if args == nil {
				args = tc.body
			}
			result := call(t, h, "human-test", tc.tool, args)
			require.Equal(t, true, result["isError"])
			details, ok := result["structuredContent"].(map[string]any)
			require.True(t, ok, "machine clients need a safe structured error code, not one indistinguishable text for every failure")
			require.Equal(t, api["error"], details["error"])
		})
	}
}

func TestReviewMCPParameterlessToolsPermitOmittedArguments(t *testing.T) {
	s := httpStore(t)
	h := New(s, fixtureVerifier{}, nil, nil)
	for _, name := range []string{"identity_read", "room_list"} {
		t.Run(name, func(t *testing.T) {
			status, response := request(t, h, "human-test", "POST", "/v1/mcp", map[string]any{
				"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": map[string]any{"name": name},
			})
			require.Equal(t, 200, status)
			result, ok := response["result"].(map[string]any)
			require.True(t, ok)
			require.NotEqual(t, true, result["isError"], "MCP CallToolRequest.arguments is optional; omission means no supplied arguments")
			require.Contains(t, result, "structuredContent")
		})
	}
}

func TestReviewMCPUnknownToolIsProtocolError(t *testing.T) {
	s := httpStore(t)
	h := New(s, fixtureVerifier{}, nil, nil)
	status, response := request(t, h, "human-test", "POST", "/v1/mcp", map[string]any{
		"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": map[string]any{"name": "not_a_registered_tool", "arguments": map[string]any{}},
	})
	require.Equal(t, 200, status)
	err, ok := response["error"].(map[string]any)
	require.True(t, ok, "unknown tool names are protocol errors rather than attempted business operations")
	require.Equal(t, float64(-32602), err["code"])
	require.NotContains(t, response, "result")
}

func TestReviewCurrentPermissionsAndCrossResourceActionFence(t *testing.T) {
	s := httpStore(t)
	ctx := context.Background()
	h := New(s, fixtureVerifier{}, nil, nil)
	owner, err := s.ResolveIdentity(ctx, "test-only-issuer", "human-test")
	require.NoError(t, err)
	w, err := s.CreateWorkspace(ctx, owner.ID, "review-create-workspace", "审查空间")
	require.NoError(t, err)
	_, err = s.CreateRoom(ctx, owner.ID, "review-create-workspace", w, "不可跨资源借用动作", nil)
	require.ErrorIs(t, err, domain.ErrConflict)
	r, err := s.CreateRoom(ctx, owner.ID, "review-create-room", w, "审查群", nil)
	require.NoError(t, err)
	stopped, err := s.SetStopped(ctx, owner.ID, r.ID, "review-stop-room", r.Version, true)
	require.NoError(t, err)
	resumed, err := s.SetStopped(ctx, owner.ID, r.ID, "review-resume-room", stopped.Version, false)
	require.NoError(t, err)
	replayed, err := s.SetStopped(ctx, owner.ID, r.ID, "review-stop-room", r.Version, true)
	require.NoError(t, err)
	require.Equal(t, stopped, replayed, "a replay is the original receipt, not a new policy write")
	var current domain.Room
	require.NoError(t, s.Pool.QueryRow(ctx, "SELECT version,scope_epoch,stopped FROM rooms WHERE id=$1", r.ID).Scan(&current.Version, &current.ScopeEpoch, &current.Stopped))
	require.Equal(t, resumed.Version, current.Version)
	require.False(t, current.Stopped)
	_, err = s.Pool.Exec(ctx, "UPDATE room_members SET role='member' WHERE room_id=$1 AND principal_id=$2", r.ID, owner.ID)
	require.NoError(t, err)
	_, err = s.SetStopped(ctx, owner.ID, r.ID, "review-stop-room", r.Version, true)
	require.ErrorIs(t, err, domain.ErrForbidden, "current role must fence replay, even though the original action was authorized")
	policy := map[string]any{"room_id": r.ID, "action_id": "review-stop-room", "expected_version": r.Version, "stopped": true}
	require.Equal(t, true, call(t, h, "human-test", "room_execution_policy", policy)["isError"])
	_, err = s.Pool.Exec(ctx, "DELETE FROM workspace_members WHERE workspace_id=$1 AND principal_id=$2", w, owner.ID)
	require.NoError(t, err)
	_, err = s.CreateWorkspace(ctx, owner.ID, "review-create-workspace", "审查空间")
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = s.CreateRoom(ctx, owner.ID, "review-create-room", w, "审查群", nil)
	require.ErrorIs(t, err, domain.ErrForbidden)
	_, err = s.Messages(ctx, owner.ID, r.ID, 0)
	require.ErrorIs(t, err, domain.ErrForbidden)
}

func TestReviewPaginationAcrossAPIAndMCP(t *testing.T) {
	s := httpStore(t)
	ctx := context.Background()
	h := New(s, fixtureVerifier{}, nil, nil)
	owner, err := s.ResolveIdentity(ctx, "test-only-issuer", "human-test")
	require.NoError(t, err)
	w, err := s.CreateWorkspace(ctx, owner.ID, "review-pagination-workspace", "分页验证")
	require.NoError(t, err)
	var sampleRoom string
	for index := 0; index < 102; index++ {
		r, err := s.CreateRoom(ctx, owner.ID, fmt.Sprintf("review-pagination-room-%03d", index), w, "合成分页群", nil)
		require.NoError(t, err)
		sampleRoom = r.ID
	}
	status, first := request(t, h, "human-test", "GET", "/v1/rooms", nil)
	require.Equal(t, 200, status)
	require.Len(t, first["rooms"], 100)
	require.Equal(t, first, structured(t, call(t, h, "human-test", "room_list", map[string]any{})))
	cursor := first["cursor"].(string)
	require.NotEmpty(t, cursor)
	status, last := request(t, h, "human-test", "GET", "/v1/rooms?after="+cursor, nil)
	require.Equal(t, 200, status)
	require.Len(t, last["rooms"], 2)
	require.Empty(t, last["cursor"])
	require.Equal(t, last, structured(t, call(t, h, "human-test", "room_list", map[string]any{"after": cursor})))
	seen := map[string]bool{}
	for _, page := range []map[string]any{first, last} {
		for _, item := range page["rooms"].([]any) {
			id := item.(map[string]any)["id"].(string)
			require.False(t, seen[id])
			seen[id] = true
		}
	}
	require.Len(t, seen, 102)
	for index := 0; index < 102; index++ {
		_, err := s.Send(ctx, owner.ID, sampleRoom, domain.SendMessage{ActionID: fmt.Sprintf("review-pagination-message-%03d", index), Content: "合成分页消息"})
		require.NoError(t, err)
	}
	status, first = request(t, h, "human-test", "GET", "/v1/rooms/"+sampleRoom+"/messages", nil)
	require.Equal(t, 200, status)
	require.Len(t, first["messages"], 100)
	require.Equal(t, true, first["has_more"])
	require.Equal(t, float64(100), first["cursor"])
	require.Equal(t, first, structured(t, call(t, h, "human-test", "message_read", map[string]any{"room_id": sampleRoom})))
	status, last = request(t, h, "human-test", "GET", "/v1/rooms/"+sampleRoom+"/messages?after=100", nil)
	require.Equal(t, 200, status)
	require.Len(t, last["messages"], 2)
	require.Equal(t, false, last["has_more"])
	require.Equal(t, float64(102), last["cursor"])
	require.Equal(t, last, structured(t, call(t, h, "human-test", "message_read", map[string]any{"room_id": sampleRoom, "after": 100})))
}
