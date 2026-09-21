// Usernames are never reissued, accounts are never hard-deleted, and the audit
// log is append-only. See docs/architecture/decisions.md.
import { createTestDatabase, mkUser, failure, SQLSTATE } from './harness';

describe('identity and audit (database layer)', () => {
  let db;

  beforeAll(async () => {
    db = await createTestDatabase('identity');
  }, 60000);

  afterAll(async () => {
    await db.drop();
  });

  const rename = (id, username) =>
    db.client.query('UPDATE users SET username = $2 WHERE id = $1', [id, username]);
  const history = async (userId) =>
    (
      await db.client.query(
        'SELECT username::text, released_at FROM username_history WHERE user_id = $1 ORDER BY assigned_at, username',
        [userId],
      )
    ).rows;

  describe('usernames', () => {
    it('records a history row when an account is created', async () => {
      const u = await mkUser(db.client, 'fresh');
      const rows = await history(u.id);
      expect(rows).toHaveLength(1);
      expect(rows[0].username).toBe(u.username);
      expect(rows[0].released_at).toBeNull();
    });

    it('releases the old name and records the new one on rename', async () => {
      const u = await mkUser(db.client, 'renamed');
      await rename(u.id, `${u.username}new`);

      const rows = await history(u.id);
      expect(rows).toHaveLength(2);
      const old = rows.find((r) => r.username === u.username);
      const current = rows.find((r) => r.username === `${u.username}new`);
      expect(old.released_at).not.toBeNull();
      expect(current.released_at).toBeNull();
    });

    it('does not add history when the username is left unchanged', async () => {
      const u = await mkUser(db.client, 'same');
      await db.client.query(`UPDATE users SET display_name = 'Someone Else' WHERE id = $1`, [u.id]);
      await rename(u.id, u.username);
      expect(await history(u.id)).toHaveLength(1);
    });

    it('NEVER lets a released username be taken by a different account', async () => {
      const original = await mkUser(db.client, 'burn');
      const burned = original.username;
      await rename(original.id, `${burned}moved`);

      // The old name is free in `users` -- only the history keeps it burned.
      const free = await db.client.query('SELECT 1 FROM users WHERE username = $1', [burned]);
      expect(free.rowCount).toBe(0);

      const err = await failure(
        db.client.query(
          `INSERT INTO users (username, display_name, role_key) VALUES ($1, 'Squatter', 'member')`,
          [burned],
        ),
      );
      expect(err.code).toBe(SQLSTATE.unique);
      expect(err.constraint).toBe('username_history_username_key');
    });

    it('blocks renaming a second account onto a released name', async () => {
      const first = await mkUser(db.client, 'first');
      const second = await mkUser(db.client, 'second');
      const burned = first.username;
      await rename(first.id, `${burned}gone`);

      const err = await failure(rename(second.id, burned));
      expect(err.code).toBe(SQLSTATE.unique);

      // The failed rename must leave the second account untouched.
      const { rows } = await db.client.query('SELECT username::text FROM users WHERE id = $1', [
        second.id,
      ]);
      expect(rows[0].username).toBe(second.username);
      expect((await history(second.id)).filter((r) => r.released_at === null)).toHaveLength(1);
    });

    it('treats usernames case-insensitively', async () => {
      const u = await mkUser(db.client, 'casey');
      const err = await failure(
        db.client.query(
          `INSERT INTO users (username, display_name, role_key) VALUES ($1, 'Impostor', 'member')`,
          [u.username.toUpperCase()],
        ),
      );
      expect(err.code).toBe(SQLSTATE.unique);
    });

    it.each([
      ['too short', 'ab'],
      ['contains a space', 'has space'],
      ['starts with a symbol', '-lead1'],
      ['ends with a symbol', 'trail1.'],
      ['contains an @', 'a@b.cd'],
    ])('rejects a malformed username: %s', async (_label, bad) => {
      const err = await failure(
        db.client.query(
          `INSERT INTO users (username, display_name, role_key) VALUES ($1, 'X', 'member')`,
          [bad],
        ),
      );
      expect(err.code).toBe(SQLSTATE.check);
      expect(err.constraint).toBe('users_username_format');
    });
  });

  describe('accounts are never hard-deleted', () => {
    it('refuses DELETE FROM users, because the username history restricts it', async () => {
      const u = await mkUser(db.client, 'keep');
      const err = await failure(db.client.query('DELETE FROM users WHERE id = $1', [u.id]));
      expect([SQLSTATE.restrict, SQLSTATE.foreignKey]).toContain(err.code);

      const still = await db.client.query('SELECT 1 FROM users WHERE id = $1', [u.id]);
      expect(still.rowCount).toBe(1);
    });

    it('soft-deletes via status, and only with a deleted_at stamp', async () => {
      const u = await mkUser(db.client, 'soft');

      const err = await failure(
        db.client.query(`UPDATE users SET status = 'deleted' WHERE id = $1`, [u.id]),
      );
      expect(err.code).toBe(SQLSTATE.check);
      expect(err.constraint).toBe('users_deleted_stamp');

      await db.client.query(`UPDATE users SET status = 'deleted', deleted_at = now() WHERE id = $1`, [
        u.id,
      ]);
      const { rows } = await db.client.query('SELECT status FROM users WHERE id = $1', [u.id]);
      expect(rows[0].status).toBe('deleted');
    });

    it('rejects an unknown role', async () => {
      const err = await failure(
        db.client.query(
          `INSERT INTO users (username, display_name, role_key) VALUES ('nobody1', 'N', 'superuser')`,
        ),
      );
      expect(err.code).toBe(SQLSTATE.foreignKey);
    });
  });

  describe('audit_log is append-only', () => {
    const record = (action = 'users.rename') =>
      db.client.query(
        `INSERT INTO audit_log (action, actor_username, target_username, detail)
         VALUES ($1, 'amina', 'sarah', '{"from":"sara","to":"sarah"}') RETURNING id`,
        [action],
      );

    it('accepts new entries', async () => {
      const { rows } = await record();
      expect(rows[0].id).toBeDefined();
    });

    it('refuses UPDATE', async () => {
      await record();
      const err = await failure(db.client.query(`UPDATE audit_log SET actor_username = 'someone else'`));
      expect(err.code).toBe(SQLSTATE.insufficientPrivilege);
      expect(err.message).toMatch(/append-only/);
    });

    it('refuses DELETE', async () => {
      await record();
      const err = await failure(db.client.query('DELETE FROM audit_log'));
      expect(err.code).toBe(SQLSTATE.insufficientPrivilege);
    });

    it('refuses TRUNCATE -- the statement most likely to be forgotten', async () => {
      await record();
      const err = await failure(db.client.query('TRUNCATE audit_log'));
      expect(err.code).toBe(SQLSTATE.insufficientPrivilege);

      const { rows } = await db.client.query('SELECT count(*)::int AS n FROM audit_log');
      expect(rows[0].n).toBeGreaterThan(0);
    });

    it('rejects a malformed action name', async () => {
      const err = await failure(record('Not An Action'));
      expect(err.code).toBe(SQLSTATE.check);
    });

    it('carries no foreign keys, so an entry can outlive the rows it describes', async () => {
      const { rows } = await db.client.query(
        `SELECT count(*)::int AS n FROM pg_constraint WHERE conrelid = 'audit_log'::regclass AND contype = 'f'`,
      );
      expect(rows[0].n).toBe(0);
    });
  });
});
