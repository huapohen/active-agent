-- +goose Up
ALTER TABLE messages ADD CONSTRAINT messages_id_room_unique UNIQUE (id, room_id);
ALTER TABLE messages ADD COLUMN reply_to uuid;
ALTER TABLE messages ADD COLUMN reply_snapshot jsonb;
ALTER TABLE messages ADD COLUMN reaction_version bigint NOT NULL DEFAULT 0 CHECK (reaction_version >= 0);
ALTER TABLE messages ADD CONSTRAINT messages_reply_same_room FOREIGN KEY (reply_to, room_id) REFERENCES messages(id, room_id);
ALTER TABLE messages ADD CONSTRAINT messages_reply_snapshot_present CHECK ((reply_to IS NULL) = (reply_snapshot IS NULL));
CREATE TABLE message_reactions (
 message_id uuid NOT NULL REFERENCES messages(id),
 principal_id uuid NOT NULL REFERENCES principals(id),
 emoji text COLLATE "C" NOT NULL CHECK (octet_length(emoji) BETWEEN 1 AND 160),
 active boolean NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (message_id, principal_id, emoji)
);
CREATE INDEX message_reactions_active_summary ON message_reactions (message_id, emoji) WHERE active;
-- +goose Down
DROP TABLE message_reactions;
ALTER TABLE messages DROP CONSTRAINT messages_reply_snapshot_present;
ALTER TABLE messages DROP CONSTRAINT messages_reply_same_room;
ALTER TABLE messages DROP COLUMN reaction_version;
ALTER TABLE messages DROP COLUMN reply_snapshot;
ALTER TABLE messages DROP COLUMN reply_to;
ALTER TABLE messages DROP CONSTRAINT messages_id_room_unique;
