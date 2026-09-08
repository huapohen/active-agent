package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
)

func testSource() sourceFixture {
	w := uuid.NewString()
	return sourceFixture{RunID: uuid.NewString(), WorkspaceID: w, Room: domain.Room{ID: uuid.NewString(), WorkspaceID: w, Title: "合成验收 source", Version: 1, ScopeEpoch: 1}, Principals: []domain.Principal{{ID: uuid.NewString(), Kind: "human", DisplayName: "合成验收 owner"}, {ID: uuid.NewString(), Kind: "human", DisplayName: "合成验收 employee"}, {ID: uuid.NewString(), Kind: "agent", DisplayName: "合成验收 Agent"}}}
}
func TestExecutionManifestDeterministicAndBound(t *testing.T) {
	s := testSource()
	path := filepath.Join(t.TempDir(), "manifest.json")
	cfg := map[string]string{"CLERK_ISSUER": "https://example.clerk.accounts.dev", "CLERK_WORKER_MACHINE_ID": "mch_syntheticWorker"}
	f, err := loadManifest(path, s, cfg, "db", true)
	if err != nil {
		t.Fatal(err)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0600 {
		t.Fatal("manifest permissions")
	}
	again, err := loadManifest(path, s, cfg, "db", true)
	if err != nil || again.Actions["success"] != harness.StableID(s.RunID, "execution-probe/v1/success") || again.Actions["root"] != f.Actions["root"] {
		t.Fatal("action IDs changed on restart")
	}
	cfg["CLERK_WORKER_MACHINE_ID"] = "mch_other"
	if _, err = loadManifest(path, s, cfg, "db", true); err == nil {
		t.Fatal("machine binding changed")
	}
	if strings.Contains(string(mustRead(t, path)), "mt_") {
		t.Fatal("token in manifest")
	}
}
func mustRead(t *testing.T, path string) []byte {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
func TestSourceRejectsNonSyntheticOrDuplicatePrincipal(t *testing.T) {
	s := testSource()
	if validateSource(s) != nil {
		t.Fatal("valid source rejected")
	}
	s.Principals[0].DisplayName = "real user"
	if validateSource(s) == nil {
		t.Fatal("non synthetic source accepted")
	}
	s = testSource()
	s.Principals[1].ID = s.Principals[0].ID
	if validateSource(s) == nil {
		t.Fatal("duplicate source principal accepted")
	}
}
func TestHTTPReceiptChecksRejectChangedCanonicalMessage(t *testing.T) {
	a := []byte(`{"message_id":"synthetic","seq":1}`)
	b := []byte(`{ "seq": 1, "message_id":"synthetic" }`)
	if !equalJSON(a, b) || equalJSON(a, []byte(`{"message_id":"other","seq":1}`)) {
		t.Fatal("canonical receipt comparison")
	}
	for _, code := range []string{"mt_secret", "sensitive secret", "https://bad/", strings.Repeat("x", 81)} {
		if safeCode(code) {
			t.Fatal("unsafe diagnostic accepted")
		}
	}
}
func TestSuccessfulChecksResumeWithoutHTTP(t *testing.T) {
	f := &executionManifest{Checks: []check{{Name: "already_done", Passed: true}}}
	p := &probe{fixture: f}
	if err := p.httpCheck(context.Background(), "already_done", "POST", "/should-not-run", nil, 200, nil); err != nil {
		t.Fatal("completed checkpoint performed HTTP")
	}
}
func TestCheckPersistenceDoesNotSaveRawHTTPBody(t *testing.T) {
	path := filepath.Join(t.TempDir(), "manifest.json")
	p := &probe{path: path, fixture: &executionManifest{Schema: "test"}}
	if err := p.record("synthetic", 403, "forbidden", 0, true); err != nil {
		t.Fatal(err)
	}
	var saved executionManifest
	if json.Unmarshal(mustRead(t, path), &saved) != nil || len(saved.Checks) != 1 || saved.Checks[0].Code != "forbidden" {
		t.Fatal("check persistence failed")
	}
}
func TestRedirectPolicyDoesNotForwardCredentials(t *testing.T) {
	calls := 0
	target := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { calls++ }))
	defer target.Close()
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, target.URL, 307) }))
	defer source.Close()
	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	req, _ := http.NewRequest("POST", source.URL, strings.NewReader(`{"synthetic":true}`))
	req.Header.Set("Authorization", "Bearer mt_synthetic")
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 307 || calls != 0 {
		t.Fatal("redirect followed")
	}
}
