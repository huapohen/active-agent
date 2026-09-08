package httpapi

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/emoji"
	"github.com/stretchr/testify/require"
)

func realHTTPCatalog(t *testing.T) emoji.Provider {
	t.Helper()
	dir, err := filepath.Abs("../../../../apps/office/assets/emoji")
	require.NoError(t, err)
	p, err := emoji.NewLocal(dir)
	require.NoError(t, err)
	return p
}

func TestHTTPMessageHistoryReplyAndReactionReconciliation(t *testing.T) {
	ctx := context.Background()
	s := httpStore(t)
	owner, err := s.ResolveIdentity(ctx, "test-only-issuer", "human-test")
	require.NoError(t, err)
	w, err := s.CreateWorkspace(ctx, owner.ID, "interaction-http-workspace", "交互 HTTP")
	require.NoError(t, err)
	room, err := s.CreateRoom(ctx, owner.ID, "interaction-http-room", w, "历史与回应", nil)
	require.NoError(t, err)
	h := New(s, fixtureVerifier{}, nil, nil, WithEmojiProvider(realHTTPCatalog(t)))
	path := "/v1/rooms/" + room.ID + "/messages"
	var first domain.Message
	for i := 1; i <= 105; i++ {
		r, e := s.Send(ctx, owner.ID, room.ID, domain.SendMessage{ActionID: fmt.Sprintf("http-message-%03d", i), Content: fmt.Sprintf("原文 %d", i)})
		require.NoError(t, e)
		if i == 1 {
			first = r.Message
		}
	}
	code, page := request(t, h, "human-test", "GET", path+"?before=0", nil)
	require.Equal(t, 200, code)
	require.Equal(t, "before", page["direction"])
	require.Equal(t, true, page["has_more_before"])
	rows := page["messages"].([]any)
	require.Len(t, rows, 100)
	require.EqualValues(t, 6, rows[0].(map[string]any)["seq"])
	require.EqualValues(t, 105, rows[99].(map[string]any)["seq"])
	code, older := request(t, h, "human-test", "GET", path+"?before=6&limit=100", nil)
	require.Equal(t, 200, code)
	require.Len(t, older["messages"], 5)
	require.Equal(t, false, older["has_more_before"])
	code, forward := request(t, h, "human-test", "GET", path+"?after=100&limit=3", nil)
	require.Equal(t, 200, code)
	require.Len(t, forward["messages"], 3)
	require.EqualValues(t, 103, forward["cursor"])
	require.Equal(t, true, forward["has_more"])
	for _, query := range []string{"before=0&after=0", "before=-1", "before=", "limit=0", "limit=101", "limit=1&limit=2", "before=0&unknown=1", "after=0.5"} {
		code, _ := request(t, h, "human-test", "GET", path+"?"+query, nil)
		require.Equal(t, 400, code, query)
	}
	code, reply := request(t, h, "human-test", "POST", path, map[string]any{"action_id": "http-real-reply", "content": "回复内容", "reply_to": first.ID})
	require.Equal(t, 200, code)
	snapshot := reply["message"].(map[string]any)["reply"].(map[string]any)
	require.Equal(t, first.ID, snapshot["message_id"])
	require.Equal(t, first.Content, snapshot["excerpt"])
	code, _ = request(t, h, "human-test", "POST", path, map[string]any{"action_id": "http-forged-reply", "content": "不接受伪造摘要", "reply": snapshot})
	require.Equal(t, 400, code)
	point := path + "/" + first.ID
	reaction := point + "/reactions"
	cmd := map[string]any{"action_id": "http-reaction-set", "emoji": "feishu:OK", "active": true}
	code, receipt := request(t, h, "human-test", "POST", reaction, cmd)
	require.Equal(t, 200, code)
	require.EqualValues(t, 1, receipt["version"])
	code, _ = request(t, h, "human-test", "POST", reaction, map[string]any{"action_id": "http-reaction-remove", "emoji": "feishu:OK", "active": false})
	require.Equal(t, 200, code)
	code, replay := request(t, h, "human-test", "POST", reaction, cmd)
	require.Equal(t, 200, code)
	require.Equal(t, true, replay["replayed"])
	require.EqualValues(t, 1, replay["version"])
	code, current := request(t, h, "human-test", "GET", point, nil)
	require.Equal(t, 200, code)
	msg := current["message"].(map[string]any)
	require.EqualValues(t, 2, msg["reaction_version"])
	require.Empty(t, msg["reactions"])
	for _, body := range []map[string]any{
		{"action_id": "missing-intent", "emoji": "feishu:OK"},
		{"action_id": "null-intent", "emoji": "feishu:OK", "active": nil},
		{"action_id": "forged-count", "emoji": "feishu:OK", "active": true, "count": 99},
		{"action_id": "not-catalog", "emoji": "invented-emoji", "active": true},
	} {
		code, _ := request(t, h, "human-test", "POST", reaction, body)
		require.Equal(t, 400, code)
	}
	code, _ = request(t, h, "outsider-test", "GET", point, nil)
	require.Equal(t, 403, code)
	code, _ = request(t, h, "outsider-test", "GET", reaction, nil)
	require.Equal(t, 403, code)
	_, err = s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", room.ID, owner.ID)
	require.NoError(t, err)
	code, _ = request(t, h, "human-test", "POST", reaction, cmd)
	require.Equal(t, 403, code)
}

