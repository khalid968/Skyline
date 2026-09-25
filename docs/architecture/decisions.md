# Decision Log

Append-only. Each entry records what was decided, when, and why. Do not re-litigate a decision here
without the project owner's explicit say-so; if you believe one is wrong, raise it rather than quietly
working around it.

---

## 2026-09-26 (late night) — First CI run: fixes, and iOS 15 as the minimum

The first GitHub Actions run found three things that a single Windows PC could not:
- **iOS: the minimum is now iOS 15.0.** It was 13.0, but the video-thumbnail plugin needs 14 and current
  Firebase needs 15, so the app could never have built for iPhone as it was. iOS 15 runs on the iPhone 6s
  and later. A Podfile is now committed with the platform set.
- **Android (a real bug, found on the emulator): the app kept the video channel object after the call
  was set up.** On Android the plugin disposes it once negotiation finishes, so turning on the camera or
  a screen share there could have silently done nothing. The call service now looks the channel up from
  the connection every time.
- **CI machines:** Windows runs on `windows-2022` (Flutter 3.35 expects Visual Studio 2022). The Android
  job frees disk space and builds arm64 only. The timing tests get a 120 s timeout, because Argon2 is
  slower on shared runners (that was a timeout, not a leak).

## 2026-09-26 (night) — Phase 12 as built: implementation choices

- **Unavailable (board 40), server side:**
  - A direct send to a suspended person answers 409 `{unavailable: true}` and nothing is queued. The
    sender already sees "unavailable", so the answer reveals nothing new.
  - Group sends leave suspended members' devices out. The group carries on, and what is sent meanwhile
    is not theirs.
  - Suspending or reinstating publishes a `contacts` event to everyone who can see the person, and their
    apps refresh at once.
  - (The plan had said such sends were "already refused". They were in fact queued; fixed here.)
- **Security headers on every API response:** nosniff, `DENY` framing, `default-src 'none'`, no referrer,
  and `no-store`. HSTS is sent in production only.
- **The dashboard build carries a CSP** in a meta tag: self only, and inline styles only for React
  `style` attributes. Development keeps Vite's inline scripts working. Its fonts are served by the
  dashboard itself, because a request to Google would reveal every operator's address.
- **The authorization matrix and the timing tests** read the routes from the running app, so they never
  go stale.
- **Crypto-core property tests** assert the real integrity property: a changed message is refused or
  decrypts to exactly what was sent. A session-starting message carries key-agreement material that an
  established session ignores, so changing it is harmless.
- **The app's message rules moved into `MessageRules`** (pure, unit-tested), and the call service's
  outcome and freshness rules into static methods. Behaviour is unchanged: the actions and groups
  end-to-end tests still pass.
- **MinIO is built from source at RELEASE.2025-09-07 with the commit checked**, for development and CI
  alike. The production store is still Phase 13's decision.
- **Dependencies:** multer, qs and @babel/core were updated to fix advisories; npm audit is clean.
- **The load test is a committed script** that creates and drops its own database, so it can be rerun
  after any change.

## 2026-09-26 (evening) — Phase 12 (Testing and hardening) planned: owner decisions

The owner's answers:
- **CI on GitHub Actions.** Every push and pull request runs all suites: backend unit, db and app;
  dashboard; Rust test and clippy; Flutter analyze and test. There are also secret and dependency scans.
  No repository secrets are needed: tests use throwaway databases in service containers.
- **Scale target: up to 500 people on one server.** Load tests use 500 connected devices and bursts of
  50 messages a second. Budgets (p95 send under 300 ms, delivery to open sockets under 1 s) are checked,
  and fixes are made where they fail.
- **A suspended person is shown to their contacts as unavailable** (board 40):
  - The chat and its history stay.
  - The header says Unavailable, the call buttons go, and the composer becomes a plain note.
  - Nothing says why.
  - Sends to them are refused, as they already are server-side.
  - Reinstating the account restores everything.
- **iOS is built and tested on GitHub's macOS machines** (the simulator, with no signing). App Store
  signing stays with Phase 13.

The plan, in order:
1. Threat model (`docs/security/threat-model.md`).
2. CI.
3. Security tests: an authorization matrix generated from the route inventory, timing tests,
   dashboard headers and CSP, property tests for crypto-core inputs, dependency audits and refreshed
   pins (the stale MinIO image).
4. App unit and widget tests for the messaging logic.
5. Load tests at 500.
6. The "unavailable" state (board 40).
7. Close or restate every open item in known-risks and authorization.md's "Known gaps".

## 2026-09-26 (later) — Phase 11 as built: implementation choices

- **Alerts are for the owner and admins (`alerts.manage`)**, like the audit log. Alerts name operators'
  accounts and internet addresses, which is the same sensitivity as the audit trail.
- **Thresholds sit below the existing hard limits**, so detection acts first:
  - sending: 150 in 5 minutes (the limit is 120 a minute);
  - uploads: 60 starts in 10 minutes (the limit is 120 an hour);
  - wrong activation codes: 8 in an hour from one address (the limit is 10 per 15 minutes);
  - wrong dashboard passwords: 5 in 10 minutes;
  - new devices: 3 in an hour.
- **Thresholds scale with `RATE_LIMIT_SCALE`**, like every limit. Production refuses anything but 1.
- **Counters and active limits are in Redis; alerts are rows in Postgres.** The limit is set before the
  alert is written, so it holds even if the write fails. There is one open alert per kind and subject (a
  partial unique index); a repeat updates it.
- **A paused dashboard account fails exactly like a wrong password**: the same 401 and body, with Argon2
  still run for timing. A 429 for real usernames only would reveal which usernames are operators.
- **An address blocked from activating gets 429 with Retry-After.** That says nothing about any code.
- **Calls per day are counted from relay credentials divided by two**, because both sides fetch them.
  The server never sees a call.
- **Messages per day count everything that travels as a message**, including edits, reactions and call
  set-up, and each group message once. The page says so.
