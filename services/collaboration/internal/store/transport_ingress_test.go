package store

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/huapohen/active-agent/services/collaboration/internal/domain"
	"github.com/huapohen/active-agent/services/collaboration/internal/transport"
	"github.com/stretchr/testify/require"
)

func ingressFixture(t *testing.T, kind string) (*Store, string, string, domain.Room, domain.Message, transport.BridgeBinding, []byte) {
	t.Helper()
	s := testStore(t)
	ctx := context.Background()
	owner, receiver := actor(t, s, kind), actor(t, s, "human")
	w, err := s.CreateWorkspace(ctx, owner, "ingress-workspace", "可信接收测试")
	require.NoError(t, err)
	_, err = s.Pool.Exec(ctx, `INSERT INTO workspace_members VALUES($1,$2,'member')`, w, receiver)
	require.NoError(t, err)
	r, err := s.CreateRoom(ctx, owner, "ingress-create-room", w, "SDK隔离接收", []string{receiver})
	require.NoError(t, err)
	receipt, err := s.Send(ctx, owner, r.ID, domain.SendMessage{ActionID: "ingress-send-once", Content: "原始中文正文", ScopeEpoch: &r.ScopeEpoch})
	require.NoError(t, err)
	b := transport.BridgeBinding{ID: "bridge-fixture", ReceiverID: receiver, RoomID: r.ID, Secret: strings.Repeat("s", 32)}
	extra, _ := json.Marshal(map[string]any{"schema": "renji.message.v1", "room_id": r.ID, "message_id": receipt.Message.ID, "seq": receipt.Message.Seq})
	content, _ := json.Marshal(map[string]string{"content": receipt.Message.Content, "extra": string(extra)})
	raw, _ := json.Marshal(transport.SDKReceived{Schema: "renji.rongcloud.sdk-received.v1", MessageUID: "provider-uid-1", ConversationType: 3, TargetID: r.ID, SenderID: owner, MessageType: "RC:TxtMsg", Content: content, ReceivedTime: 123})
	return s, owner, receiver, r, receipt.Message, b, raw
}

func acceptFixtureOutbox(t *testing.T, s *Store, message domain.Message) {
	t.Helper()
	receipt := map[string]any{"code": 200, "messageUIDs": []map[string]string{{"groupId": message.RoomID, "messageUID": "provider-uid-1"}}}
	raw, _ := json.Marshal(receipt)
	_, err := s.Pool.Exec(context.Background(), `UPDATE transport_outbox SET status='delivered',provider_receipt=$2 WHERE event_id IN(SELECT id FROM events WHERE type='message.created' AND data->>'id'=$1)`, message.ID, raw)
	require.NoError(t, err)
}

func TestTransportIngressRequiresAcceptedCanonicalReceiptAndIsIdempotent(t *testing.T) {
	s, _, receiver, _, message, b, raw := ingressFixture(t, "human")
	ctx := context.Background()
	require.NoError(t, s.RecordTransportHeartbeat(ctx, b, "connected", 1))
	page, err := s.TransportArrivals(ctx, receiver, 0, 50, []transport.BridgeBinding{b})
	require.NoError(t, err)
	require.Empty(t, page.Events)
	require.Nil(t, page.Status.LastReceivedAt)
	require.Equal(t, "connected", page.Status.BridgeState)
	_, err = s.RecordTransportIngress(ctx, b, raw)
	require.ErrorIs(t, err, ErrIngressAwaitingAcceptance)
	acceptFixtureOutbox(t, s, message)
	var changed transport.SDKReceived
	require.NoError(t, json.Unmarshal(raw, &changed))
	changed.MessageUID = "wrong-uid"
	wrong, _ := json.Marshal(changed)
	_, err = s.RecordTransportIngress(ctx, b, wrong)
	require.ErrorIs(t, err, domain.ErrConflict)
	one, err := s.RecordTransportIngress(ctx, b, raw)
	require.NoError(t, err)
	two, err := s.RecordTransportIngress(ctx, b, raw)
	require.NoError(t, err)
	require.Equal(t, one, two)
	page, err = s.TransportArrivals(ctx, receiver, 0, 50, []transport.BridgeBinding{b})
	require.NoError(t, err)
	require.Len(t, page.Events, 1)
	require.Equal(t, one, page.Events[0])
	require.NotNil(t, page.Status.LastReceivedAt)
	var count int
	require.NoError(t, s.Pool.QueryRow(ctx, `SELECT count(*) FROM transport_inbox`).Scan(&count))
	require.Equal(t, 1, count)
	page, err = s.TransportArrivals(ctx, receiver, one.Cursor, 50, []transport.BridgeBinding{b})
	require.NoError(t, err)
	require.Empty(t, page.Events)
}

