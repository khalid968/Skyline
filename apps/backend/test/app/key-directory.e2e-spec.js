// Phase 7, end to end over HTTP with real authentication: devices register a
// Signal identity at activation, publish prekeys, and fetch each other's
// bundles, but only across a live direct contact link.
import crypto from 'crypto';
import request from 'supertest';
import { createTestDatabase, mkUser, link } from '../db/harness';
import { createTestApp } from './app-harness';
import configuration from '../../src/config/configuration';
import { AuditService } from '../../src/modules/audit/audit.service';
import { issueActivationCode } from '../../src/modules/auth/activation-codes';
import { MAX_UNCLAIMED } from '../../src/modules/devices/keys.service';
import { newDeviceKey, newIdentityKey, activationFields } from './device-key';

// Shapes of real libsignal public keys (content is random: the server never
// uses them, and cannot check signatures by design).
const b64 = (buf) => buf.toString('base64');
const ecKey = () => b64(Buffer.concat([Buffer.from([5]), crypto.randomBytes(32)]));
const kyberKey = () =>
  b64(Buffer.concat([Buffer.from([8]), crypto.randomBytes(1568)]));
const signature = () => b64(crypto.randomBytes(64));

const signed = (keyId) => ({ keyId, publicKey: ecKey(), signature: signature() });
const kyber = (keyId) => ({ keyId, publicKey: kyberKey(), signature: signature() });
const oneTime = (keyId) => ({ keyId, publicKey: ecKey() });
const range = (from, n) => Array.from({ length: n }, (_, i) => from + i);

