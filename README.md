# Skyline

Secure messaging, built for people you trust.

Skyline is a privacy-first, invite-only messaging platform for a private community, built with end-to-end encryption as a non-negotiable foundation rather than a bolt-on feature. It targets Android, iOS, Windows, macOS, Linux, and Web from a single Flutter codebase, backed by a NestJS API.

## Status

**Phase 1 of 11 — System Architecture.** See [`docs/architecture/roadmap.md`](docs/architecture/roadmap.md) for the full phase plan. No feature logic exists yet — this phase is architecture, tech stack decisions, and project scaffolding only.

## Documentation

- [Architecture overview](docs/architecture/overview.md)
- [Tech stack decisions](docs/architecture/tech-stack-decisions.md)
- [Folder structure](docs/architecture/folder-structure.md)
- [Roadmap](docs/architecture/roadmap.md)
- [Known risks](docs/architecture/known-risks.md)

## Stack

- **Client**: Flutter, Riverpod, Material 3, Clean Architecture (feature-first)
- **Backend**: NestJS (JavaScript), REST + WebSocket
- **Data**: PostgreSQL, Redis, MinIO (S3-compatible object storage)
- **Encryption**: Signal Protocol via `libsignal-client`, wrapped for Flutter with a Rust `crypto-core` and `flutter_rust_bridge`
- **Infra**: Docker Compose, Nginx

## Repository layout

```
apps/mobile/     Flutter client (all 6 platforms)
apps/backend/    NestJS API server
crypto-core/     Rust workspace wrapping libsignal-client
infra/           Docker Compose, reverse proxy, CI
docs/            Architecture, API, database, security, deployment docs
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

No public registration — accounts are invite-only, issued by administrators. Private key material is generated and stored exclusively on-device and never transmitted to or held by the server. See `docs/architecture/known-risks.md` for currently open architectural risks.
