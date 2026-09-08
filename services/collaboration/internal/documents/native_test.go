package documents

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func setupNativeReconciliation(t *testing.T) (*fixture, *Engine, *FileJournal, *int) {
	t.Helper()
	f := newFixture(t)
	j := journal(t)
	e := f.engine(j)
	e.NativeVerificationProfile = DocmostNativeProfile
	nativeReads := 0
	f.currentBody = "## Result\n\nOne.\n\nexporter artifact"
	f.currentTitle = f.source.Title
	f.server.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/pages/info" {
			f.serve(w, r)
			return
		}
		if r.Header.Get("Cookie") != "authToken=target-secret" {
			t.Error("missing legitimate target credential")
		}
		var v map[string]any
		json.NewDecoder(r.Body).Decode(&v)
		if v["pageId"] != "external-1" {
			t.Error("wrong target")
		}
		nativeReads++
		var content any = f.currentBody
		if v["format"] == nil {
			content = json.RawMessage(`{"type":"doc","content":[{"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"Result"}]},{"type":"paragraph","content":[{"type":"text","text":"One."}]}]}`)
		}
		json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"id": "external-1", "spaceId": "space-1", "title": f.currentTitle, "updatedAt": "2026-09-09T01:02:03.000Z", "content": content}})
	})
	r := Record{BindingID: f.binding().ID, BindingHash: f.binding().fingerprint(), Sequence: 1, State: "unknown", ExternalID: "external-1", SourceRevision: f.source.Revision, SourceContentHash: f.source.ContentHash, DesiredBodyHash: BodyHash(f.source.Content), DesiredTitleHash: Hash(f.source.Title), ErrorCode: "readback_mismatch", At: time.Date(2026, 9, 9, 1, 0, 0, 0, time.UTC)}
	if x := j.Append(r); x != nil {
		t.Fatal(x)
	}
	return f, e, j, &nativeReads
}
func TestNativeReconcilesKnownUnknownWithoutWritesAndPreservesHistory(t *testing.T) {
	f, e, j, reads := setupNativeReconciliation(t)
	original, _ := os.ReadFile(j.file.Name())
	r, x := e.Sync(context.Background(), f.binding())
	if x != nil || r.State != "native_verified" || r.Sequence != 2 || r.Native == nil {
		t.Fatalf("%+v %v", r, x)
	}
	if f.creates != 0 || f.updates != 0 || *reads != 4 {
		t.Fatalf("writes %d/%d reads %d", f.creates, f.updates, *reads)
	}
	if r.SourceContentHash != Hash(f.source.Content) || r.ObservedRawBodyHash != Hash(f.currentBody) || r.Native.MarkdownExportError != "readback_mismatch" || r.Native.PlatformDifferences != 0 {
		t.Fatal("incomplete exact/raw/native proof")
	}
	after, _ := os.ReadFile(j.file.Name())
	if !bytes.HasPrefix(after, original) {
		t.Fatal("rewrote original unknown history")
	}
	r2, x := e.Sync(context.Background(), f.binding())
	if x != nil || r2.Sequence != 2 || *reads != 8 {
		t.Fatalf("idempotence %+v %v", r2, x)
	}
	e.NativeVerificationProfile = ""
	_, x = e.Sync(context.Background(), f.binding())
	requireCode(t, x, "native_profile_required")
}
func TestNativeReconciliationSourceVersionOrPermissionChangeCannotSign(t *testing.T) {
	for _, kind := range []string{"revision", "content", "title", "revocation"} {
		t.Run(kind, func(t *testing.T) {
			f, e, j, reads := setupNativeReconciliation(t)
			switch kind {
			case "revision":
				f.source.Revision++
			case "content":
				f.source.Content += "new"
				f.source.ContentHash = Hash(f.source.Content)
			case "title":
				f.source.Title = "changed"
			case "revocation":
				old := f.server.Config.Handler
				f.server.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					old.ServeHTTP(w, r)
					if *reads >= 4 {
						f.allowed = false
					}
				})
			}
			_, x := e.Sync(context.Background(), f.binding())
			if x == nil {
				t.Fatal("signed changed source")
			}
			r, _ := j.Latest(f.binding().ID)
			if r.State != "unknown" || r.Sequence != 1 || f.creates+f.updates != 0 {
				t.Fatal("mutated journal or target on failure")
			}
		})
	}
}
func TestNativeVersionTitleRawAndStructureFence(t *testing.T) {
	for _, kind := range []string{"missing_version", "changed_version", "wrong_space", "wrong_id", "changed_title", "raw_changed", "native_changed", "table_header_loss", "unknown_native_attr"} {
		t.Run(kind, func(t *testing.T) {
			f, e, j, _ := setupNativeReconciliation(t)
			calls := 0
			old := f.server.Config.Handler
			f.server.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/api/pages/info" {
					old.ServeHTTP(w, r)
					return
				}
				calls++
				var v map[string]any
				json.NewDecoder(r.Body).Decode(&v)
				data := map[string]any{"id": "external-1", "spaceId": "space-1", "title": f.currentTitle, "updatedAt": "2026-09-09T01:02:03.000Z", "content": f.currentBody}
				if v["format"] == nil {
					data["content"] = json.RawMessage(`{"type":"doc","content":[{"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"Result"}]},{"type":"paragraph","content":[{"type":"text","text":"One."}]}]}`)
				}
				switch kind {
				case "missing_version":
					delete(data, "updatedAt")
				case "changed_version":
					if calls > 1 {
						data["updatedAt"] = "2026-09-09T01:02:04.000Z"
					}
				case "wrong_space":
					if calls == 2 {
						data["spaceId"] = "different"
					}
				case "wrong_id":
					if calls == 2 {
						data["id"] = "other"
					}
				case "changed_title":
					if calls == 2 {
						data["title"] = "other"
					}
				case "raw_changed":
					if calls == 3 {
						data["content"] = f.currentBody + " "
					}
				case "native_changed":
					if calls == 4 {
						data["content"] = json.RawMessage(`{"type":"doc","content":[]}`)
					}
				case "table_header_loss":
					if v["format"] == nil {
						data["content"] = json.RawMessage(`{"type":"doc","content":[]}`)
					}
				case "unknown_native_attr":
					if v["format"] == nil {
						data["content"] = json.RawMessage(`{"type":"doc","attrs":{"unreviewed":true},"content":[]}`)
					}
				}
				json.NewEncoder(w).Encode(map[string]any{"data": data})
			})
			_, x := e.Sync(context.Background(), f.binding())
			if x == nil {
				t.Fatal("signed incoherent native readback")
			}
			r, _ := j.Latest(f.binding().ID)
			if r.State != "unknown" || r.Sequence != 1 {
				t.Fatal("rewrote receipt on failed native proof")
			}
		})
	}
}
func TestJournalLegacyBytesSurviveNativeFields(t *testing.T) {
	raw := []byte(`{"binding_id":"old","binding_hash":"b","sequence":1,"state":"unknown","external_id":"external","source_revision":1,"source_content_hash":"h","desired_body_hash":"d","desired_title_hash":"t","title_verified":false,"error_code":"readback_mismatch","at":"2026-09-09T01:00:00Z"}`)
	var r Record
	if x := json.Unmarshal(raw, &r); x != nil {
		t.Fatal(x)
	}
	if !bytes.Equal(canonicalRecord(r), raw) {
		t.Fatal("legacy record hash representation changed")
	}
	line := append([]byte(`{"previous":"","record":`), raw...)
	line = append(line, []byte(`,"hash":"`+Hash("\n"+string(raw))+`"}`+"\n")...)
	p := filepath.Join(t.TempDir(), "legacy.jsonl")
	if x := os.WriteFile(p, line, 0600); x != nil {
		t.Fatal(x)
	}
	j, x := OpenFileJournal(p)
	if x != nil {
		t.Fatal(x)
	}
	defer j.Close()
	r.Sequence++
	r.State = "native_verified"
	r.Native = &NativeProof{Profile: DocmostNativeProfile}
	if x := j.Append(r); x != nil {
		t.Fatal(x)
	}
	b, _ := os.ReadFile(p)
	if !bytes.HasPrefix(b, line) {
		t.Fatal("rewrote legacy bytes")
	}
}
func canonicalRecord(r Record) []byte { b, _ := json.Marshal(r); return b }
