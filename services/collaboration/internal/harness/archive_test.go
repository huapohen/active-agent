package harness

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"go.temporal.io/sdk/activity"
	"go.temporal.io/sdk/testsuite"
	"go.temporal.io/sdk/workflow"
)

type archiveFunc func(context.Context, string) (ArchiveOutcome, error)

func (f archiveFunc) ArchiveRun(ctx context.Context, id string) (ArchiveOutcome, error) {
	return f(ctx, id)
}

type plannerFunc func(context.Context, StageInput) (StageResult, error)

func (f plannerFunc) Plan(ctx context.Context, in StageInput) (StageResult, error) { return f(ctx, in) }
func archiveVerified() ArchiveOutcome {
	return ArchiveOutcome{Status: "verified", ArchiveID: "archive-a", Through: 5, VerifiedThrough: 5, Parts: []ArchivePart{{Part: 1, State: "verified", ExternalID: "doc-a"}}}
}
func archiveEnv(a *Activities) *testsuite.TestWorkflowEnvironment {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	env.RegisterWorkflowWithOptions(RunWorkflow, workflow.RegisterOptions{Name: WorkflowName})
	env.RegisterWorkflowWithOptions(ArchiveWorkflow, workflow.RegisterOptions{Name: ArchiveWorkflowName})
	env.RegisterActivityWithOptions(a.Plan, activity.RegisterOptions{Name: planActivityName})
	env.RegisterActivityWithOptions(a.Execute, activity.RegisterOptions{Name: actionActivityName})
	env.RegisterActivityWithOptions(a.Terminal, activity.RegisterOptions{Name: terminalActivityName})
	env.RegisterActivityWithOptions(a.Archive, activity.RegisterOptions{Name: archiveActivityName})
	return env
}
func queryArchive(t *testing.T, env *testsuite.TestWorkflowEnvironment) ArchiveOutcome {
	t.Helper()
	q, e := env.QueryWorkflow(ArchiveQueryName)
	require.NoError(t, e)
	var out ArchiveOutcome
	require.NoError(t, q.Get(&out))
	return out
}
func simpleArchivePlanner(calls *int) Planner {
	return plannerFunc(func(context.Context, StageInput) (StageResult, error) {
		*calls++
		return StageResult{Done: true, Summary: "完成本地动作", Actions: []Action{{ID: StableID("run-a", "send"), Type: "message.send", Payload: json.RawMessage(`{"content":"test"}`)}}}, nil
	})
}

func TestTemporalArchiveRunsOnlyAfterTerminalAndKeepsBusinessResult(t *testing.T) {
	g := &fakeGateway{}
	plans, archives := 0, 0
	a := &Activities{Gateway: g, Planner: simpleArchivePlanner(&plans), Archiver: archiveFunc(func(_ context.Context, id string) (ArchiveOutcome, error) {
		archives++
		require.Equal(t, "run-a", id)
		require.Equal(t, "run.completed", g.events[len(g.events)-1].Type)
		return archiveVerified(), nil
	})}
	env := archiveEnv(a)
	env.ExecuteWorkflow(WorkflowName, RunInput{Context: runContext(), Goal: "finish", MaxStages: 1})
	require.NoError(t, env.GetWorkflowError())
	var out RunResult
	require.NoError(t, env.GetWorkflowResult(&out))
	require.Equal(t, "completed", out.Status)
	require.Equal(t, "verified", out.Archive.Status)
	require.Equal(t, 1, plans)
	require.Equal(t, 1, g.effects)
	require.Equal(t, 1, archives)
	require.Equal(t, *out.Archive, queryArchive(t, env))
	// The terminal event is business evidence; archive results arrive later and
	// must not change its stable event payload on a retry.
	require.NotContains(t, string(g.events[len(g.events)-1].Data), `"archive"`)
}
func TestTemporalArchiveRetriesOnlyArchiveAndBoundsKnownIDReconciliation(t *testing.T) {
	for _, recover := range []bool{true, false} {
		t.Run(map[bool]string{true: "recovers", false: "exhausts"}[recover], func(t *testing.T) {
			g := &fakeGateway{}
			plans, calls := 0, 0
			a := &Activities{Gateway: g, Planner: simpleArchivePlanner(&plans), Archiver: archiveFunc(func(context.Context, string) (ArchiveOutcome, error) {
				calls++
				if recover && calls == 3 {
					return archiveVerified(), nil
				}
				return ArchiveOutcome{Status: "attention", ArchiveID: "archive-a", Code: "doc_free_transport_unknown", Retryable: true, Parts: []ArchivePart{{Part: 1, State: "unknown", ExternalID: "doc-a"}}}, nil
			})}
			env := archiveEnv(a)
			env.ExecuteWorkflow(WorkflowName, RunInput{Context: runContext(), Goal: "finish", MaxStages: 1})
			require.NoError(t, env.GetWorkflowError())
			var out RunResult
			require.NoError(t, env.GetWorkflowResult(&out))
			require.Equal(t, "completed", out.Status)
			require.Equal(t, 3, calls)
			require.Equal(t, 1, plans)
			require.Equal(t, 1, g.effects)
			arch := queryArchive(t, env)
			require.Equal(t, 3, arch.Attempts)
			require.False(t, arch.Retryable)
			if recover {
				require.Equal(t, "verified", arch.Status)
			} else {
				require.Equal(t, "attention", arch.Status)
				require.Equal(t, "doc-a", arch.Parts[0].ExternalID)
			}
		})
	}
}

