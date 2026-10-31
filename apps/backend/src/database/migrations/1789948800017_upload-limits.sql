-- Up Migration

-- ---------------------------------------------------------------------------
-- Upload limits (owner decision 2026-10-31, security audit lead 7). Starting an
-- upload sums what the same person started in the last 24 hours, and the sweep
-- looks for uploads left idle. Both read these indexes; no data changes.
-- ---------------------------------------------------------------------------

CREATE INDEX attachments_uploader_recent ON attachments (uploaded_by_device_id, created_at);
CREATE INDEX attachments_uploading ON attachments (created_at) WHERE status = 'uploading';

-- Down Migration

DROP INDEX IF EXISTS attachments_uploading;
DROP INDEX IF EXISTS attachments_uploader_recent;
