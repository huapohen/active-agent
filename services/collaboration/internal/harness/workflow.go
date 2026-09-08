package harness

import (
	"context"
	"errors"
	"fmt"
	"time"

	"go.temporal.io/sdk/activity"
	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/worker"
	"go.temporal.io/sdk/workflow"
)

const (
	planActivityName     = "renji.agent.plan.v1"
	actionActivityName   = "renji.agent.action.v1"
	terminalActivityName = "renji.agent.terminal.v1"
)

type Activities struct {
	Gateway  Gateway
	Planner  Planner
	Archiver ArchivePlugin
}

type ActionInput struct {
	Context RunContext `json:"context"`
	Stage   int        `json:"stage"`
	Action  Action     `json:"action"`
}

type TerminalInput struct {
	Context RunContext `json:"context"`
	Result  RunResult  `json:"result"`
}

// Finalization is a separate durable activity. It writes only an audit event,
// including after a source stop; the gateway still checks current membership
// and executor binding. Retrying it cannot repeat a business action.
func (a *Activities) Terminal(ctx context.Context, input TerminalInput) error {
	if input.Context.Validate() != nil || a.Gateway == nil || input.Result.Stages < 0 || input.Result.Stages > 32 || len(input.Result.Summary) > 8000 || len(input.Result.Receipts) > 128 {
		return failure(ErrInvalid)
	}
	status := input.Result.Status
	switch status {
	case "completed", "failed", "stopped", "reconciliation_required":
	case "rejected", "stage_budget_exhausted":
		status = "failed"
	default:
		return failure(ErrInvalid)
	}
	return failure(a.Gateway.AppendEvent(ctx, input.Context, Event{ID: StableID(input.Context.RunID, "workflow-terminal-v1"), Type: "run." + status, Stage: input.Result.Stages, Data: eventData(input.Result)}))
}

func failure(err error) error {
	if errors.Is(err, ErrDenied) || errors.Is(err, ErrStopped) || errors.Is(err, ErrInvalid) {
		return temporal.NewNonRetryableApplicationError("execution contract rejected", "harness_contract_rejected", err)
	}
	return err
}

// heartbeat delivers Temporal cancellation to in-flight model/tool requests.
// Current gateway authorization is checked separately; cancellation alone is
// never evidence that a remote effect was undone.
func heartbeat(ctx context.Context) func() {
	done := make(chan struct{})
	activity.RecordHeartbeat(ctx)
	go func() {
		ticker := time.NewTicker(2 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-done:
				return
			case <-ticker.C:
				activity.RecordHeartbeat(ctx)
			}
		}
	}()
	return func() { close(done) }
}

func (a *Activities) Plan(ctx context.Context, input StageInput) (StageResult, error) {
	if err := input.Context.Validate(); err != nil {
		return StageResult{}, failure(err)
	}
	if a.Gateway == nil || a.Planner == nil {
		return StageResult{}, failure(ErrInvalid)
	}
	defer heartbeat(ctx)()
	input.Attempt = int(activity.GetInfo(ctx).Attempt)
	if err := a.Gateway.Check(ctx, input.Context); err != nil {
		return StageResult{}, failure(err)
	}
	result, err := a.Planner.Plan(ctx, input)
	if err != nil {
		return StageResult{}, failure(err)
	}
	if err = result.Validate(); err != nil {
		return StageResult{}, failure(err)
	}
	if err = a.Gateway.Check(ctx, input.Context); err != nil {
		return StageResult{}, failure(err)
	}
	if err = a.Gateway.AppendEvent(ctx, input.Context, Event{
		ID:   StableID(input.Context.RunID, fmt.Sprintf("stage:%d:attempt:%d:planned", input.Stage, input.Attempt)),
		Type: "stage.planned", Stage: input.Stage, Data: eventData(result),
	}); err != nil {
		return StageResult{}, failure(err)
	}
	return result, nil
}

func (a *Activities) Execute(ctx context.Context, input ActionInput) (Receipt, error) {
	if err := input.Context.Validate(); err != nil {
		return Receipt{}, failure(err)
	}
	if a.Gateway == nil || input.Action.ID == "" || input.Action.Type == "" {
		return Receipt{}, failure(ErrInvalid)
	}
	defer heartbeat(ctx)()
	if err := a.Gateway.Check(ctx, input.Context); err != nil {
		return Receipt{}, failure(err)
	}
	receipt, err := a.Gateway.Execute(ctx, input.Context, input.Action)
	if err != nil {
		return Receipt{}, failure(err)
	}
	if err = receipt.Validate(input.Action); err != nil {
		return Receipt{}, failure(err)
	}
	// Receipt persistence is a gateway invariant. Appending this event must be
	// idempotent too, because a crash here retries the same logical action.
	if err = a.Gateway.AppendEvent(ctx, input.Context, Event{
		ID:   StableID(input.Context.RunID, "action:"+input.Action.ID+":"+receipt.Status),
		Type: "action." + receipt.Status, Stage: input.Stage, Data: eventData(receipt),
	}); err != nil {
		return Receipt{}, failure(err)
	}
	return receipt, nil
}

