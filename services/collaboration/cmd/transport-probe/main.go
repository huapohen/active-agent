// transport-probe performs one resumable, bounded synthetic RongCloud delivery
// exercise. It never drains unrelated outbox work or retries uncertain calls.
package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
	"github.com/huapohen/active-agent/services/collaboration/internal/transport"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type fixtureMessage struct {
	ActionID string          `json:"action_id"`
	AuthorID string          `json:"author_id"`
	Content  string          `json:"content"`
	Receipt  *domain.Receipt `json:"receipt,omitempty"`
}

type manifest struct {
	Schema          string             `json:"schema"`
	RunID           string             `json:"run_id"`
	CreatedAt       time.Time          `json:"created_at"`
	DatabaseBinding string             `json:"database_binding"`
	ProviderBinding string             `json:"provider_binding"`
	Principals      []domain.Principal `json:"principals"`
	WorkspaceAction string             `json:"workspace_action"`
	WorkspaceTitle  string             `json:"workspace_title"`
	WorkspaceID     string             `json:"workspace_id,omitempty"`
	RoomAction      string             `json:"room_action"`
	RoomTitle       string             `json:"room_title"`
	Room            *domain.Room       `json:"room,omitempty"`
	Messages        []fixtureMessage   `json:"messages"`
}

type observation struct {
	At        time.Time           `json:"at"`
	Operation string              `json:"operation"`
	State     string              `json:"state"`
	Code      int                 `json:"code,omitempty"`
	Unknown   bool                `json:"unknown,omitempty"`
	Delivery  *transport.Delivery `json:"delivery,omitempty"`
}

type journal struct {
	file *os.File
	seen map[string]bool
}

type scopedMessenger struct {
	provider store.Messenger
	fixture  *manifest
	journal  *journal
}

var errScope = errors.New("synthetic fixture scope rejected")
var errReconcile = errors.New("previous attempt requires reconciliation; not resent")

