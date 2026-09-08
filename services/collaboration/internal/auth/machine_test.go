package auth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const (
	testMachineIssuer  = "https://machine-test.clerk.accounts.dev"
	testMachineSubject = "mch_executorTest"
	testMachineTarget  = "mch_collaborationTest"
	testMachineSecret  = "ak_syntheticReceiverSecret"
	testMachineToken   = "mt_syntheticOpaqueCallerToken"
)

var testMachineNow = time.Date(2026, time.September, 9, 0, 0, 0, 0, time.UTC)

func machineTestConfig() ClerkMachineConfig {
	return ClerkMachineConfig{
		Issuer: testMachineIssuer, ReceiverMachineID: testMachineTarget,
		MachineSecretKey: testMachineSecret,
	}
}

// Wire shape follows the official Go SDK M2MToken response, with the millisecond
// timestamp semantics specified in Clerk's M2M guide (not fabricated JWT claims).
func machineTestResponse() map[string]any {
	return map[string]any{
		"object": "machine_to_machine_token", "id": "mt_verifiedTokenID",
		"subject": testMachineSubject, "scopes": []string{testMachineTarget},
		"claims":  map[string]any{"agent_id": "untrusted-agent", "aud": "untrusted-audience"},
		"revoked": false, "revocation_reason": nil, "expired": false,
		"expiration": testMachineNow.Add(time.Hour).UnixMilli(), "last_used_at": nil,
		"created_at": testMachineNow.Add(-time.Minute).UnixMilli(),
		"updated_at": testMachineNow.UnixMilli(),
	}
}

func machineTestVerifier(t *testing.T, handler http.HandlerFunc) *ClerkMachine {
	t.Helper()
	server := httptest.NewTLSServer(handler)
	t.Cleanup(server.Close)
	verifier, err := NewClerkMachine(machineTestConfig())
	if err != nil {
		t.Fatal("test verifier configuration failed")
	}
	// Package-private test seam: production has no endpoint/client override and
	// always calls the official HTTPS endpoint with normal certificate validation.
	verifier.endpoint = server.URL + "/v1/m2m_tokens/verify"
	verifier.client.Transport = server.Client().Transport
	verifier.now = func() time.Time { return testMachineNow }
	return verifier
}

func TestMachineVerifyOfficialHTTPProtocol(t *testing.T) {
	var calls atomic.Int32
	verifier := machineTestVerifier(t, func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Method != http.MethodPost || r.URL.Path != "/v1/m2m_tokens/verify" || r.URL.RawQuery != "" {
			t.Error("wrong verification method or endpoint")
		}
		if r.Header.Get("Authorization") != "Bearer "+testMachineSecret || r.Header.Get("Content-Type") != "application/json" {
			t.Error("missing receiver authentication or JSON content type")
		}
		if r.Header.Get("Clerk-API-Version") != "2026-05-12" {
			t.Error("wire version differs from the inspected official Go SDK")
		}
		var request map[string]string
		if json.NewDecoder(r.Body).Decode(&request) != nil || len(request) != 1 || request["token"] != testMachineToken {
			t.Error("request is not the official token-only JSON shape")
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(machineTestResponse())
	})
	identity, err := verifier.VerifyMachine(context.Background(), testMachineToken)
	if err != nil {
		t.Fatal("valid official opaque response rejected")
	}
	if identity.Issuer != testMachineIssuer || identity.MachineSubject != testMachineSubject ||
		identity.Audience != testMachineTarget || identity.TokenID != "mt_verifiedTokenID" ||
		!reflect.DeepEqual(identity.Scopes, []string{testMachineTarget}) ||
		identity.ExpiresAt == nil || !identity.ExpiresAt.Equal(testMachineNow.Add(time.Hour)) || calls.Load() != 1 {
		t.Fatal("identity did not preserve verified source and receiver scope")
	}
	// The only subject returned comes from Clerk, never from claims.agent_id.
	if _, implementsHumanVerifier := any(verifier).(Verifier); implementsHumanVerifier {
		t.Fatal("machine adapter unexpectedly satisfies the human verifier interface")
	}
}

