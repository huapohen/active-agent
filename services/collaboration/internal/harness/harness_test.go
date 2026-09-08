package harness

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cloudwego/eino/components/model"
	"github.com/cloudwego/eino/schema"
	"github.com/stretchr/testify/require"
	"go.temporal.io/sdk/activity"
	"go.temporal.io/sdk/testsuite"
	"go.temporal.io/sdk/workflow"
)

func runContext() RunContext {
	return RunContext{PrincipalID: "agent-a", ExecutorID: "worker-a", RunID: "run-a", RoomID: "room-a", ScopeEpoch: 3, OriginScopes: []Scope{{"source-room", 2}}, RuntimeVersion: RuntimeVersion, WorkflowVersion: WorkflowVersion}
}

type fakeGateway struct {
	mu        sync.Mutex
	stopped   bool
	effects   int
	attempts  int
	loseFirst bool
	status    string
	actions   map[string]Action
	receipts  map[string]Receipt
	events    []Event
}

func (g *fakeGateway) Check(_ context.Context, r RunContext) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.stopped {
		return ErrStopped
	}
	return r.Validate()
}
func (g *fakeGateway) Execute(_ context.Context, r RunContext, a Action) (Receipt, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.attempts++
	if g.stopped {
		return Receipt{}, ErrStopped
	}
	if g.actions == nil {
		g.actions = map[string]Action{}
		g.receipts = map[string]Receipt{}
	}
	if prior, ok := g.actions[a.ID]; ok {
		if prior.Type != a.Type || string(prior.Payload) != string(a.Payload) {
			return Receipt{}, ErrInvalid
		}
		return g.receipts[a.ID], nil
	}
	g.effects++
	g.actions[a.ID] = a
	status := g.status
	if status == "" {
		status = "succeeded"
	}
	receipt := Receipt{ActionID: a.ID, Status: status, Result: json.RawMessage(`{"message_id":"m1"}`)}
	g.receipts[a.ID] = receipt
	if g.loseFirst {
		g.loseFirst = false
		return Receipt{}, errors.New("simulated response lost after commit")
	}
	return receipt, nil
}
func (g *fakeGateway) AppendEvent(_ context.Context, _ RunContext, e Event) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.events = append(g.events, e)
	return nil
}

type fakeModel struct {
	mu        sync.Mutex
	messages  []*schema.Message
	calls     int
	hook      func()
	toolsSeen bool
}

func (m *fakeModel) Generate(_ context.Context, _ []*schema.Message, opts ...model.Option) (*schema.Message, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.calls++
	if len(model.GetCommonOptions(nil, opts...).Tools) > 0 {
		m.toolsSeen = true
	}
	if m.hook != nil {
		m.hook()
	}
	if len(m.messages) == 0 {
		return nil, fmt.Errorf("fake model exhausted")
	}
	out := m.messages[0]
	m.messages = m.messages[1:]
	return out, nil
}
func (m *fakeModel) Stream(ctx context.Context, input []*schema.Message, opts ...model.Option) (*schema.StreamReader[*schema.Message], error) {
	msg, err := m.Generate(ctx, input, opts...)
	if err != nil {
		return nil, err
	}
	return schema.StreamReaderFromArray([]*schema.Message{msg}), nil
}
func finalPlan(key string, done bool) *schema.Message {
	return &schema.Message{Role: schema.Assistant, Content: fmt.Sprintf(`{"summary":"Prepare a native reply","done":%t,"actions":[{"key":%q,"type":"message.send","payload":{"content":"hello"}}]}`, done, key)}
}

func TestEinoDeepAgentConstructsAndUsesExplicitSkill(t *testing.T) {
	g := &fakeGateway{}
	m := &fakeModel{messages: []*schema.Message{
		{Role: schema.Assistant, ToolCalls: []schema.ToolCall{{ID: "skill-1", Type: "function", Function: schema.FunctionCall{Name: "skill", Arguments: `{"skill":"native-collaboration"}`}}}},
		finalPlan("send-reply", true),
	}}
	p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
	require.NoError(t, err)
	result, err := p.Plan(context.Background(), StageInput{Context: runContext(), Goal: "Reply hello to my room", Attempt: 1})
	require.NoError(t, err)
	require.True(t, result.Done)
	require.Len(t, result.Actions, 1)
	require.Equal(t, StableID("run-a", "send-reply"), result.Actions[0].ID)
	require.True(t, m.toolsSeen)
	require.Equal(t, 2, m.calls)
	require.Zero(t, g.effects)
	var toolRecorded bool
	for _, event := range g.events {
		if event.Type == "tool.result" {
			toolRecorded = true
		}
	}
	require.True(t, toolRecorded, "tool intermediate output must enter the archive")
}

