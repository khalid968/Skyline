# Running Skyline: the operator's guide

For the person who runs the organization's Skyline server. It takes you from renting a server to a
working service, then covers everyday care: updates, new app versions, backups and incidents.

You need a computer with an SSH client (Windows 11 has one built in) and about two hours for the first
setup. Every command below is typed on the **server** unless a step says "on your computer".

What you end up with, on one server:

| Address | What it is |
| --- | --- |
| `https://chat.example.org/` | The download page members use to install the app (board 41) |
| `https://chat.example.org/admin/` | The admin dashboard |
| `https://chat.example.org/api/` | The API the apps talk to (members never type this) |
| UDP/TCP 3478 | The call relay (coturn) |

The server only ever holds encrypted messages and files, and it deletes each message once every
device has received it. Nobody who runs it, you included, can read what members write.

---

## 1. Rent the server

- **Where:** an EU provider (owner decision), for example Hetzner, OVHcloud or Scaleway. Choose a data
  centre in the EU.
- **Size:** 4 vCPU, 8 GB RAM and 160 GB SSD comfortably serves a few hundred people. The load test
  measured 500 people at 50 messages a second. Media is kept for 30 days, so plan disk space for
  about a month of photos and videos.
- **System:** Ubuntu Server 24.04 LTS.
- **Access:** add your SSH public key when you order. Never use a password login.
- Write down the server's **public IPv4 address**.

## 2. The domain name

Choose a name such as `chat.example.org`. At your DNS provider, add:

| Type | Name | Value |
| --- | --- | --- |
| A | `chat` | the server's IPv4 address |
| AAAA | `chat` | the server's IPv6 address, if it has one |

Wait until the name resolves before step 6 (`ping chat.example.org` from your computer).

## 3. Harden the server

Log in: `ssh root@<address>`.

```sh
# Updates, and security updates from now on without you
apt update && apt -y full-upgrade
apt -y install unattended-upgrades ufw git
dpkg-reconfigure -plow unattended-upgrades        # answer Yes

# Your own user; root logins over SSH are then switched off
adduser skyline && usermod -aG sudo skyline
rsync --archive --chown=skyline:skyline ~/.ssh /home/skyline
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/; s/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh

# Firewall: SSH, web, and the call relay
ufw default deny incoming
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 3478
ufw allow 49160:49200/udp
ufw enable
```

From now on log in as `ssh skyline@chat.example.org`.

