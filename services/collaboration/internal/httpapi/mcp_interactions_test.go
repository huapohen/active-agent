package httpapi

import (
	"context"
	"net/http"
	"path/filepath"
	"runtime"
	"strconv"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/auth"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/emoji"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
	"github.com/stretchr/testify/require"
)

func mcpEmojiBundle(t *testing.T) emoji.Provider {
	t.Helper()
	_, f, _, _ := runtime.Caller(0)
	p, err := emoji.NewLocal(filepath.Join(filepath.Dir(f), "../../../../apps/office/assets/emoji"))
	require.NoError(t, err)
	return p
}

func TestMCPInteractionCapabilityRegistryAndSchemas(t *testing.T) {
	p := mcpEmojiBundle(t)
	for _, catalog := range []emoji.Provider{nil, p} {
		for _, isMachine := range []bool{false, true} {
			g := gin.New()
			v1 := g.Group("/v1")
			v1.Use(func(c *gin.Context) {
				c.Set("principal", domain.Principal{ID: uuid.NewString()})
				if isMachine {
					c.Set("machine", auth.MachineIdentity{Issuer: "fixture", MachineSubject: "fixture"})
				}
			})
			mountNative(v1, nil, config{emoji: catalog})
			code, caps := request(t, g, "", "GET", "/v1/capabilities", nil)
			require.Equal(t, 200, code)
			require.Equal(t, "renji.capabilities.v1", caps["schema"])
			require.Len(t, caps["capabilities"], 23)
			ids := map[string]bool{}
			for _, raw := range caps["capabilities"].([]any) {
				c := raw.(map[string]any)
				id := c["id"].(string)
				ids[id] = true
				require.Equal(t, "1", c["version"])
				available := catalog != nil || (id != "emoji.read" && id != "message.reaction.set")
				reason := "emoji_catalog_unavailable"
				if isMachine && c["machine_access"] == "gateway_action_pending" {
					available = false
					reason = "machine_action_not_implemented"
				}
				if id == "transport.session" {
					available = false
					reason = "rongcloud_client_write_policy_unverified"
				}
				if isMachine && id == "transport.arrival.read" {
					available = false
					reason = "run_scoped_receive_pending"
				}
				require.Equal(t, available, c["available"], id)
				if !available {
					require.Equal(t, reason, c["unavailable_reason"])
				} else {
					require.NotContains(t, c, "unavailable_reason")
				}
			}
			for _, id := range []string{"message.reply", "message.reaction.set", "message.reaction.read", "emoji.read", "transport.arrival.read"} {
				require.True(t, ids[id], id)
			}
			code, out := request(t, g, "", "POST", "/v1/mcp", map[string]any{"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
			require.Equal(t, 200, code)
			tools := out["result"].(map[string]any)["tools"].([]any)
			expected := 20
			if isMachine {
				expected = 17
			}
			if catalog == nil {
				expected -= 3
			}
			require.Len(t, tools, expected)
			names := map[string]bool{}
			for _, raw := range tools {
				tool := raw.(map[string]any)
				name := tool["name"].(string)
				names[name] = true
				if name != "message_send" && name != "message_reaction_set" && name != "profile_update" {
					continue
				}
				schema := tool["inputSchema"].(map[string]any)
				props := schema["properties"].(map[string]any)
				if isMachine {
					require.Contains(t, schema["required"], "run_id")
					require.Equal(t, "^[a-fA-F0-9]{64}$", props["action_id"].(map[string]any)["pattern"])
				}
				if name == "message_reaction_set" {
					require.Contains(t, schema["required"], "active")
					require.Equal(t, "boolean", props["active"].(map[string]any)["type"])
				} else if name == "message_send" {
					require.Contains(t, props, "reply_to")
				} else {
					require.Contains(t, schema["required"], "expected_version")
					require.Contains(t, schema["required"], "display_name")
				}
			}
			for _, name := range []string{"message_get", "message_reaction_read"} {
				require.True(t, names[name], name)
			}
			for _, name := range []string{"message_reaction_set", "emoji_list", "emoji_get"} {
				require.Equal(t, catalog != nil, names[name], name)
			}
			if isMachine {
				require.False(t, names["workspace_create"])
				require.False(t, names["room_create"])
				require.False(t, names["room_execution_policy"])
			}
			if catalog == nil {
				for _, name := range []string{"emoji_list", "emoji_get", "message_reaction_set"} {
					result := call(t, g, "", name, map[string]any{})
					require.Equal(t, true, result["isError"])
					require.Equal(t, "emoji_catalog_unavailable", result["structuredContent"].(map[string]any)["error"])
				}
			}
		}
	}
}

func mcpRejectArguments(t *testing.T, h http.Handler, token, name string, args any) {
	t.Helper()
	code, out := request(t, h, token, "POST", "/v1/mcp", map[string]any{"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": map[string]any{"name": name, "arguments": args}})
	require.Equal(t, 200, code)
	require.Equal(t, float64(-32602), out["error"].(map[string]any)["code"])
}

func TestTransportCapabilitiesMatchPrincipalReadiness(t *testing.T) {
	allowed := uuid.NewString()
	for _, tc := range []struct {
		name, principal string
		machine         bool
		wantSession     bool
	}{
		{"ordinary_human", uuid.NewString(), false, false},
		{"allowlisted_human", allowed, false, true},
		{"ordinary_machine", uuid.NewString(), true, false},
		{"allowlisted_machine", allowed, true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			g := gin.New()
			v1 := g.Group("/v1")
			v1.Use(func(c *gin.Context) {
				c.Set("principal", domain.Principal{ID: tc.principal})
				if tc.machine {
					c.Set("machine", auth.MachineIdentity{Issuer: "fixture", MachineSubject: "fixture"})
				}
			})
			mountNative(v1, nil, config{transportTestPrincipals: map[string]bool{allowed: true}})
			code, result := request(t, g, "", "GET", "/v1/capabilities", nil)
			require.Equal(t, 200, code)
			found := map[string]map[string]any{}
			for _, raw := range result["capabilities"].([]any) {
				entry := raw.(map[string]any)
				found[entry["id"].(string)] = entry
			}
			require.Equal(t, tc.wantSession, found["transport.session"]["available"])
			arrival := found["transport.arrival.read"]
			require.Equal(t, !tc.machine, arrival["available"])
			require.Equal(t, true, arrival["exportable"])
			require.Equal(t, map[string]any{"api": true, "mcp": false, "a2a": false}, arrival["protocols"])
			if tc.machine {
				require.Equal(t, "run_scoped_receive_pending", arrival["unavailable_reason"])
			}
		})
	}
}

func TestMCPHumanInteractionsMatchAPIAndCurrentRoomAuthorization(t *testing.T) {
	s := httpStore(t)
	ctx := context.Background()
	p := mcpEmojiBundle(t)
	s.SetReactionEmojiValidator(p)
	owner, err := s.ResolveIdentity(ctx, "test-only-issuer", "human-test")
	require.NoError(t, err)
	w, err := s.CreateWorkspace(ctx, owner.ID, "mcp-interaction-workspace", "MCP interaction fixture")
	require.NoError(t, err)
	room, err := s.CreateRoom(ctx, owner.ID, "mcp-interaction-room", w, "Target", nil)
	require.NoError(t, err)
	h := New(s, fixtureVerifier{}, nil, nil, WithEmojiProvider(p))
	var messages []domain.Message
	for i := 1; i <= 5; i++ {
		receipt, err := s.Send(ctx, owner.ID, room.ID, domain.SendMessage{ActionID: "mcp-seed-message-" + strconv.Itoa(i), Content: "消息 " + strconv.Itoa(i)})
		require.NoError(t, err)
		messages = append(messages, receipt.Message)
	}
	get := structured(t, call(t, h, "human-test", "message_get", map[string]any{"room_id": room.ID, "message_id": messages[0].ID}))
	code, api := request(t, h, "human-test", "GET", "/v1/rooms/"+room.ID+"/messages/"+messages[0].ID, nil)
	require.Equal(t, 200, code)
	require.Equal(t, api, get)
	for _, q := range []struct {
		args        map[string]any
		query       string
		first, last float64
	}{
		{map[string]any{"after": 0, "limit": 2}, "?after=0&limit=2", 1, 2},
		{map[string]any{"before": 0, "limit": 2}, "?before=0&limit=2", 4, 5},
		{map[string]any{"before": 4, "limit": 2}, "?before=4&limit=2", 2, 3},
	} {
		q.args["room_id"] = room.ID
		page := structured(t, call(t, h, "human-test", "message_read", q.args))
		code, api := request(t, h, "human-test", "GET", "/v1/rooms/"+room.ID+"/messages"+q.query, nil)
		require.Equal(t, 200, code)
		require.Equal(t, api, page)
		items := page["messages"].([]any)
		require.Len(t, items, 2)
		require.Equal(t, q.first, items[0].(map[string]any)["seq"])
		require.Equal(t, q.last, items[1].(map[string]any)["seq"])
	}
	for _, args := range []map[string]any{{"after": 0, "before": 0}, {"after": nil}, {"run_id": nil}, {"before": nil}, {"before": -1}, {"limit": 0}, {"limit": 101}, {"limit": 1.5}, {"unexpected": true}} {
		args["room_id"] = room.ID
		mcpRejectArguments(t, h, "human-test", "message_read", args)
	}
	for _, name := range []string{"message_get", "message_reaction_read"} {
		out := call(t, h, "outsider-test", name, map[string]any{"room_id": room.ID, "message_id": messages[0].ID})
		require.Equal(t, true, out["isError"])
		out = call(t, h, "human-test", name, map[string]any{"room_id": uuid.NewString(), "message_id": messages[0].ID})
		require.Equal(t, true, out["isError"])
	}
	send := map[string]any{"room_id": room.ID, "action_id": "mcp-reply-exact-action", "content": "引用后回复", "reply_to": messages[0].ID}
	reply := structured(t, call(t, h, "human-test", "message_send", send))
	require.Equal(t, messages[0].ID, reply["message"].(map[string]any)["reply_to"])
	code, api = request(t, h, "human-test", "POST", "/v1/rooms/"+room.ID+"/messages", map[string]any{"action_id": send["action_id"], "content": send["content"], "reply_to": send["reply_to"]})
	require.Equal(t, 200, code)
	require.Equal(t, reply["message"], api["message"])
	require.Equal(t, true, api["replayed"])
	set := map[string]any{"room_id": room.ID, "message_id": messages[0].ID, "action_id": "mcp-reaction-set-action", "emoji": "feishu:OK", "active": true}
	reaction := structured(t, call(t, h, "human-test", "message_reaction_set", set))
	require.Equal(t, true, reaction["selected"])
	require.Equal(t, float64(1), reaction["count"])
	code, api = request(t, h, "human-test", "POST", "/v1/rooms/"+room.ID+"/messages/"+messages[0].ID+"/reactions", map[string]any{"action_id": set["action_id"], "emoji": set["emoji"], "active": true})
	require.Equal(t, 200, code)
	require.Equal(t, true, api["replayed"])
	require.Equal(t, reaction["version"], api["version"])
	set["active"] = false
	set["action_id"] = "mcp-reaction-clear-action"
	cleared := structured(t, call(t, h, "human-test", "message_reaction_set", set))
	require.Equal(t, false, cleared["selected"])
	require.Equal(t, float64(0), cleared["count"])
	readArgs := map[string]any{"room_id": room.ID, "message_id": messages[0].ID, "expected_version": cleared["version"], "limit": 1}
	read := structured(t, call(t, h, "human-test", "message_reaction_read", readArgs))
	code, api = request(t, h, "human-test", "GET", "/v1/rooms/"+room.ID+"/messages/"+messages[0].ID+"/reactions?expected_version=2&limit=1", nil)
	require.Equal(t, 200, code)
	require.Equal(t, api, read)
	readArgs["expected_version"] = 1
	require.Equal(t, true, call(t, h, "human-test", "message_reaction_read", readArgs)["isError"])
	for _, active := range []any{nil, "false", float64(1)} {
		set["active"] = active
		set["action_id"] = "invalid-reaction-active"
		require.Equal(t, true, call(t, h, "human-test", "message_reaction_set", set)["isError"])
	}
	delete(set, "active")
	require.Equal(t, true, call(t, h, "human-test", "message_reaction_set", set)["isError"])
	set["active"] = true
	set["emoji"] = "invented:not-in-catalog"
	require.Equal(t, true, call(t, h, "human-test", "message_reaction_set", set)["isError"])
	emojiPage := structured(t, call(t, h, "human-test", "emoji_list", map[string]any{"q": "点赞", "category": "经典表情", "limit": 1}))
	code, api = request(t, h, "human-test", "GET", "/v1/emoji?q=%E7%82%B9%E8%B5%9E&category=%E7%BB%8F%E5%85%B8%E8%A1%A8%E6%83%85&limit=1", nil)
	require.Equal(t, 200, code)
	require.Equal(t, api, emojiPage)
	entry := structured(t, call(t, h, "human-test", "emoji_get", map[string]any{"id": "feishu:OK"}))
	code, api = request(t, h, "human-test", "GET", "/v1/emoji/entries/feishu:OK", nil)
	require.Equal(t, 200, code)
	require.Equal(t, api, entry)
	require.Equal(t, "/v1/emoji/assets/feishu/OK.png", entry["entry"].(map[string]any)["asset"])
	require.Equal(t, true, call(t, h, "human-test", "emoji_get", map[string]any{"id": "feishu:invented"})["isError"])
	require.Equal(t, true, call(t, h, "human-test", "emoji_list", map[string]any{"run_id": uuid.NewString()})["isError"])
	for _, args := range []map[string]any{{"limit": 0}, {"limit": 201}, {"offset": -1}, {"offset": nil}, {"run_id": nil}, {"category": nil}, {"q": nil}, {"unexpected": true}} {
		mcpRejectArguments(t, h, "human-test", "emoji_list", args)
	}
}

type mcpEmojiReadHook struct {
	emoji.Provider
	afterRead func()
}

func (p *mcpEmojiReadHook) List(ctx context.Context, q emoji.Query) (emoji.Page, error) {
	page, err := p.Provider.List(ctx, q)
	if p.afterRead != nil {
		p.afterRead()
	}
	return page, err
}
func (p *mcpEmojiReadHook) Get(ctx context.Context, id string) (emoji.Entry, error) {
	entry, err := p.Provider.Get(ctx, id)
	if p.afterRead != nil {
		p.afterRead()
	}
	return entry, err
}

func TestMCPMachineInteractionsUseRunLedgerAndInheritedScope(t *testing.T) {
	s := httpStore(t)
	ctx := context.Background()
	p := &mcpEmojiReadHook{Provider: mcpEmojiBundle(t)}
	s.SetReactionEmojiValidator(p)
	owner, err := s.ResolveIdentity(ctx, "test-only-issuer", "human-test")
	require.NoError(t, err)
	agent := uuid.NewString()
	_, err = s.Pool.Exec(ctx, "INSERT INTO principals(id,kind,display_name) VALUES($1,'agent','MCP原生同事')", agent)
	require.NoError(t, err)
	w, err := s.CreateWorkspace(ctx, owner.ID, "mcp-machine-workspace", "MCP机器范围")
	require.NoError(t, err)
	_, err = s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", w, agent)
	require.NoError(t, err)
	source, err := s.CreateRoom(ctx, owner.ID, "mcp-machine-source", w, "来源", []string{agent})
	require.NoError(t, err)
	target, err := s.CreateRoom(ctx, owner.ID, "mcp-machine-target", w, "目标", []string{agent})
	require.NoError(t, err)
	b, err := s.RegisterExecutor(ctx, owner.ID, store.RegisterExecutorCommand{ActionID: "mcp-machine-register", WorkspaceID: w, AgentPrincipalID: agent, Issuer: "https://fixture.clerk.accounts.dev", MachineSubject: "mch_fixture", Enabled: true})
	require.NoError(t, err)
	_, err = s.SetAgentExecutionPolicy(ctx, owner.ID, store.AgentExecutionPolicyCommand{ActionID: "mcp-machine-enable", WorkspaceID: w, AgentPrincipalID: agent, ProactiveEnabled: true, ExpectedVersion: 1})
	require.NoError(t, err)
	parent, err := s.CreateExecutionRun(ctx, agent, store.CreateExecutionRunCommand{ActionID: "mcp-machine-parent", ExecutorID: b.ExecutorID, RoomID: source.ID, ScopeEpoch: 1, Goal: "来源"})
	require.NoError(t, err)
	run, err := s.CreateExecutionRun(ctx, agent, store.CreateExecutionRunCommand{ActionID: "mcp-machine-child", ExecutorID: b.ExecutorID, RoomID: target.ID, ScopeEpoch: 1, ParentRunID: parent.Context.RunID, Goal: "目标协作"})
	require.NoError(t, err)
	seed, err := s.Send(ctx, owner.ID, target.ID, domain.SendMessage{ActionID: "mcp-machine-seed", Content: "被引用的原文"})
	require.NoError(t, err)
	h := New(s, fixtureVerifier{}, nil, nil, WithMachineVerifier(fixtureMachineVerifier{}), WithEmojiProvider(p))
	set := map[string]any{"room_id": target.ID, "message_id": seed.Message.ID, "action_id": harness.StableID(run.Context.RunID, "set-reaction"), "emoji": "feishu:OK", "active": false}
	require.Equal(t, true, call(t, h, "mt_fixture", "message_reaction_set", set)["isError"])
	set["run_id"] = run.Context.RunID
	set["action_id"] = "not-a-64-hex-action"
	require.Equal(t, true, call(t, h, "mt_fixture", "message_reaction_set", set)["isError"])
	set["action_id"] = harness.StableID(run.Context.RunID, "set-reaction")
	result := structured(t, call(t, h, "mt_fixture", "message_reaction_set", set))
	require.Equal(t, "succeeded", result["status"])
	require.Equal(t, result, structured(t, call(t, h, "mt_fixture", "message_reaction_set", set)))
	set["active"] = true
	require.Equal(t, true, call(t, h, "mt_fixture", "message_reaction_set", set)["isError"])
	send := map[string]any{"room_id": target.ID, "run_id": run.Context.RunID, "action_id": harness.StableID(run.Context.RunID, "reply"), "content": "来自原生Run的回复", "reply_to": seed.Message.ID}
	require.Equal(t, "succeeded", structured(t, call(t, h, "mt_fixture", "message_send", send))["status"])
	for _, name := range []string{"message_get", "message_reaction_read", "message_read"} {
		args := map[string]any{"room_id": target.ID, "run_id": run.Context.RunID}
		if name != "message_read" {
			args["message_id"] = seed.Message.ID
		} else {
			args["before"] = 0
			args["limit"] = 1
		}
		structured(t, call(t, h, "mt_fixture", name, args))
	}
	structured(t, call(t, h, "mt_fixture", "emoji_list", map[string]any{"run_id": run.Context.RunID, "limit": 1}))
	structured(t, call(t, h, "mt_fixture", "emoji_get", map[string]any{"run_id": run.Context.RunID, "id": "feishu:OK"}))
	// Revoke inherited source during the in-memory read: post-read admission must
	// prevent returning data under a run that has just become stale.
	p.afterRead = func() {
		p.afterRead = nil
		_, err := s.SetStopped(ctx, owner.ID, source.ID, "mcp-stop-during-emoji-read", 1, true)
		require.NoError(t, err)
	}
	denied := call(t, h, "mt_fixture", "emoji_list", map[string]any{"run_id": run.Context.RunID, "limit": 1})
	require.Equal(t, true, denied["isError"])
	require.Equal(t, "scope_stopped_or_stale", denied["structuredContent"].(map[string]any)["error"])
	for _, name := range []string{"message_get", "message_reaction_read", "message_read", "emoji_get"} {
		args := map[string]any{"room_id": target.ID, "run_id": run.Context.RunID}
		if name == "emoji_get" {
			delete(args, "room_id")
			args["id"] = "feishu:OK"
		} else if name != "message_read" {
			args["message_id"] = seed.Message.ID
		}
		require.Equal(t, true, call(t, h, "mt_fixture", name, args)["isError"])
	}
	// Catalog is shared account-level data when no run was requested; no live run
	// authorization is fabricated by silently ignoring a provided run_id.
	structured(t, call(t, h, "mt_fixture", "emoji_get", map[string]any{"id": "feishu:OK"}))
	_, err = s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", target.ID, agent)
	require.NoError(t, err)
	require.Equal(t, true, call(t, h, "mt_fixture", "message_get", map[string]any{"room_id": target.ID, "message_id": seed.Message.ID})["isError"])
}
