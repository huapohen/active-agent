package harness

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/cloudwego/eino/schema"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/emoji"
	"github.com/stretchr/testify/require"
)

const nativeMessageID = "00000000-0000-4000-8000-000000000011"

func boundAck(r RunContext) map[string]any {
	return map[string]any{"protocol": gatewayProtocol, "principal_id": r.PrincipalID, "executor_id": r.ExecutorID, "server_bound": true, "actions_idempotent": true, "scope_epochs_enforced": true, "action_types": []string{"message.send", "reaction.set"}, "read_capabilities": []string{"message.get", "reaction.list", "emoji.list"}}
}
func emojiFixturePage(q emoji.Query) emoji.Page {
	limit := q.Limit
	if limit == 0 {
		limit = 100
	}
	return emoji.Page{Metadata: emoji.Metadata{Revision: "fixture-revision", CatalogCount: 1}, Offset: q.Offset, Limit: limit, Total: 1, Entries: []emoji.Entry{{ID: "feishu:OK", Name: "OK", Asset: "/v1/emoji/assets/feishu/OK.png"}}}
}
func TestHTTPBindingCapabilitiesAreExplicitCopiedAndClearedOnFailure(t *testing.T) {
	r := runContext()
	ack := boundAck(r)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _ = json.NewEncoder(w).Encode(ack) }))
	defer server.Close()
	g, err := NewHTTPGateway(server.URL, "fixture", r.PrincipalID, r.ExecutorID)
	require.NoError(t, err)
	require.Empty(t, g.AllowedActionTypes())
	require.Empty(t, g.NativeReadCapabilities())
	require.NoError(t, g.VerifyBinding(context.Background()))
	require.Equal(t, []string{"message.send", "reaction.set"}, g.AllowedActionTypes())
	list := g.AllowedActionTypes()
	list[0] = "shell.execute"
	require.Equal(t, "message.send", g.AllowedActionTypes()[0])
	list = g.NativeReadCapabilities()
	list[0] = "malicious"
	require.Equal(t, "message.get", g.NativeReadCapabilities()[0])
	delete(ack, "action_types")
	delete(ack, "read_capabilities")
	require.NoError(t, g.VerifyBinding(context.Background()))
	require.Equal(t, []string{"message.send"}, g.AllowedActionTypes())
	require.Empty(t, g.NativeReadCapabilities())
	ack["action_types"] = nil
	require.ErrorIs(t, g.VerifyBinding(context.Background()), ErrDenied)
	for _, types := range [][]string{{}, {"reaction.set", "reaction.set"}, {""}} {
		ack["action_types"] = types
		require.ErrorIs(t, g.VerifyBinding(context.Background()), ErrDenied)
		require.Empty(t, g.AllowedActionTypes())
		require.Empty(t, g.NativeReadCapabilities())
	}
}
func TestNativeInteractionHTTPReadsCarryRunAndDiscardLateResults(t *testing.T) {
	for _, kind := range []string{"message.get", "reaction.list", "emoji.list"} {
		for _, late := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/stop=%v", kind, late), func(t *testing.T) {
				r := runContext()
				r.RoomID = "00000000-0000-4000-8000-000000000001"
				stopped := false
				checks, gets := 0, 0
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) {
					require.Equal(t, "Bearer fixture", q.Header.Get("Authorization"))
					switch q.URL.Path {
					case "/internal/harness/binding":
						_ = json.NewEncoder(w).Encode(boundAck(r))
						return
					case "/internal/harness/check":
						checks++
						if stopped {
							w.WriteHeader(409)
							fmt.Fprint(w, `{"code":"scope_stopped"}`)
						} else {
							fmt.Fprint(w, `{"allowed":true}`)
						}
						return
					}
					gets++
					require.Equal(t, http.MethodGet, q.Method)
					require.Equal(t, r.RunID, q.URL.Query().Get("run_id"))
					switch kind {
					case "message.get":
						require.Equal(t, "/v1/rooms/"+r.RoomID+"/messages/"+nativeMessageID, q.URL.Path)
						_ = json.NewEncoder(w).Encode(map[string]any{"message": domain.Message{ID: nativeMessageID, RoomID: r.RoomID, Seq: 1, Content: "private native message"}})
					case "reaction.list":
						require.Equal(t, "/v1/rooms/"+r.RoomID+"/messages/"+nativeMessageID+"/reactions", q.URL.Path)
						require.Equal(t, "7", q.URL.Query().Get("expected_version"))
						_ = json.NewEncoder(w).Encode(domain.ReactionPage{RoomID: r.RoomID, MessageID: nativeMessageID, Version: 7, Summaries: []domain.ReactionSummary{{Emoji: "feishu:OK", Count: 1, Selected: true}}})
					case "emoji.list":
						require.Equal(t, "/v1/emoji", q.URL.Path)
						require.Equal(t, "OK", q.URL.Query().Get("q"))
						_ = json.NewEncoder(w).Encode(emojiFixturePage(emoji.Query{}))
					}
					if late {
						stopped = true
					}
				}))
				defer server.Close()
				g, err := NewHTTPGateway(server.URL, "fixture", r.PrincipalID, r.ExecutorID)
				require.NoError(t, err)
				require.NoError(t, g.VerifyBinding(context.Background()))
				switch kind {
				case "message.get":
					m, e := g.ReadMessage(context.Background(), r, r.RoomID, nativeMessageID)
					err = e
					if late {
						require.Empty(t, m.ID)
					} else {
						require.Equal(t, nativeMessageID, m.ID)
					}
				case "reaction.list":
					version := int64(7)
					p, e := g.ReadReactions(context.Background(), r, r.RoomID, nativeMessageID, ReactionReadQuery{ExpectedVersion: &version})
					err = e
					if late {
						require.Empty(t, p.Summaries)
					} else {
						require.Len(t, p.Summaries, 1)
					}
				case "emoji.list":
					p, e := g.ReadEmoji(context.Background(), r, emoji.Query{Q: "OK"})
					err = e
					if late {
						require.Empty(t, p.Entries)
					} else {
						require.Len(t, p.Entries, 1)
					}
				}
				if late {
					require.ErrorIs(t, err, ErrStopped)
				} else {
					require.NoError(t, err)
				}
				require.Equal(t, 2, checks)
				require.Equal(t, 1, gets)
			})
		}
	}
}

