package auth

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/clerk/clerk-sdk-go/v2"
	"github.com/clerk/clerk-sdk-go/v2/jwt"
)

var ErrUnauthenticated = errors.New("unauthenticated")

type Identity struct{ Issuer, Subject string }
type Verifier interface {
	Verify(context.Context, string) (Identity, error)
}

type Clerk struct {
	Issuer            string
	AuthorizedParties map[string]bool
	client            *http.Client
	mu                sync.Mutex
	keys              map[string]*clerk.JSONWebKey
	loaded            time.Time
	// A pinned JWK is used by offline verifier tests; deployment uses key rotation.
	JWK *clerk.JSONWebKey
}

func NewClerk(issuer string, parties []string) (*Clerk, error) {
	u, err := url.Parse(issuer)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Path != "" || len(parties) == 0 {
		return nil, errors.New("Clerk configuration incomplete")
	}
	a := map[string]bool{}
	for _, p := range parties {
		if p == "" || p == "*" {
			return nil, errors.New("explicit authorized parties required")
		}
		a[p] = true
	}
	client := &http.Client{Timeout: 8 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	return &Clerk{Issuer: issuer, AuthorizedParties: a, client: client}, nil
}
func (c *Clerk) key(ctx context.Context, token string) (*clerk.JSONWebKey, error) {
	if c.JWK != nil {
		return c.JWK, nil
	}
	u, err := jwt.Decode(ctx, &jwt.DecodeParams{Token: token})
	if err != nil || u.KeyID == "" {
		return nil, ErrUnauthenticated
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if time.Since(c.loaded) < 5*time.Minute {
		if k := c.keys[u.KeyID]; k != nil {
			return k, nil
		}
		if time.Since(c.loaded) < 30*time.Second {
			return nil, ErrUnauthenticated
		}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.Issuer+"/.well-known/jwks.json", nil)
	if err != nil {
		return nil, ErrUnauthenticated
	}
	resp, err := c.client.Do(req)
	if err != nil {
		return nil, ErrUnauthenticated
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, ErrUnauthenticated
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 262145))
	if err != nil || len(b) > 262144 {
		return nil, ErrUnauthenticated
	}
	var set clerk.JSONWebKeySet
	if json.Unmarshal(b, &set) != nil || len(set.Keys) > 100 {
		return nil, ErrUnauthenticated
	}
	keys := map[string]*clerk.JSONWebKey{}
	for _, k := range set.Keys {
		if k.Use == "sig" && k.Algorithm == "RS256" {
			keys[k.KeyID] = k
		}
	}
	c.keys = keys
	c.loaded = time.Now()
	if k := keys[u.KeyID]; k != nil {
		return k, nil
	}
	return nil, ErrUnauthenticated
}
func (c *Clerk) Verify(ctx context.Context, token string) (Identity, error) {
	if len(token) > 16384 || token == "" {
		return Identity{}, ErrUnauthenticated
	}
	key, err := c.key(ctx, token)
	if err != nil {
		return Identity{}, ErrUnauthenticated
	}
	claims, err := jwt.Verify(ctx, &jwt.VerifyParams{Token: token, JWK: key, Leeway: 5 * time.Second,
		AuthorizedPartyHandler: func(azp string) bool { return c.AuthorizedParties[azp] },
		CustomClaimsConstructor: func(context.Context) any {
			return &struct {
				Status string `json:"sts"`
			}{}
		}})
	if err != nil {
		return Identity{}, ErrUnauthenticated
	}
	// SDK's issuer check accepts Clerk domains generally; bind this exact instance.
	if claims.Issuer != c.Issuer || claims.Subject == "" || claims.SessionID == "" || claims.Expiry == nil || claims.NotBefore == nil || len(claims.Actor) > 0 {
		return Identity{}, ErrUnauthenticated
	}
	if custom, ok := claims.Custom.(*struct {
		Status string `json:"sts"`
	}); ok && custom.Status != "" && custom.Status != "active" {
		return Identity{}, ErrUnauthenticated
	}
	return Identity{Issuer: claims.Issuer, Subject: claims.Subject}, nil
}
