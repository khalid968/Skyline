-- Up Migration

-- Deliberately carries NO foreign keys. An audit record has to outlive the rows
-- it describes: if deleting a user could cascade or SET NULL into this table, a
-- deletion would quietly rewrite history, and ON DELETE SET NULL would also
-- collide with the append-only trigger below. Ids are stored as plain uuids
-- alongside a snapshot of the name at the time, so the record stays readable
-- after the subject is gone.
CREATE TABLE audit_log (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  action           text        NOT NULL,
  actor_user_id    uuid,
  actor_username   text,
  actor_ip         inet,
  target_user_id   uuid,
  target_username  text,
  target_group_id  uuid,
  target_device_id uuid,
  detail           jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT audit_log_action_format CHECK (action ~ '^[a-z_]+\.[a-z_]+$')
);

CREATE INDEX audit_log_created     ON audit_log (created_at DESC);
CREATE INDEX audit_log_actor       ON audit_log (actor_user_id, created_at DESC);
CREATE INDEX audit_log_target_user ON audit_log (target_user_id, created_at DESC);
CREATE INDEX audit_log_action      ON audit_log (action, created_at DESC);

-- Append-only at the storage layer. An audit trail an operator can quietly
-- edit is not an audit trail. Corrections are recorded as new entries.
CREATE OR REPLACE FUNCTION audit_log_append_only() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'audit_log is append-only; % is not permitted', TG_OP
    USING ERRCODE = 'insufficient_privilege';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER audit_log_no_update BEFORE UPDATE ON audit_log
  FOR EACH STATEMENT EXECUTE FUNCTION audit_log_append_only();

CREATE TRIGGER audit_log_no_delete BEFORE DELETE ON audit_log
  FOR EACH STATEMENT EXECUTE FUNCTION audit_log_append_only();

-- TRUNCATE does not fire row or DELETE triggers, so without this one statement
-- would wipe the whole trail and sail past the two triggers above.
CREATE TRIGGER audit_log_no_truncate BEFORE TRUNCATE ON audit_log
  FOR EACH STATEMENT EXECUTE FUNCTION audit_log_append_only();

-- Down Migration

DROP TRIGGER IF EXISTS audit_log_no_truncate ON audit_log;
DROP TRIGGER IF EXISTS audit_log_no_delete ON audit_log;
DROP TRIGGER IF EXISTS audit_log_no_update ON audit_log;
DROP FUNCTION IF EXISTS audit_log_append_only();
DROP TABLE IF EXISTS audit_log;
