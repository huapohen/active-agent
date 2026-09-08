package harness

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/cloudwego/eino/schema"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/stretchr/testify/require"
)

func TestNativeReadsAreRunBoundPagedAndDiscardedAfterStop(t *testing.T) {
	r := runContext()
	r.RoomID = "00000000-0000-4000-8000-000000000001"
	stopped := false
	getCalls := 0
	stopAfterRead := false
	foreignResponse := false
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) {
		require.Equal(t, "Bearer fixture", q.Header.Get("Authorization"))
		if q.URL.Path == "/internal/harness/check" {
			if stopped {
				w.WriteHeader(409)
				_, _ = w.Write([]byte(`{"code":"scope_stopped"}`))
				return
			}
			_, _ = w.Write([]byte(`{"allowed":true}`))
			return
		}
		getCalls++
		require.Equal(t, "GET", q.Method)
		require.Equal(t, r.RunID, q.URL.Query().Get("run_id"))
		require.Equal(t, "5", q.URL.Query().Get("after"))
		room := r.RoomID
		if foreignResponse {
			room = "other"
		}
		_ = json.NewEncoder(w).Encode(MessagePage{Messages: []domain.Message{{ID: "msg", RoomID: room, Seq: 6, Content: "observed"}}, Cursor: 6})
		if stopAfterRead {
			stopped = true
		}
	}))
	defer s.Close()
	g, err := NewHTTPGateway(s.URL, "fixture", r.PrincipalID, r.ExecutorID)
	require.NoError(t, err)
	p, err := g.ReadMessages(context.Background(), r, r.RoomID, 5)
	require.NoError(t, err)
	require.Len(t, p.Messages, 1)
	_, err = g.ReadMessages(context.Background(), r, "00000000-0000-4000-8000-000000000002", 5)
	require.ErrorIs(t, err, ErrDenied)
	require.Equal(t, 1, getCalls)
	foreignResponse = true
	_, err = g.ReadMessages(context.Background(), r, r.RoomID, 5)
	require.Error(t, err)
	foreignResponse = false
	stopAfterRead = true
	p, err = g.ReadMessages(context.Background(), r, r.RoomID, 5)
	require.ErrorIs(t, err, ErrStopped)
	require.Empty(t, p.Messages)
}

type readingGateway struct {
	fakeGateway
	read int
}

func (g *readingGateway) ReadRooms(_ context.Context, r RunContext, _ string) (RoomPage, error) {
	g.read++
	return RoomPage{Rooms: []domain.Room{{ID: r.RoomID, Title: "actual fixture"}}}, nil
}
func (g *readingGateway) ReadMessages(_ context.Context, r RunContext, room string, _ int64) (MessagePage, error) {
	g.read++
	return MessagePage{Messages: []domain.Message{{ID: "msg1", RoomID: room, Content: "真实消息", Seq: 1}}, Cursor: 1}, nil
}

func TestEinoNativeReadToolsRecordEvidenceWithoutBusinessWrites(t *testing.T) {
	g := &readingGateway{}
	m := &fakeModel{messages: []*schema.Message{
		{Role: schema.Assistant, ToolCalls: []schema.ToolCall{{ID: "rooms", Type: "function", Function: schema.FunctionCall{Name: "im_room_list", Arguments: `{"after":""}`}}}},
		{Role: schema.Assistant, ToolCalls: []schema.ToolCall{{ID: "messages", Type: "function", Function: schema.FunctionCall{Name: "im_message_read", Arguments: `{"room_id":"room-a","after":0}`}}}},
		{Role: schema.Assistant, Content: `{"summary":"Read the source messages","done":true,"actions":[]}`},
	}}
	p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
	require.NoError(t, err)
	_, err = p.Plan(context.Background(), StageInput{Context: runContext(), Goal: "Read messages", Attempt: 1})
	require.NoError(t, err)
	require.Equal(t, 2, g.read)
	require.Zero(t, g.effects)
	raw, _ := json.Marshal(g.events)
	require.Contains(t, string(raw), "真实消息")
	require.Contains(t, string(raw), "im_message_read")
}

