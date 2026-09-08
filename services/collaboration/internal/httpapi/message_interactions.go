package httpapi

import (
	"encoding/json"
	"net/url"
	"strconv"

	"github.com/gin-gonic/gin"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/harness"
	"github.com/huapohen/active-agent/services/collaboration/internal/store"
)

type reactionCommand struct {
	ActionID   string `json:"action_id"`
	Emoji      string `json:"emoji"`
	Active     *bool  `json:"active"`
	ScopeEpoch *int64 `json:"scope_epoch,omitempty"`
	RunID      string `json:"run_id,omitempty"`
}

type messageQuery struct {
	After  int64
	Before *int64
	Limit  int
}

func readMessageQuery(values url.Values) (messageQuery, error) {
	out := messageQuery{Limit: 100}
	if !allowedQuery(values, "after", "before", "limit", "run_id") || (values.Has("after") && values.Has("before")) {
		return out, domain.ErrInvalid
	}
	for _, key := range []string{"after", "before"} {
		if raw, exists := values[key]; exists {
			n, err := strconv.ParseInt(raw[0], 10, 64)
			if err != nil || n < 0 {
				return out, domain.ErrInvalid
			}
			if key == "after" {
				out.After = n
			} else {
				out.Before = &n
			}
		}
	}
	if raw, exists := values["limit"]; exists {
		n, err := strconv.Atoi(raw[0])
		if err != nil || n < 1 || n > 100 {
			return out, domain.ErrInvalid
		}
		out.Limit = n
	}
	return out, nil
}

func messagePage(c *gin.Context, s *store.Store, room string, q messageQuery, runID string) (gin.H, error) {
	if q.Before != nil {
		return beforeMessagePage(c, s, room, *q.Before, q.Limit, runID)
	}
	messages, err := nativeMessages(c, s, room, q.After, runID)
	if err != nil {
		return nil, err
	}
	more := len(messages) > q.Limit
	if more {
		messages = messages[:q.Limit]
	}
	next := q.After
	if len(messages) > 0 {
		next = messages[len(messages)-1].Seq
	}
	return gin.H{"messages": messages, "cursor": next, "has_more": more}, nil
}

func nativeReactionSet(c *gin.Context, s *store.Store, room, message string, cmd reactionCommand) (any, error) {
	if cmd.Active == nil || !validID(room) || !validID(message) {
		return nil, domain.ErrInvalid
	}
	m, machine := machine(c)
	if !machine {
		if cmd.RunID != "" {
			return nil, domain.ErrInvalid
		}
		return s.SetReaction(c.Request.Context(), principal(c).ID, room, message, domain.SetReaction{ActionID: cmd.ActionID, Emoji: cmd.Emoji, Active: *cmd.Active, ScopeEpoch: cmd.ScopeEpoch})
	}
	if !validID(cmd.RunID) {
		return nil, domain.ErrInvalid
	}
	run, err := s.GetExecutionRun(c.Request.Context(), principal(c).ID, cmd.RunID)
	if err != nil {
		return nil, err
	}
	if run.Context.RoomID != room || (cmd.ScopeEpoch != nil && *cmd.ScopeEpoch != run.Context.ScopeEpoch) {
		return nil, domain.ErrStopped
	}
	payload, _ := json.Marshal(map[string]any{"room_id": room, "message_id": message, "emoji": cmd.Emoji, "active": *cmd.Active})
	return s.ExecuteAction(c.Request.Context(), m.Issuer, m.MachineSubject, run.Context, harness.Action{ID: cmd.ActionID, Type: "reaction.set", Payload: payload})
}

func nativeReactionRead(c *gin.Context, s *store.Store, room, message, runID string, q store.ReactionQuery) (domain.ReactionPage, error) {
	if !validID(room) || !validID(message) {
		return domain.ReactionPage{}, domain.ErrInvalid
	}
	m, ok := machine(c)
	if !ok {
		if runID != "" {
			return domain.ReactionPage{}, domain.ErrInvalid
		}
		return s.ReactionSummaries(c.Request.Context(), principal(c).ID, room, message, q)
	}
	if runID != "" {
		return s.ExecutionReactionSummaries(c.Request.Context(), m.Issuer, m.MachineSubject, runID, room, message, q)
	}
	return s.ExecutorReactionSummaries(c.Request.Context(), m.Issuer, m.MachineSubject, room, message, q)
}

