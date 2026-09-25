# Testing

Every suite, what it proves, and how to run it. On every push, GitHub Actions runs everything below
except the load test and the device end-to-end tests (`.github/workflows/ci.yml`).

## The suites

| Suite | Where | Run | What it proves |
| --- | --- | --- | --- |
| Backend unit | `apps/backend/src/**/*.spec.js` | `npx jest` | Config validation, crypto helpers, policy |
| Database invariants | `apps/backend/test/db` | `npm run test:db` | The schema's security properties: single-use codes, the contact graph, the append-only audit log, role permissions, one open alert per subject. Migrations apply, roll back and re-apply. |
| Backend app | `apps/backend/test/app` | `npm run test:app` | Every route through the real guards, with real sessions, Postgres, Redis and MinIO |
| Authorization matrix | `test/app/authorization-matrix.e2e-spec.js` | (in `test:app`) | **Every** route × every kind of caller: signed out → 401; the wrong kind of session → 401; a moderator without the permission → 403; anything outside the graph → the same 404 as something that does not exist. Routes are read from the running app, so a new route is covered automatically. |
| Timing | `test/app/timing.e2e-spec.js` | (in `test:app`) | A spent code and one that never existed, a known and an unknown operator, and an unlinked and a nonexistent id each take the same time. The medians are compared over interleaved samples. |
| Dashboard | `apps/dashboard/src/test` | `npm test` | Pages, permissions and the API client (Vitest + Testing Library) |
| Crypto core | `crypto-core/core/tests` | `cargo test` | libsignal sessions, groups, media, the vault. `untrusted_input.rs` adds property tests: random and corrupted envelopes, group messages, key bundles, QR codes and media are refused, never a panic, and never a different plaintext. |
| App unit | `apps/mobile/test` | `flutter test` | Message rules (edit and delete windows, what a receiver accepts), call outcomes and freshness, vault round trips |
| App end to end | `apps/mobile/integration_test` | see below | Real devices, real crypto, a real throwaway server: messaging, groups, actions, media, calls, the unavailable state, screenshots of every board |

## App end-to-end tests

They need a throwaway server. The fixture refuses any database not named `skyline_e2e_*`.

```bash
cd apps/backend
npx babel-node scripts/e2e-fixture.js create      # prints JSON: url, alice/bob/carol codes, group, operator password
DATABASE_URL=<url> PORT=3078 RATE_LIMIT_PREFIX=skyline-e2e RATE_LIMIT_SCALE=20 npm run start
cd ../mobile
flutter test integration_test/<name>_test.dart -d windows \
  --dart-define=SKYLINE_API=http://localhost:3078 --dart-define=ALICE_ID=... (see each test's header)
npx babel-node scripts/e2e-fixture.js drop <skyline_e2e_...>
```

On the Android emulator, use `-d emulator-5554` and `SKYLINE_API=http://10.0.2.2:3078`.

## Load test (500 people)

```bash
cd apps/backend
npx babel-node scripts/load-test.js --people 500 --rate 50 --seconds 60   # also: --pool N, --keep
```

It creates and drops its own `skyline_e2e_load_*` database, runs its own server on :3079, connects every
device's WebSocket, and sends the way the app does: POST, nudge, pull, acknowledge. The budget is a p95
send under 300 ms and a p95 delivery under 1 s. The script exits non-zero when the budget is missed.

Results on the owner's development PC (2026-09-26: Windows 11, Docker Desktop Postgres, server, clients
and database all on one machine):

| Run | Send p50 / p95 / p99 | Delivery p50 / p95 / p99 | Errors | Lost |
| --- | --- | --- | --- | --- |
| 500 people, 50 msg/s, 60 s | 18 / 30 / 102 ms | 29 / 43 / 144 ms | 0 | 0 |
| 500 people, 100 msg/s (2× target), 20 s | 18 / 118 / 475 ms | 27 / 167 / 596 ms | 0 | 0 |

The server's own p95 was 17 ms at 50 msg/s. The first run on a cold machine is slower (p95 around 600 ms)
while caches warm. For production, `DATABASE_POOL_MAX=20` gave a lower p95 than the default 10 at this
load (Phase 13).

## Scans (CI's "security" job)

- **Secrets:** gitleaks over the whole history, with `.gitleaks.toml` allowing only lock-file checksums.
- **Dependencies:**
  - `npm audit --audit-level=moderate` for the backend and the dashboard; both are clean as of
    2026-09-26.
  - `cargo audit` for crypto-core: no vulnerabilities. One "unmaintained" notice
    (`proc-macro-error2`, build time only).