func TestTemporalArchiveClaimLeaseWaitDoesNotRepeatBusinessOrTerminal(t *testing.T) {
	g := &fakeGateway{}
	plans, calls := 0, 0
	var env *testsuite.TestWorkflowEnvironment
	var attemptsAt []time.Time
	a := &Activities{Gateway: g, Planner: simpleArchivePlanner(&plans), Archiver: archiveFunc(func(context.Context, string) (ArchiveOutcome, error) {
		calls++
		attemptsAt = append(attemptsAt, env.Now())
		if calls < 3 {
			return ArchiveOutcome{Status: "attention", ArchiveID: "archive-a", Code: "archive_claim_conflict", Retryable: true, Parts: []ArchivePart{{Part: 1, State: "unknown", ExternalID: "doc-a"}}}, nil
		}
		return archiveVerified(), nil
	})}
	env = archiveEnv(a)
	env.ExecuteWorkflow(WorkflowName, RunInput{Context: runContext(), Goal: "recover lease", MaxStages: 1})
	require.NoError(t, env.GetWorkflowError())
	require.Len(t, attemptsAt, 3)
	require.Equal(t, 125*time.Second, attemptsAt[1].Sub(attemptsAt[0]))
	require.Equal(t, 125*time.Second, attemptsAt[2].Sub(attemptsAt[1]))
	require.Equal(t, 1, plans)
	require.Equal(t, 1, g.effects)
	terminalEvents := 0
	for _, event := range g.events {
		if strings.HasPrefix(event.Type, "run.") {
			terminalEvents++
		}
	}
	require.Equal(t, 1, terminalEvents)
	require.Equal(t, "verified", queryArchive(t, env).Status)
}
func TestTemporalArchiveUnknownWithoutIDNeverRetriesAndErrorsAreBounded(t *testing.T) {
	for _, mode := range []string{"unknown", "raw-error", "panic", "invalid-provider-result"} {
		t.Run(mode, func(t *testing.T) {
			calls := 0
			a := &Activities{Archiver: archiveFunc(func(context.Context, string) (ArchiveOutcome, error) {
				calls++
				switch mode {
				case "unknown":
					return ArchiveOutcome{Status: "attention", ArchiveID: "archive-a", Code: "create_outcome_unknown", Retryable: true, Parts: []ArchivePart{{Part: 1, State: "unknown"}}}, nil
				case "raw-error":
					return ArchiveOutcome{}, errors.New("secret-token=private-test")
				case "panic":
					panic("secret-token=private-test")
				default:
					return ArchiveOutcome{Status: "verified", Code: "https://private.test/?secret=private-test"}, nil
				}
			})}
			env := archiveEnv(a)
			env.ExecuteWorkflow(ArchiveWorkflowName, ArchiveInput{RunID: "run-a"})
			require.NoError(t, env.GetWorkflowError())
			out := queryArchive(t, env)
			require.Equal(t, "attention", out.Status)
			require.Equal(t, 1, calls)
			raw, e := json.Marshal(out)
			require.NoError(t, e)
			require.NotContains(t, string(raw), "private-test")
			require.NotContains(t, string(raw), "secret-token")
		})
	}
}

