package harness

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/cloudwego/eino/schema"
	"github.com/stretchr/testify/require"
)

// Responses may return commentary and a final answer in the same output array.
// Only the final-answer phase is a plan; every original item still belongs in
// private continuation history. This exercises the real Eino planner rather
// than accepting concatenated output_text as an application-level answer.
func TestReviewResponsesCommentaryDoesNotCorruptFinalPlan(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"status":"completed","output":[{"id":"rs-review","type":"reasoning","summary":[],"encrypted_content":"review-private-only"},{"id":"msg-progress","type":"message","role":"assistant","phase":"commentary","status":"completed","content":[{"type":"output_text","text":"The source evidence is complete. "}]},{"id":"msg-final","type":"message","role":"assistant","phase":"final_answer","status":"completed","content":[{"type":"output_text","text":"{\"summary\":\"Reviewed the evidence\",\"done\":true,\"actions\":[]}"}]}]}`))
	}))
	defer server.Close()
	m, err := NewConfiguredHTTPModel(server.URL, "review-fixture", "gpt-6-astra", "medium", "responses")
	require.NoError(t, err)
	g := &fakeGateway{}
	planner, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
	require.NoError(t, err)
	result, err := planner.Plan(context.Background(), StageInput{Context: runContext(), Goal: "Review the source", Attempt: 1})
	require.NoError(t, err, "intermediate commentary must not be concatenated with the final JSON plan")
	require.True(t, result.Done)
	archive, err := json.Marshal(g.events)
	require.NoError(t, err)
	require.NotContains(t, string(archive), "review-private-only")
}

func TestReviewResponsesUnknownPhaseCannotBecomeAPlan(t *testing.T) {
	raw := []json.RawMessage{json.RawMessage(`{"type":"message","role":"assistant","phase":"future-unsupported-phase","status":"completed","content":[{"type":"output_text","text":"{\"summary\":\"not a known final phase\",\"done\":true,\"actions\":[]}"}]}`)}
	_, err := decodeResponseOutput(raw)
	require.Error(t, err, "unknown output phase must not silently become an executable plan")
}

func TestReviewResponsesToolReplayRetainsCommentaryPhase(t *testing.T) {
	raw := []json.RawMessage{
		json.RawMessage(`{"id":"rs-review","type":"reasoning","summary":[],"encrypted_content":"review-private-only"}`),
		json.RawMessage(`{"id":"msg-progress","type":"message","role":"assistant","phase":"commentary","status":"completed","content":[{"type":"output_text","text":"Reading evidence."}]}`),
		json.RawMessage(`{"id":"fc-review","type":"function_call","call_id":"review-call","name":"im_room_list","arguments":"{\"after\":\"\"}","status":"completed"}`),
	}
	message, err := decodeResponseOutput(raw)
	require.NoError(t, err)
	encoded, err := json.Marshal(raw)
	require.NoError(t, err)
	message.Extra = map[string]any{responsesReplayKey: string(encoded)}
	input, err := responseInput([]*schema.Message{schema.UserMessage("Review"), message, {Role: schema.Tool, ToolCallID: "review-call", Content: `{"rooms":[],"cursor":""}`}})
	require.NoError(t, err)
	require.Len(t, input, 5)
	for i := range raw {
		require.JSONEq(t, string(raw[i]), string(input[i+1]), "opaque reasoning and assistant phase must survive continuation")
	}
}

func TestReviewResponsesReasoningStaysPrivateAcrossEinoSummarization(t *testing.T) {
	var requests []map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		require.NoError(t, json.NewDecoder(r.Body).Decode(&body))
		requests = append(requests, body)
		switch len(requests) {
		case 1:
			_, _ = w.Write([]byte(`{"status":"completed","output":[{"type":"reasoning","id":"review-reasoning","summary":[],"encrypted_content":"summary-review-private-only"},{"type":"function_call","call_id":"read-skill","name":"skill","arguments":"{\"skill\":\"native-collaboration\"}","status":"completed"}],"usage":{"input_tokens":25000,"output_tokens":100,"total_tokens":25100}}`))
		case 2:
			// The high real-wire usage above triggers Eino's actual 24k middleware.
			require.Empty(t, body["tools"], "summarization must not execute additional tools")
			_, _ = w.Write([]byte(`{"status":"completed","output":[{"type":"message","role":"assistant","phase":"final_answer","status":"completed","content":[{"type":"output_text","text":"The authorized native collaboration skill was read. Retain the original run and scope. No business action has executed."}]}],"usage":{"input_tokens":100,"output_tokens":30,"total_tokens":130}}`))
		default:
			_, _ = w.Write([]byte(`{"status":"completed","output":[{"type":"message","role":"assistant","phase":"final_answer","status":"completed","content":[{"type":"output_text","text":"{\"summary\":\"Compacted authorized evidence\",\"done\":true,\"actions\":[]}"}]}]}`))
		}
	}))
	defer server.Close()
	m, err := NewConfiguredHTTPModel(server.URL, "summary-review-credential", "gpt-6-astra", "medium", "responses")
	require.NoError(t, err)
	g := &fakeGateway{}
	planner, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
	require.NoError(t, err)
	result, err := planner.Plan(context.Background(), StageInput{Context: runContext(), Goal: "Review the source", Attempt: 1})
	require.NoError(t, err)
	require.True(t, result.Done)
	require.Len(t, requests, 3)
	second, err := json.Marshal(requests[1]["input"])
	require.NoError(t, err)
	require.Contains(t, string(second), `"encrypted_content":"summary-review-private-only"`)
	require.Contains(t, string(second), `"call_id":"read-skill"`)
	require.Contains(t, string(second), `"type":"function_call_output"`)
	third, err := json.Marshal(requests[2]["input"])
	require.NoError(t, err)
	require.NotContains(t, string(third), "summary-review-private-only", "compacted history has no dangling private continuation")
	archive, err := json.Marshal(g.events)
	require.NoError(t, err)
	require.NotContains(t, string(archive), "summary-review-private-only")
	require.NotContains(t, string(archive), "summary-review-credential")
	require.NotContains(t, string(archive), responsesReplayKey)
}
