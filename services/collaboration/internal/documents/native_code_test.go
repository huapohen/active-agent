package documents

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"os"
	"regexp"
	"strings"
	"testing"
)

func TestCodeProfileRequiresNativeEvenWhenMarkdownBytesMatch(t *testing.T) {
	for _, mode := range []string{"byte_equal", "export_mismatch", "wrong_native"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t)
			f.source.Content = "```json\n中文\n```"
			f.source.ContentHash = Hash(f.source.Content)
			j := journal(t)
			e := f.engine(j)
			e.NativeVerificationProfile = DocmostCodeNativeProfile
			f.server.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/api/pages/info" {
					f.serve(w, r)
					return
				}
				if r.Header.Get("Cookie") != "authToken=target-secret" {
					t.Error("missing auth")
				}
				var req map[string]any
				json.NewDecoder(r.Body).Decode(&req)
				var content any = f.currentBody
				if mode == "export_mismatch" {
					content = f.currentBody + "\n\nexport artifact"
				}
				if req["format"] == nil {
					text := "中文\n"
					if mode == "wrong_native" {
						text = "中文"
					}
					content = map[string]any{"type": "doc", "content": []any{map[string]any{"type": "codeBlock", "attrs": map[string]any{"language": "json"}, "content": []any{map[string]any{"type": "text", "text": text}}}}}
				}
				json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"id": "external-1", "spaceId": "space-1", "title": f.currentTitle, "updatedAt": "2026-09-09T01:02:03.000Z", "content": content}})
			})
			r, err := e.Sync(context.Background(), f.binding())
			if mode == "wrong_native" {
				requireCode(t, err, "native_structure_mismatch")
				if r.State != "unknown" || r.Native != nil {
					t.Fatal("matching Markdown signed a wrong native code block")
				}
			} else {
				if err != nil || r.State != "native_verified" || r.Native == nil || r.Native.Profile != DocmostCodeNativeProfile {
					t.Fatalf("%+v %v", r, err)
				}
				want := ""
				if mode == "export_mismatch" {
					want = "readback_mismatch"
				}
				if r.Native.MarkdownExportError != want {
					t.Fatal("fabricated or discarded export status")
				}
			}
			before, _ := os.ReadFile(j.file.Name())
			_, again := e.Sync(context.Background(), f.binding())
			if (mode == "wrong_native") != (again != nil) {
				t.Fatal("retry proof changed")
			}
			after, _ := os.ReadFile(j.file.Name())
			if f.creates != 1 || f.updates != 0 || !bytes.Equal(before, after) {
				t.Fatal("repeated a write or append")
			}
		})
	}
}

func archiveFixture(t *testing.T) (Snapshot, []byte, []byte) {
	t.Helper()
	read := func(name string) []byte {
		b, e := os.ReadFile("testdata/native/" + name)
		if e != nil {
			t.Fatal(e)
		}
		return b
	}
	body := string(read("archive.md"))
	if Hash(body) != "e37f8cacc7f3e26a53c66be9b0c89e90273e98ca1efc5da44109b980aa5d9fe9" {
		t.Fatal("archive source changed")
	}
	return Snapshot{ID: "9d62380a", Revision: 1, Title: "人机执行档案 · 76dedd18-1ddf-4fc0-abfa-19aee795b034 · 游标 5 · 1", Content: body, ContentHash: Hash(body)}, read("archive-docmost-import.json"), read("archive-affine-import.bin")
}

