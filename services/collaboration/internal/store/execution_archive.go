package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/jackc/pgx/v5"
)

const ExecutionArchiveRenderer = "renji-run-markdown-v1"
const archiveChunkBytes = 200000

type ExecutionArchivePart struct {
	Part                int    `json:"part"`
	Title               string `json:"title"`
	Content             string `json:"content,omitempty"`
	ContentHash         string `json:"content_hash"`
	State               string `json:"state"`
	ExternalID          string `json:"external_id,omitempty"`
	ObservedContentHash string `json:"observed_content_hash,omitempty"`
	ObservedTitleHash   string `json:"observed_title_hash,omitempty"`
	ErrorCode           string `json:"error_code,omitempty"`
	Attempts            int    `json:"attempts"`
}
type ExecutionArchive struct {
	ID              string                 `json:"id"`
	RunID           string                 `json:"run_id"`
	Through         int64                  `json:"through"`
	TargetBinding   string                 `json:"target_binding"`
	Renderer        string                 `json:"renderer"`
	VerifiedThrough int64                  `json:"verified_through"`
	ManifestHash    string                 `json:"manifest_hash"`
	Parts           []ExecutionArchivePart `json:"parts"`
}

// The credential/endpoint/target ACL belong to a privileged adapter config;
// TargetBinding is its stable non-secret ID, never a caller-selected URL.
type ExecutionArchiveClaim struct {
	ArchiveID      string               `json:"archive_id"`
	RunID          string               `json:"run_id"`
	TargetBinding  string               `json:"target_binding"`
	Token          string               `json:"-"`
	LeaseExpiresAt time.Time            `json:"lease_expires_at"`
	WriteAllowed   bool                 `json:"write_allowed"`
	ReconcileOnly  bool                 `json:"reconcile_only"`
	Part           ExecutionArchivePart `json:"part"`
}
type ExecutionArchiveObservation struct {
	ExternalID  string
	ContentHash string
	TitleHash   string
	ErrorCode   string
}

func archiveHash(v []byte) string { h := sha256.Sum256(v); return hex.EncodeToString(h[:]) }
func archiveBindingValid(v string) bool {
	if v == "" || len(v) > 200 {
		return false
	}
	for _, r := range v {
		if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || strings.ContainsRune("._:/-", r)) {
			return false
		}
	}
	return true
}
func archiveFence(v string) string {
	longest := func(marker rune) int {
		max, n := 0, 0
		for _, r := range v {
			if r == marker {
				n++
				if n > max {
					max = n
				}
			} else {
				n = 0
			}
		}
		return max
	}
	marker := "`"
	n := longest('`')
	if tilde := longest('~'); tilde < n {
		marker = "~"
		n = tilde
	}
	if n < 2 {
		n = 2
	}
	return strings.Repeat(marker, n+1)
}

// The source is canonical persisted JSON, not prose that could forge receipts.
// Long events are split into numbered UTF-8 chunks without dropping any byte.
func archiveChunks(v string) []string {
	out := []string{}
	for len(v) > archiveChunkBytes {
		n := archiveChunkBytes
		for n > 0 && !utf8.RuneStart(v[n]) {
			n--
		}
		out = append(out, v[:n])
		v = v[n:]
	}
	out = append(out, v)
	return out
}
func renderExecutionArchive(run ExecutionRun, through int64, entries []ExecutionEvidenceEntry) ([]ExecutionArchivePart, error) {
	runJSON, err := json.MarshalIndent(run, "", "  ")
	if err != nil {
		return nil, err
	}
	sections := []string{}
	add := func(label string, raw []byte) {
		v := string(raw)
		chunks := archiveChunks(v)
		for i, chunk := range chunks {
			f := archiveFence(chunk)
			sections = append(sections, fmt.Sprintf("## %s · 原始 JSON 分片 %d/%d\n\n分片按序直接拼接还原完整 JSON；整项 SHA-256：`%s`。\n\n%sjson\n%s\n%s\n", label, i+1, len(chunks), archiveHash(raw), f, chunk, f))
		}
	}
	add("Run 元数据（本次归档快照）", runJSON)
	for _, entry := range entries {
		raw, err := json.MarshalIndent(entry, "", "  ")
		if err != nil {
			return nil, err
		}
		label := "执行器提交的原始事件（模型文字不构成外部成功）"
		switch entry.Kind {
		case "action":
			label = "服务端已提交动作及真实业务回执（不等于运输已送达）"
		case "transport":
			label = "融云 Outbox 运输事实（pending/unknown 不表示送达）"
		case "run.status":
			label = "服务端 Run 状态变更"
		}
		add(fmt.Sprintf("证据 #%d · %s", entry.Seq, label), raw)
	}
	parts := make([]ExecutionArchivePart, 0, len(sections))
	// Each independently readable document stays well below source/provider limits.
	for _, section := range sections {
		if len(parts) == 0 || len(parts[len(parts)-1].Content)+len(section) > 500000 {
			n := len(parts) + 1
			title := fmt.Sprintf("人机执行档案 · %s · 游标 %d · %d", run.Context.RunID, through, n)
			preface := fmt.Sprintf("# %s\n\n这是持久事实档案。模型输出、Agent 输出与工具文字属于执行器报告；只有动作账本证明本地提交，只有运输回执证明实际外发。unknown 保持未知，不以文字代替回执。\n\nRun：`%s`；归档至证据游标：`%d`；渲染契约：`%s`。完整来源范围见 Run 元数据；读取权限必须满足所有来源。\n\n", title, run.Context.RunID, through, ExecutionArchiveRenderer)
			parts = append(parts, ExecutionArchivePart{Part: n, Title: title, Content: preface, State: "prepared"})
		}
		parts[len(parts)-1].Content += section + "\n"
	}
	for i := range parts {
		// Doc Free trims terminal LF at its write boundary. Generated closing
		// fences end every part, so remove only template terminal LF here.
		parts[i].Content = strings.TrimRight(parts[i].Content, "\n")
		parts[i].ContentHash = archiveHash([]byte(parts[i].Content))
	}
	return parts, nil
}

