# Authorization

How the backend decides who may do what, and how to add a route without breaking it. Read this before
writing any controller. The rule it protects is in [`contact-graph.md`](../architecture/contact-graph.md).

## The model: four global guards, default deny

Every HTTP route passes through four guards, registered globally in `app.module.js`, in this order:

| Order | Guard | Question | Failure |
| --- | --- | --- | --- |
| 1 | `RateLimitGuard` | Is this address (or username) over a `@RateLimit` for this route? Runs first, so unauthenticated floods are throttled. **Fails closed**: Redis down means refused. | `429` / `503` |
| 2 | `AuthenticatedGuard` | Is there a valid bearer token of the **right kind for this route**, and is that account (and device) **still active right now**? | `401` |
| 3 | `PermissionsGuard` | Does the caller's role hold every permission this route requires? | `403` |
| 4 | `ContactGraphGuard` | Is every person, group, chat or own-device named in the path inside the caller's graph? | `404` |

**Two kinds of session, never interchangeable.** A route with `@RequirePermission` or `@DashboardSession` is
an **operator route** and accepts only a **dashboard** session (`ska_` token, from `/admin/auth/login`). Every
other authenticated route is a **member route** and accepts only a **device** session (`skd_` token, from
activation). So an admin's own phone cannot call operator APIs, and a dashboard login cannot act as a member
in the app. This is how the locked decision "admin tooling is separate from the app" is enforced in code.

**Nothing is cached.** Each guard queries PostgreSQL on every request (an owner decision, see
`decisions.md`). Suspending a user, revoking a device, changing a role and revoking a contact link all
take effect on the *next request*, and the tests prove it. A cache would make each of those wait for
expiry.

**Why 404 and not 403 for the graph.** A `403` says "this exists but you may not". Skyline's whole design is
that a user cannot learn who else exists, so an id outside your graph must be indistinguishable from an id
that does not exist. The exception filter (`all-exceptions.filter.js`) renders every 404 with an identical
body whatever produced it: a guard, a service, or the router. A `403` is fine for *permissions* because
that an operator route exists is not a secret. Only the directory of people is.

## Writing a route

```js
import { Controller, Get, Post, Bind, Body, Dependencies } from '@nestjs/common';
import { ContactTarget, RequirePermission, GraphExempt } from '../../common/decorators/access.decorators';
import { Validated } from '../../common/decorators/validated.decorator';

@Controller('contacts')
export class ContactsController {
  // Names another person: the graph decides. Reaching outside it is a 404.
  @Get(':userId')
  @ContactTarget('userId')                      // 'visible' (default): contact or group-mate
  profile() { ... }

  // Messaging needs a DIRECT link. Sharing a group is not enough.
  @Get(':userId/thread')
  @ContactTarget('userId', { mode: 'direct' })
  thread() { ... }

  // A body must declare its DTO, or nothing validates it (see "Plain JavaScript" below).
  @Post()
  @Bind(Body())
  @Validated(CreateThingDto)
  create(dto) { ... }
}

// An operator route acts on ANY user, so it cannot be graph-scoped. It must say why, and it must be
// permission-gated instead.
@Controller('admin/users')
export class AdminUsersController {
  @Post(':userId/rename')
  @GraphExempt('operators act on any account and are gated by permission instead')
  @RequirePermission('users.rename')
  rename() { ... }
}
```

| Decorator | Meaning |
| --- | --- |
| *(none)* | Authenticated account required. Nothing else. Fine for a route with no path parameters. |
| `@Public()` | No authentication. Health checks and the activation flow, almost nothing else. Must take **no** path parameters. |
| `@RequirePermission(...keys)` | Role must hold **all** listed permissions. There is deliberately no permission for reading message content. |
| `@ContactTarget(param, {mode})` | `param` names a user. `visible` (default) or `direct`. |
| `@GroupTarget(param)` | `param` names a group; caller must be a live member. |
| `@ChatTarget(param)` | `param` names a chat. A direct chat is reachable **only while its link is live**; a group chat only by live members. |
| `@GraphExempt(reason)` | Escape hatch for operator routes. Needs a real reason **and** `@RequirePermission`. |
| `@OwnDeviceTarget(param)` | `param` names a device that must belong to the caller and be live. Anyone else's is a 404. |
| `@DashboardSession()` | An operator route that needs a dashboard session but no particular permission (sign out, 2FA, password). |
| `@RateLimit(name, rules)` | Throttle per `ip` and/or per `body.<field>` (from `common/rate-limit/rate-limit.js`). Required on every `@Public` route that checks a secret. |

