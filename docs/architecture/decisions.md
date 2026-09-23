# Decision Log

Append-only. Each entry records what was decided, when, and why. Do not re-litigate a decision here
without the project owner's explicit say-so; if you believe one is wrong, raise it rather than quietly
working around it.

---

## 2026-09-23 — Phase 6 prototypes approved; timer range; owner resets

**Approved by the owner:** design boards 9-15 (admin sign-in, 2FA code, account & 2FA setup, devices; mobile
Privacy & security, lock screen, disappearing-message timer), and both proposals shown with them:

- **The owner resets a locked-out admin's password or two-factor.** There is no self-service reset. The reset
  is audit-logged and signs the target out everywhere.
- **The v1 dashboard sidebar is Users, Contact graph, Devices** (groups and the audit viewer are v2).

**Disappearing-message timer (owner's change):** presets Off, 1 hour, 1 day, 1 week, 1 month, 3 months,
6 months, 1 year, plus **Custom: any duration from 5 minutes to 1 year** (minutes, hours, days, weeks or
months). The schema already enforces 5 seconds to 1 year (`chats.disappear_seconds`), so no migration is
needed; the client offers 5 minutes as its shortest. Longer than a year would need a schema change and the
owner's say-so.

---

## 2026-09-23 — Phase 6 (admin dashboard v1) scope and stack

**Decided by the owner:**

1. **React, plain JavaScript** for `apps/dashboard/`, matching the backend's language.
2. **v1 scope: users and activation codes, the contact-graph editor, and devices**, plus sign-in, 2FA and
   account settings. **Groups and the audit-log viewer move to v2 (Phase 11).** Consequence: until then,
   members can only have one-to-one chats, since groups can only be created by an admin.
3. **A protected owner account.** The owner (the first admin, created by `admin:create`) cannot be demoted,
   suspended, renamed or deleted by another admin, and only the owner can create, promote or remove admins.
   Needs a schema marker (e.g. `users.is_owner`, at most one) enforced in the database, not just the UI.
4. **The mobile Privacy & security screen** (app lock, disappearing-message timer) is prototyped in the same
   design round.

**Decided by the agent (reversible):** the dashboard keeps its session in an **HttpOnly, Secure, SameSite=Strict
cookie**, not a token readable by JavaScript, so a malicious script on the page cannot steal an admin session.
Requires CSRF protection on state-changing requests.

**Process:** screens not yet approved (sign-in, 2FA code entry, account/2FA setup, device list, the mobile
Privacy & security screen) are prototyped and approved before any code.

---

## 2026-09-23 — Phase 5 authentication model

**Decided by the owner:**

1. **Members have no password.** The one-time activation code is the only way in; afterwards the device
   holds the credential. No recovery codes: a lost phone means an administrator issues a new code. App
   lock (PIN/biometric) protects the phone locally.
2. **Administrators sign in to the dashboard with a password; two-factor (TOTP authenticator app) is an
   optional step each admin may turn on.** Chosen for simplicity at the start. Known trade-off: an admin
   who skips 2FA is protected by the password alone, and admins control the whole contact graph. Mitigated
   by Argon2id hashing and rate limiting. Easy to make mandatory later.
3. **Each device registers an Ed25519 signing key at activation** (Node's built-in, vetted implementation
   — no custom crypto) and must sign every token refresh with it, so a stolen refresh token alone is
   useless. `devices.identity_key` and `devices.registration_id` (the Signal Protocol fields) become
   nullable until Phase 7 fills them.

**Decided by the agent (cheap to reverse, listed so the owner can object):**

- **Tokens are opaque random strings**, stored only as HMAC-SHA256 hashes under a server pepper, and looked
  up in Postgres on every request, consistent with the no-caching rule. A JWT would buy nothing here and
  could not be revoked instantly. Device access tokens last 15 minutes; refresh tokens 30 days and rotate
  on every use, and presenting an already-rotated refresh token revokes the whole session (theft detection).
- **Operator routes accept only a dashboard session; member routes accept only a device session.** This
  enforces the locked decision that admin tooling is separate from the app: even an admin's own phone
  cannot call operator APIs.
- **Rate limiting fails closed** on the authentication endpoints: if Redis is down, activation and login
  are refused rather than left unthrottled.
- **Activation codes are 100 bits** (20 Crockford base32 characters, `SKY-XXXXX-XXXXX-XXXXX-XXXXX`), not
  the 128 the schema comment assumed. With a keyed hash, rate limiting and a 72-hour expiry, 100 bits is
  far beyond guessable, and it is shorter to type.

---

## 2026-09-21 — The WebSocket is server-to-client only; clients send over REST

**Decision.** The gateway ignores every inbound frame. Clients send messages over authenticated REST, and
receive over the socket.

**Why.** REST is where the three guards run per request. If a client could also send by writing to the
socket, every guard would have to be reimplemented there, and any gap would be a way to bypass the contact
graph. One-directional removes the whole class. Delivery still re-checks the graph at the moment it
happens, so revoking a link stops an already-open socket immediately.

---

## 2026-09-21 — Authorization is checked against Postgres on every request; it is never cached

**Decision (owner).** Account status, device revocation, role permissions and the contact graph are read
from PostgreSQL on every request, and by the WebSocket fan-out on every delivery. No Redis or in-process
cache.

**Why.** A cache makes each of these wait for expiry: a suspended user keeps working, a revoked device
keeps connecting, a revoked contact keeps receiving. For a product whose value is containment that is the
wrong trade. The cost is two extra queries per request, accepted at this scale.

**Consequence.** Measure before optimising, and never optimise by caching authorization. If load ever
demands it, prefer a faster query or a read replica over a cache.

---

## 2026-09-21 — DECIDED: true E2EE for v1; a disclosed compliance archive is a possible later mode

**Status: RESOLVED by the owner on 2026-09-21 — option 3 below.** v1 ships with true end-to-end
encryption; admins never see message content. A disclosed compliance archive may be designed later as an
opt-in deployment mode. **Nothing archive-related is built now**, and the locked rule "admins can never
read messages" stands for v1. Revisiting it needs the owner's explicit go-ahead and its own design phase
(key management, access audit, threat model) *before* Phase 7 (Encryption). The analysis that led to this
decision follows.

**The request.** "Give the admin the power to view all messages and media and have a history of
everything."

**Why it is escalated rather than built.** It contradicts, directly, a locked decision and a core design
property: admins can never read messages (`contact-graph.md` rule 7). The server holds only ciphertext;
private keys never leave devices; the seeded `permissions` table deliberately has no permission that
could grant plaintext. Implementing this is not a feature toggle. It changes what kind of product Skyline
is. Per the project rules that call is the owner's, not an agent's.

**What an admin can already see (the "history of everything" that needs no change).** The audit log of
every admin action; account, device, session and activation-code history; the full contact-link and
group-membership history; and message *metadata* (who, which chat, when, ciphertext size). Everything
except the content.

**Options put to the owner:**

1. **Keep true end-to-end encryption.** Admins get all of the above, never content. Strongest security
   claim; simplest; the position the whole design and prototype assume.
2. **A disclosed compliance archive.** Every message and attachment is *additionally* encrypted to an
   organization archive key, held by a designated compliance role and used under audited, ideally
   dual-control access. Users are told plainly and permanently. This is a real enterprise category, but it
   is a different product claim: it is no longer end-to-end between the two people, and the archive key
   becomes the single most valuable secret in the system.
3. **Ship option 1 now; design option 2 later as an opt-in deployment mode**, so the core stays clean.

**Constraints that apply to any version of option 2, so they are recorded before the choice is made:**

- **It must be disclosed to users**, in the app, permanently, not buried in terms. Reading people's
  messages without their knowledge is deceptive and, in many jurisdictions, unlawful. An agent will not
  build a covert variant.
- **It defeats disappearing messages** (below). If the archive retains everything, "messages delete
  automatically" is false for the archive, and the UI must not claim otherwise.
- It needs its own key management design, access audit log and threat model before any code.
- It re-opens the locked decisions "admins can never read messages" and "server holds only ciphertext",
  which must then be explicitly revised, not quietly bypassed.

---

## 2026-09-21 — ACCEPTED: PIN / biometric app lock (prototype required before code)

**Request (owner).** Users can protect the app with a PIN, Face ID or fingerprint.

**Design constraints:**

- **Purely local.** Biometric matching is done by the operating system (Face ID / Touch ID, Android
  BiometricPrompt, Windows Hello). The app never receives biometric data. The PIN never leaves the
  device and is never sent to the server.
- **It must gate the keys, not just cover the screen.** Store device key material in the platform
  keystore (iOS Keychain, Android Keystore, Windows DPAPI/Hello) flagged as requiring user
  authentication. A lock screen drawn over an unlocked app is decoration, not security.
- Escalating lockout delays after wrong PINs. An optional "erase after N failures" is destructive and
  strictly opt-in.
- **An administrator can neither see nor reset a user's PIN.** A forgotten PIN means the on-device keys
  are unrecoverable: the user re-activates with a fresh activation code and loses local history. The
  server never held a copy, so this is unavoidable and must be said plainly in the UI.
- **Decided (owner, 2026-09-21): app lock is always the user's own choice.** There is no admin policy
  to force it on. This also keeps the admin surface smaller: no policy setting, and one less thing an
  admin can do to a user's device.

Lands in Phase 5 (Authentication). It is UI, so a settings prototype is needed first.

---

## 2026-09-21 — ACCEPTED: user-set disappearing messages, with honest limits

**Request (owner).** Users choose how long until messages are deleted from the device automatically.

**Design.**

- A per-chat timer. The schema already supports it: `chats.disappear_seconds` (5 seconds to 1 year) and
  `messages.expires_at`.
- The client deletes its local copy at expiry. The server deletes ciphertext envelopes once delivered or
  expired.
- **Changing the timer is announced as a system message in the chat**, for the same reason a rename is:
  a silent change would let one party quietly shorten the other's retention.
- Recommended: the timer starts when the message is **read**, not sent (as in Signal).
- **Honest limits, and the UI must not overpromise:** it cannot be enforced against a modified client, a
  screenshot, or a photograph of the screen. It deletes cooperatively-run copies, nothing more.
- **Open questions:** who may set the timer in a group (groups are admin-managed, so likely admin-set);
  whether an admin may impose an organization-wide minimum or maximum.
- **Conflicts with the pending decision above.** If a compliance archive exists, disappearing messages do
  not apply to it.

Lands in Phase 8 (Messaging). It is UI, so a prototype is needed first.

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