type terminalRejectGateway struct{ fakeGateway }

func (g *terminalRejectGateway) AppendEvent(ctx context.Context, rc RunContext, e Event) error {
	if strings.HasPrefix(e.Type, "run.") {
		return ErrDenied
	}
	return g.fakeGateway.AppendEvent(ctx, rc, e)
}
func TestTemporalArchiveIsSkippedWhenTerminalCommitFails(t *testing.T) {
	g := &terminalRejectGateway{}
	plans, calls := 0, 0
	a := &Activities{Gateway: g, Planner: simpleArchivePlanner(&plans), Archiver: archiveFunc(func(context.Context, string) (ArchiveOutcome, error) { calls++; return archiveVerified(), nil })}
	env := archiveEnv(a)
	env.ExecuteWorkflow(WorkflowName, RunInput{Context: runContext(), Goal: "finish", MaxStages: 1})
	require.Error(t, env.GetWorkflowError())
	require.Zero(t, calls)
	require.Equal(t, 1, g.effects)
	require.Equal(t, "terminal_not_persisted", queryArchive(t, env).Code)
}
func TestTemporalFailedAndCancelledBusinessStillExposeArchiveQuery(t *testing.T) {
	for _, cancel := range []bool{false, true} {
		t.Run(map[bool]string{false: "failure", true: "cancel"}[cancel], func(t *testing.T) {
			g := &fakeGateway{}
			calls := 0
			p := plannerFunc(func(context.Context, StageInput) (StageResult, error) {
				if !cancel {
					return StageResult{}, ErrDenied
				}
				return StageResult{Summary: "wait", WaitSeconds: 30}, nil
			})
			a := &Activities{Gateway: g, Planner: p, Archiver: archiveFunc(func(context.Context, string) (ArchiveOutcome, error) {
				calls++
				expected := "run.failed"
				if cancel {
					expected = "run.stopped"
				}
				require.Equal(t, expected, g.events[len(g.events)-1].Type)
				return archiveVerified(), nil
			})}
			env := archiveEnv(a)
			if cancel {
				env.RegisterDelayedCallback(env.CancelWorkflow, time.Second)
			}
			env.ExecuteWorkflow(WorkflowName, RunInput{Context: runContext(), Goal: "fail", MaxStages: 2})
			require.Error(t, env.GetWorkflowError())
			require.Equal(t, 1, calls)
			require.Zero(t, g.effects)
			require.Equal(t, "verified", queryArchive(t, env).Status)
		})
	}
}
func TestTemporalArchiveAbsentConfigurationIsDurableDisabled(t *testing.T) {
	env := archiveEnv(&Activities{})
	env.ExecuteWorkflow(ArchiveWorkflowName, ArchiveInput{RunID: "run-a"})
	require.NoError(t, env.GetWorkflowError())
	var out ArchiveOutcome
	require.NoError(t, env.GetWorkflowResult(&out))
	require.Equal(t, "disabled", out.Status)
	require.Equal(t, "archive_not_configured", out.Code)
	require.Equal(t, out, queryArchive(t, env))
}
func TestTemporalLegacyHistoryVersionDoesNotScheduleNewArchive(t *testing.T) {
	g := &fakeGateway{}
	plans, calls := 0, 0
	a := &Activities{Gateway: g, Planner: simpleArchivePlanner(&plans), Archiver: archiveFunc(func(context.Context, string) (ArchiveOutcome, error) { calls++; return archiveVerified(), nil })}
	env := archiveEnv(a)
	env.OnGetVersion("automatic-terminal-archive-v1", workflow.DefaultVersion, workflow.Version(1)).Return(workflow.DefaultVersion)
	env.ExecuteWorkflow(WorkflowName, RunInput{Context: runContext(), Goal: "old history", MaxStages: 1})
	require.NoError(t, env.GetWorkflowError())
	require.Zero(t, calls)
	var out RunResult
	require.NoError(t, env.GetWorkflowResult(&out))
	require.Nil(t, out.Archive)
	require.Equal(t, "not_scheduled", queryArchive(t, env).Status)
}
