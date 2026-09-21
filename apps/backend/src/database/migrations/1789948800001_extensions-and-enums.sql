-- Up Migration

-- gen_random_uuid() for primary keys; citext for case-insensitive usernames.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

CREATE TYPE user_status      AS ENUM ('pending', 'active', 'suspended', 'deleted');
CREATE TYPE device_platform  AS ENUM ('ios', 'android', 'windows', 'macos', 'linux');
CREATE TYPE push_provider    AS ENUM ('apns', 'fcm', 'wns');
CREATE TYPE chat_kind        AS ENUM ('direct', 'group');
CREATE TYPE message_kind     AS ENUM ('user', 'system');
CREATE TYPE envelope_kind    AS ENUM ('prekey', 'whisper');

-- Shared updated_at trigger.
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Down Migration

DROP FUNCTION IF EXISTS set_updated_at();
DROP TYPE IF EXISTS envelope_kind;
DROP TYPE IF EXISTS message_kind;
DROP TYPE IF EXISTS chat_kind;
DROP TYPE IF EXISTS push_provider;
DROP TYPE IF EXISTS device_platform;
DROP TYPE IF EXISTS user_status;
