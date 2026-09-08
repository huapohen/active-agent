// Package emoji supplies an immutable local emoji catalog. It has no identity,
// network, or HTTP dependency; callers authenticate all catalog and asset reads.
package emoji

import (
	"context"
	"errors"
)

var (
	ErrInvalidBundle   = errors.New("invalid_emoji_bundle")
	ErrInvalidQuery    = errors.New("invalid_emoji_query")
	ErrUnknownEmoji    = errors.New("unknown_emoji")
	ErrAssetNotFound   = errors.New("emoji_asset_not_found")
	ErrRevisionChanged = errors.New("emoji_revision_changed")
)

// Provider is replaceable at application composition time. Contains must use
// the same snapshot as List/Get so humans and agents share reaction validation.
type Provider interface {
	Metadata() Metadata
	Contains(id string) bool
	List(context.Context, Query) (Page, error)
	Get(context.Context, string) (Entry, error)
	Asset(context.Context, string) (Asset, error)
}

type Metadata struct {
	Version        string   `json:"version"`
	UnicodeVersion string   `json:"unicode_version"`
	Revision       string   `json:"revision"`
	ETag           string   `json:"etag"`
	Categories     []string `json:"categories"`
	CatalogCount   int      `json:"catalog_count"`
	AssetCount     int      `json:"asset_count"`
}

type Entry struct {
	ID         string   `json:"id"`
	Code       string   `json:"code,omitempty"`
	Name       string   `json:"name"`
	Aliases    []string `json:"aliases"`
	Category   string   `json:"category"`
	Group      string   `json:"group"`
	Subgroup   string   `json:"subgroup"`
	Text       string   `json:"text"`
	Asset      string   `json:"asset,omitempty"`
	AssetETag  string   `json:"asset_etag,omitempty"`
	AssetBytes int      `json:"asset_bytes,omitempty"`
	Width      int      `json:"width,omitempty"`
	Height     int      `json:"height,omitempty"`
}

// Asset is a copy of verified bytes. Path is a manifest key such as
// feishu/OK.png, never a local filesystem path or a remote URL. HTTP callers
// map Path under their authenticated /v1/emoji/assets/ route.
type Asset struct {
	Path        string
	ContentType string
	ETag        string
	Data        []byte
	Width       int
	Height      int
}

type Query struct {
	Q        string
	Category string
	Offset   int
	Limit    int    // Zero defaults to 100; explicit HTTP limit=0 must be rejected there.
	Revision string // Optional optimistic fence for subsequent pages.
}

type Page struct {
	Metadata
	Total      int     `json:"total"`
	Offset     int     `json:"offset"`
	Limit      int     `json:"limit"`
	HasMore    bool    `json:"has_more"`
	NextOffset *int    `json:"next_offset"`
	Entries    []Entry `json:"entries"`
	PageETag   string  `json:"page_etag"`
}
