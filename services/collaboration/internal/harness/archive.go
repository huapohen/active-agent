package harness

import (
	"context"
	"strings"
	"time"

	"go.temporal.io/sdk/activity"
	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/workflow"
)

const (
	ArchiveWorkflowName = "renji.agent.archive.v1"
	ArchiveQueryName    = "renji.archive.status.v1"
	archiveActivityName = "renji.agent.archive.v1"
	archiveMaxAttempts  = 3
)

// ArchivePlugin is implemented outside harness. A deployment binds identity,
// credentials and destinations; none are accepted from a Workflow or model.
// Implementations must require a server-persisted terminal event and make
// uncertain writes durable before returning. Retries never imply another POST.
type ArchivePlugin interface {
	ArchiveRun(context.Context, string) (ArchiveOutcome, error)
}

type ArchiveInput struct {
	RunID string `json:"run_id"`
}
type ArchivePart struct {
	Part       int    `json:"part"`
	State      string `json:"state"`
	ExternalID string `json:"external_id,omitempty"`
}
type ArchiveOutcome struct {
	Status          string        `json:"status"`
	ArchiveID       string        `json:"archive_id,omitempty"`
	Through         int64         `json:"through,omitempty"`
	VerifiedThrough int64         `json:"verified_through,omitempty"`
	Parts           []ArchivePart `json:"parts,omitempty"`
	Code            string        `json:"code,omitempty"`
	Attempts        int           `json:"attempts,omitempty"`
	Retryable       bool          `json:"retryable,omitempty"`
}

func archiveID(v string) bool {
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
func (o ArchiveOutcome) validate() bool {
	if o.Status != "verified" && o.Status != "disabled" && o.Status != "attention" {
		return false
	}
	if o.ArchiveID != "" && !archiveID(o.ArchiveID) || len(o.Parts) > 512 || len(o.Code) > 100 || o.Through < 0 || o.VerifiedThrough < -1 {
		return false
	}
	for _, c := range o.Code {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_') {
			return false
		}
	}
	seen := map[int]bool{}
	for _, p := range o.Parts {
		if p.Part < 1 || seen[p.Part] || p.ExternalID != "" && !archiveID(p.ExternalID) {
			return false
		}
		seen[p.Part] = true
		if p.State != "verified" && p.State != "unknown" && p.State != "prepared" && p.State != "in_flight" {
			return false
		}
		if o.Status == "verified" && (p.State != "verified" || p.ExternalID == "") {
			return false
		}
	}
	return o.Status != "verified" || (o.ArchiveID != "" && len(o.Parts) > 0 && o.VerifiedThrough == o.Through && !o.Retryable)
}

// Archive is independent of Plan, Execute and Terminal. Only safe metadata is
// returned to Temporal; arbitrary provider errors, titles and bodies are never
// serialized into a new archive Activity's input/result/failure.
func (a *Activities) Archive(ctx context.Context, input ArchiveInput) (result ArchiveOutcome, resultErr error) {
	defer func() {
		if recover() != nil {
			// A replaceable plugin must not put arbitrary panic text or provider
			// response bodies into Temporal failure history.
			result = ArchiveOutcome{Status: "attention", Code: "archive_plugin_panicked"}
			resultErr = nil
		}
	}()
	if !archiveID(input.RunID) {
		return ArchiveOutcome{Status: "attention", Code: "archive_invalid_run"}, nil
	}
	if a.Archiver == nil {
		return ArchiveOutcome{Status: "disabled", Code: "archive_not_configured"}, nil
	}
	defer heartbeat(ctx)()
	out, err := a.Archiver.ArchiveRun(ctx, input.RunID)
	if err != nil {
		out = ArchiveOutcome{Status: "attention", Code: "archive_plugin_failed"}
	}
	if !out.validate() {
		out = ArchiveOutcome{Status: "attention", Code: "archive_plugin_contract_invalid"}
	}
	out.Attempts = int(activity.GetInfo(ctx).Attempt)
	if out.Attempts < 1 {
		out.Attempts = 1
	}
	// A missing ID on an unknown part is a durable unresolved create, never a
	// reason for automatic retry even if a replacement plugin asks for one.
	for _, p := range out.Parts {
		if p.State == "unknown" && p.ExternalID == "" {
			out.Retryable = false
		}
	}
	if out.Status == "attention" && out.Retryable && out.Attempts < archiveMaxAttempts {
		if out.Code == "archive_claim_conflict" {
			// Store claims live for two minutes. A killed worker's read claim
			// must expire before reconciliation takes over; rapid retries would
			// exhaust the budget while the original lease was still valid.
			return out, temporal.NewApplicationErrorWithOptions("archive claim awaits lease expiry", "archive_retry", temporal.ApplicationErrorOptions{Details: []interface{}{out}, NextRetryDelay: 125 * time.Second})
		}
		return out, temporal.NewApplicationError("archive readback requires a bounded retry", "archive_retry", out)
	}
	out.Retryable = false
	return out, nil
}

func executeArchive(ctx workflow.Context, runID string, status *ArchiveOutcome) {
	*status = ArchiveOutcome{Status: "pending"}
	ctx = workflow.WithActivityOptions(ctx, workflow.ActivityOptions{
		StartToCloseTimeout: 2 * time.Minute, ScheduleToCloseTimeout: 11 * time.Minute,
		HeartbeatTimeout: 10 * time.Second, WaitForCancellation: true,
		RetryPolicy: &temporal.RetryPolicy{InitialInterval: 2 * time.Second, MaximumInterval: 10 * time.Second, MaximumAttempts: archiveMaxAttempts},
	})
	var out ArchiveOutcome
	if err := workflow.ExecuteActivity(ctx, archiveActivityName, ArchiveInput{RunID: runID}).Get(ctx, &out); err != nil {
		out = ArchiveOutcome{Status: "attention", Code: "archive_activity_failed"}
		if temporal.IsCanceledError(err) {
			out.Code = "archive_activity_cancelled"
		}
	}
	*status = out
}

// ArchiveWorkflow only archives/reconciles a Run whose terminal fact is already
// persisted. It never invokes the model, business actions or a terminal writer.
// Even a failed/cancelled parent Run can be archived by a separately scheduled
// workflow, subject to the plugin's current machine and full-source ACL checks.
func ArchiveWorkflow(ctx workflow.Context, input ArchiveInput) (out ArchiveOutcome, err error) {
	out = ArchiveOutcome{Status: "not_scheduled"}
	if e := workflow.SetQueryHandler(ctx, ArchiveQueryName, func() (ArchiveOutcome, error) { return out, nil }); e != nil {
		return out, e
	}
	if !archiveID(strings.TrimSpace(input.RunID)) || strings.TrimSpace(input.RunID) != input.RunID {
		return ArchiveOutcome{Status: "attention", Code: "archive_invalid_run"}, nil
	}
	executeArchive(ctx, input.RunID, &out)
	return out, nil
}
