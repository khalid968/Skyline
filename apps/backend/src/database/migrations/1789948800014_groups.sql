-- Up Migration

-- ---------------------------------------------------------------------------
-- Groups (Phase 8b, decisions.md 2026-09-25). Groups are made and changed only
-- by operators in the dashboard; a member may leave on their own.
-- ---------------------------------------------------------------------------

-- A group message is encrypted ONCE with the sender's Sender Key (libsignal)
-- and stored per recipient device like any envelope.
ALTER TYPE envelope_kind ADD VALUE IF NOT EXISTS 'sender_key';

-- Moderators manage groups (owner decision), creating them included.
INSERT INTO role_permissions (role_key, permission_key)
VALUES ('moderator', 'groups.create')
ON CONFLICT DO NOTHING;

-- An archived group is closed: it no longer makes its members visible to one
-- another, and nothing can be sent in it.
CREATE OR REPLACE FUNCTION visible_user_ids(p_user uuid) RETURNS TABLE (user_id uuid) AS $$
  SELECT CASE WHEN cl.user_a_id = p_user THEN cl.user_b_id ELSE cl.user_a_id END
    FROM contact_links cl
   WHERE cl.revoked_at IS NULL
     AND p_user IN (cl.user_a_id, cl.user_b_id)
  UNION
  SELECT other.user_id
    FROM group_members mine
    JOIN group_members other ON other.group_id = mine.group_id
    JOIN groups g ON g.id = mine.group_id
   WHERE mine.user_id     = p_user
     AND mine.removed_at  IS NULL
     AND other.removed_at IS NULL
     AND g.archived_at    IS NULL
     AND other.user_id   <> p_user;
$$ LANGUAGE sql STABLE;

-- Membership history, newest-first per group (the dashboard shows it; the
-- inbox uses added_at so a new member gets no notices from before they joined).
CREATE INDEX group_members_history ON group_members (group_id, added_at);

-- Down Migration

DROP INDEX IF EXISTS group_members_history;

CREATE OR REPLACE FUNCTION visible_user_ids(p_user uuid) RETURNS TABLE (user_id uuid) AS $$
  SELECT CASE WHEN cl.user_a_id = p_user THEN cl.user_b_id ELSE cl.user_a_id END
    FROM contact_links cl
   WHERE cl.revoked_at IS NULL
     AND p_user IN (cl.user_a_id, cl.user_b_id)
  UNION
  SELECT other.user_id
    FROM group_members mine
    JOIN group_members other ON other.group_id = mine.group_id
   WHERE mine.user_id     = p_user
     AND mine.removed_at  IS NULL
     AND other.removed_at IS NULL
     AND other.user_id   <> p_user;
$$ LANGUAGE sql STABLE;

DELETE FROM role_permissions WHERE role_key = 'moderator' AND permission_key = 'groups.create';

-- Take 'sender_key' back out of the enum. Fails if any envelope still uses it:
-- intended, look first.
ALTER TYPE envelope_kind RENAME TO envelope_kind_old;
CREATE TYPE envelope_kind AS ENUM ('prekey', 'whisper');
ALTER TABLE message_envelopes
  ALTER COLUMN envelope_kind TYPE envelope_kind USING envelope_kind::text::envelope_kind;
DROP TYPE envelope_kind_old;
