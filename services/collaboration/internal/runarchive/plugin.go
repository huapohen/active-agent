package runarchive

import (
	"context"
	"encoding/json"

	"github.com/huapohen/active-agent/services/collaboration/internal/auth"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
)

// TerminalPlugin is a replaceable harness plugin, not a second workflow engine.
// It holds deployment-owned configuration and performs only archival operations.
type TerminalPlugin struct{ runner *Runner }

var _ harness.ArchivePlugin = (*TerminalPlugin)(nil)

func (r *Runner) requireTerminal(ctx context.Context, runID string) error {
	reader, err := r.authenticate(ctx)
	if err != nil {
		return err
	}
	q := store.EvidenceQuery{Limit: 100, Mode: "audit"}
	// Keep the ledger prefix fixed. An event found here is a stored execution
	// event, never a model sentence that happens to contain "run.completed".
	for pageIndex := 0; pageIndex < 1000; pageIndex++ {
		current, err := r.fresh(ctx, reader)
		if err != nil {
			return err
		}
		page, err := r.store.ReadExecutionEvidence(ctx, current, runID, q)
		if err != nil {
			return err
		}
		switch page.Run.Status {
		case "completed", "failed", "stopped", "reconciliation_required":
		default:
			return Failure("archive_run_not_terminal")
		}
		for _, entry := range page.Entries {
			if page.Run.Status == "stopped" && entry.Kind == "run.status" && entry.ObjectID == page.Run.Context.RunID {
				// A room can stop after planning but before Terminal commits. Store
				// preserves that original executor report while its database trigger
				// records the canonical stopped transition. Only this server-owned
				// evidence kind can establish stop without a run.stopped report.
				var transition struct {
					Status string `json:"status"`
				}
				if json.Unmarshal(entry.Data, &transition) == nil && transition.Status == "stopped" {
					return nil
				}
			}
			if entry.Kind != "event" {
				continue
			}
			var envelope struct {
				Event harness.Event `json:"event"`
			}
			if json.Unmarshal(entry.Data, &envelope) != nil {
				return Failure("archive_terminal_evidence_invalid")
			}
			if envelope.Event.Type == "run."+page.Run.Status {
				return nil
			}
		}
		if !page.HasMore {
			return Failure("archive_terminal_fact_missing")
		}
		q.After = page.Cursor
		q.Through = &page.Through
	}
	return Failure("archive_terminal_evidence_limit")
}

func (p *TerminalPlugin) ArchiveRun(ctx context.Context, runID string) (harness.ArchiveOutcome, error) {
	if p == nil || p.runner == nil {
		return harness.ArchiveOutcome{Status: "disabled", Code: "archive_not_configured"}, nil
	}
	r := p.runner
	if !r.config.Enabled {
		return harness.ArchiveOutcome{Status: "disabled", Code: "run_archive_disabled"}, nil
	}
	if err := r.requireTerminal(ctx, runID); err != nil {
		return harness.ArchiveOutcome{Status: "attention", Code: Code(err)}, nil
	}
	result, err := r.Run(ctx, runID)
	out := harness.ArchiveOutcome{Status: "attention", ArchiveID: result.Archive.ID, Through: result.Archive.Through, VerifiedThrough: result.Archive.VerifiedThrough, Code: result.ErrorCode}
	unknownWithoutID := false
	for _, part := range result.Archive.Parts {
		out.Parts = append(out.Parts, harness.ArchivePart{Part: part.Part, State: part.State, ExternalID: part.ExternalID})
		unknownWithoutID = unknownWithoutID || (part.State == "unknown" && part.ExternalID == "")
	}
	if err == nil && result.Status == "verified" {
		out.Status = "verified"
		return out, nil
	}
	if out.Code == "" {
		out.Code = Code(err)
	}
	if unknownWithoutID || out.Code == "create_outcome_unknown" {
		return out, nil
	}
	// The Runner itself owns durable one-write semantics. Retrying these bounded
	// failures reconciles existing IDs; it never resets intent or claim state.
	switch out.Code {
	case "doc_free_transport_unknown", "doc_free_http_failure", "invalid_doc_free_response", "invalid_doc_free_document", "archive_readback_mismatch", "archive_claim_conflict", "archive_deadline_exceeded":
		out.Retryable = true
	}
	return out, nil
}

// OpenDeployment is the composition boundary. Only the process owner chooses a
// private config path; Workflow input contains no path, URL, body or credential.
// No config or explicitly disabled config requires no database/network access.
func OpenDeployment(ctx context.Context, path string, getenv func(string) string) (harness.ArchivePlugin, func(), string, error) {
	noop := func() {}
	if path == "" {
		return nil, noop, "disabled_no_config", nil
	}
	c, err := LoadConfig(path)
	if err != nil {
		return nil, noop, "", err
	}
	if !c.Enabled {
		return &TerminalPlugin{}, noop, "disabled_by_config", nil
	}
	if getenv == nil {
		return nil, noop, "", Failure("archive_environment_missing")
	}
	v, err := auth.NewClerkMachine(auth.ClerkMachineConfig{Issuer: c.Clerk.Issuer, ReceiverMachineID: c.Clerk.ReceiverMachineID, MachineSecretKey: getenv(c.Clerk.MachineSecretEnv)})
	if err != nil {
		return nil, noop, "", Failure("invalid_clerk_configuration")
	}
	dsn := getenv(c.DatabaseURLEnv)
	if dsn == "" {
		return nil, noop, "", Failure("database_configuration_missing")
	}
	s, err := store.Open(ctx, dsn)
	if err != nil {
		return nil, noop, "", Failure("archive_database_unavailable")
	}
	r, err := New(c, s, v, getenv)
	if err != nil {
		s.Close()
		return nil, noop, "", err
	}
	return &TerminalPlugin{runner: r}, s.Close, "single_source_synthetic", nil
}
