// Package documents projects canonical Doc Free documents to explicitly approved
// downstream namespaces. It never imports a downstream body into Doc Free.
package documents

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

type Snapshot struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	Content     string `json:"content"`
	Revision    int64  `json:"revision"`
	ContentHash string `json:"content_hash"`
}

func Hash(text string) string { b := sha256.Sum256([]byte(text)); return hex.EncodeToString(b[:]) }

// Markdown renderers differ in their terminal newline, but internal whitespace,
// Unicode, paragraphs, and order remain significant. No fuzzy matching is used.
func BodyHash(text string) string {
	return Hash(strings.TrimRight(strings.ReplaceAll(text, "\r\n", "\n"), "\n"))
}
func (s Snapshot) Validate() error {
	if s.ID == "" || s.Revision < 1 || strings.TrimSpace(s.Title) == "" || len(s.Title) > 2000 || len(s.Content) > 1_000_000 || Hash(s.Content) != s.ContentHash {
		return Failure("invalid_source_snapshot")
	}
	return nil
}

type Binding struct {
	ID             string `json:"id"`
	PrincipalID    string `json:"principal_id"`
	SourceEndpoint string `json:"source_endpoint"`
	RoomID         string `json:"room_id"`
	DocumentID     string `json:"document_id"`
	Target         string `json:"target"`
	TargetEndpoint string `json:"target_endpoint"`
	NamespaceID    string `json:"namespace_id"`
	// This is a privileged deployment configuration, never a client assertion.
	ApprovedBy           string `json:"approved_by"`
	ApprovalReference    string `json:"approval_reference"`
	Generation           int64  `json:"generation"`
	Enabled              bool   `json:"enabled"`
	GatewayOnlyNamespace bool   `json:"gateway_only_namespace"`
}

func (b Binding) Validate() error {
	if !b.Enabled || b.Generation < 1 || !b.GatewayOnlyNamespace || b.ApprovedBy == "" || b.ApprovalReference == "" {
		return Failure("projection_not_approved")
	}
	if b.ID == "" || b.PrincipalID == "" || b.SourceEndpoint == "" || b.RoomID == "" || b.DocumentID == "" || b.NamespaceID == "" || b.TargetEndpoint == "" || (b.Target != "affine" && b.Target != "docmost") {
		return Failure("invalid_binding")
	}
	return nil
}
func (b Binding) fingerprint() string { raw, _ := json.Marshal(b); return Hash(string(raw)) }

type Observation struct {
	ExternalID, BodyHash, TitleHash string
	TitleReadable                   bool
}
type Source interface {
	Read(context.Context, Binding) (Snapshot, error)
}
type Target interface {
	Name() string
	Scope() (string, string)
	ValidateSnapshot(Snapshot) error
	Read(context.Context, string) (Observation, error)
	Create(context.Context, Snapshot) (string, error)
	Update(context.Context, string, Snapshot, func() error) error
}

// Store must serialize workers for its complete lifetime, and Append must be
// durable before returning. Implementations may use PG transactions or a file
// journal. A memory cache by itself does not satisfy this interface's contract.
type Store interface {
	Lock(context.Context) (func(), error)
	Latest(string) (Record, bool)
	Append(Record) error
}
type Guard func(context.Context, Binding) error

type Record struct {
	BindingID         string    `json:"binding_id"`
	BindingHash       string    `json:"binding_hash"`
	Sequence          int64     `json:"sequence"`
	State             string    `json:"state"`
	ExternalID        string    `json:"external_id,omitempty"`
	SourceRevision    int64     `json:"source_revision"`
	SourceContentHash string    `json:"source_content_hash"`
	DesiredBodyHash   string    `json:"desired_body_hash"`
	DesiredTitleHash  string    `json:"desired_title_hash"`
	ObservedBodyHash  string    `json:"observed_body_hash,omitempty"`
	ObservedTitleHash string    `json:"observed_title_hash,omitempty"`
	TitleVerified     bool      `json:"title_verified"`
	ErrorCode         string    `json:"error_code,omitempty"`
	At                time.Time `json:"at"`
}

// Error strings contain bounded codes only. Never include provider messages,
// source bodies, headers, cookies or response bytes in a journal or UI result.
type Failure string

