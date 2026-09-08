package harness

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/cloudwego/eino/components/model"
	"github.com/cloudwego/eino/schema"
)

const responsesReplayKey = "renji.responses.private_output.v1"

// ResponsesModel preserves the provider's output items in private, per-message
// memory for tool continuation. They never enter the visible execution archive.
// No shared previous_response_id or implicit endpoint/model fallback is used.
type ResponsesModel struct {
	endpoint, token, name, effort string
	client                        *http.Client
}

func NewConfiguredHTTPModel(endpoint, token, name, effort, style string) (model.BaseChatModel, error) {
	switch style {
	case "", "chat_completions":
		return NewHTTPModel(endpoint, token, name, effort)
	case "responses":
		base, err := safeEndpoint(endpoint)
		if err != nil {
			return nil, err
		}
		if strings.TrimSpace(token) == "" || strings.ContainsAny(token, "\r\n") || strings.TrimSpace(name) == "" {
			return nil, ErrInvalid
		}
		return &ResponsesModel{base + "/responses", token, name, effort, &http.Client{Timeout: 75 * time.Second, CheckRedirect: noRedirect}}, nil
	default:
		return nil, fmt.Errorf("%w: unsupported explicit model API style", ErrInvalid)
	}
}

func responseInput(messages []*schema.Message) ([]json.RawMessage, error) {
	items := []json.RawMessage{}
	add := func(v any) { b, _ := json.Marshal(v); items = append(items, b) }
	for _, m := range messages {
		if m == nil {
			return nil, ErrInvalid
		}
		if m.Role == schema.Assistant {
			if replay, ok := m.Extra[responsesReplayKey].(string); ok {
				var raw []json.RawMessage
				if json.Unmarshal([]byte(replay), &raw) != nil {
					return nil, ErrInvalid
				}
				decoded, err := decodeResponseOutput(raw)
				if err != nil || decoded.Content != m.Content || !sameTools(decoded.ToolCalls, m.ToolCalls) {
					return nil, ErrInvalid
				}
				items = append(items, raw...)
				continue
			}
		}
		if m.Role == schema.Tool {
			if m.ToolCallID == "" {
				return nil, ErrInvalid
			}
			add(map[string]any{"type": "function_call_output", "call_id": m.ToolCallID, "output": m.Content})
			continue
		}
		if m.Role != schema.User && m.Role != schema.System && m.Role != schema.Assistant {
			return nil, ErrInvalid
		}
		if m.Content != "" || len(m.ToolCalls) == 0 {
			add(map[string]any{"role": m.Role, "content": m.Content})
		}
		for _, call := range m.ToolCalls {
			if m.Role != schema.Assistant || call.ID == "" || call.Function.Name == "" || !json.Valid([]byte(call.Function.Arguments)) {
				return nil, ErrInvalid
			}
			add(map[string]any{"type": "function_call", "call_id": call.ID, "name": call.Function.Name, "arguments": call.Function.Arguments})
		}
	}
	return items, nil
}

func sameTools(a, b []schema.ToolCall) bool {
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return bytes.Equal(x, y)
}

func decodeResponseOutput(raw []json.RawMessage) (*schema.Message, error) {
	out := &schema.Message{Role: schema.Assistant}
	seen := map[string]bool{}
	var final, commentary, legacy string
	finalCount := 0
	for _, item := range raw {
		var v struct {
			Type, Role, Status, Phase, Name, Arguments string
			Content                                    []struct{ Type, Text string }
		}
		// call_id needs its explicit wire name; other fields decode case-insensitively.
		var call struct {
			CallID string `json:"call_id"`
		}
		if json.Unmarshal(item, &v) != nil || json.Unmarshal(item, &call) != nil {
			return nil, ErrInvalid
		}
		switch v.Type {
		case "reasoning": // opaque continuation only; never surface hidden fields
		case "message":
			if v.Role != "assistant" || v.Status != "completed" {
				return nil, fmt.Errorf("model response incomplete")
			}
			var content string
			for _, c := range v.Content {
				if c.Type != "output_text" {
					return nil, fmt.Errorf("model output content unsupported")
				}
				content += c.Text
			}
			switch v.Phase {
			case "final_answer":
				finalCount++
				final += content
			case "commentary":
				commentary += content
			case "":
				legacy += content
			default:
				return nil, fmt.Errorf("model output phase unsupported")
			}
		case "function_call":
			if call.CallID == "" || seen[call.CallID] || v.Name == "" || !json.Valid([]byte(v.Arguments)) || (v.Status != "" && v.Status != "completed") {
				return nil, ErrInvalid
			}
			seen[call.CallID] = true
			out.ToolCalls = append(out.ToolCalls, schema.ToolCall{ID: call.CallID, Type: "function", Function: schema.FunctionCall{Name: v.Name, Arguments: v.Arguments}})
		default:
			return nil, fmt.Errorf("model output item unsupported")
		}
	}
	if finalCount > 1 || (finalCount > 0 && legacy != "") {
		return nil, fmt.Errorf("model final output ambiguous")
	}
	if finalCount == 1 {
		out.Content = final
	} else if legacy != "" {
		out.Content = legacy
	} else if len(out.ToolCalls) > 0 {
		out.Content = commentary
	}
	if out.Content == "" && len(out.ToolCalls) == 0 {
		return nil, fmt.Errorf("model output empty")
	}
	return out, nil
}

