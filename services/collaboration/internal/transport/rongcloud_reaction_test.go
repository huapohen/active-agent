package transport

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/stretchr/testify/require"
)

func reactionFixture() domain.ReactionReceipt {
	return domain.ReactionReceipt{RoomID: "room", MessageID: "message", PrincipalID: "actor", Version: 3,
		Emoji: "private-emoji-must-not-be-transported", Active: true, Selected: true, Count: 2, Changed: true}
}

func TestReactionCommandSignedCanonicalInvalidationOnly(t *testing.T) {
	var calls atomic.Int32
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		require.Equal(t, http.MethodPost, r.Method)
		require.Equal(t, "/message/group/publish.json", r.URL.Path)
		require.Empty(t, r.URL.RawQuery)
		require.Equal(t, "app-test", r.Header.Get("App-Key"))
		require.Equal(t, "application/x-www-form-urlencoded", r.Header.Get("Content-Type"))
		nonce, err := hex.DecodeString(r.Header.Get("Nonce"))
		require.NoError(t, err)
		require.Len(t, nonce, 16)
		_, err = strconv.ParseInt(r.Header.Get("Timestamp"), 10, 64)
		require.NoError(t, err)
		sig := sha1.Sum([]byte("secret-test" + r.Header.Get("Nonce") + r.Header.Get("Timestamp")))
		require.Equal(t, hex.EncodeToString(sig[:]), r.Header.Get("Signature"))
		require.NoError(t, r.ParseForm())
		require.Len(t, r.Form, 9)
		for key, want := range map[string]string{"fromUserId": "actor", "toGroupId": "room", "objectName": "RC:CmdMsg", "isIncludeSender": "1", "isPersisted": "0", "disablePush": "true", "disableUpdateLastMsg": "true", "needReadReceipt": "0"} {
			require.Equal(t, []string{want}, r.Form[key], key)
		}
		var command map[string]string
		require.NoError(t, json.Unmarshal([]byte(r.Form.Get("content")), &command))
		require.Len(t, command, 2)
		require.Equal(t, "renji.message.reaction", command["name"])
		var data map[string]any
		require.NoError(t, json.Unmarshal([]byte(command["data"]), &data))
		require.Equal(t, map[string]any{"schema": "renji.reaction.v1", "room_id": "room", "message_id": "message", "version": float64(3)}, data)
		require.NotContains(t, r.Form.Get("content"), "private-emoji")
		_, _ = io.WriteString(w, `{"code":200,"messageUIDs":[{"groupId":"room","messageUID":"accepted-command-uid"}]}`)
	}))
	defer s.Close()
	r, err := NewRongCloud(s.URL, "app-test", "secret-test")
	require.NoError(t, err)
	d, err := r.NotifyReaction(context.Background(), reactionFixture())
	require.NoError(t, err)
	require.Equal(t, "accepted-command-uid", d.MessageUIDs[0].MessageUID)
	require.Equal(t, int32(1), calls.Load())
}

func TestReactionMalformedCanonicalPointersDoNotReachProvider(t *testing.T) {
	var calls atomic.Int32
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1); w.WriteHeader(500) }))
	defer s.Close()
	r, err := NewRongCloud(s.URL, "key", "secret")
	require.NoError(t, err)
	for _, mutate := range []func(*domain.ReactionReceipt){
		func(v *domain.ReactionReceipt) { v.RoomID = "" },
		func(v *domain.ReactionReceipt) { v.RoomID = "room&toGroupId=other" },
		func(v *domain.ReactionReceipt) { v.RoomID = "room,other" },
		func(v *domain.ReactionReceipt) { v.MessageID = "../other" },
		func(v *domain.ReactionReceipt) { v.MessageID = strings.Repeat("a", 129) },
		func(v *domain.ReactionReceipt) { v.MessageID = "message\nother" },
		func(v *domain.ReactionReceipt) { v.PrincipalID = "" },
		func(v *domain.ReactionReceipt) { v.PrincipalID = string([]byte{255}) },
		func(v *domain.ReactionReceipt) { v.Version = 0 },
		func(v *domain.ReactionReceipt) { v.Version = -1 },
	} {
		v := reactionFixture()
		mutate(&v)
		_, err := r.NotifyReaction(context.Background(), v)
		require.ErrorIs(t, err, domain.ErrInvalid)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = r.NotifyReaction(ctx, reactionFixture())
	require.ErrorIs(t, err, context.Canceled)
	require.Zero(t, calls.Load())
}

func TestReactionAcceptanceRequiresExactlyMatchingGroupUID(t *testing.T) {
	for _, body := range []string{
		`{"code":200}`,
		`{"code":200,"messageUIDs":[]}`,
		`{"code":200,"messageUIDs":[{"groupId":"other","messageUID":"uid"}]}`,
		`{"code":200,"messageUIDs":[{"groupId":"room","messageUID":""}]}`,
		`{"code":200,"messageUIDs":[{"groupId":"room","messageUID":"   "}]}`,
		`{"code":200,"messageUIDs":[{"groupId":"room","messageUID":"uid"},{"groupId":"other","messageUID":"other-uid"}]}`,
		`{"code":200,"messageUIDs":[{"groupId":"room","messageUID":"uid"},{"groupId":"room","messageUID":"uid2"}]}`,
		`{"code":200,"messageUIDs":[{"groupId":"room","messageUID":123}]}`,
		`not-json`,
	} {
		s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, body) }))
		r, err := NewRongCloud(s.URL, "key", "secret")
		require.NoError(t, err)
		_, err = r.NotifyReaction(context.Background(), reactionFixture())
		var pe *ProviderError
		require.ErrorAs(t, err, &pe, body)
		require.True(t, pe.Unknown, body)
		s.Close()
	}
}

func TestReactionRejectionsAndUnknownResponsesNeverRetry(t *testing.T) {
	for _, tc := range []struct {
		status  int
		body    string
		unknown bool
	}{
		{429, `{"code":429,"errorMessage":"secret-provider-detail"}`, false},
		{200, `{"code":403,"errorMessage":"secret-provider-detail"}`, false},
		{503, `{"code":500,"errorMessage":"secret-provider-detail"}`, true},
		{200, strings.Repeat("x", 262145), true},
	} {
		var calls atomic.Int32
		s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			calls.Add(1)
			w.WriteHeader(tc.status)
			_, _ = io.WriteString(w, tc.body)
		}))
		r, err := NewRongCloud(s.URL, "key", "secret")
		require.NoError(t, err)
		_, err = r.NotifyReaction(context.Background(), reactionFixture())
		var pe *ProviderError
		require.ErrorAs(t, err, &pe)
		require.Equal(t, tc.unknown, pe.Unknown)
		require.NotContains(t, err.Error(), "secret-provider-detail")
		require.Equal(t, int32(1), calls.Load())
		s.Close()
	}
	r, err := NewRongCloud("http://127.0.0.1:1", "key", "secret")
	require.NoError(t, err)
	r.client.Transport = reactionFailingRoundTripper{}
	_, err = r.NotifyReaction(context.Background(), reactionFixture())
	var pe *ProviderError
	require.ErrorAs(t, err, &pe)
	require.True(t, pe.Unknown)
	require.NotContains(t, err.Error(), "private-network-error")
}

type reactionFailingRoundTripper struct{}

func (reactionFailingRoundTripper) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, errors.New("private-network-error")
}
