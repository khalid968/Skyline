// Groups (Phase 8b), end to end with real dashboard sign-ins, real device
// tokens and the real database. The rules under test are owner decisions
// (decisions.md, 2026-09-25): operators make and change groups; a member may
// leave; membership is checked on every request and at delivery (404 outside).
import crypto from 'crypto';
import request from 'supertest';
import { createTestDatabase, mkUser, link } from '../db/harness';
import { createTestApp } from './app-harness';
import configuration from '../../src/config/configuration';
import { AuditService } from '../../src/modules/audit/audit.service';
import { issueActivationCode } from '../../src/modules/auth/activation-codes';
import { hashPassword } from '../../src/modules/auth/admin-auth.service';
import { newDeviceKey, activationFields } from './device-key';

const PASSWORD = 'correct horse battery staple';
const b64 = (buf) => buf.toString('base64');
const ecKey = () =>
  b64(Buffer.concat([Buffer.from([5]), crypto.randomBytes(32)]));
const kyberKey = () =>
  b64(Buffer.concat([Buffer.from([8]), crypto.randomBytes(1568)]));
const sig = () => b64(crypto.randomBytes(64));

describe('groups (real sign-ins, real database)', () => {
  let db;
  let t;
  let audit;
  let pepper;
  let seq = 0;
  let admin;
  let moderator;
  let a;
  let b;
  let c;
  let s;
  let otherAdmin;
  const api = () => request(t.app.getHttpServer());

  const operator = async (role) => {
    const username = `${role}-${++seq}`;
    const { rows } = await db.client.query(
      `INSERT INTO users (username, display_name, role_key, status) VALUES ($1, $3, $2, 'active') RETURNING id`,
      [username, role, username],
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
      h: { Authorization: `Bearer ${login.body.token}` },
    };
  };

  const member = async (name) => {
    const u = await mkUser(db.client, name, { status: 'pending' });
    const key = newDeviceKey();
    const code = (
      await issueActivationCode(db.client, {
        pepper,
        userId: u.id,
        issuedBy: admin.id,
        audit,
      })
    ).code;
    const res = await api()
      .post('/auth/activate')
      .send({
        code,
        deviceName: 'Phone',
        platform: 'android',
        ...activationFields(code, key),
      });
    expect(res.status).toBe(201);
    const d = {
      userId: u.id,
      ...res.body,
      h: { Authorization: `Bearer ${res.body.accessToken}` },
    };
    const up = await api()
      .put('/me/keys')
      .set(d.h)
      .send({
        signedPreKey: { keyId: 1, publicKey: ecKey(), signature: sig() },
        lastResortKyberPreKey: {
          keyId: 2,
          publicKey: kyberKey(),
          signature: sig(),
        },
        oneTimePreKeys: [{ keyId: 3, publicKey: ecKey() }],
      });
    expect(up.status).toBeLessThan(300);
    return d;
  };

  const dev = (d) => ({ userId: d.userId, deviceNumber: d.deviceNumber });
  const groupSend = (from, groupId, devices, extra = {}) =>
    api()
      .post(`/groups/${groupId}/messages`)
      .set(from.h)
      .send({
        messageId: crypto.randomUUID(),
        body: b64(crypto.randomBytes(120)),
        devices,
        ...extra,
      });
  const inbox = async (d) => (await api().get('/me/inbox').set(d.h)).body;
  const events = (box) => box.system.map((x) => x.event.type);

  let groupId;
  let beforeRemoval; // a message carol never collected before she was removed

  beforeAll(async () => {
    db = await createTestDatabase('groups');
    audit = new AuditService({ query: (q, p) => db.client.query(q, p) });
    pepper = Buffer.from(configuration().auth.tokenPepper, 'utf8');
    t = await createTestApp({ db, realAuth: true });
    admin = await operator('admin');
    moderator = await operator('moderator');
    otherAdmin = await mkUser(db.client, 'another-admin', { role: 'admin' });
    a = await member('alice');
    b = await member('bob');
    c = await member('carol');
    s = await member('stranger');
    await link(db.client, a.userId, b.userId, admin.id); // carol is NOT linked to alice
  }, 120000);

  afterAll(async () => {
    await t.close();
    await db.drop();
  });

  it('a moderator creates a group; it is announced and audited', async () => {
    const res = await api()
      .post('/admin/groups')
      .set(moderator.h)
      .send({
        name: 'Operations',
        description: 'North site',
        memberIds: [a.userId, b.userId, c.userId],
      });
    expect(res.status).toBe(201);
    groupId = res.body.groupId;
    expect(res.body.members).toBe(3);
    const audited = await db.client.query(
      `SELECT 1 FROM audit_log WHERE action = 'groups.create'`,
    );
    expect(audited.rowCount).toBe(1);
    expect(events(await inbox(a))).toContain('group_created');
    expect(
      (await api().get('/admin/groups').set(admin.h)).body.map((g) => g.name),
    ).toContain('Operations');
  });

  it('members only, and never a phone on an operator route', async () => {
    expect((await api().get('/admin/groups').set(a.h)).status).toBe(401);
    expect(
      (await api().get(`/groups/${groupId}/keys?userId=${a.userId}`).set(s.h))
        .status,
    ).toBe(404);
    expect((await groupSend(s, groupId, [])).status).toBe(404);
    expect((await api().post(`/groups/${groupId}/leave`).set(s.h)).status).toBe(
      404,
    );
    expect(
      (await api().post(`/groups/${crypto.randomUUID()}/leave`).set(a.h))
        .status,
    ).toBe(404);
  });

  it('lists my groups with every member and their devices, and who is also a contact', async () => {
    const mine = (await api().get('/me/groups').set(a.h)).body;
    expect(mine).toHaveLength(1);
    const g = mine[0];
    expect(g).toMatchObject({
      groupId,
      name: 'Operations',
      description: 'North site',
      archived: false,
    });
    const byName = Object.fromEntries(g.members.map((m) => [m.userId, m]));
    expect(byName[b.userId].linked).toBe(true);
    expect(byName[c.userId].linked).toBe(false);
    expect(byName[a.userId].you).toBe(true);
    expect(byName[c.userId].devices[0].identityKey).toBeTruthy();
    expect((await api().get('/me/groups').set(s.h)).body).toEqual([]);
  });

  it('fetches a fellow member’s key bundles, even without a direct link; never a stranger’s', async () => {
    const ok = await api()
      .get(`/groups/${groupId}/keys?userId=${c.userId}`)
      .set(a.h);
    expect(ok.status).toBe(200);
    expect(ok.body.devices[0].preKey).toBeTruthy();
    expect(
      (await api().get(`/groups/${groupId}/keys?userId=${s.userId}`).set(a.h))
        .status,
    ).toBe(404);
    expect((await api().get(`/users/${c.userId}/keys`).set(a.h)).status).toBe(
      404,
    ); // no direct link
  });

  it('one Sender Key ciphertext goes to exactly every member device; a stale list is a 409', async () => {
    const stale = await groupSend(a, groupId, [dev(b)]);
    expect(stale.status).toBe(409);
    expect(stale.body.missing).toEqual([dev(c)]);
    const wrong = await groupSend(a, groupId, [dev(b), dev(c), dev(s)]);
    expect(wrong.status).toBe(409);
    expect(wrong.body.extra).toEqual([dev(s)]);

    const body = b64(crypto.randomBytes(200));
    const sent = await api()
      .post(`/groups/${groupId}/messages`)
      .set(a.h)
      .send({
        messageId: crypto.randomUUID(),
        body,
        devices: [dev(b), dev(c)],
      });
    expect(sent.status).toBe(201);
    for (const d of [b, c]) {
      const got = (await inbox(d)).envelopes.find(
        (e) => e.messageId === sent.body.messageId,
      );
      expect(got).toMatchObject({
        kind: 'sender_key',
        groupId,
        body,
        senderUserId: a.userId,
      });
    }
    expect((await inbox(s)).envelopes).toHaveLength(0);
  });

  it('key shares go pairwise to any member device, never outside the group', async () => {
    const env = (d) => ({
      ...dev(d),
      kind: 'prekey',
      body: b64(crypto.randomBytes(90)),
    });
    const ok = await api()
      .post(`/groups/${groupId}/key-shares`)
      .set(a.h)
      .send({ messageId: crypto.randomUUID(), envelopes: [env(c)] });
    expect(ok.status).toBe(201);
    const got = (await inbox(c)).envelopes.find(
      (e) => e.messageId === ok.body.messageId,
    );
    expect(got).toMatchObject({ kind: 'prekey', groupId });
    const out = await api()
      .post(`/groups/${groupId}/key-shares`)
      .set(a.h)
      .send({ messageId: crypto.randomUUID(), envelopes: [env(s)] });
    expect(out.status).toBe(409);
  });

  it('a removed member is out at once: no routes, no new messages, no undelivered old ones', async () => {
    const before = await groupSend(a, groupId, [dev(b), dev(c)]);
    expect(before.status).toBe(201);
    beforeRemoval = before.body.messageId;
    const res = await api()
      .post(`/admin/groups/${groupId}/members`)
      .set(admin.h)
      .send({ userId: c.userId, member: false });
    expect(res.body).toEqual({ member: false, changed: true });
    expect((await groupSend(c, groupId, [])).status).toBe(404);
    expect((await api().get('/me/groups').set(c.h)).body).toEqual([]);
    // Waiting copies are no longer handed over, and new sends leave carol out.
    expect(
      (await inbox(c)).envelopes.filter((e) => e.groupId === groupId),
    ).toHaveLength(0);
    expect((await groupSend(a, groupId, [dev(b), dev(c)])).status).toBe(409);
    expect((await groupSend(a, groupId, [dev(b)])).status).toBe(201);
    expect(events(await inbox(a))).toContain('group_member_removed');
  });

  it('typing signals go to members only, and never outside the group', async () => {
    const env = (d) => ({
      ...dev(d),
      kind: 'whisper',
      body: b64(crypto.randomBytes(40)),
    });
    expect(
      (
        await api()
          .post(`/groups/${groupId}/signals`)
          .set(a.h)
          .send({ envelopes: [env(b)] })
      ).status,
    ).toBe(204);
    expect(
      (
        await api()
          .post(`/groups/${groupId}/signals`)
          .set(a.h)
          .send({ envelopes: [env(s)] })
      ).status,
    ).toBe(400);
    expect(
      (
        await api()
          .post(`/groups/${groupId}/signals`)
          .set(s.h)
          .send({ envelopes: [env(a)] })
      ).status,
    ).toBe(404);
  });

  it('a member leaves by themselves; the group is told', async () => {
    const res = await api().post(`/groups/${groupId}/leave`).set(b.h);
    expect(res.status).toBe(204);
    expect((await api().post(`/groups/${groupId}/leave`).set(b.h)).status).toBe(
      404,
    );
    const box = await inbox(a);
    const left = box.system.find((x) => x.event.type === 'group_member_left');
    expect(left.event).toMatchObject({ userId: b.userId, groupId });
    const audited = await db.client.query(
      `SELECT 1 FROM audit_log WHERE action = 'groups.leave'`,
    );
    expect(audited.rowCount).toBe(1);
  });

  it('someone added later sees nothing from before they joined', async () => {
    await api()
      .post(`/admin/groups/${groupId}/members`)
      .set(admin.h)
      .send({ userId: s.userId, member: true });
    const types = events(await inbox(s));
    expect(types).toContain('group_member_added');
    expect(types).not.toContain('group_created');
    expect(types).not.toContain('group_member_left');

    // Added back later, carol does not collect what was left from before.
    await api()
      .post(`/admin/groups/${groupId}/members`)
      .set(admin.h)
      .send({ userId: c.userId, member: true });
    const back = await inbox(c);
    expect(
      back.envelopes.find((e) => e.messageId === beforeRemoval),
    ).toBeUndefined();
    await api()
      .post(`/admin/groups/${groupId}/members`)
      .set(admin.h)
      .send({ userId: c.userId, member: false });
  });

  it('a rename is announced; moderators cannot touch operators; archiving closes the group', async () => {
    const renamed = await api()
      .patch(`/admin/groups/${groupId}`)
      .set(moderator.h)
      .send({ name: 'Ops North' });
    expect(renamed.body.name).toBe('Ops North');
    const ev = (await inbox(a)).system.find(
      (x) => x.event.type === 'group_renamed',
    );
    expect(ev.event).toMatchObject({ from: 'Operations', to: 'Ops North' });

    const forbidden = await api()
      .post(`/admin/groups/${groupId}/members`)
      .set(moderator.h)
      .send({ userId: otherAdmin.id, member: true });
    expect(forbidden.status).toBe(403);

    await api()
      .post(`/admin/groups/${groupId}/archive`)
      .set(admin.h)
      .send({ archived: true });
    expect((await groupSend(a, groupId, [dev(s)])).status).toBe(404);
    const mine = (await api().get('/me/groups').set(a.h)).body[0];
    expect(mine).toMatchObject({ archived: true, members: [] });
    await api()
      .post(`/admin/groups/${groupId}/archive`)
      .set(admin.h)
      .send({ archived: false });
    expect((await groupSend(a, groupId, [dev(s)])).status).toBe(201);
  });

  it('shows the membership history to operators', async () => {
    const d = (await api().get(`/admin/groups/${groupId}`).set(admin.h)).body;
    const by = Object.fromEntries(d.history.map((m) => [m.userId, m]));
    expect(by[b.userId].left).toBe(true);
    expect(by[c.userId].left).toBe(false);
    expect(by[c.userId].removedAt).toBeTruthy();
    expect(d.members).toBe(2);
  });
});
