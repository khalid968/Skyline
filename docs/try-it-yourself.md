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

## Starting over

Your development accounts live in the Docker volume. To wipe everything and start clean:

```powershell
cd C:\Users\kkhal\Desktop\AI\Skyline
docker compose -f infra/docker/docker-compose.yml down -v   # deletes ALL development data
docker compose -f infra/docker/docker-compose.yml up -d
cd apps\backend
npm run migrate:up
```
