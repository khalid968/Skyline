-- Up Migration

-- code_hash is HMAC-SHA256(server pepper, normalized code). It is deterministic
-- so it can be indexed and looked up, and keyed so a database leak alone does
-- not yield redeemable codes. The code itself is shown once, at creation, and
-- is never stored or recoverable. A slow KDF is deliberately NOT used: codes
-- carry 128 bits of entropy, so there is nothing to brute force, and redemption
-- must stay cheap and constant-time.
CREATE TABLE activation_codes (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  code_hash             bytea       NOT NULL UNIQUE,
  issued_by             uuid        NOT NULL REFERENCES users(id),
  created_at            timestamptz NOT NULL DEFAULT now(),
  expires_at            timestamptz NOT NULL DEFAULT (now() + interval '72 hours'),
  redeemed_at           timestamptz,
  redeemed_by_device_id uuid        REFERENCES devices(id) ON DELETE RESTRICT,
  revoked_at            timestamptz,
  revoked_by            uuid        REFERENCES users(id),
  CONSTRAINT activation_codes_hash_len CHECK (octet_length(code_hash) = 32),
  CONSTRAINT activation_codes_expiry   CHECK (expires_at > created_at),
  CONSTRAINT activation_codes_redeemed_names_device
    CHECK ((redeemed_at IS NULL) = (redeemed_by_device_id IS NULL)),
  CONSTRAINT activation_codes_not_both_spent_and_revoked
    CHECK (redeemed_at IS NULL OR revoked_at IS NULL),
  CONSTRAINT activation_codes_revoked_by_stamp
    CHECK (revoked_by IS NULL OR revoked_at IS NOT NULL)
);

-- At most one live (unredeemed, unrevoked) code per user. Issuing a
-- replacement therefore requires revoking the outstanding one first.
CREATE UNIQUE INDEX activation_codes_one_live_per_user
  ON activation_codes (user_id) WHERE redeemed_at IS NULL AND revoked_at IS NULL;

CREATE INDEX activation_codes_user ON activation_codes (user_id);
CREATE INDEX activation_codes_expiring
  ON activation_codes (expires_at) WHERE redeemed_at IS NULL AND revoked_at IS NULL;

-- Single use, enforced by the database rather than trusted to the service.
-- Once a code is spent, its redemption facts are frozen: nothing can move
-- redeemed_at back to NULL, repoint it at another device, or rewrite the hash.
CREATE OR REPLACE FUNCTION activation_codes_freeze_when_spent() RETURNS trigger AS $$
BEGIN
  IF OLD.redeemed_at IS NOT NULL AND (
       NEW.redeemed_at           IS DISTINCT FROM OLD.redeemed_at OR
       NEW.redeemed_by_device_id IS DISTINCT FROM OLD.redeemed_by_device_id OR
       NEW.code_hash             IS DISTINCT FROM OLD.code_hash OR
       NEW.user_id               IS DISTINCT FROM OLD.user_id
     ) THEN
    RAISE EXCEPTION 'activation code % is already spent and cannot be redeemed again', OLD.id
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER activation_codes_single_use BEFORE UPDATE ON activation_codes
  FOR EACH ROW EXECUTE FUNCTION activation_codes_freeze_when_spent();

-- The only supported way to redeem a code. One atomic conditional UPDATE: the
-- row is claimed or it is not, with no window between the check and the write.
-- Do NOT reimplement this as SELECT-then-UPDATE in the service layer. That
-- races, and two devices could redeem the same code.
--
-- Returns the user id on success, or NULL for every failure mode alike:
-- unknown code, already spent, revoked, expired. Callers must not distinguish
-- between them, in the response body, the status code, or the time taken.
CREATE OR REPLACE FUNCTION redeem_activation_code(p_code_hash bytea, p_device_id uuid)
RETURNS uuid AS $$
DECLARE
  v_user_id uuid;
BEGIN
  UPDATE activation_codes
     SET redeemed_at           = now(),
         redeemed_by_device_id = p_device_id
   WHERE code_hash   = p_code_hash
     AND redeemed_at IS NULL
     AND revoked_at  IS NULL
     AND expires_at  > now()
  RETURNING user_id INTO v_user_id;

  RETURN v_user_id;
END;
$$ LANGUAGE plpgsql;

-- Down Migration

DROP FUNCTION IF EXISTS redeem_activation_code(bytea, uuid);
DROP TRIGGER IF EXISTS activation_codes_single_use ON activation_codes;
DROP FUNCTION IF EXISTS activation_codes_freeze_when_spent();
DROP TABLE IF EXISTS activation_codes;
