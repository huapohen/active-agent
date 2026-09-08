// Package harness implements bounded Agent stages. Temporal owns the durable
// lifecycle; business effects are committed only through the action gateway.
package harness

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
)

const (
	RuntimeType     = "eino-deepagents"
	RuntimeVersion  = "eino-v0.9.19-renji-1"
	WorkflowVersion = "renji-stage-v1"
	WorkflowName    = "renji.agent.run.v1"
	TaskQueue       = "renji-agent-v1"
)

var (
	ErrDenied         = errors.New("harness authorization denied")
	ErrStopped        = errors.New("harness source scope stopped")
	ErrInvalid        = errors.New("invalid harness request")
	ErrOutcomeUnknown = errors.New("action outcome requires reconciliation")
	keyPattern        = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,64}$`)
)

type Scope struct {
	RoomID string `json:"room_id"`
	Epoch  int64  `json:"epoch"`
}

// RunContext is persisted execution metadata, never an authentication claim.
// The gateway authenticates the worker credential and resolves these values
// against its registered Run and executor binding on every request.
type RunContext struct {
	PrincipalID     string  `json:"principal_id"`
	ExecutorID      string  `json:"executor_id"`
	RunID           string  `json:"run_id"`
	RoomID          string  `json:"room_id"`
	ScopeEpoch      int64   `json:"scope_epoch"`
	OriginScopes    []Scope `json:"origin_scopes,omitempty"`
	RuntimeVersion  string  `json:"runtime_version"`
	WorkflowVersion string  `json:"workflow_version"`
}

func (r RunContext) Validate() error {
	if strings.TrimSpace(r.PrincipalID) == "" || strings.TrimSpace(r.ExecutorID) == "" || strings.TrimSpace(r.RunID) == "" || strings.TrimSpace(r.RoomID) == "" || r.ScopeEpoch < 0 {
		return fmt.Errorf("%w: missing execution binding", ErrInvalid)
	}
	for _, id := range []string{r.PrincipalID, r.ExecutorID, r.RunID, r.RoomID} {
		if len(id) > 128 {
			return fmt.Errorf("%w: invalid execution identifier", ErrInvalid)
		}
	}
	if len(r.OriginScopes) > 16 {
		return fmt.Errorf("%w: origin scope budget exceeded", ErrInvalid)
	}
	if r.RuntimeVersion != RuntimeVersion || r.WorkflowVersion != WorkflowVersion {
		return fmt.Errorf("%w: runtime or workflow version unsupported", ErrInvalid)
	}
	seen := make(map[string]int64)
	for _, scope := range append([]Scope{{r.RoomID, r.ScopeEpoch}}, r.OriginScopes...) {
		if scope.RoomID == "" || len(scope.RoomID) > 128 || scope.Epoch < 0 {
			return fmt.Errorf("%w: invalid origin scope", ErrInvalid)
		}
		if prior, ok := seen[scope.RoomID]; ok && prior != scope.Epoch {
			return fmt.Errorf("%w: conflicting origin epochs", ErrInvalid)
		}
		seen[scope.RoomID] = scope.Epoch
	}
	return nil
}

type Action struct {
	ID      string          `json:"id"`
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload"`
}

type Receipt struct {
	ActionID string          `json:"action_id"`
	Status   string          `json:"status"`
	Result   json.RawMessage `json:"result,omitempty"`
}

func (r Receipt) Validate(action Action) error {
	if r.ActionID != action.ID {
		return fmt.Errorf("%w: receipt identity mismatch", ErrInvalid)
	}
	// Large artifacts live behind resource IDs; receipt history stays bounded.
	if len(r.Result) > 8192 || (len(r.Result) > 0 && !json.Valid(r.Result)) {
		return fmt.Errorf("%w: receipt result invalid or oversized", ErrInvalid)
	}
	switch r.Status {
	case "succeeded", "rejected", "running", "unknown":
		return nil
	default:
		return fmt.Errorf("%w: invalid receipt status", ErrInvalid)
	}
}

type Event struct {
	ID        string          `json:"id"`
	Type      string          `json:"type"`
	Stage     int             `json:"stage"`
	AgentPath string          `json:"agent_path,omitempty"`
	Data      json.RawMessage `json:"data,omitempty"`
}

// Gateway implementations must enforce current scope epochs, Run/executor
// binding and object permissions, and durably deduplicate actions/events.
// An external timeout is unknown, not proof that the operation failed.
type Gateway interface {
	Check(context.Context, RunContext) error
	Execute(context.Context, RunContext, Action) (Receipt, error)
	AppendEvent(context.Context, RunContext, Event) error
}

type StageInput struct {
	Context         RunContext `json:"context"`
	Goal            string     `json:"goal"`
	Stage           int        `json:"stage"`
	Attempt         int        `json:"attempt"`
	Receipts        []Receipt  `json:"receipts,omitempty"`
	PreviousSummary string     `json:"previous_summary,omitempty"`
}

type StageResult struct {
	Summary     string   `json:"summary"`
	Actions     []Action `json:"actions"`
	Done        bool     `json:"done"`
	WaitSeconds int      `json:"wait_seconds,omitempty"`
}

func (s StageResult) Validate() error {
	if strings.TrimSpace(s.Summary) == "" || len(s.Summary) > 8000 || len(s.Actions) > 4 || s.WaitSeconds < 0 || s.WaitSeconds > 86400 || (s.Done && s.WaitSeconds > 0) || (!s.Done && s.WaitSeconds == 0 && len(s.Actions) == 0) {
		return ErrInvalid
	}
	seen := map[string]bool{}
	for _, a := range s.Actions {
		id, err := hex.DecodeString(a.ID)
		if err != nil || len(id) != 32 || a.Type == "" || len(a.Payload) > 60000 || !json.Valid(a.Payload) || seen[a.ID] {
			return ErrInvalid
		}
		seen[a.ID] = true
	}
	return nil
}

type RunInput struct {
	Context   RunContext `json:"context"`
	Goal      string     `json:"goal"`
	MaxStages int        `json:"max_stages"`
}

type RunResult struct {
	Status   string          `json:"status"`
	Summary  string          `json:"summary"`
	Stages   int             `json:"stages"`
	Receipts []Receipt       `json:"receipts"`
	Archive  *ArchiveOutcome `json:"archive,omitempty"`
}

type Planner interface {
	Plan(context.Context, StageInput) (StageResult, error)
}

func StableID(runID, logicalKey string) string {
	sum := sha256.Sum256([]byte(runID + "\x00" + logicalKey))
	return hex.EncodeToString(sum[:])
}

func eventData(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}
