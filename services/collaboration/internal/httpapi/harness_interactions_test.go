package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"testing"

	"github.com/cloudwego/eino/components/model"
	"github.com/cloudwego/eino/schema"
	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/emoji"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
	"github.com/stretchr/testify/require"
	"go.temporal.io/sdk/activity"
	"go.temporal.io/sdk/testsuite"
	"go.temporal.io/sdk/workflow"
)

type harnessInteractionFixture struct {
	s                       *store.Store
	owner, agent, workspace string
	source, target          domain.Room
	binding                 store.ExecutorBinding
	run                     store.ExecutionRun
	message                 domain.Message
	gateway                 *harness.HTTPGateway
}

func newHarnessInteractionFixture(t *testing.T, catalog bool) harnessInteractionFixture {
	t.Helper()
	ctx := context.Background()
	s := httpStore(t)
	f := harnessInteractionFixture{s: s}
	owner, err := s.ResolveIdentity(ctx, "test-only-issuer", "human-test")
	require.NoError(t, err)
	f.owner = owner.ID
	f.agent = uuid.NewString()
	_, err = s.Pool.Exec(ctx, "INSERT INTO principals(id,kind,display_name) VALUES($1,'agent','原生反应同事')", f.agent)
	require.NoError(t, err)
	f.workspace, err = s.CreateWorkspace(ctx, f.owner, "interaction-workspace", "合成原生交互")
	require.NoError(t, err)
	_, err = s.Pool.Exec(ctx, "INSERT INTO workspace_members VALUES($1,$2,'member')", f.workspace, f.agent)
	require.NoError(t, err)
	f.source, err = s.CreateRoom(ctx, f.owner, "interaction-source-room", f.workspace, "来源", []string{f.agent})
	require.NoError(t, err)
	f.target, err = s.CreateRoom(ctx, f.owner, "interaction-target-room", f.workspace, "目标", []string{f.agent})
	require.NoError(t, err)
	f.binding, err = s.RegisterExecutor(ctx, f.owner, store.RegisterExecutorCommand{ActionID: "interaction-executor", WorkspaceID: f.workspace, AgentPrincipalID: f.agent, Issuer: "https://fixture.clerk.accounts.dev", MachineSubject: "mch_fixture", Enabled: true})
	require.NoError(t, err)
	_, err = s.SetAgentExecutionPolicy(ctx, f.owner, store.AgentExecutionPolicyCommand{ActionID: "interaction-proactive", WorkspaceID: f.workspace, AgentPrincipalID: f.agent, ExpectedVersion: 1, ProactiveEnabled: true})
	require.NoError(t, err)
	parent, err := s.CreateExecutionRun(ctx, f.agent, store.CreateExecutionRunCommand{ActionID: "interaction-parent-run", ExecutorID: f.binding.ExecutorID, RoomID: f.source.ID, ScopeEpoch: f.source.ScopeEpoch, Goal: "合成来源"})
	require.NoError(t, err)
	f.run, err = s.CreateExecutionRun(ctx, f.agent, store.CreateExecutionRunCommand{ActionID: "interaction-child-run", ExecutorID: f.binding.ExecutorID, RoomID: f.target.ID, ScopeEpoch: f.target.ScopeEpoch, ParentRunID: parent.Context.RunID, Goal: "查看真实表情目录，撤销自己的OK并回复"})
	require.NoError(t, err)
	sent, err := s.Send(ctx, f.owner, f.target.ID, domain.SendMessage{ActionID: "interaction-seed-message", Content: "服务端可读原始消息"})
	require.NoError(t, err)
	f.message = sent.Message
	options := []Option{WithMachineVerifier(fixtureMachineVerifier{})}
	if catalog {
		dir, e := filepath.Abs("../../../../apps/office/assets/emoji")
		require.NoError(t, e)
		p, e := emoji.NewLocal(dir)
		require.NoError(t, e)
		options = append(options, WithEmojiProvider(p))
	}
	server := httptest.NewServer(New(s, fixtureVerifier{}, nil, nil, options...))
	t.Cleanup(server.Close)
	f.gateway, err = harness.NewHTTPGateway(server.URL, "mt_fixture", f.agent, f.binding.ExecutorID)
	require.NoError(t, err)
	require.NoError(t, f.gateway.VerifyBinding(ctx))
	return f
}

