package runarchive

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/auth"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
	"github.com/jackc/pgx/v5"
	"github.com/stretchr/testify/require"
)

const testIssuer = "https://synthetic-archive.invalid"
const testSubject = "mch_archive_worker"

type verifierFunc func(context.Context, string) (auth.MachineIdentity, error)

func (f verifierFunc) VerifyMachine(ctx context.Context, token string) (auth.MachineIdentity, error) {
	return f(ctx, token)
}
func validVerifier(_ context.Context, token string) (auth.MachineIdentity, error) {
	if token != "mt_synthetic" {
		return auth.MachineIdentity{}, auth.ErrUnauthenticated
	}
	expires := time.Now().Add(time.Hour)
	return auth.MachineIdentity{Issuer: testIssuer, MachineSubject: testSubject, Audience: "mch_receiver", ExpiresAt: &expires}, nil
}

type fixture struct {
	s                       *store.Store
	owner, agent, workspace string
	room                    domain.Room
	run                     store.ExecutionRun
	config                  Config
}

func newFixture(t *testing.T, endpoint string) fixture {
	t.Helper()
	dsn := os.Getenv("RENJI_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set RENJI_TEST_DATABASE_URL for isolated real PostgreSQL integration")
	}
	ctx := context.Background()
	admin, err := pgx.Connect(ctx, dsn)
	require.NoError(t, err)
	schema := "archive_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	_, err = admin.Exec(ctx, "CREATE SCHEMA "+schema)
	require.NoError(t, err)
	u, err := url.Parse(dsn)
	require.NoError(t, err)
	q := u.Query()
	q.Set("search_path", schema)
	u.RawQuery = q.Encode()
	s, err := store.Open(ctx, u.String())
	require.NoError(t, err)
	t.Cleanup(func() { s.Close(); admin.Exec(ctx, "DROP SCHEMA "+schema+" CASCADE"); admin.Close(ctx) })
	require.NoError(t, s.Migrate(ctx))
	f := fixture{s: s, owner: uuid.NewString(), agent: uuid.NewString()}
	_, err = s.Pool.Exec(ctx, "INSERT INTO principals(id,kind,display_name) VALUES($1,'human','合成人'),($2,'agent','合成Agent')", f.owner, f.agent)
	require.NoError(t, err)
	f.workspace, err = s.CreateWorkspace(ctx, f.owner, "archive-workspace", "隔离归档测试")
	require.NoError(t, err)
	_, err = s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", f.workspace, f.agent)
	require.NoError(t, err)
	f.room, err = s.CreateRoom(ctx, f.owner, "archive-source", f.workspace, "合成来源", []string{f.agent})
	require.NoError(t, err)
	b, err := s.RegisterExecutor(ctx, f.owner, store.RegisterExecutorCommand{ActionID: "archive-binding", WorkspaceID: f.workspace, AgentPrincipalID: f.agent, Issuer: testIssuer, MachineSubject: testSubject, Enabled: true})
	require.NoError(t, err)
	_, err = s.SetAgentExecutionPolicy(ctx, f.owner, store.AgentExecutionPolicyCommand{ActionID: "archive-active", WorkspaceID: f.workspace, AgentPrincipalID: f.agent, ExpectedVersion: 1, ProactiveEnabled: true})
	require.NoError(t, err)
	f.run, err = s.CreateExecutionRun(ctx, f.agent, store.CreateExecutionRunCommand{ActionID: "archive-run", ExecutorID: b.ExecutorID, RoomID: f.room.ID, ScopeEpoch: f.room.ScopeEpoch, Goal: "合成失败事实归档，不运行模型"})
	require.NoError(t, err)
	require.NoError(t, s.AppendExecutionEvent(ctx, testIssuer, testSubject, f.run.Context, harness.Event{ID: harness.StableID(f.run.Context.RunID, "model"), Type: "model.output", Data: json.RawMessage(`{"content":"这是模型报告，不是消息已经发送的证据。中文\\n` + "```" + `"}`)}))
	require.NoError(t, s.AppendExecutionEvent(ctx, testIssuer, testSubject, f.run.Context, harness.Event{ID: harness.StableID(f.run.Context.RunID, "failed"), Type: "run.failed", Data: json.RawMessage(`{"code":"synthetic_failure","actions":0}`)}))
	f.config = Config{Schema: "renji.run-archive.v1", Enabled: true, Mode: "single_source_synthetic", DatabaseURLEnv: "RENJI_DATABASE_URL", Clerk: ClerkConfig{Issuer: testIssuer, ReceiverMachineID: "mch_receiver", MachineSecretEnv: "CLERK_RECEIVER_SECRET", TokenEnv: "RENJI_EXECUTOR_TOKEN"}, Targets: []TargetConfig{{BindingID: "synthetic-archive-v1", ApprovedBy: "synthetic-owner", ApprovalReference: "isolated-test", WorkspaceID: f.workspace, SourceRoomID: f.room.ID, DocFreeEndpoint: endpoint, DocFreeRoomID: "room-test", DocFreePrincipalID: "principal-agent", DocFreeTokenEnv: "DOC_FREE_TOKEN", PrincipalMappings: []PrincipalMapping{{GoPrincipalID: f.owner, DocFreePrincipalID: "principal-human"}, {GoPrincipalID: f.agent, DocFreePrincipalID: "principal-agent"}}}}}
	return f
}
func (f fixture) runner(t *testing.T) *Runner {
	t.Helper()
	r, err := New(f.config, f.s, verifierFunc(validVerifier), func(k string) string {
		if k == "RENJI_EXECUTOR_TOKEN" {
			return "mt_synthetic"
		}
		if k == "DOC_FREE_TOKEN" {
			return "doc-test-secret"
		}
		return ""
	})
	require.NoError(t, err)
	return r
}
func (f fixture) read(t *testing.T, id string) store.ExecutionArchive {
	t.Helper()
	a, e := f.s.ReadExecutionArchive(context.Background(), store.EvidenceReader{MachineIssuer: testIssuer, MachineSubject: testSubject}, id)
	require.NoError(t, e)
	return a
}

