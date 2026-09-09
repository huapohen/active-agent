package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/stretchr/testify/require"
)

func TestRoomListPreviewAPIAndMCPUseSameFactsAndExplicitEmpty(t *testing.T) {
	s := httpStore(t)
	ctx := context.Background()
	owner, err := s.ResolveIdentity(ctx, "test-only-issuer", "human-test")
	require.NoError(t, err)
	w, err := s.CreateWorkspace(ctx, owner.ID, "room-preview-workspace", "会话摘要验证")
	require.NoError(t, err)
	r, err := s.CreateRoom(ctx, owner.ID, "room-preview-create", w, "真实消息摘要", nil)
	require.NoError(t, err)
	h := New(s, fixtureVerifier{}, nil, nil)
	status, page := request(t, h, "human-test", http.MethodGet, "/v1/rooms", nil)
	require.Equal(t, 200, status)
	row := page["rooms"].([]any)[0].(map[string]any)
	empty, present := row["last_message"]
	require.True(t, present)
	require.Nil(t, empty)
	require.Equal(t, page, structured(t, call(t, h, "human-test", "room_list", map[string]any{})))
	_, err = s.Send(ctx, owner.ID, r.ID, domain.SendMessage{ActionID: "room-preview-http-message", Content: "这条消息来自正式消息表"})
	require.NoError(t, err)
	status, page = request(t, h, "human-test", http.MethodGet, "/v1/rooms", nil)
	require.Equal(t, 200, status)
	preview := page["rooms"].([]any)[0].(map[string]any)["last_message"].(map[string]any)
	require.Equal(t, "这条消息来自正式消息表", preview["excerpt"])
	require.Equal(t, r.ID, preview["room_id"])
	require.Equal(t, owner.ID, preview["author_id"])
	require.NotEmpty(t, preview["created_at"])
	require.Equal(t, page, structured(t, call(t, h, "human-test", "room_list", map[string]any{})))
	// Metadata mutations that did not fetch a summary must not claim this
	// nonempty room is empty and overwrite an existing UI preview.
	changed, err := s.SetStopped(ctx, owner.ID, r.ID, "room-preview-policy-change", r.Version, true)
	require.NoError(t, err)
	raw, err := json.Marshal(changed)
	require.NoError(t, err)
	var fields map[string]any
	require.NoError(t, json.Unmarshal(raw, &fields))
	_, present = fields["last_message"]
	require.False(t, present)
}
