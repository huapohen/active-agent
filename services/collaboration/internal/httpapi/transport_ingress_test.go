package httpapi

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/huapohen/active-agent/services/collaboration/internal/transport"
	"github.com/stretchr/testify/require"
)

func TestTrustedBridgeIngressRejectsBrowserAndRemoteWithoutStoreAccess(t *testing.T) {
	b := transport.BridgeBinding{ID: "bridge", ReceiverID: "11111111-1111-4111-8111-111111111111", RoomID: "22222222-2222-4222-8222-222222222222", Secret: strings.Repeat("s", 32)}
	gin.SetMode(gin.TestMode)
	g := gin.New()
	v1 := g.Group("/v1")
	require.NoError(t, MountRongCloudIngress(g, v1, nil, []transport.BridgeBinding{b}))
	for _, test := range []struct{ remote, secret, origin string }{{"192.0.2.1:1234", b.Secret, ""}, {"127.0.0.1:1234", "other", ""}, {"127.0.0.1:1234", b.Secret, "http://127.0.0.1:5173"}, {"unknown", b.Secret, ""}} {
		r := httptest.NewRequest("POST", "/internal/transport/rongcloud/bridge/received", strings.NewReader(`{}`))
		r.RemoteAddr = test.remote
		r.Header.Set("Authorization", "Bearer "+test.secret)
		r.Header.Set("Origin", test.origin)
		w := httptest.NewRecorder()
		g.ServeHTTP(w, r)
		require.Equal(t, 403, w.Code)
		require.NotContains(t, w.Body.String(), b.Secret)
	}
}

func TestTrustedBridgeHeartbeatIsNotReceiptAndStatusIsIdentityScoped(t *testing.T) {
	s := httpStore(t)
	ctx := context.Background()
	p, err := s.ResolveIdentity(ctx, "test-only-issuer", "human-test")
	require.NoError(t, err)
	w, err := s.CreateWorkspace(ctx, p.ID, "bridge-http-workspace", "测试接收")
	require.NoError(t, err)
	room, err := s.CreateRoom(ctx, p.ID, "bridge-http-room", w, "合法接收范围", nil)
	require.NoError(t, err)
	b := transport.BridgeBinding{ID: "bridge", ReceiverID: p.ID, RoomID: room.ID, Secret: strings.Repeat("s", 32)}
	g := New(s, fixtureVerifier{}, nil, nil, WithRongCloudBridges([]transport.BridgeBinding{b}))
	r := httptest.NewRequest("POST", "/internal/transport/rongcloud/bridge/heartbeat", strings.NewReader(`{"state":"connected","sequence":1}`))
	r.RemoteAddr = "127.0.0.1:1234"
	r.Header.Set("Authorization", "Bearer "+b.Secret)
	recorder := httptest.NewRecorder()
	g.ServeHTTP(recorder, r)
	require.Equal(t, 200, recorder.Code)
	status, page := request(t, g, "human-test", "GET", "/v1/transport/events", nil)
	require.Equal(t, 200, status)
	require.Empty(t, page["events"])
	state := page["status"].(map[string]any)
	require.Equal(t, "connected", state["bridge_state"])
	require.Nil(t, state["last_received_at"])
	status, page = request(t, g, "outsider-test", "GET", "/v1/transport/events", nil)
	require.Equal(t, 200, status)
	state = page["status"].(map[string]any)
	require.Equal(t, "unavailable", state["bridge_state"])
	require.Nil(t, state["last_heartbeat_at"])
	status, _ = request(t, g, "", "GET", "/v1/transport/events", nil)
	require.Equal(t, 401, status)
	for _, query := range []string{"?after=-1", "?after=0&after=1", "?limit=0", "?limit=101", "?receiver_id=" + p.ID, "?run_id=anything"} {
		status, _ = request(t, g, "human-test", "GET", "/v1/transport/events"+query, nil)
		require.Equal(t, 400, status)
	}
}
