-- Up Migration

-- ---------------------------------------------------------------------------
-- Phase 7: the key directory. PUBLIC keys only.
--
-- Each device has its own Signal identity (decisions.md, 2026-09-23). To let
-- someone start an encrypted conversation with it while it is offline, the
-- device publishes a "prekey bundle": a signed prekey (EC, rotated), a
-- post-quantum Kyber prekey (one-time where possible, else a reusable
-- "last resort" one), and optionally a one-time EC prekey. PQXDH combines them.
--
-- The server cannot check the signatures (that would mean linking libsignal,
-- which is AGPL and forbidden in the backend, or writing XEdDSA ourselves,
-- which is custom cryptography). It does not need to: libsignal on the
-- fetching device verifies every signature against the identity key before
-- using a bundle, so a forged key is rejected by the only party that matters.
-- ---------------------------------------------------------------------------

-- libsignal addresses a device as (name, device id) where the device id is a
-- small integer (1..127). Ours are UUIDs, so each device also gets a number,
-- unique for the user FOR EVER (revoked devices keep theirs): reusing a number
-- would let a new device inherit sessions meant for an old one.
ALTER TABLE devices ADD COLUMN device_number smallint;
ALTER TABLE devices ADD CONSTRAINT devices_device_number_range
  CHECK (device_number BETWEEN 1 AND 127);
CREATE UNIQUE INDEX devices_user_device_number ON devices (user_id, device_number);

-- Serialized libsignal public key: a 0x05 type byte then 32 bytes.
ALTER TABLE devices ADD CONSTRAINT devices_identity_key_format
  CHECK (identity_key IS NULL OR (octet_length(identity_key) = 33 AND get_byte(identity_key, 0) = 5));

-- Two live devices with one identity key means one was cloned from the other.
CREATE UNIQUE INDEX devices_live_identity_key ON devices (identity_key)
  WHERE revoked_at IS NULL AND identity_key IS NOT NULL;

-- An identity key never changes. A new identity is a new device, with its own
-- activation code, and contacts are told. This is what makes safety numbers
-- mean something: the server cannot swap a key under a verified contact.
CREATE FUNCTION devices_identity_immutable() RETURNS trigger AS $$
BEGIN
  IF OLD.identity_key IS NOT NULL AND NEW.identity_key IS DISTINCT FROM OLD.identity_key THEN
    RAISE EXCEPTION 'a device identity key can never change' USING ERRCODE = '23514';
  END IF;
  IF OLD.registration_id IS NOT NULL AND NEW.registration_id IS DISTINCT FROM OLD.registration_id THEN
    RAISE EXCEPTION 'a device registration id can never change' USING ERRCODE = '23514';
  END IF;
  IF OLD.device_number IS NOT NULL AND NEW.device_number IS DISTINCT FROM OLD.device_number THEN
    RAISE EXCEPTION 'a device number can never change' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER devices_identity_immutable BEFORE UPDATE ON devices
  FOR EACH ROW EXECUTE FUNCTION devices_identity_immutable();

-- Key ids follow Signal's convention: 24-bit, chosen by the device.

-- The signed EC prekey. The device rotates it; the newest live one is served.
-- Old ones are kept (superseded_at) because a message may still arrive that was
-- encrypted to it.
CREATE TABLE signed_prekeys (
  id             bigserial PRIMARY KEY,
  device_id      uuid        NOT NULL REFERENCES devices(id),
  key_id         integer     NOT NULL,
  public_key     bytea       NOT NULL,
  signature      bytea       NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  superseded_at  timestamptz,
  CONSTRAINT signed_prekeys_key_id CHECK (key_id BETWEEN 1 AND 16777215),
  CONSTRAINT signed_prekeys_public_key CHECK (octet_length(public_key) = 33 AND get_byte(public_key, 0) = 5),
  CONSTRAINT signed_prekeys_signature CHECK (octet_length(signature) = 64)
);
CREATE UNIQUE INDEX signed_prekeys_device_key ON signed_prekeys (device_id, key_id);
CREATE UNIQUE INDEX signed_prekeys_one_current ON signed_prekeys (device_id) WHERE superseded_at IS NULL;

-- Kyber (ML-KEM) prekeys, signed by the identity key. One-time ones are handed
-- out once each; the single live "last resort" one is reused when they run out.
CREATE TABLE kyber_prekeys (
  id             bigserial PRIMARY KEY,
  device_id      uuid        NOT NULL REFERENCES devices(id),
  key_id         integer     NOT NULL,
  public_key     bytea       NOT NULL,
  signature      bytea       NOT NULL,
  last_resort    boolean     NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  -- one-time keys: who took it and when. Never handed out twice.
  claimed_at     timestamptz,
  claimed_by     uuid        REFERENCES devices(id),
  -- last-resort keys: replaced by a newer one.
  superseded_at  timestamptz,
  CONSTRAINT kyber_prekeys_key_id CHECK (key_id BETWEEN 1 AND 16777215),
  CONSTRAINT kyber_prekeys_public_key CHECK (octet_length(public_key) BETWEEN 1000 AND 1700),
  CONSTRAINT kyber_prekeys_signature CHECK (octet_length(signature) = 64),
  CONSTRAINT kyber_prekeys_claim_pair CHECK ((claimed_at IS NULL) = (claimed_by IS NULL)),
  CONSTRAINT kyber_prekeys_claim_kind CHECK (NOT (last_resort AND claimed_at IS NOT NULL)),
  CONSTRAINT kyber_prekeys_supersede_kind CHECK (last_resort OR superseded_at IS NULL)
);
CREATE UNIQUE INDEX kyber_prekeys_device_key ON kyber_prekeys (device_id, key_id);
CREATE UNIQUE INDEX kyber_prekeys_one_last_resort ON kyber_prekeys (device_id)
  WHERE last_resort AND superseded_at IS NULL;