func TestArchiveNativeCodeProfilesFullOfficialOfflineImport(t *testing.T) {
	s, docmost, affine := archiveFixture(t)
	if _, e := CompareDocmostNative(s.Content, docmost); e == nil {
		t.Fatal("v1 broadened to code")
	}
	p, e := CompareDocmostNativeProfile(s.Content, docmost, DocmostCodeNativeProfile)
	if e != nil {
		t.Fatal(e)
	}
	parsed, e := markdownTreeForProfile(s.Content, DocmostCodeNativeProfile)
	if e != nil {
		t.Fatal(e)
	}
	// Independently slice this frozen source's six JSON fences. A trailing LF
	// is part of each code payload, not globally trimmed as Markdown whitespace.
	chunks := regexp.MustCompile("(?ms)^```json\\n(.*?)^```$").FindAllStringSubmatch(s.Content, -1)
	var codes []tree
	for _, n := range parsed["children"].([]tree) {
		if n["type"] == "codeBlock" {
			codes = append(codes, n)
		}
	}
	if len(chunks) != 6 || len(codes) != 6 {
		t.Fatal("lost archive code blocks")
	}
	for i, c := range codes {
		if c["language"] != "json" || c["text"] != chunks[i][1] || !strings.HasSuffix(c["text"].(string), "\n") {
			t.Fatal("code language/bytes changed")
		}
	}
	a := &Affine{}
	if e = a.WithNativeCodec(installedAffineCodec(t), nativeNode(t)); e != nil {
		t.Fatal(e)
	}
	if _, e = a.compareNative(context.Background(), s, affine); e == nil {
		t.Fatal("v1 AFF profile broadened")
	}
	ap, e := a.compareNativeProfile(context.Background(), s, affine, AffineCodeNativeProfile)
	if e != nil {
		t.Fatal(e)
	}
	if p.SourceHash != ap.SourceCanonicalHash || p.TargetHash != ap.TargetCanonicalHash || ap.Profile != AffineCodeNativeProfile {
		t.Fatal("full archive differs")
	}
}

func TestCodeExactLanguageUnicodeAndLineEndings(t *testing.T) {
	for _, tc := range []struct{ name, source, language, text string }{
		{"chinese", "```json\n{\"中文\": \"🚀\"}\n```", "json", "{\"中文\": \"🚀\"}\n"},
		{"two_terminal_lf", "~~~c++\n中文\n\n~~~", "c++", "中文\n\n"},
		{"empty", "```\n```", "", ""},
		{"no_terminal_lf", "```text\n末行", "text", "末行"},
		{"crlf", "```json\r\n中文\r\n```", "json", "中文\r\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var language any
			if tc.language != "" {
				language = tc.language
			}
			native := map[string]any{"type": "doc", "content": []any{map[string]any{"type": "codeBlock", "attrs": map[string]any{"language": language}, "content": []any{map[string]any{"type": "text", "text": tc.text}}}}}
			if tc.text == "" {
				native["content"].([]any)[0].(map[string]any)["content"] = []any{}
			}
			b, _ := json.Marshal(native)
			if _, e := CompareDocmostNativeProfile(tc.source, b, DocmostCodeNativeProfile); e != nil {
				t.Fatal(e)
			}
			for _, change := range []string{"language", "text", "marks", "unknown_attr", "unknown_child"} {
				var altered map[string]any
				json.Unmarshal(b, &altered)
				code := altered["content"].([]any)[0].(map[string]any)
				switch change {
				case "language":
					code["attrs"].(map[string]any)["language"] = "wrong"
				case "text":
					code["content"] = []any{map[string]any{"type": "text", "text": tc.text + "\n"}}
				case "marks":
					code["content"] = []any{map[string]any{"type": "text", "text": "x", "marks": []any{map[string]any{"type": "bold"}}}}
				case "unknown_attr":
					code["attrs"].(map[string]any)["collapsed"] = true
				case "unknown_child":
					code["content"] = []any{map[string]any{"type": "paragraph"}}
				}
				bad, _ := json.Marshal(altered)
				if _, e := CompareDocmostNativeProfile(tc.source, bad, DocmostCodeNativeProfile); e == nil {
					t.Fatal("accepted " + change)
				}
			}
		})
	}
	for _, source := range []string{"```json extra\nx\n```", "```../../url\nx\n```"} {
		if _, e := markdownTreeForProfile(source, DocmostCodeNativeProfile); e == nil {
			t.Fatal("accepted unrepresentable fence metadata")
		}
	}
}