func TestEinoDiscardsModelOutputAfterScopeStop(t *testing.T) {
	g := &fakeGateway{}
	m := &fakeModel{messages: []*schema.Message{finalPlan("reply", true)}, hook: func() { g.mu.Lock(); g.stopped = true; g.mu.Unlock() }}
	p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
	require.NoError(t, err)
	_, err = p.Plan(context.Background(), StageInput{Context: runContext(), Goal: "Reply"})
	require.Error(t, err)
	require.Zero(t, g.effects)
}

func TestEinoTemporarySubagentProducesSeparateTrace(t *testing.T) {
	g := &fakeGateway{}
	m := &fakeModel{messages: []*schema.Message{
		{Role: schema.Assistant, ToolCalls: []schema.ToolCall{{ID: "research-1", Type: "function", Function: schema.FunctionCall{Name: "task", Arguments: `{"subagent_type":"general-purpose","description":"Review the proposed collaboration response without executing it."}`}}}},
		{Role: schema.Assistant, Content: `{"summary":"Read-only review complete","done":true,"actions":[]}`},
		finalPlan("send-reply", true),
	}}
	p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
	require.NoError(t, err)
	_, err = p.Plan(context.Background(), StageInput{Context: runContext(), Goal: "Review and reply", Attempt: 1})
	require.NoError(t, err)
	var childTraced bool
	for _, event := range g.events {
		if event.Type == "agent.output" && strings.Contains(string(event.Data), "general-purpose") {
			childTraced = true
		}
	}
	require.True(t, childTraced)
	require.Equal(t, 3, m.calls)
	require.Zero(t, g.effects)
}

func TestEinoReductionOffloadsAndReadsPrivateEvidence(t *testing.T) {
	g := &fakeGateway{}
	large := strings.Repeat("verified evidence line\n", 900)
	m := &fakeModel{messages: []*schema.Message{
		{Role: schema.Assistant, ToolCalls: []schema.ToolCall{{ID: "research-large", Type: "function", Function: schema.FunctionCall{Name: "task", Arguments: `{"subagent_type":"general-purpose","description":"Return the long evidence report without taking business actions."}`}}}},
		{Role: schema.Assistant, Content: large},
		{Role: schema.Assistant, ToolCalls: []schema.ToolCall{{ID: "read-evidence", Type: "function", Function: schema.FunctionCall{Name: "read_file", Arguments: `{"path":"/stage/trunc/research-large","offset":1,"limit":2}`}}}},
		finalPlan("send-reply", true),
	}}
	p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
	require.NoError(t, err)
	_, err = p.Plan(context.Background(), StageInput{Context: runContext(), Goal: "Read and cite the evidence", Attempt: 1})
	require.NoError(t, err)
	var reRead bool
	for _, event := range g.events {
		if event.Type == "tool.result" && strings.Contains(string(event.Data), `"tool":"read_file"`) && strings.Contains(string(event.Data), "verified evidence line") {
			reRead = true
		}
	}
	require.True(t, reRead)
	require.Zero(t, g.effects)
}

func TestEinoSummaryMiddlewareRunsAtConfiguredThreshold(t *testing.T) {
	g := &fakeGateway{}
	m := &fakeModel{messages: []*schema.Message{{Role: schema.Assistant, Content: "Preserved goal and original room scope; no official action has been committed."}, finalPlan("send-reply", true)}}
	p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
	require.NoError(t, err)
	input := StageInput{Context: runContext(), Goal: strings.Repeat("goal ", 11000), PreviousSummary: strings.Repeat("summary ", 1000), Attempt: 1}
	for i := 0; i < 8; i++ {
		input.Receipts = append(input.Receipts, Receipt{ActionID: StableID("run-a", fmt.Sprint(i)), Status: "succeeded", Result: eventData(map[string]string{"evidence": strings.Repeat("x", 7900)})})
	}
	_, err = p.Plan(context.Background(), input)
	require.NoError(t, err)
	require.Equal(t, 2, m.calls)
	require.True(t, m.toolsSeen)
}

