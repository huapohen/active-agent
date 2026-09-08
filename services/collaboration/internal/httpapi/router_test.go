package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/auth"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
	"github.com/jackc/pgx/v5"
	"github.com/stretchr/testify/require"
)

type fixtureVerifier struct{}

func (fixtureVerifier) Verify(_ context.Context, token string) (auth.Identity, error) {
	if token != "human-test" && token != "agent-test" && token != "outsider-test" {
		return auth.Identity{}, errors.New("test credential rejected")
	}
	return auth.Identity{Issuer: "test-only-issuer", Subject: token}, nil
}
func httpStore(t *testing.T) *store.Store {
	t.Helper()
	dsn := os.Getenv("RENJI_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("real PostgreSQL requires RENJI_TEST_DATABASE_URL")
	}
	ctx := context.Background()
	admin, err := pgx.Connect(ctx, dsn)
	require.NoError(t, err)
	schema := "http_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	_, err = admin.Exec(ctx, "CREATE SCHEMA "+schema)
	require.NoError(t, err)
	u, err := url.Parse(dsn)
	require.NoError(t, err)
	q := u.Query()
	q.Set("search_path", schema)
	u.RawQuery = q.Encode()
	s, err := store.Open(ctx, u.String())
	require.NoError(t, err)
	t.Cleanup(func() { s.Close(); admin.Exec(ctx, "DROP SCHEMA "+schema+" CASCADE"); admin.Close(ctx) })
	require.NoError(t, s.Migrate(ctx))
	return s
}
func request(t *testing.T, h http.Handler, token, method, path string, body any) (int, map[string]any) {
	t.Helper()
	var data []byte
	if body != nil {
		var err error
		data, err = json.Marshal(body)
		require.NoError(t, err)
	}
	r := httptest.NewRequest(method, path, bytes.NewReader(data))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Accept", "application/json, text/event-stream")
	r.Header.Set("MCP-Protocol-Version", "2025-11-25")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	out := map[string]any{}
	if w.Body.Len() > 0 {
		require.NoError(t, json.Unmarshal(w.Body.Bytes(), &out))
	}
	return w.Code, out
}
func call(t *testing.T, h http.Handler, token, name string, args any) map[string]any {
	t.Helper()
	status, out := request(t, h, token, "POST", "/v1/mcp", map[string]any{"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": map[string]any{"name": name, "arguments": args}})
	require.Equal(t, 200, status)
	return out["result"].(map[string]any)
}
func structured(t *testing.T, out map[string]any) map[string]any {
	t.Helper()
	require.NotEqual(t, true, out["isError"])
	return out["structuredContent"].(map[string]any)
}

