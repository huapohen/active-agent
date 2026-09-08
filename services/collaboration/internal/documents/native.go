package documents

import (
	"context"
	"encoding/json"
	"time"
)

// NativeProof is appended only after a complete same-version native comparison.
// Raw Markdown mismatch remains explicit; this is not byte_verified or a claim
// of pixel layout / cross-application link navigation equivalence.
type NativeProof struct {
	Profile              string `json:"profile"`
	TargetVersion        string `json:"target_version"`
	SourceCanonicalHash  string `json:"source_canonical_hash"`
	TargetCanonicalHash  string `json:"target_canonical_hash"`
	TargetNativeRawHash  string `json:"target_native_raw_hash"`
	PlatformBehaviorHash string `json:"platform_behavior_hash"`
	PlatformDifferences  int    `json:"platform_differences"`
	MarkdownExportError  string `json:"markdown_export_error"`
}

type NativeTarget interface {
	VerifyNative(context.Context, string, Snapshot, Observation) (NativeProof, error)
	CheckNativeBaseline(context.Context, string, Observation, NativeProof) error
}

// Profile selection is explicit so adding code-block support cannot broaden an
// existing v1 journal's interpretation or silently relabel its proof.
type ProfiledNativeTarget interface {
	VerifyNativeProfile(context.Context, string, Snapshot, Observation, string) (NativeProof, error)
}

func nativeVersionValid(version string) bool {
	_, e := time.Parse(time.RFC3339Nano, version)
	return version != "" && e == nil
}

func (d *Docmost) nativePage(ctx context.Context, id string) (docmostPage, error) {
	r, e := d.call(ctx, "pages/info", map[string]any{"pageId": id, "includeContent": true, "includeSpace": true})
	if e != nil {
		return r, e
	}
	if r.ID != id || len(r.Content) == 0 || !nativeVersionValid(r.UpdatedAt) {
		return r, Failure("invalid_native_response")
	}
	var kind struct {
		Type string `json:"type"`
	}
	if json.Unmarshal(r.Content, &kind) != nil || kind.Type != "doc" {
		return r, Failure("invalid_native_response")
	}
	return r, nil
}

// Four authorized reads fence both representations around the same target
// version. This is a bounded stability check, not a provider-side transaction.
func (d *Docmost) stableNative(ctx context.Context, id string, before Observation) (docmostPage, error) {
	var empty docmostPage
	if before.ExternalID != id || !before.TitleReadable || before.RawBodyHash == "" || !nativeVersionValid(before.Version) {
		return empty, Failure("native_version_required")
	}
	first, e := d.nativePage(ctx, id)
	if e != nil {
		return empty, e
	}
	second, e := d.Read(ctx, id)
	if e != nil {
		return empty, e
	}
	last, e := d.nativePage(ctx, id)
	if e != nil {
		return empty, e
	}
	if first.UpdatedAt != before.Version || last.UpdatedAt != before.Version || second.Version != before.Version || Hash(first.Title) != before.TitleHash || Hash(last.Title) != before.TitleHash || second.TitleHash != before.TitleHash || second.RawBodyHash != before.RawBodyHash || second.BodyHash != before.BodyHash || Hash(string(first.Content)) != Hash(string(last.Content)) {
		return empty, Failure("target_changed_during_native_verification")
	}
	return last, nil
}
func (d *Docmost) VerifyNative(ctx context.Context, id string, source Snapshot, observed Observation) (NativeProof, error) {
	return d.VerifyNativeProfile(ctx, id, source, observed, DocmostNativeProfile)
}
func (d *Docmost) VerifyNativeProfile(ctx context.Context, id string, source Snapshot, observed Observation, profile string) (NativeProof, error) {
	var p NativeProof
	if nativeProfileProvider(profile) != "docmost" {
		return p, Failure("unsupported_native_profile")
	}
	if err := source.Validate(); err != nil {
		return p, err
	}
	if !observed.TitleReadable || observed.TitleHash != Hash(source.Title) {
		return p, Failure("native_title_mismatch")
	}
	n, e := d.stableNative(ctx, id, observed)
	if e != nil {
		return p, e
	}
	proof, e := CompareDocmostNativeProfile(source.Content, n.Content, profile)
	if e != nil {
		return p, e
	}
	p = NativeProof{Profile: profile, TargetVersion: n.UpdatedAt, SourceCanonicalHash: proof.SourceHash, TargetCanonicalHash: proof.TargetHash, TargetNativeRawHash: Hash(string(n.Content)), PlatformBehaviorHash: proof.PlatformHash, PlatformDifferences: proof.PlatformDifferences, MarkdownExportError: "readback_mismatch"}
	if observed.BodyHash == BodyHash(source.Content) {
		p.MarkdownExportError = ""
	}
	return p, nil
}
func (d *Docmost) CheckNativeBaseline(ctx context.Context, id string, observed Observation, proof NativeProof) error {
	if nativeProfileProvider(proof.Profile) != "docmost" || proof.TargetNativeRawHash == "" || proof.SourceCanonicalHash != proof.TargetCanonicalHash {
		return Failure("invalid_native_receipt")
	}
	n, e := d.stableNative(ctx, id, observed)
	if e != nil {
		return e
	}
	if n.UpdatedAt != proof.TargetVersion || Hash(string(n.Content)) != proof.TargetNativeRawHash {
		return Failure("external_native_change_detected")
	}
	return nil
}