func TestHTTPEmojiCatalogAndBinaryAssetsRequireCurrentAuthentication(t *testing.T) {
	s := httpStore(t)
	p := realHTTPCatalog(t)
	h := New(s, fixtureVerifier{}, nil, []string{"http://127.0.0.1:5173"}, WithEmojiProvider(p))
	code, page := request(t, h, "human-test", "GET", "/v1/emoji?q=feishu%3AOK&limit=2", nil)
	require.Equal(t, 200, code)
	require.EqualValues(t, 4126, page["catalog_count"])
	code, one := request(t, h, "human-test", "GET", "/v1/emoji/entries/feishu:OK", nil)
	require.Equal(t, 200, code)
	entry := one["entry"].(map[string]any)
	require.Equal(t, "/v1/emoji/assets/feishu/OK.png", entry["asset"])
	load := func(token, etag string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", entry["asset"].(string), nil)
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		r.Header.Set("If-Match", etag)
		r.Header.Set("Origin", "http://127.0.0.1:5173")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	for _, token := range []string{"", "bad-session"} {
		require.Equal(t, 401, load(token, entry["asset_etag"].(string)).Code)
	}
	require.Equal(t, 412, load("human-test", "\"stale-image\"").Code)
	image := load("human-test", entry["asset_etag"].(string))
	require.Equal(t, 200, image.Code)
	require.Equal(t, "image/png", image.Header().Get("Content-Type"))
	require.Equal(t, "no-store", image.Header().Get("Cache-Control"))
	require.Equal(t, "ETag", image.Header().Get("Access-Control-Expose-Headers"))
	sum := sha256.Sum256(image.Body.Bytes())
	require.Equal(t, "\"sha256-"+hex.EncodeToString(sum[:])+"\"", image.Header().Get("ETag"))
	require.EqualValues(t, len(image.Body.Bytes()), entry["asset_bytes"])
	for _, suffix := range []string{"?token=human-test", "?limit=1", "/../../catalog.json"} {
		code, _ := request(t, h, "human-test", "GET", "/v1/emoji/assets/feishu/OK.png"+suffix, nil)
		require.NotEqual(t, http.StatusOK, code)
	}
	code, _ = request(t, h, "human-test", "GET", "/v1/emoji?revision=stale", nil)
	require.Equal(t, 409, code)
	for _, query := range []string{"limit=0", "offset=-1", "category=missing", "limit=201", "limit=1&limit=2", "limit=bad"} {
		code, _ := request(t, h, "human-test", "GET", "/v1/emoji?"+query, nil)
		require.Equal(t, 400, code, query)
	}
	// Missing deployment config cannot silently redirect an identity to Legacy.
	unavailable := New(s, fixtureVerifier{}, nil, nil)
	code, out := request(t, unavailable, "human-test", "GET", "/v1/emoji", nil)
	require.Equal(t, 503, code)
	require.Equal(t, "emoji_catalog_unavailable", out["error"])
}
