package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
	"github.com/huapohen/active-agent/services/collaboration/internal/transport"
	"github.com/stretchr/testify/require"
)

type transportRunFixture struct {
	s                                                      *store.Store
	h                                                      http.Handler
	owner, agent                                           string
	source, target, other                                  domain.Room
	parent, run, otherRun                                  store.ExecutionRun
	bindings                                               []transport.BridgeBinding
	rootArrival, sourceArrival, humanArrival, otherArrival domain.TransportArrival
}

func newTransportRunFixture(t *testing.T) transportRunFixture {
	t.Helper()
	ctx := context.Background()
	f := transportRunFixture{s: httpStore(t)}
	owner, err := f.s.ResolveIdentity(ctx, "test-only-issuer", "human-test")
	require.NoError(t, err)
	f.owner, f.agent = owner.ID, uuid.NewString()
	_, err = f.s.Pool.Exec(ctx, "INSERT INTO principals(id,kind,display_name) VALUES($1,'agent','原生接收同事')", f.agent)
	require.NoError(t, err)
	w, err := f.s.CreateWorkspace(ctx, f.owner, "transport-run-workspace", "隔离 Run 接收验收")
	require.NoError(t, err)
	_, err = f.s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", w, f.agent)
	require.NoError(t, err)
	f.source, err = f.s.CreateRoom(ctx, f.owner, "transport-run-source", w, "父来源", []string{f.agent})
	require.NoError(t, err)
	f.target, err = f.s.CreateRoom(ctx, f.owner, "transport-run-target", w, "当前来源", []string{f.agent})
	require.NoError(t, err)
	f.other, err = f.s.CreateRoom(ctx, f.owner, "transport-run-other", w, "不同 Run 的会话", []string{f.agent})
	require.NoError(t, err)
	b, err := f.s.RegisterExecutor(ctx, f.owner, store.RegisterExecutorCommand{ActionID: "transport-run-binding", WorkspaceID: w, AgentPrincipalID: f.agent, Issuer: "https://fixture.clerk.accounts.dev", MachineSubject: "mch_fixture", Enabled: true})
	require.NoError(t, err)
	_, err = f.s.SetAgentExecutionPolicy(ctx, f.owner, store.AgentExecutionPolicyCommand{ActionID: "transport-run-policy", WorkspaceID: w, AgentPrincipalID: f.agent, ProactiveEnabled: true, ExpectedVersion: 1})
	require.NoError(t, err)
	create := func(room domain.Room, parent string) store.ExecutionRun {
		r, e := f.s.CreateExecutionRun(ctx, f.owner, store.CreateExecutionRunCommand{ActionID: uuid.NewString(), ExecutorID: b.ExecutorID, RoomID: room.ID, ScopeEpoch: room.ScopeEpoch, ParentRunID: parent, Goal: "只读观察自己的 SDK 接收事实"})
		require.NoError(t, e)
		return r
	}
	f.parent = create(f.source, "")
	f.run = create(f.target, f.parent.Context.RunID)
	f.otherRun = create(f.other, "")
	arrival := func(room domain.Room, receiver string) domain.TransportArrival {
		binding := transport.BridgeBinding{ID: "read-" + uuid.NewString(), RoomID: room.ID, ReceiverID: receiver, Secret: strings.Repeat("fixture", 8)}
		f.bindings = append(f.bindings, binding)
		sent, e := f.s.Send(ctx, f.owner, room.ID, domain.SendMessage{ActionID: uuid.NewString(), Content: "隔离测试的 canonical message", ScopeEpoch: &room.ScopeEpoch})
		require.NoError(t, e)
		uid := uuid.NewString()
		// Isolated-schema accepted-provider fixture; no network/provider request.
		accepted, _ := json.Marshal(map[string]any{"code": 200, "messageUIDs": []map[string]string{{"groupId": room.ID, "messageUID": uid}}})
		_, e = f.s.Pool.Exec(ctx, `UPDATE transport_outbox SET status='delivered',provider_receipt=$2 WHERE event_id IN(SELECT id FROM events WHERE type='message.created' AND data->>'id'=$1)`, sent.Message.ID, accepted)
		require.NoError(t, e)
		pointer, _ := json.Marshal(map[string]any{"schema": "renji.message.v1", "room_id": room.ID, "message_id": sent.Message.ID, "seq": sent.Message.Seq})
		content, _ := json.Marshal(map[string]string{"content": sent.Message.Content, "extra": string(pointer)})
		raw, _ := json.Marshal(transport.SDKReceived{Schema: "renji.rongcloud.sdk-received.v1", MessageUID: uid, ConversationType: 3, TargetID: room.ID, SenderID: f.owner, MessageType: "RC:TxtMsg", Content: content, ReceivedTime: 123})
		a, e := f.s.RecordTransportIngress(ctx, binding, raw)
		require.NoError(t, e)
		require.NoError(t, f.s.RecordTransportHeartbeat(ctx, binding, "connected", 1))
		return a
	}
	f.rootArrival = arrival(f.target, f.agent)
	f.humanArrival = arrival(f.target, f.owner)
	f.otherArrival = arrival(f.other, f.agent)
	f.sourceArrival = arrival(f.source, f.agent)
	f.h = New(f.s, fixtureVerifier{}, nil, nil, WithMachineVerifier(fixtureMachineVerifier{}), WithRongCloudBridges(f.bindings))
	return f
}

