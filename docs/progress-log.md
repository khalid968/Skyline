# Progress Log

Append one entry per working session, newest at the top. This is the handoff record: an agent picking
up Skyline should read `CLAUDE.md` first, then the most recent entries here.

Each entry states what was decided, what changed on disk, and what the next agent should do. Do not
rewrite history in this file — append.

---

## 2026-09-25 (late night) — Media pushed; Phase 8b started: decisions and prototypes

- **Pushed** everything through commit 591b996 to GitHub. Before pushing, the new commits were checked
  for secrets.
- **The owner started Phase 8b** and decided four things (see `decisions.md`, "Phase 8b started"):
  - groups are managed by admins and moderators in the dashboard now, and members can leave;
  - any member can set a group's timer, and the change is announced;
  - edit within 15 minutes, delete for everyone within 24 hours;
  - anyone can pin (3 per chat), and any emoji works as a reaction.
- **Plan:**
  - groups use libsignal Sender Keys, rotated whenever someone leaves or is removed;
  - replies, edits, deletions, reactions, pins and mentions are ordinary encrypted messages that point at
    an earlier message;
  - search runs only on the device;
  - drafts, archive and mute are kept on each device.
- **Prototypes 26-31 published** to the design canvas for approval: the chat list with groups, archive and
  mute; a group conversation; message actions; group info with leave and mentions; search; and the
  dashboard's Groups page.
- **Next agent should:** wait for the owner's approval of 26-31, then build in this order:
  1. dashboard groups and the server's group routes (membership checked on every send and delivery,
     404 outside);
  2. Sender Keys in the crypto core;
  3. group messaging in the app;
  4. message actions;
  5. search, drafts, archive and mute.

---

## 2026-09-25 (late night) — Album viewer; view once easier to find

Two points from the owner's testing:

- **The extra photos in an album could not be reached** (the "+4" tile). Tapping any album tile now opens
  `AlbumViewerScreen` at that photo. You can swipe through every photo and video in the album; on a PC
  there are Previous and Next arrows and the arrow keys work. It shows "4 of 8", fetches photos that are
  not downloaded yet, and offers play or download for videos.
- **"View once doesn't exist when sending from Windows."** It did exist, but only for exactly one photo or
  video picked through Photos or Video. It was hidden when several files were picked or the file came
  through File, and a Windows app built before it would not have it either.
  - The "1" button now always shows. It is greyed when view once cannot apply, and tapping it says why.
  - A single picture or video picked through File can now be sent view-once too (it goes as a photo or
    video).
- **Verified:** Windows `media_ui_test`. Tapping "+1" opens "4 of 5" and Next reaches "5 of 5"; the
  screenshots were checked. The unit tests pass.

---

## 2026-09-25 (night) — Several files at once, view once and the media gallery BUILT (boards 23-25)

The owner approved boards 23-25 ("looks great"). Design notes are in `decisions.md`, 2026-09-25 (night).

**Built (app only; the server needed no change)**

- **Model:** a message now carries a list of files (`items`). Messages stored before this change still load.
- **Sending:** `Messenger.sendFiles` handles albums and documents; `viewOnceOpened` and the `opened`
  notice handle view-once.
- **Screens:**
  - picking up to 10 files, with the preview strip (✕ to remove, + to add) and the view-once toggle;
  - album bubbles (2, 3, or 4 tiles with "+N");
  - view-once bubbles, with the viewers in view-once mode: no save button, and screen protection on;
  - the gallery (`media_gallery_screen.dart`, route `/chat/:peer/media`).
- **Screen protection:** a native `skyline/screen` channel, in `MainActivity.kt` (FLAG_SECURE) and in
  `flutter_window.cpp` (excluded from capture).

**Verified**

- Windows `messaging_test` (two devices, real server):
  - a 3-photo album plus a PDF go out as two messages, and each photo decrypts correctly;
  - a view-once photo: the sender's copy is burned at once, and the recipient gets no preview. After one
    opening the file leaves the recipient's disk, and the sender sees Opened.
- Windows `media_ui_test`: screenshots of the preview with several files, the view-once preview, the
  album and view-once bubbles on both sides, and the gallery. They match boards 23-25.
  - Known difference: the view-once ring is solid, not dashed.
- `screen_protection_test` passes on Windows and on the Android emulator.
- `flutter analyze` is clean, 12 unit tests pass, and the Android debug APK builds.
- **Found and fixed:** album downloads finishing together could overwrite each other's progress. Updates to
  one message are now serialised.

**Not done**

- The server copy of a view-once file is not deleted early. It is useless without the key, and goes at 30
  days.
- Not tried on iPhone.

**Next agent should:** report to the owner. Then Phase 8b, **prototypes first**. Nothing is pushed yet;
ask the owner before pushing.

---

## 2026-09-25 (evening) — One-click dev environment; media gaps closed; boards 23-25 for approval

The owner asked for:
1. a one-click way to run the testing environment;
2. sending several files at once;
3. view-once messages;
4. then "complete building what's missing".

**Built**

