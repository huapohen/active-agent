package emoji

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"testing/fstest"
)

func actualBundle(t *testing.T) *Local {
	t.Helper()
	_, file, _, _ := runtime.Caller(0)
	p, err := NewLocal(filepath.Join(filepath.Dir(file), "../../../../apps/office/assets/emoji"))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestRealBundle4126IDs182VerifiedPNGs(t *testing.T) {
	p := actualBundle(t)
	m := p.Metadata()
	if m.CatalogCount != 4126 || m.AssetCount != 182 || len(m.Categories) != 10 || m.UnicodeVersion != "17.0" || len(m.Revision) != 71 {
		t.Fatalf("metadata: %+v", m)
	}
	seen := map[string]bool{}
	assets, totalBytes, offset := 0, 0, 0
	for {
		page, err := p.List(context.Background(), Query{Offset: offset, Limit: 200, Revision: m.Revision})
		if err != nil || page.Total != 4126 || page.Revision != m.Revision || page.PageETag == "" {
			t.Fatalf("page: %+v, %v", page, err)
		}
		for _, e := range page.Entries {
			if seen[e.ID] || !p.Contains(e.ID) {
				t.Fatalf("duplicate or invalid ID %q", e.ID)
			}
			seen[e.ID] = true
			if e.Asset == "" {
				continue
			}
			a, err := p.Asset(context.Background(), e.Asset)
			if err != nil || a.ETag != e.AssetETag || a.ETag != quotedHash(hash(a.Data)) || len(a.Data) != e.AssetBytes || a.ContentType != "image/png" {
				t.Fatalf("asset %s: %v", e.Asset, err)
			}
			assets++
			totalBytes += len(a.Data)
		}
		if !page.HasMore {
			if page.NextOffset != nil {
				t.Fatal("unexpected last-page cursor")
			}
			break
		}
		if page.NextOffset == nil || *page.NextOffset <= offset {
			t.Fatal("invalid cursor")
		}
		offset = *page.NextOffset
	}
	if len(seen) != 4126 || assets != 182 || totalBytes != 1880966 {
		t.Fatalf("IDs %d assets %d bytes %d", len(seen), assets, totalBytes)
	}
	for _, invalid := range []string{"👍🏻not-an-emoji", "feishu:INVENTED", ":feishu:OK:", "feishu:ok", "👍 ", ""} {
		if p.Contains(invalid) {
			t.Fatalf("accepted noncatalog ID %q", invalid)
		}
	}
}

func TestSearchPaginationAndRevisionBoundaries(t *testing.T) {
	p := actualBundle(t)
	ctx := context.Background()
	for _, tc := range []struct{ q, category, want string }{
		{"点赞", "经典表情", "feishu:THUMBSUP"},
		{"ＯＫ", "经典表情", "feishu:OK"},
		{"standard thumbsUP", "经典表情", "feishu:THUMBSUP"},
		{"smiling face", "笑脸与情感", ""},
	} {
		page, err := p.List(ctx, Query{Q: tc.q, Category: tc.category})
		if err != nil || page.Total == 0 {
			t.Fatalf("search %q: %v", tc.q, err)
		}
		found := tc.want == ""
		for _, e := range page.Entries {
			found = found || e.ID == tc.want
		}
		if !found {
			t.Fatalf("search %q missing %q", tc.q, tc.want)
		}
	}
	for _, q := range []Query{{Offset: -1}, {Limit: -1}, {Limit: 201}, {Q: strings.Repeat("中", 101)}, {Q: string([]byte{255})}, {Category: "invented"}} {
		if _, err := p.List(ctx, q); !errors.Is(err, ErrInvalidQuery) {
			t.Fatalf("invalid query accepted: %+v %v", q, err)
		}
	}
	if _, err := p.List(ctx, Query{Revision: "old"}); !errors.Is(err, ErrRevisionChanged) {
		t.Fatalf("revision: %v", err)
	}
	page, err := p.List(ctx, Query{Offset: math.MaxInt})
	if err != nil || len(page.Entries) != 0 || page.HasMore || page.NextOffset != nil {
		t.Fatalf("oversized offset overflow: %+v %v", page, err)
	}
	page, _ = p.List(ctx, Query{})
	if page.Limit != 100 || len(page.Entries) != 100 {
		t.Fatal("default limit")
	}
	again, _ := p.List(ctx, Query{})
	other, _ := p.List(ctx, Query{Offset: 1})
	if again.PageETag != page.PageETag || other.PageETag == page.PageETag {
		t.Fatal("page etag must identify deterministic page response")
	}
	for _, path := range []string{"../catalog.json", "feishu/../catalog.json", "/feishu/OK.png", "feishu/%2e%2e/catalog.json", "https://example.com/x.png", "feishu/OK.png?x=1", "feishu\\OK.png", "feishu/INVENTED.png"} {
		if _, err := p.Asset(ctx, path); !errors.Is(err, ErrAssetNotFound) {
			t.Fatalf("nonmanifest path accepted: %q %v", path, err)
		}
	}
}

func TestSnapshotIsolationConcurrentReadsAndCancellation(t *testing.T) {
	root, manifest := fixture(t, color.RGBA{R: 255, A: 255})
	p, err := load(root, manifest)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	// The source can disappear after startup; requests use no filesystem handles.
	for k := range root {
		delete(root, k)
	}
	m := p.Metadata()
	m.Categories[0] = "corrupted"
	e, _ := p.Get(ctx, "feishu:OK")
	e.Aliases[0] = "corrupted"
	a, _ := p.Asset(ctx, "feishu/OK.png")
	a.Data[0] = 0
	page, _ := p.List(ctx, Query{})
	page.Entries[0].Aliases[0] = "corrupted"
	var wg sync.WaitGroup
	for range 12 {
		wg.Go(func() {
			for range 20 {
				e, err := p.Get(ctx, "feishu:OK")
				a, assetErr := p.Asset(ctx, "feishu/OK.png")
				page, listErr := p.List(ctx, Query{Q: "ＯＫ"})
				if err != nil || assetErr != nil || listErr != nil || e.Aliases[0] != "OK" || a.Data[0] != 137 || page.Total != 1 || p.Metadata().Categories[0] != "经典表情" {
					t.Error("mutable or inconsistent snapshot")
				}
			}
		})
	}
	wg.Wait()
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := p.List(cancelled, Query{}); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if _, err := p.Get(cancelled, "feishu:OK"); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if _, err := p.Asset(cancelled, "feishu/OK.png"); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}

func TestBundleFailsClosedOnCorruptionAndUnknownSchema(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(fstest.MapFS, *bundleManifest)
	}{
		{"missing asset", func(f fstest.MapFS, _ *bundleManifest) { delete(f, "feishu/OK.png") }},
		{"corrupt bytes", func(f fstest.MapFS, _ *bundleManifest) { f["feishu/OK.png"].Data[0] = 0 }},
		{"digest checked", func(_ fstest.MapFS, m *bundleManifest) { m.Assets[0].SHA256 = strings.Repeat("0", 64) }},
		{"remote asset", func(_ fstest.MapFS, m *bundleManifest) { m.Assets[0].Path = "https://example.com/a.png" }},
		{"traversal", func(_ fstest.MapFS, m *bundleManifest) { m.Assets[0].Path = "feishu/../OK.png" }},
		{"duplicate asset", func(_ fstest.MapFS, m *bundleManifest) { m.Assets = append(m.Assets, m.Assets[0]); m.AssetCount++ }},
		{"unrecognized schema", func(_ fstest.MapFS, m *bundleManifest) { m.Schema = "future" }},
		{"oversized declaration", func(_ fstest.MapFS, m *bundleManifest) { m.Assets[0].Bytes = 1<<20 + 1 }},
		{"not png", func(f fstest.MapFS, m *bundleManifest) {
			b := []byte("not a PNG")
			f["feishu/OK.png"].Data = b
			m.Assets[0].Bytes = len(b)
			m.Assets[0].SHA256 = hash(b)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f, raw := fixture(t, color.RGBA{A: 255})
			var m bundleManifest
			if err := json.Unmarshal(raw, &m); err != nil {
				t.Fatal(err)
			}
			tc.mutate(f, &m)
			raw, _ = json.Marshal(m)
			if _, err := load(f, raw); !errors.Is(err, ErrInvalidBundle) {
				t.Fatalf("accepted: %v", err)
			}
		})
	}
	for _, tc := range []struct {
		name   string
		mutate func(map[string]any)
	}{
		{"unknown property", func(c map[string]any) { c["remote_url"] = "https://example.com" }},
		{"count mismatch", func(c map[string]any) { c["count"] = 2 }},
		{"duplicate category", func(c map[string]any) { c["categories"] = []string{"经典表情", "经典表情"} }},
		{"missing category", func(c map[string]any) { c["categories"] = []string{"other"} }},
		{"invalid ID/asset mapping", func(c map[string]any) { c["entries"].([]any)[0].(map[string]any)["id"] = "feishu:invented" }},
		{"client supplied etag", func(c map[string]any) { c["entries"].([]any)[0].(map[string]any)["asset_etag"] = "unverified" }},
		{"unknown entry property", func(c map[string]any) { c["entries"].([]any)[0].(map[string]any)["onclick"] = "bad" }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f, raw := fixture(t, color.RGBA{A: 255})
			var m bundleManifest
			var c map[string]any
			_ = json.Unmarshal(raw, &m)
			_ = json.Unmarshal(f["catalog.json"].Data, &c)
			tc.mutate(c)
			b, _ := json.Marshal(c)
			f["catalog.json"].Data = b
			m.CatalogBytes = len(b)
			m.CatalogSHA256 = hash(b)
			raw, _ = json.Marshal(m)
			if _, err := load(f, raw); !errors.Is(err, ErrInvalidBundle) {
				t.Fatalf("accepted: %v", err)
			}
		})
	}
}

