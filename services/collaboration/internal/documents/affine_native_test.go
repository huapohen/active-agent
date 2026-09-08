package documents

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// This wrapper isolates the engine's write policy after a native receipt. The
// real HTTP/version/codec proof is covered separately above and below.
type affineWriteGuardTarget struct {
	Target
	checks int
}

func (a *affineWriteGuardTarget) Name() string { return "affine" }
func (a *affineWriteGuardTarget) VerifyNative(context.Context, string, Snapshot, Observation) (NativeProof, error) {
	return NativeProof{}, Failure("unexpected_native_reconciliation")
}
func (a *affineWriteGuardTarget) CheckNativeBaseline(context.Context, string, Observation, NativeProof) error {
	a.checks++
	return nil
}

func TestAffineNativeNewSourceRevisionCannotUseMarkdownWriter(t *testing.T) {
	for _, changed := range []string{"content", "title", "revision_only"} {
		t.Run(changed, func(t *testing.T) {
			f := newFixture(t)
			f.currentBody, f.currentTitle = "provider export differs", f.source.Title
			j := journal(t)
			e := f.engine(j)
			target := &affineWriteGuardTarget{Target: e.Target}
			e.Target, e.NativeVerificationProfile = target, AffineNativeProfile
			b := f.binding()
			b.Target = "affine"
			r := Record{
				BindingID: b.ID, BindingHash: b.fingerprint(), Sequence: 1,
				State: "native_verified", ExternalID: "external-1",
				SourceRevision: f.source.Revision, SourceContentHash: f.source.ContentHash,
				DesiredBodyHash: BodyHash(f.source.Content), DesiredTitleHash: Hash(f.source.Title),
				ObservedBodyHash: BodyHash(f.currentBody), ObservedRawBodyHash: Hash(f.currentBody),
				ObservedTitleHash: Hash(f.currentTitle), TitleVerified: true,
				At:     time.Date(2026, 9, 9, 1, 0, 0, 0, time.UTC),
				Native: &NativeProof{Profile: AffineNativeProfile, MarkdownExportError: "readback_mismatch"},
			}
			if err := j.Append(r); err != nil {
				t.Fatal(err)
			}
			before, err := os.ReadFile(j.file.Name())
			if err != nil {
				t.Fatal(err)
			}
			// Same-version reconciliation remains read-only and idempotent.
			if same, err := e.Sync(context.Background(), b); err != nil || same.Sequence != r.Sequence {
				t.Fatalf("same source %+v: %v", same, err)
			}
			f.source.Revision++
			switch changed {
			case "content":
				f.source.Content += "\n\nNew paragraph."
				f.source.ContentHash = Hash(f.source.Content)
			case "title":
				f.source.Title = "New title"
			}
			got, err := e.Sync(context.Background(), b)
			requireCode(t, err, "affine_native_write_plan_required")
			if got.Sequence != r.Sequence || got.State != "native_verified" || target.checks != 2 {
				t.Fatalf("lost signed baseline: %+v, checks=%d", got, target.checks)
			}
			after, err := os.ReadFile(j.file.Name())
			if err != nil {
				t.Fatal(err)
			}
			if f.creates != 0 || f.updates != 0 || !bytes.Equal(before, after) {
				t.Fatal("new source was dispatched through the Markdown writer or journal was changed")
			}
		})
	}
}

