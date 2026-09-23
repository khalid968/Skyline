// Phase 5, end to end, with REAL authentication: real Ed25519 device keys, real
// activation codes, real bearer tokens. No test headers, no fake principals.
import crypto from 'crypto';
import request from 'supertest';
import WebSocket from 'ws';
import { generate as totpCode } from 'otplib';
import { createTestDatabase, mkUser } from '../db/harness';
import { createTestApp } from './app-harness';
import configuration from '../../src/config/configuration';
import { AuditService } from '../../src/modules/audit/audit.service';
import { issueActivationCode } from '../../src/modules/auth/activation-codes';
import {
  normalizeActivationCode,
  signedMessage,
} from '../../src/modules/auth/auth-crypto';
import { hashPassword } from '../../src/modules/auth/admin-auth.service';
import { newDeviceKey, activationFields } from './device-key';

// ------------------------------------------------------------------ a "client"


const GENERIC_401 = {
  statusCode: 401,
  error: 'Unauthorized',
  message: 'Unauthorized',
};

describe('authentication (real tokens, real database)', () => {
  let db;
  let t;
  let audit;
  let pepper;
  let issuer; // an admin who issues codes
  const sockets = [];

  const api = () => request(t.app.getHttpServer());
  const bearer = (token) => ({ Authorization: `Bearer ${token}` });

  const issueCode = async (userId, by = issuer.id) =>
    (
      await issueActivationCode(db.client, {
        pepper,
        userId,
        issuedBy: by,
        audit,
      })
    ).code;

  const activate = (code, key = newDeviceKey(), overrides = {}) =>
    api()
      .post('/auth/activate')
      .send({
        code,
        deviceName: 'Test phone',
        platform: 'android',
        ...activationFields(code, key),
        ...overrides,
      });

  // A fresh member, activated on a fresh device.
  const member = async (name = 'member') => {
    const user = await mkUser(db.client, name, { status: 'pending' });
    const key = newDeviceKey();
    const res = await activate(await issueCode(user.id), key);
    expect(res.status).toBe(201);
    return { user, key, ...res.body };
  };

  const refresh = (
    session,
    {
      key = session.key,
      timestamp = Math.floor(Date.now() / 1000),
      token = session.refreshToken,
    } = {},
  ) =>
    api()
      .post('/auth/refresh')
      .send({
        refreshToken: token,
        timestamp,
        signature: key.sign(signedMessage.refresh(timestamp, token)),
      });

  const operator = async (
    name = 'op',
    { role = 'admin', password = 'correct horse battery staple' } = {},
  ) => {
    const user = await mkUser(db.client, name, { role });
    await db.client.query(
      'INSERT INTO admin_credentials (user_id, password_hash) VALUES ($1, $2)',
      [user.id, await hashPassword(password)],
    );
    return { ...user, password };
  };

  const login = (username, password) =>
    api().post('/admin/auth/login').send({ username, password });

  beforeAll(async () => {
    db = await createTestDatabase('authn');
    audit = new AuditService({ query: (q, p) => db.client.query(q, p) });
    pepper = Buffer.from(configuration().auth.tokenPepper, 'utf8');
    issuer = await mkUser(db.client, 'issuer', { role: 'admin' });
    t = await createTestApp({ db, realAuth: true, listen: true });
  }, 90000);

  afterEach(() => {
    while (sockets.length) sockets.pop().terminate();
  });

  afterAll(async () => {
    await t.close();
    await db.drop();
  });

  // ================================================================ activation

  describe('activation', () => {
    it('turns a code into a registered device and a working session', async () => {
      const user = await mkUser(db.client, 'sarah', { status: 'pending' });
      const key = newDeviceKey();
      const res = await activate(await issueCode(user.id), key);

      expect(res.status).toBe(201);
      expect(res.body.userId).toBe(user.id);
      expect(res.body.accessToken).toMatch(/^skd_/);
      expect(res.body.refreshToken).toMatch(/^skr_/);

      const me = await api().get('/me').set(bearer(res.body.accessToken));
      expect(me.status).toBe(200);
      expect(me.body).toMatchObject({
        userId: user.id,
        username: user.username,
        deviceId: res.body.deviceId,
      });

      const { rows } = await db.client.query(
        `SELECT u.status, d.signing_key FROM users u JOIN devices d ON d.user_id = u.id WHERE d.id = $1`,
        [res.body.deviceId],
      );
      expect(rows[0].status).toBe('active'); // pending -> active on first activation
      expect(rows[0].signing_key.toString('base64')).toBe(key.publicKey);
    });

    it('never stores a token: only hashes are in the database', async () => {
      const m = await member();
      const all = JSON.stringify(
        (await db.client.query('SELECT * FROM device_sessions')).rows,
      );
      expect(all).not.toContain(m.accessToken);
      expect(all).not.toContain(m.refreshToken);
    });

    it('accepts a code however it was typed', async () => {
      const user = await mkUser(db.client, 'typist', { status: 'pending' });
      const code = await issueCode(user.id);
      const sloppy = ` ${code.toLowerCase().replace(/-/g, ' ')} `;
      expect((await activate(sloppy)).status).toBe(201);
    });

    it('is SINGLE USE: the same code on a second device fails', async () => {
      const user = await mkUser(db.client, 'once', { status: 'pending' });
      const code = await issueCode(user.id);
      expect((await activate(code)).status).toBe(201);

      const again = await activate(code, newDeviceKey());
      expect(again.status).toBe(401);
      expect(again.body).toEqual(GENERIC_401);
    });

    it('lets exactly ONE of many simultaneous activations of a code win', async () => {
      const user = await mkUser(db.client, 'raced', { status: 'pending' });
      const code = await issueCode(user.id);
      const results = await Promise.all(
        Array.from({ length: 12 }, () => activate(code, newDeviceKey())),
      );
      expect(results.filter((r) => r.status === 201)).toHaveLength(1);
      expect(results.filter((r) => r.status === 401)).toHaveLength(11);
      const { rows } = await db.client.query(
        'SELECT count(*)::int AS n FROM devices WHERE user_id = $1',
        [user.id],
      );
      expect(rows[0].n).toBe(1);
    });

    it('fails every bad attempt with the SAME response, so none can be told apart', async () => {
      const c = db.client;
      const u1 = await mkUser(c, 'exp', { status: 'pending' });
      const expired = await issueCode(u1.id);
      await c.query(
        `UPDATE activation_codes SET created_at = now() - interval '5 days', expires_at = now() - interval '1 day' WHERE user_id = $1`,
        [u1.id],
      );
      const u2 = await mkUser(c, 'rev', { status: 'pending' });
      const revoked = await issueCode(u2.id);
      await c.query(
        'UPDATE activation_codes SET revoked_at = now() WHERE user_id = $1',
        [u2.id],
      );
      const u3 = await mkUser(c, 'good', { status: 'pending' });
      const good = await issueCode(u3.id);
      const other = newDeviceKey();

      const attempts = {
        'never issued': await activate('SKY-00000-00000-00000-00000'),
        expired: await activate(expired),
        revoked: await activate(revoked),
        'signed by a different key': await activate(good, newDeviceKey(), {
          signature: activationFields(good, other).signature,
        }),
        'signature over a different code': await activate(
          good,
          other,
          activationFields(good, other, '00000000000000000000'),
        ),
        'not a code at all': await activate('hello-this-is-not-a-code'),
      };

      for (const [label, res] of Object.entries(attempts)) {
        expect([label, res.status, res.body]).toEqual([
          label,
          401,
          GENERIC_401,
        ]);
      }
      // And the good code was not burned by the bad-signature attempts.
      expect((await activate(good)).status).toBe(201);
    });

    it('refuses a suspended account, and leaves the code unspent (all or nothing)', async () => {
      const user = await mkUser(db.client, 'sus', { status: 'pending' });
      const code = await issueCode(user.id);
      await db.client.query(
        `UPDATE users SET status = 'suspended', suspended_at = now() WHERE id = $1`,
        [user.id],
      );

      expect((await activate(code)).status).toBe(401);
      const { rows } = await db.client.query(
        'SELECT redeemed_at FROM activation_codes WHERE user_id = $1',
        [user.id],
      );
      expect(rows[0].redeemed_at).toBeNull();
      const devices = await db.client.query(
        'SELECT count(*)::int AS n FROM devices WHERE user_id = $1',
        [user.id],
      );
      expect(devices.rows[0].n).toBe(0);
    });

    it('refuses a signing key already on a live device (a cloned device), without burning the code', async () => {
      const first = await member('orig');
      const user = await mkUser(db.client, 'copy', { status: 'pending' });
      const code = await issueCode(user.id);

      expect((await activate(code, first.key)).status).toBe(401);
      const { rows } = await db.client.query(
        'SELECT redeemed_at FROM activation_codes WHERE user_id = $1',
        [user.id],
      );
      expect(rows[0].redeemed_at).toBeNull();
      expect((await activate(code)).status).toBe(201);
    });

    it('rejects malformed input with a 400 before touching any code', async () => {
      const res = await api()
        .post('/auth/activate')
        .send({ code: 'SKY-00000-00000-00000-00000', platform: 'fridge' });
      expect(res.status).toBe(400);
    });

    it('records the activation in the audit log, without the code', async () => {
      const m = await member('audited');
      const { rows } = await db.client.query(
        `SELECT detail::text AS detail FROM audit_log WHERE action = 'devices.activate' AND target_device_id = $1`,
        [m.deviceId],
      );
      expect(rows).toHaveLength(1);
      expect(rows[0].detail).not.toMatch(/SKY-/);
    });
  });

  // =================================================================== tokens

  describe('device tokens', () => {
    it.each([
      ['no token', {}],
      ['garbage', bearer('nonsense')],
      ['a well-formed token nobody issued', bearer(`skd_${'A'.repeat(43)}`)],
      ['not a Bearer header', { Authorization: 'Basic abc' }],
    ])('refuses %s', async (_label, headers) => {
      const res = await api().get('/me').set(headers);
      expect(res.status).toBe(401);
      expect(res.body).toEqual(GENERIC_401);
    });

    it('refuses a REFRESH token used as an access token', async () => {
      const m = await member();
      expect((await api().get('/me').set(bearer(m.refreshToken))).status).toBe(
        401,
      );
    });

    it('stops working the moment the account is suspended', async () => {
      const m = await member();
      await db.client.query(
        `UPDATE users SET status = 'suspended', suspended_at = now() WHERE id = $1`,
        [m.userId],
      );
      expect((await api().get('/me').set(bearer(m.accessToken))).status).toBe(
        401,
      );
    });

    it('stops working once it expires', async () => {
      const m = await member();
      await db.client.query(
        `UPDATE device_sessions SET access_expires_at = now() - interval '1 second' WHERE device_id = $1`,
        [m.deviceId],
      );
      expect((await api().get('/me').set(bearer(m.accessToken))).status).toBe(
        401,
      );
    });

    it('cannot reach an operator route: a phone is never an admin console', async () => {
      const m = await member();
      await db.client.query(
        `UPDATE users SET role_key = 'admin' WHERE id = $1`,
        [m.userId],
      );
      expect(
        (await api().get('/admin/auth/me').set(bearer(m.accessToken))).status,
      ).toBe(401);
    });
  });

  describe('refresh', () => {
    it('swaps a signed refresh for a new pair, and the old access token stops working', async () => {
      const m = await member();
      const res = await refresh(m);
      expect(res.status).toBe(200);
      expect(res.body.accessToken).not.toBe(m.accessToken);
      expect(res.body.refreshToken).not.toBe(m.refreshToken);

      expect(
        (await api().get('/me').set(bearer(res.body.accessToken))).status,
      ).toBe(200);
      expect((await api().get('/me').set(bearer(m.accessToken))).status).toBe(
        401,
      );
    });

    it('refuses a refresh token without a signature from the device key: a stolen token alone is useless', async () => {
      const m = await member();
      const res = await refresh(m, { key: newDeviceKey() });
      expect(res.status).toBe(401);
      expect(res.body).toEqual(GENERIC_401);
      // The failed attempt did not rotate or revoke anything: the real device carries on.
      expect((await refresh(m)).status).toBe(200);
    });

    it('refuses a signature with a stale or future timestamp (replay window)', async () => {
      const m = await member();
      const now = Math.floor(Date.now() / 1000);
      expect((await refresh(m, { timestamp: now - 3600 })).status).toBe(401);
      expect((await refresh(m, { timestamp: now + 3600 })).status).toBe(401);
    });

    it('REVOKES the whole session when an already-used refresh token comes back (theft detection)', async () => {
      const m = await member();
      const first = await refresh(m);
      expect(first.status).toBe(200);

      // Someone replays the ORIGINAL refresh token, correctly signed.
      const replay = await refresh(m);
      expect(replay.status).toBe(401);

      // Now even the legitimate new tokens are dead: the device must re-activate.
      expect(
        (await api().get('/me').set(bearer(first.body.accessToken))).status,
      ).toBe(401);
      expect(
        (await refresh(m, { token: first.body.refreshToken })).status,
      ).toBe(401);

      const { rows } = await db.client.query(
        `SELECT detail->>'reason' AS reason FROM audit_log WHERE action = 'sessions.revoke' AND target_device_id = $1`,
        [m.deviceId],
      );
      expect(rows.map((r) => r.reason)).toContain('refresh_token_reused');
    });

    it('refuses a refresh for a revoked device', async () => {
      const m = await member();
      await db.client.query(
        'UPDATE devices SET revoked_at = now() WHERE id = $1',
        [m.deviceId],
      );
      expect((await refresh(m)).status).toBe(401);
    });
  });

  describe('signing out and devices', () => {
    it('logout ends this session only', async () => {
      const m = await member();
      expect(
        (await api().post('/auth/logout').set(bearer(m.accessToken))).status,
      ).toBe(204);
      expect((await api().get('/me').set(bearer(m.accessToken))).status).toBe(
        401,
      );
      expect((await refresh(m)).status).toBe(401);
    });

    it('lists my devices and marks the current one', async () => {
      const m = await member();
      const res = await api().get('/me/devices').set(bearer(m.accessToken));
      expect(res.status).toBe(200);
      expect(res.body).toHaveLength(1);
      expect(res.body[0]).toMatchObject({
        deviceId: m.deviceId,
        current: true,
        platform: 'android',
      });
    });

    it('revoking my own device kills its tokens at once', async () => {
      const m = await member();
      const res = await api()
        .post(`/me/devices/${m.deviceId}/revoke`)
        .set(bearer(m.accessToken));
      expect(res.status).toBe(204);
      expect((await api().get('/me').set(bearer(m.accessToken))).status).toBe(
        401,
      );
      expect((await refresh(m)).status).toBe(401);
    });

    it("answers someone else's device with the same 404 as a device that does not exist", async () => {
      const me = await member();
      const other = await member();
      const theirs = await api()
        .post(`/me/devices/${other.deviceId}/revoke`)
        .set(bearer(me.accessToken));
      const nobody = await api()
        .post('/me/devices/00000000-0000-4000-8000-000000000000/revoke')
        .set(bearer(me.accessToken));
      expect(theirs.status).toBe(404);
      expect(theirs.body).toEqual(nobody.body);
      // And their device is untouched.
      expect(
        (await api().get('/me').set(bearer(other.accessToken))).status,
      ).toBe(200);
    });
  });

  describe('WebSocket', () => {
    const open = (url, headers) =>
      new Promise((resolve) => {
        const ws = new WebSocket(url, { headers });
        sockets.push(ws);
        const out = { ws, messages: [] };
        ws.on('message', (d) => {
          out.messages.push(JSON.parse(d.toString()));
          if (out.messages[0]?.type === 'ready')
            resolve({ ...out, ready: true });
        });
        ws.on('close', (code) => resolve({ ...out, ready: false, code }));
        ws.on('error', () => {});
      });

    it('admits a device access token in the Authorization header', async () => {
      const m = await member();
      const r = await open(
        `ws://localhost:${t.port}/ws`,
        bearer(m.accessToken),
      );
      expect(r.ready).toBe(true);
    });

    it('admits it as ?token= for clients that cannot set headers', async () => {
      const m = await member();
      const r = await open(
        `ws://localhost:${t.port}/ws?token=${m.accessToken}`,
      );
      expect(r.ready).toBe(true);
    });

    it('refuses no token, a refresh token, and a dashboard token', async () => {
      const m = await member();
      const op = await operator('wsop');
      const dash = (await login(op.username, op.password)).body.token;
      for (const headers of [{}, bearer(m.refreshToken), bearer(dash)]) {
        const r = await open(`ws://localhost:${t.port}/ws`, headers);
        expect(r.ready).toBe(false);
        expect(r.code).toBe(1008);
      }
    });
  });

  // ============================================================== dashboard

  describe('administrator sign-in', () => {
    it('signs in with a password when two-factor is off', async () => {
      const op = await operator();
      const res = await login(op.username, op.password);
      expect(res.status).toBe(200);
      expect(res.body.mfaRequired).toBe(false);
      expect(res.body.token).toMatch(/^ska_/);

      const me = await api().get('/admin/auth/me').set(bearer(res.body.token));
      expect(me.status).toBe(200);
      expect(me.body).toMatchObject({
        userId: op.id,
        role: 'admin',
        twoFactorEnabled: false,
      });
    });

    it('stores the password only as an Argon2id hash', async () => {
      const op = await operator();
      const { rows } = await db.client.query(
        'SELECT password_hash FROM admin_credentials WHERE user_id = $1',
        [op.id],
      );
      expect(rows[0].password_hash).toMatch(/^\$argon2id\$/);
      expect(rows[0].password_hash).not.toContain(op.password);
    });

    it('fails a wrong password, an unknown user and a member with the SAME response', async () => {
      const op = await operator();
      const plainMember = await mkUser(db.client, 'plain');
      const results = [
        await login(op.username, 'wrong password entirely'),
        await login('nobody-by-this-name', 'whatever'),
        await login(plainMember.username, 'whatever'),
      ];
      for (const r of results) {
        expect(r.status).toBe(401);
        expect(r.body).toEqual(GENERIC_401);
      }
    });

    it('refuses a suspended administrator even with the right password', async () => {
      const op = await operator();
      await db.client.query(
        `UPDATE users SET status = 'suspended', suspended_at = now() WHERE id = $1`,
        [op.id],
      );
      expect((await login(op.username, op.password)).status).toBe(401);
    });

    it('a dashboard token cannot act as a member in the app', async () => {
      const op = await operator();
      const token = (await login(op.username, op.password)).body.token;
      expect((await api().get('/me').set(bearer(token))).status).toBe(401);
    });

    it('stops a demoted admin on the next request', async () => {
      const op = await operator();
      const token = (await login(op.username, op.password)).body.token;
      await db.client.query(
        `UPDATE users SET role_key = 'member' WHERE id = $1`,
        [op.id],
      );
      expect(
        (await api().get('/admin/auth/me').set(bearer(token))).status,
      ).toBe(401);
    });

    it('signs out after an hour idle, and after 12 hours regardless', async () => {
      const op = await operator();
      const idle = (await login(op.username, op.password)).body.token;
      const old = (await login(op.username, op.password)).body.token;
      await db.client.query(
        `UPDATE admin_sessions SET last_used_at = now() - interval '61 minutes' WHERE user_id = $1 AND created_at = (SELECT min(created_at) FROM admin_sessions WHERE user_id = $1)`,
        [op.id],
      );
      await db.client.query(
        `UPDATE admin_sessions SET created_at = now() - interval '13 hours', expires_at = now() - interval '1 hour'
          WHERE user_id = $1 AND last_used_at > now() - interval '1 minute'`,
        [op.id],
      );
      expect((await api().get('/admin/auth/me').set(bearer(idle))).status).toBe(
        401,
      );
      expect((await api().get('/admin/auth/me').set(bearer(old))).status).toBe(
        401,
      );
    });

    it('logout ends the dashboard session', async () => {
      const op = await operator();
      const token = (await login(op.username, op.password)).body.token;
      expect(
        (await api().post('/admin/auth/logout').set(bearer(token))).status,
      ).toBe(204);
      expect(
        (await api().get('/admin/auth/me').set(bearer(token))).status,
      ).toBe(401);
    });

    it('records successful and failed sign-ins in the audit log, never the password', async () => {
      const op = await operator();
      await login(op.username, 'a wrong guess here');
      await login(op.username, op.password);
      const { rows } = await db.client.query(
        `SELECT action, detail::text AS detail FROM audit_log
          WHERE (actor_user_id = $1 OR target_user_id = $1) AND action LIKE 'admin_auth.%'`,
        [op.id],
      );
      expect(rows.map((r) => r.action).sort()).toEqual([
        'admin_auth.login',
        'admin_auth.login_failed',
      ]);
      expect(JSON.stringify(rows)).not.toContain(op.password);
      expect(JSON.stringify(rows)).not.toContain('a wrong guess here');
    });

    it('changing the password signs out every OTHER session and retires the old password', async () => {
      const op = await operator();
      const keep = (await login(op.username, op.password)).body.token;
      const other = (await login(op.username, op.password)).body.token;

      const res = await api()
        .post('/admin/auth/password')
        .set(bearer(keep))
        .send({
          currentPassword: op.password,
          newPassword: 'a brand new long password',
        });
      expect(res.status).toBe(204);

      expect((await api().get('/admin/auth/me').set(bearer(keep))).status).toBe(
        200,
      );
      expect(
        (await api().get('/admin/auth/me').set(bearer(other))).status,
      ).toBe(401);
      expect((await login(op.username, op.password)).status).toBe(401);
      expect(
        (await login(op.username, 'a brand new long password')).status,
      ).toBe(200);
    });

    it('refuses a password change with the wrong current password, or a short new one', async () => {
      const op = await operator();
      const token = (await login(op.username, op.password)).body.token;
      const wrong = await api()
        .post('/admin/auth/password')
        .set(bearer(token))
        .send({
          currentPassword: 'not it at all',
          newPassword: 'a brand new long password',
        });
      const short = await api()
        .post('/admin/auth/password')
        .set(bearer(token))
        .send({ currentPassword: op.password, newPassword: 'short' });
      expect(wrong.status).toBe(400);
      expect(short.status).toBe(400);
    });
  });

  describe('optional two-factor', () => {
    const at = (secret, offsetSec = 0) =>
      totpCode({ secret, epoch: Math.floor(Date.now() / 1000) + offsetSec });

    const enableFor = async (op) => {
      const token = (await login(op.username, op.password)).body.token;
      const setup = await api()
        .post('/admin/auth/two-factor/setup')
        .set(bearer(token));
      expect(setup.status).toBe(200);
      expect(setup.body.otpauthUri).toMatch(/^otpauth:\/\/totp\/Skyline:/);
      const code = await at(setup.body.secret);
      const enable = await api()
        .post('/admin/auth/two-factor/enable')
        .set(bearer(token))
        .send({ code });
      expect(enable.status).toBe(204);
      return { token, secret: setup.body.secret, usedCode: code };
    };

    it('is off until the admin turns it on, and turning it on needs a working code', async () => {
      const op = await operator();
      const token = (await login(op.username, op.password)).body.token;
      await api().post('/admin/auth/two-factor/setup').set(bearer(token));
      const bad = await api()
        .post('/admin/auth/two-factor/enable')
        .set(bearer(token))
        .send({ code: '000000' });
      expect(bad.status).toBe(400);
      expect(
        (await api().get('/admin/auth/me').set(bearer(token))).body
          .twoFactorEnabled,
      ).toBe(false);
    });

    it('once on, the password alone only gets a short-lived "enter your code" token', async () => {
      const op = await operator();
      const { secret } = await enableFor(op);

      const step1 = await login(op.username, op.password);
      expect(step1.status).toBe(200);
      expect(step1.body.mfaRequired).toBe(true);
      expect(step1.body.token).toBeUndefined();
      // The pending token grants nothing on its own.
      expect(
        (await api().get('/admin/auth/me').set(bearer(step1.body.mfaToken)))
          .status,
      ).toBe(401);

      const step2 = await api()
        .post('/admin/auth/mfa')
        .send({ mfaToken: step1.body.mfaToken, code: await at(secret, 30) });
      expect(step2.status).toBe(200);
      expect(
        (await api().get('/admin/auth/me').set(bearer(step2.body.token))).body
          .twoFactorEnabled,
      ).toBe(true);

      // The pending token is spent once used.
      const reuse = await api()
        .post('/admin/auth/mfa')
        .send({ mfaToken: step1.body.mfaToken, code: await at(secret, 30) });
      expect(reuse.status).toBe(401);
    });

    it('rejects a wrong code, and a code that was already used (no replay)', async () => {
      const op = await operator();
      const { secret, usedCode } = await enableFor(op);
      const pending = (await login(op.username, op.password)).body.mfaToken;

      const wrong = await api()
        .post('/admin/auth/mfa')
        .send({ mfaToken: pending, code: '000000' });
      expect(wrong.status).toBe(401);

      // The exact code used to switch 2FA on is dead, even inside its 30-second window.
      const replay = await api()
        .post('/admin/auth/mfa')
        .send({ mfaToken: pending, code: usedCode });
      expect(replay.status).toBe(401);

      const next = await at(secret, 30);
      expect(
        (
          await api()
            .post('/admin/auth/mfa')
            .send({ mfaToken: pending, code: next })
        ).status,
      ).toBe(200);

      // And that one cannot be used again for a second sign-in.
      const pending2 = (await login(op.username, op.password)).body.mfaToken;
      expect(
        (
          await api()
            .post('/admin/auth/mfa')
            .send({ mfaToken: pending2, code: next })
        ).status,
      ).toBe(401);
    });

    it('stores the secret encrypted, never in plain text', async () => {
      const op = await operator();
      const { secret } = await enableFor(op);
      const { rows } = await db.client.query(
        'SELECT totp_secret_enc FROM admin_credentials WHERE user_id = $1',
        [op.id],
      );
      expect(rows[0].totp_secret_enc.toString('latin1')).not.toContain(secret);
    });

    it('turning it off needs BOTH the password and a current code', async () => {
      const op = await operator();
      const { token, secret } = await enableFor(op);
      const later = await at(secret, 30);

      const noPassword = await api()
        .post('/admin/auth/two-factor/disable')
        .set(bearer(token))
        .send({ password: 'wrong password here', code: later });
      expect(noPassword.status).toBe(400);

      const ok = await api()
        .post('/admin/auth/two-factor/disable')
        .set(bearer(token))
        .send({ password: op.password, code: later });
      expect(ok.status).toBe(204);
      expect((await login(op.username, op.password)).body.mfaRequired).toBe(
        false,
      );
    });

    it('cannot be set up twice over an active one', async () => {
      const op = await operator();
      const { token } = await enableFor(op);
      expect(
        (await api().post('/admin/auth/two-factor/setup').set(bearer(token)))
          .status,
      ).toBe(409);
    });
  });
});
