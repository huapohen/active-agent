// execution-probe bootstraps only the recorded synthetic fixture, then verifies
// the real Clerk-machine-authenticated HTTP action gateway. It never dispatches
// the resulting transport outbox or changes the original RongCloud manifest.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
	"github.com/jackc/pgx/v5/pgxpool"
)

const localAPI = "http://127.0.0.1:3318"

type sourceFixture struct {
	RunID       string             `json:"run_id"`
	WorkspaceID string             `json:"workspace_id"`
	Principals  []domain.Principal `json:"principals"`
	Room        domain.Room        `json:"room"`
}
type check struct {
	At         time.Time `json:"at"`
	Name       string    `json:"name"`
	Passed     bool      `json:"passed"`
	HTTPStatus int       `json:"http_status,omitempty"`
	Code       string    `json:"code,omitempty"`
	DurationMS int64     `json:"duration_ms,omitempty"`
}
type executionManifest struct {
	Schema          string                 `json:"schema"`
	RunID           string                 `json:"fixture_run_id"`
	Issuer          string                 `json:"issuer"`
	MachineSubject  string                 `json:"machine_subject"`
	DatabaseBinding string                 `json:"database_binding"`
	OwnerID         string                 `json:"owner_id"`
	AgentID         string                 `json:"agent_id"`
	WorkspaceID     string                 `json:"workspace_id"`
	Source          domain.Room            `json:"source"`
	Target          *domain.Room           `json:"target,omitempty"`
	Actions         map[string]string      `json:"actions"`
	Binding         *store.ExecutorBinding `json:"binding,omitempty"`
	Root            *store.ExecutionRun    `json:"root,omitempty"`
	Child           *store.ExecutionRun    `json:"child,omitempty"`
	Stopped         *domain.Room           `json:"stopped,omitempty"`
	Resumed         *domain.Room           `json:"resumed,omitempty"`
	Receipt         *harness.Receipt       `json:"receipt,omitempty"`
	Prepared        bool                   `json:"prepared"`
	Completed       bool                   `json:"completed"`
	Checks          []check                `json:"checks"`
}
type probe struct {
	fixture *executionManifest
	path    string
	store   *store.Store
	client  *http.Client
	token   string
}

