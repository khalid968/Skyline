// Phase 7: the key directory (migration 011). A device's Signal identity is
// fixed for life, published prekeys are facts that cannot be edited or
// removed, and a one-time key can be handed out only once.
import crypto from 'crypto';
import {
  createTestDatabase,
  mkUser,
  mkDevice,
  signalPublicKey,
  failure,
  SQLSTATE,
} from './harness';

const sig = () => crypto.randomBytes(64);
const kyberKey = () =>
  Buffer.concat([Buffer.from([8]), crypto.randomBytes(1568)]);

describe('key directory (database layer)', () => {
  let db;

  beforeAll(async () => {
    db = await createTestDatabase('keys');
  }, 60000);

  afterAll(async () => {
    await db.drop();
  });

  const q = (text, params) => db.client.query(text, params);
  const device = async (name = 'keyed') =>
    mkDevice(db.client, (await mkUser(db.client, name)).id);
  const addOneTime = (deviceId, keyId, publicKey = signalPublicKey()) =>
    q(
      `INSERT INTO one_time_prekeys (device_id, key_id, public_key) VALUES ($1, $2, $3) RETURNING id`,
      [deviceId, keyId, publicKey],
    );
  const addKyber = (deviceId, keyId, lastResort = false) =>
    q(
      `INSERT INTO kyber_prekeys (device_id, key_id, public_key, signature, last_resort)
       VALUES ($1, $2, $3, $4, $5) RETURNING id`,
      [deviceId, keyId, kyberKey(), sig(), lastResort],
    );
  const addSigned = (deviceId, keyId) =>
    q(
      `INSERT INTO signed_prekeys (device_id, key_id, public_key, signature)
       VALUES ($1, $2, $3, $4) RETURNING id`,
      [deviceId, keyId, signalPublicKey(), sig()],
    );

  describe('device identity', () => {
    it('can never change once set: a new identity is a new device', async () => {
      const d = await device();
      const err = await failure(
        q('UPDATE devices SET identity_key = $2 WHERE id = $1', [
          d,
          signalPublicKey(),
        ]),
      );
      expect(err.code).toBe(SQLSTATE.check);
      expect(err.message).toMatch(/identity key can never change/);
    });

    it('keeps its registration id and device number for life', async () => {
      const d = await device();
      await q('UPDATE devices SET device_number = 1 WHERE id = $1', [d]);
      for (const sql of [
        'UPDATE devices SET registration_id = registration_id + 1 WHERE id = $1',
        'UPDATE devices SET device_number = 2 WHERE id = $1',
      ]) {
        expect((await failure(q(sql, [d]))).code).toBe(SQLSTATE.check);
      }
    });

    it('never gives two live devices the same identity key (a clone)', async () => {
      const u = await mkUser(db.client, 'cloned');
      const key = signalPublicKey();
      const ins = () =>
        q(
          `INSERT INTO devices (user_id, name, platform, identity_key, signing_key)
           VALUES ($1, 'x', 'ios', $2, $3)`,
          [u.id, key, crypto.randomBytes(32)],
        );
      await ins();
      const err = await failure(ins());
      expect(err.constraint).toBe('devices_live_identity_key');
    });

    it('never reuses a device number for the same person, even after revocation', async () => {
      const u = await mkUser(db.client, 'numbered');
      const d = await mkDevice(db.client, u.id);
      await q(
        'UPDATE devices SET device_number = 1, revoked_at = now() WHERE id = $1',
        [d],
      );
      const d2 = await mkDevice(db.client, u.id);
      const err = await failure(
        q('UPDATE devices SET device_number = 1 WHERE id = $1', [d2]),
      );
      expect(err.constraint).toBe('devices_user_device_number');
    });

    it('limits device numbers to what libsignal accepts (1..127)', async () => {
      const d = await device();
      const err = await failure(
        q('UPDATE devices SET device_number = 128 WHERE id = $1', [d]),
      );
      expect(err.constraint).toBe('devices_device_number_range');
    });
  });

  describe('published prekeys', () => {
    it('accept only well-formed public keys and 64-byte signatures', async () => {
      const d = await device();
      const bad = [
        [
          `INSERT INTO one_time_prekeys (device_id, key_id, public_key) VALUES ($1, 1, $2)`,
          [d, Buffer.alloc(32, 1)],
          'one_time_prekeys_public_key',
        ],
        [
          `INSERT INTO signed_prekeys (device_id, key_id, public_key, signature) VALUES ($1, 1, $2, $3)`,
          [d, signalPublicKey(), Buffer.alloc(63)],
          'signed_prekeys_signature',
        ],
        [
          `INSERT INTO kyber_prekeys (device_id, key_id, public_key, signature, last_resort)
           VALUES ($1, 1, $2, $3, false)`,
          [d, Buffer.alloc(33, 5), sig()],
          'kyber_prekeys_public_key',
        ],
        [
          `INSERT INTO one_time_prekeys (device_id, key_id, public_key) VALUES ($1, 16777216, $2)`,
          [d, signalPublicKey()],
          'one_time_prekeys_key_id',
        ],
      ];
      for (const [sql, params, constraint] of bad) {
        expect((await failure(q(sql, params))).constraint).toBe(constraint);
      }
    });

    it('never reuse a key id on the same device', async () => {
      const d = await device();
      await addOneTime(d, 7);
      expect((await failure(addOneTime(d, 7))).constraint).toBe(
        'one_time_prekeys_device_key',
      );
    });

    it('have exactly one current signed prekey and one current last-resort key', async () => {
      const d = await device();
      await addSigned(d, 1);
      expect((await failure(addSigned(d, 2))).constraint).toBe(
        'signed_prekeys_one_current',
      );
      await addKyber(d, 1, true);
      expect((await failure(addKyber(d, 2, true))).constraint).toBe(
        'kyber_prekeys_one_last_resort',
      );
    });

    it('cannot be edited, deleted or truncated', async () => {
      const d = await device();
      const { rows } = await addOneTime(d, 1);
      for (const sql of [
        'UPDATE one_time_prekeys SET public_key = $2 WHERE id = $1',
        'UPDATE one_time_prekeys SET key_id = 99 WHERE id = $1 AND $2::bytea IS NOT NULL',
        'DELETE FROM one_time_prekeys WHERE id = $1 AND $2::bytea IS NOT NULL',
      ]) {
        const err = await failure(q(sql, [rows[0].id, signalPublicKey()]));
        expect(err.code).toBe(SQLSTATE.check);
      }
      for (const table of ['one_time_prekeys', 'kyber_prekeys', 'signed_prekeys']) {
        const err = await failure(q(`TRUNCATE ${table}`));
        expect([table, err.code]).toEqual([table, SQLSTATE.check]);
      }
    });

    it('once claimed, stay claimed by the same device', async () => {
      const d = await device();
      const taker = await device('taker');
      const other = await device('other');
      const { rows } = await addOneTime(d, 1);
      await q(
        'UPDATE one_time_prekeys SET claimed_at = now(), claimed_by = $2 WHERE id = $1',
        [rows[0].id, taker],
      );
      for (const sql of [
        'UPDATE one_time_prekeys SET claimed_at = NULL, claimed_by = NULL WHERE id = $1',
        'UPDATE one_time_prekeys SET claimed_by = $2 WHERE id = $1',
      ]) {
        const params = sql.includes('$2') ? [rows[0].id, other] : [rows[0].id];
        expect((await failure(q(sql, params))).code).toBe(SQLSTATE.check);
      }
    });

    it('never let a last-resort Kyber key be "claimed" (it is shared on purpose)', async () => {
      const d = await device();
      const taker = await device('lrtaker');
      const { rows } = await addKyber(d, 1, true);
      const err = await failure(
        q(
          'UPDATE kyber_prekeys SET claimed_at = now(), claimed_by = $2 WHERE id = $1',
          [rows[0].id, taker],
        ),
      );
      expect(err.constraint).toBe('kyber_prekeys_claim_kind');
    });

    it('a concurrent claim can hand one key to only one caller', async () => {
      const d = await device();
      await addOneTime(d, 1);
      const takers = [await device('t1'), await device('t2')];
      const claimSql = `UPDATE one_time_prekeys SET claimed_at = now(), claimed_by = $2
         WHERE id = (SELECT id FROM one_time_prekeys
                      WHERE device_id = $1 AND claimed_at IS NULL
                      ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED)
         RETURNING key_id`;
      let got;
      const [c1, c2] = [await db.connect(), await db.connect()];
      try {
        // Both transactions are open at once: the second must not see the key
        // the first has claimed but not yet committed.
        await c1.query('BEGIN');
        await c2.query('BEGIN');
        const first = await c1.query(claimSql, [d, takers[0]]);
        const second = await c2.query(claimSql, [d, takers[1]]);
        await c1.query('COMMIT');
        await c2.query('COMMIT');
        got = [first.rows.length, second.rows.length];
      } finally {
        await c1.end();
        await c2.end();
      }
      expect(got).toEqual([1, 0]);
    });
  });
});
