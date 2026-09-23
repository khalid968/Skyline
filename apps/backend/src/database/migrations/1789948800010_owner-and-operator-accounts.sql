-- Up Migration

-- ---------------------------------------------------------------------------
-- The protected owner (owner decision, decisions.md 2026-09-23).
-- ---------------------------------------------------------------------------

-- Exactly zero or one owner. The owner is the first administrator; only the
-- owner may create, promote or remove admins, and no one (the owner included)
-- can demote, suspend or delete the owner account.
ALTER TABLE users ADD COLUMN is_owner boolean NOT NULL DEFAULT false;
CREATE UNIQUE INDEX users_single_owner ON users ((true)) WHERE is_owner;

-- An existing deployment's earliest active administrator becomes the owner.
UPDATE users SET is_owner = true
 WHERE id = (
   SELECT u.id FROM users u JOIN admin_credentials c ON c.user_id = u.id
    WHERE u.role_key = 'admin' AND u.status = 'active'
    ORDER BY u.created_at LIMIT 1
 );

-- Enforced in the database, not only in the service, so no code path (a bug,
-- a future endpoint, a script) can take the owner out.
CREATE OR REPLACE FUNCTION users_protect_owner() RETURNS trigger AS $$
BEGIN
  IF OLD.is_owner AND (
       NOT NEW.is_owner OR
       NEW.role_key <> 'admin' OR
       NEW.status   <> 'active'
     ) THEN
    RAISE EXCEPTION 'the owner account cannot be demoted, suspended, deleted or unmarked'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  IF NOT OLD.is_owner AND NEW.is_owner THEN
    RAISE EXCEPTION 'ownership cannot be granted by an update'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_protect_owner BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION users_protect_owner();

-- ---------------------------------------------------------------------------
-- Operator accounts created or reset by someone else.
-- ---------------------------------------------------------------------------

-- Set when an operator's password was chosen by someone else (a new admin, or
-- a reset by the owner). Until they choose their own, they can reach only
-- their own account settings.
ALTER TABLE admin_credentials ADD COLUMN must_change_password boolean NOT NULL DEFAULT false;

-- Changing someone's role is its own permission, held only by admins. The
-- service further restricts anything involving the admin role to the owner.
INSERT INTO permissions (key, description) VALUES
  ('users.role', 'Change a user''s role');
INSERT INTO role_permissions (role_key, permission_key) VALUES ('admin', 'users.role');

-- Down Migration

DELETE FROM role_permissions WHERE permission_key = 'users.role';
DELETE FROM permissions WHERE key = 'users.role';
ALTER TABLE admin_credentials DROP COLUMN IF EXISTS must_change_password;
DROP TRIGGER IF EXISTS users_protect_owner ON users;
DROP FUNCTION IF EXISTS users_protect_owner();
DROP INDEX IF EXISTS users_single_owner;
ALTER TABLE users DROP COLUMN IF EXISTS is_owner;
