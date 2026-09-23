# Design System & Review Process

## The standing rule

**No user-visible surface is coded before it is prototyped and approved by the project owner.**

Each phase that touches the UI ends with a prototype on the design canvas, presented for approval. Only
after approval does implementation start. Applies to the Flutter client and the admin dashboard alike.

## Prototype canvas

<https://claude.ai/artifact/JinzvtYfYetkpiDgFQ2Gt5>

Private to the owner. Current boards:

| Board | Surface |
| --- | --- |
| 1 · Activate device | Manual account activation with an admin-issued code |
| 2 · Chats (dark) | Chat list, default theme |
| 3 · Conversation | Message thread, E2EE + disappearing-message affordances |
| 4 · Safety number | Key verification |
| 5 · Chats (light) | Chat list, light theme |
| 6 · Admin · Users | User table + create-user panel with generated activation code |
| 7 · Admin · Contact graph | The contact-link editor — interactive |
| 8 · Admin · Edit user | Rename, spent-code record, device revoke — approved 2026-09-20 |
| 9 · Admin · Sign in | Approved 2026-09-23 |
| 10 · Admin · Two-factor code | Approved 2026-09-23 — keypad works in Play |
| 11 · Admin · Your account & 2FA setup | Approved 2026-09-23 — owner badge; 2FA off → setup → on |
| 12 · Admin · Devices | Approved 2026-09-23 — revoke with confirmation |
| 13 · Privacy & security (mobile) | Approved 2026-09-23 — app lock, default disappearing timer |
| 14 · App locked (mobile) | Approved 2026-09-23 — PIN pad works in Play |
| 15 · Disappearing-message timer (mobile) | Approved 2026-09-23 — presets to 1 year plus custom; announced in the chat |

Boards 2–7 are clickable in Play mode. Board 7 has working toggles.

## Visual language

Signal-adjacent in feel — calm, dense, unornamented, trust-forward — but its own identity. Skyline does
not copy Signal's proprietary design.

**Type**

| Role | Face | Notes |
| --- | --- | --- |
| Display / wordmark / dashboard headings | Space Grotesk 500/700 | Engineered, slightly technical |
| UI and body | Plus Jakarta Sans 400–700 | High legibility at 11–16px |
| Safety numbers, activation codes, usernames | JetBrains Mono 400/500 | Anything a human must compare character by character |

**Colour**

| Token | Dark | Light |
| --- | --- | --- |
| Ground | `#0C111C` | `#F5F7FB` |
| Surface | `#141B2A` | `#FFFFFF` |
| Surface raised | `#1C2438` | `#FAFBFD` |
| Border | `#263049` | `#E7EBF2` |
| Text primary | `#F2F5FA` | `#101828` |
| Text secondary | `#9AA6BF` | `#5A6782` |
| Accent (fills, white text on it) | `#3A63D8` | `#3A63D8` |
| Accent (text/icons on ground) | `#6E96FF` | `#3A63D8` |
| Verified / encrypted | `#34C08A` | `#14774F` |
| Caution / disappearing timer | `#E8A33D` | `#8A5A0B` |
| Danger / suspended | `#D04545` | `#A32020` |

Sidebar ink for the dashboard is `#101828` with `#98A4BA` inactive labels and `#1E2A44` active rows.

**Rules**

- Green means *verified or encrypted*, never "success" generally. Reserving it keeps the security
  signal meaningful.
- Amber means *disappearing messages are on* or *needs attention*. Red means *revoked/suspended*.
- Group avatars use a 14px rounded square; person avatars are circles. This is the only shape cue
  distinguishing them, and it is load-bearing in the chat list.
- Every colour pair above meets WCAG AA (4.5:1) at the sizes used. Check before introducing new ones.
- Icons are inline stroke SVG at 1.8–2.1 stroke width. No icon fonts, no emoji.

## Implementation notes for the Flutter client

The scaffolded theme at `apps/mobile/lib/core/theme/app_theme.dart` currently uses
`ColorScheme.fromSeed`. It should be replaced with an explicit `ColorScheme` built from the tokens
above — a seed-generated palette will not reproduce them, and the security colours in particular must
be exact rather than derived.
