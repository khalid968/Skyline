// Phase 11 (admin dashboard v2, boards 36-39), end to end with REAL dashboard
// sign-ins, a real database and real Redis, at production limits. The access
// rules here are owner decisions (decisions.md 2026-09-26): the audit log and
// alerts are for the owner and admins, never moderators; every operator sees
// the overview; sessions are your own, or everyone's for the owner.
import request from 'supertest';
import { createTestDatabase, mkUser, mkDevice } from '../db/harness';
import { createTestApp } from './app-harness';
import { hashPassword } from '../../src/modules/auth/admin-auth.service';
import { AbuseService, RULES } from '../../src/modules/abuse/abuse.service';
import { UsageService } from '../../src/modules/monitoring/usage.service';
import { csvCell } from '../../src/modules/admin/admin-audit.service';

const PASSWORD = 'correct horse battery staple';

describe('admin dashboard v2 (real sign-ins, real database, real Redis)', () => {
  let db;
  let t;
  let seq = 0;
  let abuse;
  const api = () => request(t.app.getHttpServer());
  const bearer = (token) => ({ Authorization: `Bearer ${token}` });
  const res = { setHeader: () => {} };

  const operator = async (role = 'admin', { owner = false, agent = 'Firefox on Windows' } = {}) => {
    const username = `${role}-v2-${++seq}`;
    const { rows } = await db.client.query(
      `INSERT INTO users (username, display_name, role_key, status, is_owner)
       VALUES ($1, $4, $2, 'active', $3) RETURNING id`,
      [username, role, owner, `${role} ${seq}`],
    );
    await db.client.query('INSERT INTO admin_credentials (user_id, password_hash) VALUES ($1, $2)', [
      rows[0].id,
      await hashPassword(PASSWORD),
    ]);
    const login = await api().post('/admin/auth/login').set('User-Agent', agent).send({ username, password: PASSWORD });
    expect(login.status).toBe(200);
    return { id: rows[0].id, username, h: bearer(login.body.token) };
  };

  let owner;
  let admin;
  let moderator;

  beforeAll(async () => {
    db = await createTestDatabase('dashv2');
    t = await createTestApp({ db, realAuth: true, rateLimitScale: 1 });
    abuse = t.app.get(AbuseService);
    owner = await operator('admin', { owner: true });
    admin = await operator('admin');
    moderator = await operator('moderator');
  }, 90000);

  afterAll(async () => {
    await t.close();
    await db.drop();
  });

  // ------------------------------------------------------------- access

  it('lets every operator see the overview, but only the owner and admins see the audit log and alerts', async () => {
    for (const who of [owner, admin, moderator]) {
      expect((await api().get('/admin/overview').set(who.h)).status).toBe(200);
    }
    for (const who of [owner, admin]) {
      expect((await api().get('/admin/audit').set(who.h)).status).toBe(200);
      expect((await api().get('/admin/alerts').set(who.h)).status).toBe(200);
    }
    // Owner decision: moderators no longer read the audit log.
    expect((await api().get('/admin/audit').set(moderator.h)).status).toBe(403);
    expect((await api().get('/admin/audit/export').set(moderator.h)).status).toBe(403);
    expect((await api().get('/admin/alerts').set(moderator.h)).status).toBe(403);
    // Signed out: 401, whatever the page.
    for (const path of ['/admin/overview', '/admin/audit', '/admin/alerts', '/admin/sessions']) {
      expect((await api().get(path)).status).toBe(401);
    }
  });

  // ----------------------------------------------------------- overview

  it('reports service health and totals, never anything per person', async () => {
    const person = (await mkUser(db.client, 'counted')).id;
    await mkDevice(db.client, person);
    const usage = t.app.get(UsageService);
    await usage.bump('messages');
    await usage.bump('messages');
    await usage.bump('group_messages');
    await usage.bump('relay_credentials');
    await usage.bump('relay_credentials');
    await usage.bump('relay_credentials');

    const r = await api().get('/admin/overview?days=7').set(moderator.h);
    expect(r.status).toBe(200);
    const byId = Object.fromEntries(r.body.services.map((s) => [s.id, s]));
    expect(Object.keys(byId).sort()).toEqual(['database', 'realtime', 'relay', 'server', 'storage']);
    expect(byId.database.ok).toBe(true);
    expect(byId.realtime.ok).toBe(true);
    expect(r.body.totals.people).toBeGreaterThanOrEqual(1);
    expect(r.body.totals.devices).toBeGreaterThanOrEqual(1);
    expect(r.body.perDay).toHaveLength(7);
    const today = r.body.perDay[6];
    expect(today.messages).toBe(3); // one to one and group, each once
    expect(today.calls).toBe(2); // 3 relay sign-ins -> ceil(3 / 2)
    expect(r.body.storage.databaseBytes).toBeGreaterThan(0);
    expect(typeof r.body.server.version).toBe('string');
    // Nothing in the response names a member.
    expect(JSON.stringify(r.body)).not.toContain('counted');

    // Only 7, 14 or 30 days; anything else falls back to 14.
    expect((await api().get('/admin/overview?days=365').set(admin.h)).body.perDay).toHaveLength(14);
  });

  it('keeps usage totals free of any per-person column', async () => {
    const { rows } = await db.client.query(
      `SELECT column_name FROM information_schema.columns WHERE table_name = 'usage_daily' ORDER BY 1`,
    );
    expect(rows.map((r) => r.column_name)).toEqual(['count', 'day', 'metric']);
  });

  // ---------------------------------------------------------- audit log

  it('lists, filters, searches and pages the audit log, and exports a safe CSV', async () => {
    const target = (await mkUser(db.client, 'audited')).id;
    await api().post(`/admin/users/${target}/suspend`).set(admin.h).expect(200);
    await api().post(`/admin/users/${target}/reinstate`).set(admin.h).expect(200);

    const all = await api().get('/admin/audit?limit=2').set(owner.h);
    expect(all.body.entries).toHaveLength(2);
    expect(all.body.next).not.toBeNull();
    const page2 = await api().get(`/admin/audit?limit=2&before=${all.body.next}`).set(owner.h);
    expect(Number(page2.body.entries[0].id)).toBeLessThan(Number(all.body.next));

    const accounts = await api().get('/admin/audit?category=accounts&q=audited').set(owner.h);
    const actions = accounts.body.entries.map((e) => e.action);
    expect(actions).toEqual(['users.reinstate', 'users.suspend']);
    expect(accounts.body.entries[0].actor.userId).toBe(admin.id);
    expect(accounts.body.entries[0].target.displayName).toBe('audited');

    const signins = await api().get('/admin/audit?category=signins').set(owner.h);
    expect(signins.body.entries.every((e) => e.action.startsWith('admin_auth.'))).toBe(true);

    const csv = await api().get('/admin/audit/export?category=accounts').set(owner.h);
    expect(csv.status).toBe(200);
    expect(csv.headers['content-type']).toMatch(/text\/csv/);
    expect(csv.headers['content-disposition']).toMatch(/attachment; filename="skyline-audit-/);
    expect(csv.text.split('\r\n')[0]).toBe('time,action,by,by_username,about,about_username,group,device,address,details');
    expect(csv.text).toContain('users.suspend');
    // Times are ISO 8601.
    expect(csv.text.split('\r\n')[1]).toMatch(/^"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z","users\./);
    // A spreadsheet never runs a cell as a formula.
    expect(csvCell('=HYPERLINK("x")')).toBe(`"'=HYPERLINK(""x"")"`);
  });

  // ------------------------------------------------------ abuse: sending

  it('slows a device that sends far too fast, raises one alert, and lets an admin lift it', async () => {
    const person = (await mkUser(db.client, 'fastsender')).id;
    const device = await mkDevice(db.client, person);
    const caller = { userId: person, deviceId: device };
    const n = RULES.send_rate.count;
    for (let i = 0; i < n; i++) await abuse.beforeSend(caller, res);

    // One alert, with the limit running, in the audit log with no actor.
    const open = await api().get('/admin/alerts').set(admin.h);
    const alert = open.body.alerts.find((a) => a.device?.deviceId === device);
    expect(alert).toMatchObject({ kind: 'send_rate', level: 'high', limitActive: true });
    expect(alert.subject.userId).toBe(person);
    expect(alert.evidence.messages).toBe(n);
    expect(open.body.alerts.filter((a) => a.device?.deviceId === device)).toHaveLength(1);
    const auto = await api().get('/admin/audit?category=automatic').set(owner.h);
    expect(auto.body.entries.find((e) => e.action === 'abuse.auto_limit' && e.device?.deviceId === device).actor).toBeNull();

    // Slowed: one message per 5 seconds.
    await abuse.beforeSend(caller, res);
    await expect(abuse.beforeSend(caller, res)).rejects.toMatchObject({ status: 429 });

    // Lifted: sending is back to normal at once.
    const lifted = await api().post(`/admin/alerts/${alert.alertId}/lift`).set(admin.h);
    expect(lifted.status).toBe(200);
    expect(lifted.body).toMatchObject({ limitActive: false, liftedBy: 'admin 2' });
    await abuse.beforeSend(caller, res);
    await abuse.beforeSend(caller, res);
    // Nothing left to lift: 404.
    expect((await api().post(`/admin/alerts/${alert.alertId}/lift`).set(admin.h)).status).toBe(404);
    expect((await api().post(`/admin/alerts/not-a-uuid/lift`).set(admin.h)).status).toBe(404);
    // Moderators cannot act on alerts.
    expect((await api().post(`/admin/alerts/${alert.alertId}/review`).set(moderator.h).send({ suspend: false })).status).toBe(403);
  });

  it('suspends the person only when an operator decides to, on review', async () => {
    const person = (await mkUser(db.client, 'reviewed')).id;
    const device = await mkDevice(db.client, person);
    for (let i = 0; i < RULES.send_rate.count; i++) await abuse.beforeSend({ userId: person, deviceId: device }, res);
    const alert = (await api().get('/admin/alerts').set(owner.h)).body.alerts.find((a) => a.device?.deviceId === device);

    // Raising the alert suspended nobody.
    expect((await db.client.query('SELECT status FROM users WHERE id = $1', [person])).rows[0].status).toBe('active');

    const r = await api().post(`/admin/alerts/${alert.alertId}/review`).set(owner.h).send({ suspend: true });
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ outcome: 'suspended', reviewedBy: 'admin 1' });
    expect((await db.client.query('SELECT status FROM users WHERE id = $1', [person])).rows[0].status).toBe('suspended');

    const reviewed = await api().get('/admin/alerts?state=reviewed').set(owner.h);
    expect(reviewed.body.alerts.some((a) => a.alertId === alert.alertId)).toBe(true);
    // Reviewed once only.
    expect((await api().post(`/admin/alerts/${alert.alertId}/review`).set(owner.h).send({ suspend: false })).status).toBe(404);
    // The body is validated.
    expect((await api().post(`/admin/alerts/${alert.alertId}/review`).set(owner.h).send({ suspend: 'yes' })).status).toBe(400);
  });

  // ---------------------------------------------------- abuse: sign-ins

  it('pauses dashboard sign-in after 5 wrong passwords, answering exactly like a wrong password', async () => {
    const victim = await operator('moderator');
    for (let i = 0; i < RULES.admin_password.count; i++) {
      const r = await api().post('/admin/auth/login').send({ username: victim.username, password: 'wrong' });
      expect(r.status).toBe(401);
    }
    // Paused: the RIGHT password is refused, with the same 401 and body.
    const wrong = await api().post('/admin/auth/login').send({ username: victim.username, password: 'wrong' });
    const right = await api().post('/admin/auth/login').send({ username: victim.username, password: PASSWORD });
    expect(right.status).toBe(401);
    expect(right.body).toEqual(wrong.body);

    const alert = (await api().get('/admin/alerts').set(owner.h)).body.alerts.find(
      (a) => a.kind === 'admin_password' && a.subject?.userId === victim.id,
    );
    expect(alert).toMatchObject({ level: 'medium', limitActive: true });

    // Lifting it lets the operator in again.
    await api().post(`/admin/alerts/${alert.alertId}/lift`).set(owner.h).expect(200);
    expect((await api().post('/admin/auth/login').send({ username: victim.username, password: PASSWORD })).status).toBe(200);
  });

  it('raises an alert (and nothing else) for several new devices in an hour', async () => {
    const person = (await mkUser(db.client, 'manydevices')).id;
    for (let i = 0; i < RULES.device_burst.count; i++) await mkDevice(db.client, person);
    await abuse.noteDeviceActivated(person);
    const alert = (await api().get('/admin/alerts').set(admin.h)).body.alerts.find(
      (a) => a.kind === 'device_burst' && a.subject?.userId === person,
    );
    expect(alert).toMatchObject({ limitActive: false, limitUntil: null });
    expect(alert.evidence.devices).toBe(RULES.device_burst.count);
  });

  it('lets a slowed device have only one upload in progress', async () => {
    const person = (await mkUser(db.client, 'uploader')).id;
    const device = await mkDevice(db.client, person);
    const caller = { userId: person, deviceId: device };
    for (let i = 0; i < RULES.upload_rate.count; i++) await abuse.beforeUpload(caller, res);
    // Limited, but nothing in progress yet: allowed.
    await abuse.beforeUpload(caller, res);
    await db.client.query(
      `INSERT INTO attachments (storage_key, ciphertext_bytes, ciphertext_sha256, uploaded_by_device_id)
       VALUES (gen_random_uuid()::text, 100, decode(repeat('00', 32), 'hex'), $1)`,
      [device],
    );
    await expect(abuse.beforeUpload(caller, res)).rejects.toMatchObject({ status: 429 });
  });

  // ------------------------------------------------------------ sessions

  it('shows operators their own sessions, and the owner everyone\'s', async () => {
    const mine = await api().get('/admin/sessions').set(moderator.h);
    expect(mine.status).toBe(200);
    expect(mine.body.every((s) => s.operator.userId === moderator.id)).toBe(true);
    const current = mine.body.find((s) => s.current);
    expect(current).toMatchObject({ userAgent: 'Firefox on Windows', usedTwoFactor: false });

    const all = await api().get('/admin/sessions').set(owner.h);
    const people = new Set(all.body.map((s) => s.operator.userId));
    expect(people.has(admin.id) && people.has(moderator.id) && people.has(owner.id)).toBe(true);
  });

  it('ends a session on its very next request, and hides other people\'s sessions from non-owners', async () => {
    const second = await operator('moderator', { agent: 'Safari on macOS' });
    const other = await operator('moderator');
    const theirs = (await api().get('/admin/sessions').set(other.h)).body.find((s) => s.current);

    // Another moderator's session: 404, as if it did not exist.
    expect((await api().post(`/admin/sessions/${theirs.sessionId}/revoke`).set(second.h)).status).toBe(404);
    // Your own current session is ended with Sign out, not here.
    const own = (await api().get('/admin/sessions').set(second.h)).body.find((s) => s.current);
    expect((await api().post(`/admin/sessions/${own.sessionId}/revoke`).set(second.h)).status).toBe(404);

    // The owner can end anyone's.
    expect((await api().post(`/admin/sessions/${theirs.sessionId}/revoke`).set(owner.h)).status).toBe(204);
    expect((await api().get('/admin/overview').set(other.h)).status).toBe(401);
    const audit = await api().get('/admin/audit?category=signins').set(owner.h);
    expect(audit.body.entries.some((e) => e.action === 'admin_auth.session_revoke' && e.target?.userId === other.id)).toBe(true);
  });

  it('signs out everyone but the owner, or just your own other sessions', async () => {
    const a = await operator('moderator');
    const aSecond = bearer(
      (await api().post('/admin/auth/login').send({ username: a.username, password: PASSWORD })).body.token,
    );
    // A moderator: only their own other session ends.
    const r = await api().post('/admin/sessions/revoke-others').set(a.h);
    expect(r.body.signedOut).toBe(1);
    expect((await api().get('/admin/overview').set(aSecond)).status).toBe(401);
    expect((await api().get('/admin/overview').set(a.h)).status).toBe(200);
    expect((await api().get('/admin/overview').set(admin.h)).status).toBe(200);

    // The owner: everyone else's.
    await api().post('/admin/sessions/revoke-others').set(owner.h).expect(200);
    expect((await api().get('/admin/overview').set(admin.h)).status).toBe(401);
    expect((await api().get('/admin/overview').set(a.h)).status).toBe(401);
    expect((await api().get('/admin/overview').set(owner.h)).status).toBe(200);
  });
});
