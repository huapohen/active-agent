package transport

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/stretchr/testify/require"
)

func policyServer(t *testing.T, responses []string) (*RongCloud, *atomic.Int32) {
	t.Helper()
	var calls atomic.Int32
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := int(calls.Add(1)) - 1
		require.Less(t, n, len(responses))
		require.Equal(t, http.MethodPost, r.Method)
		paths := []string{"/group/ban/query.json", "/group/user/ban/whitelist/query.json"}
		require.Equal(t, paths[n%2], r.URL.Path)
		require.Empty(t, r.URL.RawQuery)
		require.NoError(t, r.ParseForm())
		require.Len(t, r.Form, 1)
		require.Equal(t, []string{"group"}, r.Form["groupId"])
		h := sha1.Sum([]byte("secret" + r.Header.Get("Nonce") + r.Header.Get("Timestamp")))
		require.Equal(t, hex.EncodeToString(h[:]), r.Header.Get("Signature"))
		_, _ = io.WriteString(w, responses[n])
	}))
	t.Cleanup(s.Close)
	r, err := NewRongCloud(s.URL, "key", "secret")
	require.NoError(t, err)
	return r, &calls
}

func TestGroupPolicyRepeatedReadsCannotGrantClientAccess(t *testing.T) {
	ban := `{"code":200,"groupinfo":[{"groupId":"group","stat":1}]}`
	r, n := policyServer(t, []string{ban, `{"code":200,"userIds":["b","a"]}`, ban, `{"code":200,"userIds":["a","b"]}`})
	v, err := r.ReadGroupWritePolicy(context.Background(), "group")
	require.NoError(t, err)
	require.Equal(t, int32(4), n.Load())
	require.True(t, v.GroupMuted)
	require.True(t, v.RepeatedReadsEqual)
	require.False(t, v.DirectClientSafe)
	require.Contains(t, v.UnverifiedPaths, "recall")
	require.Equal(t, []string{"a", "b"}, v.WhitelistIDs)
	require.Len(t, v.ResponseSHA256, 4)
	require.NotEqual(t, v.ResponseSHA256[1], v.ResponseSHA256[3])
}

func TestGroupPolicyRejectsMissingOrWrongScopeEvidence(t *testing.T) {
	ban := `{"code":200,"groupinfo":[{"groupId":"group","stat":1}]}`
	for _, body := range []string{`{"code":200}`, `{"code":200,"groupinfo":null}`, `{"code":200,"groupinfo":[]}`, `{"code":200,"groupinfo":[{"groupId":"other","stat":1}]}`, `{"code":200,"groupinfo":[{"groupId":"group"}]}`, `{"code":200,"groupinfo":[{"groupId":"group","stat":2}]}`, `{"code":200,"groupinfo":[{"groupId":"group","stat":1},{"groupId":"group","stat":1}]}`} {
		r, n := policyServer(t, []string{body})
		v, err := r.ReadGroupWritePolicy(context.Background(), "group")
		require.Error(t, err)
		require.False(t, v.DirectClientSafe)
		require.Equal(t, int32(1), n.Load())
	}
	for _, body := range []string{`{"code":200}`, `{"code":200,"userIds":null}`, `{"code":200,"userIds":["a","a"]}`, `{"code":200,"userIds":["../a"]}`, `{"code":200,"userIds":[1]}`} {
		r, n := policyServer(t, []string{ban, body})
		_, err := r.ReadGroupWritePolicy(context.Background(), "group")
		require.Error(t, err)
		require.Equal(t, int32(2), n.Load())
	}
}

func TestGroupPolicyDriftAndInvalidRequestFailClosed(t *testing.T) {
	ban := `{"code":200,"groupinfo":[{"groupId":"group","stat":1}]}`
	open := `{"code":200,"groupinfo":[{"groupId":"group","stat":0}]}`
	for _, responses := range [][]string{{ban, `{"code":200,"userIds":[]}`, open, `{"code":200,"userIds":[]}`}, {ban, `{"code":200,"userIds":[]}`, ban, `{"code":200,"userIds":["new"]}`}} {
		r, _ := policyServer(t, responses)
		_, err := r.ReadGroupWritePolicy(context.Background(), "group")
		require.ErrorIs(t, err, ErrPolicyChanged)
	}
	r, n := policyServer(t, nil)
	for _, id := range []string{"", "group,other", "group&size=200", "../group"} {
		_, err := r.ReadGroupWritePolicy(context.Background(), id)
		require.ErrorIs(t, err, domain.ErrInvalid)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := r.ReadGroupWritePolicy(ctx, "group")
	require.ErrorIs(t, err, context.Canceled)
	require.Zero(t, n.Load())
}