func workflowEnvironment(g *fakeGateway, p Planner) *testsuite.TestWorkflowEnvironment {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	a := &Activities{Gateway: g, Planner: p}
	env.RegisterWorkflowWithOptions(RunWorkflow, workflow.RegisterOptions{Name: WorkflowName})
	env.RegisterActivityWithOptions(a.Plan, activity.RegisterOptions{Name: planActivityName})
	env.RegisterActivityWithOptions(a.Execute, activity.RegisterOptions{Name: actionActivityName})
	return env
}

func TestTemporalEinoLostActionReplyDoesNotDuplicateEffect(t *testing.T) {
	g := &fakeGateway{loseFirst: true}
	m := &fakeModel{messages: []*schema.Message{finalPlan("send-reply", true)}}
	p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
	require.NoError(t, err)
	env := workflowEnvironment(g, p)
	env.ExecuteWorkflow(WorkflowName, RunInput{Context: runContext(), Goal: "Reply hello", MaxStages: 3})
	require.NoError(t, env.GetWorkflowError())
	var result RunResult
	require.NoError(t, env.GetWorkflowResult(&result))
	require.Equal(t, "completed", result.Status)
	require.Equal(t, 1, g.effects)
	require.Equal(t, 2, g.attempts)
	require.Equal(t, 1, m.calls)
}

func TestTemporalReplanPreservesLogicalActionID(t *testing.T) {
	g := &fakeGateway{}
	m := &fakeModel{messages: []*schema.Message{finalPlan("send-reply", false), finalPlan("send-reply", true)}}
	p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
	require.NoError(t, err)
	env := workflowEnvironment(g, p)
	env.ExecuteWorkflow(WorkflowName, RunInput{Context: runContext(), Goal: "Reply hello", MaxStages: 3})
	require.NoError(t, env.GetWorkflowError())
	var result RunResult
	require.NoError(t, env.GetWorkflowResult(&result))
	require.Equal(t, "completed", result.Status)
	require.Equal(t, 2, result.Stages)
	require.Equal(t, 1, g.effects)
	require.Len(t, result.Receipts, 1)
}

func TestTemporalUnknownReceiptStopsWithoutNextAction(t *testing.T) {
	g := &fakeGateway{status: "unknown"}
	m := &fakeModel{messages: []*schema.Message{finalPlan("send-reply", false)}}
	p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
	require.NoError(t, err)
	env := workflowEnvironment(g, p)
	env.ExecuteWorkflow(WorkflowName, RunInput{Context: runContext(), Goal: "Reply hello", MaxStages: 3})
	require.NoError(t, env.GetWorkflowError())
	var result RunResult
	require.NoError(t, env.GetWorkflowResult(&result))
	require.Equal(t, "reconciliation_required", result.Status)
	require.Equal(t, 1, g.attempts)
	require.Equal(t, 1, m.calls)
}

func TestTemporalStoppedOriginRejectsBeforeModel(t *testing.T) {
	g := &fakeGateway{stopped: true}
	m := &fakeModel{}
	p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
	require.NoError(t, err)
	env := workflowEnvironment(g, p)
	env.ExecuteWorkflow(WorkflowName, RunInput{Context: runContext(), Goal: "Reply hello", MaxStages: 3})
	require.Error(t, env.GetWorkflowError())
	require.Zero(t, g.effects)
	require.Zero(t, m.calls)
}

func TestTemporalDurableWaitRechecksStoppedOrigin(t *testing.T) {
	g := &fakeGateway{}
	m := &fakeModel{messages: []*schema.Message{{Role: schema.Assistant, Content: `{"summary":"Wait for the scheduled continuation","done":false,"wait_seconds":60,"actions":[]}`}}}
	p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
	require.NoError(t, err)
	env := workflowEnvironment(g, p)
	env.RegisterDelayedCallback(func() { g.mu.Lock(); g.stopped = true; g.mu.Unlock() }, 5*time.Second)
	env.ExecuteWorkflow(WorkflowName, RunInput{Context: runContext(), Goal: "Wait then act", MaxStages: 3})
	require.Error(t, env.GetWorkflowError())
	require.Equal(t, 1, m.calls)
	require.Zero(t, g.effects)
}

