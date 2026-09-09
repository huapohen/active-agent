package transport

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestSDKIngressRejectsUnknownAndForgedPointers(t *testing.T) {
	room := "11111111-1111-4111-8111-111111111111"
	message := "22222222-2222-4222-8222-222222222222"
	actor := "33333333-3333-4333-8333-333333333333"
	data, _ := json.Marshal(map[string]any{"schema": "renji.reaction.v1", "room_id": room, "message_id": message, "version": 3})
	content, _ := json.Marshal(map[string]string{"name": "renji.message.reaction", "data": string(data)})
	sdk := SDKReceived{Schema: "renji.rongcloud.sdk-received.v1", MessageUID: "uid-1", ConversationType: 3, TargetID: room, SenderID: actor, MessageType: "RC:CmdMsg", Content: content}
	raw, _ := json.Marshal(sdk)
	result, err := DecodeSDKReceived(raw)
	require.NoError(t, err)
	require.Equal(t, int64(3), result.Version)
	require.Equal(t, "message.reaction_set", result.Kind)
	for _, mutate := range []func(*SDKReceived){func(v *SDKReceived) { v.ConversationType = 1 }, func(v *SDKReceived) { v.TargetID = actor }, func(v *SDKReceived) { v.MessageUID = "" }, func(v *SDKReceived) { v.SenderID = "user" }, func(v *SDKReceived) { v.MessageType = "RC:RcCmd" }, func(v *SDKReceived) { v.ReceivedTime = -1 }, func(v *SDKReceived) { v.Content = json.RawMessage(`{"name":"renji.message.reaction","data":"{}"}`) }} {
		v := sdk
		mutate(&v)
		b, _ := json.Marshal(v)
		_, err = DecodeSDKReceived(b)
		require.Error(t, err)
	}
	_, err = DecodeSDKReceived(append(raw, []byte(` {}`)...))
	require.Error(t, err)
}