func TestAPIAndMCPShareActionsAndCurrentPermissions(t *testing.T) {
	s := httpStore(t)
	ctx := context.Background()
	v := fixtureVerifier{}
	human, err := s.ResolveIdentity(ctx, "test-only-issuer", "human-test")
	require.NoError(t, err)
	agent, err := s.ResolveIdentity(ctx, "test-only-issuer", "agent-test")
	require.NoError(t, err)
	// Fixture identity mapping only; production never accepts an actor kind claim.
	_, err = s.Pool.Exec(ctx, "UPDATE principals SET kind='agent' WHERE id=$1", agent.ID)
	require.NoError(t, err)
	h := New(s, v, nil, []string{"http://127.0.0.1:5173"})
	body := map[string]any{"action_id": "workspace-shared-action", "title": "协议同权"}
	status, out := request(t, h, "human-test", "POST", "/v1/workspaces", body)
	require.Equal(t, 201, status)
	workspace := out["workspace"].(map[string]any)["id"].(string)
	replay := structured(t, call(t, h, "human-test", "workspace_create", body))
	require.Equal(t, out, replay)
	_, err = s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", workspace, agent.ID)
	require.NoError(t, err)
	args := map[string]any{"action_id": "room-shared-action", "workspace_id": workspace, "title": "同权群", "members": []string{human.ID}}
	first := structured(t, call(t, h, "agent-test", "room_create", args))
	room := first["room"].(map[string]any)["id"].(string)
	status, out = request(t, h, "agent-test", "POST", "/v1/rooms", args)
	require.Equal(t, 201, status)
	require.Equal(t, first, out)
	command := map[string]any{"action_id": "message-shared-action", "content": "Agent 原生消息", "scope_epoch": 1}
	status, out = request(t, h, "agent-test", "POST", "/v1/rooms/"+room+"/messages", command)
	require.Equal(t, 200, status)
	command["room_id"] = room
	again := structured(t, call(t, h, "agent-test", "message_send", command))
	require.Equal(t, out["message"], again["message"])
	require.Equal(t, true, again["replayed"])
	status, out = request(t, h, "human-test", "GET", "/v1/rooms/"+room+"/messages", nil)
	require.Equal(t, 200, status)
	read := structured(t, call(t, h, "human-test", "message_read", map[string]any{"room_id": room}))
	require.Equal(t, out, read)
	denied := call(t, h, "outsider-test", "message_read", map[string]any{"room_id": room})
	require.Equal(t, true, denied["isError"])
	status, _ = request(t, h, "outsider-test", "GET", "/v1/rooms/"+room+"/messages", nil)
	require.Equal(t, 403, status)
	policy := map[string]any{"action_id": "policy-shared-action", "room_id": room, "expected_version": 1, "stopped": true}
	stopped := structured(t, call(t, h, "agent-test", "room_execution_policy", policy))
	status, out = request(t, h, "agent-test", "POST", "/v1/rooms/"+room+"/execution-policy", policy)
	require.Equal(t, 200, status)
	require.Equal(t, stopped, out)
	command["action_id"] = "new-after-stop-action"
	require.Equal(t, true, call(t, h, "agent-test", "message_send", command)["isError"])
	status, out = request(t, h, "human-test", "POST", "/v1/rooms/"+room+"/messages", map[string]any{"action_id": "human-intervene-action", "content": "人类干预"})
	require.Equal(t, 200, status)
	_, err = s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", room, agent.ID)
	require.NoError(t, err)
	command["action_id"] = "message-shared-action"
	require.Equal(t, true, call(t, h, "agent-test", "message_send", command)["isError"])
	require.Equal(t, true, call(t, h, "agent-test", "room_execution_policy", policy)["isError"])
	status, _ = request(t, h, "agent-test", "GET", "/v1/rooms/"+room+"/messages", nil)
	require.Equal(t, 403, status)
}

func TestMCPProtocolAndOriginBoundaries(t *testing.T) {
	s := httpStore(t)
	h := New(s, fixtureVerifier{}, nil, []string{"http://127.0.0.1:5173"})
	for _, token := range []string{"", "arbitrary"} {
		code, _ := request(t, h, token, "GET", "/v1/me", nil)
		require.Equal(t, 401, code)
	}
	code, out := request(t, h, "human-test", "POST", "/v1/mcp", map[string]any{"jsonrpc": "2.0", "id": "init-1", "method": "initialize", "params": map[string]any{"protocolVersion": "older-unsupported", "capabilities": map[string]any{}, "clientInfo": map[string]any{"name": "test", "version": "1"}}})
	require.Equal(t, 200, code)
	require.Equal(t, "2025-11-25", out["result"].(map[string]any)["protocolVersion"])
	code, _ = request(t, h, "human-test", "POST", "/v1/mcp", map[string]any{"jsonrpc": "2.0", "method": "notifications/initialized"})
	require.Equal(t, 202, code)
	code, out = request(t, h, "human-test", "POST", "/v1/mcp", map[string]any{"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
	require.Equal(t, 200, code)
	require.Len(t, out["result"].(map[string]any)["tools"], 10)
	code, _ = request(t, h, "human-test", "GET", "/v1/mcp", nil)
	require.Equal(t, 405, code)
	code, _ = request(t, h, "human-test", "POST", "/v1/mcp", map[string]any{"jsonrpc": "2.0", "id": map[string]string{"invalid": "id"}, "method": "ping"})
	require.Equal(t, 400, code)
	for _, header := range []struct{ name, value string }{{"Origin", "https://attacker.example"}, {"MCP-Protocol-Version", "invalid"}} {
		r := httptest.NewRequest("POST", "/v1/mcp", strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Authorization", "Bearer human-test")
		r.Header.Set("MCP-Protocol-Version", "2025-11-25")
		r.Header.Set(header.name, header.value)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if header.name == "Origin" {
			require.Equal(t, 403, w.Code)
		} else {
			require.Equal(t, 400, w.Code)
		}
	}
	code, out = request(t, h, "human-test", "GET", "/v1/capabilities", nil)
	require.Equal(t, 200, code)
	require.Equal(t, "renji.capabilities.v1", out["schema"])
	for _, entry := range out["capabilities"].([]any) {
		p := entry.(map[string]any)["protocols"].(map[string]any)
		require.Equal(t, false, p["a2a"])
	}
}
