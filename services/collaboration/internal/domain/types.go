package domain

import (
	"errors"
	"time"
)

var (
	ErrForbidden              = errors.New("forbidden")
	ErrConflict               = errors.New("action_conflict")
	ErrStopped                = errors.New("scope_stopped_or_stale")
	ErrInvalid                = errors.New("invalid_request")
	ErrProfileVersionConflict = errors.New("profile_version_conflict")
	ErrProfileBusy            = errors.New("profile_update_busy")
)

type Principal struct {
	ID          string `json:"id"`
	Kind        string `json:"kind"`
	DisplayName string `json:"display_name"`
}

type Room struct {
	ID          string `json:"id"`
	WorkspaceID string `json:"workspace_id"`
	Title       string `json:"title"`
	Kind        string `json:"kind"`
	Version     int64  `json:"version"`
	ScopeEpoch  int64  `json:"scope_epoch"`
	Stopped     bool   `json:"stopped"`
}

type Message struct {
	ID                 string            `json:"id"`
	RoomID             string            `json:"room_id"`
	AuthorID           string            `json:"author_id"`
	Content            string            `json:"content"`
	Seq                int64             `json:"seq"`
	CreatedAt          time.Time         `json:"created_at"`
	ReplyTo            string            `json:"reply_to,omitempty"`
	Reply              *MessageReply     `json:"reply,omitempty"`
	Reactions          []ReactionSummary `json:"reactions,omitempty"`
	ReactionVersion    int64             `json:"reaction_version,omitempty"`
	ReactionsHasMore   bool              `json:"reactions_has_more,omitempty"`
	ReactionsNextAfter string            `json:"reactions_next_after,omitempty"`
}

type Receipt struct {
	Message  Message `json:"message"`
	Replayed bool    `json:"replayed"`
}

type SendMessage struct {
	ActionID   string `json:"action_id"`
	Content    string `json:"content"`
	ScopeEpoch *int64 `json:"scope_epoch,omitempty"`
	ReplyTo    string `json:"reply_to,omitempty"`
}

type Event struct {
	ID          int64     `json:"id"`
	RoomID      string    `json:"room_id"`
	PrincipalID string    `json:"principal_id"`
	ActionID    string    `json:"action_id"`
	Type        string    `json:"type"`
	Data        any       `json:"data"`
	CreatedAt   time.Time `json:"created_at"`
}