func transportMCPRejected(t *testing.T, h http.Handler, token string, args any) {
	t.Helper()
	status, out := request(t, h, token, "POST", "/v1/mcp", map[string]any{"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": map[string]any{"name": "transport_arrival_read", "arguments": args}})
	require.Equal(t, 200, status)
	if rpcError, ok := out["error"].(map[string]any); ok {
		require.Equal(t, float64(-32602), rpcError["code"])
	} else {
		result := out["result"].(map[string]any)
		require.Equal(t, true, result["isError"])
		if content, ok := result["structuredContent"].(map[string]any); ok {
			require.NotContains(t, content, "events")
			require.NotContains(t, content, "status")
		}
	}
}

func TestTransportRunHTTPAndMCPReadOnlyCurrentReceiverCoverage(t *testing.T) {
	f := newTransportRunFixture(t)
	path := "/v1/transport/events?run_id=" + f.run.Context.RunID + "&limit=1"
	status, page := request(t, f.h, "mt_fixture", "GET", path, nil)
	require.Equal(t, 200, status)
	args := map[string]any{"run_id": f.run.Context.RunID, "limit": 1}
	require.Equal(t, page, structured(t, call(t, f.h, "mt_fixture", "transport_arrival_read", args)))
	require.Equal(t, f.agent, page["receiver_id"])
	require.Equal(t, f.run.Context.RunID, page["run_id"])
	rooms := []string{f.source.ID, f.target.ID}
	sort.Strings(rooms)
	require.Equal(t, []any{rooms[0], rooms[1]}, page["covered_room_ids"])
	events := page["events"].([]any)
	require.Len(t, events, 1)
	require.Equal(t, f.rootArrival.ProviderUID, events[0].(map[string]any)["provider_uid"])
	require.Equal(t, true, page["has_more"])
	after := int64(page["next_cursor"].(float64))
	status, page = request(t, f.h, "mt_fixture", "GET", fmt.Sprintf("%s&after=%d", path, after), nil)
	require.Equal(t, 200, status)
	args["after"] = after
	require.Equal(t, page, structured(t, call(t, f.h, "mt_fixture", "transport_arrival_read", args)))
	events = page["events"].([]any)
	require.Len(t, events, 1)
	require.Equal(t, f.sourceArrival.ProviderUID, events[0].(map[string]any)["provider_uid"])
	require.Equal(t, false, page["has_more"])
	// Human history retains the existing shape and exact human SDK receiver.
	status, human := request(t, f.h, "human-test", "GET", "/v1/transport/events", nil)
	require.Equal(t, 200, status)
	require.NotContains(t, human, "run_id")
	require.NotContains(t, human, "receiver_id")
	humanEvents := human["events"].([]any)
	require.Len(t, humanEvents, 1)
	require.Equal(t, f.humanArrival.ProviderUID, humanEvents[0].(map[string]any)["provider_uid"])
	require.Equal(t, human, structured(t, call(t, f.h, "human-test", "transport_arrival_read", map[string]any{})))
	// Inspect tool shape without a private/provider configuration.
	for _, token := range []string{"human-test", "mt_fixture"} {
		status, out := request(t, f.h, token, "POST", "/v1/mcp", map[string]any{"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
		require.Equal(t, 200, status)
		found := false
		for _, v := range out["result"].(map[string]any)["tools"].([]any) {
			item := v.(map[string]any)
			if item["name"] != "transport_arrival_read" {
				continue
			}
			found = true
			schema := item["inputSchema"].(map[string]any)
			properties := schema["properties"].(map[string]any)
			if token == "mt_fixture" {
				require.Contains(t, schema["required"], "run_id")
			} else {
				require.NotContains(t, properties, "run_id")
			}
			require.NotContains(t, properties, "receiver_id")
			require.NotContains(t, properties, "room_id")
		}
		require.True(t, found)
	}
}

func TestTransportRunHTTPMCPRejectMissingRunAndInvalidPagination(t *testing.T) {
	f := newTransportRunFixture(t)
	for _, query := range []string{"", "?run_id=", "?run_id=null", "?run_id=" + uuid.NewString()} {
		status, page := request(t, f.h, "mt_fixture", "GET", "/v1/transport/events"+query, nil)
		require.True(t, status == 400 || status == 403)
		require.NotContains(t, page, "events")
	}
	transportMCPRejected(t, f.h, "mt_fixture", map[string]any{})
	for _, q := range []string{"after=null", "after=9007199254740992", "after=-1", "after=1.5", "after=", "after=0&after=1", "limit=null", "limit=9007199254740992", "limit=0", "limit=101", "limit=-1", "limit=1.5", "limit=", "limit=1&limit=2", "receiver_id=" + f.owner} {
		status, _ := request(t, f.h, "mt_fixture", "GET", "/v1/transport/events?run_id="+f.run.Context.RunID+"&"+q, nil)
		require.Equal(t, 400, status, q)
	}
	for _, field := range []string{"after", "limit"} {
		for _, value := range []any{nil, int64(9007199254740992), -1, 1.5, "0"} {
			transportMCPRejected(t, f.h, "mt_fixture", map[string]any{"run_id": f.run.Context.RunID, field: value})
		}
	}
	for _, value := range []any{0, 101} {
		transportMCPRejected(t, f.h, "mt_fixture", map[string]any{"run_id": f.run.Context.RunID, "limit": value})
	}
	for _, token := range []string{"human-test", "mt_fixture"} {
		transportMCPRejected(t, f.h, token, map[string]any{"run_id": f.run.Context.RunID, "receiver_id": f.owner})
	}
	for _, value := range []any{f.run.Context.RunID, "", nil} {
		transportMCPRejected(t, f.h, "human-test", map[string]any{"run_id": value})
	}
	for _, q := range []string{"?run_id=" + f.run.Context.RunID, "?run_id=", "?run_id=null"} {
		status, _ := request(t, f.h, "human-test", "GET", "/v1/transport/events"+q, nil)
		require.Equal(t, 400, status)
	}
}

func TestTransportRunHTTPMCPCursorAndStopRetainAllSources(t *testing.T) {
	f := newTransportRunFixture(t)
	path := "/v1/transport/events?run_id=" + f.run.Context.RunID
	for _, cursor := range []int64{f.humanArrival.Cursor, f.otherArrival.Cursor} {
		status, out := request(t, f.h, "mt_fixture", "GET", fmt.Sprintf("%s&after=%d", path, cursor), nil)
		require.Equal(t, 400, status)
		require.NotContains(t, out, "events")
		transportMCPRejected(t, f.h, "mt_fixture", map[string]any{"run_id": f.run.Context.RunID, "after": cursor})
	}
	// The other Run has current rights to its own cursor, which must not be
	// portable to this child Run simply because the same Agent owns both.
	status, other := request(t, f.h, "mt_fixture", "GET", "/v1/transport/events?run_id="+f.otherRun.Context.RunID, nil)
	require.Equal(t, 200, status)
	require.Equal(t, float64(f.otherArrival.Cursor), other["next_cursor"])
	stopped, err := f.s.SetStopped(context.Background(), f.owner, f.source.ID, "transport-http-source-stop", f.source.Version, true)
	require.NoError(t, err)
	for _, resumed := range []bool{false, true} {
		if resumed {
			_, err = f.s.SetStopped(context.Background(), f.owner, f.source.ID, "transport-http-source-resume", stopped.Version, false)
			require.NoError(t, err)
		}
		status, out := request(t, f.h, "mt_fixture", "GET", fmt.Sprintf("%s&after=%d", path, f.rootArrival.Cursor), nil)
		require.Equal(t, 409, status)
		require.NotContains(t, out, "events")
		require.NotContains(t, out, "status")
		transportMCPRejected(t, f.h, "mt_fixture", map[string]any{"run_id": f.run.Context.RunID, "after": f.rootArrival.Cursor})
	}
	// A stop is not removal of the human's membership/history permission.
	status, _ = request(t, f.h, "human-test", "GET", "/v1/transport/events", nil)
	require.Equal(t, 200, status)
}

func TestTransportRunUnconfiguredStillAuthenticatesBeforeUnavailable(t *testing.T) {
	f := newTransportRunFixture(t)
	h := New(f.s, fixtureVerifier{}, nil, nil, WithMachineVerifier(fixtureMachineVerifier{}))
	status, page := request(t, h, "mt_fixture", "GET", "/v1/transport/events?run_id="+f.run.Context.RunID, nil)
	require.Equal(t, 200, status)
	require.Equal(t, f.agent, page["receiver_id"])
	require.Empty(t, page["events"])
	state := page["status"].(map[string]any)
	require.Equal(t, "unavailable", state["bridge_state"])
	require.Nil(t, state["last_heartbeat_at"])
	require.Nil(t, state["last_received_at"])
	require.Equal(t, page, structured(t, call(t, h, "mt_fixture", "transport_arrival_read", map[string]any{"run_id": f.run.Context.RunID})))
	status, _ = request(t, h, "mt_fixture", "GET", "/v1/transport/events", nil)
	require.Equal(t, 400, status)
	status, _ = request(t, h, "mt_unbound", "GET", "/v1/transport/events?run_id="+f.run.Context.RunID, nil)
	require.Equal(t, 403, status)
	_, err := f.s.SetStopped(context.Background(), f.owner, f.source.ID, "transport-no-config-stop", f.source.Version, true)
	require.NoError(t, err)
	status, out := request(t, h, "mt_fixture", "GET", "/v1/transport/events?run_id="+f.run.Context.RunID, nil)
	require.Equal(t, 409, status)
	require.NotContains(t, out, "events")
	transportMCPRejected(t, h, "mt_fixture", map[string]any{"run_id": f.run.Context.RunID})
}