func TestRevisionCoversActualImageBytesAndRootConfinement(t *testing.T) {
	f1, m1 := fixture(t, color.RGBA{R: 255, A: 255})
	f2, m2 := fixture(t, color.RGBA{B: 255, A: 255})
	p1, e1 := load(f1, m1)
	p2, e2 := load(f2, m2)
	if e1 != nil || e2 != nil || p1.Metadata().Revision == p2.Metadata().Revision {
		t.Fatal("image change not reflected in revision", e1, e2)
	}
	if _, err := NewLocal("relative/path"); !errors.Is(err, ErrInvalidBundle) {
		t.Fatal(err)
	}
	inside, outside := t.TempDir(), t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "catalog.json"), f1["catalog.json"].Data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(outside, "catalog.json"), filepath.Join(inside, "catalog.json")); err != nil {
		t.Fatal(err)
	}
	root, err := os.OpenRoot(inside)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	if _, err = load(root.FS(), m1); !errors.Is(err, ErrInvalidBundle) {
		t.Fatalf("escaped configured root: %v", err)
	}
}

func fixture(t *testing.T, pixel color.RGBA) (fstest.MapFS, []byte) {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 1, 1))
	img.SetRGBA(0, 0, pixel)
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	data := catalog{Version: "emoji-catalog/v1", UnicodeVersion: "17.0", Categories: []string{"经典表情"}, Count: 1, Entries: []Entry{{ID: "feishu:OK", Code: "OK", Name: "OK", Aliases: []string{"OK"}, Category: "经典表情", Group: "Feishu standard", Subgroup: "official reference", Asset: "assets/emoji/feishu/OK.png", Text: ":feishu:OK:"}}}
	b, _ := json.Marshal(data)
	m := bundleManifest{Schema: "renji.emoji-local-bundle.v1", CatalogPath: "catalog.json", CatalogSHA256: hash(b), CatalogBytes: len(b), CatalogCount: 1, AssetCount: 1, Assets: []manifestAsset{{Path: "feishu/OK.png", SHA256: hash(buf.Bytes()), Bytes: buf.Len()}}}
	raw, _ := json.Marshal(m)
	return fstest.MapFS{"catalog.json": &fstest.MapFile{Data: b}, "feishu/OK.png": &fstest.MapFile{Data: buf.Bytes()}}, raw
}
