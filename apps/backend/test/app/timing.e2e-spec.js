// Phase 12 (threat model A1, A3): the answers that must look the same must
// also TAKE the same time, or a stopwatch reveals what the body hides.
//
//   a spent activation code      vs  a code that never existed
//   a known operator username    vs  an unknown one (wrong password either way)
//   someone outside your graph   vs  an id that does not exist
//
// Requests are interleaved (A, B, A, B...) so drift in the machine's load
// affects both sides equally, and medians are compared, so one slow outlier
// cannot decide the result. The tolerance is the larger of a few
// milliseconds or a small fraction of the time itself: this catches a
// different code path (an extra query, a skipped hash), not scheduler noise.
import crypto from 'crypto';
import request from 'supertest';
import { createTestDatabase, mkUser, mkDevice } from '../db/harness';
import { createTestApp } from './app-harness';
import { newDeviceKey, activationFields } from './device-key';
import { issueActivationCode } from '../../src/modules/auth/activation-codes';
import { hashPassword } from '../../src/modules/auth/admin-auth.service';
import { AuditService } from '../../src/modules/audit/audit.service';
import { SessionService } from '../../src/modules/authorization/session.service';
import configuration from '../../src/config/configuration';

const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  return (s[Math.floor((s.length - 1) / 2)] + s[Math.ceil((s.length - 1) / 2)]) / 2;
};

// Times `a` and `b` interleaved, after a warm-up, and returns both medians.
async function race(a, b, samples) {
  for (let i = 0; i < 5; i++) {
    await a();
    await b();
  }
  const ta = [];
  const tb = [];
  for (let i = 0; i < samples; i++) {
    for (const [fn, out] of i % 2 ? [[a, ta], [b, tb]] : [[b, tb], [a, ta]]) {
      const start = process.hrtime.bigint();
      await fn();
      out.push(Number(process.hrtime.bigint() - start) / 1e6);
    }
  }
  return [median(ta), median(tb)];
}

const close = ([ma, mb], { absMs, rel }) => Math.abs(ma - mb) <= Math.max(absMs, rel * Math.max(ma, mb));

// Many requests each (Argon2 alone is tens of milliseconds, more on shared CI
// machines), so every test gets far more than Jest's default 5 seconds.
jest.setTimeout(120000);

describe('timing: the same answer takes the same time', () => {
  let db;
  let t;
  const api = () => request(t.app.getHttpServer());

  beforeAll(async () => {
    db = await createTestDatabase('timing');
    t = await createTestApp({ db, realAuth: true });
  }, 90000);

  afterAll(async () => {
    await t.close();
    await db.drop();
  });

  it('a spent activation code and one that never existed', async () => {
    const audit = new AuditService({ query: (q, p) => db.client.query(q, p) });
    const pepper = Buffer.from(configuration().auth.tokenPepper, 'utf8');
    const issuer = await mkUser(db.client, 'issuer', { role: 'admin' });
    const person = await mkUser(db.client, 'spender', { status: 'pending' });
    const { code: spent } = await issueActivationCode(db.client, { pepper, userId: person.id, issuedBy: issuer.id, audit });
    const activate = (code) =>
      api()
        .post('/auth/activate')
        .send({ code, deviceName: 'Phone', platform: 'android', ...activationFields(code, newDeviceKey()) });
    expect((await activate(spent)).status).toBe(201);

    const never = 'SKY-7K2PQ-M4XRT-9HWBN-C3FZD';
    const [a, b] = await race(
      async () => expect((await activate(spent)).status).toBe(401),
      async () => expect((await activate(never)).status).toBe(401),
      60,
    );
    expect(close([a, b], { absMs: 3, rel: 0.15 })).toBe(true);
  });

  it('a known operator username and an unknown one', async () => {
    const { rows } = await db.client.query(
      `INSERT INTO users (username, display_name, role_key, status) VALUES ('known-op', 'Known', 'admin', 'active') RETURNING id`,
    );
    await db.client.query('INSERT INTO admin_credentials (user_id, password_hash) VALUES ($1, $2)', [
      rows[0].id,
      await hashPassword('the real password, unused here'),
    ]);
    const login = (username) => api().post('/admin/auth/login').send({ username, password: 'a wrong guess' });
    const [a, b] = await race(
      async () => expect((await login('known-op')).status).toBe(401),
      async () => expect((await login('nobody-here')).status).toBe(401),
      30,
    );
    // Argon2 dominates (tens of milliseconds); anything that skipped it on
    // one side would differ by far more than this.
    expect(close([a, b], { absMs: 5, rel: 0.15 })).toBe(true);
  });

  it('someone outside your graph and an id that does not exist', async () => {
    const me = await mkUser(db.client, 'asker');
    const device = await mkDevice(db.client, me.id);
    await db.client.query('BEGIN');
    const { accessToken } = await t.app.get(SessionService).createDeviceSession(db.client, device);
    await db.client.query('COMMIT');
    const stranger = await mkUser(db.client, 'stranger');
    await mkDevice(db.client, stranger.id);
    const keys = (id) => api().get(`/users/${id}/keys`).set('Authorization', `Bearer ${accessToken}`);
    const [a, b] = await race(
      async () => expect((await keys(stranger.id)).status).toBe(404),
      async () => expect((await keys(crypto.randomUUID())).status).toBe(404),
      80,
    );
    expect(close([a, b], { absMs: 3, rel: 0.2 })).toBe(true);
  });
});
