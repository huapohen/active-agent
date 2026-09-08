# Native emoji local provider

The Go collaboration service loads one immutable, read-only snapshot from the explicitly configured absolute path to `active_agent/apps/office/assets/emoji`. A container can mount that directory read-only. There is no request to Doc Free, a Flutter service, a CDN, or any other process; no images are copied into this package. The loaded snapshot remains usable if the original directory becomes unavailable after startup. Restart with a reviewed bundle to change the snapshot.

The checked-in `bundle-manifest.json` pins the existing 812,640-byte catalog (`da72474f540bea4ff90f64e90ce583636f5ad4e76ae574a5e9df8f0e1401cf30`) and all 182 PNG digests / sizes. The catalog is byte-identical to the existing `doc_free/native-emoji-catalog.json`. It contains 4,126 unique IDs in 10 categories: 182 classic image entries and 3,944 Unicode 17.0 entries. Images total 1,880,966 bytes. This is the observed, existing bundle; no missing or newly advertised reference items are invented.

## API composition contract

```go
p, err := emoji.NewLocal(absoluteBundleDirectory)
// Caller fails startup if explicitly configured data cannot be verified.
var provider emoji.Provider = p
provider.Metadata()
provider.Contains("feishu:OK")
provider.List(ctx, emoji.Query{Q: "点赞", Category: "经典表情", Limit: 100})
provider.Get(ctx, "feishu:OK")
provider.Asset(ctx, "feishu/OK.png")
```

`Provider` is replaceable at composition time. `Contains` only accepts exact catalog IDs, including variation selectors, ZWJ and skin-tone sequences. It does not normalize reaction IDs or accept token text such as `:feishu:OK:` as an ID. Human / Agent validation must use the same injected snapshot. No identity state or user recents are stored in this package.

`List` supports category filtering, NFKC + Unicode case folding, and AND matching of whitespace-separated search words across ID / code / name / aliases / category / group / subgroup. Search is bounded to 100 Unicode scalar values and 400 UTF-8 bytes. Limit 0 means absent/default 100 in this Go API; an HTTP caller must reject explicitly supplied `limit=0`. Valid explicit limits are 1..200. Nonnegative offsets past the end return an empty page without overflow. Supplying `revision` fences pagination against another snapshot.

Page JSON contains `version`, `unicode_version`, `revision`, `etag`, `categories`, `catalog_count`, `asset_count`, `total`, `offset`, `limit`, `has_more`, nullable `next_offset`, `entries`, and `page_etag`. Revision hashes the exact catalog digest plus all verified asset paths and digests. `page_etag` identifies the logical page before its own ETag field is set. HTTP layers that transform the representation may use their own representation ETag; never use the whole-catalog ETag for arbitrary filtered pages.

`Entry.asset` is a manifest key such as `feishu/OK.png`, never a disk path or remote URL. The HTTP layer maps it to `/v1/emoji/assets/feishu/OK.png` and authenticates both catalog and image routes with current native v1 credentials. Classic entries additionally carry `asset_etag`, `asset_bytes`, `width`, `height`; Unicode entries carry no image path. `Asset` returns `{Path, ContentType, ETag, Data, Width, Height}` with independently copied bytes, PNG content type, and exact-byte SHA-256 ETag. Only an exact key lookup can return data: traversal, encoded paths, query strings, remote URLs and invented files are not resolved.

An absent provider can make only emoji-related capabilities unavailable. A configured but invalid bundle returns `ErrInvalidBundle`; do not silently fall back to Legacy. `ErrInvalidQuery`, `ErrRevisionChanged`, `ErrUnknownEmoji`, `ErrAssetNotFound`, and context cancellation are distinguishable with `errors.Is`. Authentication, HTTP/MCP validation and status mapping belong to the caller.

## Resource attribution and limits

The authoritative existing attribution is `apps/office/assets/emoji/README.md`; per-classic-image source URLs and hashes are in `feishu-sources.json`. Those classic images came from the Feishu Open Platform public emoji reference observed on 2026-09-06. Their rights remain with the original rights holder. This provider does **not** relicense the classic images under this repository's MIT license or establish permission for commercial redistribution. Existing image files and their attribution are unchanged.

Unicode data is the existing Unicode 17.0 emoji-test data, whose recorded source SHA-256 is `1d8a944f88d7952f7ef7c5167fef3c67995bcae24543949710231b03a201acda`. Existing Chinese names and aliases come from `emoji` 2.15.0, whose BSD license is already included in `PYTHON_EMOJI_LICENSE.txt`. Deployment copies or mounts must preserve those attribution/license files alongside the source bundle. The manifest here is a verification index, not an image license grant.

The fixed bundle does not claim coverage of private enterprise sticker packs, private user favorites, or all current Feishu client extensions. Unicode display still depends on the client's system font; classic PNG dimensions and bytes are verified, not re-rendered or replaced.

## Validation

`go test -race ./internal/emoji` reads the actual repository bundle and verifies all 4,126 IDs and all 182 image bytes / dimensions / digests, complete pagination, Chinese / English / fullwidth search, bounds, revision fencing, exact reaction IDs, invalid image keys, concurrent reads, defensive copies, and canceled contexts. Synthetic bundles exercise corruption / unknown schema / unknown properties / invalid mappings / oversized declarations / missing assets and filesystem root confinement. `os.OpenRoot` confines startup reads, and request methods retain no file handles. The package reuses the module's already pinned `golang.org/x/text` dependency and adds no download or service.
