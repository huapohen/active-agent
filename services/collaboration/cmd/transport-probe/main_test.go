package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
	"github.com/huapohen/active-agent/services/collaboration/internal/transport"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestManifestPreparedBeforeSideEffectsAndReused(t *testing.T) {
	path := filepath.Join(t.TempDir(), "manifest.json")
	f, err := loadOrPrepare(path, "db", "provider", true)
	if err != nil {
		t.Fatal(err)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0600 {
		t.Fatal("manifest permissions")
	}
	again, err := loadOrPrepare(path, "db", "provider", true)
	if err != nil || again.RunID != f.RunID || again.Messages[0].ActionID != f.Messages[0].ActionID || again.Principals[0].ID != f.Principals[0].ID {
		t.Fatal("restart generated new fixture")
	}
	if _, err = loadOrPrepare(path, "other-db", "provider", true); err == nil {
		t.Fatal("database binding changed")
	}
	if _, err = loadOrPrepare(path, "db", "other-provider", true); err == nil {
		t.Fatal("provider binding changed")
	}
	if err = os.WriteFile(path, []byte("{truncated"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = loadOrPrepare(path, "db", "provider", true); err == nil {
		t.Fatal("corrupt manifest replaced")
	}
}

func TestJournalNeverRetriesStartedOrCompletedOperation(t *testing.T) {
	for _, finished := range []bool{false, true} {
		path := filepath.Join(t.TempDir(), "observations.jsonl")
		j, err := openJournal(path)
		if err != nil {
			t.Fatal(err)
		}
		if err = j.begin("message/synthetic"); err != nil {
			t.Fatal(err)
		}
		if finished {
			if err = j.finish("message/synthetic", nil, nil); err != nil {
				t.Fatal(err)
			}
		}
		j.file.Close()
		j, err = openJournal(path)
		if err != nil {
			t.Fatal(err)
		}
		if err = j.begin("message/synthetic"); !errors.Is(err, errReconcile) {
			t.Fatal("operation repeated after restart")
		}
		j.file.Close()
	}
}

type probeRecorder struct{ calls int }

func (p *probeRecorder) Session(context.Context, domain.Principal) (transport.Session, error) {
	p.calls++
	return transport.Session{}, nil
}
func (p *probeRecorder) CreateGroup(context.Context, domain.Room, []string) error {
	p.calls++
	return nil
}
func (p *probeRecorder) Publish(context.Context, domain.Message) (transport.Delivery, error) {
	p.calls++
	return transport.Delivery{}, nil
}

func TestMessengerRejectsEverythingOutsideExactFixture(t *testing.T) {
	dir := t.TempDir()
	f, err := loadOrPrepare(filepath.Join(dir, "manifest.json"), "db", "provider", true)
	if err != nil {
		t.Fatal(err)
	}
	r := domain.Room{ID: uuid.NewString(), WorkspaceID: uuid.NewString(), Title: f.RoomTitle, Kind: "group", Version: 1, ScopeEpoch: 1}
	f.Room = &r
	m := domain.Message{ID: uuid.NewString(), RoomID: r.ID, AuthorID: f.Principals[0].ID, Content: f.Messages[0].Content, Seq: 1, CreatedAt: time.Now()}
	f.Messages[0].Receipt = &domain.Receipt{Message: m}
	j, err := openJournal(filepath.Join(dir, "observations.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer j.file.Close()
	p := &probeRecorder{}
	scoped := &scopedMessenger{provider: p, fixture: f, journal: j}
	ctx := context.Background()
	other := f.Principals[0]
	other.ID = uuid.NewString()
	if _, err = scoped.Session(ctx, other); !errors.Is(err, errScope) {
		t.Fatal("unrelated principal accepted")
	}
	other = f.Principals[0]
	other.DisplayName = "real person"
	if _, err = scoped.Session(ctx, other); !errors.Is(err, errScope) {
		t.Fatal("changed identity accepted")
	}
	members := []string{f.Principals[0].ID, f.Principals[1].ID, uuid.NewString()}
	if err = scoped.CreateGroup(ctx, r, members); !errors.Is(err, errScope) {
		t.Fatal("unrelated member accepted")
	}
	changed := r
	changed.ID = uuid.NewString()
	if err = scoped.CreateGroup(ctx, changed, members); !errors.Is(err, errScope) {
		t.Fatal("unrelated room accepted")
	}
	bad := m
	bad.Content = "real communications"
	if _, err = scoped.Publish(ctx, bad); !errors.Is(err, errScope) {
		t.Fatal("changed message accepted")
	}
	bad = m
	bad.AuthorID = uuid.NewString()
	if _, err = scoped.Publish(ctx, bad); !errors.Is(err, errScope) {
		t.Fatal("changed author accepted")
	}
	if p.calls != 0 {
		t.Fatal("out-of-scope provider calls made")
	}
	// Store serializes events to JSON; equivalent times must survive that path.
	b, _ := json.Marshal(m)
	var roundTrip domain.Message
	_ = json.Unmarshal(b, &roundTrip)
	if _, err = scoped.Publish(ctx, roundTrip); err != nil || p.calls != 1 {
		t.Fatal("exact JSON round-trip message rejected")
	}
	if _, err = scoped.Publish(ctx, roundTrip); !errors.Is(err, errReconcile) || p.calls != 1 {
		t.Fatal("duplicate provider publish")
	}
}

func TestKnownAndUnknownProviderErrorsArePreservedWithoutToken(t *testing.T) {
	path := filepath.Join(t.TempDir(), "observations.jsonl")
	j, err := openJournal(path)
	if err != nil {
		t.Fatal(err)
	}
	if err = j.begin("group/synthetic"); err != nil {
		t.Fatal(err)
	}
	if err = j.finish("group/synthetic", &transport.ProviderError{Code: 1002, Unknown: false}, nil); err != nil {
		t.Fatal(err)
	}
	j.file.Close()
	b, _ := os.ReadFile(path)
	var records []observation
	for _, line := range bytesLines(b) {
		var o observation
		if json.Unmarshal(line, &o) != nil {
			t.Fatal("bad journal")
		}
		records = append(records, o)
	}
	if len(records) != 2 || records[1].Code != 1002 || records[1].Unknown {
		t.Fatal("provider code lost")
	}
}

func bytesLines(b []byte) [][]byte {
	var out [][]byte
	start := 0
	for i, c := range b {
		if c == '\n' {
			if i > start {
				out = append(out, b[start:i])
			}
			start = i + 1
		}
	}
	return out
}

func TestProbePostgresSeedReplayAndUnrelatedPendingGuard(t *testing.T) {
	dsn := os.Getenv("RENJI_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set RENJI_TEST_DATABASE_URL for isolated PostgreSQL probe regression")
	}
	ctx := context.Background()
	admin, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal("test database unavailable")
	}
	schema := "probe_test_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	if _, err = admin.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		admin.Close(ctx)
		t.Fatal("test schema unavailable")
	}
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal("test database configuration")
	}
	config.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		t.Fatal("test pool unavailable")
	}
	s := &store.Store{Pool: pool}
	t.Cleanup(func() { s.Close(); _, _ = admin.Exec(ctx, "DROP SCHEMA "+schema+" CASCADE"); _ = admin.Close(ctx) })
	if s.Migrate(ctx) != nil {
		t.Fatal("isolated migration failed")
	}
	path := filepath.Join(t.TempDir(), "manifest.json")
	f, err := loadOrPrepare(path, "db", "provider", true)
	if err != nil {
		t.Fatal(err)
	}
	if exclusivePending(ctx, s, f) != nil {
		t.Fatal("empty fixture schema rejected")
	}
	if seed(ctx, s, f, path) != nil {
		t.Fatal("initial seed failed")
	}
	firstRoom := f.Room.ID
	firstMessage := f.Messages[0].Receipt.Message.ID
	reloaded, err := loadOrPrepare(path, "db", "provider", true)
	if err != nil {
		t.Fatal(err)
	}
	if seed(ctx, s, reloaded, path) != nil {
		t.Fatal("same action replay failed")
	}
	if reloaded.Room.ID != firstRoom || reloaded.Messages[0].Receipt.Message.ID != firstMessage {
		t.Fatal("replay duplicated business objects")
	}
	var principals, rooms, messages, outbox int
	if pool.QueryRow(ctx, "SELECT (SELECT count(*) FROM principals),(SELECT count(*) FROM rooms),(SELECT count(*) FROM messages),(SELECT count(*) FROM transport_outbox)").Scan(&principals, &rooms, &messages, &outbox) != nil || principals != 3 || rooms != 1 || messages != 3 || outbox != 4 {
		t.Fatal("fixture created unexpected number of records")
	}
	if exclusivePending(ctx, s, reloaded) != nil {
		t.Fatal("fixture-only pending rejected")
	}
	otherRoom, err := s.CreateRoom(ctx, f.Principals[0].ID, "synthetic-unrelated-room-guard", f.WorkspaceID, "独立测试非fixture群", nil)
	if err != nil {
		t.Fatal("guard fixture failed")
	}
	if err = exclusivePending(ctx, s, reloaded); err == nil || err.Error() != "non_fixture_pending_exists_no_dispatch" {
		t.Fatal("unrelated pending not rejected before claim")
	}
	var state string
	var attempts int
	if pool.QueryRow(ctx, "SELECT o.status,o.attempts FROM transport_outbox o JOIN events e ON e.id=o.event_id WHERE e.room_id=$1", otherRoom.ID).Scan(&state, &attempts) != nil || state != "pending" || attempts != 0 {
		t.Fatal("guard mutated unrelated outbox")
	}
}