type fakeDocFree struct {
	mu          sync.Mutex
	documents   map[string]doc
	posts, gets int
	mode        string
	outsider    bool
	beforePost  func()
	afterRoom   func()
}

func newDocFree(t *testing.T) (*fakeDocFree, *httptest.Server) {
	t.Helper()
	f := &fakeDocFree{documents: map[string]doc{}}
	s := httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(s.Close)
	return f, s
}
func (f *fakeDocFree) counts() (int, int) { f.mu.Lock(); defer f.mu.Unlock(); return f.posts, f.gets }
func (f *fakeDocFree) serve(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Authorization") != "Bearer doc-test-secret" {
		w.WriteHeader(401)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if r.Method == "GET" && r.URL.Path == "/api/im/me" {
		json.NewEncoder(w).Encode(map[string]any{"principal": map[string]string{"id": "principal-agent", "kind": "agent"}})
		return
	}
	if r.Method == "GET" && r.URL.Path == "/api/im/rooms/room-test" {
		f.mu.Lock()
		outsider, hook := f.outsider, f.afterRoom
		f.mu.Unlock()
		members := []map[string]string{{"principal_id": "principal-agent", "kind": "agent"}, {"principal_id": "principal-human", "kind": "human"}}
		if outsider {
			members = append(members, map[string]string{"principal_id": "unmapped", "kind": "human"})
		}
		json.NewEncoder(w).Encode(map[string]any{"room": map[string]string{"id": "room-test"}, "members": members})
		if hook != nil {
			hook()
		}
		return
	}
	if r.Method == "POST" && r.URL.Path == "/api/im/rooms/room-test/documents" {
		f.mu.Lock()
		hook := f.beforePost
		f.mu.Unlock()
		if hook != nil {
			hook()
		}
		var p struct{ Title, Content string }
		if json.NewDecoder(r.Body).Decode(&p) != nil {
			w.WriteHeader(400)
			return
		}
		f.mu.Lock()
		f.posts++
		id := "doc-" + uuid.NewString()
		d := doc{ID: id, Title: p.Title, Content: &p.Content, Revision: 1, ContentHash: Hash([]byte(p.Content))}
		f.documents[id] = d
		mode := f.mode
		f.mu.Unlock()
		if mode == "lost-response" {
			c, _, e := w.(http.Hijacker).Hijack()
			if e == nil {
				c.Close()
			}
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"document": map[string]string{"id": id}})
		return
	}
	if r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/api/im/rooms/room-test/documents/") {
		id := strings.TrimPrefix(r.URL.Path, "/api/im/rooms/room-test/documents/")
		f.mu.Lock()
		f.gets++
		readNumber := f.gets
		d, ok := f.documents[id]
		mode := f.mode
		f.mu.Unlock()
		if !ok {
			w.WriteHeader(404)
			return
		}
		if mode == "read-fails-once" && readNumber == 1 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		if mode == "body-mismatch" {
			v := *d.Content + "changed"
			d.Content = &v
			d.ContentHash = Hash([]byte(v))
		}
		if mode == "forged-hash" {
			v := *d.Content + "changed"
			d.Content = &v
		}
		if mode == "title-mismatch" {
			d.Title += "changed"
		}
		json.NewEncoder(w).Encode(map[string]any{"document": d})
		return
	}
	w.WriteHeader(404)
}