func TestNativePageValidatorsRejectScopeAndPaginationViolations(t *testing.T) {
	r := runContext()
	for _, tc := range []struct {
		name  string
		after string
		page  RoomPage
		want  error
	}{
		{"ordered", "", RoomPage{Rooms: []domain.Room{{ID: "room-a"}, {ID: "source-room"}}, Cursor: "source-room"}, nil},
		{"next", "room-a", RoomPage{Rooms: []domain.Room{{ID: "source-room"}}}, nil},
		{"empty-terminal", "source-room", RoomPage{}, nil},
		{"foreign", "", RoomPage{Rooms: []domain.Room{{ID: "foreign-room"}}}, ErrDenied},
		{"duplicate", "", RoomPage{Rooms: []domain.Room{{ID: "room-a"}, {ID: "room-a"}}}, ErrInvalid},
		{"descending", "", RoomPage{Rooms: []domain.Room{{ID: "source-room"}, {ID: "room-a"}}}, ErrInvalid},
		{"repeated-cursor", "room-a", RoomPage{Rooms: []domain.Room{{ID: "room-a"}}, Cursor: "room-a"}, ErrInvalid},
		{"wrong-cursor", "", RoomPage{Rooms: []domain.Room{{ID: "room-a"}}, Cursor: "source-room"}, ErrInvalid},
		{"empty-continuation", "", RoomPage{Cursor: "room-a"}, ErrInvalid},
		{"count-budget", "", RoomPage{Rooms: make([]domain.Room, nativeReadPageLimit+1)}, ErrInvalid},
	} {
		t.Run("rooms/"+tc.name, func(t *testing.T) {
			err := validateRoomPage(r, tc.after, tc.page)
			if tc.want == nil {
				require.NoError(t, err)
			} else {
				require.ErrorIs(t, err, tc.want)
			}
		})
	}
	for _, tc := range []struct {
		name  string
		room  string
		after int64
		page  MessagePage
		want  error
	}{
		{"ordered", r.RoomID, 5, MessagePage{Messages: []domain.Message{{RoomID: r.RoomID, Seq: 6}, {RoomID: r.RoomID, Seq: 8}}, Cursor: 8, HasMore: true}, nil},
		{"empty-terminal", r.RoomID, 5, MessagePage{Cursor: 5}, nil},
		{"negative", r.RoomID, -1, MessagePage{}, ErrInvalid},
		{"outside-request", "foreign-room", 0, MessagePage{}, ErrDenied},
		{"foreign-response", r.RoomID, 0, MessagePage{Messages: []domain.Message{{RoomID: "source-room", Seq: 1}}, Cursor: 1}, ErrDenied},
		{"repeated-sequence", r.RoomID, 5, MessagePage{Messages: []domain.Message{{RoomID: r.RoomID, Seq: 5}}, Cursor: 5}, ErrInvalid},
		{"duplicate-sequence", r.RoomID, 0, MessagePage{Messages: []domain.Message{{RoomID: r.RoomID, Seq: 1}, {RoomID: r.RoomID, Seq: 1}}, Cursor: 1}, ErrInvalid},
		{"wrong-cursor", r.RoomID, 0, MessagePage{Messages: []domain.Message{{RoomID: r.RoomID, Seq: 1}}, Cursor: 2}, ErrInvalid},
		{"empty-continuation", r.RoomID, 5, MessagePage{Cursor: 5, HasMore: true}, ErrInvalid},
		{"count-budget", r.RoomID, 0, MessagePage{Messages: make([]domain.Message, nativeReadPageLimit+1)}, ErrInvalid},
	} {
		t.Run("messages/"+tc.name, func(t *testing.T) {
			err := validateMessagePage(r, tc.room, tc.after, tc.page)
			if tc.want == nil {
				require.NoError(t, err)
			} else {
				require.ErrorIs(t, err, tc.want)
			}
		})
	}
	full := MessagePage{Cursor: nativeReadPageLimit, HasMore: true}
	for i := int64(1); i <= nativeReadPageLimit; i++ {
		full.Messages = append(full.Messages, domain.Message{RoomID: r.RoomID, Seq: i})
	}
	require.NoError(t, validateMessagePage(r, r.RoomID, 0, full), "exact page budget remains usable")
}

