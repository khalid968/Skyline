# Try it yourself

Step-by-step checks the owner can run on the Windows development machine to see each finished phase work.
Everything here uses PowerShell from the repository folder. Nothing here touches production.

## Before anything: start the data stack

1. Start **Docker Desktop** and wait until it says it is running.
2. Open PowerShell in the repository and run:

```powershell
cd C:\Users\kkhal\Desktop\AI\Skyline
docker compose -f infra/docker/docker-compose.yml up -d
cd apps\backend
npm run migrate:up
```

`migrate:up` is safe to run again; it only applies what is missing.

## Run the automated tests (every phase)

```powershell
npm test              # unit tests, needs nothing running
npm run test:db       # the database rules (Docker must be running)
npm run test:app      # the API itself: logins, permissions, contact graph, live delivery
```

Each should end with `0 failed`. The tests build their own throwaway database and delete it afterwards, so
they never touch the accounts you create below.

## Phase 5: sign-in, by hand

Two terminals. In the **first**, start the server and leave it running:

```powershell
cd C:\Users\kkhal\Desktop\AI\Skyline\apps\backend
npm run start
```

Do everything else in a **second** terminal, also in `apps\backend`.

### 1. Create yourself as the first administrator

```powershell
npm run admin:create -- --username owner --display-name "Your Name"
```

It asks for a password twice (at least 12 characters; nothing is shown as you type). It only works once: a
second administrator has to be created from the dashboard later, so pick the username you want to keep.

If the hidden prompt misbehaves in your terminal, pass the password another way for this one command:

```powershell
$env:SKYLINE_ADMIN_PASSWORD = 'your long password'; npm run admin:create -- --username owner --display-name "Your Name"; Remove-Item Env:SKYLINE_ADMIN_PASSWORD
```

### 2. Sign in as the administrator

```powershell
$login = Invoke-RestMethod -Method Post -Uri http://localhost:3000/admin/auth/login `
  -ContentType 'application/json' -Body '{"username":"owner","password":"YOUR PASSWORD"}'
$login
Invoke-RestMethod -Uri http://localhost:3000/admin/auth/me -Headers @{ Authorization = "Bearer $($login.token)" }
```

The second command shows your account with `twoFactorEnabled : False`. Try a wrong password: you get a
plain `401`, and after 10 wrong tries in 15 minutes, `429 Too Many Requests`.

### 3. Invite a member and get their one-time code

```powershell
npm run user:invite -- --username sarah.w --display-name "Sarah Whitfield"
```

It prints a code like `SKY-X1M4W-C7SCE-SV9NF-N5S94`, **once**. It is not stored anywhere, so copy it now.

### 4. Activate a "phone" with that code

The real app does not exist yet, so a small script plays the phone: it makes a device key, signs the code
and activates, exactly as the app will.

```powershell
npm run dev:device -- activate SKY-XXXXX-XXXXX-XXXXX-XXXXX   # paste your code
npm run dev:device -- me          # who am I?  -> Sarah Whitfield
npm run dev:device -- devices     # my devices -> one, marked current
npm run dev:device -- refresh     # new tokens, signed with the device key
npm run dev:device -- logout      # sign this device out
npm run dev:device -- me          # now 401
```

Things worth trying:

- **Run `activate` with the same code again.** It fails with `401`: codes are single use.
- **Run `npm run user:invite -- --username sarah.w` again**, then activate the new code: that is a second
  device for Sarah. Any earlier unused code stops working the moment a new one is issued.
- **Use the phone's token against an admin route:** it is refused. A phone is never an admin console.

`npm run dev:device -- forget` deletes the pretend phone's saved keys (`apps\backend\.dev-device.json`).

### Optional: turn on two-factor for your admin account

Needs an authenticator app on your phone (Google Authenticator, Microsoft Authenticator, 1Password...).

```powershell
$h = @{ Authorization = "Bearer $($login.token)" }
$setup = Invoke-RestMethod -Method Post -Uri http://localhost:3000/admin/auth/two-factor/setup -Headers $h
$setup.secret        # type this into your authenticator app as a new account
Invoke-RestMethod -Method Post -Uri http://localhost:3000/admin/auth/two-factor/enable -Headers $h `
  -ContentType 'application/json' -Body '{"code":"123456"}'   # the 6 digits your app shows now
