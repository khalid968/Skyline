#!/bin/sh
# Fills every empty random secret in .env (copied from production.env.example).
# Run once on the server, before the first start. It never overwrites a value
# that is already set: changing AUTH_TOKEN_PEPPER later would sign every
# device out, and changing the database passwords would lock the API out.
set -eu
cd "$(dirname "$0")"
[ -f .env ] || cp production.env.example .env
chmod 600 .env
for name in POSTGRES_PASSWORD SKYLINE_APP_DB_PASSWORD REDIS_PASSWORD MINIO_ROOT_PASSWORD AUTH_TOKEN_PEPPER AUTH_TOTP_KEY TURN_SECRET; do
  if grep -q "^${name}=$" .env; then
    value=$(openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-48)
    sed -i "s|^${name}=$|${name}=${value}|" .env
    echo "set ${name}"
  fi
done
echo "Now edit .env: SKYLINE_DOMAIN, BACKUP_AGE_RECIPIENT, APP_MIN_VERSION (SKYLINE_ADMIN_EMAIL is optional)."
