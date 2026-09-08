package emoji

import (
	"bytes"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"image/png"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
)

//go:embed bundle-manifest.json
var pinnedManifest []byte

type bundleManifest struct {
	Schema        string          `json:"schema"`
	CatalogPath   string          `json:"catalog_path"`
	CatalogSHA256 string          `json:"catalog_sha256"`
	CatalogBytes  int             `json:"catalog_bytes"`
	CatalogCount  int             `json:"catalog_count"`
	AssetCount    int             `json:"asset_count"`
	Assets        []manifestAsset `json:"assets"`
}

type manifestAsset struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Bytes  int    `json:"bytes"`
}

type catalog struct {
	Version        string   `json:"version"`
	UnicodeVersion string   `json:"unicode_version"`
	Categories     []string `json:"categories"`
	Count          int      `json:"count"`
	Entries        []Entry  `json:"entries"`
}

// Local is immutable after construction, safe for concurrent readers. No
// request performs disk I/O, and returned slices never alias internal state.
type Local struct {
	metadata   Metadata
	entries    []Entry
	byID       map[string]int
	search     []string
	assets     map[string]Asset
	categories map[string]bool
}

var _ Provider = (*Local)(nil)

// NewLocal opens an explicitly configured absolute directory containing the
// existing catalog.json and feishu/*.png. The bundled manifest pins all bytes.
// Use apps/office/assets/emoji from the repository, or a read-only mount of that
// directory in deployment. Missing/corrupt resources fail closed, never fetch.
func NewLocal(directory string) (*Local, error) {
	if !filepath.IsAbs(directory) {
		return nil, fmt.Errorf("%w: absolute directory required", ErrInvalidBundle)
	}
	root, err := os.OpenRoot(directory)
	if err != nil {
		return nil, fmt.Errorf("%w: directory unavailable", ErrInvalidBundle)
	}
	defer root.Close()
	return load(root.FS(), pinnedManifest)
}

func load(root fs.FS, manifestBytes []byte) (*Local, error) {
	var manifest bundleManifest
	if err := strictJSON(manifestBytes, &manifest); err != nil || manifest.Schema != "renji.emoji-local-bundle.v1" ||
		manifest.CatalogPath != "catalog.json" || manifest.CatalogBytes < 1 || manifest.CatalogBytes > 4<<20 ||
		manifest.CatalogCount < 1 || manifest.CatalogCount > 10000 || manifest.AssetCount != len(manifest.Assets) {
		return nil, fmt.Errorf("%w: manifest", ErrInvalidBundle)
	}
	raw, err := readVerified(root, manifest.CatalogPath, manifest.CatalogBytes, manifest.CatalogSHA256)
	if err != nil {
		return nil, err
	}
	var data catalog
	if err := strictJSON(raw, &data); err != nil || data.Version != "emoji-catalog/v1" || data.UnicodeVersion == "" ||
		data.Count != manifest.CatalogCount || len(data.Entries) != data.Count || len(data.Categories) == 0 {
		return nil, fmt.Errorf("%w: catalog", ErrInvalidBundle)
	}
	p := &Local{entries: data.Entries, byID: map[string]int{}, assets: map[string]Asset{}, categories: map[string]bool{}}
	for _, c := range data.Categories {
		if c == "" || p.categories[c] {
			return nil, fmt.Errorf("%w: category", ErrInvalidBundle)
		}
		p.categories[c] = true
	}
	// Revision covers exact catalog bytes and every verified image digest/path.
	// Manifest order is pinned, so all processes loading this bundle agree.
	revision := sha256.New()
	revision.Write([]byte(manifest.Schema + "\x00" + manifest.CatalogSHA256 + "\x00"))
	for _, a := range manifest.Assets {
		if !validAssetPath(a.Path) || a.Bytes < 1 || a.Bytes > 1<<20 {
			return nil, fmt.Errorf("%w: asset declaration", ErrInvalidBundle)
		}
		if _, exists := p.assets[a.Path]; exists {
			return nil, fmt.Errorf("%w: duplicate asset", ErrInvalidBundle)
		}
		blob, err := readVerified(root, a.Path, a.Bytes, a.SHA256)
		if err != nil {
			return nil, err
		}
		cfg, err := png.DecodeConfig(bytes.NewReader(blob))
		if err != nil || cfg.Width < 1 || cfg.Height < 1 || cfg.Width > 512 || cfg.Height > 512 {
			return nil, fmt.Errorf("%w: png dimensions", ErrInvalidBundle)
		}
		if _, err := png.Decode(bytes.NewReader(blob)); err != nil {
			return nil, fmt.Errorf("%w: png decoding", ErrInvalidBundle)
		}
		p.assets[a.Path] = Asset{Path: a.Path, ContentType: "image/png", ETag: quotedHash(a.SHA256), Data: blob, Width: cfg.Width, Height: cfg.Height}
		revision.Write([]byte(a.Path + "\x00" + a.SHA256 + "\x00"))
	}
	used := map[string]bool{}
	for i := range p.entries {
		e := &p.entries[i]
		if e.ID == "" || !utf8.ValidString(e.ID) || e.Name == "" || e.Text == "" || !p.categories[e.Category] ||
			e.AssetETag != "" || e.AssetBytes != 0 || e.Width != 0 || e.Height != 0 {
			return nil, fmt.Errorf("%w: entry", ErrInvalidBundle)
		}
		if _, exists := p.byID[e.ID]; exists {
			return nil, fmt.Errorf("%w: duplicate ID", ErrInvalidBundle)
		}
		if e.Asset != "" {
			key, ok := strings.CutPrefix(e.Asset, "assets/emoji/")
			a, exists := p.assets[key]
			if !ok || !exists || used[key] || e.ID != "feishu:"+e.Code || key != "feishu/"+e.Code+".png" || e.Text != ":"+e.ID+":" {
				return nil, fmt.Errorf("%w: asset entry", ErrInvalidBundle)
			}
			used[key] = true
			e.Asset, e.AssetETag, e.AssetBytes, e.Width, e.Height = key, a.ETag, len(a.Data), a.Width, a.Height
		} else if strings.HasPrefix(e.ID, "feishu:") || e.Code != "" || e.Text != e.ID {
			return nil, fmt.Errorf("%w: Unicode entry", ErrInvalidBundle)
		}
		p.byID[e.ID] = i
		p.search = append(p.search, normalize(strings.Join(append([]string{e.ID, e.Code, e.Name, e.Text, e.Category, e.Group, e.Subgroup}, e.Aliases...), " ")))
	}
	if len(used) != len(p.assets) {
		return nil, fmt.Errorf("%w: unreferenced asset", ErrInvalidBundle)
	}
	r := hex.EncodeToString(revision.Sum(nil))
	p.metadata = Metadata{Version: data.Version, UnicodeVersion: data.UnicodeVersion, Revision: "sha256:" + r,
		ETag: quotedHash(r), Categories: data.Categories, CatalogCount: data.Count, AssetCount: len(p.assets)}
	return p, nil
}