// RunWorkflow has no model/network/file I/O. Completed Plan and Action activity
// results live in Temporal history. A replay therefore cannot re-plan a
// committed stage or allocate a replacement logical action ID.
func RunWorkflow(ctx workflow.Context, input RunInput) (result RunResult, runErr error) {
	if err := input.Context.Validate(); err != nil {
		return RunResult{}, failure(err)
	}
	if input.Goal == "" || len(input.Goal) > 60000 || input.MaxStages < 1 || input.MaxStages > 32 {
		return RunResult{}, failure(ErrInvalid)
	}
	options := workflow.ActivityOptions{
		StartToCloseTimeout:    2 * time.Minute,
		ScheduleToCloseTimeout: 6 * time.Minute,
		HeartbeatTimeout:       10 * time.Second,
		WaitForCancellation:    true,
		RetryPolicy:            &temporal.RetryPolicy{InitialInterval: time.Second, MaximumAttempts: 3},
	}
	ctx = workflow.WithActivityOptions(ctx, options)
	result = RunResult{Status: "running", Receipts: []Receipt{}}
	archiveStatus := ArchiveOutcome{Status: "not_scheduled"}
	if err := workflow.SetQueryHandler(ctx, ArchiveQueryName, func() (ArchiveOutcome, error) { return archiveStatus, nil }); err != nil {
		return result, err
	}
	defer func() {
		// Old histories remain replayable; new executions persist their terminal
		// status before Temporal reports completion to a caller.
		if workflow.GetVersion(ctx, "persist-terminal-event-v1", workflow.DefaultVersion, 1) == workflow.DefaultVersion {
			return
		}
		if runErr != nil {
			result.Status = "failed"
			if temporal.IsCanceledError(runErr) {
				result.Status = "stopped"
			}
		}
		finalCtx, _ := workflow.NewDisconnectedContext(ctx)
		finalCtx = workflow.WithActivityOptions(finalCtx, workflow.ActivityOptions{StartToCloseTimeout: 20 * time.Second, ScheduleToCloseTimeout: time.Minute, RetryPolicy: &temporal.RetryPolicy{InitialInterval: time.Second, MaximumAttempts: 3}})
		if err := workflow.ExecuteActivity(finalCtx, terminalActivityName, TerminalInput{input.Context, result}).Get(finalCtx, nil); err != nil {
			archiveStatus = ArchiveOutcome{Status: "skipped", Code: "terminal_not_persisted"}
			if runErr == nil {
				result.Status = "reconciliation_required"
				runErr = err
			}
			return
		}
		// Old completed histories keep their exact command sequence. Archives
		// are a separate activity after the successful terminal commit.
		if workflow.GetVersion(ctx, "automatic-terminal-archive-v1", workflow.DefaultVersion, 1) != workflow.DefaultVersion {
			executeArchive(finalCtx, input.Context.RunID, &archiveStatus)
			result.Archive = &archiveStatus
		}
	}()
	seen := make(map[string]Action)
	for stage := 0; stage < input.MaxStages; stage++ {
		var plan StageResult
		err := workflow.ExecuteActivity(ctx, planActivityName, StageInput{
			Context: input.Context, Goal: input.Goal, Stage: stage,
			Receipts: result.Receipts, PreviousSummary: result.Summary,
		}).Get(ctx, &plan)
		if err != nil {
			return result, err
		}
		if err = plan.Validate(); err != nil {
			return result, failure(err)
		}
		result.Stages = stage + 1
		result.Summary = plan.Summary
		for _, action := range plan.Actions {
			if prior, exists := seen[action.ID]; exists {
				if prior.Type != action.Type || string(prior.Payload) != string(action.Payload) {
					return result, failure(fmt.Errorf("%w: action key changed meaning", ErrInvalid))
				}
				continue
			}
			var receipt Receipt
			if err = workflow.ExecuteActivity(ctx, actionActivityName, ActionInput{input.Context, stage, action}).Get(ctx, &receipt); err != nil {
				return result, err
			}
			if err = receipt.Validate(action); err != nil {
				return result, failure(err)
			}
			result.Receipts = append(result.Receipts, receipt)
			switch receipt.Status {
			case "rejected":
				result.Status = "rejected"
				return result, nil
			case "unknown", "running":
				result.Status = "reconciliation_required"
				return result, nil
			case "succeeded":
				seen[action.ID] = action
			}
		}
		if plan.Done {
			result.Status = "completed"
			return result, nil
		}
		if plan.WaitSeconds > 0 {
			// Long waits use a durable timer, not a sleeping Activity. After the
			// timer the Plan gateway check re-evaluates current authorization.
			if err := workflow.Sleep(ctx, time.Duration(plan.WaitSeconds)*time.Second); err != nil {
				return result, err
			}
		}
	}
	result.Status = "stage_budget_exhausted"
	return result, nil
}

func Register(w worker.Worker, a *Activities) {
	w.RegisterWorkflowWithOptions(RunWorkflow, workflow.RegisterOptions{Name: WorkflowName})
	w.RegisterWorkflowWithOptions(ArchiveWorkflow, workflow.RegisterOptions{Name: ArchiveWorkflowName})
	w.RegisterActivityWithOptions(a.Plan, activity.RegisterOptions{Name: planActivityName})
	w.RegisterActivityWithOptions(a.Execute, activity.RegisterOptions{Name: actionActivityName})
	w.RegisterActivityWithOptions(a.Terminal, activity.RegisterOptions{Name: terminalActivityName})
	w.RegisterActivityWithOptions(a.Archive, activity.RegisterOptions{Name: archiveActivityName})
}