- **Request statistics are per instance and in memory, for the last hour**: a status and a duration
  only, with no path and no caller.
- **The CSV export is a plain GET link** carrying the session cookie. A GET changes nothing, so it
  needs no CSRF header. Cells starting with = + - @ are neutralised.
- **Entries with no actor read "Skyline" only for automatic actions** (`abuse.*`). A failed sign-in
  reads "Not signed in".
- **Overview is the landing page** after sign-in.

## 2026-09-26 — Phase 11 (Admin dashboard v2) planned: owner decisions

The owner's answers:
- **"Reporting" means usage reports only.** The dashboard shows totals: people, active today, devices,
  waiting messages, messages and calls per day, and storage.
  - Nothing is ever shown per person: not how much someone writes, not who they talk to.
  - There is no "report a person" and no "report with messages"; the latter would bend "admins never read
    messages".
- **Abuse detection: alerts plus automatic limits.** Signals are metadata only (counts and timing).
  Automatic actions slow things down and never suspend anyone:
  - a device sending far too fast: 1 message per 5 s for 30 minutes;
  - an address guessing activation codes: blocked for 1 hour;
  - wrong dashboard passwords: that account's sign-in paused for 15 minutes;
  - uploads far above normal: one upload at a time for 30 minutes;
  - a burst of new devices: alert only.

  Every automatic action appears in the alert and in the audit log, and an admin can lift it early.
  Suspending remains a human decision.
- **Audit log: the owner and admins can read it; moderators cannot.** It stays append-only (a
  database trigger already refuses UPDATE, DELETE and TRUNCATE). It gets a CSV download.
- **Monitoring: a built-in Overview page.** It shows the health of the server, Postgres, Redis, MinIO
  and coturn, storage used, connected devices, waiting messages, and the error rate. No
  Prometheus or Grafana.
- **Sessions page:** it lists dashboard sessions. Operators can end their own, and the owner can end
  anyone's, or everyone's but their own. Member devices stay on the Devices page (revoking one signs it
  out).

Prototypes 36-39 were drawn for approval, and approved the same day ("looks good").

## 2026-09-25 (night) — Phase 10 (Calls) as built: implementation choices

- **Setup is two Signal-encrypted messages** (offer and answer, with all candidates gathered first, no
  trickle), plus small control messages: taken, decline, busy, hangup. The DTLS fingerprints ride inside
  them, so the media is bound to the verified Signal identities. The server sees only ordinary
  ciphertext envelopes.
- **Relay only** (owner decision): `iceTransportPolicy: relay`, one ICE server entry per URL (the Windows
  plugin keeps only the last URL of a list), and coturn credentials that last 10 minutes.
- **One video channel from the start.** The caller creates it and the answerer adopts the one in the
  offer, so switching the camera or a screen share on is a `replaceTrack` and never a renegotiation.
- **Freshness uses the server's clock.** The inbox reports how long the server held each envelope
  (`ageMs`), and an offer older than 50 s is recorded as missed instead of ringing. The caller's clock
  is never trusted: an emulator 345 s behind turned every call into a missed call.
- **Only the device on the other end can end a call.** A hangup from any other device is ignored.
  Answering on one of your devices stops the others ringing.
- **Android screen sharing** follows Android 14's order: consent first
  (`Helper.requestCapturePermission`), then a foreground service of type mediaProjection with a visible
  notification, then the capture.
- **The call screens sit above the navigator**, so they cannot use Tooltips (there is no Overlay there)
  and they use fixed light text colours whatever the theme.

## 2026-09-25 — Phase 10 (Calls) started: owner decisions and plan

**The owner decided:**

- **One-to-one voice and video calls in v1.** Group calls come later: they need a media server (SFU) and
  frame encryption on top, a phase of their own.
- **Every call goes through our own relay (TURN, in Docker Compose).** Neither person learns the other's IP
  address. The relay only forwards encrypted packets. The cost is slightly more delay.
- **Screen sharing on Windows and Android.** iPhone screen sharing needs an Apple broadcast extension and
  comes with the rest of iOS.

**How it will be built** (implementation choices):

- **WebRTC through `flutter_webrtc`** (Android, iOS, Windows).
  - Audio and video are encrypted end to end between the two devices (DTLS-SRTP). The relay cannot
    decrypt them.
  - The app checks that each side's DTLS fingerprint is the one sent inside the Signal-encrypted call
    setup. So the call is bound to the verified Skyline identities, and a relay or server in the middle
    cannot join.
- **Call setup travels as ordinary encrypted Skyline messages** (offer, answer, network candidates, hang
  up), pairwise to the contact's devices. The server sees only that messages were sent.
- **Only direct contacts can call each other.** Calls are messages, so the contact graph rule applies
  unchanged. Sharing a group is not enough.
- **Relay credentials:** short-lived and issued per call by the server (`GET /calls/turn`, members only),
  so the relay is useless to anyone outside Skyline.
- **Ringing when the app is closed** uses the existing content-free wake-up. The app wakes, fetches and
  decrypts the offer, then rings. iPhone ringing (PushKit/CallKit) needs the Apple developer account and
  comes with iOS.
- **No recording, ever.** Nothing about a call's content touches the server.
- **Prototypes first** (boards 32-35): incoming call, voice call, video call with screen sharing, and calls
  in a chat.

---

## 2026-09-25 (later) — Phase 8b as built: implementation choices

Boards 26-31 were approved ("looks good"). Choices made while building, within the owner's decisions:

- **View once stays one-to-one.** In a group, the "opened" notice would need to reach every member's
  devices and still leave the others able to view it once each; not designed yet. The toggle is hidden in
  groups.
