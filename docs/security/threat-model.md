# Threat model

Phase 12, 2026-09-26. This is the one place that says what Skyline defends against, how, and which test
proves it. It also says plainly what Skyline does **not** defend against. Update it whenever a
protection, a test, or an accepted risk changes.

Rows marked **Phase 12** were found while writing this document and are fixed in this phase. Rows marked
**Phase 13** belong to deployment.

---

## What we protect

| Asset | Where it lives | Who may see it |
| --- | --- | --- |
| Message, media and call content | Only on the devices of the people in the conversation. The server holds ciphertext for at most 30 days (media) or until delivery (messages). | The people in the conversation. **Never operators**, never the server. |
| Private keys (Signal identity, prekeys, sender keys, device signing key) | The device's encrypted vault (`crypto-core`) | That device only |
| The contact graph (who is linked to whom, who is in which group) | Postgres | Operators, and each member for their own links. Nobody else may learn that anyone else exists. |
| Metadata (who messages whom, and when; device list; last seen) | Postgres, in memory while delivering | The server by necessity; operators see only totals and account-level facts, never per-person activity |
| Activation codes | Printed once; stored only as an HMAC | The person the code is for |
| Operator credentials and sessions | Argon2id hash; HMAC'd tokens; HttpOnly cookie | That operator |
| The audit log | Postgres, append-only | Owner and admins |
| Availability | Everything | Everyone |

## Who might attack, and what they can already do

| # | Actor | Starting position |
| --- | --- | --- |
| A1 | Outsider | Can reach the server's public address. No account. |
| A2 | Network attacker | Sits on the path: café Wi-Fi, an ISP, a hostile network. |
| A3 | Curious or hostile member | Has an activated device and a set of links. |
| A4 | Rogue moderator or admin | Has a dashboard account with its role's permissions. |
| A5 | Compromised server | Root on the host: can read and change the database, the code and the traffic after TLS. |
| A6 | Relay (coturn) operator | Sees relayed call packets. |
| A7 | Push provider (Google FCM, later Apple APNs) | Sees wake-ups sent to device tokens. |
| A8 | Thief or finder of a device | Physical access to an unlocked or locked phone or PC. |
| A9 | Supply chain | A malicious or vulnerable dependency, container image or build step. |

---

## Threats, protections and proof

Each row gives the threat, the protection that answers it, and the test that proves the protection
holds.

### A1 · Outsider

| Threat | Protection | Proof |
| --- | --- | --- |
| Guess an activation code | 100-bit codes. Stored as HMAC only, single use (one atomic `UPDATE` and a unique partial index). The rate limit is 10 per 15 min per address. Abuse detection blocks an address for 1 h after 8 wrong codes. | `test/db/activation-codes`, `rate-limit-and-cli`, `dashboard-v2` |
| Tell spent, expired and nonexistent codes apart | The same 401, from the same code path | `authentication.e2e-spec`, `timing.e2e-spec` |
| Guess an operator password | Argon2id, optional TOTP. Limits per address and per username. The sign-in pause answers exactly like a wrong password. | `admin-api`, `dashboard-v2` (the pause is indistinguishable) |
| Learn which usernames are operators | An unknown username still pays a full Argon2 verification, and the answer is the same 401 | `admin-api`, `timing.e2e-spec` |
| Call member routes without a session | Global guards, default deny, 401 | `authorization.e2e-spec`, route inventory, `authorization-matrix.e2e-spec` |
| Flood the server | Rate limits that fail closed (Redis down means 503, not unlimited). Body size limits. | `rate-limit-and-cli`, `http-behaviour` |
| Probe the stack | No `x-powered-by`. Health says only up or down. Errors are uniform and generic. | `http-behaviour` (security headers on every response) |
| Use the call relay as an open proxy | Short-lived HMAC credentials that require a device session | `calls.e2e-spec`; denying private ranges in production: **Phase 13** |