type harnessInteractionModel struct {
	mu        sync.Mutex
	calls     int
	messages  []*schema.Message
	seenTools map[string]bool
	inputs    []string
}

func (m *harnessInteractionModel) Generate(_ context.Context, in []*schema.Message, opts ...model.Option) (*schema.Message, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.calls++
	if m.seenTools == nil {
		m.seenTools = map[string]bool{}
	}
	for _, tool := range model.GetCommonOptions(nil, opts...).Tools {
		m.seenTools[tool.Name] = true
	}
	for _, msg := range in {
		if msg.Role == schema.Tool {
			m.inputs = append(m.inputs, msg.Content)
		}
	}
	if len(m.messages) == 0 {
		return nil, fmt.Errorf("synthetic model exhausted")
	}
	out := m.messages[0]
	m.messages = m.messages[1:]
	return out, nil
}
func (m *harnessInteractionModel) Stream(ctx context.Context, in []*schema.Message, opts ...model.Option) (*schema.StreamReader[*schema.Message], error) {
	out, err := m.Generate(ctx, in, opts...)
	if err != nil {
		return nil, err
	}
	return schema.StreamReaderFromArray([]*schema.Message{out}), nil
}
func harnessInteractionTool(name, args string) *schema.Message {
	return &schema.Message{Role: schema.Assistant, ToolCalls: []schema.ToolCall{{ID: "fixture-" + name, Type: "function", Function: schema.FunctionCall{Name: name, Arguments: args}}}}
}