Decorators stack, so a route with `:chatId` and `:userId` carries both.

## The route inventory: forgetting a decorator fails the build

`test/app/route-inventory.js` enumerates every route in the real `AppModule` and fails if:

- **any path parameter** is not covered by a graph decorator, or by `@GraphExempt` plus
  `@RequirePermission`. This includes a parameter like `:username`, which would be directory discovery;
- a `@Public` route takes a parameter, or is graph-scoped, or requires a permission;
- a graph decorator names a parameter that is not in the path (a typo would silently protect nothing);
- a route takes a `@Body()` without `@Validated(Dto)`.

The checker has its own tests: a checker that cannot fail proves nothing.

## Plain JavaScript gotchas (these cost real time)

This project is JavaScript, not TypeScript, compiled by Babel with legacy decorators. Consequences:

1. **No parameter decorators.** `create(@Body() dto)` is a syntax error. Use `@Bind(Body())` above the method.
2. **DTO validation silently does nothing without help.** TypeScript emits type metadata telling Nest
   which class to validate a body against. Plain JS has none, so the global `ValidationPipe` has no class to
   check and passes everything. **Always add `@Validated(YourDto)`.** The inventory test enforces it.
3. **Injection is `@Dependencies(...)`**, not constructor type annotations.
4. **Use `_underscore` methods, not `#private`.** Babel's legacy decorators are fussy about private members.
5. **Babel config is `babel.config.js` (project-wide), not `.babelrc`,** because tests must also compile a few
   ESM-only dependencies (otplib -> `@scure/base`, `@noble/*`), and a `.babelrc` never applies inside
   `node_modules`. Consequently **both Jest configs must have `rootDir` at the backend root** (Babel looks for
   `babel.config.js` from there) and list those packages in `transformIgnorePatterns`. Get either wrong and
   every decorator, or every `import` in those packages, is a syntax error.

## What is protected at the transport level

- **Validation** is strict and global: an undeclared field is **rejected**, not silently trimmed
  (`forbidNonWhitelisted`), which closes mass-assignment. Error messages name the bad fields and never
  echo the submitted values.
- **Every error is generic.** No stack, SQL, constraint name or path ever reaches a client. Only a
  *list of validation messages* is passed through on a 400; any other 400 message (such as a body-parser
  internal) is replaced. The detail goes to the log, keyed by request id.
- **`PublicBodyException`** lets a 5xx publish a body its thrower deems safe (the readiness up/down list).
  It is ignored for any 4xx, so it can never be used to make two 404s distinguishable.
- **Logging is structured and redacted by key name**, deliberately broad. Bodies and query strings are
  never logged. Inbound request ids are honoured only if short and boring, so a caller cannot inject
  newlines into logs.
- **Config validates at boot** and reports every problem at once, **never printing a value**. In
  production it refuses development placeholder secrets.
- `X-Powered-By` is removed. Health endpoints reveal only `up`/`down`, never a reason, host or version.

## WebSockets

- **One-directional.** The socket delivers server to client only; inbound frames are ignored. Clients
  *send* over authenticated REST, where the graph is enforced per request. This removes a whole class of
  "write a message by talking to the socket directly" bypasses.
- **Device tokens only.** `TokenWsAuthenticator` accepts a device access token in the `Authorization`
  header (or `?token=` for clients that cannot set headers; query strings are never logged). A refresh token
  or a dashboard token is refused: a dashboard login has no business receiving members' messages. The
  account and device are then re-checked against the database before the socket is admitted.
- **Delivery re-checks the graph at the moment of delivery**, not at connect time (`FanoutService`, backed
  by `GraphService.deliverableDevices`). So revoking a link, suspending a user or revoking a device stops
  delivery on an **already-open socket**, immediately. The sender's own other devices always qualify.
- **Multi-instance.** `publish()` goes to Redis pub/sub and every instance delivers to its own connected
  sockets; each instance re-applies the graph check. Verified with two real backends and one channel.
