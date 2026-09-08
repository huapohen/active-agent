package documents

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestAffineBodyReadbackIsExplicitlyPartialAndTitleHasSeparateFence(t *testing.T) {
	source := newFixture(t)
	body := ""
	creates, bodyWrites, titleWrites := 0, 0, 0
	affineServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer affine-secret" || r.URL.Path != "/api/workspaces/workspace-1/mcp" {
			t.Error("wrong affine request scope")
		}
		var input struct {
			Params struct {
				Name string         `json:"name"`
				Args map[string]any `json:"arguments"`
			} `json:"params"`
		}
		json.NewDecoder(r.Body).Decode(&input)
		var text string
		switch input.Params.Name {
		case "read_document":
			text = body + "\n"
		case "create_document":
			creates++
			body = input.Params.Args["content"].(string)
			text = `{"success":true,"docId":"affine-doc-1"}`
		case "update_document":
			bodyWrites++
			body = input.Params.Args["content"].(string)
			source.allowed = false
			text = `{"success":true,"docId":"affine-doc-1"}`
		case "update_document_meta":
			titleWrites++
			text = `{"success":true,"docId":"affine-doc-1"}`
		default:
			t.Error("unexpected tool", input.Params.Name)
		}
		json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": "document-projection", "result": map[string]any{"content": []any{map[string]any{"type": "text", "text": text}}}})
	}))
	defer affineServer.Close()
	a, err := NewAffine(affineServer.URL, "workspace-1", "affine-secret")
	if err != nil {
		t.Fatal(err)
	}
	j := journal(t)
	e := source.engine(j)
	e.Target = a
	b := source.binding()
	b.Target = "affine"
	b.TargetEndpoint = affineServer.URL
	b.NamespaceID = "workspace-1"
	r, err := e.Sync(context.Background(), b)
	if err != nil || r.State != "partial_verification" || r.TitleVerified || creates != 1 {
		t.Fatal(r, err, creates)
	}
	source.source.Revision++
	source.source.Content = "Next body"
	source.source.ContentHash = Hash(source.source.Content)
	r, err = e.Sync(context.Background(), b)
	requireCode(t, err, "access_denied")
	if r.State != "unknown" || bodyWrites != 1 || titleWrites != 0 {
		t.Fatal(r, bodyWrites, titleWrites)
	}
}
func TestAffineH1IsProtectedInTransportAndSourceIsUnchanged(t *testing.T) {
	original := "# Actual body heading\n\nImportant."
	f := newFixture(t)
	f.source.Content = original
	f.source.ContentHash = Hash(original)
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var input struct {
			Params struct {
				Name string         `json:"name"`
				Args map[string]any `json:"arguments"`
			} `json:"params"`
		}
		json.NewDecoder(r.Body).Decode(&input)
		text := original + "\n"
		if input.Params.Name == "create_document" {
			calls++
			if input.Params.Args["content"] != "\n"+original {
				t.Error("H1 would be stripped")
			}
			text = `{"success":true,"docId":"h1-doc"}`
		}
		json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"content": []any{map[string]any{"type": "text", "text": text}}}})
	}))
	defer server.Close()
	a, _ := NewAffine(server.URL, "space-1", "token")
	e := f.engine(journal(t))
	e.Target = a
	b := f.binding()
	b.Target = "affine"
	b.TargetEndpoint = server.URL
	r, err := e.Sync(context.Background(), b)
	if err != nil || r.State != "partial_verification" || r.ObservedBodyHash != Hash(original) || calls != 1 {
		t.Fatal(r, err, calls)
	}
	if f.source.Content != original {
		t.Fatal("canonical source altered")
	}
}
func TestAffineToolErrorBodyIsNotMistakenForReadback(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"isError": true, "content": []any{map[string]any{"type": "text", "text": "credential secret should not leak"}}}})
	}))
	defer server.Close()
	a, _ := NewAffine(server.URL, "workspace", "token")
	_, err := a.Read(context.Background(), "doc")
	requireCode(t, err, "provider_tool_failure")
}
func TestEndpointsRejectNonLoopbackPlaintextUserinfoAndPathConfusion(t *testing.T) {
	for _, endpoint := range []string{"http://example.com", "https://user:pass@example.com", "https://example.com?token=secret", "https://example.com/nested", "file:///tmp/f"} {
		if _, err := NewHTTP(endpoint, nil); err == nil {
			t.Fatal("accepted", endpoint)
		}
	}
}
func TestBodyHashPreservesMeaningfulWhitespace(t *testing.T) {
	if BodyHash("a\n\nb\n") != BodyHash("a\r\n\r\nb") {
		t.Fatal("newline representation mismatch")
	}
	if BodyHash("a\n\nb") == BodyHash("a\nb") {
		t.Fatal("paragraphs erased")
	}
	if BodyHash(" a") == BodyHash("a") {
		t.Fatal("leading space erased")
	}
}

func TestAffineMetadataCompletesPartialReceiptWithoutAnotherWrite(t *testing.T) {
	f := newFixture(t)
	body := ""
	creates := 0
	public := false
	wrongScope := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/graphql" {
			if r.Header.Get("Cookie") != "affine_session=metadata-secret" || r.Header.Get("Authorization") != "" {
				t.Error("metadata auth mixed with MCP")
			}
			workspace := "space-1"
			if wrongScope {
				workspace = "other"
			}
			json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"workspace": map[string]any{"doc": map[string]any{"id": "affine-doc", "workspaceId": workspace, "title": f.source.Title, "public": public}}}})
			return
		}
		if r.Header.Get("Cookie") != "" {
			t.Error("browser credential sent to MCP")
		}
		var input struct {
			Params struct {
				Name string         `json:"name"`
				Args map[string]any `json:"arguments"`
			} `json:"params"`
		}
		json.NewDecoder(r.Body).Decode(&input)
		text := body
		if input.Params.Name == "create_document" {
			creates++
			body = input.Params.Args["content"].(string)
			text = `{"success":true,"docId":"affine-doc"}`
		}
		json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"content": []any{map[string]any{"type": "text", "text": text}}}})
	}))
	defer server.Close()
	a, _ := NewAffine(server.URL, "space-1", "token")
	e := f.engine(journal(t))
	e.Target = a
	b := f.binding()
	b.Target = "affine"
	b.TargetEndpoint = server.URL
	r, err := e.Sync(context.Background(), b)
	if err != nil || r.State != "partial_verification" {
		t.Fatal(r, err)
	}
	if err = a.WithMetadataReadback("affine_session=metadata-secret"); err != nil {
		t.Fatal(err)
	}
	r, err = e.Sync(context.Background(), b)
	if err != nil || r.State != "verified" || !r.TitleVerified || creates != 1 {
		t.Fatal(r, err, creates)
	}
	public = true
	_, err = e.Sync(context.Background(), b)
	requireCode(t, err, "target_visibility_not_private")
	public = false
	wrongScope = true
	_, err = e.Sync(context.Background(), b)
	requireCode(t, err, "target_scope_mismatch")
	if creates != 1 {
		t.Fatal("rewrote during metadata checks")
	}
}
