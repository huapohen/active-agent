package runarchive

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/huapohen/active-agent/services/collaboration/internal/auth"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
)

type Runner struct {
	config       Config
	store        *store.Store
	verifier     auth.MachineVerifier
	machineToken string
	getenv       func(string) string
}
type Result struct {
	At        time.Time              `json:"at"`
	Mode      string                 `json:"mode"`
	Status    string                 `json:"status"`
	Archive   store.ExecutionArchive `json:"archive"`
	ErrorCode string                 `json:"error_code,omitempty"`
}

func New(c Config, s *store.Store, v auth.MachineVerifier, getenv func(string) string) (*Runner, error) {
	if err := c.Validate(); err != nil {
		return nil, err
	}
	if s == nil || v == nil || getenv == nil {
		return nil, Failure("archive_dependencies_missing")
	}
	token := getenv(c.Clerk.TokenEnv)
	if token == "" {
		return nil, Failure("machine_credential_missing")
	}
	return &Runner{config: c, store: s, verifier: v, machineToken: token, getenv: getenv}, nil
}
func (r *Runner) authenticate(ctx context.Context) (store.EvidenceReader, error) {
	m, err := r.verifier.VerifyMachine(ctx, r.machineToken)
	if err != nil || m.Issuer != r.config.Clerk.Issuer || m.Audience != r.config.Clerk.ReceiverMachineID || m.ExpiresAt == nil || !m.ExpiresAt.After(time.Now()) {
		return store.EvidenceReader{}, Failure("machine_authentication_failed")
	}
	return store.EvidenceReader{MachineIssuer: m.Issuer, MachineSubject: m.MachineSubject}, nil
}

type docClient struct {
	base, room, principal, token string
	client                       *http.Client
}

func newDocClient(t TargetConfig, token string) (*docClient, error) {
	if token == "" || strings.ContainsAny(token, "\r\n") {
		return nil, Failure("doc_free_credential_missing")
	}
	u, _ := url.Parse(t.DocFreeEndpoint)
	tr := http.DefaultTransport.(*http.Transport).Clone()
	ip := net.ParseIP(u.Hostname())
	if u.Hostname() == "localhost" || ip != nil && ip.IsLoopback() {
		tr.Proxy = nil
	}
	return &docClient{base: strings.TrimRight(t.DocFreeEndpoint, "/"), room: t.DocFreeRoomID, principal: t.DocFreePrincipalID, token: token, client: &http.Client{Timeout: 12 * time.Second, Transport: tr, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}
func (d *docClient) call(ctx context.Context, method, path string, input, result any) error {
	var body io.Reader
	if input != nil {
		raw, err := json.Marshal(input)
		if err != nil {
			return Failure("invalid_doc_free_request")
		}
		body = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, d.base+path, body)
	if err != nil {
		return Failure("invalid_doc_free_request")
	}
	req.Header.Set("Authorization", "Bearer "+d.token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	resp, err := d.client.Do(req)
	if err != nil {
		return Failure("doc_free_transport_unknown")
	}
	defer resp.Body.Close()
	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		return Failure("doc_free_access_denied")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return Failure("doc_free_http_failure")
	}
	// A room detail includes existing document bodies. Bound the complete response
	// rather than treating a truncated member list as the actual audience.
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 32000001))
	if err != nil || len(raw) > 32000000 {
		return Failure("invalid_doc_free_response")
	}
	if json.Unmarshal(raw, result) != nil {
		return Failure("invalid_doc_free_response")
	}
	return nil
}
func (d *docClient) docPath(id string) string {
	return "/api/im/rooms/" + url.PathEscape(d.room) + "/documents" + func() string {
		if id != "" {
			return "/" + url.PathEscape(id)
		}
		return ""
	}()
}

type doc struct {
	ID          string  `json:"id"`
	Title       string  `json:"title"`
	Content     *string `json:"content"`
	Revision    int64   `json:"revision"`
	ContentHash string  `json:"content_hash"`
}

