-- Up Migration

-- ---------------------------------------------------------------------------
-- Media (decisions.md 2026-09-25). Files are encrypted on the phone; the server
-- stores opaque blobs in object storage (MinIO in development) for 30 days.
-- Nothing here can decrypt anything: the key travels inside the message.
-- ---------------------------------------------------------------------------

CREATE TYPE attachment_status AS ENUM ('uploading', 'ready', 'deleted');

-- A file is uploaded BEFORE the message that carries it is sent, so it
-- belongs to no message at first. It is claimed by exactly one message, once.
ALTER TABLE attachments ALTER COLUMN message_id DROP NOT NULL;
ALTER TABLE attachments ADD COLUMN status attachment_status NOT NULL DEFAULT 'uploading';
ALTER TABLE attachments ADD COLUMN upload_id text;              -- the S3 multipart upload
ALTER TABLE attachments ADD COLUMN deleted_at timestamptz;
ALTER TABLE attachments ALTER COLUMN uploaded_by_device_id SET NOT NULL;
-- 30 days from creation, whatever happens (owner decision).
ALTER TABLE attachments ALTER COLUMN expires_at SET DEFAULT now() + interval '30 days';
UPDATE attachments SET expires_at = created_at + interval '30 days' WHERE expires_at IS NULL;
ALTER TABLE attachments ALTER COLUMN expires_at SET NOT NULL;

-- 2 GB of plaintext plus the 16-byte GCM tag.
ALTER TABLE attachments ADD CONSTRAINT attachments_max_size
  CHECK (ciphertext_bytes <= 2147483648 + 16);
ALTER TABLE attachments ADD CONSTRAINT attachments_deleted_stamp
  CHECK ((status = 'deleted') = (deleted_at IS NOT NULL));
ALTER TABLE attachments ADD CONSTRAINT attachments_claimed_only_when_ready
  CHECK (message_id IS NULL OR status <> 'uploading');

-- The sweep's index now skips deleted rows (migration 007's covered all).
DROP INDEX attachments_expiring;
CREATE INDEX attachments_expiring ON attachments (expires_at) WHERE status <> 'deleted';

-- Uploaded parts (8 MB each, the last smaller). Enough to resume an upload and
-- to complete the S3 multipart upload.
CREATE TABLE attachment_parts (
  attachment_id uuid    NOT NULL REFERENCES attachments(id),
  part_number   integer NOT NULL,
  etag          text    NOT NULL,
  bytes         integer NOT NULL,
  uploaded_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (attachment_id, part_number),
  CONSTRAINT attachment_parts_number CHECK (part_number BETWEEN 1 AND 10000),
  CONSTRAINT attachment_parts_bytes CHECK (bytes BETWEEN 1 AND 8388608)
);

-- An attachment is claimed by one message and never moved to another; its
-- size and hash never change; rows are never deleted (status 'deleted' when
-- the blob is gone); a deletion is never undone.
CREATE FUNCTION attachments_guard() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'attachments are never deleted (mark them deleted)' USING ERRCODE = '23514';
  END IF;
  IF OLD.message_id IS NOT NULL AND NEW.message_id IS DISTINCT FROM OLD.message_id THEN
    RAISE EXCEPTION 'an attachment belongs to one message, for good' USING ERRCODE = '23514';
  END IF;
  IF NEW.ciphertext_bytes IS DISTINCT FROM OLD.ciphertext_bytes
     OR NEW.ciphertext_sha256 IS DISTINCT FROM OLD.ciphertext_sha256
     OR NEW.storage_key IS DISTINCT FROM OLD.storage_key
     OR NEW.uploaded_by_device_id IS DISTINCT FROM OLD.uploaded_by_device_id THEN
    RAISE EXCEPTION 'an attachment''s identity never changes' USING ERRCODE = '23514';
  END IF;
  IF OLD.status = 'deleted' AND NEW.status <> 'deleted' THEN
    RAISE EXCEPTION 'a deleted attachment stays deleted' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER attachments_guard BEFORE UPDATE OR DELETE ON attachments
  FOR EACH ROW EXECUTE FUNCTION attachments_guard();

-- Down Migration

DROP TRIGGER IF EXISTS attachments_guard ON attachments;
DROP FUNCTION IF EXISTS attachments_guard();
DROP TABLE IF EXISTS attachment_parts;
DROP INDEX IF EXISTS attachments_expiring;
CREATE INDEX attachments_expiring ON attachments (expires_at) WHERE expires_at IS NOT NULL;
ALTER TABLE attachments DROP CONSTRAINT IF EXISTS attachments_claimed_only_when_ready;
ALTER TABLE attachments DROP CONSTRAINT IF EXISTS attachments_deleted_stamp;
ALTER TABLE attachments DROP CONSTRAINT IF EXISTS attachments_max_size;
ALTER TABLE attachments ALTER COLUMN expires_at DROP NOT NULL;
ALTER TABLE attachments ALTER COLUMN expires_at DROP DEFAULT;
ALTER TABLE attachments ALTER COLUMN uploaded_by_device_id DROP NOT NULL;
ALTER TABLE attachments DROP COLUMN IF EXISTS deleted_at;
ALTER TABLE attachments DROP COLUMN IF EXISTS upload_id;
ALTER TABLE attachments DROP COLUMN IF EXISTS status;
-- Fails if an attachment was never claimed by a message. Intended: look first.
ALTER TABLE attachments ALTER COLUMN message_id SET NOT NULL;
DROP TYPE IF EXISTS attachment_status;