CREATE INDEX kyber_prekeys_available ON kyber_prekeys (device_id, id)
  WHERE NOT last_resort AND claimed_at IS NULL;

-- One-time EC prekeys. Each is handed out at most once.
CREATE TABLE one_time_prekeys (
  id             bigserial PRIMARY KEY,
  device_id      uuid        NOT NULL REFERENCES devices(id),
  key_id         integer     NOT NULL,
  public_key     bytea       NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  claimed_at     timestamptz,
  claimed_by     uuid        REFERENCES devices(id),
  CONSTRAINT one_time_prekeys_key_id CHECK (key_id BETWEEN 1 AND 16777215),
  CONSTRAINT one_time_prekeys_public_key CHECK (octet_length(public_key) = 33 AND get_byte(public_key, 0) = 5),
  CONSTRAINT one_time_prekeys_claim_pair CHECK ((claimed_at IS NULL) = (claimed_by IS NULL))
);
CREATE UNIQUE INDEX one_time_prekeys_device_key ON one_time_prekeys (device_id, key_id);
CREATE INDEX one_time_prekeys_available ON one_time_prekeys (device_id, id) WHERE claimed_at IS NULL;

-- Published keys are facts, not drafts: a key's bytes can never be edited, a
-- claimed key can never be unclaimed, and nothing is deleted. Only the claim
-- and supersede stamps may be set, once.
CREATE FUNCTION prekeys_append_only() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME USING ERRCODE = '23514';
  END IF;
  IF NEW.device_id IS DISTINCT FROM OLD.device_id
     OR NEW.key_id IS DISTINCT FROM OLD.key_id
     OR NEW.public_key IS DISTINCT FROM OLD.public_key THEN
    RAISE EXCEPTION 'a published prekey can never change' USING ERRCODE = '23514';
  END IF;
  IF TG_TABLE_NAME <> 'one_time_prekeys' THEN
    IF NEW.signature IS DISTINCT FROM OLD.signature THEN
      RAISE EXCEPTION 'a published prekey can never change' USING ERRCODE = '23514';
    END IF;
  END IF;
  IF TG_TABLE_NAME <> 'signed_prekeys' THEN
    IF OLD.claimed_at IS NOT NULL AND (NEW.claimed_at IS DISTINCT FROM OLD.claimed_at
                                       OR NEW.claimed_by IS DISTINCT FROM OLD.claimed_by) THEN
      RAISE EXCEPTION 'a claimed prekey stays claimed' USING ERRCODE = '23514';
    END IF;
  END IF;
  IF TG_TABLE_NAME <> 'one_time_prekeys' THEN
    IF OLD.superseded_at IS NOT NULL AND NEW.superseded_at IS DISTINCT FROM OLD.superseded_at THEN
      RAISE EXCEPTION 'a superseded prekey stays superseded' USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER signed_prekeys_append_only BEFORE UPDATE OR DELETE ON signed_prekeys
  FOR EACH ROW EXECUTE FUNCTION prekeys_append_only();
CREATE TRIGGER kyber_prekeys_append_only BEFORE UPDATE OR DELETE ON kyber_prekeys
  FOR EACH ROW EXECUTE FUNCTION prekeys_append_only();
CREATE TRIGGER one_time_prekeys_append_only BEFORE UPDATE OR DELETE ON one_time_prekeys
  FOR EACH ROW EXECUTE FUNCTION prekeys_append_only();

-- TRUNCATE skips row triggers (the Phase 3 audit-log lesson), so refuse it too.
CREATE FUNCTION prekeys_no_truncate() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME USING ERRCODE = '23514';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER signed_prekeys_no_truncate BEFORE TRUNCATE ON signed_prekeys
  FOR EACH STATEMENT EXECUTE FUNCTION prekeys_no_truncate();
CREATE TRIGGER kyber_prekeys_no_truncate BEFORE TRUNCATE ON kyber_prekeys
  FOR EACH STATEMENT EXECUTE FUNCTION prekeys_no_truncate();
CREATE TRIGGER one_time_prekeys_no_truncate BEFORE TRUNCATE ON one_time_prekeys
  FOR EACH STATEMENT EXECUTE FUNCTION prekeys_no_truncate();

-- Down Migration

DROP TABLE IF EXISTS one_time_prekeys;
DROP TABLE IF EXISTS kyber_prekeys;
DROP TABLE IF EXISTS signed_prekeys;
DROP FUNCTION IF EXISTS prekeys_no_truncate();
DROP FUNCTION IF EXISTS prekeys_append_only();
DROP TRIGGER IF EXISTS devices_identity_immutable ON devices;
DROP FUNCTION IF EXISTS devices_identity_immutable();
DROP INDEX IF EXISTS devices_live_identity_key;
ALTER TABLE devices DROP CONSTRAINT IF EXISTS devices_identity_key_format;
DROP INDEX IF EXISTS devices_user_device_number;
ALTER TABLE devices DROP CONSTRAINT IF EXISTS devices_device_number_range;
ALTER TABLE devices DROP COLUMN IF EXISTS device_number;
