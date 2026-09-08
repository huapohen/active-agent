package harness

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/cloudwego/eino/schema"
	"github.com/stretchr/testify/require"
)

func TestResponsesToolContinuationPreservesOpaqueItemsWithoutArchivingThem(t *testing.T) {
	var requests []map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, "/responses", r.URL.Path)
		require.Equal(t, "Bearer fixture", r.Header.Get("Authorization"))
		var q map[string]any
		require.NoError(t, json.NewDecoder(r.Body).Decode(&q))
		requests = append(requests, q)
		require.Equal(t, false, q["store"])
		require.Equal(t, "gpt-6-astra", q["model"])
		require.Equal(t, "medium", q["reasoning"].(map[string]any)["effort"])
		w.Header().Set("Content-Type", "application/json")
		if len(requests) == 1 {
			_, _ = w.Write([]byte(`{"status":"completed","output":[{"type":"reasoning","id":"rs1","summary":[],"encrypted_content":"opaque-fixture"},{"type":"function_call","id":"fc1","call_id":"call1","name":"skill","arguments":"{\"skill\":\"native-collaboration\"}","status":"completed"}],"usage":{"input_tokens":20,"output_tokens":10,"total_tokens":30}}`))
			return
		}
		_, _ = w.Write([]byte(`{"status":"completed","output":[{"type":"message","role":"assistant","phase":"final_answer","status":"completed","content":[{"type":"output_text","text":"{\"summary\":\"Reviewed actual tool evidence\",\"done\":true,\"actions\":[]}"}]}]}`))
	}))
	defer server.Close()
	m, err := NewConfiguredHTTPModel(server.URL, "fixture", "gpt-6-astra", "medium", "responses")
	require.NoError(t, err)
	g := &fakeGateway{}
	p, err := NewEinoPlanner(PlannerConfig{Model: m, Gateway: g, AllowedActionTypes: []string{"message.send"}})
	require.NoError(t, err)
	result, err := p.Plan(context.Background(), StageInput{Context: runContext(), Goal: "Review the skill", Attempt: 1})
	require.NoError(t, err)
	require.True(t, result.Done)
	require.Len(t, requests, 2)
	second, _ := json.Marshal(requests[1]["input"])
	require.Contains(t, string(second), `"encrypted_content":"opaque-fixture"`)
	require.Contains(t, string(second), `"type":"function_call_output"`)
	require.Contains(t, string(second), `"call_id":"call1"`)
	archive, _ := json.Marshal(g.events)
	require.NotContains(t, string(archive), "opaque-fixture")
	require.NotContains(t, string(archive), responsesReplayKey)
	require.Contains(t, string(archive), "tool.result")
}

func TestResponsesRejectsIncompleteUnsafeAndUnknownOutputs(t *testing.T) {
	for _, body := range []string{
		`{"status":"incomplete","output":[]}`,
		`{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"refusal","text":"x"}]}]}`,
		`{"status":"completed","output":[{"type":"web_search_call"}]}`,
		`{"status":"completed","output":[{"type":"function_call","call_id":"1","name":"x","arguments":"oops"}]}`,
		`{"status":"completed","output":[{"type":"function_call","call_id":"1","name":"x","arguments":"{}"},{"type":"function_call","call_id":"1","name":"x","arguments":"{}"}]}`,
		`{"status":"completed","output":[{"type":"message","role":"assistant","status":"in_progress","content":[{"type":"output_text","text":"partial"}]}]}`,
	} {
		t.Run(body, func(t *testing.T) {
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte(body)) }))
			defer s.Close()
			m, err := NewConfiguredHTTPModel(s.URL, "fixture", "named-model", "medium", "responses")
			require.NoError(t, err)
			_, err = m.Generate(context.Background(), []*schema.Message{schema.UserMessage("test")})
			require.Error(t, err)
		})
	}
}

func TestResponsesDoesNotRedirectCredentialsOrMixIndependentHistories(t *testing.T) {
	called := false
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { called = true }))
	defer target.Close()
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL, http.StatusTemporaryRedirect)
	}))
	defer s.Close()
	m, err := NewConfiguredHTTPModel(s.URL, "fixture", "named-model", "medium", "responses")
	require.NoError(t, err)
	_, err = m.Generate(context.Background(), []*schema.Message{schema.UserMessage("test")})
	require.Error(t, err)
	require.False(t, called)
	private := `[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"old"}]}]`
	_, err = responseInput([]*schema.Message{{Role: schema.Assistant, Content: "changed", Extra: map[string]any{responsesReplayKey: private}}})
	require.Error(t, err)
	items, err := responseInput([]*schema.Message{schema.UserMessage("independent")})
	require.NoError(t, err)
	raw, _ := json.Marshal(items)
	require.NotContains(t, string(raw), "old")
	_, err = NewConfiguredHTTPModel(s.URL, "fixture", "named-model", "medium", "automatic-fallback")
	require.Error(t, err)
	_, err = responseInput([]*schema.Message{nil})
	require.Error(t, err)
	_, err = m.Generate(context.Background(), []*schema.Message{schema.UserMessage(strings.Repeat("x", 2*1024*1024))})
	require.ErrorIs(t, err, ErrInvalid)
}
