# Progress Log

Append one entry per working session, newest at the top. This is the handoff record: an agent picking
up Skyline should read `CLAUDE.md` first, then the most recent entries here.

Each entry states what was decided, what changed on disk, and what the next agent should do. Do not
rewrite history in this file — append.

---

## 2026-09-23 — Phase 5 BUILT: authentication, invites, rate limiting

**Owner decisions** (full text in `decisions.md`, 2026-09-23): members have **no password** (the activation code
is the only way in; the device is the credential; no recovery codes); **admins sign in with a password and
2FA is optional**, chosen for simplicity; each device registers an **Ed25519 signing key** now, Signal keys in
Phase 7. The owner also asked to push: Phases 2-4 were pushed to GitHub at the start of this session.

**Built:**

- **Migration 009**: device `signing_key`; Signal fields nullable until Phase 7; the code->device FK deferred
  to COMMIT so activation is one atomic transaction; token hashes on `device_sessions`;
  `admin_credentials` and `admin_sessions`.
- **Activation** (`POST /auth/activate`): code + device public key + signature over the code. Redeems through
  `redeem_activation_code()`, registers the device, opens a session, all or nothing.
- **Device tokens**: 15-min access, 30-day refresh that rotates; refresh needs a fresh Ed25519 signature;
  a reused refresh token revokes the whole session. Logout, list/revoke own devices.
- **Admin sign-in**: Argon2id password, optional TOTP 2FA (setup/enable/disable), password change that signs
  out other sessions, 12h absolute / 60-min idle dashboard sessions.
- **Session kinds are enforced**: operator routes accept only dashboard sessions, member routes only device
  sessions. An admin's phone cannot call operator APIs.
- **Rate limiting** (carried over from Phase 4): Redis fixed windows, per address and per username, fails
  closed. WebSocket login now takes a real device token.
- **CLI**: `npm run admin:create` (first admin only), `npm run user:invite` (member + one-time code, shown once).
  **`npm run dev:device`**: a pretend phone for trying the API by hand (dev only).
- **`docs/try-it-yourself.md`**: the owner's step-by-step manual test.

**Tests: 344 pass** (109 unit, 78 db, 157 app), no leaked databases. The Phase 5 suite uses real keys and
real tokens (no test shortcuts). **8 mutation checks, all caught**: refresh accepting any signature, reuse
detection off, activation skipping the signature or admitting a suspended account, a phone accepted on
operator routes, a replayable 2FA code, a suspended admin signing in, password change keeping other sessions.

**Found and fixed along the way:** otplib's dependency is ESM-only and Jest could not load it (fixed by moving
to a project-wide `babel.config.js` and rooting both Jest configs at the backend folder: note this in
`authorization.md` gotcha 5); a failed-2FA audit entry would have been rolled back with its transaction (now
written outside it); and the CLI password prompt could hang on piped input (rewritten; verified piped, the
live-keyboard path is untested here, so an env-var fallback is documented).

**A process slip, recorded honestly:** while testing the CLI, a command chain kept running after a syntax
check failed, so later steps ran without the throwaway `DATABASE_URL` and would have hit the dev database. The
CLI crashed before touching anything and the dev database was verified untouched (0 users). The re-run used
`set -e` and a guard that refuses any database name that is not a throwaway one. **Do the same: any command
that creates accounts must prove it is pointed at a throwaway database first.**

**Deliberately NOT done:** no accounts were created in the owner's dev database. `admin:create` only makes the
*first* admin, so that must be the owner's own.

**Moved out of Phase 5:** the PIN/biometric app lock is purely on-device, so it belongs with the mobile app
build, not the backend. Its Privacy & security settings prototype is still owed.

**Known gaps** (details in `authorization.md`): `trust proxy` must be set when Nginx arrives (Phase 13) or all
clients share one rate-limit counter; a client that blindly retries a successful refresh gets its session
revoked; timing uniformity is by design, not measured.

