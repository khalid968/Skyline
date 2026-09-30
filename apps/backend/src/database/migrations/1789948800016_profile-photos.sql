-- Up Migration

-- ---------------------------------------------------------------------------
-- Profile photos (Phase 14d, board 46; owner decision 2026-09-29). Each person
-- sets their own photo. It is encrypted on their device like any attachment:
-- the server stores ciphertext and which attachment is whose current photo,
-- nothing else. The key travels to contacts inside Signal messages.
-- ---------------------------------------------------------------------------

-- An upload is either for a message or someone's profile photo, never both:
-- a profile photo can't be claimed by a message, and a message's file can't
-- become a profile photo.
ALTER TABLE attachments ADD COLUMN kind text NOT NULL DEFAULT 'message';
ALTER TABLE attachments ADD CONSTRAINT attachments_kind
  CHECK (kind IN ('message', 'profile'));
ALTER TABLE attachments ADD CONSTRAINT attachments_profile_unclaimed
  CHECK (kind <> 'profile' OR message_id IS NULL);

-- Whose current photo. While current it never expires (expires_at is
-- 'infinity'); replaced or removed, it expires at once and the usual sweep
-- deletes the blob.
ALTER TABLE users ADD COLUMN photo_attachment_id uuid REFERENCES attachments(id) ON DELETE RESTRICT;
CREATE UNIQUE INDEX users_photo_attachment ON users (photo_attachment_id)
  WHERE photo_attachment_id IS NOT NULL;

-- Down Migration

DROP INDEX IF EXISTS users_photo_attachment;
ALTER TABLE users DROP COLUMN IF EXISTS photo_attachment_id;
ALTER TABLE attachments DROP CONSTRAINT IF EXISTS attachments_profile_unclaimed;
ALTER TABLE attachments DROP CONSTRAINT IF EXISTS attachments_kind;
ALTER TABLE attachments DROP COLUMN IF EXISTS kind;
