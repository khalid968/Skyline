# The public front door (build context: the repository root):
#   /            the download page (board 41, apps/download)
#   /admin/      the dashboard, built for that path
#   /api/        the API and its WebSocket, proxied to the backend
#   /downloads/  release files and manifest (a volume the release step fills)
# TLS from Let's Encrypt (the certbot service), with a self-signed stand-in
# until the real certificate exists, so Nginx can always start.
FROM node:24-bookworm-slim AS dashboard
WORKDIR /src
COPY apps/dashboard/package.json apps/dashboard/package-lock.json ./
RUN npm ci
COPY apps/dashboard/ ./
RUN DASHBOARD_BASE=/admin/ npm run build

FROM nginx:1.27-alpine
RUN apk add --no-cache openssl
COPY --from=dashboard /src/dist /srv/dashboard
COPY apps/download/ /srv/download/
COPY apps/dashboard/public/fonts /srv/download/fonts
COPY apps/dashboard/public/favicon.svg /srv/download/favicon.svg
COPY infra/production/web/nginx.conf.template /etc/nginx/templates/default.conf.template
COPY infra/production/web/tls.sh /docker-entrypoint.d/40-skyline-tls.sh
RUN chmod +x /docker-entrypoint.d/40-skyline-tls.sh && rm -f /etc/nginx/conf.d/default.conf