func nativeNode(t *testing.T) string {
	t.Helper()
	p, e := exec.LookPath("node")
	if e != nil {
		t.Skip("Node runtime unavailable")
	}
	p, e = filepath.Abs(p)
	if e != nil {
		t.Fatal(e)
	}
	return p
}
func installedAffineCodec(t *testing.T) string {
	t.Helper()
	if _, e := exec.LookPath("node"); e != nil {
		t.Skip("Node native codec runtime unavailable")
	}
	dir, e := filepath.Abs("affinecodec")
	if e != nil {
		t.Fatal(e)
	}
	if _, e := os.Stat(filepath.Join(dir, "node_modules", "yjs")); e != nil {
		t.Skip("run npm ci --prefix internal/documents/affinecodec for native codec integration")
	}
	return dir
}
func TestAffineNativeCodecRejectsLegacyTablesAndVerifiesOfficialDatabase(t *testing.T) {
	dir := installedAffineCodec(t)
	source, _ := nativeFixture(t)
	s := Snapshot{ID: "doc-1", Title: "人机 startup 第一阶段交付 · a9005c0 · 2026-09-09", Content: source, Revision: 1, ContentHash: Hash(source)}
	a := &Affine{}
	if e := a.WithNativeCodec(dir, nativeNode(t)); e != nil {
		t.Fatal(e)
	}
	legacy, e := os.ReadFile("testdata/native/affine-original.bin")
	if e != nil {
		t.Fatal(e)
	}
	if _, e = a.compareNative(context.Background(), s, legacy); e == nil {
		t.Fatal("signed legacy lossy table")
	}
	repaired, e := os.ReadFile("testdata/native/affine-database.bin")
	if e != nil {
		t.Fatal(e)
	}
	p, e := a.compareNative(context.Background(), s, repaired)
	if e != nil {
		t.Fatal(e)
	}
	if p.SourceCanonicalHash != p.TargetCanonicalHash || p.Profile != AffineNativeProfile {
		t.Fatal("incomplete proof")
	}
	s.Content += "changed"
	s.ContentHash = Hash(s.Content)
	if _, e = a.compareNative(context.Background(), s, repaired); e == nil {
		t.Fatal("accepted different source")
	}
}
func TestAffineNativeHTTPRequiresPrivateMetadataAndStableRepresentations(t *testing.T) {
	for _, mode := range []string{"ok", "no_cookie", "wrong_etag", "wrong_bytes", "redirect", "public_title", "wrong_content_type"} {
		t.Run(mode, func(t *testing.T) {
			reads := 0
			meta := 0
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/graphql" {
					meta++
					w.Header().Set("Content-Type", "application/json")
					json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"workspace": map[string]any{"doc": map[string]any{"id": "doc-1", "workspaceId": "space-1", "title": "Title", "public": mode == "public_title"}}}})
					return
				}
				if r.URL.Path == "/api/workspaces/space-1/mcp" {
					json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"content": []any{map[string]any{"type": "text", "text": "exported"}}}})
					return
				}
				if r.Header.Get("Cookie") != "valid-cookie" {
					w.WriteHeader(403)
					return
				}
				reads++
				w.Header().Set("Content-Type", "application/octet-stream")
				w.Header().Set("ETag", "frozen")
				switch mode {
				case "wrong_etag":
					if reads == 2 {
						w.Header().Set("ETag", "changed")
					}
				case "wrong_bytes":
					if reads == 2 {
						w.Write([]byte("different"))
						return
					}
				case "redirect":
					w.Header().Set("Location", "https://example.invalid")
					w.WriteHeader(302)
					return
				case "wrong_content_type":
					w.Header().Set("Content-Type", "text/plain")
				}
				w.Write([]byte("native"))
			}))
			defer srv.Close()
			a, e := NewAffine(srv.URL, "space-1", "write-token")
			if e != nil {
				t.Fatal(e)
			}
			if mode != "no_cookie" {
				if e = a.WithMetadataReadback("valid-cookie"); e != nil {
					t.Fatal(e)
				}
			}
			observed := Observation{ExternalID: "doc-1", BodyHash: BodyHash("exported"), RawBodyHash: Hash("exported"), TitleHash: Hash("Title"), TitleReadable: true}
			_, e = a.stableNative(context.Background(), "doc-1", observed)
			if mode == "ok" {
				if e != nil || reads != 2 || meta != 1 {
					t.Fatalf("%v reads%d meta%d", e, reads, meta)
				}
			} else if e == nil {
				t.Fatal("accepted incoherent/unauthorized native snapshot")
			}
		})
	}
}
func TestNativeProfileCannotDispatchToDifferentProvider(t *testing.T) {
	f := newFixture(t)
	e := f.engine(journal(t))
	e.NativeVerificationProfile = AffineNativeProfile
	_, x := e.Sync(context.Background(), f.binding())
	requireCode(t, x, "native_profile_target_mismatch")
	if f.creates+f.updates != 0 {
		t.Fatal("dispatched wrong profile")
	}
}

func TestAffineNativeChildReceivesNoParentSecretsOrNodeInjection(t *testing.T) {
	dir := installedAffineCodec(t)
	node := nativeNode(t)
	temp := t.TempDir()
	marker := filepath.Join(temp, "injection-ran")
	injection := filepath.Join(temp, "injection.cjs")
	script := "require('node:fs').writeFileSync(" + string(canonicalBytes(marker)) + ",'injected');"
	if e := os.WriteFile(injection, []byte(script), 0600); e != nil {
		t.Fatal(e)
	}
	for _, key := range []string{"CLERK_SECRET_KEY", "RONGCLOUD_APP_SECRET", "OPENAI_API_KEY", "CODEX_TEST_SYNTHETIC_SECRET"} {
		t.Setenv(key, "synthetic-secret-not-for-child")
	}
	t.Setenv("NODE_OPTIONS", "--require="+injection)
	t.Setenv("NODE_PATH", temp)
	wrapper := filepath.Join(temp, "trusted-node-wrapper")
	body := "#!/bin/sh\nif [ -n \"$CLERK_SECRET_KEY$RONGCLOUD_APP_SECRET$OPENAI_API_KEY$CODEX_TEST_SYNTHETIC_SECRET$NODE_OPTIONS$NODE_PATH\" ]; then exit 98; fi\nexec '" + node + "' \"$@\"\n"
	if e := os.WriteFile(wrapper, []byte(body), 0700); e != nil {
		t.Fatal(e)
	}
	a := &Affine{}
	if e := a.WithNativeCodec(dir, wrapper); e != nil {
		t.Fatal(e)
	}
	source, _ := nativeFixture(t)
	s := Snapshot{ID: "doc-1", Title: "人机 startup 第一阶段交付 · a9005c0 · 2026-09-09", Revision: 1, Content: source, ContentHash: Hash(source)}
	b, e := os.ReadFile("testdata/native/affine-database.bin")
	if e != nil {
		t.Fatal(e)
	}
	if _, e = a.compareNative(context.Background(), s, b); e != nil {
		t.Fatal(e)
	}
	if _, e := os.Stat(marker); !os.IsNotExist(e) {
		t.Fatal("NODE_OPTIONS injected into child")
	}
	if e = a.WithNativeCodec(dir, "node"); e == nil {
		t.Fatal("accepted PATH-resolved node")
	}
}
