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
import {
  MediaService,
  PART_SIZE,
  MIN_FREE_DISK_BYTES,
} from '../../src/modules/media/media.service';
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

  // Storage limits (owner decision 2026-10-31, security audit lead 7).
  describe('storage limits', () => {
    const GB = 1024 ** 3;
    const start = (d, ciphertextBytes) =>
      api()
        .post('/attachments')
        .set(d.h)
        .send({ ciphertextBytes, sha256: b64(crypto.randomBytes(32)) });

    it('one person may start 5 GB of uploads a day, on all their devices together', async () => {
      const { from, to } = await people('q1');
      expect((await start(from, 2 * GB)).status).toBe(201);
      expect((await start(from, 2 * GB)).status).toBe(201);
      const over = await start(from, 2 * GB);
      expect(over.status).toBe(429);
      const wait = Number(over.headers['retry-after']);
      expect(wait).toBeGreaterThan(23 * 3600);
      expect(wait).toBeLessThanOrEqual(24 * 3600);
      // What still fits, fits; a second device of the same person shares it.
      expect((await start(from, 900 * 1024 ** 2)).status).toBe(201);
      const second = await device(from.userId);
      expect((await start(second, 200 * 1024 ** 2)).status).toBe(429);
      // Someone else is not affected.
      expect((await start(to, 2 * GB)).status).toBe(201);
      // A day later the allowance is back, and the idle uploads are swept.
      await db.client.query(
        `UPDATE attachments a SET created_at = now() - interval '25 hours'
           FROM devices d WHERE d.id = a.uploaded_by_device_id AND d.user_id = ANY($1::uuid[])`,
        [[from.userId, to.userId]],
      );
      expect((await start(from, 2 * GB)).status).toBe(201);
      expect(await t.app.get(MediaService).sweep()).toBeGreaterThanOrEqual(4);
    }, 60000);

    it('no upload starts that would leave the disk below 6 GB free', async () => {
      const { from } = await people('q2');
      const media = t.app.get(MediaService);
      const real = media.freeDiskBytes;
      // Uploads still in progress count as if written: 1 GB to spare
      // beyond them and the floor.
      const pending = Number(
        (
          await db.client.query(
            `SELECT coalesce(sum(a.ciphertext_bytes - coalesce((SELECT sum(bytes) FROM attachment_parts p
                                                                 WHERE p.attachment_id = a.id), 0)), 0) AS n
               FROM attachments a WHERE a.status = 'uploading'`,
          )
        ).rows[0].n,
      );
      media.freeDiskBytes = async () => MIN_FREE_DISK_BYTES + pending + GB;
      try {
        expect((await start(from, 2 * GB)).status).toBe(507);
        expect((await start(from, 1024 ** 2)).status).toBe(201);
        // That 1 MB now counts too: 1 GB no longer fits.
        expect((await start(from, GB)).status).toBe(507);
        // Unreadable free space: the daily allowance still applies.
        media.freeDiskBytes = async () => null;
        expect((await start(from, 2 * GB)).status).toBe(201);
      } finally {
        media.freeDiskBytes = real;
      }
    }, 60000);

    it('an upload idle for 24 hours is removed; one still moving is kept', async () => {
      const { from } = await people('q3');
      const idle = await upload(from, crypto.randomBytes(PART_SIZE + 10), {
        finish: false,
        skip: [2],
      });
      const moving = await upload(from, crypto.randomBytes(PART_SIZE + 10), {
        finish: false,
        skip: [2],
      });
      const ids = [idle.attachmentId, moving.attachmentId];
      await db.client.query(
        `UPDATE attachments SET created_at = now() - interval '25 hours' WHERE id = ANY($1::uuid[])`,
        [ids],
      );
      await db.client.query(
        `UPDATE attachment_parts SET uploaded_at = now() - interval '25 hours' WHERE attachment_id = $1`,
        [idle.attachmentId],
      );
      await t.app.get(MediaService).sweep();
      const { rows } = await db.client.query(
        'SELECT id, status FROM attachments WHERE id = ANY($1::uuid[])',
        [ids],
      );
      const status = Object.fromEntries(rows.map((r) => [r.id, r.status]));
      expect(status[idle.attachmentId]).toBe('deleted');
      expect(status[moving.attachmentId]).toBe('uploading');
    }, 60000);
  });

  // Phase 14d (board 46): profile photos.
  describe('profile photos', () => {
    const contactsOf = async (d) => (await api().get('/me/contacts').set(d.h)).body;

    it('a contact sees and downloads your photo; nobody else can', async () => {
      const { from, to } = await people('pp1');
      const stranger = await device((await mkUser(db.client, 'pp1c', { status: 'pending' })).id);
      const bytes = crypto.randomBytes(40 * 1024);
      const up = await upload(from, bytes);
      expect((await api().put('/me/photo').set(from.h).send({ attachmentId: up.attachmentId })).status).toBe(204);

      const seen = (await contactsOf(to)).find((c) => c.userId === from.userId);
      expect(seen.photo).toBe(up.attachmentId);
      const got = await download(to, up.attachmentId);
      expect(got.status).toBe(200);
      expect(Buffer.compare(got.body, bytes)).toBe(0);
      expect((await download(stranger, up.attachmentId)).status).toBe(404);
    });

    it('a photo is never sent in a message, and a sent file never becomes a photo', async () => {
      const { from, to } = await people('pp2');
      const photo = await upload(from, crypto.randomBytes(1024));
      await api().put('/me/photo').set(from.h).send({ attachmentId: photo.attachmentId });
      expect((await send(from, to, [photo.attachmentId])).status).toBe(400);

      const file = await upload(from, crypto.randomBytes(1024));
      expect((await send(from, to, [file.attachmentId])).status).toBe(201);
      expect((await api().put('/me/photo').set(from.h).send({ attachmentId: file.attachmentId })).status).toBe(404);
      // Someone else's upload: the same 404.
      const theirs = await upload(to, crypto.randomBytes(1024));
      expect((await api().put('/me/photo').set(from.h).send({ attachmentId: theirs.attachmentId })).status).toBe(404);
    });

    it('replacing or removing a photo takes the old one away at once', async () => {
      const { from, to } = await people('pp3');
      const first = await upload(from, crypto.randomBytes(2048));
      await api().put('/me/photo').set(from.h).send({ attachmentId: first.attachmentId });
      const second = await upload(from, crypto.randomBytes(2048));
      await api().put('/me/photo').set(from.h).send({ attachmentId: second.attachmentId });
      expect((await download(to, first.attachmentId)).status).toBe(404);
      expect((await download(to, second.attachmentId)).status).toBe(200);

      expect((await api().delete('/me/photo').set(from.h)).status).toBe(204);
      expect((await contactsOf(to)).find((c) => c.userId === from.userId).photo).toBeNull();
      expect((await download(to, second.attachmentId)).status).toBe(404);
    });

    it('two photo changes at once keep exactly one photo, and the sweep deletes orphans (security audit 2026-10-30)', async () => {
      const { from } = await people('pp4');
      const kept = async () =>
        (
          await db.client.query(
            `SELECT a.id FROM attachments a JOIN devices d ON d.id = a.uploaded_by_device_id
              WHERE d.user_id = $1 AND a.kind = 'profile' AND a.expires_at = 'infinity' AND a.status <> 'deleted'`,
            [from.userId],
          )
        ).rows.map((r) => r.id);
      for (let round = 0; round < 6; round++) {
        const x = await upload(from, crypto.randomBytes(512));
        const y = await upload(from, crypto.randomBytes(512));
        const rs = await Promise.all(
          [x, y].map((u) => api().put('/me/photo').set(from.h).send({ attachmentId: u.attachmentId })),
        );
        for (const r of rs) expect(r.status).toBe(204);
        expect(await kept()).toHaveLength(1);
      }
      const current = (await db.client.query('SELECT photo_attachment_id AS p FROM users WHERE id = $1', [from.userId])).rows[0].p;
      expect(await kept()).toEqual([current]);

      // An orphan left behind by older code is swept even though it never expires.
      const orphan = await upload(from, crypto.randomBytes(512));
      await db.client.query(`UPDATE attachments SET kind = 'profile', expires_at = 'infinity' WHERE id = $1`, [orphan.attachmentId]);
      await t.app.get(MediaService).sweep();
      const status = async (id) => (await db.client.query('SELECT status FROM attachments WHERE id = $1', [id])).rows[0].status;
      expect(await status(orphan.attachmentId)).toBe('deleted');
      expect(await status(current)).toBe('ready');
    });
  });
});
