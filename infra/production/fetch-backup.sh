#!/bin/sh
# Run on YOUR OWN computer, not the server: copies the newest backup off the
# server, so a lost server does not take its backups with it (known-risks.md,
# "Backups live on the same server").
#   ./fetch-backup.sh <user@server> [folder on the server, default ~/skyline]
# It arrives still encrypted to your age key, with its checksums checked.
# On Windows, use Windows' ssh so the ssh-agent key works:
#   SSH=/c/Windows/System32/OpenSSH/ssh.exe ./fetch-backup.sh root@server /opt/skyline
set -eu
host=${1:?usage: fetch-backup.sh user@server [path to the Skyline checkout]}
dir=${2:-skyline}
out="skyline-backup-$(date -u +%Y-%m-%d)"
mkdir -p "$out"
"${SSH:-ssh}" "$host" "cd '$dir/infra/production' && docker compose run --rm --no-deps -T --entrypoint tar backup -C /backups/latest -chf - ." \
  | tar -C "$out" -xf -
(cd "$out" && sha256sum -c SHA256SUMS)
echo "Saved to $out/ (encrypted; restoring needs your age private key)."