func main() {
	dir := flag.String("env-dir", "", "ignored startup data directory containing api.env and rongcloud.env")
	mode := flag.String("mode", "inspect", "prepare, initialize-empty, execute, or inspect")
	flag.Parse()
	if *dir == "" || (*mode != "prepare" && *mode != "initialize-empty" && *mode != "execute" && *mode != "inspect") {
		fail("arguments_invalid")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	if err := run(ctx, *dir, *mode); err != nil {
		// All returned errors are fixed classifications, never driver/provider
		// raw errors that may contain credentials or token-bearing bodies.
		fail(err.Error())
	}
}

func fail(code string) {
	_ = json.NewEncoder(os.Stderr).Encode(map[string]string{"state": "stopped", "code": code})
	os.Exit(1)
}

func run(ctx context.Context, dir, mode string) error {
	config, err := loadConfig(dir)
	if err != nil {
		return errors.New("configuration_unavailable")
	}
	pc, err := pgxpool.ParseConfig(config["RENJI_DATABASE_URL"])
	if err != nil || pc.ConnConfig.Database != "renji_startup" {
		return errors.New("startup_database_binding_invalid")
	}
	pc.ConnConfig.RuntimeParams["search_path"] = "public"
	dbBinding := digest(fmt.Sprintf("%s:%d/%s/public", pc.ConnConfig.Host, pc.ConnConfig.Port, pc.ConnConfig.Database))
	providerBinding := digest(config["RONGCLOUD_API_URL"] + "\x00" + config["RONGCLOUD_APP_KEY"])
	manifestPath := filepath.Join(dir, "rongcloud-outbox-fixture-v1.json")
	f, err := loadOrPrepare(manifestPath, dbBinding, providerBinding, mode != "inspect")
	if err != nil {
		return errors.New("fixture_manifest_invalid_or_missing")
	}
	pool, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return errors.New("database_unavailable")
	}
	defer pool.Close()
	s := &store.Store{Pool: pool}
	var db, schema string
	if err = pool.QueryRow(ctx, "SELECT current_database(),current_schema()").Scan(&db, &schema); err != nil || db != "renji_startup" || schema != "public" {
		return errors.New("startup_public_schema_unavailable")
	}
	// Cooperating probe processes serialize without changing the outbox schema.
	lock, err := pool.Acquire(ctx)
	if err != nil {
		return errors.New("probe_lock_unavailable")
	}
	defer lock.Release()
	var locked bool
	if err = lock.QueryRow(ctx, "SELECT pg_try_advisory_lock(hashtextextended($1,0))", "renji.rongcloud.synthetic.probe.v1").Scan(&locked); err != nil || !locked {
		return errors.New("another_probe_is_running")
	}
	defer lock.Exec(context.Background(), "SELECT pg_advisory_unlock(hashtextextended($1,0))", "renji.rongcloud.synthetic.probe.v1")
	if mode == "initialize-empty" {
		var count int
		if err = pool.QueryRow(ctx, `SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public' AND tablename IN('principals','external_identities','workspaces','workspace_members','rooms','room_members','messages','actions','events','transport_outbox','goose_db_version')`).Scan(&count); err != nil || count != 0 {
			return errors.New("public_kernel_not_empty_no_initialization")
		}
		if err = s.Migrate(ctx); err != nil {
			return errors.New("empty_public_initialization_failed")
		}
		return json.NewEncoder(os.Stdout).Encode(map[string]any{"state": "empty_public_initialized", "external_calls": 0})
	}
	if mode == "inspect" {
		return writeSnapshot(ctx, s, f, dir)
	}
	if err = exclusivePending(ctx, s, f); err != nil {
		return err
	}
	if mode == "prepare" {
		return json.NewEncoder(os.Stdout).Encode(map[string]any{"state": "prepared", "run_id": f.RunID, "principal_count": len(f.Principals), "message_count": len(f.Messages), "external_calls": 0})
	}
	if err = seed(ctx, s, f, manifestPath); err != nil {
		return err
	}
	provider, err := transport.NewRongCloud(config["RONGCLOUD_API_URL"], config["RONGCLOUD_APP_KEY"], config["RONGCLOUD_APP_SECRET"])
	if err != nil {
		return errors.New("provider_configuration_invalid")
	}
	j, err := openJournal(filepath.Join(dir, "rongcloud-outbox-provider-observations-v1.jsonl"))
	if err != nil {
		return errors.New("provider_journal_unavailable")
	}
	defer j.file.Close()
	scoped := &scopedMessenger{provider: provider, fixture: f, journal: j}
	// Exactly one room creation + three known message events. Re-runs reuse
	// delivered rows; rejected/unknown/in_flight rows stop without reset/retry.
	for step := 0; step < 4; step++ {
		if err = exclusivePending(ctx, s, f); err != nil {
			return err
		}
		var pending, unsafe int
		if err = pool.QueryRow(ctx, `SELECT count(*) FILTER(WHERE o.status='pending'),count(*) FILTER(WHERE o.status NOT IN('pending','delivered'))
FROM transport_outbox o JOIN events e ON e.id=o.event_id WHERE e.room_id=$1`, f.Room.ID).Scan(&pending, &unsafe); err != nil {
			return errors.New("outbox_status_unavailable")
		}
		if unsafe > 0 {
			_ = writeSnapshot(ctx, s, f, dir)
			return errors.New("fixture_delivery_requires_reconciliation")
		}
		if pending == 0 {
			break
		}
		worked, dispatchErr := s.DispatchOne(ctx, scoped)
		if snapshotErr := writeSnapshot(ctx, s, f, dir); snapshotErr != nil {
			return snapshotErr
		}
		if dispatchErr != nil {
			return errors.New("dispatch_persistence_or_claim_failed")
		}
		if !worked {
			return errors.New("fixture_pending_not_claimable")
		}
	}
	if err = writeSnapshot(ctx, s, f, dir); err != nil {
		return err
	}
	var delivered int
	if err = pool.QueryRow(ctx, `SELECT count(*) FROM transport_outbox o JOIN events e ON e.id=o.event_id WHERE e.room_id=$1 AND o.status='delivered'`, f.Room.ID).Scan(&delivered); err != nil {
		return errors.New("final_delivery_check_failed")
	}
	if delivered != 4 {
		return errors.New("fixture_not_fully_delivered_no_retry")
	}
	return nil
}

