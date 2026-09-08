package harness

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const gatewayProtocol = "renji-harness-v1"

type HTTPGateway struct {
	base             string
	token            string
	principal        string
	executor         string
	client           *http.Client
	capabilitiesMu   sync.RWMutex
	actionTypes      []string
	readCapabilities []string
}

func safeEndpoint(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", ErrInvalid
	}
	local := u.Hostname() == "localhost"
	if ip := net.ParseIP(u.Hostname()); ip != nil {
		local = ip.IsLoopback()
	}
	if u.Scheme != "https" && !(u.Scheme == "http" && local) {
		return "", fmt.Errorf("%w: TLS required outside loopback", ErrInvalid)
	}
	return strings.TrimRight(u.String(), "/"), nil
}

func noRedirect(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }

func NewHTTPGateway(endpoint, token, principal, executor string) (*HTTPGateway, error) {
	base, err := safeEndpoint(endpoint)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(token) == "" || strings.ContainsAny(token, "\r\n") || principal == "" || executor == "" {
		return nil, ErrInvalid
	}
	return &HTTPGateway{base: base, token: token, principal: principal, executor: executor, client: &http.Client{Timeout: 15 * time.Second, CheckRedirect: noRedirect}}, nil
}

// VerifyBinding is mandatory before worker startup. These acknowledgements
// assert implemented server contracts, not values the client can self-grant.
// An unimplemented route or human session credential cannot silently enable it.
func (g *HTTPGateway) VerifyBinding(ctx context.Context) error {
	g.capabilitiesMu.Lock()
	g.actionTypes = nil
	g.readCapabilities = nil
	g.capabilitiesMu.Unlock()
	var binding struct {
		Protocol            string          `json:"protocol"`
		PrincipalID         string          `json:"principal_id"`
		ExecutorID          string          `json:"executor_id"`
		ServerBound         bool            `json:"server_bound"`
		ActionsIdempotent   bool            `json:"actions_idempotent"`
		ScopeEpochsEnforced bool            `json:"scope_epochs_enforced"`
		ActionTypes         json.RawMessage `json:"action_types"`
		ReadCapabilities    []string        `json:"read_capabilities"`
	}
	if err := g.post(ctx, "/internal/harness/binding", map[string]string{"principal_id": g.principal, "executor_id": g.executor}, &binding); err != nil {
		return err
	}
	if binding.Protocol != gatewayProtocol || binding.PrincipalID != g.principal || binding.ExecutorID != g.executor || !binding.ServerBound || !binding.ActionsIdempotent || !binding.ScopeEpochsEnforced {
		return ErrDenied
	}
	// Missing action_types means the original v1 server contract only. New
	// capabilities must be explicit; old histories and message-only fixtures work.
	actions := []string{"message.send"}
	if len(binding.ActionTypes) > 0 {
		if json.Unmarshal(binding.ActionTypes, &actions) != nil {
			return ErrDenied
		}
	}
	if len(actions) == 0 || len(actions) > 64 || len(binding.ReadCapabilities) > 64 {
		return ErrDenied
	}
	seen := map[string]bool{}
	for _, name := range actions {
		if name == "" || len(name) > 128 || seen[name] {
			return ErrDenied
		}
		seen[name] = true
	}
	seen = map[string]bool{}
	for _, name := range binding.ReadCapabilities {
		if name == "" || len(name) > 128 || seen[name] {
			return ErrDenied
		}
		seen[name] = true
	}
	g.capabilitiesMu.Lock()
	g.actionTypes = actions
	g.readCapabilities = append([]string(nil), binding.ReadCapabilities...)
	g.capabilitiesMu.Unlock()
	return nil
}

func (g *HTTPGateway) AllowedActionTypes() []string {
	g.capabilitiesMu.RLock()
	defer g.capabilitiesMu.RUnlock()
	return append([]string(nil), g.actionTypes...)
}
func (g *HTTPGateway) NativeReadCapabilities() []string {
	g.capabilitiesMu.RLock()
	defer g.capabilitiesMu.RUnlock()
	return append([]string(nil), g.readCapabilities...)
}
func (g *HTTPGateway) supportsNativeRead(name string) bool {
	for _, capability := range g.NativeReadCapabilities() {
		if capability == name {
			return true
		}
	}
	return false
}

func (g *HTTPGateway) bound(r RunContext) error {
	if err := r.Validate(); err != nil {
		return err
	}
	if r.PrincipalID != g.principal || r.ExecutorID != g.executor {
		return ErrDenied
	}
	return nil
}

func (g *HTTPGateway) Check(ctx context.Context, r RunContext) error {
	if err := g.bound(r); err != nil {
		return err
	}
	var result struct {
		Allowed bool `json:"allowed"`
	}
	if err := g.post(ctx, "/internal/harness/check", map[string]any{"context": r}, &result); err != nil {
		return err
	}
	if !result.Allowed {
		return ErrDenied
	}
	return nil
}
func (g *HTTPGateway) Execute(ctx context.Context, r RunContext, a Action) (Receipt, error) {
	if err := g.bound(r); err != nil {
		return Receipt{}, err
	}
	var result Receipt
	err := g.post(ctx, "/internal/harness/actions", map[string]any{"context": r, "action": a}, &result)
	if err != nil {
		return Receipt{}, err
	}
	return result, result.Validate(a)
}
func (g *HTTPGateway) AppendEvent(ctx context.Context, r RunContext, e Event) error {
	if err := g.bound(r); err != nil {
		return err
	}
	return g.post(ctx, "/internal/harness/events", map[string]any{"context": r, "event": e}, nil)
}

func (g *HTTPGateway) post(ctx context.Context, path string, body any, out any) error {
	return g.request(ctx, http.MethodPost, path, body, out)
}

func (g *HTTPGateway) request(ctx context.Context, method, path string, body any, out any) error {
	encoded, err := json.Marshal(body)
	if err != nil {
		return ErrInvalid
	}
	if len(encoded) > 2*1024*1024 {
		return ErrInvalid
	}
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(encoded)
	}
	req, err := http.NewRequestWithContext(ctx, method, g.base+path, reader)
	if err != nil {
		return ErrInvalid
	}
	req.Header.Set("Authorization", "Bearer "+g.token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := g.client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return fmt.Errorf("harness gateway transport unavailable")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 2*1024*1024+1))
	if err != nil || len(data) > 2*1024*1024 {
		return fmt.Errorf("harness gateway response invalid")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var code struct {
			Code string `json:"code"`
		}
		_ = json.Unmarshal(data, &code)
		if code.Code == "scope_stopped" || code.Code == "scope_epoch_mismatch" {
			return ErrStopped
		}
		switch resp.StatusCode {
		case 401, 403:
			return ErrDenied
		case 400, 404, 409, 422:
			return ErrInvalid
		default:
			return fmt.Errorf("harness gateway HTTP %d", resp.StatusCode)
		}
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(data, out); err != nil {
		return fmt.Errorf("harness gateway response invalid")
	}
	return nil
}