```

From then on, signing in returns `mfaRequired: True` and an `mfaToken`; finish with:

```powershell
Invoke-RestMethod -Method Post -Uri http://localhost:3000/admin/auth/mfa `
  -ContentType 'application/json' -Body '{"mfaToken":"PASTE","code":"123456"}'
```

The dashboard (Phase 6, below) turns all of this into screens.

## Phase 6: the admin dashboard

1. **Restart the backend** so it picks up the new admin routes and migration 010. In the first terminal,
   press `Ctrl+C` and then run:

   ```powershell
   cd C:\Users\kkhal\Desktop\AI\Skyline\apps\backend
   npm run migrate:up
   npm run start
   ```

2. In a **second** terminal, start the dashboard (the first time only, run `npm install` first):

   ```powershell
   cd C:\Users\kkhal\Desktop\AI\Skyline\apps\dashboard
   npm install
   npm run dev
   ```

3. Open <http://localhost:5173> and sign in with the administrator you created in Phase 5. That account is now
   the **owner**: it shows a crown badge, and nobody else can demote, suspend or rename it.

Things to try:

- **Users → Create user.** Make two members, and add the first as an initial contact of the second. The
  activation code appears once; copy it.
- **Contact graph.** Pick a person and switch contacts on and off. Links always work both ways.
- **A user's page.** Rename them, suspend and reinstate them, or issue a new code.
- **Make a moderator.** They get a temporary password. Sign in as them in a private window: they must choose a
  new password before anything else opens. They can manage members but cannot touch you.
- **Account.** Turn on two-factor sign-in by scanning the QR code with an authenticator app.

Dashboard tests: `npm test` in `apps\dashboard` (no backend needed).

## Phase 7: encryption

There are no new screens yet (chats come in Phase 8). What you can check is that the encryption works.
Open PowerShell. If `cargo` is "not recognized", close PowerShell and open a new one; the Rust installer
updates PATH only for new windows.

1. **The crypto core's own tests.** Two simulated devices talk, plus the attack cases (a tampered message, a
   replayed message, a forged key, a swapped identity, the wrong vault key):

   ```powershell
   cd C:\Users\kkhal\Desktop\AI\Skyline\crypto-core
   cargo test
   ```

   Look for `test result: ok` lines, with no `FAILED`.

2. **Real devices against the real server.** This builds a small tool that plays two phones, then runs the
   server test that uses it. It creates its own throwaway database and deletes it afterwards.

   ```powershell
   cargo build -p skyline_e2e
   cd ..\apps\backend
   npx jest --config ./test/jest-e2e.json --runInBand app/crypto-e2e
   ```

   Expect `2 passed`: the devices exchange messages, and without a contact link the server refuses to hand
   out keys.

3. **Encryption inside the Windows app.** The first run takes a few minutes, because it compiles Signal's
   library:

   ```powershell
   cd ..\mobile
   flutter test integration_test/crypto_test.dart -d windows
   ```

   Expect `All tests passed!`.

The backend must be **restarted** (`npm run migrate:up`, then `npm run start`) to pick up migration 011 and the
new activation format. The old `npm run dev:device` pretend phone was updated to match.

## One click: start everything

Double-click **`Start Skyline.cmd`** in the Skyline folder. It starts:

1. Docker and the database, Redis and MinIO;
2. the server on :3000 (applying new migrations first);
3. the dashboard, which opens in your browser;
4. the Android emulator, with the app on it;
5. the Windows app.

Each runs in its own window, and anything already running is left alone. The apps take a few minutes to
build the first time. To skip parts, run it from PowerShell:

```powershell
& ".\Start Skyline.cmd" -NoAndroid     # also: -NoWindows, -NoDashboard
```

Double-click **`Stop Skyline.cmd`** to close the windows it opened. Docker keeps running and your data
stays; `& ".\Stop Skyline.cmd" -StopDocker` stops the data stack too.

## Phase 8a: real messaging between two devices

You will run your own server, create two people in the dashboard, and chat between the Windows app and the
Android emulator.

1. **Update and restart the server** (first terminal):

   ```powershell
   cd C:\Users\kkhal\Desktop\AI\Skyline\apps\backend
   npm run migrate:up
   npm run start
   ```

   Optional, for Android push: in `apps\backend\.env` add the line
   `FCM_SERVICE_ACCOUNT_FILE=C:/Users/kkhal/Skyline-secrets/skyline-a090f-firebase-adminsdk-fbsvc-b632fb1e41.json`
   before starting the server.

2. **In the dashboard** (`cd apps\dashboard; npm run dev`, then open http://localhost:5173): create two
   members, for example Amina and Omar, and link them to each other on **Contact graph**. Copy each one's
   activation code.

3. **Windows app**, as Amina:

   ```powershell
   cd C:\Users\kkhal\Desktop\AI\Skyline\apps\mobile
   flutter run -d windows
   ```

   Enter Amina's code and a device name. Omar appears in the chat list.

4. **Android app**, as Omar: start the emulator from Android Studio (Device Manager). If it crashes, start it
   from PowerShell with `emulator -avd Medium_Phone_API_36.1 -gpu swiftshader_indirect`. Then:

   ```powershell
   flutter run -d emulator-5554
   ```

   Enter Omar's code. The emulator reaches your PC's server at `10.0.2.2:3000` automatically.

5. **Talk.** Send from one and watch it arrive on the other: one tick, then two ticks, then the white "read"
   badge when it is opened. Things to try:

   - Tap a message you sent to see what each mark means.
   - Tap the clock in a chat to set a disappearing timer. Both sides see a notice.
   - Tap the name at the top to compare safety numbers. On the phone, "Scan their code" reads the other
     screen's QR code.
   - Settings (the gear): turn on app lock with a PIN. Close and reopen: Skyline is locked.
   - Close the emulator app (swipe it away), then send from Windows: with push configured, the phone shows
     "Skyline · New message", with nothing about who or what.
   - Stop the server: the app shows "You are offline", and messages you write wait with a clock, then send
     when the server is back.

## Media: photos, videos, documents and voice messages

Same setup as Phase 8a. Run `npm run migrate:up` once for the new tables, and keep Docker running: files go
to MinIO.

1. **Update and restart the server:** `npm run migrate:up`, then `npm run start`.
2. **Restart both apps** (`flutter run -d windows` and `flutter run -d emulator-5554`). The new plugins
   need a full rebuild, not a hot reload.
3. **Send things.** In a chat:
   - Tap **+** to open the attach menu (Photos, Camera on the phone, Video, File). Pick a file, add a
     caption, and send. The bubble shows "Encrypting and sending" with a percentage.
   - **Hold the microphone** to record a voice message. Release to send; slide left before releasing to
     cancel. The first time, the phone asks for microphone access.
4. **Receive things.** On the other device:
   - Photos and voice messages download by themselves.
   - Videos and documents say "tap to download". Tap, watch the progress, then tap again to play or
     open.
   - Open a photo: the viewer's download button asks before saving an unencrypted copy.
5. **Several at once:** in Photos (or Video, or File), pick up to 10. The preview shows them in a strip:
   tap one to look at it, the small x to drop it, + to add more. Photos and videos arrive as one album.
6. **View once:** pick a single photo, tap the round **1** next to the caption (it turns amber), and send.
   The other side taps it, looks, closes: it is gone on their devices, and you see "Opened". Try taking a
   screenshot while it is open on Android or Windows: the screenshot comes out blank.
7. **Media gallery:** the picture icon at the top of a chat lists that chat's photos, videos, files and
   voice messages.
8. **Worth trying:**
   - Send a big video (hundreds of MB) and switch the phone to airplane mode halfway. Turn it back on:
     the upload carries on where it stopped.
   - Set a disappearing timer, send a photo, and wait. The photo's file goes with the message.
   - Files are kept on the server for 30 days. After that, a device that never downloaded one shows
     "no longer available".

## Phase 8b: groups, message tools, search

Double-click **`Stop Skyline.cmd`** and then **`Start Skyline.cmd`**: Start runs the new migration, but only when it starts the server itself. Then **restart both apps**: the
new features include native code, so a hot reload is not enough.

You need three people for a real group. In the dashboard, make a third member (for example Leila) and
give her a code, but **do not** link her to Amina. She can sign in on a second Windows window
(`flutter run -d windows` again, from another terminal) or on the emulator.

1. **Make a group (dashboard → Groups):**
   - **New group:** name it, for example Operations.
   - **Add members:** type a name to add Amina, Omar and Leila.
   - The group appears in each person's chat list by itself, with a square picture.
2. **Talk in it:**
   - Each message shows its sender's name in their own colour.
   - Leila can read Amina's messages even though they are not contacts.
   - In group info (tap the group's name), Leila is marked "not linked to you".
3. **Message tools.** Long-press a message (right-click on Windows):
   - **React:** one of the six quick reactions, or **+** for any emoji.
   - **Reply:** the answer shows a quote of the message it answers.
   - **Edit:** only your own messages, for 15 minutes. The others see "edited".
   - **Pin:** it appears in a bar at the top, and the chat says who pinned it. Tap the bar to go through
     up to 3 pins.
   - **Delete:** "for everyone" works for 24 hours and leaves "This message was deleted"; "for me" works any
     time.
   - **Mention:** in a group, type **@** and pick a name. That person sees an **@** badge in their chat
     list.
4. **Chat list:**
   - Use the **All / Unread / Groups** filters.
   - Long-press a chat (right-click on Windows, or swipe left on a phone) to **Mute** it (crossed bell, grey
     count) or **Archive** it. Archived chats sit behind the **Archived** row and come back when someone
     writes, unless muted.
   - Type half a message and leave the chat: it shows as an amber **Draft** in the list.
5. **Search:** the magnifier at the top searches the messages on this device. It never finds people.
6. **Leaving and removing:**
   - In group info, **Leave group** asks first.
   - In the dashboard, **Remove** someone, or **Archive group** to close it.
   - Removed members stop receiving at once, and the others' next messages use new keys the removed
     person does not have.

## Phase 10: voice and video calls

Start everything with **Start Skyline.cmd**. It now also starts the call relay (coturn). Sign in as two
linked people, for example one on Windows and one on the Android emulator.

1. **Call:** open the chat. The phone and camera buttons are at the top right. The other device rings
   full screen with **Decline**, **Message** and **Accept**.
2. **During the call:**
   - The screen shows the timer and "End-to-end encrypted · through Skyline's relay". Every call goes
     through the relay, so neither of you learns the other's IP address.
   - **Mute**, **Speaker** (phones), and **Video** turn the camera on in the middle of a voice call.
   - The arrow at the top left **minimises** the call. A green "On a call" bar then takes you back to it.
3. **Video:** in a video call your camera appears in the small corner tile. **Flip** switches cameras on
   a phone.
4. **Share your screen** (Windows and Android):
   - On Android, Skyline asks the system first and keeps a "Skyline is sharing your screen" notification
     up the whole time.
   - A red bar on your screen says you are sharing; **Stop** ends it.
5. **In the chat afterwards:** every call leaves a line: "Voice call · 1 min 7 s", "No answer",
   "Declined", or a red **Missed voice call** with **Call back**.
6. **Two devices of your own:** both ring. Answering on one stops the other.

Limits for now:
- **App running:** a phone rings only while Skyline is running (in the foreground or recently used).
  Ringing a closed app is a later piece of work.
- **iOS:** calls there are untested.

## Phase 11: the dashboard's Overview, Alerts, Audit log and Sessions

Restart the server first: it applies migration 015. **Start Skyline.cmd** runs migrations whenever it
starts the server, and so does `npm run migrate:up`. Then sign in to the dashboard. You now land on
**Overview**.

1. **Overview:**
   - A card for each service. If the call relay is stopped, a yellow warning names it.
   - Totals, with messages and calls per day (7, 14 or 30 days), storage, and server numbers.
   - Nothing on the page is about any one person.
2. **Alerts** (owner and admins):
   - To see one, sign out and enter a wrong dashboard password 5 times for another operator, for
     example a moderator you created.
   - An alert appears, and that account can't sign in for 15 minutes, even with the right password.
   - **Lift now** ends the pause.
   - **Mark as reviewed** closes the alert. **Suspend** is offered only for people you may manage, and
     asks first.
3. **Audit log** (owner and admins):
   - Filter by Links, Groups, Accounts and devices, Sign-ins or Automatic, or type a name.
   - Click a row for its details.
   - **Download CSV** saves exactly what the page shows.
4. **Sessions:**
   - Sign in from a second browser, then end that session from here. The other browser is signed out on
     its next click.
   - As the owner, you see everyone's sessions and can sign out everyone except yourself.

Moderators see Overview and Sessions (their own), but not Alerts or the Audit log.

## Phase 12: an unavailable contact

1. In the dashboard, **Suspend** someone who is linked to you.
2. On your phone or PC, their chat at once says **Unavailable**:
   - The message box and the call buttons are replaced by a note.
   - Your history stays.
   - In the chat list their row is greyed out.
3. A message written just before the suspension is marked **Not sent · this account is unavailable**.
4. **Reinstate** them, and everything is back.

The first **Start Skyline** after this update builds MinIO from source (a few minutes, once). Your stored
files are kept.

## Phase 13: the production stack on your PC (the dress rehearsal)

This runs exactly what the rented server will run, on ports 8080/8443, with a self-signed certificate
and without the call relay. Docker Desktop must be running. In Git Bash, from `infra/production`:

```sh
./generate-secrets.sh                      # creates .env here (gitignored) with random secrets
age-keygen -o ~/rehearsal.key              # winget install FiloSottile.age, if you don't have it
# in .env: SKYLINE_DOMAIN=localhost, SKYLINE_ADMIN_EMAIL=you@example.org,
#          BACKUP_AGE_RECIPIENT=<the age1... key it printed>
R="-f docker-compose.yml -f docker-compose.rehearsal.yml -p skyline-rehearsal"
docker compose $R build
docker compose $R run --rm migrate
docker compose $R up -d
docker compose $R exec backend node dist/cli/admin-create.js --username you --display-name "You"
```

Then, accepting the browser's certificate warning:

1. **https://localhost:8443/** shows the download page (board 41). "No release has been published yet" is
   correct at this point.
2. **https://localhost:8443/admin/** shows the dashboard. Sign in with the account you just created.
3. Take a backup and look at it:
   `docker compose $R exec backup backup.sh --now`, then `docker compose $R exec backup ls -l /backups/latest`.
   The files are encrypted: only `~/rehearsal.key` opens them.

To finish, remove everything, including its data:
`docker compose $R down -v`, and delete `.env` (it was only for the rehearsal).

The update banner and "Please update" screen (board 42) are covered by `flutter test` (`update_gate_test.dart`).
They appear in the app once a release is published (see `docs/deployment/operator-guide.md`, section 10).

## Starting over

Your development accounts live in the Docker volume. To wipe everything and start clean:

```powershell
cd C:\Users\kkhal\Desktop\AI\Skyline
docker compose -f infra/docker/docker-compose.yml down -v   # deletes ALL development data
docker compose -f infra/docker/docker-compose.yml up -d
cd apps\backend
npm run migrate:up
```
