-- +goose Up
CREATE TABLE principals (
    id uuid PRIMARY KEY,
    kind text NOT NULL CHECK (kind IN ('human','agent')),
    display_name text NOT NULL,
    disabled boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE external_identities (
    issuer text NOT NULL,
    subject text NOT NULL,
    principal_id uuid NOT NULL REFERENCES principals(id),
    PRIMARY KEY (issuer,subject)
);
CREATE TABLE workspaces (
    id uuid PRIMARY KEY,
    title text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE workspace_members (
    workspace_id uuid NOT NULL REFERENCES workspaces(id),
    principal_id uuid NOT NULL REFERENCES principals(id),
    role text NOT NULL CHECK (role IN ('owner','admin','member')),
    PRIMARY KEY (workspace_id,principal_id)
);
CREATE TABLE rooms (
    id uuid PRIMARY KEY,
    workspace_id uuid NOT NULL REFERENCES workspaces(id),
    title text NOT NULL,
    kind text NOT NULL DEFAULT 'group' CHECK (kind IN ('group','direct')),
    version bigint NOT NULL DEFAULT 1,
    scope_epoch bigint NOT NULL DEFAULT 1,
    stopped boolean NOT NULL DEFAULT false,
    require_human boolean NOT NULL DEFAULT false,
    seq bigint NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE room_members (
    room_id uuid NOT NULL REFERENCES rooms(id),
    principal_id uuid NOT NULL REFERENCES principals(id),
    role text NOT NULL CHECK (role IN ('owner','admin','member')),
    PRIMARY KEY (room_id,principal_id)
);
CREATE TABLE messages (
    id uuid PRIMARY KEY,
    room_id uuid NOT NULL REFERENCES rooms(id),
    author_id uuid NOT NULL REFERENCES principals(id),
    content text NOT NULL CHECK (length(content)>0 AND octet_length(content)<=8192),
    seq bigint NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (room_id,seq)
);
CREATE TABLE actions (
    principal_id uuid NOT NULL REFERENCES principals(id),
    action_id text NOT NULL,
    request_hash text NOT NULL,
    receipt jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (principal_id,action_id)
);
CREATE TABLE events (
    id bigserial PRIMARY KEY,
    room_id uuid REFERENCES rooms(id),
    principal_id uuid NOT NULL REFERENCES principals(id),
    action_id text NOT NULL,
    type text NOT NULL,
    data jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX events_room_cursor ON events(room_id,id);
CREATE TABLE transport_outbox (
    id bigserial PRIMARY KEY,
    event_id bigint NOT NULL UNIQUE REFERENCES events(id),
    provider text NOT NULL CHECK(provider='rongcloud'),
    status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','in_flight','delivered','rejected','unknown')),
    attempts integer NOT NULL DEFAULT 0,
    provider_receipt jsonb,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- No cascading deletes: resource lifecycle must preserve actions and audit.
-- +goose Down
DROP TABLE transport_outbox,events,actions,messages,room_members,rooms,workspace_members,workspaces,external_identities,principals;
