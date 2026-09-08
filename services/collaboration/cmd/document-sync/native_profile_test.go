package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/huapohen/active-agent/services/collaboration/internal/documents"
)

func TestCLIV2ProfilesReachRealNativeVerification(t *testing.T) {
	for _, tc := range []struct {
		name, provider, profile string
		exit                    int
	}{
		{"docmost_v2", "docmost", documents.DocmostCodeNativeProfile, 0},
		{"affine_v2", "affine", documents.AffineCodeNativeProfile, 0},
		{"wrong_docmost_provider", "affine", documents.DocmostCodeNativeProfile, 1},
		{"wrong_affine_provider", "docmost", documents.AffineCodeNativeProfile, 1},
		{"unknown", "docmost", "unreviewed.v3", 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			read := func(name string) []byte {
				b, e := os.ReadFile("../../internal/documents/testdata/native/" + name)
				if e != nil {
					t.Fatal(e)
				}
				return b
			}
			source := documents.Snapshot{ID: "9d62380a", Revision: 1, Title: "人机执行档案 · 76dedd18-1ddf-4fc0-abfa-19aee795b034 · 游标 5 · 1", Content: string(read("archive.md"))}
			source.ContentHash = documents.Hash(source.Content)
			pm, aff := read("archive-docmost-import.json"), read("archive-affine-import.bin")
			requests, creates, nativeReads := 0, 0, 0
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				requests++
				w.Header().Set("Content-Type", "application/json")
				if strings.HasPrefix(r.URL.Path, "/api/im/") {
					if r.Header.Get("Authorization") != "Bearer cli-synthetic-token" {
						t.Error("wrong source auth")
					}
					if r.URL.Path == "/api/im/me" {
						json.NewEncoder(w).Encode(map[string]any{"principal": map[string]any{"id": "member"}})
						return
					}
					if r.URL.Path != "/api/im/rooms/source-room/documents/9d62380a" {
						t.Error("wrong source scope")
					}
					json.NewEncoder(w).Encode(map[string]any{"document": source})
					return
				}
				if r.URL.Path == "/api/workspaces/space/docs/new-target" {
					if r.Header.Get("Cookie") != "cli-synthetic-token" {
						t.Error("missing native credential")
					}
					nativeReads++
					w.Header().Set("Content-Type", "application/octet-stream")
					w.Header().Set("ETag", "native-frozen")
					w.Write(aff)
					return
				}
				if r.URL.Path == "/graphql" {
					json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"workspace": map[string]any{"doc": map[string]any{"id": "new-target", "workspaceId": "space", "title": source.Title, "public": false}}}})
					return
				}
				var req map[string]any
				json.NewDecoder(r.Body).Decode(&req)
				if r.URL.Path == "/api/workspaces/space/mcp" {
					params := req["params"].(map[string]any)
					text := source.Content
					if params["name"] == "create_document" {
						creates++
						text = `{"success":true,"docId":"new-target"}`
					} else if params["name"] != "read_document" {
						t.Error("unexpected target write")
					}
					json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"content": []any{map[string]any{"type": "text", "text": text}}}})
					return
				}
				var content any = source.Content
				if r.URL.Path == "/api/pages/create" {
					creates++
				} else if r.URL.Path == "/api/pages/info" {
					if req["format"] == nil {
						nativeReads++
						content = json.RawMessage(pm)
					}
				} else {
					t.Error("unexpected target path")
				}
				json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"id": "new-target", "spaceId": "space", "title": source.Title, "updatedAt": "2026-09-09T06:00:00.000Z", "content": content}})
			}))
			defer srv.Close()
			credentialPath := filepath.Join(dir, "token.json")
			os.WriteFile(credentialPath, []byte(`{"token":"cli-synthetic-token"}`), 0600)
			binding := bindingConfig{Binding: documents.Binding{ID: "cli-binding", PrincipalID: "member", SourceEndpoint: srv.URL, RoomID: "source-room", DocumentID: source.ID, Target: tc.provider, TargetEndpoint: srv.URL, NamespaceID: "space", ApprovedBy: "admin", ApprovalReference: "isolated CLI test", Generation: 1, Enabled: true, GatewayOnlyNamespace: true}, SourceCredentialFile: credentialPath, TargetCredentialFile: credentialPath}
			if tc.provider == "affine" {
				binding.TargetMetadataCredentialFile = credentialPath
			}
			cfg := config{Journal: filepath.Join(dir, "journal.jsonl"), Bindings: []bindingConfig{binding}}
			raw, _ := json.Marshal(cfg)
			path := filepath.Join(dir, "config.json")
			os.WriteFile(path, raw, 0600)
			codec, _ := filepath.Abs("../../internal/documents/affinecodec")
			node := ""
			if tc.provider == "affine" && tc.profile == documents.AffineCodeNativeProfile {
				var e error
				node, e = exec.LookPath("node")
				if e != nil {
					t.Skip("Node unavailable")
				}
				node, _ = filepath.Abs(node)
				if _, e = os.Stat(filepath.Join(codec, "node_modules", "yjs")); e != nil {
					t.Skip("native codec dependencies unavailable")
				}
			}
			if got := runSelected(context.Background(), path, binding.ID, tc.profile, codec, node); got != tc.exit {
				t.Fatalf("exit=%d want=%d", got, tc.exit)
			}
			if tc.exit != 0 {
				if requests != 0 || creates != 0 {
					t.Fatal("rejected profile reached HTTP")
				}
				return
			}
			if creates != 1 || nativeReads != 2 {
				t.Fatalf("creates=%d nativeReads=%d", creates, nativeReads)
			}
			j, e := documents.OpenFileJournal(cfg.Journal)
			if e != nil {
				t.Fatal(e)
			}
			defer j.Close()
			last, ok := j.Latest(binding.ID)
			if !ok || last.State != "native_verified" || last.Native == nil || last.Native.Profile != tc.profile || last.Native.MarkdownExportError != "" {
				t.Fatal("CLI omitted native proof")
			}
		})
	}
}
