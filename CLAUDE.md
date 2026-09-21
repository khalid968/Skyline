# CLAUDE.md

Working memory for Claude Code sessions on Skyline — a privacy-first, invite-only, end-to-end-encrypted
messaging platform for a closed community. Flutter client (iOS/Android/Windows) + NestJS backend +
Rust crypto core + a separate web admin dashboard.

**Read `docs/progress-log.md` after this file.** It is the append-only session handoff record and holds
the current state of play.

## Current state

- **Phase 2 (Product design) — ✅ approved 2026-09-20.**
- **Phase 3 (Database & contact graph) — ✅ verified 2026-09-21** against a live PostgreSQL 16: applies,
  rolls back clean, re-applies, and 75 tests pass (`npm run test:db`). It found and fixed one real bug
  (`TRUNCATE` bypassed the append-only audit log). See `docs/database/schema.md`.
- **Phase 4 (Backend foundation + `ContactGraphGuard`) is next.** The owner chose SQL-backed graph
  checks (call `visible_user_ids()` / `are_linked()` per request; no Redis cache of the visible set).
- **⚠️ OPEN OWNER DECISION — admin access to message content.** The owner asked (2026-09-21) for admins
  to "view all messages and media". That contradicts the locked rule below. **Do not implement it, and do
  not quietly refuse it either: it is pending the owner's answer.** See `decisions.md`.
- Process: built phase-by-phase per `docs/architecture/roadmap.md`. **Never start a phase without the
  owner's explicit approval.** End every phase with: decisions made, files changed, what remains — then
  stop and wait.
- **Never code a user-visible surface before its prototype is approved** (`docs/architecture/design.md`).
- Append a session entry to `docs/progress-log.md` before finishing. Append decisions to
  `docs/architecture/decisions.md`. Do not rewrite either file's history.

## The rule that defines this product

**A user sees and can message exactly the people and groups an administrator has linked to them, and
nothing else — no search, no directory, no discovery, no user-created groups.** This is an authorization
invariant, not a setting. Full spec, schema and enforcement rules: `docs/architecture/contact-graph.md`.

Default deny. Return **404, not 403**, for anything outside a caller's graph — a 403 confirms the target
exists and leaks the directory the whole design exists to hide.

## Locked decisions — do not re-litigate

Rationale for each is in `docs/architecture/decisions.md`.

- **v1 platforms: iOS, Android, Windows.** The **Web messaging client is out of scope** — no official
  WASM build of `libsignal-client` exists and every alternative is unaudited. macOS/Linux are cheap
  follow-ons but unpromised.
- **Admin tooling is a separate web app**, not in-app screens. (`apps/mobile/lib/features/admin/` is
  leftover Phase 1 scaffolding and contradicts this — remove it in Phase 6.) The dashboard never holds
  message keys or plaintext, so the WASM problem does not apply to it.
- **Admins can grant/revoke contacts and suspend accounts. Admins can never read messages.** Any request
  that would give them plaintext breaks the product's core promise — escalate to the owner, never
  quietly implement.
- **Activation codes are strictly single use.** Store a hash, never the code. Redeem via one atomic
  conditional `UPDATE` + a unique partial index — **never check-then-write**, which races. Spent,
  expired and nonexistent codes fail identically, timing included.
- **Admins can rename any user, but a rename is audit-logged, announced as a system message in every
  affected conversation, and never touches identity keys** (verified safety numbers stay valid). Those
  three constraints are what stop an admin renaming one user to another's name to impersonate them —
  do not drop them for convenience. Released usernames are never reissued.
- **Nothing is hard-deleted.** Accounts are soft-deleted (`status='deleted'`); devices, sessions,
  links and memberships are revoked. `DELETE FROM users` fails by design (`username_history` is
  `ON DELETE RESTRICT`) — that is what keeps burned usernames burned.
- **Migrations are plain SQL via `node-pg-migrate`, no ORM.** The security properties live in partial
  indexes, CHECK constraints and triggers; keep them readable. Redeem codes only through
  `redeem_activation_code()`, and build authorization on `are_linked()` / `visible_user_ids()`.
- **Backend is NestJS in plain JavaScript, NOT TypeScript.** Babel handles decorators (`.babelrc`);
  `nest-cli.json` sets `"language": "js"`.
- **PostgreSQL** is the system of record. Redis = WebSocket fan-out, presence, rate limiting only.
  MinIO = encrypted media blobs.
