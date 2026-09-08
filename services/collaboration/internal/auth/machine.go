package auth

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

var (
	ErrMachineConfiguration = errors.New("Clerk machine configuration incomplete")
	// Unsupported formats also fail the ordinary authentication error check. They
	// must never fall back to the human session verifier or caller-supplied IDs.
	ErrMachineTokenFormatUnsupported = errors.Join(ErrUnauthenticated, errors.New("machine token format unsupported"))
)

// MachineIdentity identifies an authenticated executor, not an Agent principal.
// The action gateway must resolve its server-owned executor binding and current
// authorization separately. No custom token claims are promoted into identity.
type MachineIdentity struct {
	Issuer         string
	MachineSubject string
	TokenID        string
	Audience       string
	Scopes         []string
	ExpiresAt      *time.Time
}

type MachineVerifier interface {
	VerifyMachine(context.Context, string) (MachineIdentity, error)
}

type ClerkMachineConfig struct {
	// Issuer is the administrator-bound Clerk instance namespace. The opaque
	// verification response has no iss claim; this must match the instance owning
	// ReceiverMachineID and MachineSecretKey, never a value supplied by a caller.
	Issuer string
	// ReceiverMachineID is this service's Clerk machine, not the calling executor.
	ReceiverMachineID string
	// MachineSecretKey is the receiver's dedicated ak_ secret, NOT CLERK_SECRET_KEY.
	MachineSecretKey string
	// Clerk permits expiration:null. Our default requires a finite lifetime;
	// accepting non-expiring credentials needs an explicit deployment policy.
	AllowNonExpiring bool
}

// ClerkMachine implements Clerk's default opaque M2M verification protocol.
// JWT M2M tokens, OAuth tokens and API keys are explicitly unsupported here.
// In particular, clerk-sdk-go/v2 v2.7.0 jwt.Verify verifies session JWTs and is
// not a substitute for Clerk's separate machine JWT verification algorithm.
type ClerkMachine struct {
	issuer           string
	audience         string
	secret           string
	allowNonExpiring bool
	client           *http.Client
	endpoint         string
	now              func() time.Time
}

var _ MachineVerifier = (*ClerkMachine)(nil)

const (
	clerkMachineVerifyEndpoint = "https://api.clerk.com/v1/m2m_tokens/verify"
	machineMaxBodyBytes        = 64 * 1024
	machineMaxTokenBytes       = 16384
)

