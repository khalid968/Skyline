-- Up Migration

-- ---------------------------------------------------------------------------
-- Admin dashboard v2 (Phase 11, decisions.md 2026-09-26): the overview page,
-- metadata-only abuse alerts with automatic limits, the audit log viewer and
-- dashboard sessions. Nothing here can see or count what anyone writes.
-- ---------------------------------------------------------------------------

-- Owner decision: the audit log is for the owner and admins; moderators no
-- longer read it.
DELETE FROM role_permissions WHERE role_key = 'moderator' AND permission_key = 'audit.read';

INSERT INTO permissions (key, description) VALUES
  ('overview.read', 'See service health and usage totals (never per person)'),
  ('alerts.manage', 'See abuse alerts, lift automatic limits and review alerts');

INSERT INTO role_permissions (role_key, permission_key) VALUES
  ('admin', 'overview.read'),
  ('admin', 'alerts.manage'),
  ('moderator', 'overview.read');

-- Board 39: where and how each dashboard session signed in. The address and
-- browser are the operator's own, shown back to operators; members' devices
-- have no such record.
ALTER TABLE admin_sessions ADD COLUMN ip inet;
ALTER TABLE admin_sessions ADD COLUMN user_agent text;
ALTER TABLE admin_sessions ADD COLUMN two_factor boolean NOT NULL DEFAULT false;
ALTER TABLE admin_sessions ADD CONSTRAINT admin_sessions_user_agent_len
  CHECK (user_agent IS NULL OR length(user_agent) <= 300);

-- Board 36: usage totals, one counter per day. Totals ONLY: there is no user,
-- device or chat column, so per-person activity cannot be read from here by
-- anyone, however they query it.
CREATE TABLE usage_daily (
  day    date   NOT NULL,
  metric text   NOT NULL,
  count  bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (day, metric),
  CONSTRAINT usage_daily_metric CHECK (metric IN ('messages', 'group_messages', 'relay_credentials')),
  CONSTRAINT usage_daily_count CHECK (count >= 0)
);

-- Board 37: alerts raised from counts and timing. `subject_key` is what the
-- alert is about (a device id, a user id, or an address), so one open alert per
-- kind and subject is updated rather than duplicated.
CREATE TABLE alerts (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind               text        NOT NULL,
  level              text        NOT NULL,
  subject_key        text        NOT NULL,
  subject_user_id    uuid,
  subject_device_id  uuid,
  subject_ip         inet,
  evidence           jsonb       NOT NULL DEFAULT '{}'::jsonb,
  auto_action        text,
  limit_until        timestamptz,
  lifted_at          timestamptz,
  lifted_by          uuid REFERENCES users(id),
  reviewed_at        timestamptz,
  reviewed_by        uuid REFERENCES users(id),
  outcome            text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT alerts_kind CHECK (kind IN ('send_rate', 'code_guessing', 'admin_password', 'device_burst', 'upload_rate')),
  CONSTRAINT alerts_level CHECK (level IN ('high', 'medium')),
  CONSTRAINT alerts_outcome CHECK (outcome IS NULL OR outcome IN ('none', 'suspended')),
  CONSTRAINT alerts_reviewed CHECK ((reviewed_at IS NULL) = (outcome IS NULL)),
  CONSTRAINT alerts_lifted CHECK ((lifted_at IS NULL) = (lifted_by IS NULL))
);

CREATE UNIQUE INDEX alerts_one_open ON alerts (kind, subject_key) WHERE reviewed_at IS NULL;
CREATE INDEX alerts_open ON alerts (created_at DESC) WHERE reviewed_at IS NULL;
CREATE INDEX alerts_reviewed ON alerts (reviewed_at DESC) WHERE reviewed_at IS NOT NULL;

-- Down Migration

DROP TABLE IF EXISTS alerts;
DROP TABLE IF EXISTS usage_daily;
ALTER TABLE admin_sessions DROP CONSTRAINT IF EXISTS admin_sessions_user_agent_len;
ALTER TABLE admin_sessions DROP COLUMN IF EXISTS two_factor;
ALTER TABLE admin_sessions DROP COLUMN IF EXISTS user_agent;
ALTER TABLE admin_sessions DROP COLUMN IF EXISTS ip;
DELETE FROM role_permissions WHERE permission_key IN ('overview.read', 'alerts.manage');
DELETE FROM permissions WHERE key IN ('overview.read', 'alerts.manage');
INSERT INTO role_permissions (role_key, permission_key) VALUES ('moderator', 'audit.read')
  ON CONFLICT DO NOTHING;
