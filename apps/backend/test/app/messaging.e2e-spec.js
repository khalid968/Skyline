// Phase 8a, end to end over HTTP and WebSocket with real authentication:
// sending one ciphertext per device, the inbox, acknowledgement (which erases
// the ciphertext), delivery receipts, typing signals, and system notices.
// The "ciphertext" here is random bytes: the server cannot tell the
// difference, which is the point. crypto-e2e covers real libsignal.
import crypto from 'crypto';
import request from 'supertest';
import WebSocket from 'ws';
import { createTestDatabase, mkUser, link } from '../db/harness';
import { createTestApp } from './app-harness';
import configuration from '../../src/config/configuration';
import { AuditService } from '../../src/modules/audit/audit.service';
import { issueActivationCode } from '../../src/modules/auth/activation-codes';
import { newDeviceKey, activationFields } from './device-key';

const b64 = (buf) => buf.toString('base64');
const ecKey = () =>
  b64(Buffer.concat([Buffer.from([5]), crypto.randomBytes(32)]));
const kyberKey = () =>
  b64(Buffer.concat([Buffer.from([8]), crypto.randomBytes(1568)]));
const sig = () => b64(crypto.randomBytes(64));
const cipher = (n = 200) => b64(crypto.randomBytes(n));

describe('messaging (real tokens, real database, real sockets)', () => {
  let db;
  let t;
  let audit;
  let pepper;
  let issuer;
  const sockets = [];

  const api = () => request(t.app.getHttpServer());
  const bearer = (token) => ({ Authorization: `Bearer ${token}` });

  const addDevice = async (userId, { publish = true } = {}) => {
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
    expect(res.status).toBe(201);
    const d = { userId, ...res.body, h: bearer(res.body.accessToken) };
    if (publish) {
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
        });
      expect(up.status).toBe(200);
    }
    return d;
  };

  const person = async (name, devices = 1) => {
    const user = await mkUser(db.client, name, { status: 'pending' });
    const list = [];
    for (let i = 0; i < devices; i++) list.push(await addDevice(user.id));
    return { id: user.id, devices: list, d: list[0] };
  };

  const env = (to, extra = {}) => ({
    userId: to.userId,
    deviceNumber: to.deviceNumber,
    kind: 'whisper',
    body: cipher(),
    ...extra,
  });

  // Envelopes for every device that must get a copy.
  const coverAll = (from, recipient, sender) => [
    ...recipient.devices.map((d) => env(d)),
    ...sender.devices
      .filter((d) => d.deviceId !== from.deviceId)
      .map((d) => env(d)),
  ];

  const send = (from, toUserId, envelopes, messageId = crypto.randomUUID()) =>
    api()
      .post(`/users/${toUserId}/messages`)
      .set(from.h)
      .send({ messageId, envelopes });

  const inbox = (d) => api().get('/me/inbox').set(d.h);

  const openSocket = (d) =>
    new Promise((resolve) => {
      const ws = new WebSocket(`ws://localhost:${t.port}/ws`, { headers: d.h });
      sockets.push(ws);
      const out = { ws, frames: [] };
      ws.on('message', (raw) => {
        const f = JSON.parse(raw.toString());
        out.frames.push(f);
        if (f.type === 'ready') resolve(out);
      });
      ws.on('error', () => {});
    });
  const waitFor = async (sock, type, ms = 3000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      const f = sock.frames.find((x) => x.type === type);
      if (f) return f;
      await new Promise((r) => setTimeout(r, 25));
    }
    return null;
  };

  beforeAll(async () => {
    db = await createTestDatabase('messaging');
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

  describe('contacts', () => {
    it('lists only direct links, each with the devices that can be reached', async () => {
      const alice = await person('alice');
      const bob = await person('bob', 2);
      const stranger = await person('stranger');
      await addDevice(bob.id, { publish: false }); // activated, no keys: not reachable yet
      await link(db.client, alice.id, bob.id, issuer.id);

      const res = await api().get('/me/contacts').set(alice.d.h);
      expect(res.status).toBe(200);
      expect(res.body.map((c) => c.userId)).toEqual([bob.id]);
      expect(res.body[0].devices.map((d) => d.deviceNumber)).toEqual([1, 2]);
      expect(res.body[0].devices[0].identityKey).toMatch(/^[A-Za-z0-9+/]+=*$/);
      expect(res.body.some((c) => c.userId === stranger.id)).toBe(false);

      expect(
        (await api().get(`/users/${stranger.id}/devices`).set(alice.d.h))
          .status,
      ).toBe(404);
      expect(
        (await api().get(`/users/${bob.id}/devices`).set(alice.d.h)).body,
      ).toHaveLength(2);
    });
  });

  describe('sending', () => {
    it('stores one ciphertext per device: the contact’s and your OTHER devices', async () => {
      const alice = await person('asend', 2);
      const bob = await person('bsend', 2);
      await link(db.client, alice.id, bob.id, issuer.id);

      const res = await send(alice.d, bob.id, coverAll(alice.d, bob, alice));
      expect(res.status).toBe(201);

      for (const d of [...bob.devices, alice.devices[1]]) {
        const box = await inbox(d);
        expect(box.body.envelopes).toHaveLength(1);
        expect(box.body.envelopes[0]).toMatchObject({
          messageId: res.body.messageId,
          senderUserId: alice.id,
          senderDeviceNumber: 1,
          kind: 'whisper',
        });
        // How long the server has held it, by its own clock (calls ring
        // only while fresh, whatever the phones' clocks say).
        const { ageMs } = box.body.envelopes[0];
        expect(Number.isInteger(ageMs)).toBe(true);
        expect(ageMs).toBeGreaterThanOrEqual(0);
        expect(ageMs).toBeLessThan(60000);
      }
      expect((await inbox(alice.d)).body.envelopes).toHaveLength(0);
    });

    it('refuses a stale device list with 409, naming what is missing and what is unknown', async () => {
      const alice = await person('astale', 2);
      const bob = await person('bstale', 2);
      await link(db.client, alice.id, bob.id, issuer.id);

      const res = await send(alice.d, bob.id, [
        env(bob.devices[0]),
        env({ userId: bob.id, deviceNumber: 9 }),
      ]);
      expect(res.status).toBe(409);
      expect(res.body.missing).toEqual(
        expect.arrayContaining([
          { userId: bob.id, deviceNumber: 2 },
          { userId: alice.id, deviceNumber: 2 },
        ]),
      );
      expect(res.body.extra).toEqual([{ userId: bob.id, deviceNumber: 9 }]);
      const { rows } = await db.client.query(
        'SELECT count(*)::int AS n FROM messages WHERE sender_user_id = $1',
        [alice.id],
      );
      expect(rows[0].n).toBe(0);
    });

    it('a retry with the same message id delivers once', async () => {
      const alice = await person('aretry');
      const bob = await person('bretry');
      await link(db.client, alice.id, bob.id, issuer.id);
      const id = crypto.randomUUID();
      const envs = coverAll(alice.d, bob, alice);
      const first = await send(alice.d, bob.id, envs, id);
      const again = await send(alice.d, bob.id, envs, id);
      expect([first.status, again.status]).toEqual([201, 201]);
      expect(again.body).toEqual(first.body);
      expect((await inbox(bob.d)).body.envelopes).toHaveLength(1);
    });

    it('is a 404 without a direct link, and a revoked link stops delivery of what is waiting', async () => {
      const alice = await person('agraph');
      const bob = await person('bgraph');
      expect((await send(alice.d, bob.id, [env(bob.d)])).status).toBe(404);

      const linkId = await link(db.client, alice.id, bob.id, issuer.id);
      expect((await send(alice.d, bob.id, [env(bob.d)])).status).toBe(201);
      await db.client.query(
        'UPDATE contact_links SET revoked_at = now(), revoked_by = $2 WHERE id = $1',
        [linkId, issuer.id],
      );
      expect((await inbox(bob.d)).body.envelopes).toHaveLength(0);
      expect((await send(alice.d, bob.id, [env(bob.d)])).status).toBe(404);
    });

    it('rejects malformed ciphertext and duplicate devices', async () => {
      const alice = await person('abad');
      const bob = await person('bbad');
      await link(db.client, alice.id, bob.id, issuer.id);
      expect(
        (await send(alice.d, bob.id, [env(bob.d, { body: 'not base64!!' })]))
          .status,
      ).toBe(400);
      expect(
        (await send(alice.d, bob.id, [env(bob.d), env(bob.d)])).status,
      ).toBe(400);
      expect(
        (await send(alice.d, bob.id, [env(bob.d, { kind: 'plaintext' })]))
          .status,
      ).toBe(400);
    });
  });

  describe('delivery', () => {
    it('nudges the recipient over the socket; the ack erases the ciphertext and tells the sender', async () => {
      const alice = await person('adeliver');
      const bob = await person('bdeliver');
      await link(db.client, alice.id, bob.id, issuer.id);
      const bobSock = await openSocket(bob.d);
      const aliceSock = await openSocket(alice.d);

      const sent = await send(alice.d, bob.id, coverAll(alice.d, bob, alice));
      const nudge = await waitFor(bobSock, 'inbox');
      expect(nudge).toMatchObject({ type: 'inbox', payload: {} });

      const box = await inbox(bob.d);
      const ack = await api()
        .post('/me/inbox/ack')
        .set(bob.d.h)
        .send({ envelopeIds: box.body.envelopes.map((e) => e.envelopeId) });
      expect(ack.body).toEqual({ acknowledged: 1 });

      const receipt = await waitFor(aliceSock, 'receipt');
      expect(receipt.payload).toEqual({
        state: 'delivered',
        messageIds: [sent.body.messageId],
      });

      const { rows } = await db.client.query(
        'SELECT ciphertext, delivered_at FROM message_envelopes WHERE message_id = $1',
        [sent.body.messageId],
      );
      expect(rows[0].ciphertext).toBeNull();
      expect(rows[0].delivered_at).not.toBeNull();
      expect((await inbox(bob.d)).body.envelopes).toHaveLength(0);

      const status = await api()
        .post('/me/messages/status')
        .set(alice.d.h)
        .send({ messageIds: [sent.body.messageId] });
      expect(status.body).toEqual([
        { messageId: sent.body.messageId, delivered: true },
      ]);
    });

    it('a device can acknowledge only its own copies', async () => {
      const alice = await person('aown');
      const bob = await person('bown');
      const eve = await person('eown');
      await link(db.client, alice.id, bob.id, issuer.id);
      await send(alice.d, bob.id, coverAll(alice.d, bob, alice));
      const [e] = (await inbox(bob.d)).body.envelopes;
      const res = await api()
        .post('/me/inbox/ack')
        .set(eve.d.h)
        .send({ envelopeIds: [e.envelopeId] });
      expect(res.body).toEqual({ acknowledged: 0 });
      expect((await inbox(bob.d)).body.envelopes).toHaveLength(1);
    });
  });

  describe('typing signals', () => {
    it('reach online devices only and are never stored', async () => {
      const alice = await person('atype');
      const bob = await person('btype');
      await link(db.client, alice.id, bob.id, issuer.id);
      const bobSock = await openSocket(bob.d);
      const before = await db.client.query(
        'SELECT count(*)::int AS n FROM message_envelopes',
      );

      const res = await api()
        .post(`/users/${bob.id}/signals`)
        .set(alice.d.h)
        .send({ envelopes: [env(bob.d)] });
      expect(res.status).toBe(204);
      const f = await waitFor(bobSock, 'signal');
      expect(f.from).toBe(alice.id);
      expect(f.payload.fromDevice).toBe(1);
      expect(f.payload.envelopes[0]).toMatchObject({
        userId: bob.id,
        deviceNumber: 1,
      });

      const after = await db.client.query(
        'SELECT count(*)::int AS n FROM message_envelopes',
      );
      expect(after.rows[0].n).toBe(before.rows[0].n);
    });
  });

  describe('system notices', () => {
    it('an admin rename reaches each device once, and a new device starts after it', async () => {
      const alice = await person('asys');
      const bob = await person('bsys');
      await link(db.client, alice.id, bob.id, issuer.id);
      await send(alice.d, bob.id, coverAll(alice.d, bob, alice)); // the chat now exists
      const { rows } = await db.client.query(
        `SELECT id FROM chats WHERE kind = 'direct' AND $1 IN (user_a_id, user_b_id)`,
        [alice.id],
      );
      await db.client.query(
        `INSERT INTO messages (chat_id, kind, system_event) VALUES ($1, 'system', $2)`,
        [
          rows[0].id,
          JSON.stringify({ type: 'user_renamed', userId: alice.id }),
        ],
      );

      const box = await inbox(bob.d);
      expect(box.body.system).toHaveLength(1);
      expect(box.body.system[0].event).toMatchObject({ type: 'user_renamed' });
      await api()
        .post('/me/inbox/ack')
        .set(bob.d.h)
        .send({ systemSeq: box.body.system[0].seq });
      expect((await inbox(bob.d)).body.system).toHaveLength(0);

      const bobNew = await addDevice(bob.id);
      expect((await inbox(bobNew)).body.system).toHaveLength(0);
    });
  });

  describe('your own devices', () => {
    it('can fetch key bundles for your OTHER devices, never your own', async () => {
      const alice = await person('aself', 2);
      const res = await api().get('/me/device-keys').set(alice.d.h);
      expect(res.status).toBe(200);
      expect(res.body.devices.map((d) => d.deviceNumber)).toEqual([2]);
    });
  });
});
