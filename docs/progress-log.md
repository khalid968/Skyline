# Progress Log

Append one entry per working session, newest at the top. This is the handoff record: an agent picking
up Skyline should read `CLAUDE.md` first, then the most recent entries here.

Each entry states what was decided, what changed on disk, and what the next agent should do. Do not
rewrite history in this file — append.

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
