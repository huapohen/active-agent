package harness

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/require"
	historypb "go.temporal.io/api/history/v1"
	"go.temporal.io/sdk/converter"
	"go.temporal.io/sdk/worker"
	"go.temporal.io/sdk/workflow"
	"google.golang.org/protobuf/encoding/protojson"
)

type discardReplayLog struct{}

func (discardReplayLog) Debug(string, ...interface{}) {}
func (discardReplayLog) Info(string, ...interface{})  {}
func (discardReplayLog) Warn(string, ...interface{})  {}
func (discardReplayLog) Error(string, ...interface{}) {}

// This builds real Temporal protobuf history, not a mock Plan invocation. The
// replayer registers no activities or plugins, so it cannot call a model, gateway
// or document server while consuming their completed results from history.
func replayOneActivityHistory(t *testing.T, workflowName, activityName string, input, activityResult, workflowResult any) {
	t.Helper()
	payload := func(v any) map[string]any {
		p, e := converter.GetDefaultDataConverter().ToPayloads(v)
		require.NoError(t, e)
		raw, e := protojson.Marshal(p)
		require.NoError(t, e)
		var out map[string]any
		require.NoError(t, json.Unmarshal(raw, &out))
		return out
	}
	event := func(id int, kind, attr string, body map[string]any) map[string]any {
		return map[string]any{"eventId": id, "eventTime": "2026-09-09T00:00:00Z", "eventType": kind, attr: body}
	}
	events := []map[string]any{
		event(1, "EVENT_TYPE_WORKFLOW_EXECUTION_STARTED", "workflowExecutionStartedEventAttributes", map[string]any{"workflowType": map[string]any{"name": workflowName}, "taskQueue": map[string]any{"name": "archive-replay"}, "input": payload(input)}),
		event(2, "EVENT_TYPE_WORKFLOW_TASK_SCHEDULED", "workflowTaskScheduledEventAttributes", map[string]any{}),
		event(3, "EVENT_TYPE_WORKFLOW_TASK_STARTED", "workflowTaskStartedEventAttributes", map[string]any{"scheduledEventId": 2}),
		event(4, "EVENT_TYPE_WORKFLOW_TASK_COMPLETED", "workflowTaskCompletedEventAttributes", map[string]any{"scheduledEventId": 2, "startedEventId": 3}),
		event(5, "EVENT_TYPE_ACTIVITY_TASK_SCHEDULED", "activityTaskScheduledEventAttributes", map[string]any{"activityId": "5", "activityType": map[string]any{"name": activityName}, "taskQueue": map[string]any{"name": "archive-replay"}, "workflowTaskCompletedEventId": 4}),
		event(6, "EVENT_TYPE_ACTIVITY_TASK_STARTED", "activityTaskStartedEventAttributes", map[string]any{"scheduledEventId": 5}),
		event(7, "EVENT_TYPE_ACTIVITY_TASK_COMPLETED", "activityTaskCompletedEventAttributes", map[string]any{"scheduledEventId": 5, "startedEventId": 6, "result": payload(activityResult)}),
		event(8, "EVENT_TYPE_WORKFLOW_TASK_SCHEDULED", "workflowTaskScheduledEventAttributes", map[string]any{}),
		event(9, "EVENT_TYPE_WORKFLOW_TASK_STARTED", "workflowTaskStartedEventAttributes", map[string]any{"scheduledEventId": 8}),
		event(10, "EVENT_TYPE_WORKFLOW_TASK_COMPLETED", "workflowTaskCompletedEventAttributes", map[string]any{"scheduledEventId": 8, "startedEventId": 9}),
		event(11, "EVENT_TYPE_WORKFLOW_EXECUTION_COMPLETED", "workflowExecutionCompletedEventAttributes", map[string]any{"workflowTaskCompletedEventId": 10, "result": payload(workflowResult)}),
	}
	raw, e := json.Marshal(map[string]any{"events": events})
	require.NoError(t, e)
	var history historypb.History
	require.NoError(t, protojson.Unmarshal(raw, &history))
	r := worker.NewWorkflowReplayer()
	r.RegisterWorkflowWithOptions(RunWorkflow, workflow.RegisterOptions{Name: WorkflowName})
	r.RegisterWorkflowWithOptions(ArchiveWorkflow, workflow.RegisterOptions{Name: ArchiveWorkflowName})
	require.NoError(t, r.ReplayWorkflowHistory(discardReplayLog{}, &history))
}
func TestReplayLegacyBusinessHistoryDoesNotAddTerminalOrArchiveActivity(t *testing.T) {
	replayOneActivityHistory(t, WorkflowName, planActivityName, RunInput{Context: runContext(), Goal: "legacy", MaxStages: 1}, StageResult{Summary: "old result", Done: true}, RunResult{Status: "completed", Summary: "old result", Stages: 1, Receipts: []Receipt{}})
}
func TestReplayCompletedArchiveConsumesHistoryWithoutCallingPlugin(t *testing.T) {
	out := archiveVerified()
	out.Attempts = 1
	replayOneActivityHistory(t, ArchiveWorkflowName, archiveActivityName, ArchiveInput{RunID: "run-a"}, out, out)
}