// PostgreSQL and the actual Gin/HTTPGateway/Eino/Temporal activity chain are
// real here; only the chat model and Temporal scheduler are deterministic test
// doubles. No Temporal service, model endpoint or provider dispatch is started.
func TestHarnessInteractionsEinoHTTPAndPostgresCommitReplyAndReaction(t *testing.T) {
	f := newHarnessInteractionFixture(t, true)
	ctx := context.Background()
	require.Contains(t, f.gateway.AllowedActionTypes(), "reaction.set")
	_, err := f.s.SetReaction(ctx, f.agent, f.target.ID, f.message.ID, domain.SetReaction{ActionID: "interaction-seed-agent-reaction", Emoji: "feishu:OK", Active: true, ScopeEpoch: &f.target.ScopeEpoch})
	require.NoError(t, err)
	_, err = f.s.SetReaction(ctx, f.owner, f.target.ID, f.message.ID, domain.SetReaction{ActionID: "interaction-seed-owner-reaction", Emoji: "feishu:OK", Active: true})
	require.NoError(t, err)
	m := &harnessInteractionModel{messages: []*schema.Message{
		harnessInteractionTool("im_emoji_list", `{"q":"feishu:OK","limit":10}`),
		harnessInteractionTool("im_message_get", fmt.Sprintf(`{"room_id":%q,"message_id":%q}`, f.target.ID, f.message.ID)),
		harnessInteractionTool("im_reaction_list", fmt.Sprintf(`{"room_id":%q,"message_id":%q,"expected_version":2}`, f.target.ID, f.message.ID)),
		{Role: schema.Assistant, Content: fmt.Sprintf(`{"summary":"Use canonical selected state and observed emoji ID","done":true,"actions":[{"key":"remove-own-ok","type":"reaction.set","payload":{"message_id":%q,"emoji":"feishu:OK","active":false}},{"key":"reply-original","type":"message.send","payload":{"content":"合成回复","reply_to":%q}}]}`, f.message.ID, f.message.ID)},
	}}
	planner, err := harness.NewEinoPlanner(harness.PlannerConfig{Model: m, Gateway: f.gateway, AllowedActionTypes: f.gateway.AllowedActionTypes()})
	require.NoError(t, err)
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	activities := &harness.Activities{Gateway: f.gateway, Planner: planner}
	env.RegisterWorkflowWithOptions(harness.RunWorkflow, workflow.RegisterOptions{Name: harness.WorkflowName})
	env.RegisterActivityWithOptions(activities.Plan, activity.RegisterOptions{Name: "renji.agent.plan.v1"})
	env.RegisterActivityWithOptions(activities.Execute, activity.RegisterOptions{Name: "renji.agent.action.v1"})
	env.RegisterActivityWithOptions(activities.Terminal, activity.RegisterOptions{Name: "renji.agent.terminal.v1"})
	env.RegisterActivityWithOptions(activities.Archive, activity.RegisterOptions{Name: "renji.agent.archive.v1"})
	// Match the exported archive implementation's stable activity name.
	env.ExecuteWorkflow(harness.WorkflowName, harness.RunInput{Context: f.run.Context, Goal: f.run.Goal, MaxStages: 1})
	require.NoError(t, env.GetWorkflowError())
	var result harness.RunResult
	require.NoError(t, env.GetWorkflowResult(&result))
	require.Equal(t, "completed", result.Status)
	require.Len(t, result.Receipts, 2)
	require.Equal(t, 4, m.calls)
	for _, name := range []string{"im_emoji_list", "im_message_get", "im_reaction_list"} {
		require.True(t, m.seenTools[name])
	}
	raw, _ := json.Marshal(m.inputs)
	require.Contains(t, string(raw), "feishu:OK")
	require.Contains(t, string(raw), "服务端可读原始消息")
	messages, err := f.s.Messages(ctx, f.owner, f.target.ID, 0)
	require.NoError(t, err)
	require.Len(t, messages, 2)
	require.Equal(t, f.message.ID, messages[1].ReplyTo)
	require.Equal(t, f.owner, messages[1].Reply.AuthorID)
	page, err := f.s.ReactionSummaries(ctx, f.agent, f.target.ID, f.message.ID, store.ReactionQuery{})
	require.NoError(t, err)
	require.EqualValues(t, 3, page.Version)
	require.EqualValues(t, 1, page.Summaries[0].Count)
	require.False(t, page.Summaries[0].Selected)
	persisted, err := f.s.GetExecutionRun(ctx, f.owner, f.run.Context.RunID)
	require.NoError(t, err)
	require.Equal(t, "completed", persisted.Status)
	var actions, linked, pending int
	require.NoError(t, f.s.Pool.QueryRow(ctx, "SELECT count(*) FROM execution_actions WHERE run_id=$1", f.run.Context.RunID).Scan(&actions))
	require.Equal(t, 2, actions)
	require.NoError(t, f.s.Pool.QueryRow(ctx, "SELECT count(*),count(*) FILTER(WHERE status='pending') FROM transport_outbox WHERE execution_run_id=$1", f.run.Context.RunID).Scan(&linked, &pending))
	require.Equal(t, 2, linked)
	require.Equal(t, linked, pending)
	var events []byte
	require.NoError(t, f.s.Pool.QueryRow(ctx, "SELECT jsonb_agg(event)::text FROM execution_events WHERE run_id=$1", f.run.Context.RunID).Scan(&events))
	require.Contains(t, string(events), "im_emoji_list")
	require.Contains(t, string(events), "im_reaction_list")
}
func TestHarnessInteractionsHTTPGlobalCatalogKeepsRunScopeAndUnconfiguredCapabilities(t *testing.T) {
	f := newHarnessInteractionFixture(t, true)
	ctx := context.Background()
	page, err := f.gateway.ReadEmoji(ctx, f.run.Context, emoji.Query{Limit: 2})
	require.NoError(t, err)
	require.Len(t, page.Entries, 2)
	require.NotNil(t, page.NextOffset)
	next, err := f.gateway.ReadEmoji(ctx, f.run.Context, emoji.Query{Limit: 2, Offset: *page.NextOffset, Revision: page.Revision})
	require.NoError(t, err)
	require.Equal(t, *page.NextOffset, next.Offset)
	stopped, err := f.s.SetStopped(ctx, f.owner, f.source.ID, "stop-before-catalog-read", f.source.Version, true)
	require.NoError(t, err)
	empty, err := f.gateway.ReadEmoji(ctx, f.run.Context, emoji.Query{})
	require.ErrorIs(t, err, harness.ErrStopped)
	require.Empty(t, empty.Entries)
	_, err = f.gateway.ReadMessage(ctx, f.run.Context, f.target.ID, f.message.ID)
	require.ErrorIs(t, err, harness.ErrStopped)
	_, err = f.gateway.ReadReactions(ctx, f.run.Context, f.target.ID, f.message.ID, harness.ReactionReadQuery{})
	require.ErrorIs(t, err, harness.ErrStopped)
	_, err = f.s.SetStopped(ctx, f.owner, f.source.ID, "resume-before-catalog-read", stopped.Version, false)
	require.NoError(t, err)
	_, err = f.gateway.ReadEmoji(ctx, f.run.Context, emoji.Query{})
	require.ErrorIs(t, err, harness.ErrStopped)
	bare := newHarnessInteractionFixture(t, false)
	require.Equal(t, []string{"message.send", "profile.update"}, bare.gateway.AllowedActionTypes())
	require.NotContains(t, bare.gateway.NativeReadCapabilities(), "emoji.list")
	_, err = bare.gateway.ReadEmoji(ctx, bare.run.Context, emoji.Query{})
	require.ErrorIs(t, err, harness.ErrDenied)
	payload, _ := json.Marshal(map[string]any{"message_id": bare.message.ID, "emoji": "feishu:OK", "active": true})
	_, err = bare.gateway.Execute(ctx, bare.run.Context, harness.Action{ID: harness.StableID(bare.run.Context.RunID, "catalog-missing"), Type: "reaction.set", Payload: payload})
	require.ErrorIs(t, err, harness.ErrInvalid)
}

