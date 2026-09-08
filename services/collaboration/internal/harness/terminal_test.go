package harness

import (
	"encoding/json"
	"testing"

	"github.com/cloudwego/eino/schema"
	"github.com/stretchr/testify/require"
)

func TestTemporalPersistsTerminalAfterCommittedActions(t *testing.T) {
	g := &fakeGateway{}
	p, err := NewEinoPlanner(PlannerConfig{Model: &fakeModel{messages: []*schema.Message{finalPlan("final", true)}}, Gateway: g, AllowedActionTypes: []string{"message.send"}})
	require.NoError(t, err)
	env := workflowEnvironment(g, p)
	env.ExecuteWorkflow(WorkflowName, RunInput{Context: runContext(), Goal: "finish", MaxStages: 2})
	require.NoError(t, env.GetWorkflowError())
	last := g.events[len(g.events)-1]
	require.Equal(t, "run.completed", last.Type)
	require.Equal(t, StableID("run-a", "workflow-terminal-v1"), last.ID)
	var result RunResult
	require.NoError(t, json.Unmarshal(last.Data, &result))
	require.Equal(t, "completed", result.Status)
	require.Len(t, result.Receipts, 1)
	require.Equal(t, 1, g.effects)
}

func TestTemporalFailureStillPersistsAuditWithoutReexecutingActions(t *testing.T) {
	g := &fakeGateway{stopped: true}
	m := &fakeModel{}
	p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
	require.NoError(t, err)
	env := workflowEnvironment(g, p)
	env.ExecuteWorkflow(WorkflowName, RunInput{Context: runContext(), Goal: "blocked", MaxStages: 2})
	require.Error(t, env.GetWorkflowError())
	require.Zero(t, m.calls)
	require.Zero(t, g.effects)
	require.Len(t, g.events, 1)
	require.Equal(t, "run.failed", g.events[0].Type)
}
