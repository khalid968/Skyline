# Skyline — Backend

NestJS (JavaScript) API server. REST + WebSocket, PostgreSQL + Redis + MinIO. See [`docs/architecture/overview.md`](../../docs/architecture/overview.md) for how this fits into the wider system, and [`docs/architecture/tech-stack-decisions.md`](../../docs/architecture/tech-stack-decisions.md) for why these choices were made.

## Setup

```bash
npm install
cp .env.example .env
```

Bring up the dev data plane (Postgres, Redis, MinIO) from the repo root:

```bash
docker compose -f infra/docker/docker-compose.yml up -d
```

## Running

```bash
npm run start        # single run
npm run start:dev    # watch mode
```

## Testing

```bash
npm run test
npm run test:e2e
npm run test:cov
```

## Structure

- `src/modules/` — one module per bounded context: `auth`, `users`, `devices`, `chats`, `messages`, `groups`, `media`, `notifications`, `admin`, `websocket`. Empty scaffolds as of Phase 1; business logic is added module-by-module in later phases.
- `src/common/` — cross-cutting guards, interceptors, filters, decorators, pipes.
- `src/config/` — environment-driven runtime configuration (`configuration.js`).
- `src/database/` — migrations and schema (Phase 3).