func TestHarnessCatalogRemovalClearsStoreValidatorAndNativeAdvertisement(t *testing.T) {
	f := newHarnessInteractionFixture(t, true)
	ctx := context.Background()
	payload, _ := json.Marshal(map[string]any{"message_id": f.message.ID, "emoji": "feishu:OK", "active": true})
	action := harness.Action{ID: harness.StableID(f.run.Context.RunID, "before-catalog-removal"), Type: "reaction.set", Payload: payload}
	_, err := f.gateway.Execute(ctx, f.run.Context, action)
	require.NoError(t, err)
	// Recompose the same Store with an explicitly absent catalog. Do not keep
	// an earlier deployment's validator behind the disabled public capability.
	disabled := New(f.s, fixtureVerifier{}, nil, nil, WithMachineVerifier(fixtureMachineVerifier{}))
	code, ack := request(t, disabled, "mt_fixture", "POST", "/internal/harness/binding", map[string]string{"principal_id": f.agent, "executor_id": f.binding.ExecutorID})
	require.Equal(t, 200, code)
	require.Equal(t, []any{"message.send", "profile.update"}, ack["action_types"])
	action.ID = harness.StableID(f.run.Context.RunID, "after-catalog-removal")
	code, _ = request(t, disabled, "mt_fixture", "POST", "/internal/harness/actions", map[string]any{"context": f.run.Context, "action": action})
	require.Equal(t, 400, code)
	var count int
	require.NoError(t, f.s.Pool.QueryRow(ctx, "SELECT count(*) FROM execution_actions WHERE run_id=$1", f.run.Context.RunID).Scan(&count))
	require.Equal(t, 1, count)
	page, err := f.s.ReactionSummaries(ctx, f.agent, f.target.ID, f.message.ID, store.ReactionQuery{})
	require.NoError(t, err)
	require.EqualValues(t, 1, page.Version)
	require.True(t, page.Summaries[0].Selected)
	code, out := request(t, disabled, "human-test", "POST", "/v1/rooms/"+f.target.ID+"/messages/"+f.message.ID+"/reactions", map[string]any{"action_id": "human-after-catalog-removal", "emoji": "feishu:OK", "active": false})
	require.Equal(t, 503, code)
	require.Equal(t, "emoji_catalog_unavailable", out["error"])
	for _, token := range []string{"human-test", "mt_fixture"} {
		code, out = request(t, disabled, token, "POST", "/v1/mcp", map[string]any{"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
		require.Equal(t, 200, code)
		for _, raw := range out["result"].(map[string]any)["tools"].([]any) {
			name := raw.(map[string]any)["name"]
			require.NotContains(t, []string{"message_reaction_set", "emoji_list", "emoji_get"}, name)
		}
	}
}
