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

## Starting over

Your development accounts live in the Docker volume. To wipe everything and start clean:

```powershell
cd C:\Users\kkhal\Desktop\AI\Skyline
docker compose -f infra/docker/docker-compose.yml down -v   # deletes ALL development data
docker compose -f infra/docker/docker-compose.yml up -d
cd apps\backend
npm run migrate:up
```
