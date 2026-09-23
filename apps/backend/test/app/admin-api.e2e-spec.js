// Phase 6 admin API, end to end with REAL dashboard sign-ins, cookies and
// activation codes. The owner and role rules here are owner decisions
// (decisions.md, 2026-09-23); do not weaken these tests.
import crypto from 'crypto';
import request from 'supertest';
import {
  createTestDatabase,
  mkUser,
  mkDevice,
  link,
  failure,
} from '../db/harness';
import { createTestApp } from './app-harness';
import { newDeviceKey, activationFields } from './device-key';
import { hashPassword } from '../../src/modules/auth/admin-auth.service';
import {
  normalizeActivationCode,
} from '../../src/modules/auth/auth-crypto';

const PASSWORD = 'correct horse battery staple';


describe('admin API (real sign-ins, real database)', () => {
  let db;
  let t;
  let seq = 0;
  const api = () => request(t.app.getHttpServer());
  const bearer = (token) => ({ Authorization: `Bearer ${token}` });

  // An operator with a password. The owner must be INSERTED as owner: the
  // database refuses to grant ownership by an update (migration 010).
  const operator = async (role = 'admin', { owner = false } = {}) => {
    const username = `${role}-${++seq}`;
    const { rows } = await db.client.query(
      `INSERT INTO users (username, display_name, role_key, status, is_owner)
       VALUES ($1, $4, $2, 'active', $3) RETURNING id`,
      [username, role, owner, username],
    );
    await db.client.query(
      'INSERT INTO admin_credentials (user_id, password_hash) VALUES ($1, $2)',
      [rows[0].id, await hashPassword(PASSWORD)],
    );
    const login = await api()
      .post('/admin/auth/login')
      .send({ username, password: PASSWORD });
    expect(login.status).toBe(200);
    return {
      id: rows[0].id,
      username,
      token: login.body.token,
      h: bearer(login.body.token),
    };
  };

  const activate = (code) => {
    const key = newDeviceKey();
    return api()
      .post('/auth/activate')
      .send({
        code,
        deviceName: 'Phone',
        platform: 'ios',
        ...activationFields(code, key),
      });
  };

  let owner;
  let admin;
  let moderator;

  beforeAll(async () => {
    db = await createTestDatabase('adminapi');
    t = await createTestApp({ db, realAuth: true });
    owner = await operator('admin', { owner: true });
    admin = await operator('admin');
    moderator = await operator('moderator');
  }, 90000);

  afterAll(async () => {
    await t.close();
    await db.drop();
  });

  const createUser = (as, body) =>
    api()
      .post('/admin/users')
      .set(as.h)
      .send({ displayName: 'New Person', role: 'member', ...body });

  // ================================================================= creating

  describe('creating people', () => {
    it('creates a pending member with a one-time code that really activates a phone', async () => {
      const res = await createUser(admin, {
        username: `sarah-${++seq}`,
        displayName: 'Sarah Whitfield',
      });
      expect(res.status).toBe(201);
      expect(res.body.user).toMatchObject({
        status: 'pending',
        role: 'member',
        isOwner: false,
      });
      expect(res.body.activationCode).toMatch(/^SKY(-[0-9A-Z]{5}){4}$/);
      expect(res.body.temporaryPassword).toBeUndefined();

      expect((await activate(res.body.activationCode)).status).toBe(201);
      const detail = await api()
        .get(`/admin/users/${res.body.user.userId}`)
        .set(admin.h);
      expect(detail.body.status).toBe('active');
      expect(detail.body.codes[0].state).toBe('spent');
    });

    it('never stores the code it hands out', async () => {
      const res = await createUser(admin, { username: `nostore-${++seq}` });
      const all = JSON.stringify(
        (await db.client.query('SELECT * FROM activation_codes')).rows,
      );
      expect(all).not.toContain(res.body.activationCode);
      expect(all).not.toContain(
        normalizeActivationCode(res.body.activationCode),
      );
    });

    it('links initial contacts in the same step', async () => {
      const a = await mkUser(db.client, 'friend');
      const b = await mkUser(db.client, 'friend');
      const res = await createUser(admin, {
        username: `linked-${++seq}`,
        contactIds: [a.id, b.id],
      });
      expect(res.body.user.contacts).toBe(2);
      const { rows } = await db.client.query(
        'SELECT are_linked($1, $2) AS x, are_linked($1, $3) AS y',
        [res.body.user.userId, a.id, b.id],
      );
      expect(rows[0]).toEqual({ x: true, y: true });
    });

    it('refuses a taken or burned username with a readable reason', async () => {
      const name = `taken-${++seq}`;
      expect((await createUser(admin, { username: name })).status).toBe(201);
      const again = await createUser(admin, { username: name });
      expect(again.status).toBe(400);
      expect(again.body.message.join(' ')).toMatch(/taken|used before/);
    });

    it('refuses a malformed username before touching the database', async () => {
      const res = await createUser(admin, { username: 'No Spaces Allowed' });
      expect(res.status).toBe(400);
      expect(res.body.message.join(' ')).toMatch(/username must be/);
    });

    it('rolls back entirely if a chosen contact does not exist', async () => {
      const name = `rollback-${++seq}`;
      const res = await createUser(admin, {
        username: name,
        contactIds: [crypto.randomUUID()],
      });
      expect(res.status).toBe(400);
      const { rowCount } = await db.client.query(
        'SELECT 1 FROM users WHERE username = $1',
        [name],
      );
      expect(rowCount).toBe(0);
    });

    it('only the OWNER can create an administrator', async () => {
      expect(
        (
          await createUser(admin, {
            username: `newadmin-${++seq}`,
            role: 'admin',
          })
        ).status,
      ).toBe(403);
      const res = await createUser(owner, {
        username: `newadmin-${++seq}`,
        role: 'admin',
      });
      expect(res.status).toBe(201);
      expect(res.body.temporaryPassword).toMatch(
        /^[0-9a-z]{5}(-[0-9a-z]{5}){3}$/,
      );
    });

    it('an admin can create a moderator, who gets a temporary dashboard password', async () => {
      const res = await createUser(admin, {
        username: `newmod-${++seq}`,
        role: 'moderator',
      });
      expect(res.status).toBe(201);
      expect(res.body.temporaryPassword).toBeDefined();
    });

    it('a moderator cannot create anyone', async () => {
      expect(
        (await createUser(moderator, { username: `x-${++seq}` })).status,
      ).toBe(403);
    });
  });

  // ======================================================= temporary passwords

  describe('temporary passwords', () => {
    it('lets a new operator reach only their own account until they choose a password', async () => {
      const username = `fresh-${++seq}`;
      const made = await createUser(owner, { username, role: 'admin' });
      const login = await api()
        .post('/admin/auth/login')
        .send({ username, password: made.body.temporaryPassword });
      expect(login.status).toBe(200);
      const h = bearer(login.body.token);

      const me = await api().get('/admin/auth/me').set(h);
      expect(me.body.mustChangePassword).toBe(true);
      expect((await api().get('/admin/users').set(h)).status).toBe(403);

      const changed = await api()
        .post('/admin/auth/password')
        .set(h)
        .send({
          currentPassword: made.body.temporaryPassword,
          newPassword: 'my own long password now',
        });
      expect(changed.status).toBe(204);
      expect((await api().get('/admin/users').set(h)).status).toBe(200);
      expect(
        (await api().get('/admin/auth/me').set(h)).body.mustChangePassword,
      ).toBe(false);
    });
  });

  // ======================================================== the protected owner

  describe('the protected owner', () => {
    it('cannot be suspended, deleted, demoted or renamed by another admin', async () => {
      const u = `/admin/users/${owner.id}`;
      expect((await api().post(`${u}/suspend`).set(admin.h)).status).toBe(403);
      expect((await api().post(`${u}/delete`).set(admin.h)).status).toBe(403);
      expect(
        (await api().post(`${u}/role`).set(admin.h).send({ role: 'member' }))
          .status,
      ).toBe(403);
      expect(
        (await api().patch(u).set(admin.h).send({ displayName: 'Impostor' }))
          .status,
      ).toBe(403);
      expect(
        (
          await api()
            .post(`${u}/reset-sign-in`)
            .set(admin.h)
            .send({ resetTwoFactor: true })
        ).status,
      ).toBe(403);
    });

    it('cannot suspend, delete or demote themselves either', async () => {
      const u = `/admin/users/${owner.id}`;
      expect((await api().post(`${u}/suspend`).set(owner.h)).status).toBe(403);
      expect((await api().post(`${u}/delete`).set(owner.h)).status).toBe(403);
      expect(
        (await api().post(`${u}/role`).set(owner.h).send({ role: 'member' }))
          .status,
      ).toBe(403);
    });

    it('can rename themselves', async () => {
      const res = await api()
        .patch(`/admin/users/${owner.id}`)
        .set(owner.h)
        .send({ displayName: 'The Owner' });
      expect(res.status).toBe(200);
      expect(res.body.displayName).toBe('The Owner');
    });

    it('is protected by the DATABASE too, whatever code tries', async () => {
      for (const sql of [
        `UPDATE users SET status = 'suspended', suspended_at = now() WHERE id = $1`,
        `UPDATE users SET role_key = 'member' WHERE id = $1`,
        `UPDATE users SET is_owner = false WHERE id = $1`,
      ]) {
        const err = await failure(db.client.query(sql, [owner.id]));
        expect(err.message).toMatch(/owner/);
      }
    });

    it('cannot be duplicated: ownership is never granted by an update', async () => {
      const err = await failure(
        db.client.query('UPDATE users SET is_owner = true WHERE id = $1', [
          admin.id,
        ]),
      );
      expect(err.message).toMatch(/ownership/);
    });
  });

  // ============================================================ admins on admins

  describe('who may act on whom', () => {
    it('an admin cannot touch another admin; the owner can', async () => {
      const other = await operator('admin');
      expect(
        (await api().post(`/admin/users/${other.id}/suspend`).set(admin.h))
          .status,
      ).toBe(403);
      expect(
        (await api().post(`/admin/users/${other.id}/suspend`).set(owner.h))
          .status,
      ).toBe(200);
      expect((await api().get('/admin/auth/me').set(other.h)).status).toBe(401); // suspended: out at once
    });

    it('an admin can manage a moderator, but cannot make anyone an admin', async () => {
      const mod = await operator('moderator');
      expect(
        (
          await api()
            .post(`/admin/users/${mod.id}/role`)
            .set(admin.h)
            .send({ role: 'member' })
        ).status,
      ).toBe(200);
      expect((await api().get('/admin/auth/me').set(mod.h)).status).toBe(401); // demoted: dashboard gone

      const m = await mkUser(db.client, 'promote');
      expect(
        (
          await api()
            .post(`/admin/users/${m.id}/role`)
            .set(admin.h)
            .send({ role: 'admin' })
        ).status,
      ).toBe(403);
      const byOwner = await api()
        .post(`/admin/users/${m.id}/role`)
        .set(owner.h)
        .send({ role: 'admin' });
      expect(byOwner.status).toBe(200);
      expect(byOwner.body.temporaryPassword).toBeDefined(); // a new operator needs a password
    });

    it('a moderator can suspend a member but not another operator', async () => {
      const m = await mkUser(db.client, 'member');
      const other = await operator('moderator');
      expect(
        (await api().post(`/admin/users/${m.id}/suspend`).set(moderator.h))
          .status,
      ).toBe(200);
      expect(
        (await api().post(`/admin/users/${other.id}/suspend`).set(moderator.h))
          .status,
      ).toBe(403);
      expect(
        (await api().post(`/admin/users/${admin.id}/suspend`).set(moderator.h))
          .status,
      ).toBe(403);
    });

    it('nobody can suspend, delete or re-role their own account', async () => {
      const u = `/admin/users/${admin.id}`;
      expect((await api().post(`${u}/suspend`).set(admin.h)).status).toBe(403);
      expect((await api().post(`${u}/delete`).set(admin.h)).status).toBe(403);
      expect(
        (await api().post(`${u}/role`).set(admin.h).send({ role: 'moderator' }))
          .status,
      ).toBe(403);
    });

    it("a phone (device session) can never call the admin API, even an admin's", async () => {
      const made = await createUser(owner, {
        username: `phoneadmin-${++seq}`,
        role: 'admin',
      });
      const act = await activate(made.body.activationCode);
      expect(act.status).toBe(201);
      expect(
        (await api().get('/admin/users').set(bearer(act.body.accessToken)))
          .status,
      ).toBe(401);
    });
  });

  // =================================================================== rename

  describe('rename', () => {
    it('is announced in every chat the person is in, and audit-logged with before and after', async () => {
      const a = await mkUser(db.client, 'renamee');
      const b = await mkUser(db.client, 'partner');
      await link(db.client, a.id, b.id, admin.id);
      const [lo, hi] = a.id < b.id ? [a.id, b.id] : [b.id, a.id];
      const chat = (
        await db.client.query(
          `INSERT INTO chats (kind, user_a_id, user_b_id) VALUES ('direct', $1, $2) RETURNING id`,
          [lo, hi],
        )
      ).rows[0].id;

      const res = await api()
        .patch(`/admin/users/${a.id}`)
        .set(admin.h)
        .send({ displayName: 'Renamed Person', username: `renamed-${++seq}` });
      expect(res.status).toBe(200);

      const { rows } = await db.client.query(
        `SELECT system_event FROM messages WHERE chat_id = $1 AND kind = 'system'`,
        [chat],
      );
      expect(rows).toHaveLength(1);
      expect(rows[0].system_event).toMatchObject({
        type: 'user_renamed',
        from: { displayName: 'renamee' },
        to: { displayName: 'Renamed Person' },
      });

      const audit = await db.client.query(
        `SELECT detail FROM audit_log WHERE action = 'users.rename' AND target_user_id = $1`,
        [a.id],
      );
      expect(audit.rows[0].detail).toMatchObject({
        from: { displayName: 'renamee' },
        announcedInChats: 1,
      });
    });

    it("never touches the person's keys", async () => {
      const u = await mkUser(db.client, 'keyed');
      const d = await mkDevice(db.client, u.id);
      const before = (
        await db.client.query(
          'SELECT identity_key, signing_key FROM devices WHERE id = $1',
          [d],
        )
      ).rows[0];
      await api()
        .patch(`/admin/users/${u.id}`)
        .set(admin.h)
        .send({ displayName: 'Someone Else' });
      const after = (
        await db.client.query(
          'SELECT identity_key, signing_key FROM devices WHERE id = $1',
          [d],
        )
      ).rows[0];
      expect(after).toEqual(before);
    });

    it('cannot reuse a username someone once had', async () => {
      const a = await mkUser(db.client, 'first');
      const b = await mkUser(db.client, 'second');
      await api()
        .patch(`/admin/users/${a.id}`)
        .set(admin.h)
        .send({ username: `moved-${++seq}` });
      const res = await api()
        .patch(`/admin/users/${b.id}`)
        .set(admin.h)
        .send({ username: a.username });
      expect(res.status).toBe(400);
    });
  });

  // ======================================================== suspend and delete

  describe('suspend, reinstate, delete', () => {
    it("suspending shuts a member's phone out at once, and reinstating lets it back", async () => {
      const made = await createUser(admin, { username: `susp-${++seq}` });
      const phone = (await activate(made.body.activationCode)).body;
      const id = made.body.user.userId;

      expect(
        (await api().post(`/admin/users/${id}/suspend`).set(admin.h)).status,
      ).toBe(200);
      expect(
        (await api().get('/me').set(bearer(phone.accessToken))).status,
      ).toBe(401);
      expect(
        (await api().post(`/admin/users/${id}/reinstate`).set(admin.h)).body
          .status,
      ).toBe('active');
      expect(
        (await api().get('/me').set(bearer(phone.accessToken))).status,
      ).toBe(200);
    });

    it('reinstates someone who never activated back to pending', async () => {
      const made = await createUser(admin, { username: `neveract-${++seq}` });
      const id = made.body.user.userId;
      await api().post(`/admin/users/${id}/suspend`).set(admin.h);
      expect(
        (await api().post(`/admin/users/${id}/reinstate`).set(admin.h)).body
          .status,
      ).toBe('pending');
    });

    it('deleting revokes everything and burns the username for good', async () => {
      const friend = await mkUser(db.client, 'friend');
      const name = `gone-${++seq}`;
      const made = await createUser(admin, {
        username: name,
        contactIds: [friend.id],
      });
      const phone = (await activate(made.body.activationCode)).body;
      const id = made.body.user.userId;

      expect(
        (await api().post(`/admin/users/${id}/delete`).set(admin.h)).status,
      ).toBe(204);

      expect(
        (await api().get('/me').set(bearer(phone.accessToken))).status,
      ).toBe(401);
      const { rows } = await db.client.query(
        `SELECT (SELECT count(*)::int FROM devices WHERE user_id = $1 AND revoked_at IS NULL) AS devices,
                are_linked($1, $2) AS linked, status FROM users WHERE id = $1`,
        [id, friend.id],
      );
      expect(rows[0]).toEqual({ devices: 0, linked: false, status: 'deleted' });
      expect((await createUser(admin, { username: name })).status).toBe(400); // burned
      expect(
        (await api().post(`/admin/users/${id}/suspend`).set(admin.h)).status,
      ).toBe(404);
      expect(
        (await api().get(`/admin/users/${id}`).set(admin.h)).body.status,
      ).toBe('deleted');
    });
  });

  // ===================================================================== codes

  describe('activation codes', () => {
    it('issuing a new code kills the unused old one', async () => {
      const made = await createUser(admin, { username: `recode-${++seq}` });
      const fresh = await api()
        .post(`/admin/users/${made.body.user.userId}/codes`)
        .set(admin.h);
      expect(fresh.status).toBe(200);
      expect((await activate(made.body.activationCode)).status).toBe(401);
      expect((await activate(fresh.body.activationCode)).status).toBe(201);
    });

    it('revoking leaves no live code', async () => {
      const made = await createUser(admin, { username: `revoke-${++seq}` });
      expect(
        (
          await api()
            .post(`/admin/users/${made.body.user.userId}/codes/revoke`)
            .set(admin.h)
        ).status,
      ).toBe(204);
      expect((await activate(made.body.activationCode)).status).toBe(401);
    });

    it('will not issue a code for a suspended account', async () => {
      const m = await mkUser(db.client, 'susp');
      await api().post(`/admin/users/${m.id}/suspend`).set(admin.h);
      expect(
        (await api().post(`/admin/users/${m.id}/codes`).set(admin.h)).status,
      ).toBe(400);
    });
  });

  // ============================================================ sign-in resets

  describe('owner resets a locked-out operator', () => {
    it('owner resets an admin: new temporary password, 2FA cleared, old sessions ended', async () => {
      const other = await operator('admin');
      await db.client.query(
        `UPDATE admin_credentials SET totp_secret_enc = '\\x00', totp_enabled_at = now() WHERE user_id = $1`,
        [other.id],
      );
      const res = await api()
        .post(`/admin/users/${other.id}/reset-sign-in`)
        .set(owner.h)
        .send({ resetTwoFactor: true });
      expect(res.status).toBe(200);

      expect((await api().get('/admin/auth/me').set(other.h)).status).toBe(401); // old session gone
      expect(
        (
          await api()
            .post('/admin/auth/login')
            .send({ username: other.username, password: PASSWORD })
        ).status,
      ).toBe(401);
      const login = await api()
        .post('/admin/auth/login')
        .send({
          username: other.username,
          password: res.body.temporaryPassword,
        });
      expect(login.body.mfaRequired).toBe(false); // 2FA cleared
    });

    it('an admin cannot reset another admin, but can reset a moderator', async () => {
      const other = await operator('admin');
      const mod = await operator('moderator');
      expect(
        (
          await api()
            .post(`/admin/users/${other.id}/reset-sign-in`)
            .set(admin.h)
            .send({ resetTwoFactor: false })
        ).status,
      ).toBe(403);
      expect(
        (
          await api()
            .post(`/admin/users/${mod.id}/reset-sign-in`)
            .set(admin.h)
            .send({ resetTwoFactor: false })
        ).status,
      ).toBe(200);
    });

    it('there is nothing to reset for a member', async () => {
      const m = await mkUser(db.client, 'member');
      expect(
        (
          await api()
            .post(`/admin/users/${m.id}/reset-sign-in`)
            .set(owner.h)
            .send({ resetTwoFactor: false })
        ).status,
      ).toBe(404);
    });
  });

  // ============================================================ contact links

  describe('contact links', () => {
    const setLink = (as, a, b, linked) =>
      api()
        .post('/admin/contact-links')
        .set(as.h)
        .send({ userId: a, otherUserId: b, linked });

    it('grants and revokes, idempotently, and the editor list reflects it', async () => {
      const a = await mkUser(db.client, 'la');
      const b = await mkUser(db.client, 'lb');
      expect((await setLink(moderator, a.id, b.id, true)).body).toEqual({
        linked: true,
        changed: true,
      });
      expect((await setLink(moderator, a.id, b.id, true)).body).toEqual({
        linked: true,
        changed: false,
      });

      const list = await api()
        .get(`/admin/users/${a.id}/contacts`)
        .set(admin.h);
      expect(list.body.find((x) => x.userId === b.id).linked).toBe(true);

      expect((await setLink(admin, b.id, a.id, false)).body).toEqual({
        linked: false,
        changed: true,
      });
      const { rows } = await db.client.query('SELECT are_linked($1, $2) AS v', [
        a.id,
        b.id,
      ]);
      expect(rows[0].v).toBe(false);
    });

    it('refuses to link a person to themselves', async () => {
      const a = await mkUser(db.client, 'self');
      expect((await setLink(admin, a.id, a.id, true)).status).toBe(400);
    });

    it('leaves deleted people out of the editor', async () => {
      const a = await mkUser(db.client, 'viewer');
      const gone = await mkUser(db.client, 'gone');
      await db.client.query(
        `UPDATE users SET status = 'deleted', deleted_at = now() WHERE id = $1`,
        [gone.id],
      );
      const list = await api()
        .get(`/admin/users/${a.id}/contacts`)
        .set(admin.h);
      expect(list.body.find((x) => x.userId === gone.id)).toBeUndefined();
    });
  });

  // ================================================================== devices

  describe('devices', () => {
    it('lists live devices and revokes one, shutting its token out at once', async () => {
      const made = await createUser(admin, { username: `dev-${++seq}` });
      const phone = (await activate(made.body.activationCode)).body;

      const list = await api()
        .get(`/admin/devices?userId=${made.body.user.userId}`)
        .set(moderator.h);
      expect(list.body).toHaveLength(1);

      expect(
        (
          await api()
            .post(`/admin/devices/${phone.deviceId}/revoke`)
            .set(admin.h)
        ).status,
      ).toBe(204);
      expect(
        (await api().get('/me').set(bearer(phone.accessToken))).status,
      ).toBe(401);
      expect(
        (
          await api()
            .post(`/admin/devices/${phone.deviceId}/revoke`)
            .set(admin.h)
        ).status,
      ).toBe(404);
    });

    it("an admin cannot revoke the owner's devices", async () => {
      const d = await mkDevice(db.client, owner.id);
      expect(
        (await api().post(`/admin/devices/${d}/revoke`).set(admin.h)).status,
      ).toBe(403);
    });

    it('a moderator can see devices but not revoke them', async () => {
      const m = await mkUser(db.client, 'm');
      const d = await mkDevice(db.client, m.id);
      expect(
        (await api().post(`/admin/devices/${d}/revoke`).set(moderator.h))
          .status,
      ).toBe(403);
    });
  });

  // ========================================================= cookie and CSRF

  describe('the dashboard cookie', () => {
    const cookieLogin = async () => {
      const op = await operator('admin');
      const res = await api()
        .post('/admin/auth/login')
        .set('x-skyline-client', 'dashboard')
        .send({ username: op.username, password: PASSWORD });
      return { op, res, cookie: res.headers['set-cookie'][0].split(';')[0] };
    };

    it('is HttpOnly and SameSite=Strict, and the token is kept out of the response body', async () => {
      const { res } = await cookieLogin();
      expect(res.status).toBe(200);
      expect(res.body.token).toBeUndefined();
      const set = res.headers['set-cookie'][0];
      expect(set).toMatch(/^skyline_admin=ska_/);
      expect(set).toMatch(/HttpOnly/);
      expect(set).toMatch(/SameSite=Strict/);
    });

    it('works for reads without the extra header', async () => {
      const { cookie } = await cookieLogin();
      expect(
        (await api().get('/admin/users').set('Cookie', cookie)).status,
      ).toBe(200);
    });

    it('REFUSES a state-changing request without the dashboard header (CSRF)', async () => {
      const { cookie } = await cookieLogin();
      const m = await mkUser(db.client, 'csrf');
      const forged = await api()
        .post(`/admin/users/${m.id}/suspend`)
        .set('Cookie', cookie);
      expect(forged.status).toBe(403);
      const { rows } = await db.client.query(
        'SELECT status FROM users WHERE id = $1',
        [m.id],
      );
      expect(rows[0].status).toBe('active');

      const real = await api()
        .post(`/admin/users/${m.id}/suspend`)
        .set('Cookie', cookie)
        .set('x-skyline-client', 'dashboard');
      expect(real.status).toBe(200);
    });

    it('never accepts a device token, even inside the cookie', async () => {
      const made = await createUser(admin, {
        username: `cookiephone-${++seq}`,
      });
      const phone = (await activate(made.body.activationCode)).body;
      expect(
        (
          await api()
            .get('/me')
            .set('Cookie', `skyline_admin=${phone.accessToken}`)
        ).status,
      ).toBe(401);
    });

    it('is cleared on sign out, and the session ends', async () => {
      const { cookie } = await cookieLogin();
      const out = await api()
        .post('/admin/auth/logout')
        .set('Cookie', cookie)
        .set('x-skyline-client', 'dashboard');
      expect(out.status).toBe(204);
      expect(out.headers['set-cookie'][0]).toMatch(/Max-Age=0/);
      expect(
        (await api().get('/admin/users').set('Cookie', cookie)).status,
      ).toBe(401);
    });
  });
});