func seed(ctx context.Context, s *store.Store, f *manifest, path string) error {
	// Principals and membership are setup data; business resources/messages
	// deliberately use Store APIs and their durable action receipts.
	for _, p := range f.Principals {
		if _, err := s.Pool.Exec(ctx, "INSERT INTO principals(id,kind,display_name) VALUES($1,$2,$3) ON CONFLICT(id) DO NOTHING", p.ID, p.Kind, p.DisplayName); err != nil {
			return errors.New("fixture_principal_insert_failed")
		}
		var kind, name string
		var disabled bool
		if err := s.Pool.QueryRow(ctx, "SELECT kind,display_name,disabled FROM principals WHERE id=$1", p.ID).Scan(&kind, &name, &disabled); err != nil || kind != p.Kind || name != p.DisplayName || disabled {
			return errors.New("fixture_principal_conflict")
		}
	}
	w, err := s.CreateWorkspace(ctx, f.Principals[0].ID, f.WorkspaceAction, f.WorkspaceTitle)
	if err != nil || (f.WorkspaceID != "" && f.WorkspaceID != w) {
		return errors.New("fixture_workspace_conflict")
	}
	f.WorkspaceID = w
	if persist(path, f) != nil {
		return errors.New("manifest_workspace_save_failed")
	}
	for _, p := range f.Principals[1:] {
		if _, err = s.Pool.Exec(ctx, "INSERT INTO workspace_members(workspace_id,principal_id,role) VALUES($1,$2,'member') ON CONFLICT DO NOTHING", w, p.ID); err != nil {
			return errors.New("fixture_membership_insert_failed")
		}
		var role string
		if err = s.Pool.QueryRow(ctx, "SELECT role FROM workspace_members WHERE workspace_id=$1 AND principal_id=$2", w, p.ID).Scan(&role); err != nil || role != "member" {
			return errors.New("fixture_membership_conflict")
		}
	}
	r, err := s.CreateRoom(ctx, f.Principals[0].ID, f.RoomAction, w, f.RoomTitle, []string{f.Principals[1].ID, f.Principals[2].ID})
	if err != nil || (f.Room != nil && f.Room.ID != r.ID) {
		return errors.New("fixture_room_conflict")
	}
	f.Room = &r
	if persist(path, f) != nil {
		return errors.New("manifest_room_save_failed")
	}
	for i := range f.Messages {
		m := &f.Messages[i]
		receipt, sendErr := s.Send(ctx, m.AuthorID, r.ID, domain.SendMessage{ActionID: m.ActionID, Content: m.Content, ScopeEpoch: &r.ScopeEpoch})
		if sendErr != nil || (m.Receipt != nil && m.Receipt.Message.ID != receipt.Message.ID) {
			return errors.New("fixture_message_conflict")
		}
		m.Receipt = &receipt
		if persist(path, f) != nil {
			return errors.New("manifest_message_save_failed")
		}
	}
	return nil
}