func TestTemporalCancellationEndsDurableWait(t *testing.T) {
	g := &fakeGateway{}
	m := &fakeModel{messages: []*schema.Message{{Role: schema.Assistant, Content: `{"summary":"Wait for the scheduled continuation","done":false,"wait_seconds":60,"actions":[]}`}}}
	p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
	require.NoError(t, err)
	env := workflowEnvironment(g, p)
	env.RegisterDelayedCallback(env.CancelWorkflow, 5*time.Second)
	env.ExecuteWorkflow(WorkflowName, RunInput{Context: runContext(), Goal: "Wait then act", MaxStages: 3})
	require.Error(t, env.GetWorkflowError())
	require.Equal(t, 1, m.calls)
	require.Zero(t, g.effects)
}

func TestTemporalActionKeyCannotChangePayload(t *testing.T) {
	g := &fakeGateway{}
	second := finalPlan("send-reply", true)
	second.Content = strings.ReplaceAll(second.Content, "hello", "different")
	m := &fakeModel{messages: []*schema.Message{finalPlan("send-reply", false), second}}
	p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
	require.NoError(t, err)
	env := workflowEnvironment(g, p)
	env.ExecuteWorkflow(WorkflowName, RunInput{Context: runContext(), Goal: "Reply hello", MaxStages: 3})
	require.Error(t, env.GetWorkflowError())
	require.Equal(t, 1, g.effects)
	require.Equal(t, 1, g.attempts)
}

func TestDecodeRejectsChangedScopeOrUnsupportedActionFields(t *testing.T) {
	p, _ := NewEinoPlanner(PlannerConfig{Model: &fakeModel{}, Gateway: &fakeGateway{}, AllowedActionTypes: []string{"message.send"}})
	for _, body := range []string{
		`{"summary":"x","done":true,"principal_id":"another-agent","actions":[]}`,
		`{"summary":"x","done":true,"actions":[{"key":"x","type":"shell.execute","payload":{}}]}`,
		`{"summary":"x","done":false,"actions":[]}`,
		`{"summary":"x","done":true,"wait_seconds":5,"actions":[]}`,
	} {
		_, err := p.decode("run", body)
		require.Error(t, err)
	}
}

func TestHTTPGatewayBindsMachineAndRejectsRedirect(t *testing.T) {
	var received int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		received++
		require.Equal(t, "Bearer test-machine", r.Header.Get("Authorization"))
		http.Redirect(w, r, "https://example.invalid/", http.StatusTemporaryRedirect)
	}))
	defer server.Close()
	g, err := NewHTTPGateway(server.URL, "test-machine", "agent-a", "worker-a")
	require.NoError(t, err)
	require.Error(t, g.VerifyBinding(context.Background()))
	require.Equal(t, 1, received)
	wrong := runContext()
	wrong.PrincipalID = "other-agent"
	require.ErrorIs(t, g.Check(context.Background(), wrong), ErrDenied)
	require.Equal(t, 1, received)
}

func TestHTTPGatewayRequiresAllServerReadinessAcknowledgements(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"protocol":"renji-harness-v1","principal_id":"agent-a","executor_id":"worker-a","server_bound":true,"actions_idempotent":true}`)
	}))
	defer server.Close()
	g, err := NewHTTPGateway(server.URL, "test-machine", "agent-a", "worker-a")
	require.NoError(t, err)
	require.ErrorIs(t, g.VerifyBinding(context.Background()), ErrDenied)
}

func TestHTTPModelTransportsEinoToolSchemaAndNoSecretErrors(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, "/v1/chat/completions", r.URL.Path)
		var payload map[string]any
		require.NoError(t, json.NewDecoder(r.Body).Decode(&payload))
		require.NotEmpty(t, payload["tools"])
		fmt.Fprint(w, `{"choices":[{"message":{"role":"assistant","content":"{}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":3,"total_tokens":13}}`)
	}))
	defer server.Close()
	m, err := NewHTTPModel(server.URL+"/v1", "test-model", "fake-test-model", "medium")
	require.NoError(t, err)
	msg, err := m.Generate(context.Background(), []*schema.Message{schema.UserMessage("test")}, model.WithTools([]*schema.ToolInfo{{Name: "read", Desc: "read data", ParamsOneOf: schema.NewParamsOneOfByParams(map[string]*schema.ParameterInfo{"path": {Type: schema.String, Required: true}})}}))
	require.NoError(t, err)
	require.Equal(t, 13, msg.ResponseMeta.Usage.TotalTokens)
	_, err = NewHTTPModel("http://external.invalid/v1", "secret", "test", "")
	require.Error(t, err)
	require.False(t, strings.Contains(err.Error(), "secret"))
}
