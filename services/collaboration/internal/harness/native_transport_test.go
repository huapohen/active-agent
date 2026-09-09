package harness

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/cloudwego/eino/schema"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/stretchr/testify/require"
)

func transportRunContext() RunContext {
	r := runContext()
	r.PrincipalID = "00000000-0000-4000-8000-000000000001"
	r.ExecutorID = "00000000-0000-4000-8000-000000000002"
	r.RunID = "00000000-0000-4000-8000-000000000003"
	r.RoomID = "00000000-0000-4000-8000-000000000004"
	r.OriginScopes = []Scope{{RoomID: "00000000-0000-4000-8000-000000000005", Epoch: 2}}
	return r
}

func transportFixturePage(r RunContext) domain.TransportArrivalPage {
	at := time.Date(2026, 9, 9, 2, 30, 0, 0, time.UTC)
	return domain.TransportArrivalPage{
		Schema: "renji.transport.events.v1", Transport: "rongcloud", Mode: "trusted_development_bridge",
		ReceiverID: r.PrincipalID, RunID: r.RunID, CoveredRoomIDs: []string{r.RoomID, r.OriginScopes[0].RoomID},
		Events:     []domain.TransportArrival{{Cursor: 11, EventID: 7, RoomID: r.RoomID, MessageID: nativeMessageID, Kind: "message.created", ProviderUID: "private-arrival-evidence", ReceivedAt: at}},
		NextCursor: 11, Status: domain.TransportBridgeStatus{BridgeState: "connected", LastHeartbeatAt: &at, LastReceivedAt: &at},
	}
}

func TestNativeTransportHTTPBoundReadsValidateAndDiscardLateData(t *testing.T) {
	for _, mode := range []string{"ok", "unavailable", "late_stop", "foreign_receiver", "foreign_room", "bad_cursor", "unadvertised"} {
		t.Run(mode, func(t *testing.T) {
			r := transportRunContext()
			var mu sync.Mutex
			stopped, checks, gets := false, 0, 0
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) {
				mu.Lock()
				defer mu.Unlock()
				require.Equal(t, "Bearer fixture", q.Header.Get("Authorization"))
				switch q.URL.Path {
				case "/internal/harness/binding":
					ack := boundAck(r)
					if mode != "unadvertised" {
						ack["read_capabilities"] = []string{"transport.arrival.read"}
					}
					_ = json.NewEncoder(w).Encode(ack)
				case "/internal/harness/check":
					checks++
					if stopped {
						w.WriteHeader(http.StatusConflict)
						fmt.Fprint(w, `{"code":"scope_stopped"}`)
					} else {
						fmt.Fprint(w, `{"allowed":true}`)
					}
				case "/v1/transport/events":
					gets++
					require.Equal(t, http.MethodGet, q.Method)
					require.Len(t, q.URL.Query(), 3)
					require.Equal(t, r.RunID, q.URL.Query().Get("run_id"))
					require.Equal(t, "10", q.URL.Query().Get("after"))
					require.Equal(t, "50", q.URL.Query().Get("limit"))
					p := transportFixturePage(r)
					switch mode {
					case "unavailable":
						p.Events, p.CoveredRoomIDs = []domain.TransportArrival{}, nil
						p.NextCursor = 10
						p.Status = domain.TransportBridgeStatus{BridgeState: "unavailable"}
					case "late_stop":
						stopped = true
					case "foreign_receiver":
						p.ReceiverID = r.ExecutorID
					case "foreign_room":
						p.CoveredRoomIDs = []string{r.ExecutorID}
					case "bad_cursor":
						p.NextCursor++
					}
					_ = json.NewEncoder(w).Encode(p)
				default:
					t.Errorf("unexpected endpoint %s", q.URL.Path)
					w.WriteHeader(404)
				}
			}))
			defer s.Close()
			g, err := NewHTTPGateway(s.URL, "fixture", r.PrincipalID, r.ExecutorID)
			require.NoError(t, err)
			require.NoError(t, g.VerifyBinding(context.Background()))
			page, err := g.ReadTransportArrivals(context.Background(), r, TransportArrivalQuery{After: 10})
			mu.Lock()
			defer mu.Unlock()
			switch mode {
			case "ok", "unavailable":
				require.NoError(t, err)
				require.Equal(t, r.PrincipalID, page.ReceiverID)
				require.Equal(t, 2, checks)
				if mode == "ok" {
					require.Len(t, page.Events, 1)
				} else {
					require.Empty(t, page.Events)
					require.Equal(t, "unavailable", page.Status.BridgeState)
				}
			case "late_stop":
				require.ErrorIs(t, err, ErrStopped)
				require.Equal(t, 2, checks)
			default:
				require.Error(t, err)
			}
			if mode == "unadvertised" {
				require.Zero(t, gets)
				require.Zero(t, checks)
			} else {
				require.Equal(t, 1, gets)
			}
			if err != nil {
				require.Equal(t, domain.TransportArrivalPage{}, page)
			}
		})
	}
}

type transportReadGateway struct {
	fakeGateway
	late, bad, disabled bool
	reads               int
}

func (g *transportReadGateway) NativeReadCapabilities() []string {
	if g.disabled {
		return nil
	}
	return []string{"transport.arrival.read"}
}

func (g *transportReadGateway) ReadTransportArrivals(_ context.Context, r RunContext, _ TransportArrivalQuery) (domain.TransportArrivalPage, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.reads++
	p := transportFixturePage(r)
	if g.late {
		g.stopped = true
	}
	if g.bad {
		p.ReceiverID = r.ExecutorID
	}
	return p, nil
}

