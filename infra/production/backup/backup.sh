#!/bin/sh
# Nightly encrypted backups (owner decision 2026-09-26: kept on this server,
# 30 days; known-risks.md). Everything is encrypted with `age` to the owner's
# PUBLIC key (BACKUP_AGE_RECIPIENT); the private key never lives on the
# server, so a stolen backup is unreadable and restoring needs the owner.
#
#   backup.sh            loop: one backup a night at BACKUP_HOUR (UTC)
#   backup.sh --now      one backup now, then exit
set -eu
DIR=/backups
KEEP_DAYS=${BACKUP_KEEP_DAYS:-30}
: "${BACKUP_AGE_RECIPIENT:?set BACKUP_AGE_RECIPIENT to the owner's age public key}"

one() {
  stamp=$(date -u +%Y-%m-%dT%H%M%SZ)
  tmp="$DIR/.partial-$stamp"
  mkdir -p "$tmp"
  # The database: a consistent snapshot while the server keeps running.
  PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc \
    | age -r "$BACKUP_AGE_RECIPIENT" > "$tmp/database.dump.age"
  # Media: already encrypted on the phones; encrypted again as one archive.
  tar -C /media-data -cf - . | age -r "$BACKUP_AGE_RECIPIENT" > "$tmp/media.tar.age"
  ( cd "$tmp" && sha256sum database.dump.age media.tar.age > SHA256SUMS )
  mv "$tmp" "$DIR/$stamp"
  ln -sfn "$stamp" "$DIR/latest"
  find "$DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' -mtime +"$KEEP_DAYS" -exec rm -rf {} +
  echo "backup $stamp done: $(du -sh "$DIR/$stamp" | cut -f1)"
}

if [ "${1:-}" = "--now" ]; then one; exit 0; fi

HOUR=${BACKUP_HOUR:-3}
while true; do
  now=$(date -u +%s)
  next=$(date -u -d "$(date -u +%Y-%m-%d) ${HOUR}:00:00" +%s 2>/dev/null || echo 0)
  [ "$next" -le "$now" ] && next=$((next + 86400))
  sleep $((next - now))
  one || echo "backup FAILED at $(date -u)" >&2
done
