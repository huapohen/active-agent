package documents

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

type fixture struct {
	t                                      *testing.T
	server                                 *httptest.Server
	source                                 Snapshot
	allowed                                bool
	currentBody, currentTitle              string
	creates, updates, reads                int
	failCreate, failUpdate, denyAfterWrite bool
	wrongSpace                             bool
}

func newFixture(t *testing.T) *fixture {
	f := &fixture{t: t, source: Snapshot{ID: "doc-1", Title: "Review", Content: "## Result\n\nOne.", Revision: 1}, allowed: true}
	f.source.ContentHash = Hash(f.source.Content)
	f.server = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.server.Close)
	return f
}
func (f *fixture) serve(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if strings.HasPrefix(r.URL.Path, "/api/im/") {
		if r.Header.Get("Authorization") != "Bearer member-secret" {
			f.t.Error("member auth missing")
		}
		if !f.allowed {
			w.WriteHeader(403)
			return
		}
		if r.URL.Path == "/api/im/me" {
			json.NewEncoder(w).Encode(map[string]any{"principal": map[string]any{"id": "principal-1"}})
			return
		}
		if r.Method != "GET" || r.URL.Path != "/api/im/rooms/room-1/documents/doc-1" {
			f.t.Errorf("unexpected source call %s %s", r.Method, r.URL.Path)
			w.WriteHeader(404)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"document": f.source})
		return
	}
	if r.Header.Get("Cookie") != "authToken=target-secret" {
		f.t.Error("target auth missing")
	}
	var v map[string]any
	json.NewDecoder(r.Body).Decode(&v)
	switch r.URL.Path {
	case "/api/pages/create":
		f.creates++
		if v["spaceId"] != "space-1" {
			f.t.Error("wrong namespace")
		}
		f.currentBody = v["content"].(string)
		f.currentTitle = v["title"].(string)
		if f.failCreate {
			w.WriteHeader(500)
			return
		}
	case "/api/pages/update":
		f.updates++
		if v["pageId"] != "external-1" {
			f.t.Error("wrong target ID")
		}
		f.currentBody = v["content"].(string)
		f.currentTitle = v["title"].(string)
		if f.failUpdate {
			w.WriteHeader(500)
			return
		}
	case "/api/pages/info":
		f.reads++
		if v["pageId"] != "external-1" {
			f.t.Error("wrong read ID")
		}
	default:
		f.t.Errorf("unexpected target call %s", r.URL.Path)
		w.WriteHeader(404)
		return
	}
	if f.denyAfterWrite && f.creates > 0 {
		f.allowed = false
	}
	space := "space-1"
	if f.wrongSpace {
		space = "different-space"
	}
	json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"id": "external-1", "spaceId": space, "title": f.currentTitle, "content": f.currentBody}})
}
func (f *fixture) binding() Binding {
	return Binding{ID: "projection-1", PrincipalID: "principal-1", SourceEndpoint: f.server.URL, RoomID: "room-1", DocumentID: "doc-1", Target: "docmost", TargetEndpoint: f.server.URL, NamespaceID: "space-1", ApprovedBy: "admin-1", ApprovalReference: "test-approval", Generation: 1, Enabled: true, GatewayOnlyNamespace: true}
}
func (f *fixture) engine(j Store) *Engine {
	s, err := NewDocFree(f.server.URL, "member-secret")
	if err != nil {
		f.t.Fatal(err)
	}
	target, err := NewDocmost(f.server.URL, "space-1", "target-secret")
	if err != nil {
		f.t.Fatal(err)
	}
	return &Engine{Source: s, Target: target, Store: j, Guard: func(context.Context, Binding) error { return nil }}
}
func journal(t *testing.T) *FileJournal {
	j, err := OpenFileJournal(filepath.Join(t.TempDir(), "journal.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { j.Close() })
	return j
}
func requireCode(t *testing.T, err error, want string) {
	t.Helper()
	if err == nil || Code(err) != want {
		t.Fatalf("error=%v, want %s", err, want)
	}
}
func TestProjectionRealHTTPCreateReadbackIdempotentAndUpdate(t *testing.T) {
	f := newFixture(t)
	j := journal(t)
	e := f.engine(j)
	ctx := context.Background()
	b := f.binding()
	r, err := e.Sync(ctx, b)
	if err != nil || r.State != "verified" || !r.TitleVerified {
		t.Fatalf("record=%+v err=%v", r, err)
	}
	_, err = e.Sync(ctx, b)
	if err != nil || f.creates != 1 || f.updates != 0 {
		t.Fatalf("duplicate effect: creates=%d updates=%d err=%v", f.creates, f.updates, err)
	}
	f.source.Revision++
	f.source.Content = "## Result\n\nTwo."
	f.source.ContentHash = Hash(f.source.Content)
	r, err = e.Sync(ctx, b)
	if err != nil || r.SourceRevision != 2 || r.State != "verified" || f.updates != 1 {
		t.Fatalf("update=%+v err=%v count=%d", r, err, f.updates)
	}
	raw, _ := os.ReadFile(j.file.Name())
	if strings.Contains(string(raw), "member-secret") || strings.Contains(string(raw), "One.") || strings.Contains(string(raw), "Review") {
		t.Fatal("journal exposed source/credential")
	}
}
func TestProjectionUnknownCreateNeverDuplicatesAfterRestart(t *testing.T) {
	f := newFixture(t)
	f.failCreate = true
	path := filepath.Join(t.TempDir(), "journal.jsonl")
	j, err := OpenFileJournal(path)
	if err != nil {
		t.Fatal(err)
	}
	r, err := f.engine(j).Sync(context.Background(), f.binding())
	if r.State != "unknown" || err == nil {
		t.Fatal(r, err)
	}
	j.Close()
	j, err = OpenFileJournal(path)
	if err != nil {
		t.Fatal(err)
	}
	defer j.Close()
	f.failCreate = false
	_, err = f.engine(j).Sync(context.Background(), f.binding())
	requireCode(t, err, "create_outcome_unknown")
	if f.creates != 1 {
		t.Fatal("duplicated unknown create")
	}
}
func TestProjectionUnknownKnownIDReconcilesWithoutRepeatingWrite(t *testing.T) {
	f := newFixture(t)
	e := f.engine(journal(t))
	ctx := context.Background()
	b := f.binding()
	if _, err := e.Sync(ctx, b); err != nil {
		t.Fatal(err)
	}
	f.source.Revision++
	f.source.Title = "Changed title"
	f.source.Content = "Changed body"
	f.source.ContentHash = Hash(f.source.Content)
	f.failUpdate = true
	r, err := e.Sync(ctx, b)
	if err == nil || r.State != "unknown" {
		t.Fatal(r, err)
	}
	f.failUpdate = false
	r, err = e.Sync(ctx, b)
	if err != nil || r.State != "verified" || f.updates != 1 {
		t.Fatal(r, err, f.updates)
	}
}
func TestProjectionDetectsDownstreamEditInsteadOfOverwriting(t *testing.T) {
	f := newFixture(t)
	e := f.engine(journal(t))
	ctx := context.Background()
	if _, err := e.Sync(ctx, f.binding()); err != nil {
		t.Fatal(err)
	}
	f.currentBody = "Someone else's change"
	f.source.Revision++
	r, err := e.Sync(ctx, f.binding())
	requireCode(t, err, "external_change_detected")
	if r.State != "conflict" || f.updates != 0 {
		t.Fatal(r, f.updates)
	}
	_, err = e.Sync(ctx, f.binding())
	requireCode(t, err, "target_conflict_requires_resolution")
}
func TestProjectionRevocationAtAdmissionAndAfterEffect(t *testing.T) {
	t.Run("admission", func(t *testing.T) {
		f := newFixture(t)
		f.allowed = false
		_, err := f.engine(journal(t)).Sync(context.Background(), f.binding())
		requireCode(t, err, "access_denied")
		if f.creates != 0 {
			t.Fatal("wrote after revoke")
		}
	})
	t.Run("after-effect", func(t *testing.T) {
		f := newFixture(t)
		f.denyAfterWrite = true
		r, err := f.engine(journal(t)).Sync(context.Background(), f.binding())
		requireCode(t, err, "access_denied")
		if r.State != "unknown" || f.creates != 1 {
			t.Fatal(r, f.creates)
		}
	})
}
func TestProjectionRequiresApprovedNamespaceAndBoundIdentity(t *testing.T) {
	for _, which := range []string{"unapproved", "public", "principal", "namespace", "source-endpoint"} {
		t.Run(which, func(t *testing.T) {
			f := newFixture(t)
			b := f.binding()
			switch which {
			case "unapproved":
				b.ApprovedBy = ""
			case "public":
				b.GatewayOnlyNamespace = false
			case "principal":
				b.PrincipalID = "someone-else"
			case "namespace":
				b.NamespaceID = "other"
			case "source-endpoint":
				b.SourceEndpoint = "https://example.com"
			}
			_, err := f.engine(journal(t)).Sync(context.Background(), b)
			if err == nil || f.creates != 0 {
				t.Fatal("scope check allowed write", err, f.creates)
			}
		})
	}
}
func TestProjectionRejectsWrongDocmostSpaceReceipt(t *testing.T) {
	f := newFixture(t)
	f.wrongSpace = true
	r, err := f.engine(journal(t)).Sync(context.Background(), f.binding())
	requireCode(t, err, "target_namespace_mismatch")
	if r.State != "unknown" {
		t.Fatal(r)
	}
}
func TestProjectionApprovalRaceBeforeSendIsRetryable(t *testing.T) {
	f := newFixture(t)
	e := f.engine(journal(t))
	count := 0
	e.Guard = func(context.Context, Binding) error {
		count++
		if count == 3 {
			return Failure("approval_revoked")
		}
		return nil
	}
	r, err := e.Sync(context.Background(), f.binding())
	requireCode(t, err, "approval_revoked")
	if r.State != "not_sent" || f.creates != 0 {
		t.Fatal(r, f.creates)
	}
	e.Guard = func(context.Context, Binding) error { return nil }
	r, err = e.Sync(context.Background(), f.binding())
	if err != nil || r.State != "verified" || f.creates != 1 {
		t.Fatal(r, err, f.creates)
	}
}
func TestProjectionBindingGenerationChangeRequiresReconciliation(t *testing.T) {
	f := newFixture(t)
	e := f.engine(journal(t))
	b := f.binding()
	if _, err := e.Sync(context.Background(), b); err != nil {
		t.Fatal(err)
	}
	b.Generation++
	_, err := e.Sync(context.Background(), b)
	requireCode(t, err, "binding_changed_requires_reconciliation")
	if f.updates != 0 {
		t.Fatal("unexpected write")
	}
}
func TestProjectionStoreSerializesConcurrentEngines(t *testing.T) {
	f := newFixture(t)
	j := journal(t)
	var wg sync.WaitGroup
	errs := make(chan error, 2)
	for range 2 {
		wg.Add(1)
		go func() { defer wg.Done(); _, err := f.engine(j).Sync(context.Background(), f.binding()); errs <- err }()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if f.creates != 1 {
		t.Fatal("concurrent duplicate", f.creates)
	}
}
func TestJournalLockRecoveryAndCorruption(t *testing.T) {
	path := filepath.Join(t.TempDir(), "journal.jsonl")
	j, err := OpenFileJournal(path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = OpenFileJournal(path)
	requireCode(t, err, "journal_in_use")
	r := Record{BindingID: "b", Sequence: 1, State: "prepared"}
	if err = j.Append(r); err != nil {
		t.Fatal(err)
	}
	j.Close()
	j, err = OpenFileJournal(path)
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := j.Latest("b"); got.State != "prepared" {
		t.Fatal(got)
	}
	j.Close()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString("{partial")
	f.Close()
	_, err = OpenFileJournal(path)
	requireCode(t, err, "journal_corrupt")
}
func TestHTTPDoesNotFollowCredentialRedirect(t *testing.T) {
	reached := false
	end := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { reached = true }))
	defer end.Close()
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, end.URL, http.StatusTemporaryRedirect)
	}))
	defer origin.Close()
	h, err := NewHTTP(origin.URL, http.Header{"Authorization": {"Bearer secret"}})
	if err != nil {
		t.Fatal(err)
	}
	err = h.JSON(context.Background(), "GET", "/", nil, new(any))
	requireCode(t, err, "provider_http_failure")
	if reached {
		t.Fatal("redirect followed")
	}
}
func TestSourceHashMismatchNeverWrites(t *testing.T) {
	f := newFixture(t)
	f.source.ContentHash = "invalid"
	_, err := f.engine(journal(t)).Sync(context.Background(), f.binding())
	requireCode(t, err, "invalid_source_snapshot")
	if f.creates != 0 {
		t.Fatal("unverified source copied")
	}
}
func TestFailureCodeNeverIncludesProviderMessage(t *testing.T) {
	if Code(errors.New("secret plaintext")) != "adapter_unavailable" {
		t.Fatal("unbounded error exposed")
	}
}