type unsafeReadGateway struct {
	fakeGateway
	stopLate bool
	reads    int
}

func (g *unsafeReadGateway) resultRoom(r RunContext) string {
	g.reads++
	if g.stopLate {
		g.mu.Lock()
		g.stopped = true
		g.mu.Unlock()
		return r.RoomID
	}
	return "foreign-room"
}

func (g *unsafeReadGateway) ReadRooms(_ context.Context, r RunContext, _ string) (RoomPage, error) {
	return RoomPage{Rooms: []domain.Room{{ID: g.resultRoom(r), Title: "private-plugin-result-must-not-escape"}}}, nil
}

func (g *unsafeReadGateway) ReadMessages(_ context.Context, r RunContext, _ string, after int64) (MessagePage, error) {
	return MessagePage{Messages: []domain.Message{{RoomID: g.resultRoom(r), Seq: after + 1, Content: "private-plugin-result-must-not-escape"}}, Cursor: after + 1}, nil
}

func TestNativeReadPluginsCannotLeakForeignOrRevokedPagesToModelOrTrace(t *testing.T) {
	for _, name := range []string{"im_room_list", "im_message_read"} {
		for _, late := range []bool{false, true} {
			suffix := "/foreign"
			if late {
				suffix = "/stopped-after-read"
			}
			t.Run(name+suffix, func(t *testing.T) {
				g := &unsafeReadGateway{stopLate: late}
				args := `{"after":""}`
				if name == "im_message_read" {
					args = `{"room_id":"room-a","after":5}`
				}
				m := &fakeModel{messages: []*schema.Message{
					{Role: schema.Assistant, ToolCalls: []schema.ToolCall{{ID: "unsafe-read", Type: "function", Function: schema.FunctionCall{Name: name, Arguments: args}}}},
					{Role: schema.Assistant, Content: `{"summary":"This next model call must not occur","done":true,"actions":[]}`},
				}}
				p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
				require.NoError(t, err)
				_, err = p.Plan(context.Background(), StageInput{Context: runContext(), Goal: "Read the authorized source", Attempt: 1})
				require.Error(t, err)
				require.Equal(t, 1, g.reads)
				require.Equal(t, 1, m.calls, "invalid page must never enter a model continuation")
				require.Zero(t, g.effects)
				raw, err := json.Marshal(g.events)
				require.NoError(t, err)
				require.NotContains(t, string(raw), "private-plugin-result-must-not-escape")
				for _, e := range g.events {
					require.NotEqual(t, "tool.result", e.Type, "rejected page must not enter the tool archive")
				}
			})
		}
	}
}

func TestNativeHTTPRoomPaginationUsesSharedValidation(t *testing.T) {
	r := runContext()
	r.RoomID = "00000000-0000-4000-8000-000000000001"
	r.OriginScopes = []Scope{{RoomID: "00000000-0000-4000-8000-000000000002", Epoch: 1}}
	page := RoomPage{Rooms: []domain.Room{{ID: r.OriginScopes[0].RoomID}}}
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) {
		if q.URL.Path == "/internal/harness/check" {
			_, _ = w.Write([]byte(`{"allowed":true}`))
			return
		}
		require.Equal(t, "/v1/rooms", q.URL.Path)
		require.Equal(t, r.RunID, q.URL.Query().Get("run_id"))
		require.Equal(t, r.RoomID, q.URL.Query().Get("after"))
		_ = json.NewEncoder(w).Encode(page)
	}))
	defer s.Close()
	g, err := NewHTTPGateway(s.URL, "fixture", r.PrincipalID, r.ExecutorID)
	require.NoError(t, err)
	got, err := g.ReadRooms(context.Background(), r, r.RoomID)
	require.NoError(t, err)
	require.Len(t, got.Rooms, 1)
	page = RoomPage{Rooms: []domain.Room{{ID: r.RoomID}}, Cursor: r.RoomID}
	got, err = g.ReadRooms(context.Background(), r, r.RoomID)
	require.ErrorIs(t, err, ErrInvalid)
	require.Empty(t, got.Rooms, "transport must discard the entire non-progressing page")
}
