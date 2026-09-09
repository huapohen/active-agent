package harness

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strconv"

	"github.com/cloudwego/eino/components/tool"
	"github.com/cloudwego/eino/components/tool/utils"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
)

const maxTransportReadCursor int64 = 9007199254740991

// Optional, deployment-advertised plugin. Model arguments never supply the
// receiver, Run, room set, endpoint or credential.
type NativeTransportReader interface {
	NativeReadCapabilities() []string
	ReadTransportArrivals(context.Context, RunContext, TransportArrivalQuery) (domain.TransportArrivalPage, error)
}

type TransportArrivalQuery struct {
	After int64 `json:"after"`
	Limit int   `json:"limit"`
}

func (q *TransportArrivalQuery) UnmarshalJSON(raw []byte) error {
	type plain TransportArrivalQuery
	var value plain
	if !bytes.HasPrefix(bytes.TrimSpace(raw), []byte("{")) {
		return ErrInvalid
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(&value) != nil || d.Decode(new(any)) != io.EOF {
		return ErrInvalid
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil {
		return ErrInvalid
	}
	for _, name := range []string{"after", "limit"} {
		if v, present := fields[name]; present && bytes.Equal(bytes.TrimSpace(v), []byte("null")) {
			return ErrInvalid
		}
	}
	*q = TransportArrivalQuery(value)
	return nil
}

func transportReadLimit(q TransportArrivalQuery) (int, error) {
	if q.After < 0 || q.After > maxTransportReadCursor || q.Limit < 0 || q.Limit > 100 {
		return 0, ErrInvalid
	}
	if q.Limit == 0 {
		return 50, nil
	}
	return q.Limit, nil
}

func validateTransportArrivalPage(r RunContext, q TransportArrivalQuery, p domain.TransportArrivalPage) error {
	limit, err := transportReadLimit(q)
	if err != nil {
		return err
	}
	if p.ReceiverID != r.PrincipalID || p.RunID != r.RunID {
		return ErrDenied
	}
	if p.Schema != "renji.transport.events.v1" || p.Transport != "rongcloud" || p.Mode != "trusted_development_bridge" || len(p.CoveredRoomIDs) > 100 || len(p.Events) > limit {
		return ErrInvalid
	}
	covered, lastRoom := map[string]bool{}, ""
	for _, room := range p.CoveredRoomIDs {
		if !inRun(r, room) {
			return ErrDenied
		}
		if room <= lastRoom || !validResourceIDs(room) {
			return ErrInvalid
		}
		covered[room], lastRoom = true, room
	}
	status := p.Status
	if status.BridgeState != "connected" && status.BridgeState != "disconnected" && status.BridgeState != "unavailable" {
		return ErrInvalid
	}
	if (status.LastHeartbeatAt != nil && status.LastHeartbeatAt.IsZero()) || (status.LastReceivedAt != nil && status.LastReceivedAt.IsZero()) || (status.BridgeState != "unavailable" && status.LastHeartbeatAt == nil) {
		return ErrInvalid
	}
	if len(covered) == 0 && (len(p.Events) > 0 || status.BridgeState != "unavailable" || status.LastHeartbeatAt != nil || status.LastReceivedAt != nil) {
		return ErrDenied
	}
	last := q.After
	for _, event := range p.Events {
		if !covered[event.RoomID] || !inRun(r, event.RoomID) {
			return ErrDenied
		}
		if event.Cursor <= last || event.Cursor > maxTransportReadCursor || event.EventID < 1 || event.EventID > maxTransportReadCursor || !validResourceIDs(event.MessageID) || event.ReceivedAt.IsZero() || (event.Kind != "message.created" && event.Kind != "message.reaction_set") || !transportProviderUID(event.ProviderUID) {
			return ErrInvalid
		}
		if status.LastReceivedAt == nil || event.ReceivedAt.After(*status.LastReceivedAt) {
			return ErrInvalid
		}
		last = event.Cursor
	}
	if p.NextCursor != last || (p.HasMore && len(p.Events) != limit) {
		return ErrInvalid
	}
	return nil
}

func transportProviderUID(value string) bool {
	if len(value) < 1 || len(value) > 128 {
		return false
	}
	for _, c := range value {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

func (g *HTTPGateway) ReadTransportArrivals(ctx context.Context, r RunContext, q TransportArrivalQuery) (domain.TransportArrivalPage, error) {
	if !g.supportsNativeRead("transport.arrival.read") {
		return domain.TransportArrivalPage{}, ErrDenied
	}
	limit, err := transportReadLimit(q)
	if err != nil {
		return domain.TransportArrivalPage{}, err
	}
	if err = g.Check(ctx, r); err != nil {
		return domain.TransportArrivalPage{}, err
	}
	query := url.Values{"run_id": {r.RunID}, "after": {strconv.FormatInt(q.After, 10)}, "limit": {strconv.Itoa(limit)}}
	var out domain.TransportArrivalPage
	if err = g.request(ctx, http.MethodGet, "/v1/transport/events?"+query.Encode(), nil, &out); err != nil {
		return domain.TransportArrivalPage{}, err
	}
	if err = validateTransportArrivalPage(r, q, out); err != nil {
		return domain.TransportArrivalPage{}, err
	}
	if err = g.Check(ctx, r); err != nil {
		return domain.TransportArrivalPage{}, err
	}
	return out, nil
}

func nativeTransportTools(reader NativeTransportReader, trace *stageTrace) ([]tool.BaseTool, error) {
	available := false
	for _, capability := range reader.NativeReadCapabilities() {
		available = available || capability == "transport.arrival.read"
	}
	if !available {
		return nil, nil
	}
	t, err := utils.InferTool("im_transport_arrival_read", "Read this Agent receiver's persisted RongCloud arrivals within all original Run scopes. after is a cursor from this exact receiver and current Run coverage; limit defaults to 50, maximum 100. A connection heartbeat is not a message receipt. unavailable means no observed heartbeat for the current bridge coverage; it does not claim delivery or erase separately recorded arrivals. Never chooses identity, Run, rooms or credentials.", func(ctx context.Context, q TransportArrivalQuery) (string, error) {
		if _, err := transportReadLimit(q); err != nil {
			return "", err
		}
		if err := trace.check(ctx); err != nil {
			return "", err
		}
		page, err := reader.ReadTransportArrivals(ctx, trace.input.Context, q)
		if err != nil {
			return "", err
		}
		if err = validateTransportArrivalPage(trace.input.Context, q, page); err != nil {
			return "", err
		}
		if err = trace.check(ctx); err != nil {
			return "", err
		}
		// toolFence persists this visible observation and the complete page only
		// after the final authorization check. Neither is a new business action.
		raw, err := json.Marshal(map[string]any{"page": page, "observation": map[string]any{"kind": "persisted_sdk_arrivals", "event_count": len(page.Events), "bridge_state": page.Status.BridgeState, "has_more": page.HasMore}})
		return string(raw), err
	})
	if err != nil {
		return nil, err
	}
	return []tool.BaseTool{t}, nil
}
