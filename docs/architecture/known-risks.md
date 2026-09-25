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

## Rust toolchain not installed on the development machine — CLOSED 2026-09-23

**Closed:** Rust 1.98.1 (MSVC), the VS 2022 C++ Build Tools and protoc were installed with winget in Phase 7.
The text below is kept for history.


`cargo` is not present on the owner's Windows machine. `crypto-core` cannot be built or tested until it
is installed. Not blocking now; **blocking from Phase 7 (Encryption)**. Install Rust via `rustup` before
that phase starts.

## Docker / WSL — RESOLVED 2026-09-21 (kept for the diagnosis)

Docker Desktop's Linux engine runs on WSL2, and WSL was not installed, so the daemon answered `500`.
Resolved by `wsl --install --no-distribution` and a reboot; the engine now runs (Docker 29.8.0) and the
dev stack is up. Left here because the symptom (a 500 from the engine) is misleading.

Virtualization is enabled (`HypervisorPresent: True`) — no BIOS change needed. Fix, from an elevated
PowerShell: `wsl --install --no-distribution`, reboot if prompted, start Docker Desktop, then verify with
`docker compose -f infra/docker/docker-compose.yml up -d`. The Docker binaries live at
`C:\Users\kkhal\AppData\Local\Programs\DockerDesktop\resources\bin` and are not on the PATH of shells
started before the install.

## Flutter platform runners not yet generated — CLOSED 2026-09-24

**Closed:** `android/`, `ios/` and `windows/` were generated in Phase 7 and are committed.


`apps/mobile` is a hand-authored `lib/` + `pubspec.yaml` with no SDK-generated platform folders
(`android/`, `ios/`, `windows/`); they are gitignored and bootstrapped locally. Run the
`flutter create --platforms=android,ios,windows --org com.skyline --project-name skyline .` step in
`apps/mobile/README.md` before the first `flutter pub get` / `flutter run`. Flutter 3.35.7 **is**
installed, so this is a one-command fix, not a blocker.

## Admin scaffolding contradicts the admin architecture — CLOSED 2026-09-23

`apps/mobile/lib/features/admin/` was scaffolded in Phase 1 on the assumption of in-app administration.
Administration is now a separate web dashboard (`decisions.md`). Remove or repurpose that directory when
Phase 6 starts, so nobody builds admin surface into the client binary by following the folder structure.
**Closed:** the directory was removed in Phase 6.

---

## MinIO: the compose image was gone, and the replacement is a year stale — OPEN (before Phase 9)

`minio/minio` no longer exists on Docker Hub, so `docker compose up` failed outright. The dev compose
file now uses `quay.io/minio/minio:latest`, which starts and passes its healthcheck. **But that image is
release 2025-09-07 — a year old** — so `latest` is not receiving updates. Fine for local development;
**not acceptable for production, where the object store holds every user's encrypted media.**

The client talks S3, so the store is swappable. Decide before Phase 9 whether to keep MinIO (a pinned,
self-built or source-built version) or move to another S3-compatible store. This touches the locked
"MinIO = encrypted media blobs" decision, so it is the owner's call, not an agent's.

## iOS build untested — OPEN (until a Mac is available)

There is no Mac, so the iOS side of the Rust bridge (cargokit via the podspec in
`apps/mobile/rust_builder/ios`) has never been built. Its crate path mirrors Android's but may need
adjusting for CocoaPods' symlinked layout. Build it the first time a Mac or a cloud Mac exists (the owner's
decision, 2026-09-23), before any iOS release.

## The server could relabel who sent a session-starting message — CLOSED 2026-09-24

**Closed:** `SkylineCrypto::decrypt` now requires the key directory's identity key for a first message from
an unseen device, and refuses the message if the key inside differs (Rust test
`a_first_message_must_match_the_directory_identity`). The app passes the directory's answer from
`GET /me/contacts` or `GET /me/devices`. The text below is kept for history.


A session-starting (PreKey) message carries the sender's identity key. When one arrives from a device the
recipient has never seen, the recipient trusts it on first use, under whatever sender address the server
attached. A malicious server could present Alice's genuine first message as coming from a new device of
Carol's. It still cannot forge content, and cannot read anything.

**Phase 8 must:**

- check the identity key embedded in such a message against the key directory's identity for that sender
  device, before trusting it (the server cannot give two live devices one identity key: unique index);
- surface identity changes and new devices as system notices.

Safety-number verification remains the final guard.

## The Firebase plugin is linked into the Windows app — OPEN (low)

`firebase_core` has a Windows implementation, so the Firebase C++ SDK is compiled into the Windows binary
even though Skyline never initialises Firebase there (`pushSupported` is Android only). It is dead code, but
it is third-party code in a privacy product and it makes the build larger. Before the first release,
consider moving push into an Android-only plugin, or excluding the Windows plugin registration.

## iOS push (APNs) not built — OPEN (needs an Apple developer account and a Mac)

The server's transport has an `apns` slot that currently answers "error". Build it together with the first
iOS build.
