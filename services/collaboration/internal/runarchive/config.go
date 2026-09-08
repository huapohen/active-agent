// Package runarchive binds a private, single-source synthetic document archive
// to real machine identity and the durable Run ledger. It is not a general
// destination chooser and does not claim production cross-service ACL atomicity.
package runarchive

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/url"
	"os"
	"sort"
	"strings"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
)

type Failure string

func (e Failure) Error() string { return string(e) }
func Code(err error) string {
	if e, ok := err.(Failure); ok {
		return string(e)
	}
	for _, pair := range []struct {
		err  error
		code string
	}{
		{domain.ErrForbidden, "archive_access_denied"},
		{domain.ErrConflict, "archive_claim_conflict"},
		{domain.ErrInvalid, "archive_invalid_request"},
		{domain.ErrStopped, "archive_source_stopped"},
		{context.Canceled, "archive_cancelled"},
		{context.DeadlineExceeded, "archive_deadline_exceeded"},
	} {
		if errors.Is(err, pair.err) {
			return pair.code
		}
	}
	return "archive_operation_failed"
}

type Config struct {
	Schema         string         `json:"schema"`
	Enabled        bool           `json:"enabled"`
	Mode           string         `json:"mode"`
	DatabaseURLEnv string         `json:"database_url_env"`
	Clerk          ClerkConfig    `json:"clerk"`
	Targets        []TargetConfig `json:"targets"`
}
type ClerkConfig struct {
	Issuer            string `json:"issuer"`
	ReceiverMachineID string `json:"receiver_machine_id"`
	MachineSecretEnv  string `json:"machine_secret_env"`
	TokenEnv          string `json:"token_env"`
}
type PrincipalMapping struct {
	GoPrincipalID      string `json:"go_principal_id"`
	DocFreePrincipalID string `json:"doc_free_principal_id"`
}
type TargetConfig struct {
	BindingID          string             `json:"binding_id"`
	ApprovedBy         string             `json:"approved_by"`
	ApprovalReference  string             `json:"approval_reference"`
	WorkspaceID        string             `json:"workspace_id"`
	SourceRoomID       string             `json:"source_room_id"`
	DocFreeEndpoint    string             `json:"doc_free_endpoint"`
	DocFreeRoomID      string             `json:"doc_free_room_id"`
	DocFreePrincipalID string             `json:"doc_free_principal_id"`
	DocFreeTokenEnv    string             `json:"doc_free_token_env"`
	PrincipalMappings  []PrincipalMapping `json:"principal_mappings"`
}

func Hash(v []byte) string { h := sha256.Sum256(v); return hex.EncodeToString(h[:]) }
func safeID(v string) bool {
	if v == "" || len(v) > 160 {
		return false
	}
	for _, c := range v {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.') {
			return false
		}
	}
	return v != "." && v != ".."
}
func envName(v string) bool {
	if v == "" || len(v) > 128 {
		return false
	}
	for i, c := range v {
		if !(c >= 'A' && c <= 'Z' || c == '_' || (i > 0 && c >= '0' && c <= '9')) {
			return false
		}
	}
	return true
}
func endpoint(v string) error {
	u, e := url.Parse(v)
	if e != nil || u.User != nil || u.Hostname() == "" || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || u.Path != "" && u.Path != "/" {
		return Failure("invalid_doc_free_endpoint")
	}
	ip := net.ParseIP(u.Hostname())
	loopback := u.Hostname() == "localhost" || ip != nil && ip.IsLoopback()
	if u.Scheme != "https" && (u.Scheme != "http" || !loopback) {
		return Failure("https_required")
	}
	return nil
}
func (c Config) Validate() error {
	if c.Schema != "renji.run-archive.v1" || c.Mode != "single_source_synthetic" || !envName(c.DatabaseURLEnv) || !envName(c.Clerk.MachineSecretEnv) || !envName(c.Clerk.TokenEnv) || len(c.Targets) < 1 || len(c.Targets) > 20 {
		return Failure("invalid_archive_configuration")
	}
	ids, rooms := map[string]bool{}, map[string]bool{}
	for _, t := range c.Targets {
		if !safeID(t.BindingID) || !safeID(t.WorkspaceID) || !safeID(t.SourceRoomID) || !safeID(t.DocFreeRoomID) || !safeID(t.DocFreePrincipalID) || !envName(t.DocFreeTokenEnv) || t.ApprovedBy == "" || t.ApprovalReference == "" || len(t.ApprovedBy) > 200 || len(t.ApprovalReference) > 500 || ids[t.BindingID] || rooms[t.SourceRoomID] || len(t.PrincipalMappings) < 1 || len(t.PrincipalMappings) > 100 {
			return Failure("invalid_target_binding")
		}
		if err := endpoint(t.DocFreeEndpoint); err != nil {
			return err
		}
		ids[t.BindingID] = true
		rooms[t.SourceRoomID] = true
		goIDs, docIDs := map[string]bool{}, map[string]bool{}
		writer := false
		for _, m := range t.PrincipalMappings {
			if !safeID(m.GoPrincipalID) || !safeID(m.DocFreePrincipalID) || goIDs[m.GoPrincipalID] || docIDs[m.DocFreePrincipalID] {
				return Failure("invalid_principal_mapping")
			}
			goIDs[m.GoPrincipalID] = true
			docIDs[m.DocFreePrincipalID] = true
			writer = writer || m.DocFreePrincipalID == t.DocFreePrincipalID
		}
		if !writer {
			return Failure("writer_mapping_required")
		}
	}
	return nil
}
func (t TargetConfig) fingerprint() string {
	t.DocFreeEndpoint = strings.TrimRight(t.DocFreeEndpoint, "/")
	t.PrincipalMappings = append([]PrincipalMapping(nil), t.PrincipalMappings...)
	sort.Slice(t.PrincipalMappings, func(i, j int) bool {
		return t.PrincipalMappings[i].GoPrincipalID < t.PrincipalMappings[j].GoPrincipalID
	})
	raw, _ := json.Marshal(t)
	return Hash(raw)
}
func LoadConfig(path string) (Config, error) {
	var c Config
	info, e := os.Lstat(path)
	if e != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 100000 {
		return c, Failure("private_archive_configuration_required")
	}
	raw, e := os.ReadFile(path)
	if e != nil {
		return c, Failure("archive_configuration_unreadable")
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(&c) != nil || d.Decode(new(any)) != io.EOF {
		return c, Failure("invalid_archive_configuration")
	}
	return c, c.Validate()
}
