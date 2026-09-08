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

// HTTPModel implements Eino's model contract against an explicitly configured
// chat-completions endpoint. There is no implicit cloud/model fallback.
type HTTPModel struct {
	endpoint, token, name, effort string
	client                        *http.Client
}

func NewHTTPModel(endpoint, token, name, effort string) (*HTTPModel, error) {
	base, err := safeEndpoint(endpoint)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(token) == "" || strings.ContainsAny(token, "\r\n") || strings.TrimSpace(name) == "" {
		return nil, ErrInvalid
	}
	return &HTTPModel{base + "/chat/completions", token, name, effort, &http.Client{Timeout: 75 * time.Second, CheckRedirect: noRedirect}}, nil
}

func (m *HTTPModel) Generate(ctx context.Context, input []*schema.Message, options ...model.Option) (*schema.Message, error) {
	opts := model.GetCommonOptions(nil, options...)
	messages := make([]map[string]any, 0, len(input))
	for _, msg := range input {
		if msg == nil {
			return nil, ErrInvalid
		}
		entry := map[string]any{"role": msg.Role, "content": msg.Content}
		if len(msg.ToolCalls) > 0 {
			entry["tool_calls"] = msg.ToolCalls
		}
		if msg.ToolCallID != "" {
			entry["tool_call_id"] = msg.ToolCallID
		}
		messages = append(messages, entry)
	}
	payload := map[string]any{"model": m.name, "messages": messages, "stream": false, "max_completion_tokens": 4096}
	if m.effort != "" {
		payload["reasoning_effort"] = m.effort
	}
	if opts.MaxTokens != nil {
		if *opts.MaxTokens < 1 || *opts.MaxTokens > 8192 {
			return nil, ErrInvalid
		}
		payload["max_completion_tokens"] = *opts.MaxTokens
	}
	if len(opts.Tools) > 0 {
		tools := make([]map[string]any, 0, len(opts.Tools))
		for _, spec := range opts.Tools {
			if spec == nil {
				return nil, ErrInvalid
			}
			parameters, err := spec.ParamsOneOf.ToJSONSchema()
			if err != nil {
				return nil, ErrInvalid
			}
			tools = append(tools, map[string]any{"type": "function", "function": map[string]any{"name": spec.Name, "description": spec.Desc, "parameters": parameters}})
		}
		payload["tools"] = tools
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
		Choices []struct {
			Message struct {
				Role      string            `json:"role"`
				Content   string            `json:"content"`
				ToolCalls []schema.ToolCall `json:"tool_calls"`
			} `json:"message"`
			FinishReason string `json:"finish_reason"`
		} `json:"choices"`
		Usage struct {
			PromptTokens     int `json:"prompt_tokens"`
			CompletionTokens int `json:"completion_tokens"`
			TotalTokens      int `json:"total_tokens"`
		} `json:"usage"`
	}
	if err = json.Unmarshal(data, &result); err != nil || len(result.Choices) != 1 {
		return nil, fmt.Errorf("model response invalid")
	}
	choice := result.Choices[0]
	if choice.Message.Role != "assistant" || choice.FinishReason == "length" || choice.FinishReason == "content_filter" {
		return nil, fmt.Errorf("model response incomplete")
	}
	return &schema.Message{Role: schema.Assistant, Content: choice.Message.Content, ToolCalls: choice.Message.ToolCalls, ResponseMeta: &schema.ResponseMeta{
		FinishReason: choice.FinishReason, Usage: &schema.TokenUsage{PromptTokens: result.Usage.PromptTokens, CompletionTokens: result.Usage.CompletionTokens, TotalTokens: result.Usage.TotalTokens},
	}}, nil
}

func (m *HTTPModel) Stream(ctx context.Context, input []*schema.Message, options ...model.Option) (*schema.StreamReader[*schema.Message], error) {
	msg, err := m.Generate(ctx, input, options...)
	if err != nil {
		return nil, err
	}
	return schema.StreamReaderFromArray([]*schema.Message{msg}), nil
}
