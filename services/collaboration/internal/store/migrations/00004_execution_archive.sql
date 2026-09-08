-- +goose Up
ALTER TABLE execution_runs ADD COLUMN evidence_seq bigint NOT NULL DEFAULT 0;
CREATE TABLE execution_evidence_entries (
    run_id uuid NOT NULL REFERENCES execution_runs(id),
    seq bigint NOT NULL CHECK(seq>0),
    kind text NOT NULL CHECK(kind IN('action','event','transport','run.status')),
    object_id text NOT NULL,
    data jsonb NOT NULL,
    recorded_at timestamptz NOT NULL,
    legacy_snapshot boolean NOT NULL DEFAULT false,
    PRIMARY KEY(run_id,seq)
);
-- The legacy tables did not contain a shared commit cursor. Preserve their
-- facts as explicitly labelled snapshots; this order is not invented chronology.
INSERT INTO execution_evidence_entries(run_id,seq,kind,object_id,data,recorded_at,legacy_snapshot)
SELECT run_id,row_number() OVER(PARTITION BY run_id ORDER BY at,kind,object_id),kind,object_id,data,at,true FROM (
 SELECT run_id,'action'::text kind,action_id object_id,to_jsonb(a)-'run_id' data,created_at at FROM execution_actions a
 UNION ALL SELECT run_id,'event',event_id,to_jsonb(e)-'run_id',created_at FROM execution_events e
 UNION ALL SELECT execution_run_id,'transport',id::text,jsonb_build_object('outbox_id',id,'event_id',event_id,'provider',provider,'status',status,'attempts',attempts,'provider_receipt',provider_receipt,'updated_at',updated_at),updated_at FROM transport_outbox WHERE execution_run_id IS NOT NULL
) old;
UPDATE execution_runs r SET evidence_seq=(SELECT coalesce(max(seq),0) FROM execution_evidence_entries e WHERE e.run_id=r.id);
-- +goose StatementBegin
CREATE FUNCTION capture_execution_archive_evidence() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE rid uuid; k text; oid text; body jsonb; n bigint;
BEGIN
 IF TG_TABLE_NAME='execution_actions' THEN
  rid:=NEW.run_id; k:='action'; oid:=NEW.action_id; body:=to_jsonb(NEW)-'run_id';
 ELSIF TG_TABLE_NAME='execution_events' THEN
  rid:=NEW.run_id; k:='event'; oid:=NEW.event_id; body:=to_jsonb(NEW)-'run_id';
 ELSIF TG_TABLE_NAME='transport_outbox' THEN
  rid:=NEW.execution_run_id;
  IF rid IS NULL THEN RETURN NEW; END IF;
  IF TG_OP='UPDATE' AND NEW.execution_run_id IS NOT DISTINCT FROM OLD.execution_run_id AND NEW.status=OLD.status AND NEW.attempts=OLD.attempts AND NEW.provider_receipt IS NOT DISTINCT FROM OLD.provider_receipt THEN RETURN NEW; END IF;
  k:='transport'; oid:=NEW.id::text;
  body:=jsonb_build_object('outbox_id',NEW.id,'event_id',NEW.event_id,'provider',NEW.provider,'status',NEW.status,'attempts',NEW.attempts,'provider_receipt',NEW.provider_receipt,'updated_at',NEW.updated_at);
 ELSE
  IF NEW.status=OLD.status THEN RETURN NEW; END IF;
  rid:=NEW.id; k:='run.status'; oid:=NEW.id::text;
  body:=jsonb_build_object('previous_status',OLD.status,'status',NEW.status);
 END IF;
 UPDATE execution_runs SET evidence_seq=evidence_seq+1 WHERE id=rid RETURNING evidence_seq INTO n;
 INSERT INTO execution_evidence_entries(run_id,seq,kind,object_id,data,recorded_at) VALUES(rid,n,k,oid,body,clock_timestamp());
 RETURN NEW;
END;
$$;
-- +goose StatementEnd
CREATE TRIGGER execution_action_archive AFTER INSERT ON execution_actions FOR EACH ROW EXECUTE FUNCTION capture_execution_archive_evidence();
CREATE TRIGGER execution_event_archive AFTER INSERT ON execution_events FOR EACH ROW EXECUTE FUNCTION capture_execution_archive_evidence();
CREATE TRIGGER execution_transport_archive AFTER INSERT OR UPDATE ON transport_outbox FOR EACH ROW EXECUTE FUNCTION capture_execution_archive_evidence();
CREATE TRIGGER execution_status_archive AFTER UPDATE OF status ON execution_runs FOR EACH ROW EXECUTE FUNCTION capture_execution_archive_evidence();

CREATE TABLE execution_archives (
 id uuid PRIMARY KEY,
 run_id uuid NOT NULL REFERENCES execution_runs(id),
 through_seq bigint NOT NULL CHECK(through_seq>=0),
 target_binding text NOT NULL,
 renderer_version text NOT NULL,
 run_snapshot jsonb NOT NULL,
 manifest_hash text NOT NULL,
 prepared_by uuid NOT NULL REFERENCES principals(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(run_id,through_seq,target_binding,renderer_version)
);
CREATE TABLE execution_archive_parts (
 archive_id uuid NOT NULL REFERENCES execution_archives(id),
 part integer NOT NULL CHECK(part>0),
 title text NOT NULL,
 content text NOT NULL,
 content_hash text NOT NULL,
 state text NOT NULL DEFAULT 'prepared' CHECK(state IN('prepared','in_flight','unknown','verified')),
 claim_token uuid,
 request_started_at timestamptz,
 lease_expires_at timestamptz,
 external_id text NOT NULL DEFAULT '',
 observed_content_hash text NOT NULL DEFAULT '',
 observed_title_hash text NOT NULL DEFAULT '',
 error_code text NOT NULL DEFAULT '',
 attempts integer NOT NULL DEFAULT 0,
 updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(archive_id,part)
);
CREATE TABLE execution_archive_cursors (
 run_id uuid NOT NULL REFERENCES execution_runs(id),
 target_binding text NOT NULL,
 verified_through bigint NOT NULL DEFAULT -1,
 archive_id uuid REFERENCES execution_archives(id),
 updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(run_id,target_binding)
);

-- +goose Down
DROP TABLE execution_archive_cursors,execution_archive_parts,execution_archives;
DROP TRIGGER execution_status_archive ON execution_runs;
DROP TRIGGER execution_transport_archive ON transport_outbox;
DROP TRIGGER execution_event_archive ON execution_events;
DROP TRIGGER execution_action_archive ON execution_actions;
DROP FUNCTION capture_execution_archive_evidence();
DROP TABLE execution_evidence_entries;
ALTER TABLE execution_runs DROP COLUMN evidence_seq;
