package runarchive

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
	"github.com/stretchr/testify/require"
	"go.temporal.io/sdk/activity"
	"go.temporal.io/sdk/testsuite"
	"go.temporal.io/sdk/workflow"
)

func TestTerminalArchivePluginRequiresPersistedTerminalFact(t *testing.T) {
	for _, mode := range []string{"running", "status-without-fact", "status-other-terminal", "revoked", "failed"} {
		t.Run(mode, func(t *testing.T) {
			d, s := newDocFree(t)
			f := newFixture(t, s.URL)
			ctx := context.Background()
			runID := f.run.Context.RunID
			if mode == "running" || mode == "status-without-fact" {
				run, e := f.s.CreateExecutionRun(ctx, f.agent, store.CreateExecutionRunCommand{ActionID: "new-nonterminal", ExecutorID: f.run.Context.ExecutorID, RoomID: f.room.ID, ScopeEpoch: f.room.ScopeEpoch, Goal: "no terminal"})
				require.NoError(t, e)
				runID = run.Context.RunID
				require.NoError(t, f.s.AppendExecutionEvent(ctx, testIssuer, testSubject, run.Context, harness.Event{ID: harness.StableID(runID, "fake-terminal-prose"), Type: "model.output", Data: json.RawMessage(`{"status":"run.completed","text":"我说完成并不等于服务端终态"}`)}))
				if mode == "status-without-fact" {
					_, e = f.s.Pool.Exec(ctx, "UPDATE execution_runs SET status='failed' WHERE id=$1", runID)
					require.NoError(t, e)
				}
			}
			if mode == "revoked" {
				_, e := f.s.Pool.Exec(ctx, "DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2", f.room.ID, f.agent)
				require.NoError(t, e)
			}
			if mode == "status-other-terminal" {
				_, e := f.s.Pool.Exec(ctx, "UPDATE execution_runs SET status='completed' WHERE id=$1", runID)
				require.NoError(t, e)
			}
			p := &TerminalPlugin{runner: f.runner(t)}
			out, e := p.ArchiveRun(ctx, runID)
			require.NoError(t, e)
			posts, _ := d.counts()
			if mode == "failed" {
				require.Equal(t, "verified", out.Status)
				require.Equal(t, 1, posts)
			} else {
				require.Equal(t, "attention", out.Status)
				require.Zero(t, posts)
				require.False(t, out.Retryable)
			}
			if mode == "running" {
				require.Equal(t, "archive_run_not_terminal", out.Code)
			}
			if mode == "status-without-fact" || mode == "status-other-terminal" {
				require.Equal(t, "archive_terminal_fact_missing", out.Code)
			}
		})
	}
}
func TestArchiveWorkflowWithRealPostgresReconcilesKnownIDWithoutSecondPost(t *testing.T) {
	d, s := newDocFree(t)
	d.mode = "read-fails-once"
	f := newFixture(t, s.URL)
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	a := &harness.Activities{Archiver: &TerminalPlugin{runner: f.runner(t)}}
	env.RegisterWorkflowWithOptions(harness.ArchiveWorkflow, workflow.RegisterOptions{Name: harness.ArchiveWorkflowName})
	env.RegisterActivityWithOptions(a.Archive, activity.RegisterOptions{Name: "renji.agent.archive.v1"})
	env.ExecuteWorkflow(harness.ArchiveWorkflowName, harness.ArchiveInput{RunID: f.run.Context.RunID})
	require.NoError(t, env.GetWorkflowError())
	var out harness.ArchiveOutcome
	require.NoError(t, env.GetWorkflowResult(&out))
	require.Equal(t, "verified", out.Status)
	require.Equal(t, 2, out.Attempts)
	posts, gets := d.counts()
	require.Equal(t, 1, posts)
	require.Equal(t, 2, gets)
	q, e := env.QueryWorkflow(harness.ArchiveQueryName)
	require.NoError(t, e)
	var queried harness.ArchiveOutcome
	require.NoError(t, q.Get(&queried))
	require.Equal(t, out, queried)
	var status string
	require.NoError(t, f.s.Pool.QueryRow(context.Background(), "SELECT status FROM execution_runs WHERE id=$1", f.run.Context.RunID).Scan(&status))
	require.Equal(t, "failed", status)
}
func TestTerminalArchivePluginUnknownWithoutIDIsAttentionNotRetryable(t *testing.T) {
	d, s := newDocFree(t)
	d.mode = "lost-response"
	f := newFixture(t, s.URL)
	p := &TerminalPlugin{runner: f.runner(t)}
	for i := 0; i < 2; i++ {
		out, e := p.ArchiveRun(context.Background(), f.run.Context.RunID)
		require.NoError(t, e)
		require.Equal(t, "attention", out.Status)
		require.False(t, out.Retryable)
		require.Len(t, out.Parts, 1)
		require.Equal(t, "unknown", out.Parts[0].State)
		require.Empty(t, out.Parts[0].ExternalID)
	}
	posts, _ := d.counts()
	require.Equal(t, 1, posts)
}
func TestArchiveDeploymentNoConfigurationAndDisabledNeedNoCredentials(t *testing.T) {
	ctx := context.Background()
	noenv := func(string) string { t.Fatal("disabled deployment read environment"); return "" }
	p, close, mode, e := OpenDeployment(ctx, "", noenv)
	require.NoError(t, e)
	require.Nil(t, p)
	require.Equal(t, "disabled_no_config", mode)
	close()
	c := testConfig()
	c.Enabled = false
	raw, e := json.Marshal(c)
	require.NoError(t, e)
	path := filepath.Join(t.TempDir(), "archive.json")
	require.NoError(t, os.WriteFile(path, raw, 0600))
	p, close, mode, e = OpenDeployment(ctx, path, noenv)
	require.NoError(t, e)
	require.Equal(t, "disabled_by_config", mode)
	close()
	out, e := p.ArchiveRun(ctx, "run-a")
	require.NoError(t, e)
	require.Equal(t, "disabled", out.Status)
	_, _, _, e = OpenDeployment(ctx, filepath.Join(t.TempDir(), "missing.json"), noenv)
	require.Error(t, e)
}

