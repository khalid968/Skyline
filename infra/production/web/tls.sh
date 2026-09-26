#!/bin/sh
# Runs when the Nginx container starts (nginx image entrypoint hook).
# Nginx always reads /etc/nginx/tls/{fullchain,privkey}.pem:
#   - Let's Encrypt's certificate when the certbot service has one;
#   - otherwise a self-signed stand-in, so Nginx starts and can answer the
#     certbot challenge (and so the local dress rehearsal works).
# A background loop checks every 5 minutes (a file comparison) and reloads
# when certbot has a new certificate: the first one is live within minutes.
set -eu
TLS=/etc/nginx/tls
LIVE="/etc/letsencrypt/live/${SKYLINE_DOMAIN}"
mkdir -p "$TLS"

install_cert() {
  if [ -f "$LIVE/fullchain.pem" ] && [ -f "$LIVE/privkey.pem" ]; then
    if ! cmp -s "$LIVE/fullchain.pem" "$TLS/fullchain.pem" 2>/dev/null; then
      cp "$LIVE/fullchain.pem" "$TLS/fullchain.pem"
      cp "$LIVE/privkey.pem" "$TLS/privkey.pem"
      chmod 600 "$TLS/privkey.pem"
      return 0
    fi
    return 1
  fi
  if [ ! -f "$TLS/fullchain.pem" ]; then
    echo "skyline-tls: no certificate yet for ${SKYLINE_DOMAIN}; using a self-signed stand-in"
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
      -subj "/CN=${SKYLINE_DOMAIN}" -addext "subjectAltName=DNS:${SKYLINE_DOMAIN}" \
      -keyout "$TLS/privkey.pem" -out "$TLS/fullchain.pem" 2>/dev/null
    chmod 600 "$TLS/privkey.pem"
  fi
  return 1
}

install_cert || true
(
  while sleep 300; do
    if install_cert; then nginx -s reload; fi
  done
) &
