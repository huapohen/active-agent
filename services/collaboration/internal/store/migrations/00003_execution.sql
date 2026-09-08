-- +goose Up
CREATE TABLE agent_execution_policies (
    principal_id uuid NOT NULL REFERENCES principals(id),
    workspace_id uuid NOT NULL REFERENCES workspaces(id),
    proactive_enabled boolean NOT NULL DEFAULT false,
    version bigint NOT NULL DEFAULT 1 CHECK(version>0),
    PRIMARY KEY(principal_id,workspace_id)
);
CREATE TABLE executors (
    id uuid PRIMARY KEY,
    issuer text NOT NULL,
    machine_subject text NOT NULL,
    principal_id uuid NOT NULL REFERENCES principals(id),
    workspace_id uuid NOT NULL REFERENCES workspaces(id),
    enabled boolean NOT NULL DEFAULT false,
    version bigint NOT NULL DEFAULT 1 CHECK(version>0),
    runtime_version text NOT NULL,
    workflow_version text NOT NULL,
    created_by uuid NOT NULL REFERENCES principals(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(issuer,machine_subject)
);
CREATE TABLE execution_runs (
    id uuid PRIMARY KEY,
    executor_id uuid NOT NULL REFERENCES executors(id),
    principal_id uuid NOT NULL REFERENCES principals(id),
    workspace_id uuid NOT NULL REFERENCES workspaces(id),
    executor_version bigint NOT NULL,
    policy_version bigint NOT NULL,
    parent_run_id uuid REFERENCES execution_runs(id),
    context jsonb NOT NULL,
    goal text NOT NULL CHECK(octet_length(goal) BETWEEN 1 AND 60000),
    status text NOT NULL DEFAULT 'running' CHECK(status IN('running','stopped','completed','failed','reconciliation_required')),
    created_by uuid NOT NULL REFERENCES principals(id),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE execution_actions (
    run_id uuid NOT NULL REFERENCES execution_runs(id),
    action_id text NOT NULL,
    request_hash text NOT NULL,
    action_type text NOT NULL,
    payload jsonb NOT NULL,
    receipt jsonb NOT NULL,
    message_id uuid REFERENCES messages(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(run_id,action_id)
);
CREATE TABLE execution_events (
    run_id uuid NOT NULL REFERENCES execution_runs(id),
    event_id text NOT NULL,
    request_hash text NOT NULL,
    event jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(run_id,event_id)
);
ALTER TABLE transport_outbox ADD COLUMN execution_run_id uuid REFERENCES execution_runs(id);
CREATE INDEX execution_runs_executor ON execution_runs(executor_id,created_at);

-- +goose Down
ALTER TABLE transport_outbox DROP COLUMN execution_run_id;
DROP TABLE execution_events,execution_actions,execution_runs,executors,agent_execution_policies;