func NewClerkMachine(config ClerkMachineConfig) (*ClerkMachine, error) {
	u, err := url.Parse(config.Issuer)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil ||
		u.Path != "" || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" ||
		!machineIdentifier(config.ReceiverMachineID, "mch_", 256) ||
		!machineIdentifier(config.MachineSecretKey, "ak_", 4096) {
		return nil, ErrMachineConfiguration
	}
	return &ClerkMachine{
		issuer: config.Issuer, audience: config.ReceiverMachineID,
		secret: config.MachineSecretKey, allowNonExpiring: config.AllowNonExpiring,
		endpoint: clerkMachineVerifyEndpoint, now: time.Now,
		client: &http.Client{
			Timeout: 8 * time.Second,
			// Even same-host redirects must not resend either the receiver's
			// Authorization secret or the caller's token in the JSON body.
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
	}, nil
}

func (c *ClerkMachine) VerifyMachine(ctx context.Context, token string) (MachineIdentity, error) {
	if c == nil || c.client == nil || c.now == nil || ctx == nil {
		return MachineIdentity{}, ErrUnauthenticated
	}
	if !machineIdentifier(token, "mt_", machineMaxTokenBytes) {
		return MachineIdentity{}, ErrMachineTokenFormatUnsupported
	}
	// Wire format matches clerk-sdk-go/v2@v2.7.0 m2m_token.VerifyParams.
	body, err := json.Marshal(struct {
		Token string `json:"token"`
	}{Token: token})
	if err != nil {
		return MachineIdentity{}, ErrUnauthenticated
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint, bytes.NewReader(body))
	if err != nil {
		return MachineIdentity{}, ErrUnauthenticated
	}
	req.Header.Set("Authorization", "Bearer "+c.secret)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	// Match the wire version pinned by clerk-sdk-go/v2 v2.7.0.
	req.Header.Set("Clerk-API-Version", "2026-05-12")
	req.Header.Set("Cache-Control", "no-store")
	resp, err := c.client.Do(req)
	if err != nil {
		return MachineIdentity{}, ErrUnauthenticated
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return MachineIdentity{}, ErrUnauthenticated
	}
	body, err = io.ReadAll(io.LimitReader(resp.Body, machineMaxBodyBytes+1))
	if err != nil || len(body) > machineMaxBodyBytes {
		return MachineIdentity{}, ErrUnauthenticated
	}
	return c.identityFromMachineResponse(body)
}

func (c *ClerkMachine) identityFromMachineResponse(body []byte) (MachineIdentity, error) {
	fields, err := machineResponseFields(body)
	if err != nil {
		return MachineIdentity{}, ErrUnauthenticated
	}
	// Pointers distinguish explicit false from absent/null booleans. Missing
	// security fields must not inherit the Go SDK response type's zero values.
	var result struct {
		Object     string   `json:"object"`
		ID         string   `json:"id"`
		Subject    string   `json:"subject"`
		Scopes     []string `json:"scopes"`
		Revoked    *bool    `json:"revoked"`
		Expired    *bool    `json:"expired"`
		Expiration *int64   `json:"expiration"`
		CreatedAt  int64    `json:"created_at"`
		UpdatedAt  int64    `json:"updated_at"`
	}
	if json.Unmarshal(body, &result) != nil || result.Object != "machine_to_machine_token" ||
		!machineIdentifier(result.ID, "mt_", 256) || !machineIdentifier(result.Subject, "mch_", 256) ||
		result.Revoked == nil || *result.Revoked || result.Expired == nil || *result.Expired ||
		len(result.Scopes) == 0 || len(result.Scopes) > 150 || fields["expiration"] == nil {
		return MachineIdentity{}, ErrUnauthenticated
	}
	// Official Clerk timestamps are milliseconds, unlike JWT exp/iat seconds.
	now := c.now()
	if result.CreatedAt <= 0 || result.CreatedAt > now.Add(5*time.Second).UnixMilli() ||
		result.UpdatedAt < result.CreatedAt || result.UpdatedAt > now.Add(5*time.Second).UnixMilli() {
		return MachineIdentity{}, ErrUnauthenticated
	}
	var expiresAt *time.Time
	if result.Expiration == nil {
		if !c.allowNonExpiring {
			return MachineIdentity{}, ErrUnauthenticated
		}
	} else {
		// Bound the timestamp before constructing time.Time; do not reinterpret
		// seconds as milliseconds or extend an expired token with clock leeway.
		if *result.Expiration <= now.UnixMilli() || *result.Expiration <= result.CreatedAt ||
			*result.Expiration > 253402300799999 {
			return MachineIdentity{}, ErrUnauthenticated
		}
		expiration := time.UnixMilli(*result.Expiration).UTC()
		expiresAt = &expiration
	}
	seen := make(map[string]bool, len(result.Scopes))
	for _, scope := range result.Scopes {
		if !machineIdentifier(scope, "mch_", 256) || seen[scope] {
			return MachineIdentity{}, ErrUnauthenticated
		}
		seen[scope] = true
	}
	// For opaque M2M, Clerk scopes name receiving machines. They are the
	// audience restriction, not business permissions such as room.write.
	if !seen[c.audience] {
		return MachineIdentity{}, ErrUnauthenticated
	}
	return MachineIdentity{
		Issuer: c.issuer, MachineSubject: result.Subject, TokenID: result.ID,
		Audience: c.audience, Scopes: result.Scopes, ExpiresAt: expiresAt,
	}, nil
}

func machineIdentifier(value, prefix string, maxBytes int) bool {
	if !strings.HasPrefix(value, prefix) || len(value) <= len(prefix) || len(value) > maxBytes {
		return false
	}
	for _, ch := range value[len(prefix):] {
		if (ch < 'a' || ch > 'z') && (ch < 'A' || ch > 'Z') && (ch < '0' || ch > '9') && ch != '_' && ch != '-' {
			return false
		}
	}
	return true
}

// Reject duplicate top-level fields and trailing JSON while remaining forward
// compatible with additional Clerk response fields. Custom claims are ignored.
func machineResponseFields(body []byte) (map[string]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(body))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return nil, ErrUnauthenticated
	}
	fields := map[string]json.RawMessage{}
	for decoder.More() {
		key, err := decoder.Token()
		name, ok := key.(string)
		if err != nil || !ok || fields[name] != nil {
			return nil, ErrUnauthenticated
		}
		// encoding/json accepts case-insensitive struct field aliases. Reject
		// aliases of security fields instead of letting a later "Revoked" or
		// "Subject" silently override the canonical Clerk wire field.
		if name != strings.ToLower(name) {
			switch strings.ToLower(name) {
			case "object", "id", "subject", "scopes", "revoked", "expired", "expiration", "created_at", "updated_at":
				return nil, ErrUnauthenticated
			}
		}
		var value json.RawMessage
		if decoder.Decode(&value) != nil {
			return nil, ErrUnauthenticated
		}
		fields[name] = value
	}
	if token, err = decoder.Token(); err != nil || token != json.Delim('}') {
		return nil, ErrUnauthenticated
	}
	if _, err = decoder.Token(); err != io.EOF {
		return nil, ErrUnauthenticated
	}
	return fields, nil
}
