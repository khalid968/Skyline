-- Up Migration

CREATE TABLE users (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username     citext      NOT NULL UNIQUE,
  display_name text        NOT NULL,
  role_key     text        NOT NULL REFERENCES roles(key),
  status       user_status NOT NULL DEFAULT 'pending',
  created_by   uuid        REFERENCES users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  suspended_at timestamptz,
  deleted_at   timestamptz,
  CONSTRAINT users_username_format  CHECK (username ~ '^[a-z0-9][a-z0-9._-]{1,28}[a-z0-9]$'),
  CONSTRAINT users_display_name_len CHECK (char_length(display_name) BETWEEN 1 AND 80),
  CONSTRAINT users_suspended_stamp  CHECK (status <> 'suspended' OR suspended_at IS NOT NULL),
  CONSTRAINT users_deleted_stamp    CHECK (status <> 'deleted'   OR deleted_at   IS NOT NULL)
);

CREATE INDEX users_status     ON users (status);
CREATE INDEX users_role       ON users (role_key);
CREATE INDEX users_created_by ON users (created_by);

CREATE TRIGGER users_set_updated_at BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Every username ever assigned, to anyone, appears here exactly once. The
-- global UNIQUE is what makes "a released username is never reissued" a
-- storage-level guarantee rather than a rule application code must remember.
CREATE TABLE username_history (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username    citext      NOT NULL UNIQUE,
  user_id     uuid        NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  released_at timestamptz
);

CREATE INDEX username_history_user ON username_history (user_id);
CREATE UNIQUE INDEX username_history_one_current_per_user
  ON username_history (user_id) WHERE released_at IS NULL;

-- Keeps username_history in lockstep with users.username. A rename to a
-- username that has ever existed violates the UNIQUE above and aborts the
-- whole transaction, so the rename simply cannot happen.
CREATE OR REPLACE FUNCTION users_track_username() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.username IS NOT DISTINCT FROM OLD.username THEN
      RETURN NEW;
    END IF;
    UPDATE username_history
       SET released_at = now()
     WHERE user_id = OLD.id AND released_at IS NULL;
  END IF;

  INSERT INTO username_history (username, user_id) VALUES (NEW.username, NEW.id);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_track_username_on_insert AFTER INSERT ON users
  FOR EACH ROW EXECUTE FUNCTION users_track_username();

CREATE TRIGGER users_track_username_on_update AFTER UPDATE OF username ON users
  FOR EACH ROW EXECUTE FUNCTION users_track_username();

-- Down Migration

DROP TRIGGER IF EXISTS users_track_username_on_update ON users;
DROP TRIGGER IF EXISTS users_track_username_on_insert ON users;
DROP FUNCTION IF EXISTS users_track_username();
DROP TABLE IF EXISTS username_history;
DROP TRIGGER IF EXISTS users_set_updated_at ON users;
DROP TABLE IF EXISTS users;
