#!/bin/sh
# Deploys (or updates) Skyline on this server:
#   ./deploy.sh              build the images here from this checkout
#   ./deploy.sh --no-build   use the images already here (sent by ship.sh)
#   ./deploy.sh 1.1.0        pull that version from SKYLINE_REGISTRY instead
# Steps: images, database migrations (owner role), restart, health check.
# If the new API does not become healthy, the previous version is started
# again; the migration is not undone (migrations only ever add), so a
# rollback runs the old code on the new schema, which the migration rules
# keep compatible.
set -eu
cd "$(dirname "$0")"
[ -f .env ] || { echo "no .env here: copy production.env.example and run generate-secrets.sh" >&2; exit 1; }

set -a; . ./.env; set +a
previous=${SKYLINE_VERSION:-local}
target=${1:-local}

if [ "$target" = "--no-build" ]; then
  target=local
  for image in backend web backup; do
    docker image inspect "${SKYLINE_REGISTRY:-skyline}/$image:local" >/dev/null || { echo "no ${SKYLINE_REGISTRY:-skyline}/$image:local here: run ship.sh first" >&2; exit 1; }
  done
elif [ "$target" = "local" ]; then
  SKYLINE_GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo unknown) \
  SKYLINE_VERSION=local docker compose build
else
  SKYLINE_VERSION=$target docker compose pull backend web backup
fi
export SKYLINE_VERSION=$target

echo "== migrating the database"
docker compose run --rm migrate

echo "== starting $target"
docker compose up -d --remove-orphans

echo "== waiting for the API"
for i in $(seq 1 60); do
  if docker compose exec -T backend node -e "fetch('http://127.0.0.1:3000/health/ready').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"; then
    sed -i "s|^SKYLINE_VERSION=.*|SKYLINE_VERSION=${target}|" .env
    echo "Skyline $target is up: https://${SKYLINE_DOMAIN}/"
    exit 0
  fi
  sleep 2
done

echo "!! $target did not become healthy; going back to $previous" >&2
SKYLINE_VERSION=$previous docker compose up -d --remove-orphans
exit 1
