# Skyline

Secure messaging, built for people you trust.

Skyline is a privacy-first, admin-provisioned messaging platform for a closed community, built with end-to-end encryption as a non-negotiable foundation rather than a bolt-on feature. It targets iOS, Android and Windows from a single Flutter codebase, backed by a NestJS API and a separate web admin dashboard.

What makes it different from Signal or WhatsApp: **there is no discovery.** A user sees and can message exactly the people and groups an administrator has linked to them — no search, no directory, no user-created groups. See [the contact graph](docs/architecture/contact-graph.md).

## Status

**Phase 4 of 13 — Backend foundation and authorization core (built, awaiting review).** See [`docs/architecture/roadmap.md`](docs/architecture/roadmap.md) for the full phase plan and [`docs/progress-log.md`](docs/progress-log.md) for the current state of play. No feature logic exists yet — scaffolding, architecture and design only.

## Documentation

- [Progress log](docs/progress-log.md) — start here
- [Decision log](docs/architecture/decisions.md)
- [The contact graph](docs/architecture/contact-graph.md)
- [Authorization — read before writing a controller](docs/security/authorization.md)
- [Design system & review process](docs/architecture/design.md)
- [Architecture overview](docs/architecture/overview.md)
- [Tech stack decisions](docs/architecture/tech-stack-decisions.md)
- [Folder structure](docs/architecture/folder-structure.md)
- [Roadmap](docs/architecture/roadmap.md)
- [Known risks](docs/architecture/known-risks.md)

## Stack

- **Client**: Flutter, Riverpod, Material 3, Clean Architecture (feature-first)
- **Backend**: NestJS (JavaScript), REST + WebSocket
- **Admin dashboard**: separate web app — manages identities and permissions, never holds keys or plaintext
- **Data**: PostgreSQL, Redis, MinIO (S3-compatible object storage)
- **Encryption**: Signal Protocol via `libsignal-client`, wrapped for Flutter with a Rust `crypto-core` and `flutter_rust_bridge`
- **Infra**: Docker Compose, Nginx

## Repository layout

```
apps/mobile/     Flutter client (iOS, Android, Windows)
apps/backend/    NestJS API server
apps/dashboard/  Admin web app (created in Phase 6)
crypto-core/     Rust workspace wrapping libsignal-client
infra/           Docker Compose, reverse proxy, CI
docs/            Progress log, architecture, API, database, security, deployment docs
```

See [`docs/architecture/folder-structure.md`](docs/architecture/folder-structure.md) for the full annotated layout.

## Local development

**Backend**

```
cd apps/backend
npm install
cp .env.example .env
npm run start:dev
```

**Dev data plane** (Postgres, Redis, MinIO)

```
docker compose -f infra/docker/docker-compose.yml up -d
```

**Mobile client** — requires a one-time platform bootstrap first; see [`apps/mobile/README.md`](apps/mobile/README.md).

**Crypto core**

```
cd crypto-core
cargo build
```

## Security

No public registration — accounts exist only when an administrator creates them, and are activated with a single-use code. Private key material is generated and stored exclusively on-device and never transmitted to or held by the server.

Administrators control **who may talk to whom**. Administrators **cannot read messages** — they never hold the keys, and no dashboard or API path exposes plaintext. Any feature request that would change that breaks the product's core promise.

See [`docs/architecture/known-risks.md`](docs/architecture/known-risks.md) for currently open architectural risks.