func TestTransportIngressDoesNotExposeAnotherReceiverOrRevokedRoom(t *testing.T) {
	s, owner, receiver, r, message, b, raw := ingressFixture(t, "human")
	ctx := context.Background()
	acceptFixtureOutbox(t, s, message)
	_, err := s.RecordTransportIngress(ctx, b, raw)
	require.NoError(t, err)
	require.NoError(t, s.RecordTransportHeartbeat(ctx, b, "connected", 1))
	page, err := s.TransportArrivals(ctx, owner, 0, 50, []transport.BridgeBinding{b})
	require.NoError(t, err)
	require.Empty(t, page.Events)
	require.Equal(t, "unavailable", page.Status.BridgeState)
	require.Nil(t, page.Status.LastReceivedAt)
	other, err := s.CreateRoom(ctx, owner, "ingress-second-room", r.WorkspaceID, "其他房间", []string{receiver})
	require.NoError(t, err)
	rebound := b
	rebound.RoomID = other.ID
	require.ErrorIs(t, s.RecordTransportHeartbeat(ctx, rebound, "connected", 2), domain.ErrConflict)
	page, err = s.TransportArrivals(ctx, receiver, 0, 50, []transport.BridgeBinding{rebound})
	require.NoError(t, err)
	require.Empty(t, page.Events)
	require.Nil(t, page.Status.LastHeartbeatAt)
	require.Nil(t, page.Status.LastReceivedAt)
	_, err = s.Pool.Exec(ctx, `DELETE FROM room_members WHERE room_id=$1 AND principal_id=$2`, r.ID, receiver)
	require.NoError(t, err)
	_, err = s.RecordTransportIngress(ctx, b, raw)
	require.ErrorIs(t, err, domain.ErrForbidden)
	page, err = s.TransportArrivals(ctx, receiver, 0, 50, []transport.BridgeBinding{b})
	require.NoError(t, err)
	require.Empty(t, page.Events)
	require.Nil(t, page.Status.LastReceivedAt)
	require.Equal(t, "unavailable", page.Status.BridgeState)
}

func TestTransportIngressAgentBrakePreservesHumanIntervention(t *testing.T) {
	for _, kind := range []string{"human", "agent"} {
		t.Run(kind, func(t *testing.T) {
			s, owner, receiver, r, message, b, raw := ingressFixture(t, kind)
			ctx := context.Background()
			acceptFixtureOutbox(t, s, message)
			_, err := s.SetStopped(ctx, owner, r.ID, "ingress-stop-room", r.Version, true)
			require.NoError(t, err)
			_, err = s.RecordTransportIngress(ctx, b, raw)
			if kind == "agent" {
				require.ErrorIs(t, err, domain.ErrStopped)
				return
			}
			require.NoError(t, err)
			require.NoError(t, s.RecordTransportHeartbeat(ctx, b, "connected", 1))
			page, err := s.TransportArrivals(ctx, receiver, 0, 50, []transport.BridgeBinding{b})
			require.NoError(t, err)
			require.Len(t, page.Events, 1)
			require.Equal(t, "connected", page.Status.BridgeState)
		})
	}
}

func TestTransportIngressHeartbeatRejectsLateConnected(t *testing.T) {
	s, _, receiver, _, _, b, _ := ingressFixture(t, "human")
	ctx := context.Background()
	require.NoError(t, s.RecordTransportHeartbeat(ctx, b, "connected", 10))
	require.NoError(t, s.RecordTransportHeartbeat(ctx, b, "disconnected", 12))
	require.ErrorIs(t, s.RecordTransportHeartbeat(ctx, b, "connected", 11), domain.ErrConflict)
	require.ErrorIs(t, s.RecordTransportHeartbeat(ctx, b, "connected", 12), domain.ErrConflict)
	require.ErrorIs(t, s.RecordTransportHeartbeat(ctx, b, "connected", 0), domain.ErrInvalid)
	page, err := s.TransportArrivals(ctx, receiver, 0, 50, []transport.BridgeBinding{b})
	require.NoError(t, err)
	require.Equal(t, "disconnected", page.Status.BridgeState)
	require.Nil(t, page.Status.LastReceivedAt)
}
