// transport-receive-probe is a single-room, single-message acceptance fixture.
// It never drains the general outbox; a durable intent forbids network resend.
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
	"github.com/huapohen/active-agent/services/collaboration/internal/transport"
	"github.com/jackc/pgx/v5"
)

const roomID = "63892e35-efbd-40cb-86e6-17c7cab37aa6"
const workspaceID = "736b5198-479b-4505-8dbb-8d54b0d5c697"
const senderID = "798eb3da-b217-4204-8baf-23ff2941a88c"
const receiverID = "19519294-3539-479b-8615-a9ee68709c2d"
const agentID = "b49d2ffc-946c-4061-a6ef-5ed7e4308465"

type plan struct {
	Schema         string                  `json:"schema"`
	CreatedAt      time.Time               `json:"created_at"`
	ActionID       string                  `json:"action_id"`
	RoomVersion    int64                   `json:"room_version"`
	ScopeEpoch     int64                   `json:"scope_epoch"`
	OldOutboxSHA   string                  `json:"old_outbox_5_6_sha256"`
	OldManifestSHA string                  `json:"old_manifest_sha256"`
	Binding        transport.BridgeBinding `json:"-"`
	Message        domain.Message          `json:"message"`
	OutboxID       int64                   `json:"outbox_id"`
	EventID        int64                   `json:"event_id"`
}

