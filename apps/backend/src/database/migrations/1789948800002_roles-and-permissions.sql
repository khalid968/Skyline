-- Up Migration

CREATE TABLE roles (
  key        text PRIMARY KEY,
  name       text        NOT NULL,
  rank       smallint    NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT roles_key_format CHECK (key ~ '^[a-z][a-z_]{1,30}$')
);

CREATE TABLE permissions (
  key         text PRIMARY KEY,
  description text NOT NULL,
  CONSTRAINT permissions_key_format CHECK (key ~ '^[a-z_]+\.[a-z_]+$')
);

CREATE TABLE role_permissions (
  role_key       text NOT NULL REFERENCES roles(key)       ON DELETE CASCADE,
  permission_key text NOT NULL REFERENCES permissions(key) ON DELETE CASCADE,
  PRIMARY KEY (role_key, permission_key)
);

INSERT INTO roles (key, name, rank) VALUES
  ('member',    'Member',        10),
  ('moderator', 'Moderator',     20),
  ('admin',     'Administrator', 30);

-- Every capability an operator can hold. Note what is absent and must stay
-- absent: there is no permission that grants access to message plaintext.
-- Administrators never hold message keys, so no such permission can exist.
INSERT INTO permissions (key, description) VALUES
  ('dashboard.access', 'Sign in to the admin dashboard'),
  ('users.read',       'List and view user accounts'),
  ('users.create',     'Create a user account and issue its activation code'),
  ('users.rename',     'Change a user display name or username'),
  ('users.suspend',    'Suspend or reinstate a user account'),
  ('users.delete',     'Delete a user account'),
  ('codes.issue',      'Issue a replacement activation code'),
  ('codes.revoke',     'Revoke an unredeemed activation code'),
  ('contacts.grant',   'Grant a contact link between two users'),
  ('contacts.revoke',  'Revoke a contact link between two users'),
  ('groups.create',    'Create a group'),
  ('groups.manage',    'Rename, archive, or change the membership of a group'),
  ('devices.read',     'List the devices registered to a user'),
  ('devices.revoke',   'Revoke a registered device'),
  ('audit.read',       'Read the audit log');

-- Members hold no operator permissions at all: the client needs none.
INSERT INTO role_permissions (role_key, permission_key)
SELECT 'admin', key FROM permissions;

INSERT INTO role_permissions (role_key, permission_key) VALUES
  ('moderator', 'dashboard.access'),
  ('moderator', 'users.read'),
  ('moderator', 'users.suspend'),
  ('moderator', 'contacts.grant'),
  ('moderator', 'contacts.revoke'),
  ('moderator', 'groups.manage'),
  ('moderator', 'devices.read'),
  ('moderator', 'audit.read');

-- Down Migration

DROP TABLE IF EXISTS role_permissions;
DROP TABLE IF EXISTS permissions;
DROP TABLE IF EXISTS roles;