func TestRunArchiveExactReadbackAndRepeatNeverCreatesAgain(t *testing.T) {
	d, s := newDocFree(t)
	f := newFixture(t, s.URL)
	r := f.runner(t)
	ctx := context.Background()
	// Historical audit remains readable after stop; this never executes an action.
	_, e := f.s.SetStopped(ctx, f.owner, f.room.ID, "stop-before-archive", f.room.Version, true)
	require.NoError(t, e)
	a, e := r.Run(ctx, f.run.Context.RunID)
	require.NoError(t, e)
	require.Equal(t, "verified", a.Status)
	require.Len(t, a.Archive.Parts, 1)
	require.Equal(t, a.Archive.Through, a.Archive.VerifiedThrough)
	b, e := r.Run(ctx, f.run.Context.RunID)
	require.NoError(t, e)
	require.Equal(t, a.Archive.ID, b.Archive.ID)
	require.Equal(t, a.Archive.Parts[0].ExternalID, b.Archive.Parts[0].ExternalID)
	posts, gets := d.counts()
	require.Equal(t, 1, posts)
	require.Equal(t, 2, gets)
	d.mu.Lock()
	for _, v := range d.documents {
		require.False(t, strings.HasSuffix(*v.Content, "\n"))
		require.Contains(t, *v.Content, "failed")
		require.Contains(t, *v.Content, "这是模型报告")
		require.Equal(t, Hash([]byte(*v.Content)), v.ContentHash)
	}
	d.mu.Unlock()
}
func TestRunArchiveUnknownOutcomesAreNotRetriedAsCreates(t *testing.T) {
	for _, mode := range []string{"lost-response", "body-mismatch", "title-mismatch", "forged-hash"} {
		t.Run(mode, func(t *testing.T) {
			d, s := newDocFree(t)
			d.mode = mode
			f := newFixture(t, s.URL)
			r := f.runner(t)
			ctx := context.Background()
			a, e := r.Run(ctx, f.run.Context.RunID)
			require.Error(t, e)
			stored := f.read(t, a.Archive.ID)
			require.Equal(t, "unknown", stored.Parts[0].State)
			require.Equal(t, int64(-1), stored.VerifiedThrough)
			_, e = r.Run(ctx, f.run.Context.RunID)
			require.Error(t, e)
			posts, _ := d.counts()
			require.Equal(t, 1, posts)
			d.mu.Lock()
			d.mode = ""
			d.mu.Unlock()
			b, e := r.Run(ctx, f.run.Context.RunID)
			if mode == "lost-response" {
				require.Error(t, e)
				require.Equal(t, "create_outcome_unknown", Code(e))
				require.Empty(t, stored.Parts[0].ExternalID)
			} else {
				require.NoError(t, e)
				require.Equal(t, "verified", b.Status)
				require.Equal(t, a.Archive.ID, b.Archive.ID)
			}
			posts, _ = d.counts()
			require.Equal(t, 1, posts)
		})
	}
}
func TestRunArchiveRejectsSourceAndMachineAndAudienceBoundariesBeforeCreate(t *testing.T) {
	for _, mode := range []string{"multi-source", "unmapped-room", "revoke-agent", "revoke-human-audience", "disabled-executor", "wrong-subject", "wrong-audience", "non-expiring", "target-outsider", "writer-mismatch"} {
		t.Run(mode, func(t *testing.T) {
			d, s := newDocFree(t)
			f := newFixture(t, s.URL)
			ctx := context.Background()
			runID := f.run.Context.RunID
			switch mode {
			case "multi-source":
				room, e := f.s.CreateRoom(ctx, f.owner, "other-room", f.workspace, "第二来源", []string{f.agent})
				require.NoError(t, e)
				// Create the parent while active; the first fixture run is terminal.
				parent, e := f.s.CreateExecutionRun(ctx, f.agent, store.CreateExecutionRunCommand{ActionID: "new-parent", ExecutorID: f.run.Context.ExecutorID, RoomID: f.room.ID, ScopeEpoch: f.room.ScopeEpoch, Goal: "parent"})
				require.NoError(t, e)
				child, e := f.s.CreateExecutionRun(ctx, f.agent, store.CreateExecutionRunCommand{ActionID: "child-run-test", ExecutorID: f.run.Context.ExecutorID, RoomID: room.ID, ScopeEpoch: room.ScopeEpoch, ParentRunID: parent.Context.RunID, Goal: "child"})
				require.NoError(t, e)
				runID = child.Context.RunID
			case "unmapped-room":
				f.config.Targets[0].SourceRoomID = uuid.NewString()
			case "revoke-agent":
				_, e := f.s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", f.room.ID, f.agent)
				require.NoError(t, e)
			case "revoke-human-audience":
				_, e := f.s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", f.room.ID, f.owner)
				require.NoError(t, e)
			case "disabled-executor":
				_, e := f.s.Pool.Exec(ctx, "UPDATE executors SET enabled=false WHERE id=$1", f.run.Context.ExecutorID)
				require.NoError(t, e)
			case "target-outsider":
				d.outsider = true
			case "writer-mismatch":
				f.config.Targets[0].PrincipalMappings[0].DocFreePrincipalID = "principal-agent"
				f.config.Targets[0].PrincipalMappings[1].DocFreePrincipalID = "principal-human"
			}
			r := f.runner(t)
			if mode == "wrong-subject" || mode == "wrong-audience" || mode == "non-expiring" {
				r.verifier = verifierFunc(func(c context.Context, s string) (auth.MachineIdentity, error) {
					m, e := validVerifier(c, s)
					if mode == "wrong-subject" {
						m.MachineSubject = "mch_forged"
					}
					if mode == "wrong-audience" {
						m.Audience = "mch_other"
					}
					if mode == "non-expiring" {
						m.ExpiresAt = nil
					}
					return m, e
				})
			}
			_, e := r.Run(ctx, runID)
			require.Error(t, e)
			posts, _ := d.counts()
			require.Zero(t, posts)
		})
	}
}
func TestRunArchiveBindingConfigurationCannotDrift(t *testing.T) {
	d, s := newDocFree(t)
	f := newFixture(t, s.URL)
	ctx := context.Background()
	a, e := f.runner(t).Run(ctx, f.run.Context.RunID)
	require.NoError(t, e)
	f.config.Targets[0].ApprovalReference = "changed-deployment"
	_, e = f.runner(t).Run(ctx, f.run.Context.RunID)
	require.ErrorIs(t, e, domain.ErrConflict)
	posts, _ := d.counts()
	require.Equal(t, 1, posts)
	require.Equal(t, "verified", f.read(t, a.Archive.ID).Parts[0].State)
}
func TestRunArchiveChecksAuthenticationAgainImmediatelyBeforeWrite(t *testing.T) {
	d, s := newDocFree(t)
	f := newFixture(t, s.URL)
	r := f.runner(t)
	var calls atomic.Int32
	// Calls 1=start, 2/3=initial preflight, 4/5=part preflight, 6=POST guard.
	r.verifier = verifierFunc(func(c context.Context, s string) (auth.MachineIdentity, error) {
		if calls.Add(1) >= 6 {
			return auth.MachineIdentity{}, auth.ErrUnauthenticated
		}
		return validVerifier(c, s)
	})
	_, e := r.Run(context.Background(), f.run.Context.RunID)
	require.Error(t, e)
	require.Equal(t, "machine_authentication_failed", Code(e))
	posts, _ := d.counts()
	require.Zero(t, posts)
}
func TestRunArchiveSourceAudienceLockProtectsInFlightExternalWrite(t *testing.T) {
	d, s := newDocFree(t)
	f := newFixture(t, s.URL)
	r := f.runner(t)
	entered, release := make(chan struct{}), make(chan struct{})
	d.beforePost = func() { close(entered); <-release }
	done := make(chan error, 1)
	go func() { _, e := r.Run(context.Background(), f.run.Context.RunID); done <- e }()
	select {
	case <-entered:
	case <-time.After(10 * time.Second):
		t.Fatal("POST did not start")
	}
	revokeCtx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	tx, e := f.s.Pool.Begin(context.Background())
	require.NoError(t, e)
	_, e = tx.Exec(revokeCtx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", f.room.ID, f.owner)
	cancel()
	tx.Rollback(context.Background())
	require.Error(t, e)
	close(release)
	require.NoError(t, <-done)
	posts, _ := d.counts()
	require.Equal(t, 1, posts)
	_, e = f.s.Pool.Exec(context.Background(), "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", f.room.ID, f.owner)
	require.NoError(t, e)
	_, e = r.Run(context.Background(), f.run.Context.RunID)
	require.Error(t, e)
	posts, _ = d.counts()
	require.Equal(t, 1, posts)
}
func TestRunArchiveConcurrentInvocationsHaveOneExternalCreate(t *testing.T) {
	d, s := newDocFree(t)
	f := newFixture(t, s.URL)
	var wg sync.WaitGroup
	results := make(chan error, 6)
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, e := f.runner(t).Run(context.Background(), f.run.Context.RunID)
			results <- e
		}()
	}
	wg.Wait()
	close(results)
	for e := range results {
		if e != nil {
			require.True(t, errors.Is(e, domain.ErrConflict), "unexpected bounded error: %v", e)
		}
	}
	a, e := f.runner(t).Run(context.Background(), f.run.Context.RunID)
	require.NoError(t, e)
	require.Equal(t, "verified", a.Status)
	posts, _ := d.counts()
	require.Equal(t, 1, posts)
}
func TestDocClientRejectsRedirectWithoutLeakingCredential(t *testing.T) {
	var received atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { received.Add(1) }))
	defer target.Close()
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL, http.StatusTemporaryRedirect)
	}))
	defer redirect.Close()
	d, e := newDocClient(TargetConfig{DocFreeEndpoint: redirect.URL}, "private-test-token")
	require.NoError(t, e)
	for _, method := range []string{"GET", "POST"} {
		var result any
		e = d.call(context.Background(), method, "/fixed", map[string]string{"content": "test"}, &result)
		require.Error(t, e)
	}
	require.Zero(t, received.Load())
}
