package domain

type MessageReply struct {
	MessageID  string `json:"message_id"`
	RoomID     string `json:"room_id"`
	AuthorID   string `json:"author_id"`
	AuthorName string `json:"author_name"`
	AuthorKind string `json:"author_kind"`
	Excerpt    string `json:"excerpt"`
	Seq        int64  `json:"seq"`
}
type SetReaction struct {
	ActionID   string `json:"action_id"`
	Emoji      string `json:"emoji"`
	Active     bool   `json:"active"`
	ScopeEpoch *int64 `json:"scope_epoch,omitempty"`
}
type ReactionSummary struct {
	Emoji    string `json:"emoji"`
	Count    int64  `json:"count"`
	Selected bool   `json:"selected"`
}
type ReactionReceipt struct {
	RoomID      string `json:"room_id"`
	MessageID   string `json:"message_id"`
	PrincipalID string `json:"principal_id"`
	Emoji       string `json:"emoji"`
	Active      bool   `json:"active"`
	Changed     bool   `json:"changed"`
	Version     int64  `json:"version"`
	Count       int64  `json:"count"`
	Selected    bool   `json:"selected"`
	Replayed    bool   `json:"replayed"`
}
type ReactionPage struct {
	RoomID    string            `json:"room_id"`
	MessageID string            `json:"message_id"`
	Summaries []ReactionSummary `json:"summaries"`
	Version   int64             `json:"version"`
	NextAfter string            `json:"next_after,omitempty"`
	HasMore   bool              `json:"has_more"`
}