- **E2EE = Signal Protocol via the official `libsignal-client` Rust crate**, exposed to Flutter through
  `flutter_rust_bridge` from `crypto-core/`. **Never write custom cryptography — protocol or
  primitives.**
- **Riverpod** for state (providers are also DI; no get_it). **go_router** for navigation.
  **Material 3**, themed from the explicit tokens in `docs/architecture/design.md` — replace the
  `ColorScheme.fromSeed` placeholder in `apps/mobile/lib/core/theme/app_theme.dart`; a seed palette will
  not reproduce them and the security colours must be exact.
- **Native WebSocket** (`@nestjs/platform-ws` + `ws`), not Socket.IO.
- **Single-host Docker Compose** target; backend stays stateless (shared state in Redis/Postgres).
- Server handles only ciphertext + minimal routing metadata. Private keys never leave the device. No
  analytics, telemetry or third-party trackers — ever.

## Layout

```
apps/mobile/     Flutter client — feature-first Clean Architecture (lib/features/<name>/{data,domain,presentation})
apps/backend/    NestJS (JS) — src/modules/{auth,users,devices,chats,messages,groups,media,notifications,admin,websocket}
apps/dashboard/  Admin web app — does not exist yet; created in Phase 6
crypto-core/     Rust workspace; core/ crate is empty until Phase 7
infra/docker/    Dev docker-compose.yml (Postgres, Redis, MinIO)
docs/            progress-log.md + architecture/ (overview, decisions, design, contact-graph, roadmap,
                 known-risks, tech-stack-decisions, folder-structure), api/, database/, security/, deployment/
```

Client conventions: dependencies point inward (`presentation` → `domain` ← `data`); backend module names
mirror client feature names. Details: `docs/architecture/folder-structure.md`.

## Architecture at a glance

Message send flow (full diagram in `docs/architecture/overview.md`): client encrypts locally via the
recipient's Double Ratchet session (X3DH on first contact) → sends ciphertext + minimal routing metadata
(sender device ID, recipient ID, timestamp, message ID) over TLS (Nginx) to REST/WebSocket → backend
**checks the contact graph**, then persists ciphertext+metadata in Postgres and publishes a delivery
event on Redis pub/sub → fans out over WebSocket to the recipient's connected devices (or queues for
offline delivery) → recipient decrypts locally. The server never holds a decryptable copy. Redis pub/sub
is what lets the gateway fan out across multiple backend instances once scaled past one process — hence
the stateless-backend rule above.

## Commands

```bash
# Backend (apps/backend)
npm install
cp .env.example .env       # .env is gitignored; never commit real secrets
npm run start:dev          # nodemon watch; npm run start for a single run (babel-node)
npm test                   # Jest unit; npm run test:e2e; npm run test:cov
npx jest src/app.controller.spec.js   # single file
npx jest -t "test name"               # single test
npm run format             # prettier --write "**/*.js"

# Migrations (apps/backend) — plain SQL via node-pg-migrate; needs DATABASE_URL in .env
npm run migrate:up                       # apply; migrate:down rolls back one; migrate:redo redoes the last
npm run test:db                          # 75 schema-invariant tests against a throwaway database
npm run migrate:create -- add-something  # scaffold a new .sql migration

# Dev data plane (repo root) — Docker Desktop must be running
docker compose -f infra/docker/docker-compose.yml up -d   # Postgres, Redis, MinIO

# Crypto core (crypto-core/) — needs Rust, not yet installed
cargo build && cargo test

# Flutter client (apps/mobile) — one-time platform bootstrap, note: no web
#   flutter create --platforms=android,ios,windows --org com.skyline --project-name skyline .
flutter pub get && flutter analyze && flutter test
```

## Local toolchain (owner's Windows 11 machine)

| Tool | State |
| --- | --- |
| Flutter 3.35.7 / Dart 3.9.2 | ✅ installed |
| Node 24.19 / npm 11.17 | ✅ installed |
| Rust / cargo | ❌ **not installed** — blocking from Phase 7 |
| Docker Desktop 29.8 (WSL2) | ✅ installed and working; dev stack verified |

`apps/mobile` has no SDK-generated platform runner folders yet (gitignored; see bootstrap above).
Backend boot can be smoke-tested with `npm run start` — no external services required until Phase 3.