- **Groups send no read receipts.** Delivered ticks still work (any member's device has it).
- **Sender Keys:** the app picks a new distribution id whenever a device holding the current key is no
  longer a member device, and it records which distribution ids each sender device handed over for each
  group. A group message under any other id is refused. A message that arrives before its key waits,
  sealed in the vault (at most 300), and is retried when the key comes.
- **Mute** is kept on the device. It quiets the chat list (a grey count; an archived chat stays archived).
  Push wake-ups carry no chat id, so a phone still shows the generic "New message" for a muted chat while
  the app is closed. This is a known limit.
- **Emoji picker:** recently used emoji are not stored, because that list would sit in unencrypted app
  storage.
- **Test servers** now use their own rate-limit counters (`RATE_LIMIT_PREFIX=skyline-e2e`), so test runs
  never count against the owner's dev server.

---

## 2026-09-25 — Phase 8b started: owner decisions and plan

**The owner decided** (asked at the start of 8b):

- **Groups are managed in the dashboard now**, not in Phase 11. Admins and moderators can create, rename,
  archive, and add or remove members, as for contacts. **A member may leave a group from the app**; only an
  admin can add them back. Users still cannot create groups or add anyone (the locked rule stands).
- **Any member can set a group's disappearing timer.** The change is announced in the group, as in
  one-to-one chats.
- **Edit within 15 minutes; delete for everyone within 24 hours.** An edit shows "edited"; a deletion leaves
  "This message was deleted". Deleting only for yourself is always allowed.
- **Anyone can pin**, up to 3 messages per chat, and each pin is announced. **Reactions: six quick ones plus
  the full emoji picker.**

**How it will be built** (implementation choices):

- **Group encryption uses libsignal's Sender Keys** (Signal's own group mechanism), not new cryptography.
  - Each member's device encrypts a group message once, with its sender key.
  - That sender key is shared with the other members' devices over the existing pairwise sessions.
  - When anyone leaves or is removed, every remaining member's sender key is replaced, so a former member
    cannot read what comes after.
  - The server checks group membership on every send and every delivery, exactly as it checks contact
    links: 404 outside the group.
- **Replies, edits, deletions, reactions, pins and mentions are all encrypted messages** that point at an
  earlier message id. The server sees them as ordinary ciphertext.
  - The time limits are enforced by every receiving app: an edit over 15 minutes, or a delete over
    24 hours, is ignored.
  - A modified app could still send one, but it would not be shown.
- **Search is local only.** It looks through the messages on this device. The server holds nothing
  readable, so there is nothing to search there. It never finds people: the contact graph rule is untouched.
- **Drafts, archive and mute are kept on each device, in the encrypted vault.** They are never sent to the
  server. A muted chat still gets its wake-up, but shows no notification.
- **Prototypes first** (boards 26-31): the chat list with groups, archive and mute; a group conversation;
  message actions; the group info screen and mentions; search; and the dashboard's Groups page.

---

## 2026-09-25 (night) — Several files, view once, media gallery (boards 23-25 approved)

**The owner approved** boards 23-25 ("looks great"). How they are built:

- **Several files at once.**
  - Up to 10 per send. Photos and videos become **one message** (an album) that claims all its files in
    the same send transaction; the server already allowed 10 `attachmentIds`.
  - Documents and voice messages go as their own messages. The caption rides on the album, or on the
    first document if there is no album.
  - Each file still has its own random key.
  - Previews travel inside the encrypted message, and one device's copy is limited to 48 KB. So an album
    carries small previews (under 6 KB each) for the four tiles it shows, and none for the rest; those
    appear once downloaded.
- **View once.**
  - For a single photo or video. The message carries `once: true` and **no preview at all**: a preview
    would outlive the one viewing.
  - The sender's device forgets the key and deletes its copy as soon as the message is out. The sender's
    other devices never keep a key either.
  - The recipient's device downloads it (photos automatically, so it opens offline). When the viewer
    closes, the device forgets the key and deletes the file.
  - It then sends an encrypted `opened` notice to the sender and to its own other devices, which delete
    their copies too.
  - **The `opened` notice goes even with read receipts off**, because it is the only way the recipient's
    other devices learn to delete it. So the sender sees "Opened" whatever the receipt setting. If the
    notice cannot be sent (offline), it is queued and sent on reconnect.
  - An `opened` notice is accepted only for a message in that same chat.
  - While a view-once item is on screen: Android sets FLAG_SECURE; Windows excludes the window from
    capture (`SetWindowDisplayAffinity`). iPhones cannot block screenshots, and the viewer says so.
  - **The server copy is not deleted early.** It stays, encrypted, until the 30-day sweep. Once every
    device has forgotten the key it cannot be decrypted by anyone. Deleting it early would need a new
    "delete my upload" route, which is a possible follow-up.
- **Media gallery.**
  - `/chat/:peer/media`, from a new Media button in the chat header.
  - It lists only what is on this device and still in the chat. Disappearing messages, view-once
    messages, expired files and failed sends never appear.
- **Found and fixed while building:** when an album's photos finished downloading together, their updates
  of the one stored message could overwrite each other. Updates to a message are now serialised.

---

## 2026-09-25 (later) — Media preparation before sending (within approved boards 20-22)

Implementation choices, not owner decisions. They fill in what boards 21 and 22 already show.

- **Photos are re-encoded before they are encrypted.**
  - At most 2048 px on the long side, JPEG at quality 82. PNG stays PNG, so screenshots keep sharp text.
  - Re-encoding drops the EXIF block, so **location, camera and date details never leave the device**.
  - Animations and formats the app cannot decode (HEIC, for one) go as they are.
  - To send a photo untouched, send it as a File.
- **Videos get a thumbnail and their length on every platform** (`fc_native_video_thumbnail`, and the video
  player). Both travel inside the encrypted message.
- **Videos over 12 MB are compressed on phones** (`video_compress`, medium quality). Windows has no
  converter we can ship, so it sends videos as they are.
- **"Save to this device" puts the photo in the phone's gallery** (`gal`), as board 22 says. Windows keeps a
  "save as" dialog.
