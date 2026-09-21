# Database Schema

PostgreSQL 16+. Migrations live in `apps/backend/src/database/migrations/` and run with
[`node-pg-migrate`](https://github.com/salsita/node-pg-migrate) in plain-SQL mode.

```bash
cd apps/backend
cp .env.example .env          # set DATABASE_URL
npm run migrate:up            # apply
npm run migrate:down          # roll back one
npm run migrate:create -- add-something   # scaffold a new migration
```

Migrations are numbered by timestamp prefix and applied in filename order.

| # | Migration | Contents |
| --- | --- | --- |
| 001 | `extensions-and-enums` | `pgcrypto`, `citext`, all enum types, `set_updated_at()` |
| 002 | `roles-and-permissions` | `roles`, `permissions`, `role_permissions` + seed data |
| 003 | `users-and-usernames` | `users`, `username_history` + the rename trigger |
| 004 | `devices-sessions-push` | `devices`, `device_sessions`, `push_tokens` |
| 005 | `activation-codes` | `activation_codes`, the single-use trigger, `redeem_activation_code()` |
| 006 | `contact-graph` | `groups`, `group_members`, `contact_links`, `are_linked()`, `visible_user_ids()` |
| 007 | `chats-and-messages` | `chats`, `messages`, `message_envelopes`, `attachments` |
| 008 | `audit-log` | `audit_log` + append-only triggers |

---

## The four invariants the schema enforces structurally

These are enforced by the database, not by application code, because application code forgets.

### 1. Contact links are symmetric and admin-granted

`contact_links` stores each pair once in canonical order, guarded by
`CHECK (user_a_id < user_b_id)`. There is no direction column and no way to express "A can reach B but
B cannot reach A". Look a pair up with `(LEAST(a,b), GREATEST(a,b))`, or just call `are_linked(a, b)`.

A partial unique index allows **one live link per pair** while letting revoked rows accumulate as
history, so a pair can be granted, revoked and re-granted without losing either record.

`visible_user_ids(user)` returns everyone a user may act on: live contacts plus anyone sharing a live
group. **Phase 4's guard is built on this function.** Anything outside the set is a `404`, never a
`403` — a `403` confirms the target exists and leaks the directory the design exists to hide.

### 2. Activation codes are single use

- `code_hash` is `HMAC-SHA256(server pepper, normalized code)` — deterministic so it can be indexed,
  keyed so a database leak alone yields nothing redeemable. The code itself is shown once at creation
  and is never stored. A slow KDF is deliberately not used: codes carry 128 bits of entropy, so there
  is nothing to brute force.
- A partial unique index permits **at most one live code per user**.
- `activation_codes_freeze_when_spent` is a `BEFORE UPDATE` trigger that refuses any change to
  `redeemed_at`, `redeemed_by_device_id`, `code_hash` or `user_id` once a code is spent. A buggy
  service cannot resurrect a code.
- **Redeem only through `redeem_activation_code(code_hash, device_id)`.** It is one atomic conditional
  `UPDATE` — the row is claimed or it is not, with no window between check and write. Do not
  reimplement it as `SELECT`-then-`UPDATE`; that races and two devices could redeem the same code.
  It returns the user id, or `NULL` identically for every failure: unknown, spent, revoked, expired.
  Callers must not distinguish between those in the response *or in the time taken*.

### 3. A username is never reissued

`username_history` holds every username ever assigned to anyone, with a **global** `UNIQUE`. The
`users_track_username` trigger writes to it on insert and on every rename. Renaming to a username that
has ever existed violates that `UNIQUE` and aborts the transaction, so the rename simply cannot happen.

### 4. The audit log is append-only

`audit_log` has `BEFORE UPDATE` and `BEFORE DELETE` triggers that raise. Corrections are recorded as
new entries. It deliberately carries **no foreign keys**: an audit record must outlive the rows it
describes, so ids are stored as plain uuids beside a snapshot of the name at the time.

---

## Nothing is hard-deleted

A consequence worth stating plainly, because it shapes every "delete" feature:

- `username_history.user_id` is `ON DELETE RESTRICT`, so a `DELETE FROM users` fails. Deletion is
  always soft — `status = 'deleted'` plus `deleted_at`. The username stays burned.
- `messages.sender_user_id`, `messages.sender_device_id`, `activation_codes.redeemed_by_device_id` and
  `attachments.uploaded_by_device_id` are also `RESTRICT`. They were originally `SET NULL`, which was a
  bug: the `messages_shape` and `activation_codes_redeemed_names_device` CHECK constraints require
  those columns to be non-null, so a device deletion would have failed with a confusing constraint
  violation rather than an intentional one.
- Devices are **revoked** (`revoked_at`), not deleted. Same for sessions, push tokens, contact links
  and group memberships.

The dashboard's "Delete account" is therefore a soft delete. This is the right model for an audited
system, and it is what keeps the never-reissued-username guarantee true.

---

## What the server deliberately does not store

The schema is as interesting for what is absent as for what is present.

- **No message body column.** `messages` holds routing metadata only. Content lives in
  `message_envelopes`, one ciphertext per recipient device, as the Signal Protocol requires. The
  server stores and forwards blobs it cannot decrypt.
- **No attachment metadata.** `attachments` has no filename, content type or dimensions — those are
  metadata and live inside the encrypted body. The blob's decryption key is carried in the message and
  is never stored server-side.
- **No plaintext reactions or receipts table.** Reactions travel as encrypted messages. Adding a
  `reactions(message_id, user_id, emoji)` table would leak content the server is not supposed to have.
  `delivered_at` / `read_at` on envelopes are the minimum metadata delivery actually requires.
- **No private keys, ever.** `devices.identity_key` is the *public* identity key.
- **No permission granting plaintext access.** Look at the seeded `permissions` rows: there is no
  `messages.read`, and there cannot be, because administrators never hold message keys.

`messages.system_event` is the one server-composed plaintext, and it is deliberate. It carries facts
the server already knows (an admin renamed someone, a device was added) and is what makes an admin
rename impossible to perform silently.

---

## Verification status

The migrations have **not been run against a live PostgreSQL** — Docker is not installed on the
development machine, so the dev data plane cannot start.

They have been parsed against the real PostgreSQL 18 grammar via `libpg-query`: all 113 statements
across both the up and down halves of all 8 files parse cleanly, and all seven function bodies
(five PL/pgSQL, two SQL) parse individually. That catches syntax errors and nothing else — it does
**not** verify that constraints behave as intended, that triggers fire correctly, or that the
migrations apply and roll back in order.

**Before relying on any of this:** install Docker Desktop, then

```bash
docker compose -f infra/docker/docker-compose.yml up -d
cd apps/backend && npm run migrate:up && npm run migrate:down && npm run migrate:up
```

The Phase 12 test obligations in `../architecture/contact-graph.md` are the real check.
