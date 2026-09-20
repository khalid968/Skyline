# Known Architectural Risks

## Web platform E2EE — CLOSED (deferred by scope, 2026-09-20)

Skyline's E2EE wraps Signal's official `libsignal-client` Rust crate and exposes it to Flutter via
`flutter_rust_bridge` FFI. That works on Android, iOS, Windows, macOS and Linux, where Flutter links a
native library per platform. It does not work on Web: Flutter Web runs in the browser and cannot load
native FFI libraries, and **there is no official WebAssembly build of `libsignal-client`**. Signal's own
tracking issue (<https://github.com/signalapp/libsignal/issues/350>) is open, and their earlier
JavaScript implementation is archived and explicitly unmaintained.

The available alternatives — community WASM wrappers, and an academic reimplementation of the protocol —
are not audited by Signal. Using any of them would break the project's founding rule that no unaudited
cryptography ships, ever.

**Resolution: the Web messaging client is out of scope for v1** (`decisions.md`). This closes the risk by
removing the surface, not by solving it. Revisit only if Signal ships an official WASM target.

The **admin dashboard is a web application and is unaffected** — it manages identities, contact links and
permissions, and never holds message keys or plaintext.

---

## Rust toolchain not installed on the development machine — OPEN

`cargo` is not present on the owner's Windows machine. `crypto-core` cannot be built or tested until it
is installed. Not blocking now; **blocking from Phase 7 (Encryption)**. Install Rust via `rustup` before
that phase starts.

## Docker not installed on the development machine — OPEN

No Docker daemon on the owner's Windows machine, so the `infra/docker/docker-compose.yml` dev stack
(Postgres, Redis, MinIO) cannot be brought up. The compose file has been syntax-validated but never
live-tested. Not blocking now; **blocking from Phase 3 (Database)**. Install Docker Desktop before that
phase starts, then verify with `docker compose -f infra/docker/docker-compose.yml up`.

## Flutter platform runners not yet generated — OPEN (low)

`apps/mobile` is a hand-authored `lib/` + `pubspec.yaml` with no SDK-generated platform folders
(`android/`, `ios/`, `windows/`); they are gitignored and bootstrapped locally. Run the
`flutter create --platforms=android,ios,windows --org com.skyline --project-name skyline .` step in
`apps/mobile/README.md` before the first `flutter pub get` / `flutter run`. Flutter 3.35.7 **is**
installed, so this is a one-command fix, not a blocker.

## Admin scaffolding contradicts the admin architecture — OPEN (low)

`apps/mobile/lib/features/admin/` was scaffolded in Phase 1 on the assumption of in-app administration.
Administration is now a separate web dashboard (`decisions.md`). Remove or repurpose that directory when
Phase 6 starts, so nobody builds admin surface into the client binary by following the folder structure.
