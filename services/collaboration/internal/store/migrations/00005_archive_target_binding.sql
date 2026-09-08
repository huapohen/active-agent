-- +goose Up
CREATE TABLE execution_archive_target_configs (
 binding_id text PRIMARY KEY,
 config_hash text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
-- +goose Down
DROP TABLE execution_archive_target_configs;
