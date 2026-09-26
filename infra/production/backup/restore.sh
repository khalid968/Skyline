#!/bin/sh
# Restores one backup into an EMPTY database and media store. Run from the
# backup container with the owner's age PRIVATE key mounted read-only, e.g.
#   docker compose run --rm -v ~/skyline-backup.key:/key:ro backup \
#     /usr/local/bin/restore.sh /backups/latest /key
# It refuses a database that already has tables: restoring over live data
# would mix two histories.
set -eu
SRC=${1:?backup directory, e.g. /backups/latest}
KEY=${2:?path to the owner age private key}
cd "$SRC"
sha256sum -c SHA256SUMS
export PGPASSWORD="$POSTGRES_PASSWORD"
tables=$(psql -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
if [ "$tables" != "0" ]; then
  echo "refusing: the database already has $tables tables (restore into an empty one)" >&2
  exit 1
fi
age -d -i "$KEY" database.dump.age \
  | pg_restore -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --role="$POSTGRES_USER"
# pg_restore recreates the owner's objects; the app role keeps its grants
# through the default privileges set at first start (postgres/10-app-role.sh).
psql -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
  "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO skyline_app;
   GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO skyline_app;"
age -d -i "$KEY" media.tar.age | tar -C /media-data -xf -
echo "restored $(basename "$(readlink -f "$SRC")")"
