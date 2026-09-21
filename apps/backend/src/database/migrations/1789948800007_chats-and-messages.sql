-- Up Migration

-- A direct chat stores its pair in the same canonical order as contact_links,
-- so the chat and the link that authorizes it are joinable without a direction
-- decision. A group chat points at a group instead. The shape CHECK makes the
-- two cases mutually exclusive.
CREATE TABLE chats (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind              chat_kind   NOT NULL,
  group_id          uuid        REFERENCES groups(id) ON DELETE CASCADE,
  user_a_id         uuid        REFERENCES users(id)  ON DELETE CASCADE,
  user_b_id         uuid        REFERENCES users(id)  ON DELETE CASCADE,
  disappear_seconds integer,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chats_shape CHECK (
    (kind = 'group'
      AND group_id  IS NOT NULL
      AND user_a_id IS NULL
      AND user_b_id IS NULL)
    OR
    (kind = 'direct'
      AND group_id  IS NULL
      AND user_a_id IS NOT NULL
      AND user_b_id IS NOT NULL
      AND user_a_id < user_b_id)
  ),
  CONSTRAINT chats_disappear_range
    CHECK (disappear_seconds IS NULL OR disappear_seconds BETWEEN 5 AND 31536000)
);

CREATE UNIQUE INDEX chats_one_per_group ON chats (group_id) WHERE kind = 'group';
CREATE UNIQUE INDEX chats_one_per_pair  ON chats (user_a_id, user_b_id) WHERE kind = 'direct';

-- A message row carries routing metadata only. There is no body column: the
-- content lives in message_envelopes, encrypted separately for each recipient
-- device, and the server never holds a decryptable copy.
--
-- system_event is the one exception, and it is deliberate. System messages are
-- composed by the server (an administrator renamed someone, a device was
-- added), contain only facts the server already knows, and are what makes an
-- admin rename impossible to perform silently.
CREATE TABLE messages (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chat_id             uuid         NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  kind                message_kind NOT NULL DEFAULT 'user',
  sender_user_id      uuid         REFERENCES users(id)    ON DELETE RESTRICT,
  sender_device_id    uuid         REFERENCES devices(id)  ON DELETE RESTRICT,
  system_event        jsonb,
  reply_to_message_id uuid         REFERENCES messages(id) ON DELETE SET NULL,
  created_at          timestamptz  NOT NULL DEFAULT now(),
  edited_at           timestamptz,
  deleted_at          timestamptz,
  expires_at          timestamptz,
  CONSTRAINT messages_shape CHECK (
    (kind = 'user'
      AND sender_user_id   IS NOT NULL
      AND sender_device_id IS NOT NULL
      AND system_event     IS NULL)
    OR
    (kind = 'system'
      AND system_event IS NOT NULL)
  )
);

CREATE INDEX messages_chat_created ON messages (chat_id, created_at DESC);
CREATE INDEX messages_sender       ON messages (sender_user_id);
CREATE INDEX messages_expiring     ON messages (expires_at)
  WHERE expires_at IS NOT NULL AND deleted_at IS NULL;

-- One ciphertext per recipient device, as the Signal Protocol requires. The
-- server stores and forwards these blobs and can decrypt none of them.
CREATE TABLE message_envelopes (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id          uuid          NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  recipient_device_id uuid          NOT NULL REFERENCES devices(id)  ON DELETE CASCADE,
  envelope_kind       envelope_kind NOT NULL,
  ciphertext          bytea         NOT NULL,
  created_at          timestamptz   NOT NULL DEFAULT now(),
  delivered_at        timestamptz,
  read_at             timestamptz,
  CONSTRAINT message_envelopes_ciphertext_size
    CHECK (octet_length(ciphertext) BETWEEN 1 AND 262144),
  CONSTRAINT message_envelopes_read_after_delivery
    CHECK (read_at IS NULL OR delivered_at IS NOT NULL)
);

CREATE UNIQUE INDEX message_envelopes_one_per_device
  ON message_envelopes (message_id, recipient_device_id);
CREATE INDEX message_envelopes_pending
  ON message_envelopes (recipient_device_id, created_at) WHERE delivered_at IS NULL;

-- Deliberately minimal. No filename, no content type, no dimensions: those are
-- metadata, they live inside the encrypted message body, and the server has no
-- business knowing them. The decryption key for the blob is also carried in the
-- message body and is never stored here.
CREATE TABLE attachments (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id            uuid        NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  storage_key           text        NOT NULL UNIQUE,
  ciphertext_bytes      bigint      NOT NULL,
  ciphertext_sha256     bytea       NOT NULL,
  uploaded_by_device_id uuid        REFERENCES devices(id) ON DELETE RESTRICT,
  created_at            timestamptz NOT NULL DEFAULT now(),
  expires_at            timestamptz,
  CONSTRAINT attachments_sha_len CHECK (octet_length(ciphertext_sha256) = 32),
  CONSTRAINT attachments_size    CHECK (ciphertext_bytes > 0)
);

CREATE INDEX attachments_message  ON attachments (message_id);
CREATE INDEX attachments_expiring ON attachments (expires_at) WHERE expires_at IS NOT NULL;

-- Down Migration

DROP TABLE IF EXISTS attachments;
DROP TABLE IF EXISTS message_envelopes;
DROP TABLE IF EXISTS messages;
DROP TABLE IF EXISTS chats;
