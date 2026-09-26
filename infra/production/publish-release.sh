#!/bin/sh
# Puts a new app version on this server (boards 41-42):
#   ./publish-release.sh <folder>                     the files of a GitHub release
#   ./publish-release.sh <folder> --minimum 1.2.0     ...and stop older apps working
# <folder> holds what the release workflow drafted: manifest.json, SHA256SUMS
# and the APK and/or Windows installer. Every file is checked against
# SHA256SUMS before anything changes; then the files go into the releases
# volume, where the download page and GET /app/releases find them at once.
#
# --minimum raises APP_MIN_VERSION in .env and restarts the API: apps older
# than that get "Please update" and can no longer send or receive. Use it only
# for a security fix, and only once the new version is downloadable.
set -eu
cd "$(dirname "$0")"
[ $# -ge 1 ] || { sed -n '2,12p' "$0"; exit 2; }
[ -f .env ] || { echo "no .env here: this is not a deployed Skyline folder" >&2; exit 1; }
src=$(cd "$1" && pwd)
minimum=
if [ "${2:-}" = "--minimum" ]; then
  minimum=${3:?--minimum needs a version such as 1.2.0}
  echo "$minimum" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "not a version: $minimum" >&2; exit 2; }
fi

[ -f "$src/manifest.json" ] || { echo "no manifest.json in $src" >&2; exit 1; }
[ -f "$src/SHA256SUMS" ] || { echo "no SHA256SUMS in $src" >&2; exit 1; }
echo "== checking checksums"
(cd "$src" && sha256sum -c SHA256SUMS)

project=${COMPOSE_PROJECT_NAME:-skyline}
volume=$(docker volume ls -q --filter "label=com.docker.compose.project=$project" \
  --filter label=com.docker.compose.volume=releases)
[ -n "$volume" ] || { echo "no releases volume for project $project: run ./deploy.sh first" >&2; exit 1; }

# Files first, manifest last: nobody is pointed at a file that is not there yet.
# The previous versions stay, so an app mid-download is not cut off.
echo "== publishing to $volume"
docker run --rm -v "$volume:/out" -v "$src:/in:ro" --entrypoint sh nginx:1.27-alpine -c '
  set -e
  for f in /in/*.apk /in/*.exe /in/SHA256SUMS; do [ -f "$f" ] && cp "$f" /out/; done
  cp /in/manifest.json /out/manifest.json.new && mv /out/manifest.json.new /out/manifest.json
  chmod 644 /out/*
  ls -l /out'

if [ -n "$minimum" ]; then
  echo "== raising the minimum app version to $minimum"
  if grep -q '^APP_MIN_VERSION=' .env; then
    sed -i "s|^APP_MIN_VERSION=.*|APP_MIN_VERSION=$minimum|" .env
  else
    echo "APP_MIN_VERSION=$minimum" >> .env
  fi
  docker compose up -d backend
fi
echo "Done. Check https://$(sed -n 's/^SKYLINE_DOMAIN=//p' .env)/ shows the new version."
