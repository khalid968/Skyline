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

## MinIO: the compose image was gone, and the replacement is a year stale — PARTLY CLOSED 2026-09-26

**Update 2026-09-26 (Phase 12):** MinIO is now built from source at the same release
(`infra/docker/minio/Dockerfile`), with the commit hash checked. Development and CI both use it, so a fresh
machine can set up the stack again, and the media tests pass against it. **Still open:** the release is from
2025-09, and which store production uses is decided at Deployment.


**Update 2026-09-25 (media built; the owner chose MinIO for now, production store at Deployment):** the dev
compose file is pinned by digest to the image already on the owner's machine. quay.io now refuses
anonymous pulls of MinIO images altogether (HTTP 401, even by digest), so **a fresh machine cannot set up
the dev stack**. Decide the store (SeaweedFS, Garage, a source-built MinIO, or plain disk) before anyone
else needs to run it, and certainly before Deployment.

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

## Opening a document hands plaintext to another app (media, 2026-09-25)

Skyline keeps files encrypted and decrypts them only while they are viewed. A PDF or spreadsheet, though,
opens in another app (a PDF reader, Office), which needs a normal file.

- Skyline writes a decrypted copy to its own temporary folder, passes it to that app, and deletes the
  folder at the next start.
- Until then, the copy is readable by anything that can read the app's temporary folder.
- The other app may also keep its own copy (recent files, caches). Skyline cannot control that.
- The same applies to "Save to this device" on the photo viewer, which says so and asks first.
- **Mitigation for later:** an in-app viewer for PDFs and images, so common documents never leave Skyline.

## View once is a courtesy, not a guarantee (media, 2026-09-25)

A view-once photo or video is deleted after one viewing, and screenshots are blocked on Android and Windows.
It still is not a guarantee:

- On iPhone, screenshots cannot be blocked at all.
- On any device, a second camera can photograph the screen.
- A modified app could ignore the rule entirely: the recipient's device holds the key while the photo is on
  screen.

The composer and the viewer say this in plain words. Tell users to send nothing by view-once that they
could not bear to have kept.

## Muting cannot silence a closed phone's wake-up (Phase 8b, 2026-09-25)

Push notifications carry no sender and no chat, on purpose. So when the app is closed, the phone shows
"Skyline · New message" even for a muted chat: it cannot know which chat woke it until the app opens and
decrypts.

- **Fix for later:** after the wake-up, fetch and decrypt in the background, then decide whether to show
  anything. Android allows a short background run; iOS needs a notification service extension.

## A closed app does not ring (Phase 10, 2026-09-25) — OPEN, CONFIRMED IN USE
- **What:** a call rings only while Skyline is open on screen. A killed app gets the content-free push
  wake-up and shows the missed call afterwards, but it does not ring.
- **Confirmed by the owner on the live server (2026-09-26):** when someone calls, the app doesn't wake
  up. No ringing and no call screen appear until the person opens Skyline by hand. By then the call
  has often been given up and shows as missed.
- **What people can do meanwhile:** send a message first ("calling you now"), or keep Skyline open for
  an agreed call. Messages still arrive with the usual content-free notification.
- **Why:** ringing a closed app needs Android's ConnectionService / full-screen-intent notification and
  iOS CallKit + PushKit (VoIP push). Each is its own piece of platform work.
- **Fix for later:** a dedicated "incoming call" push that starts the ringing UI, still content-free (no
  caller name leaves the server).
- **Phase 14c (2026-09-29), Android, pending device tests:** a call offer now sends a ringing push
  carrying only the offer's random message ID. Android shows its own call screen at once. Limits of this
  first version:
  - **The name:** it shows only if Skyline was used in the last 15 minutes (a valid access token lets
    the phone read the sender from its inbox without decrypting). Otherwise it says "Skyline call" until
    the app opens. The background never refreshes the session and never opens the vault.
  - **Decline:** declining on the native screen stops the ringing only, and the caller hears it ring
    out. A real "declined" would need the vault.
  - **Stale ringing:** if the caller hangs up first, the native screen keeps ringing until its
    45-second timeout.
  - **iPhone:** needs PushKit/CallKit with the APNs key (Phase 14b/14c, iOS part).

## Calls trust the relay for availability, not for secrecy (Phase 10, 2026-09-25)
- **What:** every call goes through our coturn relay. The relay sees encrypted packets, both devices' IP
  addresses, and the call's timing and volume. It never sees content: media is DTLS-SRTP end to end, and
  the DTLS fingerprints travel inside Signal-encrypted messages, so a relay cannot sit in the middle.