func main() {
	base := flag.String("env-dir", "", "existing private startup directory")
	dir := flag.String("run-dir", "", "new private run directory")
	mode := flag.String("mode", "inspect", "prepare, publish-once, inspect")
	ingress := flag.String("api-origin", "http://127.0.0.1:8090", "actual loopback Go API origin")
	flag.Parse()
	if *base == "" || *dir == "" || (*mode != "prepare" && *mode != "publish-once" && *mode != "inspect") {
		stop("arguments_invalid")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if err := run(ctx, *base, *dir, *mode, *ingress); err != nil {
		stop(err.Error())
	}
}
func stop(code string) {
	_ = json.NewEncoder(os.Stderr).Encode(map[string]string{"state": "stopped", "code": code})
	os.Exit(1)
}
func hash(raw []byte) string { h := sha256.Sum256(raw); return hex.EncodeToString(h[:]) }
func writeNew(path string, v any) error {
	raw, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return errors.New("serialization_failed")
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return errors.New("existing_intent_requires_reconciliation")
	}
	defer f.Close()
	if _, err = f.Write(raw); err != nil {
		return errors.New("intent_write_failed")
	}
	if f.Sync() != nil {
		return errors.New("intent_sync_failed")
	}
	parent, err := os.Open(filepath.Dir(path))
	if err == nil {
		defer parent.Close()
		err = parent.Sync()
	}
	if err != nil {
		return errors.New("intent_sync_failed")
	}
	return nil
}
func loadEnv(path string) (map[string]string, error) {
	f, e := os.Open(path)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	st, e := f.Stat()
	if e != nil || st.Mode().Perm()&0077 != 0 || st.Size() > 65536 {
		return nil, errors.New("private_config_required")
	}
	m := map[string]string{}
	scan := bufio.NewScanner(f)
	for scan.Scan() {
		line := strings.TrimSpace(scan.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		m[strings.TrimSpace(k)] = strings.Trim(strings.TrimSpace(v), "\"'")
	}
	return m, scan.Err()
}

func run(ctx context.Context, base, dir, mode, origin string) error {
	api, e := loadEnv(filepath.Join(base, "api.env"))
	if e != nil {
		return errors.New("private_config_unavailable")
	}
	rc, e := loadEnv(filepath.Join(base, "rongcloud.env"))
	if e != nil {
		return errors.New("private_config_unavailable")
	}
	s, e := store.Open(ctx, api["RENJI_DATABASE_URL"])
	if e != nil {
		return errors.New("database_unavailable")
	}
	defer s.Close()
	r, e := transport.NewRongCloud(rc["RONGCLOUD_API_URL"], rc["RONGCLOUD_APP_KEY"], rc["RONGCLOUD_APP_SECRET"])
	if e != nil {
		return errors.New("provider_config_invalid")
	}
	if e = os.MkdirAll(dir, 0700); e != nil {
		return errors.New("run_directory_unavailable")
	}
	old, e := os.ReadFile(filepath.Join(base, "rongcloud-outbox-fixture-v1.json"))
	if e != nil {
		return errors.New("fixture_unavailable")
	}
	var fixture struct {
		Room       domain.Room        `json:"room"`
		Principals []domain.Principal `json:"principals"`
	}
	if json.Unmarshal(old, &fixture) != nil || fixture.Room.ID != roomID || fixture.Room.WorkspaceID != workspaceID {
		return errors.New("fixture_scope_changed")
	}
	ids := []string{}
	for _, p := range fixture.Principals {
		ids = append(ids, p.ID)
	}
	slices.Sort(ids)
	want := []string{senderID, receiverID, agentID}
	slices.Sort(want)
	if !slices.Equal(ids, want) {
		return errors.New("fixture_identity_changed")
	}
	var p plan
	if mode == "prepare" {
		if _, e = os.Stat(filepath.Join(dir, "plan.json")); !os.IsNotExist(e) {
			return errors.New("existing_plan_requires_reconciliation")
		}
		var version, epoch int64
		version, epoch, e = checkRoom(ctx, s.Pool, fixture.Room.Title)
		if e != nil {
			return e
		}
		oldHash, e := oldOutboxHash(ctx, s)
		if e != nil {
			return e
		}
		p = plan{Schema: "renji.rongcloud.receive-probe.v1", CreatedAt: time.Now().UTC(), ActionID: "receive-probe-" + uuid.NewString(), RoomVersion: version, ScopeEpoch: epoch, OldOutboxSHA: oldHash, OldManifestSHA: hash(old)}
		if e = writeNew(filepath.Join(dir, "prepare-intent.json"), p); e != nil {
			return e
		}
		receipt, e := s.Send(ctx, senderID, roomID, domain.SendMessage{ActionID: p.ActionID, Content: "融云可信接收桥合成验收 · " + p.ActionID})
		if e != nil {
			return errors.New("canonical_prepare_failed")
		}
		p.Message = receipt.Message
		e = s.Pool.QueryRow(ctx, `SELECT o.id,e.id FROM transport_outbox o JOIN events e ON e.id=o.event_id WHERE e.principal_id=$1 AND e.action_id=$2 AND e.type='message.created'`, senderID, p.ActionID).Scan(&p.OutboxID, &p.EventID)
		if e != nil || p.OutboxID <= 6 {
			return errors.New("outbox_scope_invalid")
		}
		if e = writeNew(filepath.Join(dir, "plan.json"), p); e != nil {
			return e
		}
		secret := make([]byte, 32)
		if _, e = rand.Read(secret); e != nil {
			return errors.New("entropy_unavailable")
		}
		b := transport.BridgeBinding{ID: "receive-" + uuid.NewString(), ReceiverID: receiverID, RoomID: roomID, Secret: hex.EncodeToString(secret)}
		if e = writeNew(filepath.Join(dir, "bindings.json"), []transport.BridgeBinding{b}); e != nil {
			return e
		}
		if e = writeNew(filepath.Join(dir, "session-intent.json"), map[string]any{"operation": "get_existing_receiver_token", "receiver_id": receiverID, "at": time.Now().UTC()}); e != nil {
			return e
		}
		session, e := r.Session(ctx, domain.Principal{ID: receiverID, Kind: "human", DisplayName: "人机合成验收管理员"})
		if e != nil {
			return errors.New("receiver_session_unknown_no_retry")
		}
		if e = writeNew(filepath.Join(dir, "bridge.json"), map[string]any{"schema": "renji.rongcloud.trusted-bridge.v1", "bridge_id": b.ID, "receiver_id": b.ReceiverID, "room_id": b.RoomID, "app_key": session.AppKey, "provider_token": session.Token, "bridge_secret": b.Secret, "ingress_url": strings.TrimSuffix(origin, "/") + "/internal/transport/rongcloud/" + b.ID, "state_dir": filepath.Join(dir, "bridge-state"), "message_ids": []string{p.Message.ID}}); e != nil {
			return e
		}
		fmt.Println(`{"state":"prepared","message_external_sends":0,"receiver_token_requests":1}`)
		return nil
	}
	raw, e := os.ReadFile(filepath.Join(dir, "plan.json"))
	if e != nil || json.Unmarshal(raw, &p) != nil {
		return errors.New("plan_unavailable")
	}
	if p.Schema != "renji.rongcloud.receive-probe.v1" || p.Message.RoomID != roomID || p.Message.AuthorID != senderID || p.OutboxID <= 6 || p.OldManifestSHA != hash(old) {
		return errors.New("plan_scope_invalid")
	}
	bindingsRaw, e := os.ReadFile(filepath.Join(dir, "bindings.json"))
	var bindings []transport.BridgeBinding
	if e != nil || json.Unmarshal(bindingsRaw, &bindings) != nil || len(bindings) != 1 || !bindings[0].Valid() || bindings[0].RoomID != roomID || bindings[0].ReceiverID != receiverID {
		return errors.New("binding_unavailable")
	}
	p.Binding = bindings[0]
	oldHash, e := oldOutboxHash(ctx, s)
	if e != nil || oldHash != p.OldOutboxSHA {
		return errors.New("old_outbox_changed")
	}
	if mode == "inspect" {
		page, e := s.TransportArrivals(ctx, receiverID, 0, 100, bindings)
		if e != nil {
			return errors.New("ingress_unavailable")
		}
		matched := []store.TransportArrival{}
		for _, a := range page.Events {
			if a.EventID == p.EventID && a.MessageID == p.Message.ID {
				matched = append(matched, a)
			}
		}
		return json.NewEncoder(os.Stdout).Encode(map[string]any{"state": "observed", "arrivals": matched, "status": page.Status, "old_outbox_5_6_unchanged": true})
	}
	if _, e = os.Stat(filepath.Join(dir, "publish-intent.json")); !os.IsNotExist(e) {
		return errors.New("publication_intent_exists_no_resend")
	}
	page, e := s.TransportArrivals(ctx, receiverID, 0, 100, bindings)
	if e != nil || page.Status.BridgeState != "connected" {
		return errors.New("actual_sdk_receiver_not_connected")
	}
	tx, e := s.Pool.Begin(ctx)
	if e != nil {
		return errors.New("transaction_unavailable")
	}
	defer tx.Rollback(ctx)
	v, epoch, e := checkRoom(ctx, tx, fixture.Room.Title)
	if e != nil || v != p.RoomVersion || epoch != p.ScopeEpoch {
		return errors.New("source_policy_changed")
	}
	var status string
	var attempts int
	var eventID int64
	var eventRaw []byte
	e = tx.QueryRow(ctx, `SELECT o.status,o.attempts,o.event_id,e.data FROM transport_outbox o JOIN events e ON e.id=o.event_id WHERE o.id=$1 AND e.principal_id=$2 AND e.room_id=$3 AND e.action_id=$4 AND e.type='message.created' FOR UPDATE OF o FOR SHARE OF e`, p.OutboxID, senderID, roomID, p.ActionID).Scan(&status, &attempts, &eventID, &eventRaw)
	var message domain.Message
	if e != nil || status != "pending" || attempts != 0 || eventID != p.EventID || json.Unmarshal(eventRaw, &message) != nil || message.ID != p.Message.ID || message.Content != p.Message.Content {
		return errors.New("new_outbox_fence_failed")
	}
	if e = writeNew(filepath.Join(dir, "publish-intent.json"), map[string]any{"at": time.Now().UTC(), "new_outbox_id": p.OutboxID, "event_id": p.EventID, "message_id": p.Message.ID, "target_group": roomID, "operation": "message.group.publish", "network_write_budget": 1, "plan_sha256": hash(raw)}); e != nil {
		return e
	}
	// This controlled test dispatch intentionally targets only its new ID.
	// No general worker/claimNext or historical outbox row is touched.
	delivery, sendErr := r.Publish(ctx, message)
	if e = writeNew(filepath.Join(dir, "provider-result.json"), map[string]any{"at": time.Now().UTC(), "accepted": sendErr == nil, "delivery": delivery, "unknown": sendErr != nil}); e != nil {
		return e
	}
	receiptRaw, _ := json.Marshal(delivery)
	outcome := "delivered"
	if sendErr != nil {
		outcome = "unknown"
	}
	_, e = tx.Exec(ctx, `UPDATE transport_outbox SET status=$2,attempts=1,provider_receipt=$3,updated_at=clock_timestamp() WHERE id=$1 AND status='pending' AND attempts=0`, p.OutboxID, outcome, receiptRaw)
	if e != nil {
		return errors.New("outbox_ack_save_unknown")
	}
	if tx.Commit(ctx) != nil {
		return errors.New("outbox_ack_commit_unknown")
	}
	if sendErr != nil {
		return errors.New("provider_outcome_unknown_no_resend")
	}
	fmt.Println(`{"state":"provider_accepted","message_external_sends":1,"received_not_yet_claimed":true}`)
	return nil
}

type queryer interface {
	QueryRow(context.Context, string, ...any) pgx.Row
	Query(context.Context, string, ...any) (pgx.Rows, error)
}

func checkRoom(ctx context.Context, q queryer, title string) (int64, int64, error) {
	var version, epoch int64
	var stopped bool
	var actualTitle, workspace string
	e := q.QueryRow(ctx, `SELECT workspace_id::text,title,version,scope_epoch,stopped FROM rooms WHERE id=$1 FOR SHARE`, roomID).Scan(&workspace, &actualTitle, &version, &epoch, &stopped)
	if e != nil || workspace != workspaceID || actualTitle != title || stopped {
		return 0, 0, errors.New("fixture_room_changed")
	}
	rows, e := q.Query(ctx, `SELECT p.id::text,p.kind,p.disabled FROM room_members m JOIN principals p ON p.id=m.principal_id JOIN rooms r ON r.id=m.room_id JOIN workspace_members wm ON wm.workspace_id=r.workspace_id AND wm.principal_id=p.id WHERE m.room_id=$1 ORDER BY p.id FOR SHARE OF m,p,wm`, roomID)
	if e != nil {
		return 0, 0, errors.New("fixture_members_unavailable")
	}
	defer rows.Close()
	got := map[string]string{}
	for rows.Next() {
		var id, kind string
		var disabled bool
		if rows.Scan(&id, &kind, &disabled) != nil || disabled {
			return 0, 0, errors.New("fixture_members_changed")
		}
		got[id] = kind
	}
	if rows.Err() != nil || len(got) != 3 || got[senderID] != "human" || got[receiverID] != "human" || got[agentID] != "agent" {
		return 0, 0, errors.New("fixture_members_changed")
	}
	return version, epoch, nil
}
func oldOutboxHash(ctx context.Context, s *store.Store) (string, error) {
	var raw []byte
	e := s.Pool.QueryRow(ctx, `SELECT jsonb_agg(to_jsonb(o) ORDER BY o.id) FROM transport_outbox o WHERE id IN(5,6)`).Scan(&raw)
	if e != nil {
		return "", errors.New("old_outbox_unavailable")
	}
	return hash(raw), nil
}
