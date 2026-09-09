package transport

import (
	"bytes"
	"encoding/json"
	"io"
	"strings"

	"github.com/google/uuid"
	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
)

// BridgeBinding is operator configuration for a trusted service process, not a
// user-editable identity assertion. Secret is never returned to commercial UI.
type BridgeBinding struct {
	ID         string `json:"id"`
	ReceiverID string `json:"receiver_id"`
	RoomID     string `json:"room_id"`
	Secret     string `json:"secret"`
}

func (b BridgeBinding) Valid() bool {
	return reactionTransportID(b.ID) && ingressUUID(b.ReceiverID) && ingressUUID(b.RoomID) && len(b.Secret) >= 32 && len(b.Secret) <= 256 && !strings.ContainsAny(b.Secret, " \t\r\n")
}

// SDKReceived contains fields observed by the actual Events.MESSAGES listener.
// Receiver identity comes exclusively from the authenticated bridge binding.
type SDKReceived struct {
	Schema           string          `json:"schema"`
	MessageUID       string          `json:"message_uid"`
	ConversationType int             `json:"conversation_type"`
	TargetID         string          `json:"target_id"`
	SenderID         string          `json:"sender_id"`
	MessageType      string          `json:"message_type"`
	Content          json.RawMessage `json:"content"`
	ReceivedTime     int64           `json:"received_time"`
}

// CanonicalIngress is the strictly decoded canonical pointer and payload hash.
// It is still untrusted until matched to an accepted outbox receipt by Store.
type CanonicalIngress struct {
	ProviderUID     string
	RoomID          string
	AuthorID        string
	MessageID       string
	Kind            string
	Seq             int64
	Version         int64
	ContentSHA256   string
	SDKReceivedTime int64
	EnvelopeSHA256  string
}

func DecodeSDKReceived(raw []byte) (CanonicalIngress, error) {
	var out CanonicalIngress
	var sdk SDKReceived
	if len(raw) > 65536 || strictJSON(raw, &sdk) != nil || sdk.Schema != "renji.rongcloud.sdk-received.v1" || sdk.ConversationType != 3 || !ingressUUID(sdk.TargetID) || !ingressUUID(sdk.SenderID) || !reactionTransportID(sdk.MessageUID) || sdk.ReceivedTime < 0 {
		return out, domain.ErrInvalid
	}
	out = CanonicalIngress{ProviderUID: sdk.MessageUID, RoomID: sdk.TargetID, AuthorID: sdk.SenderID, SDKReceivedTime: sdk.ReceivedTime, EnvelopeSHA256: policyHash(raw)}
	switch sdk.MessageType {
	case "RC:TxtMsg":
		var content struct {
			Content string `json:"content"`
			Extra   string `json:"extra"`
		}
		var pointer struct {
			Schema    string `json:"schema"`
			RoomID    string `json:"room_id"`
			MessageID string `json:"message_id"`
			Seq       int64  `json:"seq"`
		}
		if strictJSON(sdk.Content, &content) != nil || strictJSON([]byte(content.Extra), &pointer) != nil || pointer.Schema != "renji.message.v1" || pointer.RoomID != sdk.TargetID || !ingressUUID(pointer.MessageID) || pointer.Seq < 1 || len(content.Content) == 0 || len(content.Content) > 8192 {
			return CanonicalIngress{}, domain.ErrInvalid
		}
		out.MessageID = pointer.MessageID
		out.Seq = pointer.Seq
		out.Kind = "message.created"
		out.ContentSHA256 = policyHash([]byte(content.Content))
	case "RC:CmdMsg":
		var command struct {
			Name string `json:"name"`
			Data string `json:"data"`
		}
		var pointer struct {
			Schema    string `json:"schema"`
			RoomID    string `json:"room_id"`
			MessageID string `json:"message_id"`
			Version   int64  `json:"version"`
		}
		if strictJSON(sdk.Content, &command) != nil || command.Name != "renji.message.reaction" || strictJSON([]byte(command.Data), &pointer) != nil || pointer.Schema != "renji.reaction.v1" || pointer.RoomID != sdk.TargetID || !ingressUUID(pointer.MessageID) || pointer.Version < 1 {
			return CanonicalIngress{}, domain.ErrInvalid
		}
		out.MessageID = pointer.MessageID
		out.Version = pointer.Version
		out.Kind = "message.reaction_set"
	default:
		return CanonicalIngress{}, domain.ErrInvalid
	}
	return out, nil
}

func ingressUUID(id string) bool {
	parsed, err := uuid.Parse(id)
	return err == nil && parsed.String() == id
}
func strictJSON(raw []byte, out any) error {
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if err := d.Decode(out); err != nil {
		return err
	}
	if d.Decode(new(any)) != io.EOF {
		return domain.ErrInvalid
	}
	return nil
}
