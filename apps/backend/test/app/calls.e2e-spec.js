// Calls (Phase 10): the only server part of a call is the relay credential.
// Real device tokens, real database.
import crypto from 'crypto';
import request from 'supertest';
import { createTestDatabase, mkUser } from '../db/harness';
import { createTestApp } from './app-harness';
import configuration from '../../src/config/configuration';
import { AuditService } from '../../src/modules/audit/audit.service';
import { issueActivationCode } from '../../src/modules/auth/activation-codes';
import { newDeviceKey, activationFields } from './device-key';

describe('calls: relay credentials', () => {
  let db;
  let t;
  let phone;
  const api = () => request(t.app.getHttpServer());

  beforeAll(async () => {
    db = await createTestDatabase('calls');
    t = await createTestApp({ db, realAuth: true });
    const audit = new AuditService({ query: (q, p) => db.client.query(q, p) });
    const pepper = Buffer.from(configuration().auth.tokenPepper, 'utf8');
    const issuer = await mkUser(db.client, 'issuer', { role: 'admin' });
    const u = await mkUser(db.client, 'caller', { status: 'pending' });
    const code = (
      await issueActivationCode(db.client, {
        pepper,
        userId: u.id,
        issuedBy: issuer.id,
        audit,
      })
    ).code;
    const key = newDeviceKey();
    const res = await api()
      .post('/auth/activate')
      .send({
        code,
        deviceName: 'Phone',
        platform: 'android',
        ...activationFields(code, key),
      });
    phone = { Authorization: `Bearer ${res.body.accessToken}` };
  }, 90000);

  afterAll(async () => {
    await t.close();
    await db.drop();
  });

  it('gives a signed-in device short-lived credentials coturn can check by itself', async () => {
    const res = await api().get('/calls/turn').set(phone);
    expect(res.status).toBe(200);
    const { urls, username, credential, ttlSeconds } = res.body;
    expect(urls.length).toBeGreaterThan(0);
    const [expiry, nonce] = username.split(':');
    const now = Date.now() / 1000;
    expect(Number(expiry)).toBeGreaterThan(now + ttlSeconds - 10);
    expect(Number(expiry)).toBeLessThan(now + ttlSeconds + 10);
    expect(nonce).toMatch(/^[0-9a-f]{16}$/); // nothing that names a person
    const expected = crypto
      .createHmac('sha1', configuration().turn.secret)
      .update(username)
      .digest('base64');
    expect(credential).toBe(expected);
    const again = await api().get('/calls/turn').set(phone);
    expect(again.body.username).not.toBe(username);
  });

  it('is for signed-in devices only', async () => {
    expect((await api().get('/calls/turn')).status).toBe(401);
  });
});