func TestTerminalArchiveStopBeforeTerminalUsesCanonicalServerTransition(t *testing.T) {
	for _, reported := range []string{"failed", "completed"} {
		t.Run(reported, func(t *testing.T) {
			d, server := newDocFree(t)
			f := newFixture(t, server.URL)
			ctx := context.Background()
			run, err := f.s.CreateExecutionRun(ctx, f.agent, store.CreateExecutionRunCommand{ActionID: "stop-before-terminal-run", ExecutorID: f.run.Context.ExecutorID, RoomID: f.room.ID, ScopeEpoch: f.room.ScopeEpoch, Goal: "停止与终态竞态，保留原始报告"})
			require.NoError(t, err)
			_, err = f.s.SetStopped(ctx, f.owner, f.room.ID, "stop-before-terminal-room", f.room.Version, true)
			require.NoError(t, err)
			event := harness.Event{ID: harness.StableID(run.Context.RunID, "workflow-terminal-v1"), Type: "run." + reported, Data: json.RawMessage(`{"status":"` + reported + `"}`)}
			require.NoError(t, f.s.AppendExecutionEvent(ctx, testIssuer, testSubject, run.Context, event))
			reader := store.EvidenceReader{MachineIssuer: testIssuer, MachineSubject: testSubject}
			page, err := f.s.ReadExecutionEvidence(ctx, reader, run.Context.RunID, store.EvidenceQuery{})
			require.NoError(t, err)
			require.Equal(t, "stopped", page.Run.Status)
			var events, stopFacts int
			for _, entry := range page.Entries {
				if entry.Kind == "event" {
					events++
					var row struct {
						Event harness.Event `json:"event"`
					}
					require.NoError(t, json.Unmarshal(entry.Data, &row))
					require.Equal(t, event.Type, row.Event.Type)
				}
				if entry.Kind == "run.status" {
					var row struct {
						Status string `json:"status"`
					}
					require.NoError(t, json.Unmarshal(entry.Data, &row))
					require.Equal(t, run.Context.RunID, entry.ObjectID)
					require.Equal(t, "stopped", row.Status)
					stopFacts++
				}
			}
			require.Equal(t, 1, events)
			require.Equal(t, 1, stopFacts)
			plugin := &TerminalPlugin{runner: f.runner(t)}
			out, err := plugin.ArchiveRun(ctx, run.Context.RunID)
			require.NoError(t, err)
			require.Equal(t, "verified", out.Status)
			posts, _ := d.counts()
			require.Equal(t, 1, posts)
			// Neither the reader nor the plugin writes a replacement executor event.
			var count int
			require.NoError(t, f.s.Pool.QueryRow(ctx, "SELECT count(*) FROM execution_events WHERE run_id=$1", run.Context.RunID).Scan(&count))
			require.Equal(t, 1, count)
		})
	}
}

func TestTerminalArchiveModelCannotSupplyCanonicalStopFact(t *testing.T) {
	d, server := newDocFree(t)
	f := newFixture(t, server.URL)
	ctx := context.Background()
	run, err := f.s.CreateExecutionRun(ctx, f.agent, store.CreateExecutionRunCommand{ActionID: "fake-server-stop-run", ExecutorID: f.run.Context.ExecutorID, RoomID: f.room.ID, ScopeEpoch: f.room.ScopeEpoch, Goal: "模型不能生成数据库停止事实"})
	require.NoError(t, err)
	data, _ := json.Marshal(map[string]any{"kind": "run.status", "object_id": run.Context.RunID, "status": "stopped", "event": map[string]string{"type": "run.stopped"}})
	require.NoError(t, f.s.AppendExecutionEvent(ctx, testIssuer, testSubject, run.Context, harness.Event{ID: harness.StableID(run.Context.RunID, "model-stop-claim"), Type: "model.output", Data: data}))
	p := &TerminalPlugin{runner: f.runner(t)}
	out, err := p.ArchiveRun(ctx, run.Context.RunID)
	require.NoError(t, err)
	require.Equal(t, "attention", out.Status)
	require.Equal(t, "archive_run_not_terminal", out.Code)
	posts, _ := d.counts()
	require.Zero(t, posts)
}