**Next agent:** Phase 6 (admin dashboard v1) needs the owner's explicit approval, and it is a user-visible
surface, so **its screens must be prototyped and approved first** (the Phase 2 canvas has users, create-user,
contact graph and edit-user boards; sign-in and 2FA screens are not drawn yet). The dashboard's API should reuse
`issueActivationCode()` and `AuditService`, use `@RequirePermission` + `@GraphExempt` on every route that takes
a user id, and remove `apps/mobile/lib/features/admin/`.

---

## 2026-09-21 (night) — Phase 4 BUILT: backend foundation and authorization core

**Owner decisions this session:** graph checks go **in SQL, nothing cached**; true E2EE for v1 with a
*disclosed* compliance archive possible later (nothing built toward it); app lock is **always the user's
own choice**; then "start Phase 4". All recorded in `decisions.md`.

**Built** (all under `apps/backend/src`, documented in `docs/security/authorization.md`):

- **Config** validated at boot: reports every problem at once, never prints a value, refuses dev placeholder
  secrets in production.
- **Logging**: structured JSON, redacted by key name, no bodies, no query strings, sanitised request ids.
- **One error filter**: every 404 identical whatever produced it; no stack/SQL/path ever leaks; only a
  *list* of validation messages is passed through on a 400.
- **Strict validation**, global: undeclared fields are rejected (mass assignment), values never echoed.
- **Health**: `/health` (liveness) and `/health/ready` (Postgres + Redis, up/down only).
- **Three global guards, default deny, nothing cached**: authenticated-and-still-active (401), permission
  (403), contact graph (404). Plus `AuditService`, the DB and Redis modules, and the WebSocket gateway
  with Redis fan-out that **re-checks the graph at delivery time**.
- **Route-inventory test**: fails the build if any route parameter is not graph-scoped, or a body is unvalidated.

**Tests: 243 pass** (71 unit, 75 db, 97 app), every run exiting 0 with no leaked databases. Includes real
HTTP, real WebSockets, real Redis, and **two backend instances** sharing a channel.

**Mutation-tested.** Deliberately breaking each core protection makes the suite fail: fan-out ignoring the
graph (7 tests fail), graph guard off (12), suspended user still active (2), revoked device accepted (2),
404 leaking a message (3). A first attempt at the last one "passed" only because my mutation was a no-op;
I redid it as a real leak rather than accept a false all-clear.

**Real bugs found and fixed by the tests — none would have been caught by reading:**

1. **Health check reported OK with the database down.** `database && redis ? 'ok' : ...` where the values
   were the strings `'up'`/`'down'`, both truthy. A load balancer would have kept routing to a dead instance.
2. **Malformed-JSON 400 leaked the parser's message** ("Unexpected end of JSON input"). Nest wraps
   body-parser errors in a BadRequestException carrying that text; my filter passed it through.
3. **Jest could not parse `src/`** from the e2e config (Babel ignored `.babelrc` with `rootDir` at `test/`).
4. My own test leaked a whole app when an assertion failed before cleanup, hanging the run. Now `try/finally`.

**Decisions made in code that the owner has not been asked about** (all cheap to reverse):
a suspended user stays *visible* to contacts (only deleted accounts vanish); archived groups remain reachable
by members; a missing permission is a 403 not a 404; the WebSocket is server-to-client only.

**NOT built, and stated so nobody assumes otherwise:**

- **Rate limiting.** It was on my Phase 4 plan and I did not build it. It is needed first for activation-code
  redemption (Phase 5), so it moves there.
- **Real authentication.** Every non-public route returns 401 and no WebSocket can connect until Phase 5.
- Timing side channels are unmeasured; `trust proxy` is unset until Phase 13 (details in `authorization.md`).

**Also this session:** MinIO's image had vanished from Docker Hub and the replacement is a year stale (see
`known-risks.md`, needs an owner decision before Phase 9). Docker/WSL is fixed.

**Owed to the owner:** a *Privacy & security* settings prototype (app lock, disappearing-message timer),
required before those features are coded.

**Next agent:** do not start Phase 5 without the owner's explicit approval. Read
`docs/security/authorization.md` first. Phase 5 will implement token authentication (feeding
`request.principal` and `WS_AUTHENTICATOR`), activation-code redemption through `redeem_activation_code()`,
rate limiting, and device binding. **The test harness fakes a principal from headers; that fake must never
appear in `src/`.**

