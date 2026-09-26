#!/bin/sh
# Run on YOUR computer, not the server: builds Skyline's images here and sends
# them, with this checkout's code, to a small server that shouldn't build them
# itself (one CPU, 2 GB). Then deploys there.
#   ./ship.sh root@chat.example.org            code + images, then deploy
#   ./ship.sh root@chat.example.org --no-deploy
# On Windows, set SSH to Windows' own ssh so the ssh-agent key is used:
#   SSH=/c/Windows/System32/OpenSSH/ssh.exe ./ship.sh root@...
# The server's folder is /opt/skyline; its .env and secrets/ are never touched.
set -eu
cd "$(dirname "$0")"
host=${1:?usage: ship.sh user@server [--no-deploy]}
ssh=${SSH:-ssh}
dir=/opt/skyline
repo=$(git rev-parse --show-toplevel)
sha=$(git rev-parse --short HEAD)
[ -z "$(git status --porcelain)" ] || echo "note: uncommitted changes are NOT shipped (only commit $sha)"

echo "== building the images here ($sha)"
# Compose checks every setting even to build; these placeholders never leave
# this computer and are not in the images.
tmp=.ship-build.env   # here, not mktemp: Docker on Windows can't see Git Bash's /tmp
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<EOF
SKYLINE_DOMAIN=build.invalid
SKYLINE_ADMIN_EMAIL=build@build.invalid
SKYLINE_REGISTRY=skyline
SKYLINE_VERSION=local
SKYLINE_GIT_SHA=$sha
POSTGRES_PASSWORD=build
SKYLINE_APP_DB_PASSWORD=build
REDIS_PASSWORD=build
MINIO_ROOT_USER=build
MINIO_ROOT_PASSWORD=build
AUTH_TOKEN_PEPPER=build
AUTH_TOTP_KEY=build
TURN_SECRET=build
BACKUP_AGE_RECIPIENT=build
EOF
docker compose --env-file "$tmp" build

echo "== sending the code"
(cd "$repo" && git archive --format=tar HEAD) \
  | "$ssh" "$host" "mkdir -p $dir && tar -x -C $dir --exclude=infra/production/.env && echo $sha > $dir/REVISION"

echo "== sending the images (a few minutes)"
docker save skyline/backend:local skyline/web:local skyline/backup:local skyline/minio:2025-09-07 \
  | gzip -1 | "$ssh" "$host" "gunzip | docker load"

if [ "${2:-}" != "--no-deploy" ]; then
  "$ssh" "$host" "cd $dir/infra/production && ./deploy.sh --no-build"
fi