- A 30-second sweep closes sockets whose account was suspended or device revoked. Deliveries are refused
  the instant it happens; the sweep only stops an inert socket lingering.

## Auditing

`AuditService.record()` writes to the append-only `audit_log`. Pass the caller's transaction client so the
entry commits or rolls back **with** the change it describes (tested). It refuses any `detail` field whose
name looks like a secret, because the table can never be edited or deleted.

## Authentication (Phase 5)

Full rationale in `decisions.md` (2026-09-23). How it works:

**Members (phones and desktops): no password.**

1. An administrator creates the account and issues a one-time activation code (`npm run user:invite` until
   the dashboard exists). The code is shown once and stored only as an HMAC hash.
2. The device generates an **Ed25519 key pair**, keeps the private half, and calls `POST /auth/activate` with
   the code, its public key and a signature over the code. One transaction redeems the code (through
   `redeem_activation_code()`), registers the device and opens a session; any failure rolls all of it back.
3. The device gets an **access token** (`skd_`, 15 minutes) and a **refresh token** (`skr_`, 30 days).
4. `POST /auth/refresh` swaps them for a new pair, but only with a fresh signature over
   `(timestamp, refresh token)` from the device key, so **a stolen refresh token alone is useless**. Each
   refresh token works once; presenting an already-rotated one **revokes the whole session** (theft detection).
5. `POST /auth/logout` ends this session. `POST /me/devices/:deviceId/revoke` removes a device for good.

**Operators (web dashboard): password, two-factor optional.**

1. The first admin is created with `npm run admin:create` (refuses once one exists). Passwords are Argon2id.
2. `POST /admin/auth/login` returns a dashboard token (`ska_`, 12 hours absolute, 60 minutes idle), or, if
   the admin turned 2FA on, a 5-minute `skm_` token that is only good for `POST /admin/auth/mfa` with a code.
3. 2FA is TOTP (any authenticator app): `two-factor/setup` then `two-factor/enable` with a working code.
   A code is never accepted twice. Turning it off needs the password **and** a code. Changing the password
   signs out every other dashboard session.

**Rules for anyone touching this code**

- **Every failure is the same 401.** Unknown, spent, expired or revoked code; bad signature; cloned key;
  suspended account; wrong password; unknown username (which still pays for a full Argon2 check). Tests
  assert the bodies are byte-identical.
- **Tokens and codes are never stored**, only `HMAC-SHA256(AUTH_TOKEN_PEPPER, label, value)`. Each kind has a
  prefix and its own hash label, so one kind can never be looked up as another.
- **Rate limits** (production values): activation 10 / 15 min per address; refresh 60; admin login 20 per
  address **and** 10 per username; MFA and 2FA changes 20; password change 10.
- **No custom cryptography.** Ed25519, HMAC, AES-GCM and the CSPRNG are Node's built-ins; Argon2 and TOTP are
  the `argon2` and `otplib` libraries. `src/modules/auth/auth-crypto.js` only fixes how they are used.
- **The test fakes stay in `test/`.** `test/app/app-harness.js` can set a principal from `x-test-*` headers
  for guard tests; `realAuth: true` turns that off. Nothing in `src/` may read those headers.

## The dashboard session and the admin API (Phase 6)

- **Cookie, not token.** `POST /admin/auth/login` or `/mfa` sent with `x-skyline-client: dashboard` sets
  `skyline_admin`: HttpOnly, SameSite=Strict, `Path=/`, and Secure in production. The token is then **left out
  of the body**. Without the header the old behaviour is unchanged: the token comes back in the body, for
  scripts and the CLI. Logout clears the cookie. See `src/modules/auth/dashboard-cookie.js`.
- **Reading it.** `AuthenticatedGuard` checks a bearer token first, then the cookie. The cookie is only ever
  looked up as a *dashboard* session; a device token in a cookie is ignored.
- **CSRF.** A request authenticated by cookie with any method other than GET, HEAD or OPTIONS must carry
  `x-skyline-client: dashboard`, or it gets a 403. Keep this check. SameSite is the first layer; this header
  is the second.
- **Must change password.** While `admin_credentials.must_change_password` is set, an operator can reach only
  `@DashboardSession` routes (me, password, logout) and everything else is 403. The flag is set by a temporary
  password (a new operator, or an owner reset) and cleared by `POST /admin/auth/password`.