---

## 2026-09-21 (evening) — Docker working; Phase 3 schema VERIFIED; three new owner requests

**Docker.** WSL installed and the engine runs (Docker 29.8.0). Postgres 16, Redis 7 and MinIO are up and
healthy. `minio/minio` no longer exists on Docker Hub, so the compose file now uses
`quay.io/minio/minio:latest` — which is release 2025-09-07, a year stale. Fine for dev, a real risk for
production; see `known-risks.md`.

**Phase 3 verified against a live database.** 8 migrations apply, roll back to nothing, and re-apply.
75 tests (`npm run test:db`, in `apps/backend/test/db/`) pass, including 25 concurrent connections racing
one activation code (exactly one wins). A control run with a deliberately broken check-then-write redeem
let **10 of 10** racers through, so the test discriminates. **One real bug found and fixed:** `TRUNCATE`
bypassed the append-only audit log; added a `BEFORE TRUNCATE` trigger to migration 008 (edited in place,
legitimate only while nothing is deployed anywhere). Full detail and the honest gaps (timing is not
measured; no application code exists yet to test) are in `docs/database/schema.md`. Earlier I said "15
tables"; it is 17.

**Owner requests received, all logged in `decisions.md`:**

1. **PIN / Face ID / fingerprint app lock — accepted.** Local-only, must gate the keystore not just cover
   the screen, admin can never see or reset a PIN. Phase 5. Needs a prototype first.
2. **User-set disappearing messages — accepted, with honest limits.** Schema already supports it. Phase 8.
   Needs a prototype first.
3. **Admin can view all messages and media — ESCALATED, NOT IMPLEMENTED.** It contradicts the locked rule
   that admins never read messages. Three options were put to the owner (keep E2EE; disclosed compliance
   archive; E2EE now and an opt-in archive mode later). **Do not build any of it until the owner
   answers, and never build a covert version.**

**Next agent:** read the open decision in `decisions.md` first. Phase 4 does not depend on the answer and
may proceed. Start with the DB-independent pieces (config validation, exception filter, logging,
permission decorators), then `ContactGraphGuard` over `visible_user_ids()`, tested against the real
database using the harness in `apps/backend/test/db/harness.js`.

---

## 2026-09-21 (later) — Docker installed but its engine cannot start: WSL is missing