Install Docker (the official repository, <https://docs.docker.com/engine/install/ubuntu/>), then run
`sudo usermod -aG docker skyline`, log out and back in, and check that `docker compose version` works.

> Docker publishes ports 80 and 443 itself, past ufw. No other port is published: Postgres, Redis,
> MinIO and the API are reachable only inside the stack.

## 4. Get Skyline and its settings

```sh
git clone <the Skyline repository> ~/skyline
cd ~/skyline/infra/production
./generate-secrets.sh          # creates .env (mode 600) and fills every random secret
nano .env                      # set SKYLINE_DOMAIN, SKYLINE_ADMIN_EMAIL, BACKUP_AGE_RECIPIENT
```

`.env` holds the secrets. It stays on the server; never copy it into git or a chat. Two of its values
must **never change** once people use the service. Changing `AUTH_TOKEN_PEPPER` signs every device out.
Changing a database password locks the API out.

### The backup key (on your computer)

Backups are encrypted to a key only you hold, so a stolen backup is unreadable. On your own computer,
install `age` (<https://age-encryption.org>; on Windows, `winget install FiloSottile.age`) and run:

```sh
age-keygen -o skyline-backup.key
```

It prints `Public key: age1...`. Put that line's key in `.env` as `BACKUP_AGE_RECIPIENT`. Keep
`skyline-backup.key` somewhere safe **off the server**: a password manager plus a USB stick in a
drawer. Without it no backup can ever be restored, and nobody can recover it for you.

### Push notifications (Android)

The server needs Firebase's service account to wake Android phones. Copy the JSON file from your
computer (`C:\Users\<you>\Skyline-secrets\`) into `~/skyline/infra/production/secrets/` on the server,
for example with `scp`. Then set `FCM_SERVICE_ACCOUNT_FILE=/run/skyline-secrets/<file name>.json` in
`.env`. The folder is gitignored. Without the file the service still works, but Android phones only
receive messages while Skyline is open.

## 5. First start

```sh
./deploy.sh
```

This builds the images on the server (the first time takes 10-20 minutes), applies the database
migrations, starts everything and waits until the API reports healthy. Until the real certificate
exists (the next step), Nginx serves a temporary self-signed one, so browsers will warn you.

## 6. The HTTPS certificate

```sh
docker compose --profile letsencrypt up -d certbot
docker compose logs -f certbot       # wait for "Successfully received certificate", then Ctrl+C
```

Nginx picks the certificate up within a minute. The certbot container stays running and renews it
twice a day as needed. Open `https://chat.example.org/`: you should see the download page, with no
warning.

## 7. The owner account

The first dashboard account is the **owner**, who cannot be demoted, suspended or deleted:

```sh
docker compose exec backend node dist/cli/admin-create.js --username you --display-name "Your Name"
```

It asks for a password (at least 12 characters; use your password manager). Then sign in at
`https://chat.example.org/admin/`. On the Account page, **turn on two-factor sign-in**.

Everything from here happens in the dashboard. Add people, which gives each one an activation code
to hand over in person or over a channel you trust. Link people to each other and set up groups.

## 8. Check it works

- [ ] `https://chat.example.org/` shows the download page. `https://chat.example.org/admin/` shows the
      dashboard sign-in.
- [ ] Dashboard → **Overview** shows the server, database, Redis, media store and call relay as healthy.
- [ ] Two test people on two phones: activate both, send a message, a photo and a voice note, and make
      a video call.
- [ ] Take a first backup now: `docker compose exec backup backup.sh --now`, then fetch it to your
      computer (section 11).

---

## 9. Updating the server

When a new version of Skyline is in the repository:

```sh
cd ~/skyline && git pull
cd infra/production && ./deploy.sh
```

`deploy.sh` migrates the database, starts the new version and checks its health. If the new API is not
healthy within two minutes, it starts the previous version again and exits with an error. Migrations
only ever add to the schema, so the old version runs on the new schema. Members' apps reconnect by
themselves; messages sent during the few seconds of restart wait in their outboxes.

## 10. Releasing a new app version

1. Raise `version:` in `apps/mobile/pubspec.yaml` (for example `1.1.0+2`). Write
   `docs/releases/1.1.0.md` with one line per change. Members see those lines in the app.
2. Commit, then tag and push: `git tag v1.1.0 && git push origin v1.1.0`.
3. GitHub → Actions → **Release** builds the signed Android APK and Windows installer and uploads the
   iPhone build to TestFlight. It drafts a GitHub release holding the files plus `manifest.json` and
   `SHA256SUMS`. A platform whose signing secrets are missing is left out: nothing is ever published
   unsigned.
4. Download the draft's files into one folder, copy it to the server, and publish:

   ```sh
   scp -r skyline-1.1.0 skyline@chat.example.org:~/
   ssh skyline@chat.example.org '~/skyline/infra/production/publish-release.sh ~/skyline-1.1.0'
   ```

   The script checks every checksum before changing anything. The download page and every app's
   "Update available" banner (board 42) show the new version at once. Apps check every six hours and
   at every start.
5. Publish the GitHub draft, or delete it. It is only a record.

**Forcing an update:** only for a security fix, and only after the new version is downloadable:

```sh
./publish-release.sh ~/skyline-1.1.0 --minimum 1.1.0
```

Older apps then show "Please update" and cannot send or receive until they are updated. Nothing on
their devices is lost.

### Signing secrets (one-time setup, GitHub → Settings → Secrets and variables → Actions)

| Platform | Secrets |
| --- | --- |
| Android | `ANDROID_KEYSTORE_BASE64` (`base64 -w0 release.jks`), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, `ANDROID_GOOGLE_SERVICES_JSON` |
| Windows | `WINDOWS_CERT_PFX_BASE64`, `WINDOWS_CERT_PASSWORD`: an OV or EV code-signing certificate |
| iPhone | `IOS_CERT_P12_BASE64`, `IOS_CERT_PASSWORD`, `IOS_PROFILE_BASE64`, `IOS_TEAM_ID`, `APPSTORE_API_KEY_ID`, `APPSTORE_API_ISSUER_ID`, `APPSTORE_API_KEY_P8`, `IOS_GOOGLE_SERVICE_INFO_PLIST` |

Also set these repository **variables** (not secrets): `SKYLINE_DOMAIN` (`chat.example.org`, which is
built into the apps as their server) and `IOS_TESTFLIGHT_URL`.

Create the Android key once and **never lose it**: phones only accept updates signed with the same
key.

```sh
keytool -genkeypair -v -keystore release.jks -keyalg RSA -keysize 4096 -validity 10000 -alias skyline
```

Keep `release.jks` and its passwords in your password manager as well as in GitHub.

Use "Run workflow" on the Release workflow for a **dry run**. Everything builds, and nothing is
released.

## 11. Backups

Every night at `BACKUP_HOUR` (UTC), the backup container saves the database and the media store,
encrypted to your age key, into the `backups` volume. It keeps 30 days.

**They live on the same server** (owner decision; `docs/architecture/known-risks.md`). If the server
is lost, so are they. Copy the newest one to your own computer regularly; weekly makes it a real
off-site backup. **On your computer**, from a checkout of the repository:

```sh
infra/production/fetch-backup.sh skyline@chat.example.org
```

It saves `skyline-backup-<date>/` (still encrypted) and checks the checksums.

To see the backups on the server: `docker compose exec backup ls -l /backups`.

### Restoring

Restoring goes into an **empty** database; the script refuses anything else. On a rebuilt server,
after steps 3-5:

```sh
docker compose stop backend web
docker compose down postgres minio && docker volume rm skyline_postgres-data skyline_minio-data
docker compose up -d postgres minio
# the key from your computer, briefly: copy it in, restore, delete it
scp skyline-backup.key skyline@chat.example.org:/tmp/k      # (on your computer)
docker compose run --rm -v /tmp/k:/key:ro backup /usr/local/bin/restore.sh /backups/latest /key
shred -u /tmp/k
./deploy.sh
```

To restore a backup fetched to your computer, first copy its folder into the `backups` volume (or
mount it in place of `/backups/latest` with a second `-v`).

Practise a restore once, on a spare server, before you need it for real. The dress rehearsal did this
(wipe, restore, sign in).

## 12. When something goes wrong

| Symptom | Look at |
| --- | --- |
| Nothing loads | `docker compose ps` (every service should be `healthy` or `running`), then `docker compose logs --tail 100 web backend` |
| Dashboard Overview shows a service down | `docker compose logs --tail 100 <service>`, then `docker compose restart <service>` |
| Calls fail but messages work | The firewall (3478 and 49160-49200/udp) and `docker compose logs coturn`. Some strict networks block UDP; TURN over TLS on 443 is not built yet (`known-risks.md`) |
| Disk full | `df -h`, then `docker system df`; old images: `docker image prune` |
| Certificate expired | `docker compose --profile letsencrypt logs certbot` |

Logs never contain message content or tokens, and the web server keeps no access log at all.

**A lost or stolen phone:** dashboard → Devices → revoke that device. It takes effect on the next
request.

**A suspected server compromise:** take the server off the network at the provider's console, and
keep the disk for investigation. Then rebuild on a fresh server from a backup, with **new** secrets:
run `generate-secrets.sh` on an empty `.env`. New secrets sign every device out, and members
re-activate with new codes. Messages already on their phones stay readable, because keys never
leave the phones. See `docs/security/threat-model.md`.

**A locked-out admin or moderator:** the owner (or an admin, for a moderator) resets them in the
dashboard (the person → Reset sign-in). That gives a temporary password and can switch 2FA off.

**If the owner is locked out** (lost password *and* 2FA device): today there is **no way back in**.
The owner account is protected and nobody can reset it, by design, and the command-line tool only
creates a first admin. So keep the owner's password and 2FA recovery in your password manager, and
promote a second trusted person to admin, who keeps the service running (`known-risks.md`, "The owner
cannot be recovered").