- **Mitigation:** short-lived relay credentials (10 minutes, HMAC of a random name that names no one).
  Coturn refuses to relay to 0.0.0.0/8 and link-local addresses. In development it must still reach its
  own Docker network, so private ranges are allowed there. **Production (Phase 13) must also deny
  private ranges** (10/8, 172.16/12, 192.168/16, 127/8), so the relay cannot be used to reach the
  server's internal network. Run it on the same host we already trust with metadata.

## A compromised server can add a "ghost device" (Phase 12 threat model) — ACCEPTED
- **What:** the key directory is the server's. A server under an attacker's control could list an extra
  device for Bob. Alice's app would then encrypt to it, until someone looks.
- **Mitigation:** every new device is announced in the chat with a Verify button (board 17). The header
  shows how many of a contact's devices are not verified. Safety numbers are per device. Signal and
  WhatsApp accept the same limit.
- **Would close it:** key transparency (an auditable log of every key), a large piece of work, and not
  planned.

## The server knows who talks to whom, and when (Phase 12 threat model) — ACCEPTED
- **What:** routing needs it. Content, names in messages, media and call audio are never visible, but
  the sender, recipient and time of every envelope are.
- **Mitigation:** delivered ciphertext is erased, media is deleted at 30 days, and the dashboard shows
  only totals (`usage_daily` has no per-person column).
- **Would close it:** "sealed sender", in which the server cannot see the sender. Not planned for v1.

## Timing tests run on shared CI machines — WATCH
- **What:** `timing.e2e-spec.js` compares medians with a tolerance. A noisy runner could fail it without a
  real leak.
- **If it flakes:** rerun it. If it keeps failing, look for a real new code path before widening the
  tolerance.

## Backups live on the same server (owner decision, 2026-09-26) — ACCEPTED, WATCH
- **What:** nightly encrypted backups are kept on the production server itself. If the server is lost (a
  provider outage or account problem, disk failure, a compromise that wipes it), the backups go with it,
  and so does everyone's message routing state, the contact graph and 30 days of media.
- **What is NOT lost:** message history lives on members' devices, and keys never leave them. A rebuilt
  server would need the contact graph re-entered and every device re-activated.
- **Mitigation built in:** a one-command download of the latest encrypted backup to the owner's computer.
  Doing that weekly would turn this into an off-site backup.
- **Revisit:** before the member count grows, or at the first incident.


## Calls on networks that block UDP and port 3478 (Phase 13, 2026-09-26) — WATCH
- **What:** the call relay listens on UDP and TCP 3478 only. TURN over TLS (5349, or 443) is not enabled:
  certbot's private key is readable by root only and coturn runs unprivileged. A network that allows
  nothing but HTTPS (some hotels, corporate guest Wi-Fi) cannot place calls; messages still work.
- **Would close it:** a small hook that copies the renewed certificate into a coturn-readable volume,
  then `--tls-listening-port`. On one IP, 443 is taken by Nginx, so it would be 5349 or a second address.
- **Revisit:** at the first report of calls failing on a restrictive network.

## The owner cannot be recovered (Phase 13, 2026-09-26) — ACCEPTED, WATCH
- **What:** the owner account is protected: nobody can reset its password or two-factor sign-in, and
  `admin-create` only bootstraps the first admin. An owner who loses both the password and the 2FA
  device can no longer sign in to the dashboard, and nobody else can create or remove admins.
- **Mitigation:** the operator guide says to keep both in a password manager and to promote a second
  admin, who can keep running the service (members, links, groups) but cannot manage admins.
- **Would close it:** a shell-only `owner:reset` tool (needs server access, audit-logged, announced
  in the dashboard). Not built: it needs the owner's decision, since it gives whoever runs the server
  a way to take the owner's account.

## Profile photos can't be moderated (Phase 14d, 2026-09-30) — ACCEPTED
- **What:** profile photos are end-to-end encrypted (owner decision), so administrators can't see them and
  can't remove an offensive one.
- **Mitigation:** only the people someone is linked to (or shares a group with) can download their photo.
  An administrator can unlink or suspend the person, and the photo then stops reaching the contacts they
  lose.
- **Also:** group members who are not linked to someone see initials. The photo's key travels one to one;
  sending it through groups is a possible follow-up.