**Owner decisions:** Docker installed; graph authorization goes **in SQL** (call `visible_user_ids()` /
`are_linked()` per request, no Redis cache of the visible set — a cache adds a stale-access-after-revoke
risk that isn't worth it at this scale). That is effectively the go-ahead for Phase 4.

**State found.** Docker Desktop's CLI (29.8.0) and Compose (v5.5.1) are installed at
`C:\Users\kkhal\AppData\Local\Programs\DockerDesktop\resources\bin` — on the *persistent* PATH but not in
sessions started before the install, so use the full path or restart the terminal. Launching Docker
Desktop leaves the engine returning `500 Internal Server Error` because **WSL is not installed**
(`wsl --status` reports it missing) and Docker Desktop's Linux engine runs on WSL2. Windows 11 **Home**
has no Hyper-V alternative. Virtualization itself *is* enabled (`HypervisorPresent: True`, VBS running);
`Win32_Processor.VirtualizationFirmwareEnabled` reads `False` but is a known false negative when a
hypervisor is already running — do not send the owner into the BIOS on that basis.

**Fix (needs an elevated PowerShell, possibly a reboot — owner's call, not done by the agent):**
`wsl --install --no-distribution`, reboot if asked, then start Docker Desktop.

**A local `apps/backend/.env` was created** (gitignored) with credentials matching the dev compose
stack: `DATABASE_URL=postgres://skyline:skyline@localhost:5432/skyline`. Note `.env.example` keeps the
`change-me` placeholders; only the local `.env` uses the dev-stack values.

**Not yet done, and deliberately held:** applying the Phase 3 migrations for real
(`docker compose ... up -d`, then `npm run migrate:up && migrate:down && migrate:up`). Phase 4's guard is
SQL-backed, so it should not be built on a schema that has never touched a live Postgres. DB-independent
Phase 4 pieces (config validation, exception filter, logging, permission decorators) can proceed first.

---

## 2026-09-21 — Phase 3: schema written. Not yet run against a live database.

**Tooling chosen: `node-pg-migrate` in plain-SQL mode.** No ORM. It fits the locked decisions already
in place (raw `pg`, plain JavaScript) and keeps partial indexes, CHECK constraints and triggers
readable, which matters because this schema's security properties live in exactly those things.
Added as a devDependency with `migrate*` scripts in `apps/backend/package.json`, and `DATABASE_URL`
added to `.env.example`.

**Eight migrations written** — see `docs/database/schema.md` for the full walkthrough. Summary:
extensions/enums, RBAC, users + username history, devices/sessions/push, activation codes, the contact
graph, chats/messages/envelopes/attachments, audit log.

**The four invariants are enforced by the database, not by application code:**

1. Contact links symmetric via `CHECK (user_a_id < user_b_id)`; one live link per pair via a partial
   unique index; `are_linked()` and `visible_user_ids()` are the authorization primitives Phase 4
   builds its guard on.
2. Activation codes single use: partial unique index for one live code per user, a `BEFORE UPDATE`
   trigger that freezes redemption facts once spent, and `redeem_activation_code()` doing one atomic
   conditional `UPDATE` that returns `NULL` identically for unknown/spent/revoked/expired.
3. Usernames never reissued: `username_history` with a global `UNIQUE` plus a trigger, so a rename to
   any previously used username aborts the transaction.
4. `audit_log` append-only via triggers, and deliberately FK-free so records outlive their subjects.

**Bug found and fixed during review.** Four foreign keys were written `ON DELETE SET NULL` on columns
that CHECK constraints require to be non-null (`messages.sender_user_id`, `messages.sender_device_id`,
`activation_codes.redeemed_by_device_id`, `attachments.uploaded_by_device_id`). Deleting a device would
have violated `messages_shape` with a confusing constraint error. Changed to `RESTRICT`, which makes
the real policy explicit: **nothing is hard-deleted in Skyline** — accounts are soft-deleted, devices
and links are revoked. Documented in `schema.md`.

**Verification — read this before trusting the schema.** Docker is still not installed, so the
migrations have **never been applied to a real PostgreSQL**. What was actually verified: every
statement was parsed against the genuine PostgreSQL 18 grammar using `libpg-query` — 113 statements
across all up/down halves, plus all seven function bodies parsed individually, 0 failures. **That
catches syntax errors and nothing more.** It does not prove constraints behave as intended, that
triggers fire, or that migrations apply and roll back in order.

**Next agent must, before anything else:**

1. Install Docker Desktop, bring up `infra/docker/docker-compose.yml`, then run
   `npm run migrate:up && npm run migrate:down && npm run migrate:up` and fix whatever falls over.
   Do not build Phase 4 on an unverified schema.
2. Write the constraint tests early rather than waiting for Phase 12 — especially double-redemption of
   one code under concurrency, and renaming to a burned username.
3. Then Phase 4 (backend foundation + `ContactGraphGuard` over `visible_user_ids()`), after the
   owner approves starting it.

---

## 2026-09-20 (later) — Phase 2 APPROVED. Two requirements added.

**The project owner approved the design.** Calls staying in scope (Phase 10) was called out
specifically as wanted.

**Two new requirements, both now binding on the Phase 3 schema** (full rationale in
`architecture/decisions.md`):

1. **Activation codes are strictly single use.** Store a hash, never the code. Redeem with a single
   atomic conditional `UPDATE` plus a unique partial index — **not** check-then-write, which races.
   Spent, expired and nonexistent codes must fail identically, including in timing.
2. **Admins can rename any user** (display name and username). Three constraints ship with it: every
   rename is audit-logged with old/new values; every rename is announced as a system message in each
   affected conversation; a rename never touches identity keys, so verified safety numbers stay valid.
   Constraints 2 and 3 exist because an admin who could silently rename one user to another's name
   could socially impersonate them in a network where users cannot independently search or verify
   anyone. Do not drop them for convenience.

**Prototype updated** — board 8 "Admin · Edit user" added (rename form, spent-code record, device
revocation, encryption panel, danger zone). Board 1 now states the single-use rule at the point of
entry. Canvas: <https://claude.ai/artifact/JinzvtYfYetkpiDgFQ2Gt5>

**Next agent: begin Phase 3 (Database & contact graph).** The owner has approved moving on. Start from
`architecture/contact-graph.md` and the two decision entries above. Install Docker Desktop first — the
dev data plane cannot come up without it, so migrations cannot be tested until it is running.

---

## 2026-09-20 — Phase 2 kickoff: scope corrections + first design pass

**Context.** Project owner reviewed the Phase 1 plan against the actual product requirements and found
three gaps. Four scoping questions were answered; the plan was revised and a first prototype produced.

**Decided** (full rationale in `architecture/decisions.md`):

1. v1 platforms are **iOS, Android, Windows**. The Web messaging client is dropped — no official
   WASM build of `libsignal-client` exists, and every alternative is unaudited.
2. Admin tooling is a **separate web dashboard**, not in-app screens.
3. Contacts are **fully locked** — admin assigns every link and every group membership; no user
   search, discovery, group creation or contact requests.
4. **Design is approved as a prototype before code**, every phase.

**Roadmap restructured** 11 phases → 13 (`architecture/roadmap.md`):

- New **Phase 2: Product design**.
- Contact graph moved **Phase 9 → Phase 3**. It is an authorization invariant every endpoint must
  satisfy, so it cannot be a late-stage admin feature.
- Admin dashboard split: **v1 → Phase 6** (a hard prerequisite, since accounts and contacts are created
  by hand and nobody can sign in until it exists), **v2 → Phase 11** (audit, monitoring, abuse).

**Files added**

- `docs/architecture/contact-graph.md` — the core invariant, schema sketch, enforcement rules,
  non-deletable test obligations.
- `docs/architecture/decisions.md` — append-only decision log.
- `docs/architecture/design.md` — design system tokens, type scale, colour semantics, prototype link,
  the standing design-review rule.
- `docs/progress-log.md` — this file.

**Files changed**

- `docs/architecture/roadmap.md` — rewritten (13 phases + a table of what changed and why).
- `docs/architecture/known-risks.md` — Web/WASM risk closed as *deferred by scope*; sandbox caveats
  replaced with the real local toolchain state.
- `README.md`, `CLAUDE.md` — brought in line with the above.

**Prototype** — <https://claude.ai/artifact/JinzvtYfYetkpiDgFQ2Gt5> (7 boards; private to the owner).
Design tokens are recorded in `architecture/design.md` so they survive independently of the canvas.

**Toolchain reality on the owner's machine** (Windows 11): Flutter 3.35.7 ✅, Dart 3.9.2 ✅,
Node 24.19 ✅, npm 11.17 ✅ — **Rust/cargo ❌ and Docker ❌ are not installed**. Rust is needed from
Phase 7 (`crypto-core`), Docker from Phase 3 (Postgres/Redis/MinIO). Flag this before those phases
start rather than mid-phase.

**State of the code.** Unchanged from Phase 1 — scaffolding only, no feature logic. `apps/mobile` still
has no SDK-generated platform runner folders; run the `flutter create --platforms=...` bootstrap in
`apps/mobile/README.md` before the first `flutter run` (drop `web` from that command per decision 1).

**Next agent should:**

1. Confirm the owner has approved the prototype and the revised roadmap. **Do not start Phase 3 without
   explicit approval** — that is a standing process rule, not a formality.
2. If design feedback comes back, revise the canvas boards and re-present. Read the canvas files before
   editing them; the owner may have edited the boards directly.
3. On approval, begin **Phase 3 (Database & contact graph)**: schema, migrations, indexes, constraints.
   Start from `architecture/contact-graph.md` — the `CHECK (user_a_id < user_b_id)` symmetry constraint
   and default-deny posture are the parts that must not be softened for convenience.
