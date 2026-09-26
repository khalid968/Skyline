# The Skyline API, for production (infra/production). Compiled at build time
# (no Babel at runtime), dev dependencies dropped, run as the unprivileged
# `node` user under tini. Migrations ship inside the image and are run by the
# separate `migrate` service with the database OWNER role; the running API
# uses a role that owns nothing (docs/deployment).
FROM node:24-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
# argon2 is native: its install script fetches (or builds) the binary.
RUN npm ci
COPY babel.config.js ./
COPY src ./src
RUN npx babel src -d dist --copy-files && npm prune --omit=dev

FROM node:24-bookworm-slim
ENV NODE_ENV=production
RUN apt-get update && apt-get install -y --no-install-recommends tini && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
ARG GIT_SHA=unknown
ENV GIT_SHA=$GIT_SHA
USER node
EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=5s --retries=5 \
  CMD node -e "fetch('http://127.0.0.1:3000/health/ready').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "dist/main.js"]
