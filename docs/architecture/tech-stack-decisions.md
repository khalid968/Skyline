# Tech Stack Decisions

Each decision below was either made explicitly with the project owner or follows directly from those choices. Alternatives considered are listed so the reasoning survives even if revisited later.

## Frontend: Flutter + Riverpod + Material 3

- **Flutter** is the only mainstream framework that ships a single codebase to all six required targets (Android, iOS, Windows, macOS, Linux, Web) with genuinely native-compiled performance on desktop/mobile.
- **Riverpod** over Provider/Bloc/GetX: compile-safe dependency graph (no `BuildContext` lookups), first-class support for async state (message streams, WebSocket connections), testable in isolation, and code-generation (`riverpod_generator`) keeps boilerplate low. Riverpod providers double as the app's dependency injection mechanism — no separate DI container (e.g. `get_it`) is needed.
- **Material 3** with light/dark themes driven by `ColorScheme.fromSeed` gives a modern, accessible baseline that's still easy to fully re-skin later without fighting the framework.
- **go_router** for declarative, deep-link-friendly navigation across all platforms including desktop/web back-button semantics.
- **Drift** (SQLite) for local persistence, backed by SQLCipher for at-rest encryption of the local database — required for "encrypted local storage" and offline caching.

## Backend: NestJS (JavaScript, not TypeScript)

- Chosen over Go and Rust for backend implementation speed and ecosystem maturity around REST + WebSocket + PostgreSQL/Redis tooling, and because NestJS's modular, decorator-based architecture maps directly onto Clean Architecture (modules ≈ bounded contexts, providers ≈ use cases/repositories).
- **JavaScript, not TypeScript**, per explicit project decision — NestJS supports this natively via `@nestjs/cli --language JavaScript`, using Babel decorator transforms. This trades compile-time type checking for a simpler toolchain; runtime validation (`class-validator` DTOs) compensates at the API boundary.
- Real-time transport uses `@nestjs/platform-ws` (native WebSocket) rather than Socket.IO — see `overview.md` for rationale.
- Rejected: Go (excellent concurrency model, but slower iteration and a smaller pool of contributors for a project already committing to a JS-based Flutter/Dart ecosystem story); Rust (best raw performance, but development velocity is the wrong trade-off for a backend that's mostly I/O-bound orchestration, not compute-bound — Rust's value is concentrated in the crypto core instead).

## Data plane

- **PostgreSQL** — the persistent system of record for users, devices, sessions, chats, messages (ciphertext + metadata), groups, roles, invites, notifications, and audit logs. Chosen over MongoDB/etc. because the domain is inherently relational (users↔devices↔sessions↔messages↔groups↔roles) and benefits from real foreign-key integrity and transactional guarantees.
- **Redis** — WebSocket fan-out pub/sub (so the backend can scale horizontally later without a rewrite), ephemeral presence/typing-indicator state, and rate-limiting counters. Never used as a system of record.
- **MinIO (S3-compatible)** — encrypted media/file blob storage, self-hostable to keep the "no third parties" privacy stance intact even at small scale.

## Encryption: libsignal-client via Rust FFI

- Signal Protocol (X3DH + Double Ratchet) is the industry-proven approach to forward-secret, deniable, authenticated E2EE messaging. Per the project's non-negotiable rule — never invent cryptography — Skyline wraps Signal's own official `libsignal-client` Rust crate rather than reimplementing the protocol.
- `flutter_rust_bridge` generates the Dart↔Rust FFI bindings, so the same audited crypto core runs natively on Android/iOS/Windows/macOS/Linux. The Web target's viability with this approach is an open risk — see `known-risks.md`.
- Underlying primitives (all from within `libsignal-client`, not hand-rolled): X25519 for key agreement, Ed25519 for identity/signing, AES-256 for symmetric encryption, HKDF for key derivation, SHA-256 for hashing/MACs.

## Infrastructure: Docker Compose, Nginx, single-host

- Matches the "small private deployment" scale target: a friend community, not a multi-tenant SaaS. Kubernetes, multi-region, and auto-scaling would add operational burden with no corresponding benefit at this scale.
- The architecture stays horizontally-extractable: stateless NestJS instances behind Nginx, session/presence state in Redis rather than in-process — so growth later doesn't require a rewrite, just more containers and a load balancer.
- Nginx handles TLS termination and reverse proxying to the NestJS REST/WebSocket ports; production TLS (Let's Encrypt/certbot), secrets management, and backup automation are Phase 11 work.