func (m *ResponsesModel) Generate(ctx context.Context, input []*schema.Message, options ...model.Option) (*schema.Message, error) {
	opts := model.GetCommonOptions(nil, options...)
	items, err := responseInput(input)
	if err != nil {
		return nil, err
	}
	payload := map[string]any{"model": m.name, "input": items, "stream": false, "store": false, "max_output_tokens": 4096, "include": []string{"reasoning.encrypted_content"}}
	if m.effort != "" {
		payload["reasoning"] = map[string]string{"effort": m.effort}
	}
	if opts.MaxTokens != nil {
		if *opts.MaxTokens < 1 || *opts.MaxTokens > 8192 {
			return nil, ErrInvalid
		}
		payload["max_output_tokens"] = *opts.MaxTokens
	}
	if len(opts.Tools) > 0 {
		definitions := []map[string]any{}
		for _, spec := range opts.Tools {
			if spec == nil || spec.ParamsOneOf == nil {
				return nil, ErrInvalid
			}
			params, err := spec.ParamsOneOf.ToJSONSchema()
			if err != nil {
				return nil, ErrInvalid
			}
			definitions = append(definitions, map[string]any{"type": "function", "name": spec.Name, "description": spec.Desc, "parameters": params, "strict": false})
		}
		payload["tools"] = definitions
	}
	encoded, err := json.Marshal(payload)
	if err != nil || len(encoded) > 2*1024*1024 {
		return nil, ErrInvalid
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, m.endpoint, bytes.NewReader(encoded))
	if err != nil {
		return nil, ErrInvalid
	}
	req.Header.Set("Authorization", "Bearer "+m.token)
	req.Header.Set("Content-Type", "application/json")
	response, err := m.client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, fmt.Errorf("model endpoint unavailable")
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, 1024*1024+1))
	if err != nil || len(data) > 1024*1024 {
		return nil, fmt.Errorf("model response invalid")
	}
	if response.StatusCode != 200 {
		return nil, fmt.Errorf("model endpoint HTTP %d", response.StatusCode)
	}
	var result struct {
		Status string            `json:"status"`
		Output []json.RawMessage `json:"output"`
		Error  json.RawMessage   `json:"error"`
		Usage  struct {
			Input  int `json:"input_tokens"`
			Output int `json:"output_tokens"`
			Total  int `json:"total_tokens"`
		} `json:"usage"`
	}
	if json.Unmarshal(data, &result) != nil {
		return nil, fmt.Errorf("model response invalid")
	}
	if result.Status != "completed" || (len(result.Error) > 0 && string(result.Error) != "null") {
		return nil, fmt.Errorf("model response incomplete")
	}
	out, err := decodeResponseOutput(result.Output)
	if err != nil {
		return nil, err
	}
	private, _ := json.Marshal(result.Output)
	out.Extra = map[string]any{responsesReplayKey: string(private)}
	out.ResponseMeta = &schema.ResponseMeta{FinishReason: "stop", Usage: &schema.TokenUsage{PromptTokens: result.Usage.Input, CompletionTokens: result.Usage.Output, TotalTokens: result.Usage.Total}}
	if len(out.ToolCalls) > 0 {
		out.ResponseMeta.FinishReason = "tool_calls"
	}
	return out, nil
}

func (m *ResponsesModel) Stream(ctx context.Context, input []*schema.Message, options ...model.Option) (*schema.StreamReader[*schema.Message], error) {
	out, err := m.Generate(ctx, input, options...)
	if err != nil {
		return nil, err
	}
	return schema.StreamReaderFromArray([]*schema.Message{out}), nil
}