func TestMachineVerifyRejectsInvalidSecurityFields(t *testing.T) {
	cases := []struct {
		name string
		edit func(map[string]any)
	}{
		{"revoked", func(m map[string]any) { m["revoked"] = true }},
		{"missing revoked", func(m map[string]any) { delete(m, "revoked") }},
		{"null revoked", func(m map[string]any) { m["revoked"] = nil }},
		{"expired", func(m map[string]any) { m["expired"] = true }},
		{"missing expired", func(m map[string]any) { delete(m, "expired") }},
		{"null expired", func(m map[string]any) { m["expired"] = nil }},
		{"wrong object", func(m map[string]any) { m["object"] = "api_key" }},
		{"missing subject", func(m map[string]any) { delete(m, "subject") }},
		{"human subject", func(m map[string]any) { m["subject"] = "user_executorTest" }},
		{"subject control", func(m map[string]any) { m["subject"] = "mch_executor\n" }},
		{"missing token ID", func(m map[string]any) { delete(m, "id") }},
		{"bad token ID", func(m map[string]any) { m["id"] = "api_test" }},
		{"wrong recipient", func(m map[string]any) { m["scopes"] = []string{"mch_anotherReceiver"} }},
		{"custom aud cannot replace scope", func(m map[string]any) {
			m["scopes"] = []string{}
			m["claims"] = map[string]any{"aud": testMachineTarget}
		}},
		{"business scope is not audience", func(m map[string]any) { m["scopes"] = []string{testMachineTarget, "room.write"} }},
		{"missing scopes", func(m map[string]any) { delete(m, "scopes") }},
		{"null scopes", func(m map[string]any) { m["scopes"] = nil }},
		{"string scopes", func(m map[string]any) { m["scopes"] = testMachineTarget }},
		{"duplicate scopes", func(m map[string]any) { m["scopes"] = []string{testMachineTarget, testMachineTarget} }},
		{"too many scopes", func(m map[string]any) { m["scopes"] = make([]string, 151) }},
		{"missing expiration", func(m map[string]any) { delete(m, "expiration") }},
		{"null expiration default policy", func(m map[string]any) { m["expiration"] = nil }},
		{"past expiration", func(m map[string]any) { m["expiration"] = testMachineNow.Add(-time.Second).UnixMilli() }},
		{"equal expiration", func(m map[string]any) { m["expiration"] = testMachineNow.UnixMilli() }},
		{"seconds are not milliseconds", func(m map[string]any) { m["expiration"] = testMachineNow.Add(time.Hour).Unix() }},
		{"string expiration", func(m map[string]any) { m["expiration"] = "9999999999999" }},
		{"fraction expiration", func(m map[string]any) { m["expiration"] = 1800000000000.5 }},
		{"overflow expiration", func(m map[string]any) { m["expiration"] = json.Number("9223372036854775808") }},
		{"out of range expiration", func(m map[string]any) { m["expiration"] = int64(253402300800000) }},
		{"missing creation", func(m map[string]any) { delete(m, "created_at") }},
		{"future creation", func(m map[string]any) { m["created_at"] = testMachineNow.Add(time.Minute).UnixMilli() }},
		{"future update", func(m map[string]any) { m["updated_at"] = testMachineNow.Add(time.Minute).UnixMilli() }},
		{"update before creation", func(m map[string]any) { m["updated_at"] = testMachineNow.Add(-time.Hour).UnixMilli() }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			response := machineTestResponse()
			tc.edit(response)
			verifier := machineTestVerifier(t, func(w http.ResponseWriter, _ *http.Request) { _ = json.NewEncoder(w).Encode(response) })
			identity, err := verifier.VerifyMachine(context.Background(), testMachineToken)
			if !errors.Is(err, ErrUnauthenticated) || !reflect.DeepEqual(identity, MachineIdentity{}) {
				t.Fatal("invalid response did not fail closed")
			}
		})
	}
}

