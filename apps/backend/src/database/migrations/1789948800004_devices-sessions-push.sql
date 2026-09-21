-- Up Migration

-- identity_key holds the device PUBLIC identity key only. Private key
-- material is generated on the device and never transmitted to the server.
CREATE TABLE devices (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid            NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name            text            NOT NULL,
  platform        device_platform NOT NULL,
  registration_id integer         NOT NULL,
  identity_key    bytea           NOT NULL,
  created_at      timestamptz     NOT NULL DEFAULT now(),
  last_seen_at    timestamptz,
  revoked_at      timestamptz,
  revoked_by      uuid            REFERENCES users(id),
  CONSTRAINT devices_name_len        CHECK (char_length(name) BETWEEN 1 AND 60),
  CONSTRAINT devices_registration_id CHECK (registration_id BETWEEN 1 AND 16383),
  CONSTRAINT devices_identity_key_len CHECK (octet_length(identity_key) BETWEEN 32 AND 33),
  CONSTRAINT devices_revoked_by_stamp CHECK (revoked_by IS NULL OR revoked_at IS NOT NULL)
);

CREATE UNIQUE INDEX devices_live_registration_id
  ON devices (user_id, registration_id) WHERE revoked_at IS NULL;
CREATE INDEX devices_user_live ON devices (user_id) WHERE revoked_at IS NULL;

-- refresh_token_hash is HMAC-SHA256 of the token under a server-side pepper.
-- The token itself is never stored, so a database leak does not yield
-- usable sessions.
CREATE TABLE device_sessions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id          uuid        NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  refresh_token_hash bytea       NOT NULL UNIQUE,
  created_at         timestamptz NOT NULL DEFAULT now(),
  last_used_at       timestamptz,
  expires_at         timestamptz NOT NULL,
  revoked_at         timestamptz,
  CONSTRAINT device_sessions_hash_len CHECK (octet_length(refresh_token_hash) = 32),
  CONSTRAINT device_sessions_expiry   CHECK (expires_at > created_at)
);

CREATE INDEX device_sessions_device_live
  ON device_sessions (device_id) WHERE revoked_at IS NULL;
CREATE INDEX device_sessions_expiring ON device_sessions (expires_at);

-- Push notifications are content-free wake-up signals. The server never
-- composes notification text: the device decrypts locally and builds it.
CREATE TABLE push_tokens (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id  uuid          NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  provider   push_provider NOT NULL,
  token      text          NOT NULL,
  created_at timestamptz   NOT NULL DEFAULT now(),
  revoked_at timestamptz
);

CREATE UNIQUE INDEX push_tokens_live ON push_tokens (provider, token) WHERE revoked_at IS NULL;
CREATE INDEX push_tokens_device_live ON push_tokens (device_id) WHERE revoked_at IS NULL;

-- Down Migration

DROP TABLE IF EXISTS push_tokens;
DROP TABLE IF EXISTS device_sessions;
DROP TABLE IF EXISTS devices;