func (d *docClient) read(ctx context.Context, id string) (doc, error) {
	var reply struct {
		Document doc `json:"document"`
	}
	if !safeID(id) {
		return doc{}, Failure("invalid_external_id")
	}
	err := d.call(ctx, "GET", d.docPath(id), nil, &reply)
	if err != nil {
		return doc{}, err
	}
	x := reply.Document
	if x.ID != id || x.Content == nil || x.Revision < 1 || Hash([]byte(*x.Content)) != x.ContentHash {
		return doc{}, Failure("invalid_doc_free_document")
	}
	return x, nil
}
func (d *docClient) create(ctx context.Context, p store.ExecutionArchivePart) (string, error) {
	var reply struct {
		Document doc `json:"document"`
	}
	err := d.call(ctx, "POST", d.docPath(""), map[string]string{"title": p.Title, "content": p.Content}, &reply)
	if err != nil {
		return "", err
	}
	if !safeID(reply.Document.ID) {
		return "", Failure("create_id_unknown")
	}
	return reply.Document.ID, nil
}
func (r *Runner) fresh(ctx context.Context, expected store.EvidenceReader) (store.EvidenceReader, error) {
	reader, err := r.authenticate(ctx)
	if err != nil {
		return reader, err
	}
	if reader != expected {
		return reader, Failure("machine_identity_changed")
	}
	return reader, nil
}
func (r *Runner) preflight(ctx context.Context, expected store.EvidenceReader, runID string, t TargetConfig, d *docClient, audience []string) error {
	reader, err := r.fresh(ctx, expected)
	if err != nil {
		return err
	}
	var me struct {
		Principal struct {
			ID   string `json:"id"`
			Kind string `json:"kind"`
		} `json:"principal"`
	}
	if err = r.store.WithExecutionArchiveSource(ctx, reader, runID, audience, func(c context.Context) error { return d.call(c, "GET", "/api/im/me", nil, &me) }); err != nil {
		return err
	}
	if me.Principal.ID != d.principal || me.Principal.Kind != "agent" {
		return Failure("doc_free_identity_mismatch")
	}
	reader, err = r.fresh(ctx, expected)
	if err != nil {
		return err
	}
	var detail struct {
		Room struct {
			ID string `json:"id"`
		} `json:"room"`
		Members []struct {
			PrincipalID string `json:"principal_id"`
			Kind        string `json:"kind"`
			Disabled    bool   `json:"disabled"`
		} `json:"members"`
	}
	if err = r.store.WithExecutionArchiveSource(ctx, reader, runID, audience, func(c context.Context) error {
		return d.call(c, "GET", "/api/im/rooms/"+url.PathEscape(d.room), nil, &detail)
	}); err != nil {
		return err
	}
	if detail.Room.ID != d.room || len(detail.Members) == 0 || len(detail.Members) > len(t.PrincipalMappings) {
		return Failure("doc_free_audience_mismatch")
	}
	allowed := map[string]bool{}
	for _, m := range t.PrincipalMappings {
		allowed[m.DocFreePrincipalID] = true
	}
	seen := map[string]bool{}
	writer := false
	for _, m := range detail.Members {
		if !allowed[m.PrincipalID] || seen[m.PrincipalID] || m.Disabled {
			return Failure("doc_free_audience_mismatch")
		}
		seen[m.PrincipalID] = true
		writer = writer || m.PrincipalID == d.principal
	}
	if !writer {
		return Failure("doc_free_writer_missing")
	}
	return nil
}
func (r *Runner) Run(ctx context.Context, runID string) (out Result, runErr error) {
	out = Result{At: time.Now().UTC(), Mode: "single_source_synthetic", Status: "not_started"}
	var authenticatedReader store.EvidenceReader
	defer func() {
		if runErr != nil {
			out.Status = "requires_attention"
			out.ErrorCode = Code(runErr)
			if out.Archive.ID != "" {
				// Return durable unknown/current state, not the pre-dispatch prepared
				// snapshot. Revocation or expired credentials suppress this extra read.
				archiveID := out.Archive.ID
				out.Archive = store.ExecutionArchive{ID: archiveID, RunID: runID}
				c, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
				defer cancel()
				if reader, e := r.fresh(c, authenticatedReader); e == nil {
					if current, e := r.store.ReadExecutionArchive(c, reader, archiveID); e == nil {
						out.Archive = current
					}
				}
			}
		}
	}()
	if !r.config.Enabled {
		return out, Failure("run_archive_disabled")
	}
	reader, err := r.authenticate(ctx)
	if err != nil {
		return out, err
	}
	authenticatedReader = reader
	page, err := r.store.ReadExecutionEvidence(ctx, reader, runID, store.EvidenceQuery{Limit: 1, Mode: "audit"})
	if err != nil {
		return out, err
	}
	run := page.Run
	if len(run.Context.OriginScopes) != 0 {
		return out, Failure("multi_source_archive_not_supported")
	}
	b, err := r.store.ResolveExecutor(ctx, reader.MachineIssuer, reader.MachineSubject)
	if err != nil {
		return out, err
	}
	if run.Context.ExecutorID != b.ExecutorID || run.Context.PrincipalID != b.Principal.ID {
		return out, Failure("archive_executor_mismatch")
	}
	var target *TargetConfig
	for i := range r.config.Targets {
		t := &r.config.Targets[i]
		if t.SourceRoomID == run.Context.RoomID && t.WorkspaceID == run.WorkspaceID {
			target = t
			break
		}
	}
	if target == nil {
		return out, Failure("source_room_not_allowlisted")
	}
	t := *target
	audience := []string{}
	writerMapped := false
	for _, m := range t.PrincipalMappings {
		audience = append(audience, m.GoPrincipalID)
		if m.DocFreePrincipalID == t.DocFreePrincipalID && m.GoPrincipalID == b.Principal.ID {
			writerMapped = true
		}
	}
	if !writerMapped {
		return out, Failure("archive_principal_mapping_mismatch")
	}
	d, err := newDocClient(t, r.getenv(t.DocFreeTokenEnv))
	if err != nil {
		return out, err
	}
	if err = r.preflight(ctx, reader, runID, t, d, audience); err != nil {
		return out, err
	}
	if err = r.store.BindExecutionArchiveTarget(ctx, t.BindingID, t.fingerprint()); err != nil {
		return out, err
	}
	out.Archive, err = r.store.PrepareExecutionArchive(ctx, reader, runID, t.BindingID)
	if err != nil {
		return out, err
	}
	for _, part := range out.Archive.Parts {
		if err = r.preflight(ctx, reader, runID, t, d, audience); err != nil {
			return out, err
		}
		if part.State == "verified" {
			currentReader, e := r.fresh(ctx, reader)
			if e != nil {
				return out, e
			}
			var observed doc
			e = r.store.WithExecutionArchiveSource(ctx, currentReader, runID, audience, func(c context.Context) error { var e error; observed, e = d.read(c, part.ExternalID); return e })
			if e != nil {
				return out, e
			}
			if observed.ContentHash != part.ContentHash || Hash([]byte(observed.Title)) != Hash([]byte(part.Title)) {
				return out, Failure("archive_target_changed")
			}
			continue
		}
		if part.State == "unknown" && part.ExternalID == "" {
			// No provider identifier means there is nothing to read. Do not acquire
			// a new lease merely to report an already durable unknown outcome.
			return out, Failure("create_outcome_unknown")
		}
		claim, e := r.store.ClaimExecutionArchivePart(ctx, reader, out.Archive.ID, part.Part)
		if e != nil {
			return out, e
		}
		if claim.WriteAllowed {
			currentReader, e := r.fresh(ctx, reader)
			if e != nil {
				return out, e
			}
			var externalID string
			e = r.store.WithExecutionArchiveAudience(ctx, currentReader, claim, audience, false, func(c context.Context, trusted store.ExecutionArchiveClaim) error {
				var e error
				externalID, e = d.create(c, trusted.Part)
				return e
			})
			observation := store.ExecutionArchiveObservation{ExternalID: externalID}
			if e != nil {
				observation.ErrorCode = Code(e)
			}
			// Record the actual response independently of caller cancellation/revocation.
			saveCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
			saveErr := r.store.RecordExecutionArchiveObservation(saveCtx, claim, observation)
			cancel()
			if saveErr != nil {
				return out, saveErr
			}
			if e != nil {
				return out, e
			}
			claim, e = r.store.ClaimExecutionArchivePart(ctx, reader, out.Archive.ID, part.Part)
			if e != nil {
				return out, e
			}
		}
		if claim.Part.ExternalID == "" {
			return out, Failure("create_outcome_unknown")
		}
		if err = r.preflight(ctx, reader, runID, t, d, audience); err != nil {
			return out, err
		}
		currentReader, e := r.fresh(ctx, reader)
		if e != nil {
			return out, e
		}
		var observed doc
		e = r.store.WithExecutionArchiveAudience(ctx, currentReader, claim, audience, true, func(c context.Context, trusted store.ExecutionArchiveClaim) error {
			var e error
			observed, e = d.read(c, trusted.Part.ExternalID)
			return e
		})
		observation := store.ExecutionArchiveObservation{ExternalID: claim.Part.ExternalID}
		if e != nil {
			observation.ErrorCode = Code(e)
		} else {
			observation.ContentHash = observed.ContentHash
			observation.TitleHash = Hash([]byte(observed.Title))
		}
		saveCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		saveErr := r.store.RecordExecutionArchiveObservation(saveCtx, claim, observation)
		cancel()
		if saveErr != nil {
			return out, saveErr
		}
		if e != nil {
			return out, e
		}
		if observation.ContentHash != claim.Part.ContentHash || observation.TitleHash != Hash([]byte(claim.Part.Title)) {
			return out, Failure("archive_readback_mismatch")
		}
	}
	out.Archive, err = r.store.ReadExecutionArchive(ctx, reader, out.Archive.ID)
	if err != nil {
		return out, err
	}
	for _, p := range out.Archive.Parts {
		if p.State != "verified" {
			return out, Failure("archive_readback_incomplete")
		}
	}
	out.Status = "verified"
	return out, nil
}
