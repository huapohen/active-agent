package auth

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"testing"
	"time"

	"github.com/clerk/clerk-sdk-go/v2"
	"github.com/go-jose/go-jose/v3"
	"github.com/go-jose/go-jose/v3/jwt"
	"github.com/stretchr/testify/require"
)

func TestSessionClaimsCannotImpersonateOrCrossInstance(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	require.NoError(t, err)
	signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: key}, (&jose.SignerOptions{}).WithType("JWT"))
	require.NoError(t, err)
	v := &Clerk{Issuer: "https://example.clerk.accounts.dev", AuthorizedParties: map[string]bool{"http://localhost:5173": true}, JWK: &clerk.JSONWebKey{Key: &key.PublicKey, Algorithm: "RS256"}}
	for _, tc := range []struct {
		name   string
		change func(map[string]any)
		valid  bool
	}{
		{"valid", func(map[string]any) {}, true},
		{"wrong issuer", func(m map[string]any) { m["iss"] = "https://other.clerk.accounts.dev" }, false},
		{"wrong origin", func(m map[string]any) { m["azp"] = "https://evil.invalid" }, false},
		{"missing origin", func(m map[string]any) { delete(m, "azp") }, false},
		{"expired", func(m map[string]any) { m["exp"] = time.Now().Add(-time.Minute).Unix() }, false},
		{"missing expiry", func(m map[string]any) { delete(m, "exp") }, false},
		{"missing session", func(m map[string]any) { delete(m, "sid") }, false},
		{"pending", func(m map[string]any) { m["sts"] = "pending" }, false},
		{"actor token", func(m map[string]any) { m["act"] = map[string]string{"sub": "other"} }, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := map[string]any{"iss": v.Issuer, "sub": "user_test", "sid": "sess_test", "azp": "http://localhost:5173", "iat": time.Now().Unix(), "nbf": time.Now().Add(-time.Second).Unix(), "exp": time.Now().Add(time.Minute).Unix()}
			tc.change(m)
			token, err := jwt.Signed(signer).Claims(m).CompactSerialize()
			require.NoError(t, err)
			identity, err := v.Verify(context.Background(), token)
			if tc.valid {
				require.NoError(t, err)
				require.Equal(t, "user_test", identity.Subject)
			} else {
				require.ErrorIs(t, err, ErrUnauthenticated)
			}
		})
	}
}
