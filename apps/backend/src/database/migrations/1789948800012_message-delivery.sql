-- Up Migration

-- ---------------------------------------------------------------------------
-- Phase 8a: message delivery. See decisions.md, "How messages move".
-- ---------------------------------------------------------------------------

-- A total order over messages, for system-message cursors (timestamps can tie).
ALTER TABLE messages ADD COLUMN seq bigserial;
CREATE UNIQUE INDEX messages_seq ON messages (seq);

-- Once a device has acknowledged its copy, the server erases the ciphertext.
-- The row stays (without content) for the delivery tick.
ALTER TABLE message_envelopes ALTER COLUMN ciphertext DROP NOT NULL;
ALTER TABLE message_envelopes ADD CONSTRAINT message_envelopes_erased_only_when_delivered
  CHECK (ciphertext IS NOT NULL OR delivered_at IS NOT NULL);

-- Ciphertext bytes never change, erasure is one-way, a delivery is never
-- undone, and envelopes are never deleted.
CREATE FUNCTION message_envelopes_guard() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'message envelopes are never deleted' USING ERRCODE = '23514';
  END IF;
  IF NEW.message_id IS DISTINCT FROM OLD.message_id
     OR NEW.recipient_device_id IS DISTINCT FROM OLD.recipient_device_id
     OR NEW.envelope_kind IS DISTINCT FROM OLD.envelope_kind THEN
    RAISE EXCEPTION 'an envelope''s addressing never changes' USING ERRCODE = '23514';
  END IF;
  IF NEW.ciphertext IS NOT NULL AND NEW.ciphertext IS DISTINCT FROM OLD.ciphertext THEN
    RAISE EXCEPTION 'ciphertext can only be erased, never changed' USING ERRCODE = '23514';
  END IF;
  IF OLD.delivered_at IS NOT NULL AND NEW.delivered_at IS DISTINCT FROM OLD.delivered_at THEN
    RAISE EXCEPTION 'a delivery is never undone' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER message_envelopes_guard BEFORE UPDATE OR DELETE ON message_envelopes
  FOR EACH ROW EXECUTE FUNCTION message_envelopes_guard();

-- How far each device has read the server's system messages (admin renames).
-- A new device starts at "now": it starts empty, like its encrypted history.
ALTER TABLE devices ADD COLUMN system_seq bigint NOT NULL DEFAULT 0;

-- Down Migration

ALTER TABLE devices DROP COLUMN IF EXISTS system_seq;
DROP TRIGGER IF EXISTS message_envelopes_guard ON message_envelopes;
DROP FUNCTION IF EXISTS message_envelopes_guard();
ALTER TABLE message_envelopes DROP CONSTRAINT IF EXISTS message_envelopes_erased_only_when_delivered;
-- Restoring NOT NULL fails if any ciphertext was erased. Intended: rolling back
-- past delivery with real traffic should stop and make someone look.
ALTER TABLE message_envelopes ALTER COLUMN ciphertext SET NOT NULL;
DROP INDEX IF EXISTS messages_seq;
ALTER TABLE messages DROP COLUMN IF EXISTS seq;
