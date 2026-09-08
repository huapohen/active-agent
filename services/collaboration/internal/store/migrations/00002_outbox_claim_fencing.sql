-- +goose Up
ALTER TABLE transport_outbox ADD COLUMN claim_token uuid,
    ADD COLUMN lease_expires_at timestamptz, ADD COLUMN admitted_scope_epoch bigint;
ALTER TABLE transport_outbox DROP CONSTRAINT transport_outbox_status_check;
ALTER TABLE transport_outbox ADD CONSTRAINT transport_outbox_status_check
    CHECK(status IN ('pending','in_flight','delivered','rejected','unknown','blocked'));

-- Old events have no trustworthy historic admission epoch. Leave NULL; old
-- pending Agent deliveries require review, never today's epoch as invented history.
-- +goose StatementBegin
CREATE FUNCTION capture_outbox_scope_epoch() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    SELECT r.scope_epoch INTO NEW.admitted_scope_epoch
    FROM events e JOIN rooms r ON r.id=e.room_id WHERE e.id=NEW.event_id;
    RETURN NEW;
END;
$$;
-- +goose StatementEnd
CREATE TRIGGER transport_outbox_admission_epoch BEFORE INSERT ON transport_outbox
FOR EACH ROW EXECUTE FUNCTION capture_outbox_scope_epoch();

-- +goose Down
DROP TRIGGER transport_outbox_admission_epoch ON transport_outbox;
DROP FUNCTION capture_outbox_scope_epoch();
UPDATE transport_outbox SET status='rejected' WHERE status='blocked';
ALTER TABLE transport_outbox DROP CONSTRAINT transport_outbox_status_check;
ALTER TABLE transport_outbox ADD CONSTRAINT transport_outbox_status_check
    CHECK(status IN ('pending','in_flight','delivered','rejected','unknown'));
ALTER TABLE transport_outbox DROP COLUMN admitted_scope_epoch,
    DROP COLUMN lease_expires_at,DROP COLUMN claim_token;