// Prepare freezes a complete evidence prefix and its deterministic Markdown.
// No network effect occurs. Repeating the same run/cursor/target returns the
// original durable intention, including unknown parts and their external IDs.
func (s *Store) PrepareExecutionArchive(ctx context.Context, reader EvidenceReader, runID, targetBinding string) (ExecutionArchive, error) {
	var out ExecutionArchive
	if !archiveBindingValid(targetBinding) {
		return out, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	run, actor, err := evidenceAccess(ctx, tx, reader, runID, "audit")
	if err != nil {
		return out, err
	}
	var through int64
	if err = tx.QueryRow(ctx, "SELECT evidence_seq FROM execution_runs WHERE id=$1", runID).Scan(&through); err != nil {
		return out, err
	}
	var existing string
	// An unresolved earlier snapshot cannot be bypassed by advancing the run
	// cursor and constructing another document under a new intention.
	err = tx.QueryRow(ctx, `SELECT a.id::text FROM execution_archives a WHERE a.run_id=$1 AND a.target_binding=$2 AND EXISTS(SELECT 1 FROM execution_archive_parts p WHERE p.archive_id=a.id AND p.state<>'verified') ORDER BY a.through_seq,a.id LIMIT 1`, runID, targetBinding).Scan(&existing)
	if err == nil {
		out, err = readArchiveTx(ctx, tx, existing, false)
		if err != nil {
			return out, err
		}
		return out, tx.Commit(ctx)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return out, err
	}
	err = tx.QueryRow(ctx, `SELECT id::text FROM execution_archives WHERE run_id=$1 AND through_seq=$2 AND target_binding=$3 AND renderer_version=$4`, runID, through, targetBinding, ExecutionArchiveRenderer).Scan(&existing)
	if err == nil {
		out, err = readArchiveTx(ctx, tx, existing, false)
		if err != nil {
			return out, err
		}
		return out, tx.Commit(ctx)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return out, err
	}
	rows, err := tx.Query(ctx, `SELECT seq,kind,object_id,data,recorded_at,legacy_snapshot FROM execution_evidence_entries WHERE run_id=$1 AND seq<=$2 ORDER BY seq`, runID, through)
	if err != nil {
		return out, err
	}
	entries := []ExecutionEvidenceEntry{}
	size := 0
	for rows.Next() {
		var e ExecutionEvidenceEntry
		if err = rows.Scan(&e.Seq, &e.Kind, &e.ObjectID, &e.Data, &e.RecordedAt, &e.LegacySnapshot); err != nil {
			rows.Close()
			return out, err
		}
		e.Data, err = executionJSON(e.Data)
		if err != nil {
			rows.Close()
			return out, err
		}
		size += len(e.Data)
		if size > 64000000 {
			rows.Close()
			return out, domain.ErrInvalid
		}
		entries = append(entries, e)
	}
	if err = rows.Err(); err != nil {
		rows.Close()
		return out, err
	}
	rows.Close()
	parts, err := renderExecutionArchive(run, through, entries)
	if err != nil {
		return out, err
	}
	manifest := make([]string, 0, len(parts))
	for _, part := range parts {
		manifest = append(manifest, part.ContentHash)
	}
	rawManifest, _ := json.Marshal(manifest)
	out = ExecutionArchive{VerifiedThrough: -1, ID: uuid.NewString(), RunID: runID, Through: through, TargetBinding: targetBinding, Renderer: ExecutionArchiveRenderer, ManifestHash: archiveHash(rawManifest), Parts: parts}
	rawRun, _ := json.Marshal(run)
	if _, err = tx.Exec(ctx, `INSERT INTO execution_archives(id,run_id,through_seq,target_binding,renderer_version,run_snapshot,manifest_hash,prepared_by) VALUES($1,$2,$3,$4,$5,$6,$7,$8)`, out.ID, runID, through, targetBinding, ExecutionArchiveRenderer, rawRun, out.ManifestHash, actor); err != nil {
		return out, err
	}
	for _, part := range parts {
		if _, err = tx.Exec(ctx, `INSERT INTO execution_archive_parts(archive_id,part,title,content,content_hash) VALUES($1,$2,$3,$4,$5)`, out.ID, part.Part, part.Title, part.Content, part.ContentHash); err != nil {
			return out, err
		}
	}
	if _, err = tx.Exec(ctx, `INSERT INTO execution_archive_cursors(run_id,target_binding) VALUES($1,$2) ON CONFLICT DO NOTHING`, runID, targetBinding); err != nil {
		return out, err
	}
	out, err = readArchiveTx(ctx, tx, out.ID, false)
	if err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}
func readArchiveTx(ctx context.Context, tx pgx.Tx, id string, content bool) (ExecutionArchive, error) {
	var out ExecutionArchive
	err := tx.QueryRow(ctx, `SELECT a.id::text,a.run_id::text,a.through_seq,a.target_binding,a.renderer_version,a.manifest_hash,coalesce(c.verified_through,-1) FROM execution_archives a LEFT JOIN execution_archive_cursors c ON c.run_id=a.run_id AND c.target_binding=a.target_binding WHERE a.id=$1`, id).Scan(&out.ID, &out.RunID, &out.Through, &out.TargetBinding, &out.Renderer, &out.ManifestHash, &out.VerifiedThrough)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, domain.ErrForbidden
	}
	if err != nil {
		return out, err
	}
	rows, err := tx.Query(ctx, `SELECT part,title,CASE WHEN $2 THEN content ELSE '' END,content_hash,state,external_id,observed_content_hash,observed_title_hash,error_code,attempts FROM execution_archive_parts WHERE archive_id=$1 ORDER BY part`, id, content)
	if err != nil {
		return out, err
	}
	defer rows.Close()
	out.Parts = []ExecutionArchivePart{}
	for rows.Next() {
		var p ExecutionArchivePart
		if err = rows.Scan(&p.Part, &p.Title, &p.Content, &p.ContentHash, &p.State, &p.ExternalID, &p.ObservedContentHash, &p.ObservedTitleHash, &p.ErrorCode, &p.Attempts); err != nil {
			return out, err
		}
		if !content {
			p.Content = ""
		}
		out.Parts = append(out.Parts, p)
	}
	return out, rows.Err()
}
func (s *Store) ReadExecutionArchive(ctx context.Context, reader EvidenceReader, id string) (ExecutionArchive, error) {
	var out ExecutionArchive
	if !executionUUIDs(id) {
		return out, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	// Read no frozen body before rechecking current all-source permission.
	var runID string
	err = tx.QueryRow(ctx, "SELECT run_id::text FROM execution_archives WHERE id=$1", id).Scan(&runID)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, domain.ErrForbidden
	}
	if err != nil {
		return out, err
	}
	if _, _, err = evidenceAccess(ctx, tx, reader, runID, "audit"); err != nil {
		return out, err
	}
	out, err = readArchiveTx(ctx, tx, id, false)
	if err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}