- None of the new packages contains analytics or trackers (checked in the package sources).

---

## 2026-09-25 — Media (Phase 9) brought forward, before 8b: owner decisions and design

**The owner decided** (after trying 8a): media now, then Phase 8b.

- **Types:** photos, videos, files and documents, and voice messages.
- **Size limit:** 2 GB per file.
- **Retention:** the server keeps each encrypted file for **30 days, then deletes it** (even if downloaded).
- **File store:** MinIO for development, **pinned to a fixed version**; the production store is decided in
  the Deployment phase. The code speaks S3, so switching is a configuration change. This keeps the
  known-risk about the stale MinIO image open until then.

**How it is built** (implementation choices within those decisions):

- **Encryption happens on the phone, streaming.** Each file gets a fresh random 32-byte key and 12-byte
  nonce, and is encrypted with libsignal's own streaming AES-256-GCM (`signal-crypto`,
  `Aes256GcmEncryption`). The 16-byte tag is appended. No new cryptography.
  - Decryption writes to a temporary file, and nothing is shown until the tag verifies.
  - The key, the nonce, the file name, the type and a small thumbnail travel only inside the encrypted
    message. The server sees an opaque blob, its size and its SHA-256.
- **Uploads are resumable and go through the Skyline server,** in 8 MB chunks, as an S3 multipart upload.
  MinIO is never exposed to the internet. Every chunk and every download is authorised by the server.
- **Download is authorised by the contact graph:** only the uploader, and the people in a chat whose message
  carries the file (while their link is live). Anyone else gets the usual 404.
- **On the device, media stays encrypted at rest.** The downloaded ciphertext is kept, and its key lives in
  the vault. It is decrypted into memory (photos) or a short-lived cache file (video, files) only while
  being viewed. Disappearing messages delete their media too.
- **Auto-download:** photos and voice messages download automatically; videos and files download when
  tapped, to save data.

---

## 2026-09-24 — How messages move (Phase 8a design; boards 16-19 approved)

These are implementation choices within the owner's Phase 8 decisions.

- **One inbox, pulled.** Each device fetches its own encrypted copies from `GET /me/inbox` and acknowledges
  them. The WebSocket, and later push, only send a content-free nudge (`inbox`) that tells the device to
  pull. Ciphertext never goes through fan-out, and "online", "woken by push" and "back from offline" are one
  code path.
- **The server erases ciphertext on acknowledgement.** The envelope row stays for the delivery tick, with
  `ciphertext` NULL. A trigger makes that one-way: bytes can never change, and never come back.
- **Every live device gets a copy:** each of the recipient's devices and each of the sender's OTHER devices
  (so your PC shows what you sent from your phone). A send that does not cover exactly that set is refused
  with 409, listing what is missing or unknown. The client fetches the missing bundles and retries. This is
  Signal's model.
- **Read receipts are encrypted messages**, indistinguishable from others to the server, which therefore
  never learns when anyone read anything. **Typing indicators** are encrypted too, relayed only to devices
  that are online, and never stored.
- **The disappearing-message timer lives inside the encrypted messages.** Setting it is itself a message,
  shown as a notice on both sides. Devices delete on their own. The server does not know a chat's timer
  (`chats.disappear_seconds` stays unused) and has nothing to delete, because it erased the ciphertext on
  delivery.
- **"Added a new device" notices come from the client**, generated when a contact's device list grows. A
  server announcement would be the server vouching for itself; the client's own observation is what a
  malicious server cannot fake quietly. Before trusting the first message from any device, the client
  checks its identity key against the key directory (the Phase 8 item in `known-risks.md`).
- **Server system messages** (the admin rename, a locked decision) reach devices through the same inbox, in
  order, with a per-device cursor. A new device's cursor starts at "now", so it starts empty.
- **Messages are idempotent by a client-chosen id**, so a retry after a dropped connection never delivers
  twice.
- **Message history on the device lives in the crypto core's vault** ("records": the same SQLite file, the
  same AES-256-GCM-SIV key held in the OS keystore). Record and chat ids are HMAC'd; only a sort number (the
  time) is readable in the file. SQLCipher was the alternative, but its maintained Flutter packages need
  Dart 3.10+ (this toolchain has 3.9.2) and the older ones are end-of-life. This way adds no dependency and
  no cryptography.
- **The QR scanner is zxing-cpp (`flutter_zxing` 2.2.1), not `mobile_scanner`.** On Android, `mobile_scanner`
  is built on Google's ML Kit, which reports usage data to Google: that is telemetry, which Skyline forbids.
  zxing-cpp decodes entirely on the device. Scanning is offered on phones; on a PC you compare digits. The
  match itself is libsignal's scannable-fingerprint comparison, done in the crypto core.
- **The app-lock PIN is an Argon2id hash inside the vault**, and the wrong-attempt count and backoff are
  kept in the core, so force-closing the app does not reset them.
- **A 409 may carry a structured body** (`PublicBodyException`). The contact graph never answers 409, so
  404s still cannot be told apart.

---

## 2026-09-24 — Phase 8 (Messaging) scope and ground rules, decided by the owner

- **Phase 8 is split in two, with a review after each.**
  - **8a** is one-to-one chats that work end to end: the activation screen, chat list, encrypted
    send/receive with offline queueing, delivery and read ticks, system notices (rename, new device),
    safety numbers with the sender-identity check (`known-risks.md`), disappearing messages, app lock, and
    Privacy & security settings.
  - **8b** is groups, replies, edit/delete, reactions, mentions, pinned messages, search, drafts, archive
    and mute.
- **Push is an empty wake-up through Apple (APNs) and Google (FCM).** The notification carries no sender,
  no text and no chat id: only "something new". The app wakes, fetches from the Skyline server and decrypts
  locally. Apple and Google learn only that, and when, a device got something. This is Signal's model. It
  needs a Firebase project (Android) and an Apple developer account (iOS). Windows is served by the
  WebSocket while the app runs.
