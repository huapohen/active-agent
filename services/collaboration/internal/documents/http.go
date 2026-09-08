package documents

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
)

// HTTP never follows redirects, logs response payloads, or sends credentials to
// a second origin. Plain HTTP is restricted to literal loopback addresses.
type HTTP struct {
	base    string
	client  *http.Client
	headers http.Header
}

func NewHTTP(endpoint string, headers http.Header) (*HTTP, error) {
	u, err := url.Parse(endpoint)
	if err != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Path != "" && u.Path != "/" {
		return nil, Failure("invalid_endpoint")
	}
	host := u.Hostname()
	ip := net.ParseIP(host)
	loopback := host == "localhost" || ip != nil && ip.IsLoopback()
	if u.Scheme != "https" && (u.Scheme != "http" || !loopback) {
		return nil, Failure("https_required")
	}
	if headers == nil {
		headers = make(http.Header)
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	if loopback {
		transport.Proxy = nil
	}
	return &HTTP{base: strings.TrimRight(endpoint, "/"), headers: headers.Clone(), client: &http.Client{Timeout: 15 * time.Second, Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}
func (h *HTTP) JSON(ctx context.Context, method, path string, payload any, result any) error {
	var body io.Reader
	if payload != nil {
		raw, err := json.Marshal(payload)
		if err != nil {
			return Failure("invalid_request")
		}
		body = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, h.base+path, body)
	if err != nil {
		return Failure("invalid_request")
	}
	req.Header = h.headers.Clone()
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	resp, err := h.client.Do(req)
	if err != nil {
		return Failure("transport_outcome_unknown")
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case 401, 403:
		return Failure("access_denied")
	case 404:
		return Failure("not_found")
	case 409:
		return Failure("version_conflict")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return Failure("provider_http_failure")
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 2_000_001))
	if err != nil || len(raw) > 2_000_000 {
		return Failure("invalid_response")
	}
	if err := json.Unmarshal(raw, result); err != nil {
		return Failure("invalid_response")
	}
	return nil
}

type DocFree struct{ HTTP *HTTP }

func NewDocFree(endpoint, token string) (*DocFree, error) {
	if strings.TrimSpace(token) == "" {
		return nil, Failure("credential_missing")
	}
	h, err := NewHTTP(endpoint, http.Header{"Authorization": {"Bearer " + token}})
	return &DocFree{h}, err
}
func (d *DocFree) Read(ctx context.Context, b Binding) (Snapshot, error) {
	var empty Snapshot
	if d.HTTP.base != strings.TrimRight(b.SourceEndpoint, "/") {
		return empty, Failure("source_endpoint_mismatch")
	}
	if err := RequireSafeID(b.RoomID); err != nil {
		return empty, err
	}
	if err := RequireSafeID(b.DocumentID); err != nil {
		return empty, err
	}
	var me struct {
		Principal struct {
			ID string `json:"id"`
		} `json:"principal"`
	}
	if err := d.HTTP.JSON(ctx, "GET", "/api/im/me", nil, &me); err != nil {
		return empty, err
	}
	if me.Principal.ID != b.PrincipalID {
		return empty, Failure("source_principal_mismatch")
	}
	var result struct {
		Document Snapshot `json:"document"`
	}
	err := d.HTTP.JSON(ctx, "GET", "/api/im/rooms/"+url.PathEscape(b.RoomID)+"/documents/"+url.PathEscape(b.DocumentID), nil, &result)
	if err != nil {
		return empty, err
	}
	return result.Document, result.Document.Validate()
}

type Affine struct {
	HTTP                 *HTTP
	MetadataHTTP         *HTTP
	WorkspaceID          string
	NativeCodecPath      string
	NativeNodeExecutable string
}

func NewAffine(endpoint, workspace, token string) (*Affine, error) {
	if err := RequireSafeID(workspace); err != nil {
		return nil, err
	}
	if strings.TrimSpace(token) == "" {
		return nil, Failure("credential_missing")
	}
	h, err := NewHTTP(endpoint, http.Header{"Authorization": {"Bearer " + token}})
	return &Affine{HTTP: h, WorkspaceID: workspace}, err
}

// WithMetadataReadback adds the provider's authenticated GraphQL metadata
// surface. MCP still holds the only write credential; no browser credential is
// sent to MCP. Missing metadata never becomes a successful title verification.
func (a *Affine) WithMetadataReadback(cookie string) error {
	if cookie == "" || strings.ContainsAny(cookie, "\r\n") {
		return Failure("invalid_credential")
	}
	h, err := NewHTTP(a.HTTP.base, http.Header{"Cookie": {cookie}})
	if err != nil {
		return err
	}
	a.MetadataHTTP = h
	return nil
}
func (a *Affine) readTitle(ctx context.Context, id string) (string, error) {
	var reply struct {
		Errors []json.RawMessage `json:"errors"`
		Data   struct {
			Workspace struct {
				Doc struct {
					ID          string  `json:"id"`
					WorkspaceID string  `json:"workspaceId"`
					Title       *string `json:"title"`
					Public      *bool   `json:"public"`
				} `json:"doc"`
			} `json:"workspace"`
		} `json:"data"`
	}
	args := map[string]any{"query": "query($workspace: String!, $doc: String!) { workspace(id: $workspace) { doc(docId: $doc) { id workspaceId title public } } }", "variables": map[string]string{"workspace": a.WorkspaceID, "doc": id}}
	if err := a.MetadataHTTP.JSON(ctx, "POST", "/graphql", args, &reply); err != nil {
		return "", err
	}
	d := reply.Data.Workspace.Doc
	if len(reply.Errors) != 0 {
		return "", Failure("metadata_unavailable")
	}
	if d.ID != id || d.WorkspaceID != a.WorkspaceID {
		return "", Failure("target_scope_mismatch")
	}
	if d.Public == nil || *d.Public {
		return "", Failure("target_visibility_not_private")
	}
	if d.Title == nil {
		return "", Failure("metadata_not_ready")
	}
	return *d.Title, nil
}
func (a *Affine) Name() string            { return "affine" }
func (a *Affine) Scope() (string, string) { return a.HTTP.base, a.WorkspaceID }
func (a *Affine) ValidateSnapshot(s Snapshot) error {
	if strings.ContainsAny(s.Title, "\r\n") || strings.TrimSpace(s.Title) != s.Title {
		return Failure("affine_title_not_lossless")
	}
	return nil
}
func (a *Affine) call(ctx context.Context, name string, args any) (string, error) {
	var reply struct {
		Error  json.RawMessage `json:"error"`
		Result struct {
			IsError bool `json:"isError"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"result"`
	}
	err := a.HTTP.JSON(ctx, "POST", "/api/workspaces/"+url.PathEscape(a.WorkspaceID)+"/mcp", map[string]any{"jsonrpc": "2.0", "id": "document-projection", "method": "tools/call", "params": map[string]any{"name": name, "arguments": args}}, &reply)
	if err != nil {
		return "", err
	}
	if len(reply.Error) > 0 && string(reply.Error) != "null" || reply.Result.IsError {
		return "", Failure("provider_tool_failure")
	}
	if len(reply.Result.Content) != 1 || reply.Result.Content[0].Type != "text" {
		return "", Failure("invalid_response")
	}
	return reply.Result.Content[0].Text, nil
}
func (a *Affine) Read(ctx context.Context, id string) (Observation, error) {
	if err := RequireSafeID(id); err != nil {
		return Observation{}, err
	}
	text, err := a.call(ctx, "read_document", map[string]any{"docId": id})
	if err != nil {
		return Observation{}, err
	}
	result := Observation{ExternalID: id, BodyHash: BodyHash(text), RawBodyHash: Hash(text)}
	if a.MetadataHTTP != nil {
		title, err := a.readTitle(ctx, id)
		if err != nil {
			return Observation{}, err
		}
		result.TitleHash = Hash(title)
		result.TitleReadable = true
	}
	return result, nil
}
func (a *Affine) Create(ctx context.Context, s Snapshot) (string, error) {
	text, err := a.call(ctx, "create_document", map[string]any{"title": s.Title, "content": affineBody(s.Content)})
	if err != nil {
		return "", err
	}
	var result struct {
		Success bool   `json:"success"`
		ID      string `json:"docId"`
	}
	if json.Unmarshal([]byte(text), &result) != nil || !result.Success || RequireSafeID(result.ID) != nil {
		return "", Failure("missing_external_id")
	}
	return result.ID, nil
}
func (a *Affine) Update(ctx context.Context, id string, s Snapshot, fence func() error) error {
	if err := RequireSafeID(id); err != nil {
		return err
	}
	if err := fence(); err != nil {
		return err
	}
	text, err := a.call(ctx, "update_document", map[string]any{"docId": id, "content": affineBody(s.Content)})
	if err != nil {
		return err
	}
	if err = affineAck(text, id); err != nil {
		return err
	}
	if err := fence(); err != nil {
		return err
	}
	text, err = a.call(ctx, "update_document_meta", map[string]any{"docId": id, "title": s.Title})
	if err != nil {
		return err
	}
	return affineAck(text, id)
}
func affineAck(text, id string) error {
	var result struct {
		Success bool   `json:"success"`
		ID      string `json:"docId"`
	}
	if json.Unmarshal([]byte(text), &result) != nil || !result.Success || result.ID != id {
		return Failure("invalid_write_receipt")
	}
	return nil
}

// A transport-only leading blank protects a real first H1 from the provider
// create tool's title-stripping regex. The Markdown parser discards that blank;
// readback must still equal the original canonical body, including its H1.
func affineBody(body string) string {
	if startsWithH1(body) {
		return "\n" + body
	}
	return body
}
func startsWithH1(body string) bool {
	line, _, _ := strings.Cut(body, "\n")
	return strings.HasPrefix(strings.TrimLeft(line, " \t"), "# ")
}

type Docmost struct {
	HTTP    *HTTP
	SpaceID string
}

func NewDocmost(endpoint, space, authToken string) (*Docmost, error) {
	if err := RequireSafeID(space); err != nil {
		return nil, err
	}
	if authToken == "" || strings.ContainsAny(authToken, ";\r\n") {
		return nil, Failure("invalid_credential")
	}
	h, err := NewHTTP(endpoint, http.Header{"Cookie": {"authToken=" + authToken}})
	return &Docmost{HTTP: h, SpaceID: space}, err
}
func (d *Docmost) Name() string                      { return "docmost" }
func (d *Docmost) Scope() (string, string)           { return d.HTTP.base, d.SpaceID }
func (d *Docmost) ValidateSnapshot(s Snapshot) error { return nil }

type docmostPage struct {
	ID        string          `json:"id"`
	Title     string          `json:"title"`
	Content   json.RawMessage `json:"content"`
	SpaceID   string          `json:"spaceId"`
	UpdatedAt string          `json:"updatedAt"`
}

func (d *Docmost) call(ctx context.Context, path string, args any) (docmostPage, error) {
	var result struct {
		Success *bool       `json:"success"`
		Data    docmostPage `json:"data"`
	}
	err := d.HTTP.JSON(ctx, "POST", "/api/"+path, args, &result)
	if err != nil {
		return docmostPage{}, err
	}
	if result.Success != nil && !*result.Success {
		return docmostPage{}, Failure("provider_tool_failure")
	}
	if RequireSafeID(result.Data.ID) != nil {
		return docmostPage{}, Failure("invalid_response")
	}
	if result.Data.SpaceID != d.SpaceID {
		return docmostPage{}, Failure("target_namespace_mismatch")
	}
	return result.Data, nil
}
func (d *Docmost) Read(ctx context.Context, id string) (Observation, error) {
	if err := RequireSafeID(id); err != nil {
		return Observation{}, err
	}
	r, err := d.call(ctx, "pages/info", map[string]any{"pageId": id, "format": "markdown", "includeContent": true, "includeSpace": true})
	if err != nil {
		return Observation{}, err
	}
	var body string
	if r.ID != id || len(r.Content) == 0 || json.Unmarshal(r.Content, &body) != nil {
		return Observation{}, Failure("invalid_response")
	}
	return Observation{ExternalID: r.ID, BodyHash: BodyHash(body), RawBodyHash: Hash(body), Version: r.UpdatedAt, TitleHash: Hash(r.Title), TitleReadable: true}, nil
}
func (d *Docmost) Create(ctx context.Context, s Snapshot) (string, error) {
	r, err := d.call(ctx, "pages/create", map[string]any{"spaceId": d.SpaceID, "title": s.Title, "content": s.Content, "format": "markdown"})
	return r.ID, err
}
func (d *Docmost) Update(ctx context.Context, id string, s Snapshot, fence func() error) error {
	if err := RequireSafeID(id); err != nil {
		return err
	}
	if err := fence(); err != nil {
		return err
	}
	r, err := d.call(ctx, "pages/update", map[string]any{"pageId": id, "title": s.Title, "content": s.Content, "format": "markdown", "operation": "replace"})
	if err != nil {
		return err
	}
	if r.ID != id {
		return Failure("invalid_write_receipt")
	}
	return nil
}
