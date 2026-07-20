# CLAUDE.md

Working memory for Claude Code sessions on Skyline — a privacy-first, invite-only, end-to-end-encrypted messaging platform for a private community. Flutter client (Android/iOS/Windows/macOS/Linux/Web) + NestJS backend + Rust crypto core.

## Current state

- **Phase 1 of 11 complete** (system architecture + scaffolding). **Phase 2 (Backend) is next.**
- Process: the project is built phase-by-phase per `docs/architecture/roadmap.md`. Never start a phase without the user's explicit approval. End every phase with: design decisions made, files created, remaining tasks — then stop and wait.
- Working branch: `claude/secure-messaging-platform-xd1bgh` (push with `git push -u origin <branch>`).

## Locked decisions — do not re-litigate

- **Backend is NestJS in plain JavaScript, NOT TypeScript** (explicit user decision). Babel handles decorators (`.babelrc`); generate code with `npx @nestjs/cli g <schematic> --language JavaScript` semantics (nest-cli.json already sets `"language": "js"`).
- **PostgreSQL** is the system of record. Redis = WebSocket fan-out, presence, rate limiting only. MinIO = encrypted media blobs.
- **E2EE = Signal Protocol via the official `libsignal-client` Rust crate**, exposed to Flutter through `flutter_rust_bridge` from `crypto-core/`. Never write custom cryptography — protocol or primitives. The Web/WASM gap is a known open risk (`docs/architecture/known-risks.md`), resolved by a spike at the start of Phase 5.
- **Riverpod** for state management; providers are also the DI mechanism (no get_it). **go_router** for navigation. **Material 3** with light+dark from `ColorScheme.fromSeed` (`apps/mobile/lib/core/theme/app_theme.dart`).
- **Native WebSocket** (`@nestjs/platform-ws` + `ws`), not Socket.IO.
- **Single-host Docker Compose** deployment target; keep backend stateless (shared state in Redis/Postgres) so it stays horizontally extractable.
- The server only ever handles ciphertext + minimal metadata. Private keys never leave the device. No analytics, telemetry, or third-party trackers — ever.

## Layout

```
apps/mobile/     Flutter client — feature-first Clean Architecture (lib/features/<name>/{data,domain,presentation})
apps/backend/    NestJS (JS) — src/modules/{auth,users,devices,chats,messages,groups,media,notifications,admin,websocket}
crypto-core/     Rust workspace; core/ crate is empty until Phase 5
infra/docker/    Dev docker-compose.yml (Postgres, Redis, MinIO)
docs/            architecture/ (overview, tech-stack-decisions, folder-structure, roadmap, known-risks), api/, database/, security/, deployment/
```

Client conventions: dependencies point inward (`presentation` → `domain` ← `data`); backend module names mirror client feature names. Details: `docs/architecture/folder-structure.md`, `apps/mobile/lib/features/README.md`.

## Commands

```bash
# Backend (apps/backend)
npm install
cp .env.example .env       # .env is gitignored; never commit real secrets
npm run start:dev          # nodemon watch mode; npm run start for single run
npm test                   # Jest unit; npm run test:e2e for e2e

# Dev data plane (repo root)
docker compose -f infra/docker/docker-compose.yml up -d

# Crypto core (crypto-core/)
cargo build

# Flutter client (apps/mobile) — requires one-time platform bootstrap on a machine with the Flutter SDK:
#   flutter create --platforms=android,ios,windows,macos,linux,web --org com.skyline --project-name skyline .
# then: flutter pub get && flutter analyze   (see apps/mobile/README.md)
```

## Remote sandbox caveats

- **No Flutter SDK** installed — `apps/mobile` has no SDK-generated platform runner folders; they're gitignored and bootstrapped locally (see above).
- **No runnable Docker daemon** — validate compose changes with `docker compose config`; live-test on a real machine.
- Backend boot can be smoke-tested directly: `npm run start` comes up with no external services required (DB/Redis wiring lands in Phase 2/3).
