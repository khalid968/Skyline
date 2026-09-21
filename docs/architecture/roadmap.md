# Development Roadmap

Skyline is built in phases. Each phase gets its own plan, ends with a written summary, and stops for
explicit approval before the next begins — nothing in a later phase is started early.

**Every phase that produces user-visible surface area is prototyped and approved before it is coded.**
See `design.md` for the standing design-review rule.

---

## Phase order

1. **System architecture** — ✅ complete. Project identity, tech stack decisions, monorepo scaffolding,
   local dev environment. No feature logic.

2. **Product design** — ✅ approved 2026-09-20 (a Privacy & security settings screen is still owed, see below). Visual language (type, colour,
   spacing, iconography), core mobile screens, admin dashboard screens. Clickable prototype on the
   design canvas (`design.md`). No code.

3. **Database & the contact graph** — ✅ verified 2026-09-21 against live Postgres. Full normalized PostgreSQL schema, migrations, indexes,
   constraints. **This is where the admin-controlled contact graph is defined** (`contact-graph.md`);
   it is a data-model invariant, not an admin feature, so it lands before any endpoint exists.

4. **Backend foundation & authorization core** — ✅ built 2026-09-21, awaiting review (rate limiting deferred to Phase 5). NestJS conventions: DTO validation, error handling,
   logging, health checks, base guards/interceptors/filters, WebSocket gateway skeleton. Includes the
   contact-graph guard that every downstream endpoint composes with.

5. **Authentication & invites** — admin-issued activation codes, username auth, device authentication,
   PIN / Face ID / fingerprint app lock gating the on-device keys (`decisions.md`), recovery codes, session/device binding. No public registration path exists at all.

6. **Admin dashboard (v1)** — separate web app. User creation, activation codes, the contact-graph
   editor, group membership, device list. **This is a hard prerequisite for using Skyline**: accounts
   are created by hand and contacts are assigned by hand, so nobody can sign in until this ships.

7. **Encryption** — `libsignal-client` in `crypto-core`, `flutter_rust_bridge` bindings, on-device key
   generation and storage, X3DH session establishment, Double Ratchet messaging, safety numbers.

8. **Messaging** — private chats, group chats, replies/threads, edit/delete, typing/read/delivered
   receipts, pinned messages, search, reactions, mentions, drafts, archive/mute, disappearing messages.
   Forwarding and "new chat" are constrained by the contact graph, not by user search.

9. **Media** — image/video/audio/document sharing, voice messages, media gallery, client-side
   encryption before upload, MinIO storage, compression and lazy loading.

10. **Calls** — WebRTC voice/video calls and screen sharing, E2EE call signaling and media.

11. **Admin dashboard (v2)** — audit logs, server/storage monitoring, active session management,
    remote device revocation, rate limiting, abuse detection, reporting.

12. **Testing & hardening** — unit, widget, integration, backend, API, security, and performance suites
    across client, server and dashboard. Threat model review.

13. **Deployment** — production Docker Compose, Nginx TLS, CI/CD, secrets management, automated
    backups, monitoring, logging, health checks, operator and admin guides.

---

## What changed from the original 11-phase plan, and why

| Change | Reason |
| --- | --- |
| Added **Phase 2 (Product design)** | The original plan had no design phase at all. Screens are now approved as prototypes before they are built. |
| **Contact graph pulled from Phase 9 → Phase 3** | "Users can only talk to admin-specified contacts" is an authorization invariant touched by every chat, message, search and group endpoint. Retrofitting it late would mean re-auditing every endpoint already written. |
| **Admin dashboard split: v1 → Phase 6, v2 → Phase 11** | Registration is manual and contacts are assigned by an admin, so the dashboard is a prerequisite for anyone using the product — it cannot be second-to-last. Monitoring and audit tooling can still come late. |
| Database moved ahead of backend foundation | The schema defines the invariant the guards enforce, so it is settled first. |

Phases are not started until the current phase is explicitly approved.

---

## Pending owner decisions that could change this plan

- **Admin access to message content — decided 2026-09-21** (`decisions.md`): true E2EE for v1. A
  *disclosed* compliance archive is a possible later opt-in mode. If the owner ever asks for it, it needs
  its own design phase and key-management workstream *before* Phase 7 (Encryption), and would revise two
  locked decisions. Nothing is planned or built toward it now.
- **Prototypes owed** for the accepted requests: a *Privacy & security* settings screen (app lock,
  disappearing-message timer). Not yet drawn.