- **`Start Skyline.cmd` / `Stop Skyline.cmd`** in the repository folder (`scripts/dev-up.ps1`,
  `scripts/dev-down.ps1`).
  - Start runs, in order: Docker Desktop and the data stack, then migrations, the server on :3000 and the
    dashboard (opened in the browser); then the emulator (software graphics) and the app on it, then the
    Windows app. Each runs in its own window.
  - Anything already running is reused, never restarted. Stop closes only the windows Start opened
    (process ids kept in `.dev-pids`, gitignored).
  - Checked: both scripts parse, and the Docker-health and emulator-detection steps work on this machine.
    **The full script has not been run end to end:** that starts the owner's own server on :3000.
- **Media gaps that fall under approved boards** (see `decisions.md`, "Media preparation before
  sending"):
  - photos re-encoded (at most 2048 px, EXIF and location removed);
  - video thumbnails and lengths;
  - video compression on phones;
  - saving to the phone's gallery.
  - New messages now appear at once and show "Preparing…" or "Compressing · n%" before encrypting.
- **Verified**
  - Windows `messaging_test`: a 3000x2000 camera JPEG with GPS EXIF arrives at 2048x1365, with no EXIF.
  - `flutter analyze` is clean, the unit tests pass, and the Android debug APK builds.
  - **Not verified:** video thumbnails, lengths and compression with a real video file (none in the test
    fixtures).

**Waiting for the owner (not built)**

- Boards 23 (several files at once), 24 (view once) and 25 (media gallery), published to the design
  canvas.
- The gallery is the last item on the roadmap's media list.
- Choices shown on the boards for the owner to confirm:
  - up to 10 files per send, photos and videos grouped into one album;
  - view-once for photos and videos only; screenshots blocked on Android and Windows, not possible on
    iPhone; the sender cannot reopen it either;
  - the gallery shows only what is on this device, never disappearing or view-once messages.

**Next agent should:** on approval of 23-25, build them. Server work:
- albums already fit: a message can claim up to 10 files;
- view-once needs a "viewed" sync between the viewer's own devices.

Then Phase 8b, prototypes first.

---

## 2026-09-25 (later) — Media (Phase 9) BUILT: photos, videos, documents, voice messages

The owner asked for media before Phase 8b and approved boards 20-22. Their decisions (MinIO pinned for now,
photos/videos/voice/documents, 2 GB, deleted after 30 days) are in `decisions.md`, 2026-09-25.

**What was built**

- **Crypto core** (commit e7d12d5): streaming file encryption with libsignal's AES-256-GCM
  (`crypto-core/core/src/media.rs`). Each file gets a fresh key and nonce; decryption writes nothing
  until the tag verifies.
- **Server** (commit 4d97d86): migration 013, `modules/media`.
  - Routes: `POST /attachments`, then upload progress, parts and complete (the uploader's own), then
    `GET /attachments/:id` (graph-checked, with byte ranges).
  - Uploads are resumable, in 8 MB S3 multipart parts, through the server. MinIO is never exposed.
  - A message claims its files (`attachmentIds`) inside the send transaction.
  - An hourly sweep deletes every file at 30 days.
  - Database guards: a file belongs to one message, for good; its identity never changes; rows are
    never deleted; a deletion is never undone.
- **App** (`lib/features/media`, plus the messenger and the conversation screen):
  - attach menu, preview with caption, media bubbles with progress;
  - photo viewer (saving an unencrypted copy asks first), video player, documents opened in another
    app on request;
  - hold-to-record voice messages, slide left to cancel.
  - Photos and voice download by themselves; videos and documents on tap.
  - Files stay encrypted on the device and are decrypted only while viewed (photos in memory, the
    rest as a short-lived copy swept at start).
  - Disappearing messages delete their files.

**Verified**

- Backend: 112 unit, 102 db and 239 app tests pass.
  - The app tests run against the real MinIO, in a separate `skyline-test` bucket.
  - Migration 013 goes down and up cleanly on a throwaway database.
  - Nine mutation checks were all caught. Two missed at first, and the tests were fixed so they now
    catch them.
- App: 8 unit tests pass (`test/media_model_test.dart`).
- Windows `messaging_test` passes: a photo downloads by itself and decrypts to the exact bytes; a 9 MB
  document goes up in two parts and is stored on the receiving device as ciphertext.
- Windows `media_ui_test` renders the real screens on both sides. The screenshots match boards 20-21.
- The Android debug APK builds.
- Not run on a phone yet. iOS is untested (no Mac).

**Not built (say so if asked)**

- A media gallery.
- Photo and video compression: files are sent as they are.
- Video thumbnails, and the duration of picked videos: the bubble shows a plain tile.
- Saving on Android uses the system "save as" dialog, not the gallery.

**Also fixed on the way**

- Migration 013 re-created an index that migration 007 already had; the first test run caught it.
- Three test databases leaked from that failed run. They were dropped; all are `skyline_test_*` names.

**Next agent should:** report media to the owner for review. Then Phase 8b (groups, replies, edit/delete,
reactions, mentions, pins, search, drafts, archive/mute): **prototypes first, owner approval, then build.**

---

## 2026-09-25 — Phase 8a BUILT: one-to-one messaging, app lock, safety-number scanning, push

The owner set up Firebase (project `skyline-a090f`; `google-services.json` in `apps/mobile/android/app`, and
the service account OUTSIDE the repo in `C:\Users\kkhal\Skyline-secrets\`; both are gitignored). **8a is complete and awaiting the
owner's review. 8b needs explicit approval.**

**Since the previous entry:**

- **App lock (board 14):**
  - The PIN is an Argon2id hash in the vault. Backoff (30 s after 5 misses, doubling) is kept in the core.
  - Biometrics use `local_auth`.
  - The lock screen replaces the app, rather than covering it.
- **Safety-number QR scan (board 4):**
  - `flutter_zxing` 2.2.1. `mobile_scanner` was rejected because its Android ML Kit reports usage to
    Google.
  - The match itself is libsignal's scannable-fingerprint check, in the core.
- **Push:**
  - Server: `PUT`/`DELETE /me/push`. After a send, the recipient's devices are woken with data
    `{t:"inbox"}`, coalesced to one wake-up per device every 5 s. Dead tokens are dropped. FCM HTTP v1 is
    called with a service-account JWT, without an SDK.
  - Client: `firebase_messaging`. In the foreground a wake-up just triggers a pull. In the background the
    phone shows only "New message" and does not decrypt, to avoid a second isolate touching the vault.
  - **Verified on the emulator with real Firebase:**
    - a data-only wake-up arrives, and Google shows nothing;
    - a wake-up to a killed app shows "Skyline · New message";
    - a dead token is reported and dropped.
  - Android 13+ asks for notification permission once. Tests grant it with `adb shell pm grant`.
- **Tools:**
  - `scripts/e2e-fixture.js` (throwaway fixtures).
  - `scripts/push-probe.js` (one real wake-up; refuses any database that is not `skyline_e2e_*`).
- The chat row now reads as one sentence to screen readers. It used to read the name twice.

**Tests at the close of 8a:**

- Backend: 439 tests (112 unit, 95 db, 232 app).
- Rust: 24 tests (4 store unit, 20 protocol); clippy clean.
- Dashboard: 18.
- Windows app build: `crypto_test` 4 tests; `messaging_test` (two devices through a real server) 1 test.
- Android: the push test on a real device.

**Known issues:**

- The Firebase plugin also compiles into the Windows app. It is never initialised there (push is Android
  only), but it makes the Windows binary larger (`known-risks.md`).
- With read receipts off, other own devices learn a chat was read only when it is opened there.
- iOS: push (APNs) and every iOS build still need an Apple account and a Mac.
- The background wake-up does not decrypt, so "delivered" ticks appear when the phone opens the app.

**Next agent:** wait for the owner's review of 8a; 8b (groups, replies, edit/delete, reactions, mentions,
pins, search, drafts, archive/mute) needs an explicit go. The owner can try it all with
`docs/try-it-yourself.md`, section "Phase 8a".

---

## 2026-09-24 (evening) — Phase 8a IN PROGRESS: one-to-one messaging works end to end

The owner approved boards 16-19 ("this looks good") and said go.

**Done (local commits; nothing pushed since `dd267a8`):**

- **Server (`1b0f32f`):**
  - Migration 012: message `seq`; one-way ciphertext erasure on delivery; a per-device system cursor.
  - `modules/messages`: contacts with reachable devices; send (exact device coverage or a structured 409;
    idempotent); an inbox that re-checks the graph; ack (erases the ciphertext and sends a delivered
    receipt); status; live-only typing signals.
  - `GET /me/device-keys`, and `/me/devices` now returns identity keys.
  - 11 app and 4 db tests; four mutations caught.
- **Crypto core:**
  - `decrypt` requires the directory's identity for a first message from an unseen device (`09497ab`).
    The known-risk is closed.
  - An encrypted **records** store in the vault holds the app's local history (`5e12dd5`; decision
    recorded).
- **App (`f596b0e`):**
  - The design tokens replace the seed theme.
  - Fonts are bundled, never fetched at runtime (Google Fonts would be a third-party call).
  - Stroke-SVG icons; an API client with signed refresh; a WebSocket with backoff.
  - The messaging engine: `features/messages/data/messenger.dart`.
  - Screens: activation (1), chat list (2/5/18), conversation (3/16/17/19), message details, the timer
    sheet (15), safety numbers (4), and Privacy & security (13, with the two receipt/typing switches the
    owner decided on).
- **Proven end to end:**
  - `integration_test/messaging_test.dart` passes on Windows against a real server and a throwaway
    database. It covers activate, contacts, send, receive, delivered, read, reply and the timer notice.
  - `apps/backend/scripts/e2e-fixture.js create|drop` builds that fixture and refuses any database whose
    name is not `skyline_e2e_*`.
- **Found by that test:** a single upload of 50 Kyber keys is about 105 KB, and the server's limit is
  100 KB (413). Keys are now uploaded in batches, and a failed upload is repaired on the next sync.

**Housekeeping:**

- Migrations 011 and 012 were applied to the owner's dev database by accident, via a `migrate:up` in a
  chained command. It is additive and creates no accounts.
- Two test databases leaked by an earlier force-stopped jest run were dropped.

**Still to do in 8a:**

1. App lock (board 14: PIN, face or fingerprint; `local_auth`).
2. Scanning a safety-number QR code (board 4's "Scan their code"; camera plugin; Android/iOS only).
3. Push wake-ups: needs a Firebase project from the owner, and an Apple developer account for iOS.
4. Docs: `authorization.md` messaging routes, try-it-yourself, CLAUDE.md.
5. Full test runs, then the phase report.

**Known limit:** with read receipts OFF, your other devices learn a chat was read only when it is opened
there.

---

## 2026-09-24 (later) — Phase 7 pushed; Phase 8 planned, NOT started

The owner ran the app on the Android emulator: it launches and shows the placeholder "Skyline" screen. A
reported "crash" was the app being swiped away ("remove task" in logcat); the only crash in the log was the
emulator's own Bluetooth service. The owner asked to push: `5728c1e` is on GitHub.

Phase 8 decisions are recorded in `decisions.md`:

- split into 8a (one-to-one chats) and 8b (everything else);
- push is an empty wake-up through Apple and Google;
- read receipts and typing indicators are on by default and can be switched off (reciprocal);
- a new device starts empty.

**Phase 8a has not started.** Its first step, once the owner says go, is to prototype the undesigned 8a
surfaces on the canvas and get approval: delivery ticks, new-device and identity-warning notices, and empty
and offline states. The approved boards are 1-5 and 13-15.

---

## 2026-09-24 — Phase 7 BUILT: encryption, verified on Windows and Android

The owner said "let's move where we left off". This session finished the phase.

**Done:**

- **App crypto service:** `lib/core/crypto/device_crypto.dart`. The vault's storage key is 32 bytes from
  `Random.secure`, kept in `flutter_secure_storage` and never next to the vault file. A vault whose key is
  lost is refused, never replaced. `RustLib.init()` runs at startup.
- **Analyzer:** `flutter analyze` is clean. `rust_builder/**` and the generated `lib/src/rust/**` are
  excluded from analysis.
- **Integration test** (`integration_test/crypto_test.dart`): 3 tests. They pass **on Windows** (in the real
  app build) and **on the Android emulator** (x86_64 build; cargokit cross-compiled libsignal).
- **Backend suite:** the full `test:app` now passes in one run (216 tests). The earlier "hang" was CPU
  contention with a cargo build. One CLI test was timing-sensitive under full load: `babel-node` cold start
  took more than 60s. Its time limits were raised (120s for the process, 180s for the test).
- **Mutation checks:** four more on the key directory, all caught:
  - the graph check removed from bundle fetch;
  - one-time keys never marked claimed;
  - no per-contact fetch limit;
  - malformed keys accepted.

  With the five crypto-store checks earlier, that is nine in total.
- **Docs:** decisions (how Phase 7 was built), known risks (Rust and runners closed; iOS untested and
  sender relabelling open for Phase 8), `authorization.md` (key directory), `try-it-yourself.md` (Phase 7),
  the roadmap, CLAUDE.md and the mobile README.

**Toolchain additions:** the VS Build Tools needed the "C++ ATL" component for `flutter_secure_storage` on
Windows. The owner approved the installer's admin prompt.

- Installer quirk: `setup.exe modify` rejects `--wait` (exit code 87); leave that flag out.
- Emulator quirk: the Android emulator crashed with the default GPU mode on this PC ("A device attached to
  the system is not functioning"). Start it with `-gpu swiftshader_indirect`.

**Totals:**

- 417 backend tests: 110 unit, 91 db, 216 app.
- 20 Rust tests.
- 3 integration tests, run on Windows and on Android.
- 18 dashboard tests, unchanged.

**Next agent should:**

1. Wait for the owner's review. **Phase 8 (Messaging) needs explicit approval.**
2. Phase 8's first task: before trusting a session-starting message from an unknown device, check its
   identity key against the key directory (`known-risks.md`).
3. The owner must restart their backend (run `npm run migrate:up` first) to get migration 011 and
   activation v2.

---

## 2026-09-23 (night, later) — Phase 7 IN PROGRESS (owner closed the session mid-phase)

The owner said "yes go ahead" on Phase 7. Nothing from Phase 7 is pushed; local commits only.

**Done and tested:**

- **Toolchain** (installed via winget):
  - VS 2022 Build Tools with C++, rustup with Rust 1.98.1 (pinned in `crypto-core/rust-toolchain.toml`,
    matching libsignal), protoc 36 (on the user PATH), and `flutter_rust_bridge_codegen` 2.13.0.
  - In a fresh shell, `export PATH="$HOME/.cargo/bin:$PATH"` may be needed.
- **`crypto-core/core`**: libsignal v0.103.1, pinned by tag.
  - API: `SkylineCrypto` with identity, prekeys (signed, Kyber, one-time), PQXDH `start_session`,
    `encrypt`/`decrypt`, `safety_number`, and Ed25519 `sign`.
  - Keys live in an encrypted SQLite vault (`vault.rs`), and identity trust is strict.
  - 20 tests and 5 mutation checks, all caught. There is no `unsafe` code.
  - Found and fixed: opening the vault with the wrong key silently created a second identity; it is now
    refused as `VaultLocked`.
- **Backend** (commit `f54b05f`):
  - Migration 011 (key directory), and activation v2, which registers the Signal identity under the
    device signature.
  - Key routes: `PUT`/`GET /me/keys` and `GET /users/:id/keys`, with a direct link required and per-caller
    rate limits.
  - `RateLimitModule` is now global, with `enforceLimit()` for per-caller limits.
  - Tests: 12 db tests and 14 app tests for keys. `test:db` passes 79 + 12. The app suites pass file by
    file, but the FULL `npm run test:app` run should be repeated: one earlier run hung while cargo was
    compiling at the same time.
- **`crypto-core/e2e` plus `test/app/crypto-e2e.e2e-spec.js`**: two real libsignal devices against the
  real backend. They activate, publish keys, fetch bundles, start a session and talk, and the 404 without
  a link holds. The test passes; it needs `cargo build -p skyline_e2e` first, or it is skipped.

**Uncommitted, next steps:**

1. The bridge:
   - `crypto-core/ffi`: a thin `CryptoDevice` wrapper. It builds.
   - `apps/mobile/rust_builder`: cargokit wired to `crypto-core/ffi`.
   - `flutter_rust_bridge.yaml`, and the generated `lib/src/rust`.
   - `pubspec.yaml`, now with `flutter_rust_bridge 2.13.0`, `skyline_crypto_ffi` and `integration_test`.
   - `apps/mobile/{android,ios,windows}` are now tracked (root `.gitignore` changed). The template test
     `widget_test.dart` was deleted.
2. Still to do:
   - Load the storage key from `flutter_secure_storage` in `lib/core/crypto/`.
   - An integration test on Windows (`flutter test integration_test -d windows`), then an Android build.
     The NDK is not checked yet.
   - Run `flutter analyze`, and repeat the full `test:app`.
   - Docs: decisions (committed platform folders, the committed `Cargo.lock`, the ffi crate split), CLAUDE.md
     and authorization.md for the key routes, and try-it-yourself.
   - Then end the phase and ask the owner.
3. **Noted for Phase 8:** when a session-starting message arrives from an unknown device, the client should
   check the embedded identity key against the key directory before trusting it (so the server cannot
   relabel a sender). Safety-number verification is the final guard.

---

## 2026-09-23 (late night) — Phase 6 pushed; Phase 7 planned, NOT started

The owner reviewed Phase 6 ("looks good") and asked to push. `275d670` is on GitHub. The Phase 7 plan was
presented:

1. toolchain;
2. the `libsignal` crypto core with Rust tests;
3. `flutter_rust_bridge` bindings and on-device key storage;
4. the backend key directory (prekey tables, upload, graph-checked bundle fetch, one-time keys claimed
   atomically, fetch rate-limited);
5. an end-to-end check that the server stores only ciphertext.

The owner answered the four open questions (recorded in `decisions.md`): accept AGPL, each device has its own
keys, Claude installs the toolchain via winget, and no Mac for now. **Phase 7 has not started. Wait for
the owner's explicit go.**

---

## 2026-09-23 (night) — Phase 6 BUILT: admin dashboard v1

The owner approved boards 9-15 and asked for longer disappearing-message periods. The timer now has presets
from 1 hour to 1 year plus a custom duration; this is a Phase 8 mobile screen and board 15 was updated.
Then Phase 6 was built. **It is awaiting the owner's review. Phase 7 needs explicit approval.**

**Backend** (commit `ddc4d35`):

- Migration 010 adds `is_owner`, protected by a trigger, and `must_change_password`.
- `src/modules/admin/` holds the users, codes, contact-link and devices APIs, with 15 routes, all behind
  `@RequirePermission`.
- `admin-policy.js` decides who may manage whom:
  - nobody manages themselves;
  - only the owner manages admins;
  - moderators manage members only.
- The dashboard session is a cookie, with the CSRF header rule.

**Dashboard** (`apps/dashboard`, new): React 19 + Vite 8, plain JavaScript.

- `src/lib/api.js` is the only fetch path. It stays same-origin through `/api` and always sends the CSRF
  header.
- `src/lib/auth.jsx` holds the session state plus `capabilities()` and `canManage()`, which mirror the
  backend policy.
- The pages:
  - `SignIn` and `TwoFactor`;
  - `Users`, with the create-user panel;
  - `UserDetail`: rename, role, suspend, reinstate, delete, codes, devices and reset sign-in;
  - `ContactGraph`: a picker plus switches, updated optimistically;
  - `Devices`;
  - `Account`: password, 2FA with a QR code, and the must-change lock.

**Verified**

- `npm test` in `apps/dashboard`: 18 tests.
- `npm run build` is clean. oxlint gives only style warnings.
- Backend: 387 tests.
- Smoke test through the real proxy path: the dashboard on :5179, the backend on :3077, and a throwaway
  database, dropped afterwards.
  - Checked: the HttpOnly cookie is set and no token appears in the body; CSRF is refused without the header;
    users are created with initial contacts; link, unlink, rename, suspend and reinstate work.
  - A moderator is held to the account page until they change their password, then cannot touch the owner
    but can suspend a member. After logout the cookie is dead.
  - Suspend and reinstate return 200, not 204.

**Next agent should:**

1. Remind the owner to **restart their backend on :3000**. It was started before Phase 6 and does not have
   the admin routes.
2. Wait for the owner's review of Phase 6. **Phase 7 (Encryption) needs explicit approval.** It also needs
   Rust installed, which it still is not.
3. Known leftovers (the stray `apps/mobile/lib/features/admin/` placeholder folders were removed this phase):
   - Groups and the audit-log viewer are dashboard v2 (Phase 11).

---

## 2026-09-23 (evening) — Phase 6 prototypes drawn, awaiting approval

The owner said "let's start". Seven screens were added to the canvas (boards 9-15, listed in `design.md`):
admin sign-in, 2FA code, account & 2FA setup, devices, and on mobile Privacy & security, the lock screen and
the disappearing-message timer. **No Phase 6 code has been written; it waits for approval of these.** Two
proposals shown on the canvas need an explicit yes or no: the owner resets a locked-out admin's password or 2FA
(no self-service reset), and the v1 sidebar is Users / Contact graph / Devices only.

---

## 2026-09-23 (later) — Phase 5 pushed; Phase 6 scoped, NOT started

The owner tested Phase 5 by hand (admin sign-in worked once the doc's `YOUR PASSWORD` placeholder was replaced)
and asked to push: `3e7894e` is on GitHub. Phase 6 decisions are in `decisions.md` (React + plain JS; v1 =
users/codes, contact graph, devices; groups and audit viewer moved to v2; protected owner account; dashboard
session in an HttpOnly cookie). **The owner has not yet said "go" on Phase 6.** First step once they do:
prototype the unapproved screens on the design canvas and get approval before any code.

---

## 2026-09-23 — Phase 5 BUILT: authentication, invites, rate limiting

**Owner decisions** (full text in `decisions.md`, 2026-09-23): members have **no password** (the activation code
is the only way in; the device is the credential; no recovery codes); **admins sign in with a password and
2FA is optional**, chosen for simplicity; each device registers an **Ed25519 signing key** now, Signal keys in
Phase 7. The owner also asked to push: Phases 2-4 were pushed to GitHub at the start of this session.

**Built:**

- **Migration 009**: device `signing_key`; Signal fields nullable until Phase 7; the code->device FK deferred
  to COMMIT so activation is one atomic transaction; token hashes on `device_sessions`;
  `admin_credentials` and `admin_sessions`.
- **Activation** (`POST /auth/activate`): code + device public key + signature over the code. Redeems through
  `redeem_activation_code()`, registers the device, opens a session, all or nothing.
- **Device tokens**: 15-min access, 30-day refresh that rotates; refresh needs a fresh Ed25519 signature;
  a reused refresh token revokes the whole session. Logout, list/revoke own devices.
- **Admin sign-in**: Argon2id password, optional TOTP 2FA (setup/enable/disable), password change that signs
  out other sessions, 12h absolute / 60-min idle dashboard sessions.
- **Session kinds are enforced**: operator routes accept only dashboard sessions, member routes only device
  sessions. An admin's phone cannot call operator APIs.
- **Rate limiting** (carried over from Phase 4): Redis fixed windows, per address and per username, fails
  closed. WebSocket login now takes a real device token.
- **CLI**: `npm run admin:create` (first admin only), `npm run user:invite` (member + one-time code, shown once).
  **`npm run dev:device`**: a pretend phone for trying the API by hand (dev only).
- **`docs/try-it-yourself.md`**: the owner's step-by-step manual test.

**Tests: 344 pass** (109 unit, 78 db, 157 app), no leaked databases. The Phase 5 suite uses real keys and
real tokens (no test shortcuts). **8 mutation checks, all caught**: refresh accepting any signature, reuse
detection off, activation skipping the signature or admitting a suspended account, a phone accepted on
operator routes, a replayable 2FA code, a suspended admin signing in, password change keeping other sessions.

**Found and fixed along the way:** otplib's dependency is ESM-only and Jest could not load it (fixed by moving
to a project-wide `babel.config.js` and rooting both Jest configs at the backend folder: note this in
`authorization.md` gotcha 5); a failed-2FA audit entry would have been rolled back with its transaction (now
written outside it); and the CLI password prompt could hang on piped input (rewritten; verified piped, the
live-keyboard path is untested here, so an env-var fallback is documented).

**A process slip, recorded honestly:** while testing the CLI, a command chain kept running after a syntax
check failed, so later steps ran without the throwaway `DATABASE_URL` and would have hit the dev database. The
CLI crashed before touching anything and the dev database was verified untouched (0 users). The re-run used
`set -e` and a guard that refuses any database name that is not a throwaway one. **Do the same: any command
that creates accounts must prove it is pointed at a throwaway database first.**

**Deliberately NOT done:** no accounts were created in the owner's dev database. `admin:create` only makes the
*first* admin, so that must be the owner's own.

**Moved out of Phase 5:** the PIN/biometric app lock is purely on-device, so it belongs with the mobile app
build, not the backend. Its Privacy & security settings prototype is still owed.

**Known gaps** (details in `authorization.md`): `trust proxy` must be set when Nginx arrives (Phase 13) or all
clients share one rate-limit counter; a client that blindly retries a successful refresh gets its session
revoked; timing uniformity is by design, not measured.

**Next agent:** Phase 6 (admin dashboard v1) needs the owner's explicit approval, and it is a user-visible
surface, so **its screens must be prototyped and approved first** (the Phase 2 canvas has users, create-user,
contact graph and edit-user boards; sign-in and 2FA screens are not drawn yet). The dashboard's API should reuse
`issueActivationCode()` and `AuditService`, use `@RequirePermission` + `@GraphExempt` on every route that takes
a user id, and remove `apps/mobile/lib/features/admin/`.

---

## 2026-09-21 (night) — Phase 4 BUILT: backend foundation and authorization core

**Owner decisions this session:** graph checks go **in SQL, nothing cached**; true E2EE for v1 with a
*disclosed* compliance archive possible later (nothing built toward it); app lock is **always the user's
own choice**; then "start Phase 4". All recorded in `decisions.md`.

**Built** (all under `apps/backend/src`, documented in `docs/security/authorization.md`):

- **Config** validated at boot: reports every problem at once, never prints a value, refuses dev placeholder
  secrets in production.
- **Logging**: structured JSON, redacted by key name, no bodies, no query strings, sanitised request ids.
- **One error filter**: every 404 identical whatever produced it; no stack/SQL/path ever leaks; only a
  *list* of validation messages is passed through on a 400.
- **Strict validation**, global: undeclared fields are rejected (mass assignment), values never echoed.
- **Health**: `/health` (liveness) and `/health/ready` (Postgres + Redis, up/down only).
- **Three global guards, default deny, nothing cached**: authenticated-and-still-active (401), permission
  (403), contact graph (404). Plus `AuditService`, the DB and Redis modules, and the WebSocket gateway
  with Redis fan-out that **re-checks the graph at delivery time**.
- **Route-inventory test**: fails the build if any route parameter is not graph-scoped, or a body is unvalidated.

**Tests: 243 pass** (71 unit, 75 db, 97 app), every run exiting 0 with no leaked databases. Includes real
HTTP, real WebSockets, real Redis, and **two backend instances** sharing a channel.

**Mutation-tested.** Deliberately breaking each core protection makes the suite fail: fan-out ignoring the
graph (7 tests fail), graph guard off (12), suspended user still active (2), revoked device accepted (2),
404 leaking a message (3). A first attempt at the last one "passed" only because my mutation was a no-op;
I redid it as a real leak rather than accept a false all-clear.

**Real bugs found and fixed by the tests — none would have been caught by reading:**

1. **Health check reported OK with the database down.** `database && redis ? 'ok' : ...` where the values
   were the strings `'up'`/`'down'`, both truthy. A load balancer would have kept routing to a dead instance.
2. **Malformed-JSON 400 leaked the parser's message** ("Unexpected end of JSON input"). Nest wraps
   body-parser errors in a BadRequestException carrying that text; my filter passed it through.
3. **Jest could not parse `src/`** from the e2e config (Babel ignored `.babelrc` with `rootDir` at `test/`).
4. My own test leaked a whole app when an assertion failed before cleanup, hanging the run. Now `try/finally`.

**Decisions made in code that the owner has not been asked about** (all cheap to reverse):
a suspended user stays *visible* to contacts (only deleted accounts vanish); archived groups remain reachable
by members; a missing permission is a 403 not a 404; the WebSocket is server-to-client only.

**NOT built, and stated so nobody assumes otherwise:**

- **Rate limiting.** It was on my Phase 4 plan and I did not build it. It is needed first for activation-code
  redemption (Phase 5), so it moves there.
- **Real authentication.** Every non-public route returns 401 and no WebSocket can connect until Phase 5.
- Timing side channels are unmeasured; `trust proxy` is unset until Phase 13 (details in `authorization.md`).

**Also this session:** MinIO's image had vanished from Docker Hub and the replacement is a year stale (see
`known-risks.md`, needs an owner decision before Phase 9). Docker/WSL is fixed.

**Owed to the owner:** a *Privacy & security* settings prototype (app lock, disappearing-message timer),
required before those features are coded.

**Next agent:** do not start Phase 5 without the owner's explicit approval. Read
`docs/security/authorization.md` first. Phase 5 will implement token authentication (feeding
`request.principal` and `WS_AUTHENTICATOR`), activation-code redemption through `redeem_activation_code()`,
rate limiting, and device binding. **The test harness fakes a principal from headers; that fake must never
appear in `src/`.**

---

## 2026-09-21 (evening) — Docker working; Phase 3 schema VERIFIED; three new owner requests

**Docker.** WSL installed and the engine runs (Docker 29.8.0). Postgres 16, Redis 7 and MinIO are up and
healthy. `minio/minio` no longer exists on Docker Hub, so the compose file now uses
`quay.io/minio/minio:latest` — which is release 2025-09-07, a year stale. Fine for dev, a real risk for
production; see `known-risks.md`.

**Phase 3 verified against a live database.** 8 migrations apply, roll back to nothing, and re-apply.
75 tests (`npm run test:db`, in `apps/backend/test/db/`) pass, including 25 concurrent connections racing
one activation code (exactly one wins). A control run with a deliberately broken check-then-write redeem
let **10 of 10** racers through, so the test discriminates. **One real bug found and fixed:** `TRUNCATE`
bypassed the append-only audit log; added a `BEFORE TRUNCATE` trigger to migration 008 (edited in place,
legitimate only while nothing is deployed anywhere). Full detail and the honest gaps (timing is not
measured; no application code exists yet to test) are in `docs/database/schema.md`. Earlier I said "15
tables"; it is 17.

**Owner requests received, all logged in `decisions.md`:**

1. **PIN / Face ID / fingerprint app lock — accepted.** Local-only, must gate the keystore not just cover
   the screen, admin can never see or reset a PIN. Phase 5. Needs a prototype first.
2. **User-set disappearing messages — accepted, with honest limits.** Schema already supports it. Phase 8.
   Needs a prototype first.
3. **Admin can view all messages and media — ESCALATED, NOT IMPLEMENTED.** It contradicts the locked rule
   that admins never read messages. Three options were put to the owner (keep E2EE; disclosed compliance
   archive; E2EE now and an opt-in archive mode later). **Do not build any of it until the owner
   answers, and never build a covert version.**

**Next agent:** read the open decision in `decisions.md` first. Phase 4 does not depend on the answer and
may proceed. Start with the DB-independent pieces (config validation, exception filter, logging,
permission decorators), then `ContactGraphGuard` over `visible_user_ids()`, tested against the real
database using the harness in `apps/backend/test/db/harness.js`.

---

## 2026-09-21 (later) — Docker installed but its engine cannot start: WSL is missing

**Owner decisions:** Docker installed; graph authorization goes **in SQL** (call `visible_user_ids()` /
`are_linked()` per request, no Redis cache of the visible set — a cache adds a stale-access-after-revoke
risk that isn't worth it at this scale). That is effectively the go-ahead for Phase 4.

**State found.** Docker Desktop's CLI (29.8.0) and Compose (v5.5.1) are installed at
`C:\Users\kkhal\AppData\Local\Programs\DockerDesktop\resources\bin` — on the *persistent* PATH but not in
sessions started before the install, so use the full path or restart the terminal. Launching Docker
Desktop leaves the engine returning `500 Internal Server Error` because **WSL is not installed**
(`wsl --status` reports it missing) and Docker Desktop's Linux engine runs on WSL2. Windows 11 **Home**
has no Hyper-V alternative. Virtualization itself *is* enabled (`HypervisorPresent: True`, VBS running);
`Win32_Processor.VirtualizationFirmwareEnabled` reads `False` but is a known false negative when a
hypervisor is already running — do not send the owner into the BIOS on that basis.

**Fix (needs an elevated PowerShell, possibly a reboot — owner's call, not done by the agent):**
`wsl --install --no-distribution`, reboot if asked, then start Docker Desktop.

**A local `apps/backend/.env` was created** (gitignored) with credentials matching the dev compose
stack: `DATABASE_URL=postgres://skyline:skyline@localhost:5432/skyline`. Note `.env.example` keeps the
`change-me` placeholders; only the local `.env` uses the dev-stack values.

**Not yet done, and deliberately held:** applying the Phase 3 migrations for real
(`docker compose ... up -d`, then `npm run migrate:up && migrate:down && migrate:up`). Phase 4's guard is
SQL-backed, so it should not be built on a schema that has never touched a live Postgres. DB-independent
Phase 4 pieces (config validation, exception filter, logging, permission decorators) can proceed first.

---

## 2026-09-21 — Phase 3: schema written. Not yet run against a live database.

**Tooling chosen: `node-pg-migrate` in plain-SQL mode.** No ORM. It fits the locked decisions already
in place (raw `pg`, plain JavaScript) and keeps partial indexes, CHECK constraints and triggers
readable, which matters because this schema's security properties live in exactly those things.
Added as a devDependency with `migrate*` scripts in `apps/backend/package.json`, and `DATABASE_URL`
added to `.env.example`.

**Eight migrations written** — see `docs/database/schema.md` for the full walkthrough. Summary:
extensions/enums, RBAC, users + username history, devices/sessions/push, activation codes, the contact
graph, chats/messages/envelopes/attachments, audit log.

**The four invariants are enforced by the database, not by application code:**

1. Contact links symmetric via `CHECK (user_a_id < user_b_id)`; one live link per pair via a partial
   unique index; `are_linked()` and `visible_user_ids()` are the authorization primitives Phase 4
   builds its guard on.
2. Activation codes single use: partial unique index for one live code per user, a `BEFORE UPDATE`
   trigger that freezes redemption facts once spent, and `redeem_activation_code()` doing one atomic
   conditional `UPDATE` that returns `NULL` identically for unknown/spent/revoked/expired.
3. Usernames never reissued: `username_history` with a global `UNIQUE` plus a trigger, so a rename to
   any previously used username aborts the transaction.
4. `audit_log` append-only via triggers, and deliberately FK-free so records outlive their subjects.

**Bug found and fixed during review.** Four foreign keys were written `ON DELETE SET NULL` on columns
that CHECK constraints require to be non-null (`messages.sender_user_id`, `messages.sender_device_id`,
`activation_codes.redeemed_by_device_id`, `attachments.uploaded_by_device_id`). Deleting a device would
have violated `messages_shape` with a confusing constraint error. Changed to `RESTRICT`, which makes
the real policy explicit: **nothing is hard-deleted in Skyline** — accounts are soft-deleted, devices
and links are revoked. Documented in `schema.md`.

**Verification — read this before trusting the schema.** Docker is still not installed, so the
migrations have **never been applied to a real PostgreSQL**. What was actually verified: every
statement was parsed against the genuine PostgreSQL 18 grammar using `libpg-query` — 113 statements
across all up/down halves, plus all seven function bodies parsed individually, 0 failures. **That
catches syntax errors and nothing more.** It does not prove constraints behave as intended, that
triggers fire, or that migrations apply and roll back in order.

**Next agent must, before anything else:**

1. Install Docker Desktop, bring up `infra/docker/docker-compose.yml`, then run
   `npm run migrate:up && npm run migrate:down && npm run migrate:up` and fix whatever falls over.
   Do not build Phase 4 on an unverified schema.
2. Write the constraint tests early rather than waiting for Phase 12 — especially double-redemption of
   one code under concurrency, and renaming to a burned username.
3. Then Phase 4 (backend foundation + `ContactGraphGuard` over `visible_user_ids()`), after the
   owner approves starting it.

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
