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
- **Phase 4 (Backend foundation + authorization core) — ✅ built 2026-09-21**, awaiting the owner's
  review. Config validation, redacted JSON logging, uniform error filter, strict validation, health
  checks, the three global guards, the audit service, and the WebSocket gateway with Redis fan-out.
  243 tests pass (71 unit, 75 db, 97 app), and the core protections were mutation-tested. **Read
  `docs/security/authorization.md` before writing any controller.** Rate limiting was NOT built; it moves
  to Phase 5.
- **Phase 5 (Authentication & invites) — ✅ built 2026-09-23**, awaiting the owner's review. Device
  activation with Ed25519 keys, rotating signed refresh tokens, admin password sign-in with optional TOTP,
  session kinds enforced, rate limiting (fails closed), `admin:create` / `user:invite` / `dev:device` tools.
  344 tests pass; 8 more mutation checks caught. Owner's manual test: `docs/try-it-yourself.md`.
- **Phase 6 (Admin dashboard v1) — ✅ built 2026-09-23**, awaiting the owner's review. `apps/dashboard`
  (React 19 + Vite, plain JS): users & activation codes, contact-graph editor, devices, sign-in with
  optional 2FA, account page. Backend: `modules/admin/`, migration 010 (protected **owner**,
  `must_change_password`). Session = HttpOnly cookie + CSRF header rule, same-origin via `/api` proxy, **no
  CORS**. 387 backend + 18 dashboard tests pass. Groups & audit viewer are v2 (Phase 11).
- **Phase 7 (Encryption) — ✅ built 2026-09-24**, awaiting the owner's review.
  - `crypto-core/core`: libsignal v0.103.1 plus an encrypted SQLite key vault. Every device has its own
    identity, and identity trust is strict.
  - Backend: migration 011 (the key directory) and activation v2.
  - `crypto-core/ffi`, `apps/mobile/rust_builder` (cargokit) and `lib/core/crypto/`.
  - Proven end to end: real devices against the real backend (`crypto-e2e`), and in the app on Windows and
    Android (`integration_test/crypto_test.dart`). iOS is untested (no Mac).
  - Tests: 417 backend, 20 Rust, 3 integration. Nine mutation checks were all caught.
- **Phase 8a (one-to-one messaging) — ✅ built 2026-09-25**, awaiting the owner's review.
  - Server: `modules/messages` (per-device inbox; ciphertext erased on delivery) and
    `modules/notifications` (content-free FCM wake-ups).
  - App: activation, chats, conversation, safety numbers with QR scan, app lock, and Privacy & security
    (boards 1-5 and 13-19).
  - Local history lives in the vault's encrypted records.
  - Proven between two devices through a real server, and push on a real device.
  - **8b needs explicit approval.** Design notes are in `decisions.md` ("How messages move").
- **Media (Phase 9, brought forward) — ✅ built 2026-09-25**, awaiting the owner's review.
  - Photos, videos, documents and voice messages, up to 2 GB, encrypted on the device.
  - Resumable 8 MB uploads through the server to MinIO (pinned). Downloads are graph-checked.
  - The server deletes every file at 30 days (`modules/media`, migration 013; app: `lib/features/media`).
  - Also built: several files at once (albums), view once (screenshots blocked on Android and Windows) and
    the media gallery (boards 23-25). Photos are re-encoded with EXIF stripped; `Start Skyline.cmd` starts everything.
- **Phase 8b (groups and message tools) — ✅ built and pushed 2026-09-25.**
- **Phase 12 (Testing and hardening) — ✅ built 2026-09-26**, awaiting the owner's review.
  - Threat model: `docs/security/threat-model.md`. How to run every suite: `docs/testing.md`.
  - **CI** (`.github/workflows/ci.yml`, actions pinned to commits) runs backend, dashboard, Rust, Flutter,
    Windows and iOS (simulator) tests, an Android build, gitleaks and dependency audits.
  - Security tests: the authorization matrix (every route × every caller), statistical timing tests,
    security headers, and crypto-core property tests (`untrusted_input.rs`).
  - Load: 500 people at 50 msg/s gives p95 send 30 ms and delivery 43 ms
    (`npx babel-node scripts/load-test.js`).
  - Dashboard fonts are self-hosted, and its build carries a CSP.
  - **MinIO is built from source** (`infra/docker/minio`): images can no longer be pulled anonymously.
  - Board 40: a suspended contact is unavailable. Sends answer 409 `{unavailable}`, groups leave them out,
    and a `contacts` event tells their contacts' apps.