func TestEinoTransportObservationUsesRealPluginAndEvidenceWithoutActions(t *testing.T) {
	g := &transportReadGateway{}
	m := &fakeModel{messages: []*schema.Message{
		nativeToolMessage("im_transport_arrival_read", `{"after":0,"limit":50}`),
		{Role: schema.Assistant, Content: `{"summary":"Read one persisted SDK arrival; no new delivery was requested","done":true,"actions":[]}`},
	}}
	p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
	require.NoError(t, err)
	result, err := p.Plan(context.Background(), StageInput{Context: transportRunContext(), Goal: "Observe current receiver arrivals", Attempt: 1})
	require.NoError(t, err)
	require.True(t, result.Done)
	require.Empty(t, result.Actions)
	require.Equal(t, 1, g.reads)
	require.Equal(t, 2, m.calls)
	require.True(t, m.toolsSeen)
	require.Zero(t, g.effects)
	var observations int
	for _, e := range g.events {
		if e.Type == "tool.result" {
			observations++
			raw, err := json.Marshal(e)
			require.NoError(t, err)
			require.Contains(t, string(raw), "persisted_sdk_arrivals")
			require.Contains(t, string(raw), "private-arrival-evidence")
			require.Contains(t, string(raw), transportRunContext().PrincipalID)
		}
	}
	require.Equal(t, 1, observations)
}

func TestEinoTransportPluginFencesForeignStoppedAndModelIdentityArguments(t *testing.T) {
	for _, mode := range []string{"foreign", "late_stop", "model_run", "model_identity", "bad_limit", "null_after", "null_limit", "unadvertised"} {
		t.Run(mode, func(t *testing.T) {
			g := &transportReadGateway{bad: mode == "foreign", late: mode == "late_stop", disabled: mode == "unadvertised"}
			args := `{"after":0,"limit":50}`
			if mode == "model_run" {
				args = `{"run_id":"someone-else","after":0}`
			}
			if mode == "model_identity" {
				args = `{"receiver_id":"human","after":0}`
			}
			if mode == "bad_limit" {
				args = `{"after":0,"limit":101}`
			}
			if mode == "null_after" {
				args = `{"after":null,"limit":50}`
			}
			if mode == "null_limit" {
				args = `{"after":0,"limit":null}`
			}
			m := &fakeModel{messages: []*schema.Message{nativeToolMessage("im_transport_arrival_read", args), {Role: schema.Assistant, Content: `{"summary":"must not continue","done":true,"actions":[]}`}}}
			p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
			require.NoError(t, err)
			_, err = p.Plan(context.Background(), StageInput{Context: transportRunContext(), Goal: "observe", Attempt: 1})
			require.Error(t, err)
			require.Equal(t, 1, m.calls)
			require.Zero(t, g.effects)
			if mode == "foreign" || mode == "late_stop" {
				require.Equal(t, 1, g.reads)
			} else {
				require.Zero(t, g.reads)
			}
			for _, e := range g.events {
				require.NotEqual(t, "tool.result", e.Type)
				raw, _ := json.Marshal(e)
				require.NotContains(t, string(raw), "private-arrival-evidence")
			}
		})
	}
}

func TestNativeTransportPageRejectsForgedObservationAndCursors(t *testing.T) {
	r := transportRunContext()
	require.NoError(t, validateTransportArrivalPage(r, TransportArrivalQuery{}, transportFixturePage(r)))
	for name, mutate := range map[string]func(*domain.TransportArrivalPage){
		"schema":             func(p *domain.TransportArrivalPage) { p.Schema = "future-schema" },
		"duplicate_coverage": func(p *domain.TransportArrivalPage) { p.CoveredRoomIDs = append(p.CoveredRoomIDs, r.RoomID) },
		"uncovered_event":    func(p *domain.TransportArrivalPage) { p.CoveredRoomIDs = []string{r.OriginScopes[0].RoomID} },
		"duplicate_cursor":   func(p *domain.TransportArrivalPage) { p.Events = append(p.Events, p.Events[0]) },
		"unsafe_cursor": func(p *domain.TransportArrivalPage) {
			p.Events[0].Cursor = maxTransportReadCursor + 1
			p.NextCursor = p.Events[0].Cursor
		},
		"forged_next":                  func(p *domain.TransportArrivalPage) { p.NextCursor++ },
		"forged_more":                  func(p *domain.TransportArrivalPage) { p.HasMore = true },
		"fake_provider_uid":            func(p *domain.TransportArrivalPage) { p.Events[0].ProviderUID = "https://provider.invalid" },
		"fake_kind":                    func(p *domain.TransportArrivalPage) { p.Events[0].Kind = "model.claimed_delivery" },
		"missing_heartbeat":            func(p *domain.TransportArrivalPage) { p.Status.LastHeartbeatAt = nil },
		"missing_receipt_time":         func(p *domain.TransportArrivalPage) { p.Status.LastReceivedAt = nil },
		"newer_than_last":              func(p *domain.TransportArrivalPage) { p.Events[0].ReceivedAt = p.Events[0].ReceivedAt.Add(time.Hour) },
		"status_leak_without_coverage": func(p *domain.TransportArrivalPage) { p.Events = nil; p.NextCursor = 0; p.CoveredRoomIDs = nil },
	} {
		t.Run(name, func(t *testing.T) {
			p := transportFixturePage(r)
			mutate(&p)
			require.Error(t, validateTransportArrivalPage(r, TransportArrivalQuery{}, p))
		})
	}
	for _, q := range []TransportArrivalQuery{{After: -1}, {After: maxTransportReadCursor + 1}, {Limit: -1}, {Limit: 101}} {
		_, err := transportReadLimit(q)
		require.ErrorIs(t, err, ErrInvalid)
	}
}
