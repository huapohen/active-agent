package harness

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/stretchr/testify/require"
)

func TestNativeProfileReadKeepsIdentityAndLateStopFence(t *testing.T) {
	for _, mode := range []string{"ok", "late_stop", "wrong_identity", "unavailable"} {
		t.Run(mode, func(t *testing.T) {
			r := runContext()
			var stopped atomic.Bool
			var gets atomic.Int64
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) {
				require.Equal(t, "Bearer fixture", q.Header.Get("Authorization"))
				switch q.URL.Path {
				case "/internal/harness/binding":
					ack := boundAck(r)
					if mode != "unavailable" {
						ack["read_capabilities"] = []string{"profile.read"}
					}
					_ = json.NewEncoder(w).Encode(ack)
				case "/internal/harness/check":
					if stopped.Load() {
						w.WriteHeader(409)
						fmt.Fprint(w, `{"code":"scope_stopped"}`)
						return
					}
					fmt.Fprint(w, `{"allowed":true}`)
				case "/v1/profile":
					gets.Add(1)
					require.Equal(t, "GET", q.Method)
					require.Equal(t, r.RunID, q.URL.Query().Get("run_id"))
					p := domain.Profile{Principal: domain.Principal{ID: r.PrincipalID, Kind: "agent", DisplayName: "同事"}, Version: 1}
					if mode == "wrong_identity" {
						p.Principal.ID = "another-principal"
					}
					if mode == "late_stop" {
						stopped.Store(true)
					}
					_ = json.NewEncoder(w).Encode(p)
				default:
					w.WriteHeader(404)
				}
			}))
			defer server.Close()
			g, err := NewHTTPGateway(server.URL, "fixture", r.PrincipalID, r.ExecutorID)
			require.NoError(t, err)
			require.NoError(t, g.VerifyBinding(context.Background()))
			profile, err := g.ReadProfile(context.Background(), r)
			switch mode {
			case "ok":
				require.NoError(t, err)
				require.Equal(t, r.PrincipalID, profile.Principal.ID)
			case "late_stop":
				require.ErrorIs(t, err, ErrStopped)
				require.Empty(t, profile.Principal.ID)
			case "wrong_identity", "unavailable":
				require.ErrorIs(t, err, ErrDenied)
				require.Empty(t, profile.Principal.ID)
			}
			if mode == "unavailable" {
				require.Zero(t, gets.Load())
			} else {
				require.EqualValues(t, 1, gets.Load())
			}
		})
	}
}
