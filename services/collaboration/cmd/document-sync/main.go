// document-sync performs one operator-approved projection pass. It never
// enumerates or exports all rooms, and never logs credential or document bodies.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"time"

	"github.com/huapohen/active-agent/services/collaboration/internal/documents"
)

type config struct {
	Journal  string          `json:"journal"`
	Bindings []bindingConfig `json:"bindings"`
}
type bindingConfig struct {
	documents.Binding
	SourceCredentialFile         string `json:"source_credential_file"`
	TargetCredentialFile         string `json:"target_credential_file"`
	TargetMetadataCredentialFile string `json:"target_metadata_credential_file,omitempty"`
}

func privateRead(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 2_000_000 {
		return nil, documents.Failure("private_file_required")
	}
	return os.ReadFile(path)
}
func readConfig(path string) (config, error) {
	var c config
	raw, err := privateRead(path)
	if err != nil {
		return c, err
	}
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	if dec.Decode(&c) != nil {
		return c, documents.Failure("invalid_config")
	}
	if dec.Decode(new(any)) != io.EOF {
		return c, documents.Failure("invalid_config")
	}
	if !filepath.IsAbs(c.Journal) || len(c.Bindings) == 0 {
		return c, documents.Failure("invalid_config")
	}
	seen := map[string]bool{}
	for _, b := range c.Bindings {
		if b.ID == "" || seen[b.ID] || !filepath.IsAbs(b.SourceCredentialFile) || !filepath.IsAbs(b.TargetCredentialFile) {
			return c, documents.Failure("invalid_config")
		}
		if b.TargetMetadataCredentialFile != "" && (!filepath.IsAbs(b.TargetMetadataCredentialFile) || b.Target != "affine") {
			return c, documents.Failure("invalid_config")
		}
		seen[b.ID] = true
	}
	return c, nil
}
func credential(path, provider string) (string, error) {
	raw, err := privateRead(path)
	if err != nil {
		return "", err
	}
	text := strings.TrimSpace(string(raw))
	if provider == "docmost" {
		for _, line := range strings.Split(text, "\n") {
			parts := strings.Split(line, "\t")
			if len(parts) == 7 && parts[5] == "authToken" {
				return parts[6], nil
			}
		}
	}
	if strings.HasPrefix(text, "{") {
		var v struct {
			Token string `json:"token"`
			Data  struct {
				Create struct {
					Token string `json:"token"`
				} `json:"createMcpCredential"`
			} `json:"data"`
		}
		if json.Unmarshal(raw, &v) != nil {
			return "", documents.Failure("invalid_credential_file")
		}
		if v.Token != "" {
			text = v.Token
		} else {
			text = v.Data.Create.Token
		}
	}
	if text == "" || strings.ContainsAny(text, "\r\n") {
		return "", documents.Failure("invalid_credential_file")
	}
	return text, nil
}
func run(ctx context.Context, path string) int { return runSelected(ctx, path, "", "", "", "") }
func runSelected(ctx context.Context, path, onlyBinding, nativeProfile, nativeCodec, nativeNode string) int {
	if nativeProfile != "" && nativeProfile != documents.DocmostNativeProfile && nativeProfile != documents.AffineNativeProfile {
		emitError(documents.Failure("unsupported_native_profile"))
		return 2
	}
	c, err := readConfig(path)
	if err != nil {
		emitError(err)
		return 2
	}
	if onlyBinding != "" {
		found := false
		for _, b := range c.Bindings {
			if b.ID == onlyBinding && b.Enabled {
				found = true
			}
		}
		if !found {
			emitError(documents.Failure("binding_not_found"))
			return 2
		}
	}
	journal, err := documents.OpenFileJournal(c.Journal)
	if err != nil {
		emitError(err)
		return 2
	}
	defer journal.Close()
	code := 0
	for _, binding := range c.Bindings {
		if !binding.Enabled || onlyBinding != "" && binding.ID != onlyBinding {
			continue
		}
		if err := binding.Validate(); err != nil {
			emitError(err)
			code = 1
			continue
		}
		sourceToken, err := credential(binding.SourceCredentialFile, "doc_free")
		if err != nil {
			emitError(err)
			code = 1
			continue
		}
		targetToken, err := credential(binding.TargetCredentialFile, binding.Target)
		if err != nil {
			emitError(err)
			code = 1
			continue
		}
		source, err := documents.NewDocFree(binding.SourceEndpoint, sourceToken)
		if err != nil {
			emitError(err)
			code = 1
			continue
		}
		var target documents.Target
		switch binding.Target {
		case "affine":
			target, err = documents.NewAffine(binding.TargetEndpoint, binding.NamespaceID, targetToken)
		case "docmost":
			target, err = documents.NewDocmost(binding.TargetEndpoint, binding.NamespaceID, targetToken)
		default:
			err = documents.Failure("unsupported_target")
		}
		if err != nil {
			emitError(err)
			code = 1
			continue
		}

		if binding.TargetMetadataCredentialFile != "" {
			metadataCredential, loadErr := credential(binding.TargetMetadataCredentialFile, "affine_metadata")
			if loadErr != nil {
				emitError(loadErr)
				code = 1
				continue
			}
			if err = target.(*documents.Affine).WithMetadataReadback(metadataCredential); err != nil {
				emitError(err)
				code = 1
				continue
			}
		}
		if nativeProfile == documents.AffineNativeProfile && binding.Target == "affine" {
			if err := target.(*documents.Affine).WithNativeCodec(nativeCodec, nativeNode); err != nil {
				emitError(err)
				code = 1
				continue
			}
		}
		guard := func(ctx context.Context, b documents.Binding) error {
			live, err := readConfig(path)
			if err != nil {
				return documents.Failure("approval_unavailable")
			}
			if live.Journal != c.Journal {
				return documents.Failure("approval_changed")
			}
			for _, entry := range live.Bindings {
				if entry.ID == b.ID {
					if !reflect.DeepEqual(entry, binding) {
						return documents.Failure("approval_changed")
					}
					return entry.Validate()
				}
			}
			return documents.Failure("approval_revoked")
		}
		engine := documents.Engine{Source: source, Target: target, Store: journal, Guard: guard, NativeVerificationProfile: nativeProfile}
		result, err := engine.Sync(ctx, binding.Binding)
		output := map[string]any{"binding_id": binding.ID, "target": binding.Target, "record": result}
		if err != nil {
			output["error_code"] = documents.Code(err)
			code = 1
		} else if result.State != "verified" && result.State != "native_verified" {
			code = 1
		}
		json.NewEncoder(os.Stdout).Encode(output)
	}
	return code
}
func emitError(err error) {
	json.NewEncoder(os.Stderr).Encode(map[string]string{"error_code": documents.Code(err)})
}
func main() {
	path := flag.String("config", "", "private absolute JSON configuration path")
	timeout := flag.Duration("timeout", 2*time.Minute, "overall deadline for one pass")
	onlyBinding := flag.String("binding", "", "process only this explicitly configured binding")
	nativeProfile := flag.String("native-profile", "", "opt in to an exact supported native reconciliation profile")
	nativeCodec := flag.String("native-codec", "", "absolute directory of the installed AFFiNE native codec")
	nativeNode := flag.String("native-node", "", "absolute trusted Node executable for the native codec")
	flag.Parse()
	if !filepath.IsAbs(*path) || *timeout <= 0 || flag.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "usage: document-sync -config /absolute/private/config.json [-binding id] [-native-profile profile] [-timeout 2m]")
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	os.Exit(runSelected(ctx, *path, *onlyBinding, *nativeProfile, *nativeCodec, *nativeNode))
}
