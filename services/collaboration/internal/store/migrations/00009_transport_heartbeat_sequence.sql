-- +goose Up
-- Migration 00008 is already in use. A separate migration preserves its hash.
ALTER TABLE transport_bridge_status ADD COLUMN heartbeat_seq bigint NOT NULL DEFAULT 0 CHECK(heartbeat_seq>=0 AND heartbeat_seq<=9007199254740991);
-- +goose Down
ALTER TABLE transport_bridge_status DROP COLUMN heartbeat_seq;