func (p *Local) Metadata() Metadata {
	m := p.metadata
	m.Categories = append([]string(nil), m.Categories...)
	return m
}

func (p *Local) Contains(id string) bool {
	_, ok := p.byID[id]
	return ok
}

func (p *Local) Get(ctx context.Context, id string) (Entry, error) {
	if err := ctx.Err(); err != nil {
		return Entry{}, err
	}
	i, ok := p.byID[id]
	if !ok {
		return Entry{}, ErrUnknownEmoji
	}
	return cloneEntry(p.entries[i]), nil
}

func (p *Local) Asset(ctx context.Context, path string) (Asset, error) {
	if err := ctx.Err(); err != nil {
		return Asset{}, err
	}
	a, ok := p.assets[path]
	if !ok {
		return Asset{}, ErrAssetNotFound
	}
	a.Data = append([]byte(nil), a.Data...)
	return a, nil
}

func (p *Local) List(ctx context.Context, q Query) (Page, error) {
	if err := ctx.Err(); err != nil {
		return Page{}, err
	}
	if !utf8.ValidString(q.Q) || len(q.Q) > 400 || utf8.RuneCountInString(q.Q) > 100 || q.Offset < 0 || q.Limit < 0 || q.Limit > 200 ||
		(q.Category != "" && !p.categories[q.Category]) {
		return Page{}, ErrInvalidQuery
	}
	if q.Revision != "" && q.Revision != p.metadata.Revision {
		return Page{}, ErrRevisionChanged
	}
	if q.Limit == 0 {
		q.Limit = 100
	}
	words := strings.Fields(normalize(q.Q))
	result := Page{Metadata: p.Metadata(), Offset: q.Offset, Limit: q.Limit, Entries: []Entry{}}
	for i, e := range p.entries {
		if err := ctx.Err(); err != nil {
			return Page{}, err
		}
		if q.Category != "" && q.Category != e.Category {
			continue
		}
		matches := true
		for _, word := range words {
			if !strings.Contains(p.search[i], word) {
				matches = false
				break
			}
		}
		if !matches {
			continue
		}
		if result.Total >= q.Offset && len(result.Entries) < q.Limit {
			result.Entries = append(result.Entries, cloneEntry(e))
		}
		result.Total++
	}
	result.HasMore = q.Offset < result.Total && len(result.Entries) < result.Total-q.Offset
	if result.HasMore {
		next := q.Offset + len(result.Entries)
		result.NextOffset = &next
	}
	raw, _ := json.Marshal(result)
	result.PageETag = quotedHash(hash(raw))
	return result, nil
}

func readVerified(root fs.FS, path string, size int, expected string) ([]byte, error) {
	if !fs.ValidPath(path) || len(expected) != 64 {
		return nil, fmt.Errorf("%w: resource declaration", ErrInvalidBundle)
	}
	f, err := root.Open(path)
	if err != nil {
		return nil, fmt.Errorf("%w: resource unavailable", ErrInvalidBundle)
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() != int64(size) {
		return nil, fmt.Errorf("%w: resource size", ErrInvalidBundle)
	}
	b, err := io.ReadAll(io.LimitReader(f, int64(size)+1))
	if err != nil || len(b) != size || hash(b) != expected {
		return nil, fmt.Errorf("%w: resource digest", ErrInvalidBundle)
	}
	return b, nil
}

func validAssetPath(path string) bool {
	code, ok := strings.CutPrefix(path, "feishu/")
	code, ext := strings.CutSuffix(code, ".png")
	if !ok || !ext || code == "" {
		return false
	}
	for _, ch := range code {
		if !(ch >= 'a' && ch <= 'z') && !(ch >= 'A' && ch <= 'Z') && !(ch >= '0' && ch <= '9') && ch != '_' {
			return false
		}
	}
	return true
}

func strictJSON(raw []byte, dst any) error {
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if err := d.Decode(dst); err != nil {
		return err
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return fmt.Errorf("trailing JSON data")
	}
	return nil
}

func cloneEntry(e Entry) Entry {
	e.Aliases = append([]string{}, e.Aliases...)
	return e
}

func normalize(s string) string  { return cases.Fold().String(norm.NFKC.String(s)) }
func hash(b []byte) string       { v := sha256.Sum256(b); return hex.EncodeToString(v[:]) }
func quotedHash(s string) string { return `"sha256-` + s + `"` }
