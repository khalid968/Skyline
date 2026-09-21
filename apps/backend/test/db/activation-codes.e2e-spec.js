// Activation codes are strictly single use. The database enforces it, not the
// service layer, because service code forgets. See docs/architecture/decisions.md.
import {
  createTestDatabase,
  mkUser,
  mkDevice,
  mkCode,
  hashOf,
  next,
  failure,
  SQLSTATE,
} from './harness';

describe('activation codes (database layer)', () => {
  let db;
  let admin;

  beforeAll(async () => {
    db = await createTestDatabase('codes');
    admin = await mkUser(db.client, 'admin', { role: 'admin' });
  }, 60000);

  afterAll(async () => {
    await db.drop();
  });

  const redeem = async (hash, deviceId, client = db.client) =>
    (await client.query('SELECT redeem_activation_code($1, $2) AS user_id', [hash, deviceId])).rows[0]
      .user_id;

  describe('redeem_activation_code()', () => {
    it('returns the owning user on first use', async () => {
      const user = await mkUser(db.client, 'invitee', { status: 'pending' });
      const device = await mkDevice(db.client, user.id);
      const code = await mkCode(db.client, user.id, admin.id);

      expect(await redeem(code.hash, device)).toBe(user.id);
    });

    it('returns NULL the second time -- a spent code is dead', async () => {
      const user = await mkUser(db.client, 'invitee');
      const first = await mkDevice(db.client, user.id);
      const second = await mkDevice(db.client, user.id);
      const code = await mkCode(db.client, user.id, admin.id);

      expect(await redeem(code.hash, first)).toBe(user.id);
      expect(await redeem(code.hash, second)).toBeNull();
    });

    it('records exactly which device spent it, and it stays that device', async () => {
      const user = await mkUser(db.client, 'invitee');
      const first = await mkDevice(db.client, user.id);
      const second = await mkDevice(db.client, user.id);
      const code = await mkCode(db.client, user.id, admin.id);

      await redeem(code.hash, first);
      await redeem(code.hash, second);

      const { rows } = await db.client.query(
        'SELECT redeemed_by_device_id, redeemed_at FROM activation_codes WHERE id = $1',
        [code.id],
      );
      expect(rows[0].redeemed_by_device_id).toBe(first);
      expect(rows[0].redeemed_at).not.toBeNull();
    });

    it('returns NULL for a code that was never issued', async () => {
      const user = await mkUser(db.client, 'bystander');
      const device = await mkDevice(db.client, user.id);
      expect(await redeem(hashOf(next() + 9000), device)).toBeNull();
    });

    it('returns NULL for an expired code', async () => {
      const user = await mkUser(db.client, 'late');
      const device = await mkDevice(db.client, user.id);
      const code = await mkCode(db.client, user.id, admin.id, {
        createdSql: `now() - interval '5 days'`,
        expiresSql: `now() - interval '2 days'`,
      });

      expect(await redeem(code.hash, device)).toBeNull();
    });

    it('returns NULL for a revoked code', async () => {
      const user = await mkUser(db.client, 'revoked');
      const device = await mkDevice(db.client, user.id);
      const code = await mkCode(db.client, user.id, admin.id);
      await db.client.query(
        `UPDATE activation_codes SET revoked_at = now(), revoked_by = $2 WHERE id = $1`,
        [code.id, admin.id],
      );

      expect(await redeem(code.hash, device)).toBeNull();
    });

    it('gives spent, expired, revoked and unknown codes the same answer, so callers cannot tell them apart', async () => {
      const user = await mkUser(db.client, 'uniform');
      const device = await mkDevice(db.client, user.id);

      const spent = await mkCode(db.client, user.id, admin.id);
      await redeem(spent.hash, device);

      const u2 = await mkUser(db.client, 'uniform');
      const expired = await mkCode(db.client, u2.id, admin.id, {
        createdSql: `now() - interval '5 days'`,
        expiresSql: `now() - interval '2 days'`,
      });

      const u3 = await mkUser(db.client, 'uniform');
      const revoked = await mkCode(db.client, u3.id, admin.id);
      await db.client.query(`UPDATE activation_codes SET revoked_at = now() WHERE id = $1`, [
        revoked.id,
      ]);

      const answers = [
        await redeem(spent.hash, device),
        await redeem(expired.hash, device),
        await redeem(revoked.hash, device),
        await redeem(hashOf(next() + 12345), device),
      ];
      expect(answers).toEqual([null, null, null, null]);
    });
  });

  describe('concurrency', () => {
    it('lets exactly ONE of many simultaneous redemptions win', async () => {
      const RACERS = 25;
      const user = await mkUser(db.client, 'raced');
      const code = await mkCode(db.client, user.id, admin.id);

      // A separate connection and a separate device per racer, so the attempts
      // genuinely overlap on the server rather than queueing on one socket.
      const racers = [];
      for (let i = 0; i < RACERS; i++) {
        racers.push({
          client: await db.connect(),
          device: await mkDevice(db.client, user.id),
        });
      }

      try {
        const results = await Promise.all(racers.map((r) => redeem(code.hash, r.device, r.client)));

        const winners = results.filter((r) => r !== null);
        expect(winners).toHaveLength(1);
        expect(winners[0]).toBe(user.id);

        const { rows } = await db.client.query(
          'SELECT redeemed_by_device_id FROM activation_codes WHERE id = $1',
          [code.id],
        );
        const winningDevices = racers.filter((r) => r.device === rows[0].redeemed_by_device_id);
        expect(winningDevices).toHaveLength(1);
      } finally {
        await Promise.all(racers.map((r) => r.client.end()));
      }
    }, 60000);
  });

  describe('a spent code is frozen', () => {
    const spendOne = async () => {
      const user = await mkUser(db.client, 'frozen');
      const device = await mkDevice(db.client, user.id);
      const code = await mkCode(db.client, user.id, admin.id);
      await redeem(code.hash, device);
      return { user, device, code };
    };

    it('cannot be un-redeemed', async () => {
      const { code } = await spendOne();
      const err = await failure(
        db.client.query(
          `UPDATE activation_codes SET redeemed_at = NULL, redeemed_by_device_id = NULL WHERE id = $1`,
          [code.id],
        ),
      );
      // The freeze trigger fires first; either it or the pairing CHECK stops it.
      expect([SQLSTATE.integrity, SQLSTATE.check]).toContain(err.code);
    });

    it('cannot be repointed at a different device', async () => {
      const { user, code } = await spendOne();
      const other = await mkDevice(db.client, user.id);

      const err = await failure(
        db.client.query(`UPDATE activation_codes SET redeemed_by_device_id = $2 WHERE id = $1`, [
          code.id,
          other,
        ]),
      );
      expect(err.code).toBe(SQLSTATE.integrity);
      expect(err.message).toMatch(/already spent/);
    });

    it('cannot have its hash rewritten to make it look like a different code', async () => {
      const { code } = await spendOne();
      const err = await failure(
        db.client.query(`UPDATE activation_codes SET code_hash = $2 WHERE id = $1`, [
          code.id,
          hashOf(next() + 777),
        ]),
      );
      expect(err.code).toBe(SQLSTATE.integrity);
    });

    it('cannot be reassigned to a different user', async () => {
      const { code } = await spendOne();
      const stranger = await mkUser(db.client, 'stranger');
      const err = await failure(
        db.client.query(`UPDATE activation_codes SET user_id = $2 WHERE id = $1`, [
          code.id,
          stranger.id,
        ]),
      );
      expect(err.code).toBe(SQLSTATE.integrity);
    });

    it('cannot be both spent and revoked', async () => {
      const { code } = await spendOne();
      const err = await failure(
        db.client.query(`UPDATE activation_codes SET revoked_at = now() WHERE id = $1`, [code.id]),
      );
      expect(err.code).toBe(SQLSTATE.check);
      expect(err.constraint).toBe('activation_codes_not_both_spent_and_revoked');
    });
  });

  describe('issuing', () => {
    it('allows only one live code per user', async () => {
      const user = await mkUser(db.client, 'one');
      await mkCode(db.client, user.id, admin.id);

      const err = await failure(mkCode(db.client, user.id, admin.id));
      expect(err.code).toBe(SQLSTATE.unique);
      expect(err.constraint).toBe('activation_codes_one_live_per_user');
    });

    it('allows a replacement once the old code is revoked, and does not revive the old one', async () => {
      const user = await mkUser(db.client, 'replaced');
      const device = await mkDevice(db.client, user.id);
      const old = await mkCode(db.client, user.id, admin.id);
      await db.client.query(`UPDATE activation_codes SET revoked_at = now() WHERE id = $1`, [old.id]);

      const fresh = await mkCode(db.client, user.id, admin.id);

      expect(await redeem(old.hash, device)).toBeNull();
      expect(await redeem(fresh.hash, device)).toBe(user.id);
    });

    it('allows a replacement once the old code has been spent (a second device later)', async () => {
      const user = await mkUser(db.client, 'twice');
      const d1 = await mkDevice(db.client, user.id);
      const d2 = await mkDevice(db.client, user.id);
      const first = await mkCode(db.client, user.id, admin.id);
      await redeem(first.hash, d1);

      const second = await mkCode(db.client, user.id, admin.id);

      expect(await redeem(second.hash, d2)).toBe(user.id);
      expect(await redeem(first.hash, d2)).toBeNull();
    });

    it('rejects a hash that is not 32 bytes, so a raw code cannot be stored by mistake', async () => {
      const user = await mkUser(db.client, 'raw');
      const err = await failure(
        db.client.query(
          `INSERT INTO activation_codes (user_id, code_hash, issued_by) VALUES ($1, $2, $3)`,
          [user.id, Buffer.from('SKY-4F2A-99XD-7C1B'), admin.id],
        ),
      );
      expect(err.code).toBe(SQLSTATE.check);
      expect(err.constraint).toBe('activation_codes_hash_len');
    });

    it('never stores a duplicate hash', async () => {
      const a = await mkUser(db.client, 'dupa');
      const b = await mkUser(db.client, 'dupb');
      const hash = hashOf(next() + 4242);
      await mkCode(db.client, a.id, admin.id, { hash });

      const err = await failure(mkCode(db.client, b.id, admin.id, { hash }));
      expect(err.code).toBe(SQLSTATE.unique);
    });
  });
});
