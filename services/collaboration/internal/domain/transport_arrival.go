package domain

import "time"

// Arrival notices are persisted observations of a specific receiver's SDK,
// never fabricated from a successful sender request or a connection heartbeat.
type TransportArrival struct {
	Cursor      int64     `json:"cursor"`
	EventID     int64     `json:"event_id"`
	RoomID      string    `json:"room_id"`
	MessageID   string    `json:"message_id"`
	Kind        string    `json:"kind"`
	ProviderUID string    `json:"provider_uid"`
	ReceivedAt  time.Time `json:"received_at"`
}

type TransportBridgeStatus struct {
	BridgeState     string     `json:"bridge_state"`
	LastHeartbeatAt *time.Time `json:"last_heartbeat_at"`
	LastReceivedAt  *time.Time `json:"last_received_at"`
}

type TransportArrivalPage struct {
	Schema         string                `json:"schema"`
	Transport      string                `json:"transport"`
	Mode           string                `json:"mode"`
	Events         []TransportArrival    `json:"events"`
	NextCursor     int64                 `json:"next_cursor"`
	HasMore        bool                  `json:"has_more"`
	Status         TransportBridgeStatus `json:"status"`
	ReceiverID     string                `json:"receiver_id,omitempty"`
	RunID          string                `json:"run_id,omitempty"`
	CoveredRoomIDs []string              `json:"covered_room_ids,omitempty"`
}