- **Read receipts and typing indicators are on by default, and each person can switch them off** in
  Privacy & security. Switching yours off also hides other people's from you, which is reciprocal, as in
  Signal.
- **A new device starts with no history.** Messages are encrypted per device, and the server deletes each
  envelope's ciphertext once that device has it, so no stored backlog exists to leak. A device-to-device
  history transfer may come later as its own design.

---

## 2026-09-24 — How Phase 7 was built (implementation choices)

None of these changes an owner decision.

- **libsignal is pinned by tag (`v0.103.1`), and `crypto-core/Cargo.lock` is committed.** Upgrades are
  deliberate (read the release notes). The Rust toolchain is pinned to libsignal's (`1.98.1`,
  `crypto-core/rust-toolchain.toml`).
- **Three crates:**
  - `core` is pure and tested: the libsignal integration and the key vault.
  - `ffi` is a thin `flutter_rust_bridge` layer that only converts types.
  - `e2e` is a development tool that plays two devices against a running backend.

  The bridge's generated code never touches `core`, so `core` is testable without Flutter.
- **The on-device key vault.** It is one SQLite file.
  - Every value is sealed with AES-256-GCM-SIV. Row ids are HMAC'd, so the file does not reveal who the
    device talks to. Both subkeys are derived with HKDF from a 32-byte storage key that lives only in the
    OS keystore (`flutter_secure_storage`: Keychain with *this-device-only*, Android encrypted prefs,
    Windows Credential Manager).
  - This composes standard primitives; it is not new cryptography.
  - A vault that exists but cannot be read with the key is refused (`VaultLocked`) and never overwritten.
    Recovery is a new activation code, like a new phone.
- **Identity trust is strict.** A different identity key for a device we already know is refused, never
  accepted with a warning. Skyline identities cannot change (the server refuses to change one), so a new key
  can only mean an attack or a bug.
- **Activation signature v2 covers the Signal identity:**
  `skyline-activate:v2:<code>:<identityKey b64>:<registrationId>`. Whoever holds the device credential
  provably chose that identity key.
- **libsignal device ids** are `devices.device_number` (1..127). A number is never reused for the same
  person, even after revocation, so a new device can never inherit an old device's sessions.
- **The server does not verify prekey signatures.** Doing so would mean linking libsignal into the backend,
  which would make the backend AGPL (forbidden by the licence decision), or writing XEdDSA ourselves, which
  would be custom cryptography. It does not need to: libsignal verifies every signature on the fetching
  device before use (tested: a substituted signed prekey or Kyber key is refused). The server checks shapes
  only.
- **Key draining is rate-limited per caller device.** At most 20 bundle fetches per contact per hour and 300
  in total. The rate-limit guard runs before authentication and cannot see the caller, so these limits are
  enforced in the service with `enforceLimit()` from the now-global `RateLimitModule`.
- **The Android, iOS and Windows runner folders are committed.** They carry real configuration. macOS,
  Linux and web are not v1 platforms and are not generated.

---

## 2026-09-23 — Phase 7 (Encryption) ground rules, decided by the owner

- **The AGPL-3.0 licence of `libsignal` is accepted.** The Skyline client apps link `libsignal` and are
  therefore AGPL: their source must be offered to the people who receive them (the members). The backend and
  the admin dashboard do not link it and are unaffected; keep it that way, and never link `libsignal` into
  either. This is the same model Signal uses. Every non-AGPL alternative is an unaudited reimplementation,
  which the "no custom cryptography" rule forbids.
- **Each device has its own keys.** Every device is activated with its own admin-issued code, generates its
  own identity key and prekeys, and is verified separately (one safety number per device). A contact sees a
  system notice when someone adds a device. Senders encrypt to each of the recipient's live devices.
  - *Rejected:* one shared identity with linked devices, as in Signal or WhatsApp. Copying the identity key
    between devices needs a provisioning protocol that `libsignal` does not fully provide, so we would have
    to write cryptographic glue ourselves.
- **The key exchange is `libsignal`'s current default, PQXDH** (X3DH with post-quantum Kyber prekeys), not
  classic X3DH. The roadmap's "X3DH" means whatever `libsignal` currently uses.
- **Toolchain.** Claude installs Rust (MSVC) and the Microsoft C++ Build Tools through winget on the
  owner's machine.
- **No Mac is available**, so iOS is built and tested later. Phase 7 is proven on Windows and Android; the
  iOS side is kept buildable in principle but is untested until a Mac or a cloud Mac exists.

---

## 2026-09-23 — How the dashboard holds its session; the protected owner

These are implementation choices made while building Phase 6. None of them changes an owner decision.

- **The dashboard session is an HttpOnly, SameSite=Strict cookie (`skyline_admin`), not a token in the
  page.** The backend sets the cookie only when the login request carries `x-skyline-client: dashboard`, and
  then leaves the token out of the response. Script on the page never sees the token, so an injected script
  cannot steal it. Bearer tokens still work for scripts and the CLI.
- **CSRF: any cookie-authenticated change must carry `x-skyline-client: dashboard`.** This covers every
  method except GET, HEAD and OPTIONS. Another website cannot set a custom header on a cross-site request, so
  it cannot make the browser perform an admin action. The rule sits on top of SameSite=Strict as a second
  layer.
- **The dashboard and the API share one origin.** In development the Vite server forwards `/api/*` to the
  backend. In production Nginx will do the same (Phase 13). As a result the backend has **no CORS
  configuration at all**. Do not add one.
- **Operator accounts are created `active` and get a temporary password.** They cannot sign in to the
  dashboard until they redeem a phone code, which was a real bug found while testing. The temporary password
  sets `must_change_password`, and the server allows only the account routes until the operator chooses a
  new password.
- **The protected owner is enforced in the database.** A trigger rejects any change that would demote,
  suspend or delete the owner, and any change that would create a second owner. The API checks the same
  rules first, so the operator sees a readable 403.

