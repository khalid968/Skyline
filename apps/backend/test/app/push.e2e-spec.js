// Phase 8a push wake-ups, with a recording transport in place of Google:
// who is woken, how often, with what (nothing), and what happens to dead
// tokens and revoked devices.
import crypto from 'crypto';
import request from 'supertest';
import { createTestDatabase, mkUser, link } from '../db/harness';
import { createTestApp } from './app-harness';
import configuration from '../../src/config/configuration';
import { AuditService } from '../../src/modules/audit/audit.service';
import { issueActivationCode } from '../../src/modules/auth/activation-codes';
import { WAKE_UP } from '../../src/modules/notifications/push.transport';
import { newDeviceKey, activationFields } from './device-key';

const b64 = (buf) => buf.toString('base64');
const ecKey = () =>
  b64(Buffer.concat([Buffer.from([5]), crypto.randomBytes(32)]));
const kyberKey = () =>
  b64(Buffer.concat([Buffer.from([8]), crypto.randomBytes(1568)]));
const sig = () => b64(crypto.randomBytes(64));

describe('push wake-ups (recording transport)', () => {
  let db;
  let t;
  let audit;
  let pepper;
  let issuer;
  const api = () => request(t.app.getHttpServer());

  const device = async (userId) => {
    const key = newDeviceKey();
    const code = (
      await issueActivationCode(db.client, {
        pepper,
        userId,
        issuedBy: issuer.id,
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
    const d = {
      userId,
      ...res.body,
      h: { Authorization: `Bearer ${res.body.accessToken}` },
    };
    await api()
      .put('/me/keys')
      .set(d.h)
      .send({
        signedPreKey: { keyId: 1, publicKey: ecKey(), signature: sig() },
        lastResortKyberPreKey: {
          keyId: 2,
          publicKey: kyberKey(),
          signature: sig(),
        },
      });
    return d;
  };

  const pair = async (name) => {
    const a = await mkUser(db.client, `${name}a`, { status: 'pending' });
    const b = await mkUser(db.client, `${name}b`, { status: 'pending' });
    await link(db.client, a.id, b.id, issuer.id);
    return { from: await device(a.id), to: await device(b.id) };
  };

  const send = (from, to) =>
    api()
      .post(`/users/${to.userId}/messages`)
      .set(from.h)
      .send({
        messageId: crypto.randomUUID(),
        envelopes: [
          {
            userId: to.userId,
            deviceNumber: to.deviceNumber,
            kind: 'whisper',
            body: b64(crypto.randomBytes(64)),
          },
        ],
      });

  const token = () => `fcm-${crypto.randomBytes(24).toString('hex')}`;

  beforeAll(async () => {
    db = await createTestDatabase('push');
    audit = new AuditService({ query: (q, p) => db.client.query(q, p) });
    pepper = Buffer.from(configuration().auth.tokenPepper, 'utf8');
    issuer = await mkUser(db.client, 'issuer', { role: 'admin' });
    t = await createTestApp({ db, realAuth: true });
  }, 90000);

  beforeEach(() => {
    t.push.sent.length = 0;
    t.push.outcome = 'ok';
  });

  afterAll(async () => {
    await t.close();
    await db.drop();
  });

  it('wakes the recipient’s device, with nothing in the message', async () => {
    const { from, to } = await pair('p1');
    const tok = token();
    expect(
      (
        await api()
          .put('/me/push')
          .set(to.h)
          .send({ provider: 'fcm', token: tok })
      ).status,
    ).toBe(204);
    expect((await send(from, to)).status).toBe(201);
    expect(t.push.sent).toEqual([{ provider: 'fcm', token: tok }]);
    // The payload is fixed and content-free: no sender, no text, no chat.
    expect(WAKE_UP).toEqual({ t: 'inbox' });
  });

  it('wakes a device once for a burst of messages', async () => {
    const { from, to } = await pair('p2');
    await api()
      .put('/me/push')
      .set(to.h)
      .send({ provider: 'fcm', token: token() });
    for (let i = 0; i < 4; i++) expect((await send(from, to)).status).toBe(201);
    expect(t.push.sent).toHaveLength(1);
  });

  it('keeps one token per device, and forgets a token the provider calls dead', async () => {
    const { from, to } = await pair('p3');
    const old = token();
    const current = token();
    await api().put('/me/push').set(to.h).send({ provider: 'fcm', token: old });
    await api()
      .put('/me/push')
      .set(to.h)
      .send({ provider: 'fcm', token: current });
    t.push.outcome = 'invalid';
    await send(from, to);
    expect(t.push.sent).toEqual([{ provider: 'fcm', token: current }]);
    const { rows } = await db.client.query(
      'SELECT count(*)::int AS n FROM push_tokens WHERE device_id = $1 AND revoked_at IS NULL',
      [to.deviceId],
    );
    expect(rows[0].n).toBe(0);
  });

  it('never wakes a revoked device, and stops after the device unregisters', async () => {
    const { from, to } = await pair('p4');
    await api()
      .put('/me/push')
      .set(to.h)
      .send({ provider: 'fcm', token: token() });
    expect((await api().delete('/me/push').set(to.h)).status).toBe(204);
    await send(from, to);
    expect(t.push.sent).toHaveLength(0);

    const { from: f2, to: t2 } = await pair('p5');
    await api()
      .put('/me/push')
      .set(t2.h)
      .send({ provider: 'fcm', token: token() });
    await db.client.query(
      'UPDATE devices SET revoked_at = now() WHERE id = $1',
      [t2.deviceId],
    );
    await send(f2, t2); // coverage now excludes the revoked device, so this is a 409
    expect(t.push.sent).toHaveLength(0);
  });

  it('rejects an unknown provider and a nonsense token', async () => {
    const { to } = await pair('p6');
    expect(
      (
        await api()
          .put('/me/push')
          .set(to.h)
          .send({ provider: 'pigeon', token: token() })
      ).status,
    ).toBe(400);
    expect(
      (
        await api()
          .put('/me/push')
          .set(to.h)
          .send({ provider: 'fcm', token: 'short' })
      ).status,
    ).toBe(400);
  });
});
