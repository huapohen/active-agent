-- +goose Up
CREATE TABLE workspace_invitations (
 id uuid PRIMARY KEY,
 workspace_id uuid NOT NULL REFERENCES workspaces(id),
 created_by uuid NOT NULL REFERENCES principals(id),
 create_action_id text NOT NULL,
 creator_role text NOT NULL CHECK(creator_role IN ('owner','admin')),
 code_hash text NOT NULL UNIQUE CHECK(code_hash ~ '^[0-9a-f]{64}$'),
 role text NOT NULL DEFAULT 'member' CHECK(role='member'),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 expires_at timestamptz NOT NULL,
 accepted_by uuid REFERENCES principals(id),
 accepted_at timestamptz,
 accepted_run_id uuid REFERENCES execution_runs(id),
 revoked_at timestamptz,
 revoked_by uuid REFERENCES principals(id),
 issued_run_id uuid REFERENCES execution_runs(id),
 issued_authority jsonb,
 CHECK(expires_at>created_at),
 CHECK((accepted_by IS NULL)=(accepted_at IS NULL)),
 CHECK((revoked_by IS NULL)=(revoked_at IS NULL)),
 CHECK(accepted_at IS NULL OR revoked_at IS NULL),
 CHECK((issued_run_id IS NULL)=(issued_authority IS NULL)),
 UNIQUE(created_by,create_action_id)
);
CREATE INDEX workspace_invitations_directory ON workspace_invitations(workspace_id,id);
-- +goose Down
DROP TABLE workspace_invitations;
