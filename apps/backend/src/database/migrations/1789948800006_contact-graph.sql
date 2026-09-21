-- Up Migration

CREATE TABLE groups (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text        NOT NULL,
  description text,
  created_by  uuid        NOT NULL REFERENCES users(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  archived_at timestamptz,
  CONSTRAINT groups_name_len        CHECK (char_length(name) BETWEEN 1 AND 80),
  CONSTRAINT groups_description_len CHECK (description IS NULL OR char_length(description) <= 500)
);

CREATE TRIGGER groups_set_updated_at BEFORE UPDATE ON groups
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Written only by an administrator. Members cannot add or remove anyone,
-- themselves included.
CREATE TABLE group_members (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id   uuid        NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  user_id    uuid        NOT NULL REFERENCES users(id)  ON DELETE CASCADE,
  added_by   uuid        NOT NULL REFERENCES users(id),
  added_at   timestamptz NOT NULL DEFAULT now(),
  removed_at timestamptz,
  removed_by uuid        REFERENCES users(id),
  CONSTRAINT group_members_removed_by_stamp CHECK (removed_by IS NULL OR removed_at IS NOT NULL)
);

CREATE UNIQUE INDEX group_members_one_live
  ON group_members (group_id, user_id) WHERE removed_at IS NULL;
CREATE INDEX group_members_user_live  ON group_members (user_id)  WHERE removed_at IS NULL;
CREATE INDEX group_members_group_live ON group_members (group_id) WHERE removed_at IS NULL;

-- The pair is stored in canonical order with a CHECK, so a link is structurally
-- symmetric: one row per pair, no direction, and no way to express "A can reach
-- B but B cannot reach A". Look up with (LEAST(a,b), GREATEST(a,b)).
CREATE TABLE contact_links (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_a_id  uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_b_id  uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_by uuid        NOT NULL REFERENCES users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  revoked_by uuid        REFERENCES users(id),
  CONSTRAINT contact_links_canonical_order  CHECK (user_a_id < user_b_id),
  CONSTRAINT contact_links_revoked_by_stamp CHECK (revoked_by IS NULL OR revoked_at IS NOT NULL)
);

-- One LIVE link per pair. Revoked rows accumulate as history, so a pair can be
-- granted, revoked and granted again without losing the record of either.
CREATE UNIQUE INDEX contact_links_one_live_per_pair
  ON contact_links (user_a_id, user_b_id) WHERE revoked_at IS NULL;

CREATE INDEX contact_links_a_live ON contact_links (user_a_id) WHERE revoked_at IS NULL;
CREATE INDEX contact_links_b_live ON contact_links (user_b_id) WHERE revoked_at IS NULL;

-- The authorization primitive. The Phase 4 ContactGraphGuard is built on this.
CREATE OR REPLACE FUNCTION are_linked(p_one uuid, p_two uuid) RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1 FROM contact_links
     WHERE user_a_id  = LEAST(p_one, p_two)
       AND user_b_id  = GREATEST(p_one, p_two)
       AND revoked_at IS NULL
  );
$$ LANGUAGE sql STABLE;

-- Every principal a user may act on: their live contacts, plus everyone who
-- shares a live group membership with them. Anything outside this set must be
-- answered with 404, never 403.
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

-- Down Migration

DROP FUNCTION IF EXISTS visible_user_ids(uuid);
DROP FUNCTION IF EXISTS are_linked(uuid, uuid);
DROP TABLE IF EXISTS contact_links;
DROP TABLE IF EXISTS group_members;
DROP TRIGGER IF EXISTS groups_set_updated_at ON groups;
DROP TABLE IF EXISTS groups;