type extendedReadGateway struct {
	fakeGateway
	stopLate bool
	bad      bool
	calls    []string
}

func (g *extendedReadGateway) NativeReadCapabilities() []string {
	return []string{"message.get", "reaction.list", "emoji.list"}
}
func (g *extendedReadGateway) mark(kind string) {
	g.calls = append(g.calls, kind)
	if g.stopLate {
		g.mu.Lock()
		g.stopped = true
		g.mu.Unlock()
	}
}
func (g *extendedReadGateway) ReadMessage(_ context.Context, r RunContext, room, id string) (domain.Message, error) {
	g.mark("message.get")
	if g.bad {
		room = "foreign"
	}
	return domain.Message{ID: id, RoomID: room, Seq: 1, Content: "private-extension-result"}, nil
}
func (g *extendedReadGateway) ReadReactions(_ context.Context, r RunContext, room, id string, _ ReactionReadQuery) (domain.ReactionPage, error) {
	g.mark("reaction.list")
	if g.bad {
		room = "foreign"
	}
	return domain.ReactionPage{RoomID: room, MessageID: id, Version: 1, Summaries: []domain.ReactionSummary{{Emoji: "feishu:OK", Count: 1, Selected: true}}}, nil
}
func (g *extendedReadGateway) ReadEmoji(_ context.Context, _ RunContext, q emoji.Query) (emoji.Page, error) {
	g.mark("emoji.list")
	p := emojiFixturePage(q)
	if g.bad {
		p.NextOffset = new(int)
		p.HasMore = true
	}
	return p, nil
}
func nativeToolMessage(name, args string) *schema.Message {
	return &schema.Message{Role: schema.Assistant, ToolCalls: []schema.ToolCall{{ID: "call-" + name, Type: "function", Function: schema.FunctionCall{Name: name, Arguments: args}}}}
}
func TestEinoExtendedReadsAndReactionPlanAreRealToolsButNotBusinessWrites(t *testing.T) {
	g := &extendedReadGateway{}
	m := &fakeModel{messages: []*schema.Message{
		nativeToolMessage("im_emoji_list", `{"q":"OK"}`),
		nativeToolMessage("im_message_get", fmt.Sprintf(`{"room_id":"room-a","message_id":%q}`, nativeMessageID)),
		nativeToolMessage("im_reaction_list", fmt.Sprintf(`{"room_id":"room-a","message_id":%q,"expected_version":1}`, nativeMessageID)),
		{Role: schema.Assistant, Content: fmt.Sprintf(`{"summary":"Use observed catalog ID to remove my reaction","done":true,"actions":[{"key":"remove-ok","type":"reaction.set","payload":{"message_id":%q,"emoji":"feishu:OK","active":false}}]}`, nativeMessageID)},
	}}
	p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send", "reaction.set"}})
	require.NoError(t, err)
	result, err := p.Plan(context.Background(), StageInput{Context: runContext(), Goal: "Remove current reaction", Attempt: 1})
	require.NoError(t, err)
	require.Equal(t, []string{"emoji.list", "message.get", "reaction.list"}, g.calls)
	require.Len(t, result.Actions, 1)
	require.Equal(t, "reaction.set", result.Actions[0].Type)
	require.Contains(t, string(result.Actions[0].Payload), `"active":false`)
	require.Equal(t, 4, m.calls)
	require.Zero(t, g.effects)
	raw, _ := json.Marshal(g.events)
	require.Contains(t, string(raw), "private-extension-result")
	require.Contains(t, string(raw), "im_emoji_list")
	// A deployment that did not admit reaction.set cannot decode the same action.
	p.config.AllowedActionTypes = []string{"message.send"}
	_, err = p.decode(runContext().RunID, fmt.Sprintf(`{"summary":"denied","done":true,"actions":[{"key":"x","type":"reaction.set","payload":{"message_id":%q,"emoji":"feishu:OK","active":true}}]}`, nativeMessageID))
	require.ErrorIs(t, err, ErrInvalid)
}
func TestExtendedReadPluginsDiscardForeignOrStoppedDataBeforeTrace(t *testing.T) {
	for _, kind := range []string{"im_message_get", "im_reaction_list", "im_emoji_list"} {
		for _, late := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/late=%v", kind, late), func(t *testing.T) {
				g := &extendedReadGateway{bad: !late, stopLate: late}
				args := fmt.Sprintf(`{"room_id":"room-a","message_id":%q}`, nativeMessageID)
				if kind == "im_emoji_list" {
					args = `{"q":"OK"}`
				}
				m := &fakeModel{messages: []*schema.Message{nativeToolMessage(kind, args), {Role: schema.Assistant, Content: `{"summary":"must not continue","done":true,"actions":[]}`}}}
				p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
				require.NoError(t, err)
				_, err = p.Plan(context.Background(), StageInput{Context: runContext(), Goal: "read", Attempt: 1})
				require.Error(t, err)
				require.Equal(t, 1, m.calls)
				require.Zero(t, g.effects)
				raw, _ := json.Marshal(g.events)
				require.NotContains(t, string(raw), "private-extension-result")
				for _, e := range g.events {
					require.NotEqual(t, "tool.result", e.Type)
				}
			})
		}
	}
}
func TestNativeInteractionValidatorsRejectForgedVersionsPaginationAndForeignReply(t *testing.T) {
	r := runContext()
	good := domain.ReactionPage{RoomID: r.RoomID, MessageID: nativeMessageID, Version: 2, Summaries: []domain.ReactionSummary{{Emoji: "feishu:OK", Count: 1}}}
	require.NoError(t, validateReactionPage(r, r.RoomID, nativeMessageID, ReactionReadQuery{}, good))
	for name, mutate := range map[string]func(*domain.ReactionPage){"negative_count": func(p *domain.ReactionPage) { p.Summaries[0].Count = -1 }, "duplicate": func(p *domain.ReactionPage) { p.Summaries = append(p.Summaries, p.Summaries[0]) }, "forged_cursor": func(p *domain.ReactionPage) { p.HasMore = true; p.NextAfter = "fake" }, "zero_version": func(p *domain.ReactionPage) { p.Version = 0 }} {
		t.Run(name, func(t *testing.T) {
			bad := good
			bad.Summaries = append([]domain.ReactionSummary(nil), good.Summaries...)
			mutate(&bad)
			require.Error(t, validateReactionPage(r, r.RoomID, nativeMessageID, ReactionReadQuery{}, bad))
		})
	}
	version := int64(1)
	require.Error(t, validateReactionPage(r, r.RoomID, nativeMessageID, ReactionReadQuery{ExpectedVersion: &version}, good))
	require.False(t, validReactionQuery(ReactionReadQuery{After: "feishu:OK"}))
	p := emojiFixturePage(emoji.Query{})
	p.Revision = "old"
	require.Error(t, validateEmojiPage(emoji.Query{Revision: "new"}, p))
	require.False(t, validEmojiQuery(emoji.Query{Offset: 100}))
	p = emojiFixturePage(emoji.Query{})
	p.Entries[0].Asset = "https://untrusted.example/private"
	require.Error(t, validateEmojiPage(emoji.Query{}, p))
	msg := domain.Message{ID: nativeMessageID, RoomID: r.RoomID, Seq: 2, ReplyTo: "00000000-0000-4000-8000-000000000012", Reply: &domain.MessageReply{MessageID: "00000000-0000-4000-8000-000000000012", RoomID: "foreign", Seq: 1}}
	require.ErrorIs(t, validateMessage(r, r.RoomID, nativeMessageID, msg), ErrDenied)
	require.ErrorIs(t, validateMessagePage(r, r.RoomID, 0, MessagePage{Messages: []domain.Message{msg}, Cursor: 2}), ErrDenied)
	require.NotContains(t, actionSchemaInstruction([]string{"message.send"}), "reaction.set payload")
	require.Contains(t, actionSchemaInstruction([]string{"reaction.set"}), "active: required true or false")
}
func TestExtendedHTTPUnadvertisedCapabilitiesMakeNoRequest(t *testing.T) {
	calls := 0
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { calls++; fmt.Fprint(w, `{}`) }))
	defer s.Close()
	r := runContext()
	g, err := NewHTTPGateway(s.URL, "fixture", r.PrincipalID, r.ExecutorID)
	require.NoError(t, err)
	_, err = g.ReadEmoji(context.Background(), r, emoji.Query{})
	require.ErrorIs(t, err, ErrDenied)
	_, err = g.ReadMessage(context.Background(), r, r.RoomID, nativeMessageID)
	require.ErrorIs(t, err, ErrDenied)
	_, err = g.ReadReactions(context.Background(), r, r.RoomID, nativeMessageID, ReactionReadQuery{})
	require.ErrorIs(t, err, ErrDenied)
	require.Zero(t, calls)
	require.NotContains(t, strings.Join(g.NativeReadCapabilities(), ","), "emoji.list")
}