func exclusivePending(ctx context.Context, s *store.Store, f *manifest) error {
	var room any
	if f.Room != nil {
		room = f.Room.ID
	}
	var unrelated, inflight int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FILTER(WHERE e.room_id IS DISTINCT FROM $1::uuid),count(*) FILTER(WHERE o.status='in_flight')
FROM transport_outbox o JOIN events e ON e.id=o.event_id WHERE o.status IN('pending','in_flight')`, room).Scan(&unrelated, &inflight); err != nil {
		var pe *pgconn.PgError
		if errors.As(err, &pe) {
			return fmt.Errorf("outbox_exclusivity_check_failed_sqlstate_%s", pe.Code)
		}
		return errors.New("outbox_exclusivity_check_failed")
	}
	if unrelated > 0 {
		return errors.New("non_fixture_pending_exists_no_dispatch")
	}
	if inflight > 0 {
		return errors.New("in_flight_exists_no_dispatch")
	}
	return nil
}

func (s *scopedMessenger) Session(ctx context.Context, p domain.Principal) (transport.Session, error) {
	allowed := false
	for _, candidate := range s.fixture.Principals {
		if p == candidate {
			allowed = true
		}
	}
	if !allowed {
		return transport.Session{}, errScope
	}
	op := "register/" + p.ID
	if err := s.journal.begin(op); err != nil {
		return transport.Session{}, err
	}
	result, err := s.provider.Session(ctx, p)
	if saveErr := s.journal.finish(op, err, nil); saveErr != nil {
		return transport.Session{}, saveErr
	}
	return result, err
}
func (s *scopedMessenger) CreateGroup(ctx context.Context, r domain.Room, members []string) error {
	if s.fixture.Room == nil || r != *s.fixture.Room || len(members) != len(s.fixture.Principals) {
		return errScope
	}
	expected := []string{}
	for _, p := range s.fixture.Principals {
		expected = append(expected, p.ID)
	}
	actual := append([]string{}, members...)
	sort.Strings(expected)
	sort.Strings(actual)
	for i := range expected {
		if expected[i] != actual[i] {
			return errScope
		}
	}
	op := "group/" + r.ID
	if err := s.journal.begin(op); err != nil {
		return err
	}
	err := s.provider.CreateGroup(ctx, r, members)
	if saveErr := s.journal.finish(op, err, nil); saveErr != nil {
		return saveErr
	}
	return err
}
func (s *scopedMessenger) Publish(ctx context.Context, m domain.Message) (transport.Delivery, error) {
	allowed := false
	for _, candidate := range s.fixture.Messages {
		if candidate.Receipt != nil && sameMessage(candidate.Receipt.Message, m) {
			allowed = true
		}
	}
	if !allowed || s.fixture.Room == nil || m.RoomID != s.fixture.Room.ID {
		return transport.Delivery{}, errScope
	}
	op := "message/" + m.ID
	if err := s.journal.begin(op); err != nil {
		return transport.Delivery{}, err
	}
	result, err := s.provider.Publish(ctx, m)
	if saveErr := s.journal.finish(op, err, &result); saveErr != nil {
		return transport.Delivery{}, saveErr
	}
	return result, err
}

func openJournal(path string) (*journal, error) {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_APPEND, 0600)
	if err != nil {
		return nil, err
	}
	j := &journal{file: f, seen: map[string]bool{}}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		var o observation
		if json.Unmarshal(scanner.Bytes(), &o) != nil || o.Operation == "" {
			f.Close()
			return nil, errReconcile
		}
		j.seen[o.Operation] = true
	}
	if err = scanner.Err(); err != nil {
		f.Close()
		return nil, err
	}
	return j, nil
}
func (j *journal) append(o observation) error {
	o.At = time.Now().UTC()
	if json.NewEncoder(j.file).Encode(o) != nil || j.file.Sync() != nil {
		return errors.New("provider_journal_write_failed")
	}
	return nil
}
func (j *journal) begin(op string) error {
	if j.seen[op] {
		return errReconcile
	}
	j.seen[op] = true
	return j.append(observation{Operation: op, State: "began"})
}
func (j *journal) finish(op string, err error, d *transport.Delivery) error {
	o := observation{Operation: op, State: "acknowledged", Code: 200, Delivery: d}
	if err != nil {
		o.State = "failed"
		o.Code = 0
		o.Unknown = true
		o.Delivery = nil
		var p *transport.ProviderError
		if errors.As(err, &p) {
			o.Code = p.Code
			o.Unknown = p.Unknown
		}
	}
	return j.append(o)
}

func loadOrPrepare(path, dbBinding, providerBinding string, create bool) (*manifest, error) {
	if b, err := os.ReadFile(path); err == nil {
		var f manifest
		if json.Unmarshal(b, &f) != nil || validateManifest(&f, dbBinding, providerBinding) != nil {
			return nil, errScope
		}
		return &f, nil
	} else if !errors.Is(err, os.ErrNotExist) || !create {
		return nil, err
	}
	id := uuid.NewString()
	short := id[:8]
	f := &manifest{Schema: "renji.rongcloud.synthetic.v1", RunID: id, CreatedAt: time.Now().UTC(), DatabaseBinding: dbBinding, ProviderBinding: providerBinding,
		WorkspaceAction: "transport-probe/" + id + "/workspace", WorkspaceTitle: "人机合成验收工作区 · " + short,
		RoomAction: "transport-probe/" + id + "/room", RoomTitle: "融云人机同群合成验收 · " + short}
	for i, name := range []string{"合成验收 · 人类管理员", "合成验收 · 人类员工", "合成验收 · Agent同事"} {
		kind := "human"
		if i == 2 {
			kind = "agent"
		}
		p := domain.Principal{ID: uuid.NewString(), Kind: kind, DisplayName: name + " · " + short}
		f.Principals = append(f.Principals, p)
		f.Messages = append(f.Messages, fixtureMessage{ActionID: fmt.Sprintf("transport-probe/%s/message/%d", id, i+1), AuthorID: p.ID, Content: fmt.Sprintf("[合成验收 %s] %s：验证 Go 持久消息经 Outbox 投递融云，序号 %d。", short, name, i+1)})
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	if json.NewEncoder(file).Encode(f) != nil || file.Sync() != nil {
		return nil, errors.New("manifest_create_failed")
	}
	if err = syncDir(filepath.Dir(path)); err != nil {
		return nil, err
	}
	return f, nil
}
func validateManifest(f *manifest, dbBinding, providerBinding string) error {
	if f.Schema != "renji.rongcloud.synthetic.v1" || f.DatabaseBinding != dbBinding || f.ProviderBinding != providerBinding || len(f.Principals) != 3 || len(f.Messages) != 3 || !strings.Contains(f.RoomTitle, "合成验收") || !strings.Contains(f.WorkspaceTitle, "合成验收") {
		return errScope
	}
	if _, err := uuid.Parse(f.RunID); err != nil {
		return errScope
	}
	seen := map[string]bool{}
	for i, p := range f.Principals {
		if _, err := uuid.Parse(p.ID); err != nil || seen[p.ID] || !strings.Contains(p.DisplayName, "合成验收") {
			return errScope
		}
		seen[p.ID] = true
		expected := "human"
		if i == 2 {
			expected = "agent"
		}
		if p.Kind != expected {
			return errScope
		}
	}
	for i, m := range f.Messages {
		if m.AuthorID != f.Principals[i].ID || m.ActionID != fmt.Sprintf("transport-probe/%s/message/%d", f.RunID, i+1) || !strings.HasPrefix(m.Content, "[合成验收 ") {
			return errScope
		}
	}
	if f.WorkspaceAction != "transport-probe/"+f.RunID+"/workspace" || f.RoomAction != "transport-probe/"+f.RunID+"/room" {
		return errScope
	}
	return nil
}
func persist(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".transport-probe-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(append(b, '\n'))
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = os.Rename(tmp, path); err != nil {
		return err
	}
	return syncDir(filepath.Dir(path))
}
func syncDir(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}
func digest(v string) string { b := sha256.Sum256([]byte(v)); return hex.EncodeToString(b[:]) }

func loadConfig(dir string) (map[string]string, error) {
	values := map[string]string{}
	for _, name := range []string{"api.env", "rongcloud.env"} {
		f, err := os.Open(filepath.Join(dir, name))
		if err != nil {
			return nil, err
		}
		scanner := bufio.NewScanner(f)
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			line = strings.TrimPrefix(line, "export ")
			key, value, ok := strings.Cut(line, "=")
			if !ok {
				f.Close()
				return nil, errors.New("invalid env")
			}
			key = strings.TrimSpace(key)
			value = strings.TrimSpace(value)
			if strings.HasPrefix(value, "\"") {
				decoded, e := strconv.Unquote(value)
				if e != nil {
					f.Close()
					return nil, e
				}
				value = decoded
			} else if strings.HasPrefix(value, "'") && strings.HasSuffix(value, "'") {
				value = value[1 : len(value)-1]
			}
			values[key] = value
		}
		err = scanner.Err()
		f.Close()
		if err != nil {
			return nil, err
		}
	}
	for _, key := range []string{"RENJI_DATABASE_URL", "RONGCLOUD_API_URL", "RONGCLOUD_APP_KEY", "RONGCLOUD_APP_SECRET"} {
		if values[key] == "" {
			return nil, errors.New("missing configuration")
		}
	}
	return values, nil
}

func writeSnapshot(ctx context.Context, s *store.Store, f *manifest, dir string) error {
	type row struct {
		ID       int64           `json:"id"`
		Kind     string          `json:"kind"`
		Status   string          `json:"status"`
		Attempts int             `json:"attempts"`
		Receipt  json.RawMessage `json:"provider_receipt"`
	}
	records := []row{}
	if f.Room != nil {
		rows, err := s.Pool.Query(ctx, `SELECT o.id,e.type,o.status,o.attempts,o.provider_receipt FROM transport_outbox o JOIN events e ON e.id=o.event_id WHERE e.room_id=$1 ORDER BY o.id`, f.Room.ID)
		if err != nil {
			return errors.New("outbox_readback_failed")
		}
		defer rows.Close()
		for rows.Next() {
			var r row
			if rows.Scan(&r.ID, &r.Kind, &r.Status, &r.Attempts, &r.Receipt) != nil {
				return errors.New("outbox_readback_failed")
			}
			records = append(records, r)
		}
		if rows.Err() != nil {
			return errors.New("outbox_readback_failed")
		}
	}
	state := "incomplete"
	delivered := 0
	for _, r := range records {
		if r.Status == "delivered" {
			delivered++
		}
		if r.Status == "unknown" || r.Status == "in_flight" {
			state = "reconciliation_required"
		}
		if r.Status == "rejected" && state != "reconciliation_required" {
			state = "provider_or_payload_rejected"
		}
	}
	if delivered == 4 && len(records) == 4 {
		state = "server_delivery_verified"
	}
	result := map[string]any{"schema": "renji.rongcloud.synthetic.receipt.v1", "at": time.Now().UTC(), "run_id": f.RunID, "state": state, "outbox": records, "client_receive_verified": false}
	if f.Room != nil {
		result["room_id"] = f.Room.ID
	}
	if persist(filepath.Join(dir, "rongcloud-outbox-readback-v1.json"), result) != nil {
		return errors.New("readback_save_failed")
	}
	if json.NewEncoder(os.Stdout).Encode(result) != nil {
		return errors.New("readback_output_failed")
	}
	return nil
}

func sameMessage(a, b domain.Message) bool {
	return a.ID == b.ID && a.RoomID == b.RoomID && a.AuthorID == b.AuthorID && a.Content == b.Content && a.Seq == b.Seq && a.CreatedAt.Equal(b.CreatedAt)
}