func TestMachineVerifyExplicitNonExpiringPolicy(t *testing.T) {
	response := machineTestResponse()
	response["expiration"] = nil
	verifier := machineTestVerifier(t, func(w http.ResponseWriter, _ *http.Request) { _ = json.NewEncoder(w).Encode(response) })
	verifier.allowNonExpiring = true
	identity, err := verifier.VerifyMachine(context.Background(), testMachineToken)
	if err != nil || identity.ExpiresAt != nil {
		t.Fatal("explicit non-expiring policy did not preserve Clerk null expiration")
	}
	// A missing expiration must still not be interpreted as intentional null.
	delete(response, "expiration")
	if _, err := verifier.VerifyMachine(context.Background(), testMachineToken); !errors.Is(err, ErrUnauthenticated) {
		t.Fatal("missing expiration accepted under non-expiring policy")
	}
}

func TestMachineVerifyNoSuccessCache(t *testing.T) {
	var calls atomic.Int32
	verifier := machineTestVerifier(t, func(w http.ResponseWriter, _ *http.Request) {
		response := machineTestResponse()
		response["revoked"] = calls.Add(1) > 1
		_ = json.NewEncoder(w).Encode(response)
	})
	if _, err := verifier.VerifyMachine(context.Background(), testMachineToken); err != nil {
		t.Fatal("first active token rejected")
	}
	if _, err := verifier.VerifyMachine(context.Background(), testMachineToken); !errors.Is(err, ErrUnauthenticated) || calls.Load() != 2 {
		t.Fatal("revocation was bypassed by a cached identity")
	}
}

func TestMachineVerifyRejectsOtherFormatsWithoutNetwork(t *testing.T) {
	var calls atomic.Int32
	verifier := machineTestVerifier(t, func(w http.ResponseWriter, _ *http.Request) { calls.Add(1); w.WriteHeader(500) })
	for _, token := range []string{"", "mt_", "ak_apiKey", "oat_accessToken", "header.payload.signature", "mt_header.payload.signature", "Bearer mt_value", "mt_value\n", "mt_含中文", " mt_value", "mt_" + strings.Repeat("x", machineMaxTokenBytes)} {
		if _, err := verifier.VerifyMachine(context.Background(), token); !errors.Is(err, ErrMachineTokenFormatUnsupported) || !errors.Is(err, ErrUnauthenticated) {
			t.Fatal("unsupported token type did not fail before network")
		}
	}
	if calls.Load() != 0 {
		t.Fatal("unsupported credential was transmitted to Clerk")
	}
}

func TestMachineVerifyMalformedResponseAndHTTPFailure(t *testing.T) {
	valid, _ := json.Marshal(machineTestResponse())
	cases := []struct {
		name   string
		status int
		body   string
	}{
		{"empty", 200, ""}, {"HTML", 200, "<html>proxy</html>"}, {"null", 200, "null"},
		{"array", 200, "[]"}, {"truncated", 200, string(valid[:len(valid)-1])},
		{"duplicate subject", 200, `{"subject":"mch_forged",` + string(valid[1:])},
		{"case alias subject", 200, string(valid[:len(valid)-1]) + `,"Subject":"mch_forged"}`},
		{"case alias revoked", 200, string(valid[:len(valid)-1]) + `,"Revoked":false}`},
		{"trailing JSON", 200, string(valid) + `{}`},
		{"oversized", 200, string(valid) + strings.Repeat(" ", machineMaxBodyBytes)},
		{"unauthorized", 401, `{"errors":[{"code":"token_invalid"}]}`},
		{"forbidden HTML", 403, "proxy refused"}, {"not found", 404, "{}"},
		{"rate limit", 429, "{}"}, {"server error", 500, "{}"}, {"unexpected success", 201, string(valid)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			verifier := machineTestVerifier(t, func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = io.WriteString(w, tc.body)
			})
			if identity, err := verifier.VerifyMachine(context.Background(), testMachineToken); !errors.Is(err, ErrUnauthenticated) || !reflect.DeepEqual(identity, MachineIdentity{}) {
				t.Fatal("malformed/error response produced an identity")
			}
		})
	}
}

