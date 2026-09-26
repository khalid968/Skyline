#!/bin/sh
# Runs once, when the database volume is first created (docker-entrypoint-initdb.d).
#
# Two roles (threat model A5):
#   $POSTGRES_USER   owns the schema; used ONLY by the `migrate` service.
#   skyline_app      what the running API connects as. It can read and write
#                    rows but owns nothing, so it cannot drop tables, alter
#                    them, or disable the triggers that keep the audit log
#                    append-only and the owner account protected. It gets no
#                    TRUNCATE (which bypasses row triggers).
set -eu
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
CREATE ROLE skyline_app LOGIN PASSWORD '${SKYLINE_APP_DB_PASSWORD}';
REVOKE ALL ON DATABASE "${POSTGRES_DB}" FROM PUBLIC;
GRANT CONNECT ON DATABASE "${POSTGRES_DB}" TO skyline_app;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO skyline_app;
-- Whatever the owner creates from now on (every migration):
ALTER DEFAULT PRIVILEGES FOR ROLE "${POSTGRES_USER}" IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO skyline_app;
ALTER DEFAULT PRIVILEGES FOR ROLE "${POSTGRES_USER}" IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO skyline_app;
ALTER DEFAULT PRIVILEGES FOR ROLE "${POSTGRES_USER}" IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO skyline_app;
SQL