describe('key directory (real tokens, real database)', () => {
  let db;
  let t;
  let audit;
  let pepper;
  let issuer;

  const api = () => request(t.app.getHttpServer());
  const bearer = (token) => ({ Authorization: `Bearer ${token}` });

  const issueCode = async (userId) =>
    (
      await issueActivationCode(db.client, {
        pepper,
        userId,
        issuedBy: issuer.id,
        audit,
      })
    ).code;

  // A member with one activated device that has published a full key set.
  const member = async (name, { publish = true, oneTimeCount = 2 } = {}) => {
    const user = await mkUser(db.client, name, { status: 'pending' });
    const device = await addDevice(user.id);
    if (publish) await publishAll(device, oneTimeCount);
    return { user, ...device };
  };

  const addDevice = async (userId) => {
    const key = newDeviceKey();
    const code = await issueCode(userId);
    const res = await api()
      .post('/auth/activate')
      .send({
        code,
        deviceName: 'Phone',
        platform: 'android',
        ...activationFields(code, key),
      });
    expect(res.status).toBe(201);
    return { key, ...res.body, h: bearer(res.body.accessToken) };
  };

  const publishAll = async (device, oneTimeCount = 2) => {
    const res = await api()
      .put('/me/keys')
      .set(device.h)
      .send({
        signedPreKey: signed(1),
        lastResortKyberPreKey: kyber(1000),
        oneTimePreKeys: range(1, oneTimeCount).map(oneTime),
        kyberPreKeys: range(1, oneTimeCount).map(kyber),
      });
    expect(res.status).toBe(200);
    return res.body;
  };

  const fetchKeys = (from, userId) =>
    api().get(`/users/${userId}/keys`).set(from.h);

  beforeAll(async () => {
    db = await createTestDatabase('keysapi');
    audit = new AuditService({ query: (q, p) => db.client.query(q, p) });
    pepper = Buffer.from(configuration().auth.tokenPepper, 'utf8');
    issuer = await mkUser(db.client, 'issuer', { role: 'admin' });
    t = await createTestApp({ db, realAuth: true });
  }, 90000);

  afterAll(async () => {
    await t.close();
    await db.drop();
  });

  // ================================================================ activation

  describe('activation registers a Signal identity', () => {
    it('stores the identity key and gives each device the next device number', async () => {
      const user = await mkUser(db.client, 'numbered', { status: 'pending' });
      const first = await addDevice(user.id);
      const second = await addDevice(user.id);
      expect([first.deviceNumber, second.deviceNumber]).toEqual([1, 2]);

      const { rows } = await db.client.query(
        'SELECT identity_key, registration_id FROM devices WHERE id = $1',
        [first.deviceId],
      );
      expect(b64(rows[0].identity_key)).toBe(first.key.identityKey);
      expect(rows[0].registration_id).toBe(first.key.registrationId);
    });

    it('refuses, with the usual generic 401, an identity the signature does not cover', async () => {
      const user = await mkUser(db.client, 'swapped', { status: 'pending' });
      const key = newDeviceKey();
      const code = await issueCode(user.id);
      const fields = activationFields(code, key);
      const attempts = {
        'identity swapped after signing': { ...fields, identityKey: newIdentityKey() },
        'registration id swapped after signing': {
          ...fields,
          registrationId: (key.registrationId % 16383) + 1,
        },
        'not a Curve25519 key (wrong type byte)': (() => {
          const k = { ...key };
          k.identityKey = b64(Buffer.concat([Buffer.from([6]), crypto.randomBytes(32)]));
          return activationFields(code, k);
        })(),
      };
      for (const [label, body] of Object.entries(attempts)) {
        const res = await api()
          .post('/auth/activate')
          .send({ code, deviceName: 'Phone', platform: 'ios', ...body });
        expect([label, res.status, res.body.message]).toEqual([label, 401, 'Unauthorized']);
      }
      // ...and the code was not spent by any of them.
      const res = await api()
        .post('/auth/activate')
        .send({ code, deviceName: 'Phone', platform: 'ios', ...fields });
      expect(res.status).toBe(201);
    });

    it('refuses an identity key that a live device already has (a clone)', async () => {
      const a = await mkUser(db.client, 'original', { status: 'pending' });
      const b = await mkUser(db.client, 'copycat', { status: 'pending' });
      const key = newDeviceKey();
      const firstCode = await issueCode(a.id);
      const ok = await api()
        .post('/auth/activate')
        .send({ code: firstCode, deviceName: 'P', platform: 'ios', ...activationFields(firstCode, key) });
      expect(ok.status).toBe(201);

      const clone = { ...newDeviceKey(), identityKey: key.identityKey };
      const code = await issueCode(b.id);
      const res = await api()
        .post('/auth/activate')
        .send({ code, deviceName: 'P', platform: 'ios', ...activationFields(code, clone) });
      expect(res.status).toBe(401);
    });
  });

  // ================================================================ publishing

  describe('publishing prekeys', () => {
    it('stores a full key set and reports what is on file', async () => {
      const m = await member('publisher', { publish: false });
      const counts = await publishAll(m, 3);
      expect(counts).toMatchObject({
        oneTimePreKeys: 3,
        kyberPreKeys: 3,
        signedPreKey: { keyId: 1 },
        lastResortKyberPreKeyId: 1000,
      });
      const again = await api().get('/me/keys').set(m.h);
      expect(again.body).toEqual(counts);
    });

    it('rotating the signed prekey replaces the one that is served', async () => {
      const m = await member('rotator');
      const res = await api().put('/me/keys').set(m.h).send({ signedPreKey: signed(2) });
      expect(res.body.signedPreKey.keyId).toBe(2);
    });

    it('rejects malformed keys with reasons, and stores nothing from that upload', async () => {
      const m = await member('sloppy', { publish: false });
      const res = await api()
        .put('/me/keys')
        .set(m.h)
        .send({
          signedPreKey: { keyId: 1, publicKey: b64(crypto.randomBytes(33)), signature: signature() },
          oneTimePreKeys: [oneTime(1), oneTime(1)],
          kyberPreKeys: [{ ...kyber(1), publicKey: ecKey().padEnd(1400, 'A') }],
        });
      expect(res.status).toBe(400);
      expect(res.body.message).toEqual(
        expect.arrayContaining([
          'signedPreKey.publicKey is not a serialized Curve25519 public key',
          'kyberPreKeys.0.publicKey is not a serialized Kyber public key',
          'oneTimePreKeys has the same keyId twice',
        ]),
      );
      const counts = await api().get('/me/keys').set(m.h);
      expect(counts.body).toMatchObject({ oneTimePreKeys: 0, signedPreKey: null });
    });

    it('rejects an empty upload, unknown fields, and a key id used before', async () => {
      const m = await member('repeat');
      expect((await api().put('/me/keys').set(m.h).send({})).status).toBe(400);
      expect(
        (await api().put('/me/keys').set(m.h).send({ oneTimePreKeys: [oneTime(50)], extra: 1 })).status,
      ).toBe(400);
      const reuse = await api().put('/me/keys').set(m.h).send({ oneTimePreKeys: [oneTime(1)] });
      expect(reuse.status).toBe(400);
      expect(reuse.body.message).toEqual(['a keyId in this upload was already used by this device']);
    });

    it(`caps unused one-time keys at ${MAX_UNCLAIMED} per device`, async () => {
      const m = await member('hoarder', { publish: false });
      for (let i = 0; i < MAX_UNCLAIMED / 100; i++) {
        const res = await api()
          .put('/me/keys')
          .set(m.h)
          .send({ oneTimePreKeys: range(1 + i * 100, 100).map(oneTime) });
        expect(res.status).toBe(200);
      }
      const over = await api()
        .put('/me/keys')
        .set(m.h)
        .send({ oneTimePreKeys: [oneTime(MAX_UNCLAIMED + 1)] });
      expect(over.status).toBe(400);
    });

    it('is a member route: a dashboard session cannot publish keys', async () => {
      const res = await api().put('/me/keys').set(bearer(`ska_${'A'.repeat(43)}`)).send({
        oneTimePreKeys: [oneTime(1)],
      });
      expect(res.status).toBe(401);
    });
  });

  // ================================================================= fetching

  describe('fetching a contact’s bundles', () => {
    it('returns one bundle per live, published device of a direct contact', async () => {
      const alice = await member('alice');
      const bob = await member('bob');
      const bobPc = await addDevice(bob.user.id);
      await publishAll(bobPc);
      await addDevice(bob.user.id); // activated but never published: not offered
      await link(db.client, alice.user.id, bob.user.id, issuer.id);

      const res = await fetchKeys(alice, bob.user.id);
      expect(res.status).toBe(200);
      expect(res.body.userId).toBe(bob.user.id);
      expect(res.body.devices.map((d) => d.deviceNumber)).toEqual([1, 2]);
      const d = res.body.devices[0];
      expect(d).toEqual({
        deviceNumber: 1,
        registrationId: bob.key.registrationId,
        identityKey: bob.key.identityKey,
        signedPreKey: { keyId: 1, publicKey: expect.any(String), signature: expect.any(String) },
        kyberPreKey: { keyId: 1, publicKey: expect.any(String), signature: expect.any(String) },
        preKey: { keyId: 1, publicKey: expect.any(String) },
      });
    });

    it('hands each one-time key out once, then falls back to the last-resort Kyber key', async () => {
      const alice = await member('alice2');
      const bob = await member('bob2', { oneTimeCount: 2 });
      await link(db.client, alice.user.id, bob.user.id, issuer.id);

      const seen = [];
      for (let i = 0; i < 3; i++) {
        const [d] = (await fetchKeys(alice, bob.user.id)).body.devices;
        seen.push([d.preKey && d.preKey.keyId, d.kyberPreKey.keyId]);
      }
      expect(seen).toEqual([
        [1, 1],
        [2, 2],
        [null, 1000],
      ]);
      const counts = await api().get('/me/keys').set(bob.h);
      expect(counts.body).toMatchObject({ oneTimePreKeys: 0, kyberPreKeys: 0 });
    });

    it('is a 404, identical in every case, outside a direct link', async () => {
      const alice = await member('alice3');
      const stranger = await member('stranger');
      const formerFriend = await member('former');
      const linkId = await link(db.client, alice.user.id, formerFriend.user.id, issuer.id);
      await db.client.query(
        'UPDATE contact_links SET revoked_at = now(), revoked_by = $2 WHERE id = $1',
        [linkId, issuer.id],
      );

      const cases = {
        'a stranger': stranger.user.id,
        'a revoked link': formerFriend.user.id,
        'yourself': alice.user.id,
        'nobody at all': crypto.randomUUID(),
        'not an id': 'not-a-uuid',
      };
      const bodies = new Set();
      for (const [label, id] of Object.entries(cases)) {
        const res = await fetchKeys(alice, id);
        expect([label, res.status]).toEqual([label, 404]);
        bodies.add(JSON.stringify(res.body));
      }
      expect(bodies.size).toBe(1);

      // ...and nothing was claimed from the stranger's keys.
      const counts = await api().get('/me/keys').set(stranger.h);
      expect(counts.body.oneTimePreKeys).toBe(2);
    });

    it('never offers a revoked device', async () => {
      const alice = await member('alice4');
      const bob = await member('bob4');
      await link(db.client, alice.user.id, bob.user.id, issuer.id);
      await db.client.query('UPDATE devices SET revoked_at = now() WHERE id = $1', [bob.deviceId]);
      const res = await fetchKeys(alice, bob.user.id);
      expect(res.body.devices).toEqual([]);
    });
  });

  describe('fetch throttling (real limits)', () => {
    let strict;
    beforeAll(async () => {
      // Scale 0.1: 2 fetches per contact per hour instead of 20.
      strict = await createTestApp({ db, realAuth: true, rateLimitScale: 0.1 });
    }, 60000);
    afterAll(() => strict.close());

    it('stops one device draining a contact’s one-time keys', async () => {
      const alice = await member('drainer');
      const bob = await member('drained', { oneTimeCount: 10 });
      await link(db.client, alice.user.id, bob.user.id, issuer.id);
      const get = () =>
        request(strict.app.getHttpServer()).get(`/users/${bob.user.id}/keys`).set(alice.h);

      expect((await get()).status).toBe(200);
      expect((await get()).status).toBe(200);
      const third = await get();
      expect(third.status).toBe(429);
      expect(third.headers['retry-after']).toBeDefined();
      const counts = await api().get('/me/keys').set(bob.h);
      expect(counts.body.oneTimePreKeys).toBe(8);
    });
  });
});