- **Who may manage whom** (`src/modules/admin/admin-policy.js`). Every admin write calls `assertCanManage`:
  - nobody acts on themselves, except to rename themselves or revoke their own device;
  - only the owner acts on an administrator;
  - a moderator acts only on members.

  `assertCanAssignRole`: only the owner makes or unmakes administrators. The database trigger
  `users_protect_owner` enforces the owner's protection even if the API is bypassed. The dashboard's
  `canManage()` mirrors these rules only to hide buttons.
- **Admin routes do not use the contact graph.** Operators manage everyone, so every `:id` route is
  `@GraphExempt(OPERATOR)` plus `@RequirePermission(...)`. Permissions come from migrations 002 and 010, and
  `users.role` is admin-only.
- **Same origin, no CORS.** The dashboard reaches the API through `/api` on its own origin: the Vite proxy
  in development, Nginx in production. Adding CORS would open the cookie to other origins' requests, so don't.

## The key directory (Phase 7)

These are member routes, so they accept only a device session. Everything stored is a PUBLIC key; private
keys never leave the device's encrypted vault.

| Route | Guard | What it does |
| --- | --- | --- |
| `PUT /me/keys` | device session | Publish or top up this device's signed prekey, last-resort Kyber key, and one-time EC and Kyber prekeys. At most 100 keys per upload, and at most 500 unused keys of each kind. A key id is never reused by the same device. |
| `GET /me/keys` | device session | How many one-time keys are left, so the device knows when to top up. |
| `GET /users/:userId/keys` | `@ContactTarget(direct)` | One bundle per live, fully published device of a directly linked contact. Anyone else, yourself included, is the usual identical 404. |

- **Claiming.** Fetching a bundle claims one one-time EC key and one one-time Kyber key per device,
  atomically (`UPDATE … WHERE id = (SELECT … FOR UPDATE SKIP LOCKED)`), so two callers never receive the
  same key. When the Kyber keys run out, the device's reusable last-resort key is served instead.
- **Rate limits against key draining.** Each calling device may make 20 fetches per contact per hour and 300
  in total, enforced in `KeysService` through `enforceLimit()`, because the guard runs before
  authentication. Like every limit, it fails closed: if Redis is down, the request gets a 503.
