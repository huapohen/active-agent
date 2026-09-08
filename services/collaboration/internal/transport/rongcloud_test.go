package transport

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/stretchr/testify/require"
)

func TestSignedTransportAndCanonicalMetadata(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, "app-test", r.Header.Get("App-Key"))
		h := sha1.Sum([]byte("secret-test" + r.Header.Get("Nonce") + r.Header.Get("Timestamp")))
		require.Equal(t, hex.EncodeToString(h[:]), r.Header.Get("Signature"))
		require.NoError(t, r.ParseForm())
		switch r.URL.Path {
		case "/user/getToken.json":
			require.Equal(t, "actor", r.Form.Get("userId"))
			w.Write([]byte(`{"code":200,"userId":"actor","token":"fixture-token"}`))
		case "/message/group/publish.json":
			require.Equal(t, "1", r.Form.Get("isIncludeSender"))
			var body map[string]string
			require.NoError(t, json.Unmarshal([]byte(r.Form.Get("content")), &body))
			var extra map[string]any
			require.NoError(t, json.Unmarshal([]byte(body["extra"]), &extra))
			require.Equal(t, "message", extra["message_id"])
			require.Equal(t, float64(4), extra["seq"])
			w.Write([]byte(`{"code":200,"messageUIDs":[{"groupId":"room","messageUID":"provider-uid"}]}`))
		default:
			t.Errorf("unexpected route")
		}
	}))
	defer s.Close()
	r, err := NewRongCloud(s.URL, "app-test", "secret-test")
	require.NoError(t, err)
	session, err := r.Session(context.Background(), domain.Principal{ID: "actor", DisplayName: "Agent同事"})
	require.NoError(t, err)
	require.Equal(t, "actor", session.UserID)
	delivery, err := r.Publish(context.Background(), domain.Message{ID: "message", RoomID: "room", AuthorID: "actor", Content: "消息", Seq: 4})
	require.NoError(t, err)
	require.Len(t, delivery.MessageUIDs, 1)
}
func TestAmbiguousDeliveryNeverCountsAsSuccess(t *testing.T) {
	for _, body := range []string{`{"code":200}`, `{"code":200,"messageUIDs":[{"groupId":"wrong","messageUID":"id"}]}`, `not-json`} {
		s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(body)) }))
		r, err := NewRongCloud(s.URL, "key", "secret")
		require.NoError(t, err)
		_, err = r.Publish(context.Background(), domain.Message{RoomID: "room"})
		var pe *ProviderError
		require.ErrorAs(t, err, &pe)
		require.True(t, pe.Unknown)
		s.Close()
	}
}