### A2 · Network attacker

| Threat | Protection | Proof |
| --- | --- | --- |
| Read or alter traffic | TLS to Nginx (**Phase 13**). Content is end-to-end encrypted regardless, so the network sees only ciphertext. | `crypto-e2e`; `untrusted_input.rs` (tampered messages never decrypt to anything else) |
| Swap keys in transit (man in the middle) | Strict identity trust: a changed identity is blocked, never silently accepted. Safety numbers with QR verification. | Rust `core` tests (identity trust), `key-directory` |
| Read call media | DTLS-SRTP. The fingerprints travel inside Signal-encrypted messages, so the relay or the network cannot sit in the middle. | `calls_test` (relay only, both directions) |
| Forge dashboard actions (CSRF) | The session cookie is SameSite=Strict. Every cookie-authenticated change needs `x-skyline-client`. There is no CORS. | `admin-api` |
| Clickjack the dashboard | The API sends `frame-ancestors 'none'` and `X-Frame-Options: DENY`. The dashboard build carries a strict CSP; Nginx adds frame-ancestors for the dashboard (**Phase 13**). | `http-behaviour`, CI (the built page is self-contained) |

### A3 · Member

| Threat | Protection | Proof |
| --- | --- | --- |
| Find people they are not linked to (the product's core promise) | There is no search and no directory. Any id outside the graph answers **404, not 403**. Every check hits Postgres, with no cache. | `authorization.e2e-spec`, `test/db/contact-graph`, route inventory, `authorization-matrix.e2e-spec` |
| Tell an unlinked id from a nonexistent one | The same 404, in the same time | `authorization-matrix`, `timing.e2e-spec` |
| Message or call someone after their link is revoked | The graph is checked on every send and again at delivery, and open sockets stop at once | `fanout.e2e-spec`, `messaging.e2e-spec` |
| Read a group after being removed | Sender keys rotate when anyone leaves. A re-added member does not collect old envelopes. | `groups.e2e-spec`, `groups_test` |
| Impersonate someone by display name | Only operators rename. Renames are audited and announced, and identity keys never change. | `admin-api` |
| Download someone else's media | Downloads are graph-checked. Object names are random. Files are ciphertext with the key inside the message. | `media.e2e-spec` |
| Spam or flood contacts | Send limits, plus abuse detection that slows the device | `dashboard-v2` |
| Edit or delete another person's message | Receivers enforce authorship and time windows | `actions_test` |

### A4 · Rogue operator

| Threat | Protection | Proof |
| --- | --- | --- |
| Read messages | No permission grants plaintext, and none can: the server never holds keys | db test "no permission grants plaintext", `crypto-e2e` |
| Quietly link themselves to someone to read along | A link lets them message the person. It gives no access to past or other conversations. Every link is audited. | `admin-api`, audit log |
| Add a device to someone's account to receive their messages | Devices only arrive with activation codes. Issuing a code is audited. Contacts see a "new device" notice in the chat and must verify it. The device burst alert fires. | `admin-api`, `dashboard-v2`, board 17 |
| Take over or demote the owner | A database trigger, plus `admin-policy.js` | `admin-api`, db tests |
| Cover their tracks | The audit log is append-only at the database (UPDATE, DELETE and TRUNCATE are refused). Moderators cannot read it. | db `identity-and-audit`, `dashboard-v2` |
| Watch individual activity | The overview is totals only. `usage_daily` has no per-person column. | `dashboard-v2` (schema check) |
| Lock out another operator | Only the owner manages admins. A sign-in pause can be lifted. | `admin-api` |

### A5 · Compromised server

This is the hardest actor. The design limits what a full compromise yields, but it cannot prevent the
compromise.

| Threat | Protection | Proof, or residual risk |
| --- | --- | --- |
| Read stored messages and media | Only ciphertext exists. Messages are erased on delivery; media is deleted at 30 days. | `crypto-e2e` |
| **Ghost device**: add a device to a user's directory so senders encrypt to it | Senders see a "new device" notice in the chat. Safety numbers are per device; the header shows "N devices not verified". | **Residual.** A server that adds a device receives messages sent before anyone checks. This is the same limit Signal and WhatsApp accept. Mitigation: verify safety numbers; watch the new-device notices. |
| Relabel the sender of a session-starting message | Fixed in Phase 7: the sender is bound to the directory identity | `key-directory` (see known-risks, closed) |
| Learn who talks to whom, and when | Nothing: the server routes messages, so it knows | **Residual.** Sealed sender is not implemented. Written up in known-risks. |
| Change the code to exfiltrate keys | Out of scope for the server: keys never leave the device. A tampered **app** is a supply-chain risk (A9). | — |
| Bypass the database triggers | The application's database role must not own the tables or be a superuser | **Phase 13** (deployment: a separate migration role) |

### A6 · Relay operator

| Threat | Protection | Proof, or residual risk |
| --- | --- | --- |
| Listen to calls | DTLS-SRTP end to end | `calls_test` |
| See who calls whom | Relay usernames are random and name no one. The relay sees both IP addresses and the timing. | **Residual**, documented in known-risks |

### A7 · Push provider

| Threat | Protection | Proof, or residual risk |
| --- | --- | --- |
| Read message content | Wake-ups carry no content, not even the sender | `push.e2e-spec` |
| Learn when a device receives something | Unavoidable while push is used | **Residual** |

### A8 · Lost or stolen device

| Threat | Protection | Proof, or residual risk |
| --- | --- | --- |
| Read history on the device | The vault is encrypted, with its key in the OS keystore. The app lock (PIN or biometrics) is optional, the user's choice. | Rust vault tests. **Residual:** without an app lock, an unlocked phone shows messages. |
| Keep receiving messages | An admin revokes the device; that is immediate, including open sockets | `fanout.e2e-spec`, `admin-api` |
| Clone the device's credential | The refresh token is signed by the device key and rotates; reuse revokes the session | `authentication.e2e-spec` |

### A9 · Supply chain

| Threat | Protection | Proof |
| --- | --- | --- |
| A vulnerable dependency | Lockfiles are committed. CI fails on any moderate or worse npm advisory, and runs `cargo audit`. Fixed on 2026-09-26: multer, qs and @babel/core. | CI `security` job |
| A tampered container image | coturn is pinned by digest. MinIO is built from source at a checked commit. GitHub Actions are pinned to commits. | `infra/docker/minio/Dockerfile`, `ci.yml` |
| A committed secret | `.env` and Firebase files are gitignored. gitleaks scans the whole history on every push (the history is clean). | CI `security` job |
| Third-party requests that leak users' or operators' addresses | No analytics or trackers. The app bundles its fonts. The dashboard's fonts are served by the dashboard itself (they had come from Google). | CI (the built page is self-contained), CSP `font-src 'self'` |

---

## Phase 12 actions found here: all done (2026-09-26)

1. Security headers on every API response, and a strict CSP for the dashboard build.
2. The dashboard's fonts are self-hosted: no request leaves for Google.
3. The authorization matrix: every route × every kind of caller.
4. Statistical timing tests.
5. Dependency audits and secret scanning in CI. MinIO is built from source at a pinned commit.
6. Found while building: sends to a suspended person used to be queued. They are now refused (board 40).

## Accepted residual risks (written up in `known-risks.md`)

- A compromised server can add a ghost device (above).
- The server knows the metadata: who talks to whom, and when.
- The relay and the push provider see timing and IP addresses.
- A phone without an app lock shows its messages to whoever holds it unlocked.
- View once is a courtesy, not a guarantee.
- A closed app does not ring.
- A shared address (an office NAT) that guesses codes is blocked as a whole for an hour. An operator can
  lift the block.