- **Append-only.** Published keys cannot be edited, deleted or truncated (migration 011's triggers). A
  claimed key stays claimed, and a device's identity key, registration id and device number never change.
- **No signature checks on the server, by design.** The fetching device's libsignal verifies them. See
  `decisions.md`, 2026-09-24.
- **Activation (v2)** must also send `identityKey` (libsignal's serialized key: 33 bytes starting 0x05) and
  `registrationId`, both covered by the Ed25519 signature. A clone (an identity key already live on another
  device) gets the same generic 401 as every other activation failure.

## Messaging and push (Phase 8a)

These are member routes (device sessions only). Every route that names another person needs a live
**direct** link; anything else is the identical 404.

| Route | Guard | What it does |
| --- | --- | --- |
| `GET /me/contacts` | device session | Directly linked people, each with their reachable devices and identity keys. |
| `GET /users/:userId/devices` | `@ContactTarget(direct)` | One contact's reachable devices: used to check a first message's sender. |
| `POST /users/:userId/messages` | `@ContactTarget(direct)` | One ciphertext per device: EXACTLY the contact's reachable devices plus the sender's other ones. Anything else is a 409 listing `missing`/`extra`. Idempotent by the client's `messageId`. 120 per device per minute. |
| `POST /users/:userId/signals` | `@ContactTarget(direct)` | Typing indicators: relayed live to connected devices, never stored. |
| `GET /me/inbox` | device session | This device's undelivered copies and system notices. **Re-checks the graph now:** a message from someone whose link was revoked stays undelivered. |
| `POST /me/inbox/ack` | device session | Only this device's own copies. Erases the ciphertext (a trigger makes it one-way) and tells the sender "delivered". |
| `POST /me/messages/status` | device session | Delivery state of your own messages. |
| `GET /me/device-keys` | device session | Bundles for your OTHER devices (same claiming and limits as a contact's). |
| `PUT` / `DELETE /me/push` | device session | This device's push token (one per device). |

- **Push wake-ups carry nothing:** the payload is always `{"t":"inbox"}`, with no sender, no text and no
  chat. A device is woken at most once per 5 s; a token the provider reports as dead is forgotten; revoked
  devices are never woken. Firebase is off until `FCM_SERVICE_ACCOUNT_FILE` is set, and tests use a
  recording transport (`test/app/app-harness.js`).
- **A 409 body may be structured** (`PublicBodyException` for status 409). No graph check ever answers 409,
  so 404s stay indistinguishable.

## Dashboard v2 (Phase 11)

| Route | Who | Guarded by |
| --- | --- | --- |
| `GET /admin/overview` | every operator | `overview.read` |
| `GET /admin/audit`, `GET /admin/audit/export` | owner, admins | `audit.read` (moderators lost it in migration 015) |
| `GET /admin/alerts`, `POST /admin/alerts/:alertId/{lift,review}` | owner, admins | `alerts.manage` + `@GraphExempt` |
| `GET /admin/sessions`, `POST /admin/sessions/{revoke-others,:sessionId/revoke}` | every operator | `dashboard.access` + `@DashboardSession`; the service limits non-owners to their own sessions and answers 404 otherwise |

Reviewing an alert with `suspend: true` goes through `AdminUsersService.suspend`, so admin-policy's
who-may-act-on-whom rules apply exactly as they do on the Users page.

Abuse limits are rate limiting (Redis), not authorization. Nothing about who may do what is cached.

## Tests

| Command | Suite | Needs |
| --- | --- | --- |
| `npm test` | 110 unit tests (config, redaction, logger, filter, validation, auth crypto, rate-limit guard) | nothing |
| `npm run test:db` | 91 schema-invariant tests (incl. the key directory) | Postgres up |
| `npm run test:app` | 216 tests: guards, the key directory, real libsignal devices end to end (`crypto-e2e`, needs `cargo build -p skyline_e2e` or it is skipped), real-token authentication, WebSocket fan-out, audit, rate limits, CLI tools, admin API and owner protection, dashboard cookie and CSRF, route inventory | Postgres + Redis up |
| `npm test` in `apps/dashboard` | 18 dashboard tests (API client, sign-in and 2FA, must-change lock, create user, contact graph, owner read-only) | nothing |

`test:db` and `test:app` build a throwaway database per suite and drop it afterwards. The core
protections were **mutation-tested**: deliberately breaking each (graph filter off, guard off, suspended
still active, revoked device accepted, 404 leaking a message) makes the suite fail, so a green run means
something. Phase 5 added eight more: refresh accepting any signature, reuse detection off, activation
skipping the signature check or letting a suspended account in, a phone accepted on operator routes, a
replayable 2FA code, a suspended admin signing in, a password change leaving other sessions alive. All
eight were caught.

## Known gaps, stated plainly

- **Rate limiting is per address, and every address looks the same behind a proxy.** `trust proxy` is unset,
  so once Nginx is in front (Phase 13) every request will seem to come from it and share one counter. Set
  `trust proxy` to the proxy's address then, or the limits become a denial of service.
- **A benign double refresh looks like theft.** If a flaky network makes a device retry a refresh whose
  first attempt actually succeeded, the retry presents an already-rotated token and the session is revoked;
  the device must re-activate. Standard behaviour for rotating tokens, but the Phase 7+ client must avoid
  blind retries of `/auth/refresh`.
- **Timing across the whole activation path is not measured.** A malformed request returns before the
  database; a well-formed wrong code does one query. Neither reveals anything about valid codes, but the
  uniformity of timing is asserted by design, not by test.
- **Timing is not measured.** An unlinked id and a nonexistent id take slightly different SQL paths. The
  difference is sub-millisecond and untested; a determined attacker with many samples is not ruled out.
- **`trust proxy` is not set**, so `req.ip` is the proxy's address until Phase 13 puts Nginx in front.
- **Archived groups** are still reachable by their members (`archived_at` is not checked). Undecided.
- **A suspended user is still visible** to their contacts; only *deleted* accounts vanish. Undecided.
- **Redaction is by field name.** A secret inside a free-text value is not detected.
- **Two extra queries per request** (account, then graph) is the accepted cost of "no caching". Measure
  before optimising, and never optimise by caching authorization.
