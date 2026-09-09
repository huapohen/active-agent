-- +goose Up
CREATE TABLE transport_bridge_status (
    bridge_id text PRIMARY KEY,
    receiver_id uuid NOT NULL REFERENCES principals(id),
    room_id uuid NOT NULL REFERENCES rooms(id),
    connection_state text NOT NULL CHECK(connection_state IN('connected','disconnected')),
    heartbeat_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE transport_inbox (
    id bigserial PRIMARY KEY,
    bridge_id text NOT NULL,
    receiver_id uuid NOT NULL REFERENCES principals(id),
    room_id uuid NOT NULL REFERENCES rooms(id),
    message_id uuid NOT NULL REFERENCES messages(id),
    event_id bigint NOT NULL REFERENCES events(id),
    provider_uid text NOT NULL,
    kind text NOT NULL CHECK(kind IN('message.created','message.reaction_set')),
    observed_scope_epoch bigint NOT NULL,
    sdk_received_time bigint NOT NULL CHECK(sdk_received_time>=0),
    envelope_sha256 text NOT NULL,
    received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(receiver_id,provider_uid),
    UNIQUE(receiver_id,event_id)
);
CREATE INDEX transport_inbox_receiver_cursor ON transport_inbox(receiver_id,id);
-- +goose Down
DROP TABLE transport_inbox,transport_bridge_status;