// Claim authorizes exactly one first write. Expired/in-flight/unknown outcomes
// are read-only reconciliation; even a missing external ID never permits create.
func (s *Store) ClaimExecutionArchivePart(ctx context.Context, reader EvidenceReader, id string, part int) (ExecutionArchiveClaim, error) {
	var out ExecutionArchiveClaim
	if !executionUUIDs(id) || part < 1 {
		return out, domain.ErrInvalid
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	err = tx.QueryRow(ctx, "SELECT run_id::text,target_binding FROM execution_archives WHERE id=$1", id).Scan(&out.RunID, &out.TargetBinding)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, domain.ErrForbidden
	}
	if err != nil {
		return out, err
	}
	if _, _, err = evidenceAccess(ctx, tx, reader, out.RunID, "audit"); err != nil {
		return out, err
	}
	out.ArchiveID = id
	out.Part.Part = part
	var token *string
	var lease *time.Time
	var activeLease bool
	err = tx.QueryRow(ctx, `SELECT title,content,content_hash,state,external_id,observed_content_hash,observed_title_hash,error_code,attempts,claim_token::text,lease_expires_at,coalesce(lease_expires_at>clock_timestamp(),false) FROM execution_archive_parts WHERE archive_id=$1 AND part=$2 FOR UPDATE`, id, part).Scan(&out.Part.Title, &out.Part.Content, &out.Part.ContentHash, &out.Part.State, &out.Part.ExternalID, &out.Part.ObservedContentHash, &out.Part.ObservedTitleHash, &out.Part.ErrorCode, &out.Part.Attempts, &token, &lease, &activeLease)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, domain.ErrForbidden
	}
	if err != nil {
		return out, err
	}
	if out.Part.State == "prepared" {
		out.Token = uuid.NewString()
		out.WriteAllowed = true
		out.Part.State = "in_flight"
		out.Part.Attempts++
		err = tx.QueryRow(ctx, `UPDATE execution_archive_parts SET state='in_flight',claim_token=$3,lease_expires_at=clock_timestamp()+interval '2 minutes',attempts=attempts+1,updated_at=clock_timestamp() WHERE archive_id=$1 AND part=$2 RETURNING lease_expires_at`, id, part, out.Token).Scan(&out.LeaseExpiresAt)
	} else {
		out.ReconcileOnly = true
		// A concurrent owner retains its secret claim. A later reconcile obtains a
		// fresh token only once its lease expires, fencing delayed old observations.
		if out.Part.State != "verified" && activeLease {
			return ExecutionArchiveClaim{}, domain.ErrConflict
		}
		if out.Part.State != "verified" {
			out.Token = uuid.NewString()
			out.Part.State = "unknown"
			err = tx.QueryRow(ctx, `UPDATE execution_archive_parts SET state='unknown',claim_token=$3,lease_expires_at=clock_timestamp()+interval '2 minutes',updated_at=clock_timestamp() WHERE archive_id=$1 AND part=$2 RETURNING lease_expires_at`, id, part, out.Token).Scan(&out.LeaseExpiresAt)
		}
	}
	if err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}