func (f Failure) Error() string { return string(f) }
func Code(err error) string {
	var f Failure
	if errors.As(err, &f) {
		return string(f)
	}
	return "adapter_unavailable"
}

type Engine struct {
	Source Source
	Target Target
	Store  Store
	Guard  Guard
	Now    func() time.Time
}

func (e *Engine) Sync(ctx context.Context, b Binding) (Record, error) {
	var last Record
	if err := b.Validate(); err != nil {
		return last, err
	}
	if e.Source == nil || e.Target == nil || e.Store == nil || e.Guard == nil || e.Target.Name() != b.Target {
		return last, Failure("gateway_not_configured")
	}
	release, lockErr := e.Store.Lock(ctx)
	if lockErr != nil {
		return last, lockErr
	}
	defer release()
	targetEndpoint, targetNamespace := e.Target.Scope()
	if targetEndpoint != strings.TrimRight(b.TargetEndpoint, "/") || targetNamespace != b.NamespaceID {
		return last, Failure("target_binding_mismatch")
	}
	check := func() error {
		if err := ctx.Err(); err != nil {
			return Failure("cancelled")
		}
		return e.Guard(ctx, b)
	}
	if err := check(); err != nil {
		return last, err
	}
	prior, exists := e.Store.Latest(b.ID)
	if exists && prior.BindingHash != b.fingerprint() {
		return prior, Failure("binding_changed_requires_reconciliation")
	}
	if exists && prior.State == "not_sent" {
		exists = false
	}
	source, err := e.Source.Read(ctx, b)
	if err != nil {
		return prior, err
	}
	if err = source.Validate(); err != nil {
		return prior, err
	}
	if source.ID != b.DocumentID {
		return prior, Failure("source_scope_mismatch")
	}
	if err := e.Target.ValidateSnapshot(source); err != nil {
		return prior, err
	}
	now := time.Now
	if e.Now != nil {
		now = e.Now
	}
	save := func(r Record, state, code string) (Record, error) {
		r.Sequence++
		r.State = state
		r.ErrorCode = code
		r.At = now().UTC()
		if err := e.Store.Append(r); err != nil {
			return r, Failure("journal_unavailable")
		}
		return r, nil
	}
	// Every downstream effect rereads current member access and checks that the
	// approved source version is still current. AFFiNE's separate title/body calls
	// invoke this fence separately. This is not an atomic cross-service commit.
	fence := func() error {
		if err := check(); err != nil {
			return err
		}
		live, err := e.Source.Read(ctx, b)
		if err != nil {
			return err
		}
		if err = live.Validate(); err != nil {
			return err
		}
		if live.ID != source.ID || live.Revision != source.Revision || live.ContentHash != source.ContentHash || live.Title != source.Title {
			return Failure("source_changed")
		}
		return nil
	}
	if exists {
		if prior.State == "conflict" {
			return prior, Failure("target_conflict_requires_resolution")
		}
		if prior.ExternalID == "" {
			return prior, Failure("create_outcome_unknown")
		}
		observed, err := e.Target.Read(ctx, prior.ExternalID)
		if err != nil {
			return prior, err
		}
		if observed.ExternalID != prior.ExternalID {
			return prior, Failure("target_scope_mismatch")
		}
		sameDesired := observed.BodyHash == prior.DesiredBodyHash && (!observed.TitleReadable || observed.TitleHash == prior.DesiredTitleHash)
		// An interrupted known-ID write may only be reconciled by readback. It is
		// never automatically resent, since provider APIs expose no version CAS.
		if prior.State == "prepared" || prior.State == "submitted" || prior.State == "unknown" {
			if !sameDesired {
				r, x := save(prior, "unknown", "write_outcome_unknown")
				if x != nil {
					return r, x
				}
				return r, Failure("write_outcome_unknown")
			}
			prior.ObservedBodyHash = observed.BodyHash
			prior.ObservedTitleHash = observed.TitleHash
			prior.TitleVerified = observed.TitleReadable
			state := "verified"
			if !observed.TitleReadable {
				state = "partial_verification"
			}
			if err := fence(); err != nil {
				return prior, err
			}
			prior, err = save(prior, state, "")
			if err != nil {
				return prior, err
			}
			// Return this recovered result; a later invocation handles a newer source.
			return prior, nil
		}

		// A newly connected metadata reader can complete a previously partial
		// receipt without resending either title or body.
		if prior.State == "partial_verification" && observed.TitleReadable && sameDesired {
			if err := fence(); err != nil {
				return prior, err
			}
			prior.ObservedTitleHash = observed.TitleHash
			prior.TitleVerified = true
			prior, err = save(prior, "verified", "")
			if err != nil {
				return prior, err
			}
		}
		if observed.BodyHash != prior.ObservedBodyHash || (observed.TitleReadable && observed.TitleHash != prior.ObservedTitleHash) {
			r, x := save(prior, "conflict", "external_change_detected")
			if x != nil {
				return r, x
			}
			return r, Failure("external_change_detected")
		}
		if source.Revision < prior.SourceRevision {
			return prior, Failure("source_revision_regressed")
		}
		if source.Revision == prior.SourceRevision {
			if source.ContentHash != prior.SourceContentHash || BodyHash(source.Content) != prior.DesiredBodyHash || Hash(source.Title) != prior.DesiredTitleHash {
				return prior, Failure("source_revision_collision")
			}
			return prior, nil
		}
	}
	current := Record{BindingID: b.ID, BindingHash: b.fingerprint(), Sequence: prior.Sequence, ExternalID: prior.ExternalID, SourceRevision: source.Revision, SourceContentHash: source.ContentHash, DesiredBodyHash: BodyHash(source.Content), DesiredTitleHash: Hash(source.Title)}
	if err := fence(); err != nil {
		return prior, err
	}
	current, err = save(current, "prepared", "")
	if err != nil {
		return current, err
	}
	if err := fence(); err != nil {
		// No downstream request was made. Retain the prior stable record when one
		// exists; otherwise no create attempt has occurred and a retry is safe.
		if exists {
			prior.Sequence = current.Sequence
			current, saveErr := save(prior, prior.State, Code(err))
			if saveErr != nil {
				return current, saveErr
			}
			return current, err
		}
		current, saveErr := save(current, "not_sent", Code(err))
		if saveErr != nil {
			return current, saveErr
		}
		return current, err
	}
	if current.ExternalID == "" {
		current.ExternalID, err = e.Target.Create(ctx, source)
	} else {
		err = e.Target.Update(ctx, current.ExternalID, source, fence)
	}
	if err != nil {
		r, x := save(current, "unknown", Code(err))
		if x != nil {
			return r, x
		}
		return r, err
	}
	if current.ExternalID == "" {
		r, x := save(current, "unknown", "missing_external_id")
		if x != nil {
			return r, x
		}
		return r, Failure("missing_external_id")
	}
	current, err = save(current, "submitted", "")
	if err != nil {
		return current, err
	}
	observed, err := e.Target.Read(ctx, current.ExternalID)
	if err != nil {
		r, x := save(current, "unknown", Code(err))
		if x != nil {
			return r, x
		}
		return r, err
	}
	current.ObservedBodyHash = observed.BodyHash
	current.ObservedTitleHash = observed.TitleHash
	current.TitleVerified = observed.TitleReadable && observed.TitleHash == current.DesiredTitleHash
	if observed.ExternalID != current.ExternalID || observed.BodyHash != current.DesiredBodyHash || (observed.TitleReadable && !current.TitleVerified) {
		r, x := save(current, "unknown", "readback_mismatch")
		if x != nil {
			return r, x
		}
		return r, Failure("readback_mismatch")
	}
	// A revoked/changed source after dispatch is an in-flight result, not a grant
	// to continue. Record the effect and require reconciliation.
	if err := fence(); err != nil {
		r, x := save(current, "unknown", Code(err))
		if x != nil {
			return r, x
		}
		return r, err
	}
	state := "verified"
	if !observed.TitleReadable {
		state = "partial_verification"
	}
	return save(current, state, "")
}

func RequireSafeID(id string) error {
	if id == "" || len(id) > 160 || strings.ContainsAny(id, "/?#%\\\r\n") || id == "." || id == ".." {
		return Failure("invalid_resource_id")
	}
	return nil
}
func (r Record) String() string {
	return fmt.Sprintf("%s: %s (source revision %d)", r.BindingID, r.State, r.SourceRevision)
}
