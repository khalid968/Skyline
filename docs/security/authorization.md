# Authorization

How the backend decides who may do what, and how to add a route without breaking it. Read this before
writing any controller. The rule it protects is in [`contact-graph.md`](../architecture/contact-graph.md).

## The model: three global guards, default deny

Every HTTP route passes through three guards, registered globally in `app.module.js`, in this order:

| Order | Guard | Question | Failure |
| --- | --- | --- | --- |
| 1 | `AuthenticatedGuard` | Is there a principal, and is that account and device **still active right now**? | `401` |
| 2 | `PermissionsGuard` | Does the caller's role hold every permission this route requires? | `403` |
| 3 | `ContactGraphGuard` | Is every person, group or chat named in the path inside the caller's contact graph? | `404` |

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
5. **Jest needs `rootDir` at the backend root** for anything that imports `src/`. Otherwise Babel does not
   pick up `.babelrc` for source files and every decorator is a syntax error. (Already set in
   `test/jest-e2e.json`.)

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
- **Default deny.** `WS_AUTHENTICATOR` defaults to `DenyAllWsAuthenticator`, so until Phase 5 supplies a real
  one **nobody can connect**. A socket anyone can open is a way to receive other people's traffic.
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

## The Phase 5 seam

Authentication (turning a token into a principal) does not exist yet. Its contract with this layer:

- HTTP: set `request.principal = { userId, deviceId }`. `AuthenticatedGuard` does the rest, including
  re-checking the account and device against the database.
- WebSocket: provide a `WS_AUTHENTICATOR` returning `{ userId, deviceId }` or `null`.

Until then every non-public route answers `401`. **The tests fake the principal from headers
(`test/app/app-harness.js`). That fake must never exist in `src/`.**

## Tests

| Command | Suite | Needs |
| --- | --- | --- |
| `npm test` | 71 unit tests (config, redaction, logger, filter, validation) | nothing |
| `npm run test:db` | 75 schema-invariant tests | Postgres up |
| `npm run test:app` | 97 tests: HTTP guards, WebSocket fan-out, audit, route inventory | Postgres + Redis up |

`test:db` and `test:app` build a throwaway database per suite and drop it afterwards. The core
protections were **mutation-tested**: deliberately breaking each (graph filter off, guard off, suspended
still active, revoked device accepted, 404 leaking a message) makes the suite fail, so a green run means
something.

## Known gaps, stated plainly

- **Rate limiting is not implemented.** It was on the Phase 4 plan and is deferred to Phase 5, where it is
  needed first: throttling activation-code redemption is what stops code guessing.
- **Timing is not measured.** An unlinked id and a nonexistent id take slightly different SQL paths. The
  difference is sub-millisecond and untested; a determined attacker with many samples is not ruled out.
- **`trust proxy` is not set**, so `req.ip` is the proxy's address until Phase 13 puts Nginx in front.
- **Archived groups** are still reachable by their members (`archived_at` is not checked). Undecided.
- **A suspended user is still visible** to their contacts; only *deleted* accounts vanish. Undecided.
- **Redaction is by field name.** A secret inside a free-text value is not detected.
- **Two extra queries per request** (account, then graph) is the accepted cost of "no caching". Measure
  before optimising, and never optimise by caching authorization.