---

## 2026-09-23 — Phase 6 prototypes approved; timer range; owner resets

**Approved by the owner:** design boards 9-15 (admin sign-in, 2FA code, account & 2FA setup, devices; mobile
Privacy & security, lock screen, disappearing-message timer), and both proposals shown with them:

- **The owner resets a locked-out admin's password or two-factor.** There is no self-service reset. The reset
  is audit-logged and signs the target out everywhere.
- **The v1 dashboard sidebar is Users, Contact graph, Devices** (groups and the audit viewer are v2).

**Disappearing-message timer (owner's change):** presets Off, 1 hour, 1 day, 1 week, 1 month, 3 months,
6 months, 1 year, plus **Custom: any duration from 5 minutes to 1 year** (minutes, hours, days, weeks or
months). The schema already enforces 5 seconds to 1 year (`chats.disappear_seconds`), so no migration is
needed; the client offers 5 minutes as its shortest. Longer than a year would need a schema change and the
owner's say-so.

---

## 2026-09-23 — Phase 6 (admin dashboard v1) scope and stack

**Decided by the owner:**

1. **React, plain JavaScript** for `apps/dashboard/`, matching the backend's language.
2. **v1 scope: users and activation codes, the contact-graph editor, and devices**, plus sign-in, 2FA and
   account settings. **Groups and the audit-log viewer move to v2 (Phase 11).** Consequence: until then,
   members can only have one-to-one chats, since groups can only be created by an admin.
3. **A protected owner account.** The owner (the first admin, created by `admin:create`) cannot be demoted,
   suspended, renamed or deleted by another admin, and only the owner can create, promote or remove admins.
   Needs a schema marker (e.g. `users.is_owner`, at most one) enforced in the database, not just the UI.
4. **The mobile Privacy & security screen** (app lock, disappearing-message timer) is prototyped in the same
   design round.

**Decided by the agent (reversible):** the dashboard keeps its session in an **HttpOnly, Secure, SameSite=Strict
cookie**, not a token readable by JavaScript, so a malicious script on the page cannot steal an admin session.
Requires CSRF protection on state-changing requests.

**Process:** screens not yet approved (sign-in, 2FA code entry, account/2FA setup, device list, the mobile
Privacy & security screen) are prototyped and approved before any code.

---

## 2026-09-23 — Phase 5 authentication model

**Decided by the owner:**

1. **Members have no password.** The one-time activation code is the only way in; afterwards the device
   holds the credential. No recovery codes: a lost phone means an administrator issues a new code. App
   lock (PIN/biometric) protects the phone locally.
2. **Administrators sign in to the dashboard with a password; two-factor (TOTP authenticator app) is an
   optional step each admin may turn on.** Chosen for simplicity at the start. Known trade-off: an admin
   who skips 2FA is protected by the password alone, and admins control the whole contact graph. Mitigated
   by Argon2id hashing and rate limiting. Easy to make mandatory later.
3. **Each device registers an Ed25519 signing key at activation** (Node's built-in, vetted implementation
   — no custom crypto) and must sign every token refresh with it, so a stolen refresh token alone is
   useless. `devices.identity_key` and `devices.registration_id` (the Signal Protocol fields) become
   nullable until Phase 7 fills them.

**Decided by the agent (cheap to reverse, listed so the owner can object):**

- **Tokens are opaque random strings**, stored only as HMAC-SHA256 hashes under a server pepper, and looked
  up in Postgres on every request, consistent with the no-caching rule. A JWT would buy nothing here and
  could not be revoked instantly. Device access tokens last 15 minutes; refresh tokens 30 days and rotate
  on every use, and presenting an already-rotated refresh token revokes the whole session (theft detection).
- **Operator routes accept only a dashboard session; member routes accept only a device session.** This
  enforces the locked decision that admin tooling is separate from the app: even an admin's own phone
  cannot call operator APIs.
- **Rate limiting fails closed** on the authentication endpoints: if Redis is down, activation and login
  are refused rather than left unthrottled.
- **Activation codes are 100 bits** (20 Crockford base32 characters, `SKY-XXXXX-XXXXX-XXXXX-XXXXX`), not
  the 128 the schema comment assumed. With a keyed hash, rate limiting and a 72-hour expiry, 100 bits is
  far beyond guessable, and it is shorter to type.

---

## 2026-09-21 — The WebSocket is server-to-client only; clients send over REST

**Decision.** The gateway ignores every inbound frame. Clients send messages over authenticated REST, and
receive over the socket.

**Why.** REST is where the three guards run per request. If a client could also send by writing to the
socket, every guard would have to be reimplemented there, and any gap would be a way to bypass the contact
graph. One-directional removes the whole class. Delivery still re-checks the graph at the moment it
happens, so revoking a link stops an already-open socket immediately.

---

## 2026-09-21 — Authorization is checked against Postgres on every request; it is never cached

**Decision (owner).** Account status, device revocation, role permissions and the contact graph are read
from PostgreSQL on every request, and by the WebSocket fan-out on every delivery. No Redis or in-process
cache.

**Why.** A cache makes each of these wait for expiry: a suspended user keeps working, a revoked device
keeps connecting, a revoked contact keeps receiving. For a product whose value is containment that is the
wrong trade. The cost is two extra queries per request, accepted at this scale.

**Consequence.** Measure before optimising, and never optimise by caching authorization. If load ever
demands it, prefer a faster query or a read replica over a cache.

---

## 2026-09-21 — DECIDED: true E2EE for v1; a disclosed compliance archive is a possible later mode

**Status: RESOLVED by the owner on 2026-09-21 — option 3 below.** v1 ships with true end-to-end
encryption; admins never see message content. A disclosed compliance archive may be designed later as an
opt-in deployment mode. **Nothing archive-related is built now**, and the locked rule "admins can never
read messages" stands for v1. Revisiting it needs the owner's explicit go-ahead and its own design phase
(key management, access audit, threat model) *before* Phase 7 (Encryption). The analysis that led to this
decision follows.

**The request.** "Give the admin the power to view all messages and media and have a history of
everything."

**Why it is escalated rather than built.** It contradicts, directly, a locked decision and a core design
property: admins can never read messages (`contact-graph.md` rule 7). The server holds only ciphertext;
private keys never leave devices; the seeded `permissions` table deliberately has no permission that
could grant plaintext. Implementing this is not a feature toggle. It changes what kind of product Skyline
is. Per the project rules that call is the owner's, not an agent's.

**What an admin can already see (the "history of everything" that needs no change).** The audit log of
every admin action; account, device, session and activation-code history; the full contact-link and
group-membership history; and message *metadata* (who, which chat, when, ciphertext size). Everything
except the content.

**Options put to the owner:**

1. **Keep true end-to-end encryption.** Admins get all of the above, never content. Strongest security
   claim; simplest; the position the whole design and prototype assume.
2. **A disclosed compliance archive.** Every message and attachment is *additionally* encrypted to an
   organization archive key, held by a designated compliance role and used under audited, ideally
   dual-control access. Users are told plainly and permanently. This is a real enterprise category, but it
   is a different product claim: it is no longer end-to-end between the two people, and the archive key
   becomes the single most valuable secret in the system.
3. **Ship option 1 now; design option 2 later as an opt-in deployment mode**, so the core stays clean.

**Constraints that apply to any version of option 2, so they are recorded before the choice is made:**

- **It must be disclosed to users**, in the app, permanently, not buried in terms. Reading people's
  messages without their knowledge is deceptive and, in many jurisdictions, unlawful. An agent will not
  build a covert variant.
- **It defeats disappearing messages** (below). If the archive retains everything, "messages delete
  automatically" is false for the archive, and the UI must not claim otherwise.
- It needs its own key management design, access audit log and threat model before any code.
- It re-opens the locked decisions "admins can never read messages" and "server holds only ciphertext",
  which must then be explicitly revised, not quietly bypassed.

---

## 2026-09-21 — ACCEPTED: PIN / biometric app lock (prototype required before code)

**Request (owner).** Users can protect the app with a PIN, Face ID or fingerprint.

**Design constraints:**

- **Purely local.** Biometric matching is done by the operating system (Face ID / Touch ID, Android
  BiometricPrompt, Windows Hello). The app never receives biometric data. The PIN never leaves the
  device and is never sent to the server.
- **It must gate the keys, not just cover the screen.** Store device key material in the platform
  keystore (iOS Keychain, Android Keystore, Windows DPAPI/Hello) flagged as requiring user
  authentication. A lock screen drawn over an unlocked app is decoration, not security.
- Escalating lockout delays after wrong PINs. An optional "erase after N failures" is destructive and
  strictly opt-in.
- **An administrator can neither see nor reset a user's PIN.** A forgotten PIN means the on-device keys
  are unrecoverable: the user re-activates with a fresh activation code and loses local history. The
  server never held a copy, so this is unavoidable and must be said plainly in the UI.
- **Decided (owner, 2026-09-21): app lock is always the user's own choice.** There is no admin policy
  to force it on. This also keeps the admin surface smaller: no policy setting, and one less thing an
  admin can do to a user's device.

Lands in Phase 5 (Authentication). It is UI, so a settings prototype is needed first.

---

## 2026-09-21 — ACCEPTED: user-set disappearing messages, with honest limits

**Request (owner).** Users choose how long until messages are deleted from the device automatically.

**Design.**

- A per-chat timer. The schema already supports it: `chats.disappear_seconds` (5 seconds to 1 year) and
  `messages.expires_at`.
- The client deletes its local copy at expiry. The server deletes ciphertext envelopes once delivered or
  expired.
- **Changing the timer is announced as a system message in the chat**, for the same reason a rename is:
  a silent change would let one party quietly shorten the other's retention.
- Recommended: the timer starts when the message is **read**, not sent (as in Signal).
- **Honest limits, and the UI must not overpromise:** it cannot be enforced against a modified client, a
  screenshot, or a photograph of the screen. It deletes cooperatively-run copies, nothing more.
- **Open questions:** who may set the timer in a group (groups are admin-managed, so likely admin-set);
  whether an admin may impose an organization-wide minimum or maximum.
- **Conflicts with the pending decision above.** If a compliance archive exists, disappearing messages do
  not apply to it.

Lands in Phase 8 (Messaging). It is UI, so a prototype is needed first.

---

## 2026-09-21 — Migrations are plain SQL run by `node-pg-migrate`. No ORM.

**Decision.** `node-pg-migrate` in `-j sql` mode. Migrations are `.sql` files with `-- Up Migration`
and `-- Down Migration` sections, in `apps/backend/src/database/migrations/`.

**Why.** The backend already uses raw `pg` and plain JavaScript, both locked decisions. This schema's
security properties live in partial indexes, CHECK constraints and triggers — things an ORM either
hides, generates badly, or cannot express. Plain SQL keeps them reviewable, which for this project
matters more than developer convenience.

---

## 2026-09-21 — Nothing is hard-deleted.

**Decision.** Accounts are soft-deleted (`status = 'deleted'` plus `deleted_at`). Devices, sessions,
push tokens, contact links and group memberships are revoked, never removed. `username_history.user_id`
is `ON DELETE RESTRICT`, so `DELETE FROM users` fails by design.

**Why.** Partly principle — an audited system should not let operators erase history — and partly
because it is the only way the never-reissue-a-username guarantee stays true. It also resolved a bug:
four foreign keys were `ON DELETE SET NULL` on columns that CHECK constraints require to be non-null,
so deleting a device would have failed with a confusing constraint violation. Making them `RESTRICT`
turns an accidental failure into an intentional rule.

**Consequence.** The dashboard's "Delete account" is a soft delete. If a hard delete is ever genuinely
required (a legal erasure request, say), it needs a deliberate, audited procedure — not a `DELETE`.

---

## 2026-09-20 — Activation codes are strictly single use.

**Decision.** An activation code is redeemable **exactly once**, binds to the one device that redeems
it, and is dead thereafter. Issuing a replacement creates a new code and never revives a spent one.
Codes also expire after 72 hours unredeemed.

**Why.** Requested by the project owner. A reusable code is a shared secret that silently turns into a
second way into an account — it defeats the point of manual provisioning.

**Implementation requirements (Phase 3 schema / Phase 5 auth), not optional:**

- `activation_codes` stores a **hash** of the code, never the code itself. It is shown once, at
  creation, and is unrecoverable afterwards.
- Redemption is a single atomic transaction: `UPDATE ... SET redeemed_at = now(), redeemed_by_device_id = $1
  WHERE id = $2 AND redeemed_at IS NULL` and the code is spent only if that statement affects one row.
  A `UNIQUE` partial index enforces it at the storage layer too. **Do not implement this as
  check-then-write** — that races, and two devices could redeem the same code concurrently.
- A spent or expired code returns the same generic failure as a nonexistent one, with no timing
  difference. Distinguishing them lets an attacker enumerate valid codes.
- Redemption attempts are rate limited per source and written to the audit log.

---

## 2026-09-20 — Administrators can rename any user; renames are announced and never touch keys.

**Decision.** An admin can change any user's **display name** and **username** from the dashboard.
Three constraints ship with the capability:

1. Every rename is written to the audit log with the old value, the new value, the acting admin, and a
   timestamp.
2. Every rename is announced as a system message inside each conversation the renamed user is part of
   ("Admin changed this contact's name from X to Y").
3. A rename **never** alters identity keys. Safety numbers a contact has already verified stay valid,
   and no re-verification prompt is triggered.

**Why.** The rename itself was requested by the project owner. Constraints 1–3 are mine, and they close
a real hole: in a network where users cannot search or independently confirm who anyone is, an admin who
could silently rename "Daniel Okonkwo" to "Sarah Whitfield" could socially impersonate one user to
another. The audit entry plus the in-chat announcement makes that loud instead of silent. Keeping keys
untouched means the cryptographic identity remains the thing users actually verify — the display name is
explicitly cosmetic.

**Also:** a released username is never reissued to a different account, so an old handle cannot be
inherited by someone else.

---

## 2026-09-20 — v1 ships on iOS, Android and Windows. Web is dropped for the messaging client.

**Decision.** The Flutter client targets iOS, Android and Windows for v1. macOS and Linux are cheap
follow-ons from the same codebase but are not promised. The **Web messaging client is out of scope**.

**Why.** Skyline's E2EE depends on Signal's official `libsignal-client` Rust crate, and there is no
official WebAssembly build of it. Signal's own tracking issue for a WASM target
(<https://github.com/signalapp/libsignal/issues/350>) is open, and their earlier JavaScript
implementation is archived and explicitly unmaintained. The remaining options are community WASM
wrappers and an academic reimplementation — none audited by Signal. Shipping a browser client on any of
those would break the project's founding rule: **no unaudited cryptography, ever**. Rather than weaken
the guarantee for browser users or ship a second, unproven crypto path, Web is deferred until an
official WASM target exists.

**Consequence.** `known-risks.md`'s open Web/WASM risk is closed as *deferred by scope*, not solved.
Revisit only if Signal ships an official WASM build.

---

## 2026-09-20 — Admin tooling is a separate web application, not in-app admin screens.

**Decision.** Administration lives in a dedicated browser-based dashboard, served separately from the
messaging client. The scaffolded `apps/mobile/lib/features/admin/` directory is **not** the admin
surface and should be removed or repurposed when Phase 6 starts.

**Why.** Keeping admin code out of the binary that end users install removes the admin UI, its routes
and its endpoints from every user device — a meaningful reduction in attack surface for a product whose
entire value is containment. It also gives admins a screen size suited to managing a contact graph.

**Note.** This is web, but it is *safe* web: the dashboard manages identities, links and permissions and
never holds message keys or plaintext, so the WASM problem above does not apply to it.

---

## 2026-09-20 — Contacts are fully locked: no discovery, no user-created groups, no request flow.

**Decision.** Option "fully locked". Admins assign every contact link and every group membership. Users
cannot search, browse, discover, or request. See `contact-graph.md` for the full specification.

**Why.** Chosen by the project owner. A contact-request flow was offered and declined for v1; it can be
added later without changing the schema.

**Consequence.** The contact graph moved from Phase 9 to Phase 3 — it is an authorization invariant
every endpoint must satisfy, not a late-stage admin feature.

---

## 2026-09-20 — Design is approved as prototypes before code, every phase.

**Decision.** Added Phase 2 (Product design) and a standing rule in `design.md`: no user-visible surface
is implemented before the project owner approves a prototype of it.

**Why.** Requested by the project owner. The original 11-phase roadmap contained no design phase at all.

---

## Carried over from Phase 1 (unchanged, do not re-litigate)

- Backend is **NestJS in plain JavaScript, not TypeScript**.
- **PostgreSQL** is the system of record; Redis is WebSocket fan-out, presence and rate limiting only;
  MinIO holds encrypted media blobs.
- **E2EE is the Signal Protocol via the official `libsignal-client` crate**, wrapped in `crypto-core`
  and exposed to Flutter through `flutter_rust_bridge`. Never write custom cryptography — not protocols,
  not primitives.
- **Riverpod** for state and DI; **go_router** for navigation; **Material 3**.
- **Native WebSocket** (`@nestjs/platform-ws` + `ws`), not Socket.IO.
- Single-host **Docker Compose** deployment; backend instances stay stateless.
- The server handles only ciphertext and minimal routing metadata. Private keys never leave the device.
  No analytics, telemetry or third-party trackers, ever.
