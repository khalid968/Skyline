// Media, end to end with real authentication and the real (dev) object store:
// resumable 8 MB uploads, claiming by a message, graph-checked downloads with
// byte ranges, and deletion after 30 days. The bytes are random: the server
// cannot tell ciphertext from noise, which is the point.
import crypto from 'crypto';
import request from 'supertest';
import { createTestDatabase, mkUser, link } from '../db/harness';
import { createTestApp } from './app-harness';
import configuration from '../../src/config/configuration';
import { AuditService } from '../../src/modules/audit/audit.service';
import { issueActivationCode } from '../../src/modules/auth/activation-codes';
import { MediaService, PART_SIZE } from '../../src/modules/media/media.service';
import { newDeviceKey, activationFields } from './device-key';

const b64 = (buf) => buf.toString('base64');
const ecKey = () =>
  b64(Buffer.concat([Buffer.from([5]), crypto.randomBytes(32)]));
const kyberKey = () =>
  b64(Buffer.concat([Buffer.from([8]), crypto.randomBytes(1568)]));
const sig = () => b64(crypto.randomBytes(64));

describe('media (real tokens, real object store)', () => {
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

  const people = async (name) => {
    const a = await mkUser(db.client, `${name}a`, { status: 'pending' });
    const b = await mkUser(db.client, `${name}b`, { status: 'pending' });
    const linkId = await link(db.client, a.id, b.id, issuer.id);
    return { from: await device(a.id), to: await device(b.id), linkId };
  };

  // Uploads `bytes` as a file; returns its id.
  const upload = async (d, bytes, { finish = true, skip = [] } = {}) => {
    const sha256 = b64(crypto.createHash('sha256').update(bytes).digest());
    const s = await api()
      .post('/attachments')
      .set(d.h)
      .send({ ciphertextBytes: bytes.length, sha256 });
    expect(s.status).toBe(201);
    for (let n = 1; n <= s.body.parts; n++) {
      if (skip.includes(n)) continue;
      const part = bytes.subarray((n - 1) * PART_SIZE, n * PART_SIZE);
      const r = await api()
        .put(`/attachments/${s.body.attachmentId}/parts?part=${n}`)
        .set(d.h)
        .set('content-type', 'application/octet-stream')
        .send(part);
      expect([n, r.status]).toEqual([n, 204]);
    }
    if (finish) {
      const c = await api()
        .post(`/attachments/${s.body.attachmentId}/complete`)
        .set(d.h);
      expect(c.status).toBe(200);
    }
    return s.body;
  };

  const send = (from, to, attachmentIds) =>
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
        attachmentIds,
      });

  const download = (d, id) =>
    api()
      .get(`/attachments/${id}`)
      .set(d.h)
      .buffer(true)
      .parse((res, cb) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => cb(null, Buffer.concat(chunks)));
      });

  beforeAll(async () => {
    db = await createTestDatabase('media');
    audit = new AuditService({ query: (q, p) => db.client.query(q, p) });
    pepper = Buffer.from(configuration().auth.tokenPepper, 'utf8');
    issuer = await mkUser(db.client, 'issuer', { role: 'admin' });
    t = await createTestApp({ db, realAuth: true });
  }, 90000);

  afterAll(async () => {
    await t.close();
    await db.drop();
  });

  it('uploads in 8 MB parts, is claimed by a message, and downloads byte for byte', async () => {
    const { from, to } = await people('m1');
    const bytes = crypto.randomBytes(2 * PART_SIZE + 12345);
    const up = await upload(from, bytes);
    expect(up.parts).toBe(3);

    // Nobody but the uploader can fetch it before a message carries it.
    expect((await download(to, up.attachmentId)).status).toBe(404);

    expect((await send(from, to, [up.attachmentId])).status).toBe(201);
    const got = await download(to, up.attachmentId);
    expect(got.status).toBe(200);
    expect(Buffer.compare(got.body, bytes)).toBe(0);
    expect(got.headers['cache-control']).toBe('no-store');

    // A resumed download: a byte range.
    const part = await api()
      .get(`/attachments/${up.attachmentId}`)
      .set(to.h)
      .set('range', `bytes=${PART_SIZE}-${PART_SIZE + 99}`)
      .buffer(true)
      .parse((res, cb) => {
        const c = [];
        res.on('data', (x) => c.push(x));
        res.on('end', () => cb(null, Buffer.concat(c)));
      });
    expect(part.status).toBe(206);
    expect(
      Buffer.compare(part.body, bytes.subarray(PART_SIZE, PART_SIZE + 100)),
    ).toBe(0);
  }, 60000);

  it('resumes an interrupted upload and refuses to complete an incomplete one', async () => {
    const { from } = await people('m2');
    const bytes = crypto.randomBytes(PART_SIZE + 500);
    const up = await upload(from, bytes, { finish: false, skip: [2] });
    const prog = await api()
      .get(`/attachments/${up.attachmentId}/upload`)
      .set(from.h);
    expect(prog.body).toMatchObject({ parts: 2, done: [1] });
    expect(
      (await api().post(`/attachments/${up.attachmentId}/complete`).set(from.h))
        .status,
    ).toBe(409);

    const last = bytes.subarray(PART_SIZE);
    const wrongSize = await api()
      .put(`/attachments/${up.attachmentId}/parts?part=2`)
      .set(from.h)
      .set('content-type', 'application/octet-stream')
      .send(last.subarray(1));
    expect(wrongSize.status).toBe(400);
    const outOfRange = await api()
      .put(`/attachments/${up.attachmentId}/parts?part=3`)
      .set(from.h)
      .set('content-type', 'application/octet-stream')
      .send(last);
    expect(outOfRange.status).toBe(400);

    await api()
      .put(`/attachments/${up.attachmentId}/parts?part=2`)
      .set(from.h)
      .set('content-type', 'application/octet-stream')
      .send(last);
    expect(
      (await api().post(`/attachments/${up.attachmentId}/complete`).set(from.h))
        .status,
    ).toBe(200);
  }, 60000);

  it('is a 404 to strangers, for uploads and downloads alike, and after a link is revoked', async () => {
    const { from, to, linkId } = await people('m3');
    const stranger = await people('m3x');
    const inProgress = await upload(from, crypto.randomBytes(1000), {
      finish: false,
    });
    expect(
      (
        await api()
          .get(`/attachments/${inProgress.attachmentId}/upload`)
          .set(stranger.from.h)
      ).status,
    ).toBe(404);
    expect(
      (
        await api()
          .post(`/attachments/${inProgress.attachmentId}/complete`)
          .set(stranger.from.h)
      ).status,
    ).toBe(404);
    // Not even the uploader can download a file that is not finished.
    expect((await download(from, inProgress.attachmentId)).status).toBe(404);

    const done = await upload(from, crypto.randomBytes(1000));
    await send(from, to, [done.attachmentId]);
    expect((await download(stranger.from, done.attachmentId)).status).toBe(404);
    expect((await download(to, done.attachmentId)).status).toBe(200);
    await db.client.query(
      'UPDATE contact_links SET revoked_at = now(), revoked_by = $2 WHERE id = $1',
      [linkId, issuer.id],
    );
    expect((await download(to, done.attachmentId)).status).toBe(404);
    expect((await download(from, done.attachmentId)).status).toBe(200); // still the uploader's
  }, 60000);

  it('a message can carry only your own, finished, unclaimed files', async () => {
    const { from, to } = await people('m4');
    const other = await people('m4x');
    const theirs = await upload(other.from, crypto.randomBytes(500));
    expect((await send(from, to, [theirs.attachmentId])).status).toBe(400);

    const unfinished = await upload(from, crypto.randomBytes(500), {
      finish: false,
    });
    expect((await send(from, to, [unfinished.attachmentId])).status).toBe(400);

    const mine = await upload(from, crypto.randomBytes(500));
    expect((await send(from, to, [mine.attachmentId])).status).toBe(201);
    expect((await send(from, to, [mine.attachmentId])).status).toBe(400);
  }, 60000);

  it('deletes every file after 30 days: the blob is gone and the download is a 404', async () => {
    const { from, to } = await people('m5');
    const up = await upload(from, crypto.randomBytes(3000));
    await send(from, to, [up.attachmentId]);
    const left = await upload(from, crypto.randomBytes(3000), {
      finish: false,
    });
    await db.client.query(
      `UPDATE attachments SET expires_at = now() - interval '1 second' WHERE id = ANY($1::uuid[])`,
      [[up.attachmentId, left.attachmentId]],
    );
    // Expired is gone at once, even before the sweep gets to it.
    expect((await download(to, up.attachmentId)).status).toBe(404);
    const media = t.app.get(MediaService);
    expect(await media.sweep()).toBeGreaterThanOrEqual(2);
    expect((await download(to, up.attachmentId)).status).toBe(404);
    const { rows } = await db.client.query(
      'SELECT status, deleted_at FROM attachments WHERE id = ANY($1::uuid[]) ORDER BY id',
      [[up.attachmentId, left.attachmentId]],
    );
    expect(rows.every((r) => r.status === 'deleted' && r.deleted_at)).toBe(
      true,
    );
    // The object itself is gone from the store.
    const storage = t.app.get(MediaService).storage;
    const key = (
      await db.client.query(
        'SELECT storage_key FROM attachments WHERE id = $1',
        [up.attachmentId],
      )
    ).rows[0].storage_key;
    await expect(storage.read(key)).rejects.toBeDefined();
  }, 60000);

  it('rejects nonsense sizes and hashes', async () => {
    const { from } = await people('m6');
    const sha256 = b64(crypto.randomBytes(32));
    expect(
      (
        await api()
          .post('/attachments')
          .set(from.h)
          .send({ ciphertextBytes: 5, sha256 })
      ).status,
    ).toBe(400);
    expect(
      (
        await api()
          .post('/attachments')
          .set(from.h)
          .send({ ciphertextBytes: 3 * 1024 ** 3, sha256 })
      ).status,
    ).toBe(400);
    expect(
      (
        await api()
          .post('/attachments')
          .set(from.h)
          .send({ ciphertextBytes: 100, sha256: 'short' })
      ).status,
    ).toBe(400);
  });
});