func main() {
	dir := flag.String("env-dir", "", "ignored startup data directory")
	mode := flag.String("mode", "inspect", "prepare, verify, inspect")
	flag.Parse()
	if *dir == "" || (*mode != "prepare" && *mode != "verify" && *mode != "inspect") {
		fatal("arguments_invalid")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	if err := run(ctx, *dir, *mode); err != nil {
		fatal(err.Error())
	}
}
func fatal(code string) {
	_ = json.NewEncoder(os.Stderr).Encode(map[string]string{"state": "stopped", "code": code})
	os.Exit(1)
}
func run(ctx context.Context, dir, mode string) error {
	cfg, err := loadConfig(dir)
	if err != nil {
		return errors.New("private_configuration_unavailable")
	}
	pc, err := pgxpool.ParseConfig(cfg["RENJI_DATABASE_URL"])
	if err != nil || pc.ConnConfig.Database != "renji_startup" {
		return errors.New("startup_database_invalid")
	}
	pc.ConnConfig.RuntimeParams["search_path"] = "public"
	var source sourceFixture
	b, err := os.ReadFile(filepath.Join(dir, "rongcloud-outbox-fixture-v1.json"))
	if err != nil || json.Unmarshal(b, &source) != nil || validateSource(source) != nil {
		return errors.New("synthetic_source_manifest_invalid")
	}
	path := filepath.Join(dir, "execution-gateway-fixture-v1.json")
	f, err := loadManifest(path, source, cfg, digest(fmt.Sprintf("%s:%d/%s/public", pc.ConnConfig.Host, pc.ConnConfig.Port, pc.ConnConfig.Database)), mode != "inspect")
	if err != nil {
		return err
	}
	pool, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return errors.New("database_unavailable")
	}
	defer pool.Close()
	p := &probe{fixture: f, path: path, store: &store.Store{Pool: pool}, token: cfg["RENJI_GATEWAY_TOKEN"], client: &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
	lock, err := pool.Acquire(ctx)
	if err != nil {
		return errors.New("probe_lock_unavailable")
	}
	defer lock.Release()
	var locked bool
	if lock.QueryRow(ctx, "SELECT pg_try_advisory_lock(hashtextextended($1,0))", "renji.execution.synthetic.probe.v1").Scan(&locked) != nil || !locked {
		return errors.New("another_execution_probe_is_running")
	}
	defer lock.Exec(context.Background(), "SELECT pg_advisory_unlock(hashtextextended($1,0))", "renji.execution.synthetic.probe.v1")
	if err = p.validateDatabase(ctx); err != nil {
		return err
	}
	if mode == "inspect" {
		return p.snapshot(ctx, dir)
	}
	if !f.Prepared {
		if err = p.prepare(ctx); err != nil {
			return err
		}
	}
	if mode == "prepare" {
		return p.snapshot(ctx, dir)
	}
	if !f.Completed {
		if err = p.verify(ctx); err != nil {
			_ = p.snapshot(ctx, dir)
			return err
		}
	}
	return p.snapshot(ctx, dir)
}
func validateSource(s sourceFixture) error {
	if _, err := uuid.Parse(s.RunID); err != nil || len(s.Principals) != 3 || s.WorkspaceID != s.Room.WorkspaceID || !strings.Contains(s.Room.Title, "合成验收") {
		return errors.New("source invalid")
	}
	if _, err := uuid.Parse(s.Room.ID); err != nil {
		return err
	}
	if _, err := uuid.Parse(s.WorkspaceID); err != nil {
		return err
	}
	seen := map[string]bool{}
	for i, p := range s.Principals {
		if _, err := uuid.Parse(p.ID); err != nil || seen[p.ID] || !strings.Contains(p.DisplayName, "合成验收") {
			return errors.New("principal invalid")
		}
		seen[p.ID] = true
		kind := "human"
		if i == 2 {
			kind = "agent"
		}
		if p.Kind != kind {
			return errors.New("kind invalid")
		}
	}
	return nil
}
func loadManifest(path string, s sourceFixture, cfg map[string]string, db string, create bool) (*executionManifest, error) {
	if b, err := os.ReadFile(path); err == nil {
		var f executionManifest
		if json.Unmarshal(b, &f) != nil || f.Schema != "renji.execution.synthetic.v1" || f.RunID != s.RunID || f.OwnerID != s.Principals[0].ID || f.AgentID != s.Principals[2].ID || f.Source.ID != s.Room.ID || f.WorkspaceID != s.WorkspaceID || f.Issuer != cfg["CLERK_ISSUER"] || f.MachineSubject != cfg["CLERK_WORKER_MACHINE_ID"] || f.DatabaseBinding != db {
			return nil, errors.New("execution_manifest_binding_mismatch")
		}
		for _, key := range actionKeys() {
			if f.Actions[key] != harness.StableID(s.RunID, "execution-probe/v1/"+key) {
				return nil, errors.New("execution_action_id_mismatch")
			}
		}
		return &f, nil
	} else if !errors.Is(err, os.ErrNotExist) || !create {
		return nil, errors.New("execution_manifest_missing")
	}
	f := &executionManifest{Schema: "renji.execution.synthetic.v1", RunID: s.RunID, Issuer: cfg["CLERK_ISSUER"], MachineSubject: cfg["CLERK_WORKER_MACHINE_ID"], DatabaseBinding: db, OwnerID: s.Principals[0].ID, AgentID: s.Principals[2].ID, WorkspaceID: s.WorkspaceID, Source: s.Room, Actions: map[string]string{}}
	for _, key := range actionKeys() {
		f.Actions[key] = harness.StableID(s.RunID, "execution-probe/v1/"+key)
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return nil, errors.New("execution_manifest_create_failed")
	}
	defer file.Close()
	if json.NewEncoder(file).Encode(f) != nil || file.Sync() != nil || syncDir(filepath.Dir(path)) != nil {
		return nil, errors.New("execution_manifest_persist_failed")
	}
	return f, nil
}
func actionKeys() []string {
	return []string{"register", "proactive", "target", "root", "child", "success", "missing_run", "forged", "trimmed", "stopped_action", "resumed_action", "stop", "resume"}
}
func (p *probe) save() error {
	if persist(p.path, p.fixture) != nil {
		return errors.New("execution_manifest_save_failed")
	}
	return nil
}
func (p *probe) validateDatabase(ctx context.Context) error {
	f := p.fixture
	var sourceWorkspace, title string
	if p.store.Pool.QueryRow(ctx, "SELECT workspace_id::text,title FROM rooms WHERE id=$1", f.Source.ID).Scan(&sourceWorkspace, &title) != nil || sourceWorkspace != f.WorkspaceID || title != f.Source.Title {
		return errors.New("source_room_binding_changed")
	}
	var ownerKind, agentKind, role string
	if p.store.Pool.QueryRow(ctx, "SELECT p.kind,m.role FROM principals p JOIN workspace_members m ON m.principal_id=p.id WHERE p.id=$1 AND m.workspace_id=$2 AND NOT p.disabled", f.OwnerID, f.WorkspaceID).Scan(&ownerKind, &role) != nil || ownerKind != "human" || role != "owner" {
		return errors.New("synthetic_owner_binding_changed")
	}
	if p.store.Pool.QueryRow(ctx, "SELECT kind FROM principals WHERE id=$1 AND NOT disabled", f.AgentID).Scan(&agentKind) != nil || agentKind != "agent" {
		return errors.New("synthetic_agent_binding_changed")
	}
	return nil
}
func (p *probe) prepare(ctx context.Context) error {
	f := p.fixture
	s := p.store
	b, err := s.RegisterExecutor(ctx, f.OwnerID, store.RegisterExecutorCommand{ActionID: f.Actions["register"], WorkspaceID: f.WorkspaceID, AgentPrincipalID: f.AgentID, Issuer: f.Issuer, MachineSubject: f.MachineSubject, Enabled: true})
	if err != nil {
		return errors.New("executor_bootstrap_failed")
	}
	f.Binding = &b
	if p.save() != nil {
		return errors.New("binding_save_failed")
	}
	_, err = s.SetAgentExecutionPolicy(ctx, f.OwnerID, store.AgentExecutionPolicyCommand{ActionID: f.Actions["proactive"], WorkspaceID: f.WorkspaceID, AgentPrincipalID: f.AgentID, ProactiveEnabled: true, ExpectedVersion: 1})
	if err != nil {
		return errors.New("policy_bootstrap_failed")
	}
	b, err = s.ResolveExecutor(ctx, f.Issuer, f.MachineSubject)
	if err != nil || !b.ProactiveEnabled {
		return errors.New("executor_bootstrap_readback_failed")
	}
	f.Binding = &b
	if p.save() != nil {
		return errors.New("policy_save_failed")
	}
	target, err := s.CreateRoom(ctx, f.OwnerID, f.Actions["target"], f.WorkspaceID, "执行来源停止合成验收 · "+f.RunID[:8], []string{f.AgentID})
	if err != nil {
		return errors.New("target_room_bootstrap_failed")
	}
	if f.Target != nil && f.Target.ID != target.ID {
		return errors.New("target_room_conflict")
	}
	f.Target = &target
	if p.save() != nil {
		return errors.New("target_save_failed")
	}
	root, err := s.CreateExecutionRun(ctx, f.OwnerID, store.CreateExecutionRunCommand{ActionID: f.Actions["root"], ExecutorID: b.ExecutorID, RoomID: f.Source.ID, ScopeEpoch: f.Source.ScopeEpoch, Goal: "合成验收：父来源范围，无模型调用"})
	if err != nil {
		return errors.New("root_run_bootstrap_failed")
	}
	f.Root = &root
	if p.save() != nil {
		return errors.New("root_save_failed")
	}
	child, err := s.CreateExecutionRun(ctx, f.OwnerID, store.CreateExecutionRunCommand{ActionID: f.Actions["child"], ExecutorID: b.ExecutorID, RoomID: target.ID, ScopeEpoch: target.ScopeEpoch, ParentRunID: root.Context.RunID, Goal: "合成验收：继承来源的目标群动作，不向融云投递"})
	if err != nil {
		return errors.New("child_run_bootstrap_failed")
	}
	f.Child = &child
	if len(child.Context.OriginScopes) != 1 || child.Context.OriginScopes[0].RoomID != f.Source.ID || child.Context.OriginScopes[0].Epoch != f.Source.ScopeEpoch {
		return errors.New("source_inheritance_not_recorded")
	}
	f.Prepared = true
	return p.save()
}

func (p *probe) done(name string) bool {
	for _, c := range p.fixture.Checks {
		if c.Name == name && c.Passed {
			return true
		}
	}
	return false
}
func (p *probe) record(name string, status int, code string, elapsed time.Duration, passed bool) error {
	p.fixture.Checks = append(p.fixture.Checks, check{At: time.Now().UTC(), Name: name, Passed: passed, HTTPStatus: status, Code: code, DurationMS: elapsed.Milliseconds()})
	if err := p.save(); err != nil {
		return err
	}
	if !passed {
		return fmt.Errorf("check_failed_%s_http_%d", name, status)
	}
	return nil
}
func (p *probe) request(ctx context.Context, method, path string, body any) (int, []byte, time.Duration, error) {
	encoded, err := json.Marshal(body)
	if err != nil {
		return 0, nil, 0, errors.New("request_encode_failed")
	}
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(encoded)
	}
	req, err := http.NewRequestWithContext(ctx, method, localAPI+path, reader)
	if err != nil {
		return 0, nil, 0, errors.New("request_invalid")
	}
	req.Header.Set("Authorization", "Bearer "+p.token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("MCP-Protocol-Version", "2025-11-25")
	start := time.Now()
	resp, err := p.client.Do(req)
	if err != nil {
		return 0, nil, time.Since(start), errors.New("gateway_outcome_unknown")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 262145))
	if err != nil || len(data) > 262144 {
		return resp.StatusCode, nil, time.Since(start), errors.New("gateway_response_invalid")
	}
	return resp.StatusCode, data, time.Since(start), nil
}
func (p *probe) httpCheck(ctx context.Context, name, method, path string, body any, status int, validate func([]byte) bool) error {
	if p.done(name) {
		return nil
	}
	got, data, dur, err := p.request(ctx, method, path, body)
	code := ""
	var failure struct {
		Error string `json:"error"`
		Code  string `json:"code"`
	}
	_ = json.Unmarshal(data, &failure)
	if safeCode(failure.Code) {
		code = failure.Code
	} else if safeCode(failure.Error) {
		code = failure.Error
	}
	passed := err == nil && got == status && (validate == nil || validate(data))
	return p.record(name, got, code, dur, passed)
}
func safeCode(s string) bool {
	if s == "" || len(s) > 80 || strings.HasPrefix(s, "mt_") || strings.HasPrefix(s, "ak_") || strings.HasPrefix(s, "sk_") {
		return false
	}
	for _, c := range s {
		if (c < 'a' || c > 'z') && c != '_' {
			return false
		}
	}
	return true
}
func (p *probe) action(key string) harness.Action {
	body, _ := json.Marshal(map[string]string{"room_id": p.fixture.Target.ID, "content": "[合成验收 " + p.fixture.RunID[:8] + "] 官方 Clerk 机器凭据经 Go Run 网关提交；本消息不向融云投递。"})
	return harness.Action{ID: p.fixture.Actions[key], Type: "message.send", Payload: body}
}
func (p *probe) verify(ctx context.Context) error {
	f := p.fixture
	rc := f.Child.Context
	if err := p.httpCheck(ctx, "machine_me", "GET", "/v1/me", nil, 200, func(b []byte) bool {
		var r struct {
			Principal domain.Principal `json:"principal"`
		}
		return json.Unmarshal(b, &r) == nil && r.Principal.ID == f.AgentID && r.Principal.Kind == "agent"
	}); err != nil {
		return err
	}
	binding := map[string]string{"principal_id": f.AgentID, "executor_id": f.Binding.ExecutorID}
	if err := p.httpCheck(ctx, "server_binding", "POST", "/internal/harness/binding", binding, 200, func(b []byte) bool {
		var r struct {
			Protocol  string `json:"protocol"`
			Principal string `json:"principal_id"`
			Executor  string `json:"executor_id"`
			Bound     bool   `json:"server_bound"`
		}
		return json.Unmarshal(b, &r) == nil && r.Protocol == "renji-harness-v1" && r.Principal == f.AgentID && r.Executor == f.Binding.ExecutorID && r.Bound
	}); err != nil {
		return err
	}
	if err := p.httpCheck(ctx, "run_read", "GET", "/v1/runs/"+rc.RunID, nil, 200, func(b []byte) bool {
		var r struct {
			Run store.ExecutionRun `json:"run"`
		}
		return json.Unmarshal(b, &r) == nil && reflect.DeepEqual(r.Run.Context, rc)
	}); err != nil {
		return err
	}
	if err := p.httpCheck(ctx, "run_admitted", "POST", "/internal/harness/check", map[string]any{"context": rc}, 200, nil); err != nil {
		return err
	}
	a := p.action("success")
	var payload map[string]string
	_ = json.Unmarshal(a.Payload, &payload)
	apiBody := map[string]any{"action_id": a.ID, "content": payload["content"], "run_id": rc.RunID, "scope_epoch": rc.ScopeEpoch}
	acceptReceipt := func(b []byte) bool {
		var r harness.Receipt
		if json.Unmarshal(b, &r) != nil || r.ActionID != a.ID || r.Status != "succeeded" {
			return false
		}
		if f.Receipt != nil && !equalJSON(f.Receipt.Result, r.Result) {
			return false
		}
		f.Receipt = &r
		return true
	}
	if err := p.httpCheck(ctx, "rest_action", "POST", "/v1/rooms/"+rc.RoomID+"/messages", apiBody, 200, acceptReceipt); err != nil {
		return err
	}
	if err := p.httpCheck(ctx, "rest_action_replay", "POST", "/v1/rooms/"+rc.RoomID+"/messages", apiBody, 200, acceptReceipt); err != nil {
		return err
	}
	if err := p.httpCheck(ctx, "gateway_action_replay", "POST", "/internal/harness/actions", map[string]any{"context": rc, "action": a}, 200, acceptReceipt); err != nil {
		return err
	}
	mcp := map[string]any{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": map[string]any{"name": "message_send", "arguments": map[string]any{"room_id": rc.RoomID, "action_id": a.ID, "content": payload["content"], "run_id": rc.RunID, "scope_epoch": rc.ScopeEpoch}}}
	if err := p.httpCheck(ctx, "mcp_action_replay", "POST", "/v1/mcp", mcp, 200, func(b []byte) bool {
		var r struct {
			Result struct {
				IsError    bool            `json:"isError"`
				Structured json.RawMessage `json:"structuredContent"`
			} `json:"result"`
		}
		return json.Unmarshal(b, &r) == nil && !r.Result.IsError && acceptReceipt(r.Result.Structured)
	}); err != nil {
		return err
	}
	if err := p.httpCheck(ctx, "missing_run_denied", "POST", "/v1/rooms/"+rc.RoomID+"/messages", map[string]any{"action_id": f.Actions["missing_run"], "content": payload["content"]}, 400, nil); err != nil {
		return err
	}
	if err := p.httpCheck(ctx, "forged_binding_denied", "POST", "/internal/harness/binding", map[string]string{"principal_id": f.AgentID, "executor_id": f.OwnerID}, 403, nil); err != nil {
		return err
	}
	bad := rc
	bad.ExecutorID = f.OwnerID
	if err := p.httpCheck(ctx, "forged_executor_denied", "POST", "/internal/harness/actions", map[string]any{"context": bad, "action": p.action("forged")}, 403, nil); err != nil {
		return err
	}
	bad = rc
	bad.OriginScopes = nil
	if err := p.httpCheck(ctx, "source_reduction_denied", "POST", "/internal/harness/actions", map[string]any{"context": bad, "action": p.action("trimmed")}, 403, nil); err != nil {
		return err
	}
	if !p.done("one_committed_action") {
		var messages, actions, outbox int
		err := p.store.Pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM messages WHERE room_id=$1),(SELECT count(*) FROM execution_actions WHERE run_id=$2),(SELECT count(*) FROM transport_outbox WHERE execution_run_id=$2)`, rc.RoomID, rc.RunID).Scan(&messages, &actions, &outbox)
		if err = p.record("one_committed_action", 0, "", 0, err == nil && messages == 1 && actions == 1 && outbox == 1); err != nil {
			return err
		}
	}
	if f.Stopped == nil {
		stopped, err := p.store.SetStopped(ctx, f.OwnerID, f.Source.ID, f.Actions["stop"], f.Source.Version, true)
		if err != nil {
			return errors.New("source_stop_bootstrap_failed")
		}
		f.Stopped = &stopped
		if err = p.save(); err != nil {
			return err
		}
	}
	if err := p.targetRemainsActive(ctx, "target_active_while_source_stopped"); err != nil {
		return err
	}
	if err := p.httpCheck(ctx, "source_stop_denied", "POST", "/internal/harness/actions", map[string]any{"context": rc, "action": p.action("stopped_action")}, 409, stoppedResponse); err != nil {
		return err
	}
	if err := p.httpCheck(ctx, "stopped_run_check_denied", "POST", "/internal/harness/check", map[string]any{"context": rc}, 409, stoppedResponse); err != nil {
		return err
	}
	if f.Resumed == nil {
		resumed, err := p.store.SetStopped(ctx, f.OwnerID, f.Source.ID, f.Actions["resume"], f.Stopped.Version, false)
		if err != nil {
			return errors.New("source_resume_bootstrap_failed")
		}
		f.Resumed = &resumed
		if err = p.save(); err != nil {
			return err
		}
	}
	if err := p.targetRemainsActive(ctx, "target_active_after_source_resume"); err != nil {
		return err
	}
	if err := p.httpCheck(ctx, "old_epoch_after_resume_denied", "POST", "/internal/harness/actions", map[string]any{"context": rc, "action": p.action("resumed_action")}, 409, stoppedResponse); err != nil {
		return err
	}
	if err := p.httpCheck(ctx, "old_success_replay_after_resume_denied", "POST", "/internal/harness/actions", map[string]any{"context": rc, "action": a}, 409, stoppedResponse); err != nil {
		return err
	}
	if !p.done("no_external_delivery") {
		var pending, attempts, delivered int
		err := p.store.Pool.QueryRow(ctx, `SELECT count(*) FILTER(WHERE status='pending'),coalesce(sum(attempts),0),count(*) FILTER(WHERE status='delivered') FROM transport_outbox o JOIN events e ON e.id=o.event_id WHERE e.room_id=$1`, rc.RoomID).Scan(&pending, &attempts, &delivered)
		if err = p.record("no_external_delivery", 0, "", 0, err == nil && pending == 2 && attempts == 0 && delivered == 0); err != nil {
			return err
		}
	}
	if !p.done("post_stop_no_new_messages") {
		var count int
		err := p.store.Pool.QueryRow(ctx, "SELECT count(*) FROM messages WHERE room_id=$1", rc.RoomID).Scan(&count)
		if err = p.record("post_stop_no_new_messages", 0, "", 0, err == nil && count == 1); err != nil {
			return err
		}
	}
	f.Completed = true
	return p.save()
}
func stoppedResponse(b []byte) bool {
	var v struct {
		Code string `json:"code"`
	}
	return json.Unmarshal(b, &v) == nil && v.Code == "scope_stopped"
}
func (p *probe) targetRemainsActive(ctx context.Context, name string) error {
	if p.done(name) {
		return nil
	}
	var stopped bool
	var epoch int64
	err := p.store.Pool.QueryRow(ctx, "SELECT stopped,scope_epoch FROM rooms WHERE id=$1", p.fixture.Target.ID).Scan(&stopped, &epoch)
	return p.record(name, 0, "", 0, err == nil && !stopped && epoch == p.fixture.Target.ScopeEpoch)
}
func equalJSON(a, b []byte) bool {
	var av, bv any
	return json.Unmarshal(a, &av) == nil && json.Unmarshal(b, &bv) == nil && reflect.DeepEqual(av, bv)
}
func (p *probe) snapshot(ctx context.Context, dir string) error {
	f := p.fixture
	passed := 0
	for _, c := range f.Checks {
		if c.Passed {
			passed++
		}
	}
	r := map[string]any{"schema": "renji.execution.synthetic.receipt.v1", "at": time.Now().UTC(), "fixture_run_id": f.RunID, "prepared": f.Prepared, "completed": f.Completed, "agent_id": f.AgentID, "source_room_id": f.Source.ID, "checks_passed": passed, "checks": f.Checks, "bootstrap": "test-admin-store-cli", "clerk_human_login_verified": false, "external_transport_sent": false}
	if f.Target != nil {
		r["target_room_id"] = f.Target.ID
	}
	if f.Binding != nil {
		r["executor_id"] = f.Binding.ExecutorID
	}
	if f.Child != nil {
		r["run_id"] = f.Child.Context.RunID
	}
	if f.Receipt != nil {
		r["action_receipt"] = f.Receipt
	}
	if f.Stopped != nil {
		r["stopped_source_epoch"] = f.Stopped.ScopeEpoch
	}
	if f.Resumed != nil {
		r["resumed_source_epoch"] = f.Resumed.ScopeEpoch
	}
	db, err := p.databaseReadback(ctx)
	if err != nil {
		return err
	}
	r["database_readback"] = db
	if persist(filepath.Join(dir, "execution-gateway-readback-v1.json"), r) != nil {
		return errors.New("readback_save_failed")
	}
	return json.NewEncoder(os.Stdout).Encode(r)
}

func (p *probe) databaseReadback(ctx context.Context) (map[string]any, error) {
	f := p.fixture
	out := map[string]any{}
	for name, id := range map[string]string{"source": f.Source.ID, "target": func() string {
		if f.Target != nil {
			return f.Target.ID
		}
		return ""
	}()} {
		if id == "" {
			continue
		}
		var stopped bool
		var epoch, version int64
		if p.store.Pool.QueryRow(ctx, "SELECT stopped,scope_epoch,version FROM rooms WHERE id=$1", id).Scan(&stopped, &epoch, &version) != nil {
			return nil, errors.New("scope_readback_failed")
		}
		out[name] = map[string]any{"room_id": id, "stopped": stopped, "scope_epoch": epoch, "version": version}
	}
	var previousDelivered int
	if p.store.Pool.QueryRow(ctx, "SELECT count(*) FROM transport_outbox o JOIN events e ON e.id=o.event_id WHERE e.room_id=$1 AND o.status='delivered'", f.Source.ID).Scan(&previousDelivered) != nil {
		return nil, errors.New("original_transport_readback_failed")
	}
	out["original_room_delivered_outbox"] = previousDelivered
	if f.Target != nil && f.Child != nil {
		var messages, actions int
		if p.store.Pool.QueryRow(ctx, "SELECT (SELECT count(*) FROM messages WHERE room_id=$1),(SELECT count(*) FROM execution_actions WHERE run_id=$2)", f.Target.ID, f.Child.Context.RunID).Scan(&messages, &actions) != nil {
			return nil, errors.New("message_readback_failed")
		}
		out["target_message_count"] = messages
		out["execution_action_count"] = actions
		rows, err := p.store.Pool.Query(ctx, `SELECT o.id,e.type,o.status,o.attempts,coalesce(o.execution_run_id::text,'') FROM transport_outbox o JOIN events e ON e.id=o.event_id WHERE e.room_id=$1 ORDER BY o.id`, f.Target.ID)
		if err != nil {
			return nil, errors.New("target_transport_readback_failed")
		}
		defer rows.Close()
		type item struct {
			ID       int64  `json:"id"`
			Type     string `json:"type"`
			Status   string `json:"status"`
			Attempts int    `json:"attempts"`
			RunID    string `json:"execution_run_id,omitempty"`
		}
		items := []item{}
		for rows.Next() {
			var i item
			if rows.Scan(&i.ID, &i.Type, &i.Status, &i.Attempts, &i.RunID) != nil {
				return nil, errors.New("target_transport_readback_failed")
			}
			items = append(items, i)
		}
		if rows.Err() != nil {
			return nil, errors.New("target_transport_readback_failed")
		}
		out["target_outbox"] = items
	}
	return out, nil
}
func loadConfig(dir string) (map[string]string, error) {
	wanted := map[string]bool{"RENJI_DATABASE_URL": true, "CLERK_ISSUER": true, "CLERK_WORKER_MACHINE_ID": true, "RENJI_GATEWAY_TOKEN": true}
	out := map[string]string{}
	for _, name := range []string{"api.env", "clerk.env", "clerk-worker.env"} {
		f, err := os.Open(filepath.Join(dir, name))
		if err != nil {
			return nil, err
		}
		s := bufio.NewScanner(f)
		for s.Scan() {
			line := strings.TrimSpace(s.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			key, val, ok := strings.Cut(strings.TrimPrefix(line, "export "), "=")
			key = strings.TrimSpace(key)
			if !ok || !wanted[key] {
				continue
			}
			val = strings.TrimSpace(val)
			if strings.HasPrefix(val, "\"") {
				val, err = strconv.Unquote(val)
				if err != nil {
					f.Close()
					return nil, err
				}
			} else if strings.HasPrefix(val, "'") && strings.HasSuffix(val, "'") {
				val = val[1 : len(val)-1]
			}
			out[key] = val
		}
		err = s.Err()
		f.Close()
		if err != nil {
			return nil, err
		}
	}
	for key := range wanted {
		if out[key] == "" {
			return nil, errors.New("configuration missing")
		}
	}
	if !strings.HasPrefix(out["CLERK_WORKER_MACHINE_ID"], "mch_") || !strings.HasPrefix(out["RENJI_GATEWAY_TOKEN"], "mt_") {
		return nil, errors.New("machine configuration invalid")
	}
	return out, nil
}
func digest(v string) string { h := sha256.Sum256([]byte(v)); return hex.EncodeToString(h[:]) }
func persist(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".execution-probe-*")
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