func nativeMessage(c *gin.Context, s *store.Store, room, message, runID string) (domain.Message, error) {
	if !validID(room) || !validID(message) {
		return domain.Message{}, domain.ErrInvalid
	}
	m, ok := machine(c)
	if !ok {
		if runID != "" {
			return domain.Message{}, domain.ErrInvalid
		}
		return s.Message(c.Request.Context(), principal(c).ID, room, message)
	}
	if runID != "" {
		return s.ExecutionMessage(c.Request.Context(), m.Issuer, m.MachineSubject, runID, room, message)
	}
	return s.ExecutorMessage(c.Request.Context(), m.Issuer, m.MachineSubject, room, message)
}

func nativeMessagesBefore(c *gin.Context, s *store.Store, room string, before int64, limit int, runID string) ([]domain.Message, error) {
	m, ok := machine(c)
	if !ok {
		if runID != "" {
			return nil, domain.ErrInvalid
		}
		return s.MessagesBefore(c.Request.Context(), principal(c).ID, room, before, limit)
	}
	if runID != "" {
		return s.ExecutionMessagesBefore(c.Request.Context(), m.Issuer, m.MachineSubject, runID, room, before, limit)
	}
	return s.ExecutorMessagesBefore(c.Request.Context(), m.Issuer, m.MachineSubject, room, before, limit)
}

func beforeMessagePage(c *gin.Context, s *store.Store, room string, before int64, limit int, runID string) (gin.H, error) {
	messages, err := nativeMessagesBefore(c, s, room, before, limit, runID)
	if err != nil {
		return nil, err
	}
	more := len(messages) > limit
	if more {
		messages = messages[len(messages)-limit:]
	}
	next := int64(0)
	if len(messages) != 0 {
		next = messages[0].Seq
	}
	return gin.H{"messages": messages, "cursor": next, "has_more": more, "has_more_before": more, "direction": "before"}, nil
}

func readReactionQuery(values url.Values) (store.ReactionQuery, error) {
	out := store.ReactionQuery{After: values.Get("after"), Limit: 50}
	if !allowedQuery(values, "after", "limit", "expected_version", "run_id") {
		return out, domain.ErrInvalid
	}
	if raw, exists := values["limit"]; exists {
		n, err := strconv.Atoi(raw[0])
		if err != nil || n < 1 || n > 50 {
			return out, domain.ErrInvalid
		}
		out.Limit = n
	}
	if raw, exists := values["expected_version"]; exists {
		n, err := strconv.ParseInt(raw[0], 10, 64)
		if err != nil || n < 0 {
			return out, domain.ErrInvalid
		}
		out.ExpectedVersion = &n
	}
	return out, nil
}

func mountMessageInteractions(v1 *gin.RouterGroup, s *store.Store, cfg config) {
	v1.GET("/rooms/:room/messages/:message", func(c *gin.Context) {
		if !allowedQuery(c.Request.URL.Query(), "run_id") {
			fail(c, domain.ErrInvalid)
			return
		}
		m, err := nativeMessage(c, s, c.Param("room"), c.Param("message"), c.Query("run_id"))
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(200, gin.H{"message": m})
	})
	v1.GET("/rooms/:room/messages/:message/reactions", func(c *gin.Context) {
		q, err := readReactionQuery(c.Request.URL.Query())
		if err != nil {
			fail(c, err)
			return
		}
		page, err := nativeReactionRead(c, s, c.Param("room"), c.Param("message"), c.Query("run_id"), q)
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(200, page)
	})
	v1.POST("/rooms/:room/messages/:message/reactions", func(c *gin.Context) {
		var cmd reactionCommand
		if !strictBody(c, &cmd) {
			return
		}
		if cfg.emoji == nil {
			fail(c, errEmojiUnavailable)
			return
		}
		receipt, err := nativeReactionSet(c, s, c.Param("room"), c.Param("message"), cmd)
		if err != nil {
			fail(c, err)
			return
		}
		c.JSON(200, receipt)
	})
}
