-- Up Migration

-- ---------------------------------------------------------------------------
-- Devices: an Ed25519 signing key now; the Signal Protocol fields in Phase 7.
-- ---------------------------------------------------------------------------

-- The device proves possession of this key on every token refresh, so a stolen
-- refresh token alone is useless. PUBLIC key only; the private half never
-- leaves the device.
ALTER TABLE devices ADD COLUMN signing_key bytea;
ALTER TABLE devices ADD CONSTRAINT devices_signing_key_len CHECK (octet_length(signing_key) = 32);
ALTER TABLE devices ALTER COLUMN signing_key SET NOT NULL;

-- Two live devices sharing a signing key means one was cloned from the other.
CREATE UNIQUE INDEX devices_live_signing_key ON devices (signing_key) WHERE revoked_at IS NULL;

-- Filled in by Phase 7 (Encryption). The CHECK constraints still apply once set.
ALTER TABLE devices ALTER COLUMN identity_key DROP NOT NULL;
ALTER TABLE devices ALTER COLUMN registration_id DROP NOT NULL;

-- ---------------------------------------------------------------------------
-- Activation: redeem the code and create the device in ONE transaction.
-- ---------------------------------------------------------------------------

-- redeem_activation_code() must name the redeeming device, but the device row
-- can only be created once the code has told us whose account it is. Deferring
-- this foreign key to COMMIT lets both happen atomically: claim the code with a
-- pre-generated device id, then insert that device, then commit. If anything
-- fails, both roll back and the code is untouched.
ALTER TABLE activation_codes
  ALTER CONSTRAINT activation_codes_redeemed_by_device_id_fkey DEFERRABLE INITIALLY DEFERRED;

-- ---------------------------------------------------------------------------
-- Device sessions: short-lived access token + rotating refresh token.
-- ---------------------------------------------------------------------------

-- Both tokens are stored only as HMAC-SHA256 hashes under a server pepper.
-- previous_refresh_hash holds the refresh token that was just rotated away: if
-- it is ever presented again, someone other than the device has a copy, and
-- the whole session is revoked.
ALTER TABLE device_sessions ADD COLUMN access_token_hash bytea;
ALTER TABLE device_sessions ADD COLUMN access_expires_at timestamptz;
ALTER TABLE device_sessions ADD COLUMN previous_refresh_hash bytea;
ALTER TABLE device_sessions ADD CONSTRAINT device_sessions_access_hash_len
  CHECK (access_token_hash IS NULL OR octet_length(access_token_hash) = 32);
ALTER TABLE device_sessions ADD CONSTRAINT device_sessions_access_pairing
  CHECK ((access_token_hash IS NULL) = (access_expires_at IS NULL));
CREATE UNIQUE INDEX device_sessions_access_token ON device_sessions (access_token_hash)
  WHERE access_token_hash IS NOT NULL;
CREATE INDEX device_sessions_previous_refresh ON device_sessions (previous_refresh_hash)
  WHERE previous_refresh_hash IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Operators: password + optional TOTP, and dashboard sessions.
-- ---------------------------------------------------------------------------

-- Only operators (roles holding dashboard.access) have a row here. Members have
-- no password at all. password_hash is an Argon2id encoded string.
-- totp_secret_enc is the authenticator secret encrypted with AES-256-GCM under a
-- server key; totp_last_step records the last accepted code's time step so the
-- same code can never be used twice.
CREATE TABLE admin_credentials (
  user_id             uuid PRIMARY KEY REFERENCES users(id) ON DELETE RESTRICT,
  password_hash       text        NOT NULL,
  password_changed_at timestamptz NOT NULL DEFAULT now(),
  totp_secret_enc     bytea,
  totp_enabled_at     timestamptz,
  totp_last_step      bigint,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT admin_credentials_argon2id CHECK (password_hash LIKE '$argon2id$%'),
  CONSTRAINT admin_credentials_totp_needs_secret
    CHECK (totp_enabled_at IS NULL OR totp_secret_enc IS NOT NULL)
);

CREATE TRIGGER admin_credentials_set_updated_at BEFORE UPDATE ON admin_credentials
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- A dashboard session. 'pending_mfa' is the short-lived state between a correct
-- password and a correct authenticator code; it grants nothing except the right
-- to submit that code.
CREATE TABLE admin_sessions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash   bytea       NOT NULL UNIQUE,
  state        text        NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  revoked_at   timestamptz,
  CONSTRAINT admin_sessions_state CHECK (state IN ('pending_mfa', 'active')),
  CONSTRAINT admin_sessions_hash_len CHECK (octet_length(token_hash) = 32),
  CONSTRAINT admin_sessions_expiry CHECK (expires_at > created_at)
);

CREATE INDEX admin_sessions_user_live ON admin_sessions (user_id) WHERE revoked_at IS NULL;

-- Down Migration

DROP TABLE IF EXISTS admin_sessions;
DROP TRIGGER IF EXISTS admin_credentials_set_updated_at ON admin_credentials;
DROP TABLE IF EXISTS admin_credentials;

DROP INDEX IF EXISTS device_sessions_previous_refresh;
DROP INDEX IF EXISTS device_sessions_access_token;
ALTER TABLE device_sessions DROP CONSTRAINT IF EXISTS device_sessions_access_pairing;
ALTER TABLE device_sessions DROP CONSTRAINT IF EXISTS device_sessions_access_hash_len;
ALTER TABLE device_sessions DROP COLUMN IF EXISTS previous_refresh_hash;
ALTER TABLE device_sessions DROP COLUMN IF EXISTS access_expires_at;
ALTER TABLE device_sessions DROP COLUMN IF EXISTS access_token_hash;

ALTER TABLE activation_codes
  ALTER CONSTRAINT activation_codes_redeemed_by_device_id_fkey NOT DEFERRABLE;

-- Restoring NOT NULL fails if Phase 5 devices exist without Signal keys. That is
-- intended: rolling back past Phase 5 with real devices registered should stop
-- and make someone look, not silently discard them.
ALTER TABLE devices ALTER COLUMN registration_id SET NOT NULL;
ALTER TABLE devices ALTER COLUMN identity_key SET NOT NULL;
DROP INDEX IF EXISTS devices_live_signing_key;
ALTER TABLE devices DROP CONSTRAINT IF EXISTS devices_signing_key_len;
ALTER TABLE devices DROP COLUMN IF EXISTS signing_key;