// Validate immediately before the adapter's external request. To avoid a
// check/write race the adapter must run its bounded request in WithArchiveClaim.
func (s *Store) WithExecutionArchiveClaim(ctx context.Context, reader EvidenceReader, claim ExecutionArchiveClaim, readOnly bool, fn func(context.Context, ExecutionArchiveClaim) error) error {
	return s.WithExecutionArchiveAudience(ctx, reader, claim, nil, readOnly, fn)
}
func (s *Store) WithExecutionArchiveAudience(ctx context.Context, reader EvidenceReader, claim ExecutionArchiveClaim, audience []string, readOnly bool, fn func(context.Context, ExecutionArchiveClaim) error) error {
	if fn == nil || !executionUUIDs(claim.ArchiveID, claim.Token) {
		return domain.ErrInvalid
	}
	authorize := func(tx pgx.Tx, reserve bool) (ExecutionArchiveClaim, error) {
		var runID, binding string
		err := tx.QueryRow(ctx, "SELECT run_id::text,target_binding FROM execution_archives WHERE id=$1", claim.ArchiveID).Scan(&runID, &binding)
		if err != nil {
			return claim, domain.ErrForbidden
		}
		run, _, accessErr := evidenceAccess(ctx, tx, reader, runID, "audit")
		if accessErr != nil {
			return claim, accessErr
		}
		if err = lockArchiveAudience(ctx, tx, run, audience); err != nil {
			return claim, err
		}
		var state, external, content, title, hash string
		var active, started bool
		err = tx.QueryRow(ctx, `SELECT state,external_id,content,title,content_hash,coalesce(claim_token=$3 AND lease_expires_at>clock_timestamp(),false),request_started_at IS NOT NULL FROM execution_archive_parts WHERE archive_id=$1 AND part=$2 FOR UPDATE`, claim.ArchiveID, claim.Part.Part, claim.Token).Scan(&state, &external, &content, &title, &hash, &active, &started)
		if err != nil {
			return claim, err
		}
		if !active || binding != claim.TargetBinding || runID != claim.RunID {
			return claim, domain.ErrConflict
		}
		if !readOnly && (state != "in_flight" || !claim.WriteAllowed || external != "" || (reserve && started)) {
			return claim, domain.ErrConflict
		}
		if readOnly && external == "" {
			return claim, domain.ErrConflict
		}
		if reserve {
			if _, err = tx.Exec(ctx, `UPDATE execution_archive_parts SET request_started_at=clock_timestamp() WHERE archive_id=$1 AND part=$2`, claim.ArchiveID, claim.Part.Part); err != nil {
				return claim, err
			}
		}
		claim.Part.Content = content
		claim.Part.Title = title
		claim.Part.ContentHash = hash
		claim.Part.ExternalID = external
		return claim, nil
	}
	// Persist the one-time request marker before the network call. A crash even
	// before dispatch conservatively becomes unknown, never permission to retry.
	if !readOnly {
		tx, err := s.Pool.Begin(ctx)
		if err != nil {
			return err
		}
		_, err = authorize(tx, true)
		if err != nil {
			tx.Rollback(ctx)
			return err
		}
		if err = tx.Commit(ctx); err != nil {
			return err
		}
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	trusted, err := authorize(tx, false)
	if err != nil {
		return err
	}
	bounded, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if err = fn(bounded, trusted); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Only a trusted adapter calls this with a provider's actual ID/readback hashes.
// No HTTP/MCP request exposes it. The token permits recording an in-flight fact
// after source revocation, but returns no document body and grants no new write.
func (s *Store) RecordExecutionArchiveObservation(ctx context.Context, claim ExecutionArchiveClaim, observation ExecutionArchiveObservation) error {
	if !executionUUIDs(claim.ArchiveID, claim.Token) || claim.Part.Part < 1 || len(observation.ExternalID) > 160 || strings.ContainsAny(observation.ExternalID, "\r\n\x00") || len(observation.ErrorCode) > 100 {
		return domain.ErrInvalid
	}
	if observation.ContentHash != "" && !validExecutionID(observation.ContentHash) || observation.TitleHash != "" && !validExecutionID(observation.TitleHash) {
		return domain.ErrInvalid
	}
	for _, r := range observation.ErrorCode {
		if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '_') {
			return domain.ErrInvalid
		}
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	// Serialize part completions so the final part observes every committed
	// sibling and advances the cursor even under simultaneous readbacks.
	var archiveID string
	if err = tx.QueryRow(ctx, "SELECT id::text FROM execution_archives WHERE id=$1 FOR UPDATE", claim.ArchiveID).Scan(&archiveID); err != nil {
		return err
	}
	var expected, title, external, state, token string
	err = tx.QueryRow(ctx, `SELECT content_hash,title,external_id,state,coalesce(claim_token::text,'') FROM execution_archive_parts WHERE archive_id=$1 AND part=$2 FOR UPDATE`, claim.ArchiveID, claim.Part.Part).Scan(&expected, &title, &external, &state, &token)
	if err != nil {
		return err
	}
	if token != claim.Token {
		return domain.ErrConflict
	}
	if external != "" && observation.ExternalID != "" && external != observation.ExternalID {
		return domain.ErrConflict
	}
	if observation.ExternalID != "" {
		external = observation.ExternalID
	}
	verified := external != "" && observation.ContentHash == expected && observation.TitleHash == archiveHash([]byte(title)) && observation.ErrorCode == ""
	next := "unknown"
	code := observation.ErrorCode
	if verified {
		next = "verified"
	} else if code == "" {
		code = "readback_required"
	}
	if state == "verified" && !verified {
		return domain.ErrConflict
	}
	if _, err = tx.Exec(ctx, `UPDATE execution_archive_parts SET state=$3,external_id=$4,observed_content_hash=$5,observed_title_hash=$6,error_code=$7,lease_expires_at=NULL,updated_at=clock_timestamp() WHERE archive_id=$1 AND part=$2`, claim.ArchiveID, claim.Part.Part, next, external, observation.ContentHash, observation.TitleHash, code); err != nil {
		return err
	}
	if verified {
		_, err = tx.Exec(ctx, `UPDATE execution_archive_cursors c SET verified_through=a.through_seq,archive_id=a.id,updated_at=clock_timestamp() FROM execution_archives a WHERE a.id=$1 AND c.run_id=a.run_id AND c.target_binding=a.target_binding AND c.verified_through<a.through_seq AND NOT EXISTS(SELECT 1 FROM execution_archive_parts p WHERE p.archive_id=a.id AND p.state<>'verified')`, claim.ArchiveID)
		if err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}
