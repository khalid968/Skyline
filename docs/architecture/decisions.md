# Decision Log

Append-only. Each entry records what was decided, when, and why. Do not re-litigate a decision here
without the project owner's explicit say-so; if you believe one is wrong, raise it rather than quietly
working around it.

---

## 2026-09-21 — Migrations are plain SQL run by `node-pg-migrate`. No ORM.

**Decision.** `node-pg-migrate` in `-j sql` mode. Migrations are `.sql` files with `-- Up Migration`
and `-- Down Migration` sections, in `apps/backend/src/database/migrations/`.

**Why.** The backend already uses raw `pg` and plain JavaScript, both locked decisions. This schema's
security properties live in partial indexes, CHECK constraints and triggers — things an ORM either
hides, generates badly, or cannot express. Plain SQL keeps them reviewable, which for this project
matters more than developer convenience.

---

## 2026-09-21 — Nothing is hard-deleted.

**Decision.** Accounts are soft-deleted (`status = 'deleted'` plus `deleted_at`). Devices, sessions,
push tokens, contact links and group memberships are revoked, never removed. `username_history.user_id`
is `ON DELETE RESTRICT`, so `DELETE FROM users` fails by design.

**Why.** Partly principle — an audited system should not let operators erase history — and partly
because it is the only way the never-reissue-a-username guarantee stays true. It also resolved a bug:
four foreign keys were `ON DELETE SET NULL` on columns that CHECK constraints require to be non-null,
so deleting a device would have failed with a confusing constraint violation. Making them `RESTRICT`
turns an accidental failure into an intentional rule.

**Consequence.** The dashboard's "Delete account" is a soft delete. If a hard delete is ever genuinely
required (a legal erasure request, say), it needs a deliberate, audited procedure — not a `DELETE`.

---

## 2026-09-20 — Activation codes are strictly single use.

**Decision.** An activation code is redeemable **exactly once**, binds to the one device that redeems
it, and is dead thereafter. Issuing a replacement creates a new code and never revives a spent one.
Codes also expire after 72 hours unredeemed.

**Why.** Requested by the project owner. A reusable code is a shared secret that silently turns into a
second way into an account — it defeats the point of manual provisioning.

**Implementation requirements (Phase 3 schema / Phase 5 auth), not optional:**

- `activation_codes` stores a **hash** of the code, never the code itself. It is shown once, at
  creation, and is unrecoverable afterwards.
- Redemption is a single atomic transaction: `UPDATE ... SET redeemed_at = now(), redeemed_by_device_id = $1
  WHERE id = $2 AND redeemed_at IS NULL` and the code is spent only if that statement affects one row.
  A `UNIQUE` partial index enforces it at the storage layer too. **Do not implement this as
  check-then-write** — that races, and two devices could redeem the same code concurrently.
- A spent or expired code returns the same generic failure as a nonexistent one, with no timing
  difference. Distinguishing them lets an attacker enumerate valid codes.
- Redemption attempts are rate limited per source and written to the audit log.

---

## 2026-09-20 — Administrators can rename any user; renames are announced and never touch keys.

**Decision.** An admin can change any user's **display name** and **username** from the dashboard.
Three constraints ship with the capability:

1. Every rename is written to the audit log with the old value, the new value, the acting admin, and a
   timestamp.
2. Every rename is announced as a system message inside each conversation the renamed user is part of
   ("Admin changed this contact's name from X to Y").
3. A rename **never** alters identity keys. Safety numbers a contact has already verified stay valid,
   and no re-verification prompt is triggered.

**Why.** The rename itself was requested by the project owner. Constraints 1–3 are mine, and they close
a real hole: in a network where users cannot search or independently confirm who anyone is, an admin who
could silently rename "Daniel Okonkwo" to "Sarah Whitfield" could socially impersonate one user to
another. The audit entry plus the in-chat announcement makes that loud instead of silent. Keeping keys
untouched means the cryptographic identity remains the thing users actually verify — the display name is
explicitly cosmetic.

**Also:** a released username is never reissued to a different account, so an old handle cannot be
inherited by someone else.

---

## 2026-09-20 — v1 ships on iOS, Android and Windows. Web is dropped for the messaging client.

**Decision.** The Flutter client targets iOS, Android and Windows for v1. macOS and Linux are cheap
follow-ons from the same codebase but are not promised. The **Web messaging client is out of scope**.

**Why.** Skyline's E2EE depends on Signal's official `libsignal-client` Rust crate, and there is no
official WebAssembly build of it. Signal's own tracking issue for a WASM target
(<https://github.com/signalapp/libsignal/issues/350>) is open, and their earlier JavaScript
implementation is archived and explicitly unmaintained. The remaining options are community WASM
wrappers and an academic reimplementation — none audited by Signal. Shipping a browser client on any of
those would break the project's founding rule: **no unaudited cryptography, ever**. Rather than weaken
the guarantee for browser users or ship a second, unproven crypto path, Web is deferred until an
official WASM target exists.

**Consequence.** `known-risks.md`'s open Web/WASM risk is closed as *deferred by scope*, not solved.
Revisit only if Signal ships an official WASM build.

---

## 2026-09-20 — Admin tooling is a separate web application, not in-app admin screens.

**Decision.** Administration lives in a dedicated browser-based dashboard, served separately from the
messaging client. The scaffolded `apps/mobile/lib/features/admin/` directory is **not** the admin
surface and should be removed or repurposed when Phase 6 starts.

**Why.** Keeping admin code out of the binary that end users install removes the admin UI, its routes
and its endpoints from every user device — a meaningful reduction in attack surface for a product whose
entire value is containment. It also gives admins a screen size suited to managing a contact graph.

**Note.** This is web, but it is *safe* web: the dashboard manages identities, links and permissions and
never holds message keys or plaintext, so the WASM problem above does not apply to it.

---

## 2026-09-20 — Contacts are fully locked: no discovery, no user-created groups, no request flow.

**Decision.** Option "fully locked". Admins assign every contact link and every group membership. Users
cannot search, browse, discover, or request. See `contact-graph.md` for the full specification.

**Why.** Chosen by the project owner. A contact-request flow was offered and declined for v1; it can be
added later without changing the schema.

**Consequence.** The contact graph moved from Phase 9 to Phase 3 — it is an authorization invariant
every endpoint must satisfy, not a late-stage admin feature.

---

## 2026-09-20 — Design is approved as prototypes before code, every phase.

**Decision.** Added Phase 2 (Product design) and a standing rule in `design.md`: no user-visible surface
is implemented before the project owner approves a prototype of it.

**Why.** Requested by the project owner. The original 11-phase roadmap contained no design phase at all.

---

## Carried over from Phase 1 (unchanged, do not re-litigate)

- Backend is **NestJS in plain JavaScript, not TypeScript**.
- **PostgreSQL** is the system of record; Redis is WebSocket fan-out, presence and rate limiting only;
  MinIO holds encrypted media blobs.
- **E2EE is the Signal Protocol via the official `libsignal-client` crate**, wrapped in `crypto-core`
  and exposed to Flutter through `flutter_rust_bridge`. Never write custom cryptography — not protocols,
  not primitives.
- **Riverpod** for state and DI; **go_router** for navigation; **Material 3**.
- **Native WebSocket** (`@nestjs/platform-ws` + `ws`), not Socket.IO.
- Single-host **Docker Compose** deployment; backend instances stay stateless.
- The server handles only ciphertext and minimal routing metadata. Private keys never leave the device.
  No analytics, telemetry or third-party trackers, ever.