func TestMachineVerifyRedirectNeverTransmitsCredentials(t *testing.T) {
	for _, status := range []int{301, 302, 303, 307, 308} {
		for _, sameOrigin := range []bool{false, true} {
			t.Run(fmt.Sprintf("status_%d_same_%v", status, sameOrigin), func(t *testing.T) {
				var destinationCalls atomic.Int32
				destination := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
					destinationCalls.Add(1)
					_ = json.NewEncoder(w).Encode(machineTestResponse())
				}))
				defer destination.Close()
				verifier := machineTestVerifier(t, func(w http.ResponseWriter, r *http.Request) {
					if r.URL.Path == "/redirected" {
						destinationCalls.Add(1)
						return
					}
					target := destination.URL + "/redirected"
					if sameOrigin {
						target = "/redirected"
					}
					w.Header().Set("Location", target)
					w.WriteHeader(status)
				})
				if _, err := verifier.VerifyMachine(context.Background(), testMachineToken); !errors.Is(err, ErrUnauthenticated) || destinationCalls.Load() != 0 {
					t.Fatal("redirect followed or accepted")
				}
			})
		}
	}
}

func TestMachineVerifyCancellationAndNetworkFailure(t *testing.T) {
	verifier := machineTestVerifier(t, func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-time.After(time.Second):
		}
	})
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	start := time.Now()
	if _, err := verifier.VerifyMachine(ctx, testMachineToken); !errors.Is(err, ErrUnauthenticated) || time.Since(start) > time.Second {
		t.Fatal("caller cancellation did not stop verification")
	}
	verifier.client.Transport = machineErrorTransport{}
	if _, err := verifier.VerifyMachine(context.Background(), testMachineToken); err != ErrUnauthenticated {
		t.Fatal("transport error was exposed instead of sanitized")
	}
	var zero *ClerkMachine
	if _, err := zero.VerifyMachine(context.Background(), testMachineToken); !errors.Is(err, ErrUnauthenticated) {
		t.Fatal("nil verifier did not fail closed")
	}
}

type machineErrorTransport struct{}

func (machineErrorTransport) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, errors.New("synthetic sensitive transport diagnostic")
}

func TestMachineConfigurationIsServerBound(t *testing.T) {
	for _, issuer := range []string{"", "http://example.com", "https://example.com/", "https://user@example.com", "https://example.com?", "https://example.com?q=x", "https://example.com#x"} {
		config := machineTestConfig()
		config.Issuer = issuer
		if _, err := NewClerkMachine(config); !errors.Is(err, ErrMachineConfiguration) {
			t.Fatal("invalid issuer accepted")
		}
	}
	for _, secret := range []string{"", "sk_test_notMachine", "ak_", "ak_secret\n"} {
		config := machineTestConfig()
		config.MachineSecretKey = secret
		if _, err := NewClerkMachine(config); !errors.Is(err, ErrMachineConfiguration) {
			t.Fatal("non-machine secret accepted")
		}
	}
	for _, target := range []string{"", "*", "user_123", "mch_", "mch_receiver\n"} {
		config := machineTestConfig()
		config.ReceiverMachineID = target
		if _, err := NewClerkMachine(config); !errors.Is(err, ErrMachineConfiguration) {
			t.Fatal("invalid receiver accepted")
		}
	}
	verifier, err := NewClerkMachine(machineTestConfig())
	if err != nil || verifier.endpoint != clerkMachineVerifyEndpoint || verifier.client.Timeout != 8*time.Second {
		t.Fatal("production endpoint or timeout is not fixed")
	}
	if verifier.client.CheckRedirect(nil, nil) != http.ErrUseLastResponse {
		t.Fatal("production redirect guard is missing")
	}
}