- **Phase 11 (Admin dashboard v2) — ✅ built 2026-09-26**, awaiting the owner's review. Boards 36-39.
  - **Overview:** service health (server, Postgres, Redis, MinIO, coturn via STUN) and usage totals.
    `usage_daily` has no per-person column, by design.
  - **Alerts:** `modules/abuse`, metadata only. Automatic limits live in Redis; an operator can lift one.
    Suspending is always a person's decision. A paused dashboard sign-in answers exactly like a wrong
    password.
  - **Audit log:** a viewer plus CSV export (cells neutralised against formula injection).
  - **Sessions:** everyone ends their own; the owner ends anyone's.
  - Migration 015: moderators lose `audit.read`; new permissions `overview.read` (all operators) and
    `alerts.manage` (admins).
  - Tests: 484 backend (`test/app/dashboard-v2.e2e-spec.js`) and 31 dashboard. Five mutation checks were
    all caught.
- **Phase 10 (Calls) — ✅ built 2026-09-25**, awaiting the owner's review.
  - What it covers: one-to-one voice and video with `flutter_webrtc`, and screen sharing on Windows
    (desktopCapturer) and Android (a mediaProjection foreground service).
  - Setup: offer and answer travel as Signal-encrypted `{"type":"call"}` messages. There is no trickle,
    and the answerer adopts the offer's video transceiver.
  - Relay only: `iceTransportPolicy: relay` through coturn (compose), with short-lived HMAC credentials
    from `GET /calls/turn`. In development, `TURN_URLS` defaults to the PC's LAN IP; production requires it.
  - An offer's freshness is judged by the server-held age (`ageMs` in the inbox), never by the caller's clock.
  - Code: `lib/features/calls`, `modules/calls`. Tests: `integration_test/calls_test.dart` and
    `call_ui_test.dart` (four sizes, fails on overflow).
  - Limit: a closed app does not ring (`known-risks.md`).
  - Details for Phase 8b (groups, message tools, search):
  - Groups: managed in the dashboard (Groups page), libsignal Sender Keys rotated when anyone leaves.
  - Message tools: reply, edit (15 minutes), delete (24 hours), reactions, pins, mentions.
  - Chat list and search: local search, drafts, archive and mute.
  - See the progress log for what remains.
  - Firebase secrets stay OUT of git: `google-services.json` is gitignored, and the service account lives in
    `C:\Users\kkhal\Skyline-secrets\`.
- **Owner decisions 2026-09-21** (`decisions.md`): admins never see message content in v1 (a *disclosed*
  compliance archive may be designed later as an opt-in mode — build nothing toward it now); app lock
  (PIN/biometrics) is always the user's own choice, no admin override; user-set disappearing messages are
  accepted (Phase 8). Their Privacy & security, lock-screen and timer prototypes were **approved
  2026-09-23** (design boards 13-15). The timer offers Off, 1 hour, 1 day, 1 week, 1 month, 3 months,
  6 months, 1 year, plus a custom duration from 5 minutes to 1 year.
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
- **Admin tooling is a separate web app** (`apps/dashboard`), never in-app screens. The dashboard never
  holds message keys or plaintext, so the WASM problem does not apply to it.
- **The owner account is protected** (`users.is_owner`, DB trigger): nobody can demote, suspend, rename or
  delete it, and only the owner creates, promotes or removes admins. Moderators manage members only;
  nobody manages themselves. Policy lives in `modules/admin/admin-policy.js` — every admin write calls it.
- **Dashboard session = `skyline_admin` HttpOnly SameSite=Strict cookie**, and every cookie-authenticated
  change must carry `x-skyline-client: dashboard` (CSRF). The dashboard is same-origin through `/api`; never
  add CORS. Details: `docs/security/authorization.md` → "The dashboard session".
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
- **Authorization is global guards, default deny, and NOTHING is cached** (owner decision): 429 if rate-limited (checked first, fails closed), 401 if
  not an active account, 403 if the role lacks a permission, **404** if a named person/group/chat is
  outside the contact graph. Every check hits Postgres per request, so suspending a user, revoking a
  device, changing a role or revoking a link takes effect on the very next request. **Never add a cache.**
  Every route path parameter must be covered by `@ContactTarget`/`@GroupTarget`/`@ChatTarget`, or by
  `@GraphExempt(reason)` + `@RequirePermission`; the route-inventory test fails the build otherwise.
- **Members have no password; operators do** (owner decision). Members get in only with a one-time
  activation code, then the device is the credential (Ed25519 key signs activation and every refresh).
  Admins: Argon2id password, TOTP 2FA optional. **Operator routes accept only dashboard sessions (`ska_`),
  member routes only device sessions (`skd_`)** — never interchangeable. Tokens and codes are stored only as
  HMAC hashes; every auth failure is the same 401. Before running anything that creates accounts, **prove
  the command points at a throwaway database** (see the 2026-09-23 progress-log entry).
- **The WebSocket is server-to-client only** and delivery re-checks the graph at delivery time, so a
  revocation stops an already-open socket at once. Clients send over authenticated REST.
- **Plain-JS traps:** no parameter decorators (use `@Bind(Body())`), and DTO validation does nothing
  unless the route also has `@Validated(Dto)`. Details in `docs/security/authorization.md`.
- **Nothing is hard-deleted.** Accounts are soft-deleted (`status='deleted'`); devices, sessions,
  links and memberships are revoked. `DELETE FROM users` fails by design (`username_history` is
  `ON DELETE RESTRICT`) — that is what keeps burned usernames burned.
- **Migrations are plain SQL via `node-pg-migrate`, no ORM.** The security properties live in partial
  indexes, CHECK constraints and triggers; keep them readable. Redeem codes only through
  `redeem_activation_code()`, and build authorization on `are_linked()` / `visible_user_ids()`.
- **Backend is NestJS in plain JavaScript, NOT TypeScript.** Babel handles decorators (`babel.config.js`, project-wide: `.babelrc` would not reach the ESM-only deps tests compile);
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
apps/backend/    NestJS (JS) — src/modules/{auth,users,devices,chats,messages,groups,media,calls,notifications,admin,abuse,monitoring,websocket}
apps/dashboard/  Admin web app — React + Vite, plain JS (src/lib/api.js is the only fetch path; src/pages/*)
crypto-core/     Rust workspace: core/ (libsignal + encrypted vault), ffi/ (flutter_rust_bridge surface), e2e/ (dev tool)
infra/docker/    Dev docker-compose.yml (Postgres, Redis, MinIO)
docs/            progress-log.md + architecture/ (overview, decisions, design, contact-graph, roadmap,
                 known-risks, tech-stack-decisions, folder-structure), api/, database/, security/
                 (authorization.md), deployment/
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
npm run test:db                          # 105 schema-invariant tests against a throwaway database
npm run test:app                         # 275 tests (incl. the authorization matrix and timing tests): guards, auth, admin API, dashboard v2, keys, messaging, media (real MinIO), calls, push, crypto e2e, WebSocket, rate limits, CLI, route inventory
                                         #   (needs the dev Postgres AND Redis up; each suite drops its own DB)
npm run migrate:create -- add-something  # scaffold a new .sql migration

# Operator tools (apps/backend) — act on whatever DATABASE_URL points at
npm run admin:create -- --username x --display-name "Name"   # FIRST admin only; prompts for password
npm run user:invite -- --username x --display-name "Name"    # member + one-time code, printed once
npm run dev:device -- activate SKY-...                      # pretend phone (dev only): activate|me|devices|refresh|logout|forget

# End-to-end app tests against a THROWAWAY server (apps/backend)
npx babel-node scripts/e2e-fixture.js create    # prints JSON: db url + two linked people + codes
DATABASE_URL=<its url> PORT=3078 npm run start  # then run integration_test/messaging_test.dart -d windows
                                                #   with the --dart-defines listed at the top of that test
npx babel-node scripts/e2e-fixture.js drop <skyline_e2e_...>
# Push on Android: set FCM_SERVICE_ACCOUNT_FILE for the server; scripts/push-probe.js sends one wake-up

# Admin dashboard (apps/dashboard) — needs the backend running on :3000 (override: SKYLINE_API=...)
npm install
npm run dev                # http://localhost:5173, proxies /api -> backend
npm test                   # Vitest + Testing Library, no backend needed
npm run build

# Dev data plane (repo root) — Docker Desktop must be running
docker compose -f infra/docker/docker-compose.yml up -d   # Postgres, Redis, MinIO

# Crypto core (crypto-core/) — Rust 1.98.1 pinned; libsignal's build needs protoc on PATH.
# In a fresh shell: export PATH="$HOME/.cargo/bin:$PATH" (protoc is on the Windows user PATH)
cargo test                               # core: vault + libsignal protocol tests
cargo clippy --all-targets               # must stay warning-free
cargo build -p skyline_e2e               # enables test/app/crypto-e2e (skipped without it)
# After changing crypto-core/ffi/src/api: regenerate the Dart bindings (from apps/mobile)
flutter_rust_bridge_codegen generate

# Flutter client (apps/mobile) — platform runners are committed (android, ios, windows; no web)
flutter pub get && flutter analyze && flutter test
flutter test integration_test/crypto_test.dart -d windows   # real native crypto core in the app build
```

## Local toolchain (owner's Windows 11 machine)

| Tool | State |
| --- | --- |
| Flutter 3.35.7 / Dart 3.9.2 | ✅ installed |
| Node 24.19 / npm 11.17 | ✅ installed |
| Rust 1.98.1 (MSVC) / VS 2022 C++ Build Tools / protoc 36 / flutter_rust_bridge_codegen 2.13.0 | ✅ installed 2026-09-23 |
| Docker Desktop 29.8 (WSL2) | ✅ installed and working; dev stack verified |

`apps/mobile/{android,ios,windows}` are committed; `rust_builder/` (cargokit) builds `crypto-core/ffi` into the app.
Backend boot needs the dev Postgres + Redis up (`npm run start`). Smoke tests that create accounts must
run against a **throwaway** database on a spare port — never the owner's dev DB, never their server on :3000.
