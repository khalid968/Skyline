# The Contact Graph

The single most important behavioural rule in Skyline, and the one that most distinguishes it from
Signal or WhatsApp.

> **A user can see, search, and message exactly the people and groups an administrator has explicitly
> linked to them. Nothing else in the system is visible to them — not even its existence.**

This is not a privacy setting and not an admin convenience feature. It is an authorization invariant
that every read and write path in the product has to satisfy.

## Rules

1. **No discovery.** There is no public directory, no user search across the organization, no "find by
   username", no contact import from the device address book, no QR-code add, no invite links between
   users. If a user is not linked to you, no API response may reveal that they exist.
2. **Links are created only by an administrator**, in the admin dashboard. There is no in-app request
   flow in v1 (this was considered and deferred — see `decisions.md`).
3. **Links are symmetric.** If A can message B, B can message A. A one-way link is not a supported
   state; the schema enforces this rather than leaving it to application code.
4. **Groups are admin-created.** Users cannot create groups, add members, or remove members. Group
   membership is assigned in the dashboard.
5. **A user with zero links is valid** and sees an empty app — no chat list, no search results, no
   directory. This is a normal state (a newly created account before links are assigned), not an error.
6. **Revocation is immediate.** When an admin removes a link, the conversation disappears from the
   user's devices on next sync and new messages in either direction are rejected. Ciphertext already
   delivered to a device stays on that device — the server cannot reach into it, and claiming otherwise
   would be a lie about the encryption model.
7. **Administrators are not exempt from encryption.** An admin can grant and revoke who talks to whom,
   and can suspend an account. An admin **cannot read message content** — they never hold the keys. Any
   future feature request that would let an admin read plaintext breaks the product's core promise and
   must be escalated to the user, never quietly implemented.

## Schema sketch (settled in Phase 3)

```
contact_links
  id             uuid pk
  user_a_id      uuid fk -> users(id)   -- ordered: user_a_id < user_b_id
  user_b_id      uuid fk -> users(id)
  created_by     uuid fk -> users(id)   -- the admin who granted it
  created_at     timestamptz
  revoked_at     timestamptz null
  UNIQUE (user_a_id, user_b_id)
  CHECK (user_a_id < user_b_id)         -- enforces symmetry: one row per pair, no direction
```

Storing the pair in a canonical order with a `CHECK` is what makes symmetry structural. A lookup is
`(least(a,b), greatest(a,b))`. Group membership lives in a separate `group_members` table with the
same "written only by an admin" rule.

## Enforcement (settled in Phase 4)

A single `ContactGraphGuard` resolves, per request, the set of principals the caller may act on, and
every controller that accepts a target user or chat ID composes with it. The rule for reviewers:

- **Default deny.** A new endpoint that takes a user, chat, group or message ID and does not go through
  the guard is a bug, even if it "only reads".
- **404, not 403**, for a target outside the caller's graph. A 403 confirms the target exists, which
  leaks the directory the whole design is meant to hide.
- WebSocket fan-out filters on the same set — a delivery event must never reach a device whose user is
  not linked to the sender.

## Test obligations (Phase 12)

At minimum, and these are the tests that must never be deleted:

- A user with zero links gets empty results from every list endpoint and 404 from every targeted one.
- Revoking a link mid-session stops delivery on the open WebSocket, not just on reconnect.
- No endpoint's error message, timing, or response shape distinguishes "does not exist" from
  "exists but is not linked to you".
- An admin account cannot retrieve message plaintext through any dashboard or API path.
