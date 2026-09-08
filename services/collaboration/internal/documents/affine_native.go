package documents

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
)

const AffineNativeProfile = "affine.database-v3.rich-text.b4c8548c0.v1"

func (h *HTTP) binary(ctx context.Context, path string) ([]byte, string, error) {
	req, e := http.NewRequestWithContext(ctx, http.MethodGet, h.base+path, nil)
	if e != nil {
		return nil, "", Failure("invalid_request")
	}
	req.Header = h.headers.Clone()
	req.Header.Set("Accept", "application/octet-stream")
	res, e := h.client.Do(req)
	if e != nil {
		return nil, "", Failure("adapter_unavailable")
	}
	defer res.Body.Close()
	if res.StatusCode == 401 || res.StatusCode == 403 {
		return nil, "", Failure("access_denied")
	}
	if res.StatusCode == 404 {
		return nil, "", Failure("not_found")
	}
	if res.StatusCode != 200 || res.Header.Get("Content-Type") != "application/octet-stream" {
		return nil, "", Failure("invalid_native_response")
	}
	b, e := io.ReadAll(io.LimitReader(res.Body, 2_000_001))
	if e != nil || len(b) == 0 || len(b) > 2_000_000 {
		return nil, "", Failure("invalid_native_response")
	}
	etag := res.Header.Get("ETag")
	if len(etag) > 512 {
		return nil, "", Failure("invalid_native_response")
	}
	return b, etag, nil
}
func (a *Affine) WithNativeCodec(directory, nodeExecutable string) error {
	if !filepath.IsAbs(directory) || !filepath.IsAbs(nodeExecutable) {
		return Failure("invalid_native_codec")
	}
	p := filepath.Join(directory, "verify-stdio.mjs")
	info, e := os.Lstat(p)
	if e != nil || !info.Mode().IsRegular() {
		return Failure("native_codec_unavailable")
	}
	resolved, e := filepath.EvalSymlinks(nodeExecutable)
	if e != nil {
		return Failure("native_node_unavailable")
	}
	binary, e := os.Stat(resolved)
	if e != nil || !binary.Mode().IsRegular() || binary.Mode().Perm()&0111 == 0 {
		return Failure("native_node_unavailable")
	}
	a.NativeCodecPath = p
	a.NativeNodeExecutable = resolved
	return nil
}
func (a *Affine) nativeBytes(ctx context.Context, id string) ([]byte, string, error) {
	if a.MetadataHTTP == nil {
		return nil, "", Failure("native_read_credential_required")
	}
	if e := RequireSafeID(id); e != nil {
		return nil, "", e
	}
	return a.MetadataHTTP.binary(ctx, "/api/workspaces/"+url.PathEscape(a.WorkspaceID)+"/docs/"+url.PathEscape(id))
}
func (a *Affine) stableNative(ctx context.Context, id string, before Observation) ([]byte, error) {
	if before.ExternalID != id || !before.TitleReadable || before.RawBodyHash == "" {
		return nil, Failure("native_title_required")
	}
	first, etag, e := a.nativeBytes(ctx, id)
	if e != nil {
		return nil, e
	}
	middle, e := a.Read(ctx, id)
	if e != nil {
		return nil, e
	}
	last, lastETag, e := a.nativeBytes(ctx, id)
	if e != nil {
		return nil, e
	}
	if etag == "" || etag != lastETag || Hash(string(first)) != Hash(string(last)) || before.RawBodyHash != middle.RawBodyHash || before.BodyHash != middle.BodyHash || before.TitleHash != middle.TitleHash {
		return nil, Failure("target_changed_during_native_verification")
	}
	return last, nil
}

type boundedOutput struct{ bytes.Buffer }

func (w *boundedOutput) Write(p []byte) (int, error) {
	if len(p) > 64000-w.Len() {
		return 0, Failure("native_codec_output_limit")
	}
	return w.Buffer.Write(p)
}
func (a *Affine) compareNative(ctx context.Context, source Snapshot, native []byte) (NativeProof, error) {
	var p NativeProof
	if a.NativeCodecPath == "" || a.NativeNodeExecutable == "" {
		return p, Failure("native_codec_unavailable")
	}
	tree, e := markdownTree(source.Content)
	if e != nil {
		return p, e
	}
	input, e := json.Marshal(map[string]any{"profile": AffineNativeProfile, "source": tree, "title": source.Title, "snapshot": base64.StdEncoding.EncodeToString(native)})
	if e != nil {
		return p, Failure("invalid_native_request")
	}
	cmd := exec.CommandContext(ctx, a.NativeNodeExecutable, "--max-old-space-size=256", a.NativeCodecPath)
	// This process handles documents only. It must never inherit model, auth,
	// transport credentials, NODE_OPTIONS, NODE_PATH or shell runtime hooks.
	cmd.Env = []string{"LANG=C.UTF-8", "LC_ALL=C.UTF-8"}
	cmd.Dir = filepath.Dir(a.NativeCodecPath)
	cmd.Stdin = bytes.NewReader(input)
	var output boundedOutput
	cmd.Stdout = &output
	cmd.Stderr = io.Discard
	if e := cmd.Run(); e != nil {
		return p, Failure("native_structure_not_verified")
	}
	var result struct {
		Profile       string `json:"profile"`
		SourceHash    string `json:"source_hash"`
		TargetHash    string `json:"target_hash"`
		SnapshotHash  string `json:"snapshot_hash"`
		VisitedBlocks int    `json:"visited_blocks"`
	}
	decoder := json.NewDecoder(bytes.NewReader(output.Bytes()))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&result) != nil || decoder.Decode(new(any)) != io.EOF {
		return p, Failure("invalid_native_proof")
	}
	desired := Hash(string(canonicalBytes(tree)))
	raw := Hash(string(native))
	if result.Profile != AffineNativeProfile || result.SourceHash != desired || result.TargetHash != desired || result.SnapshotHash != raw || result.VisitedBlocks < 1 {
		return p, Failure("native_structure_mismatch")
	}
	return NativeProof{Profile: AffineNativeProfile, TargetVersion: "sha256:" + raw, SourceCanonicalHash: desired, TargetCanonicalHash: result.TargetHash, TargetNativeRawHash: raw, PlatformBehaviorHash: Hash("[]"), MarkdownExportError: "readback_mismatch"}, nil
}
func (a *Affine) VerifyNative(ctx context.Context, id string, source Snapshot, observed Observation) (NativeProof, error) {
	var p NativeProof
	if e := source.Validate(); e != nil {
		return p, e
	}
	if !observed.TitleReadable || observed.TitleHash != Hash(source.Title) {
		return p, Failure("native_title_mismatch")
	}
	native, e := a.stableNative(ctx, id, observed)
	if e != nil {
		return p, e
	}
	return a.compareNative(ctx, source, native)
}
func (a *Affine) CheckNativeBaseline(ctx context.Context, id string, observed Observation, proof NativeProof) error {
	if proof.Profile != AffineNativeProfile || proof.TargetNativeRawHash == "" || proof.SourceCanonicalHash != proof.TargetCanonicalHash {
		return Failure("invalid_native_receipt")
	}
	native, e := a.stableNative(ctx, id, observed)
	if e != nil {
		return e
	}
	raw := Hash(string(native))
	if raw != proof.TargetNativeRawHash || proof.TargetVersion != "sha256:"+raw {
		return Failure("external_native_change_detected")
	}
	return nil
}
