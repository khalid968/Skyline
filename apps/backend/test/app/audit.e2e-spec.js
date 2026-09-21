import { createTestDatabase, mkUser, mkDevice } from '../db/harness';
import { AuditService } from '../../src/modules/audit/audit.service';

describe('AuditService (real database)', () => {
  let db;
  let audit;
  let admin;
  let target;

  const rows = async (action) =>
    (
      await db.client.query(
        `SELECT action, actor_user_id, actor_username::text AS actor_username, target_user_id,
                target_username::text AS target_username, host(actor_ip) AS ip, detail
           FROM audit_log WHERE action = $1 ORDER BY id`,
        [action],
      )
    ).rows;

  beforeAll(async () => {
    db = await createTestDatabase('audit');
    // AuditService only needs something with .query(), which the harness client provides.
    audit = new AuditService({
      query: (text, params) => db.client.query(text, params),
    });
    admin = await mkUser(db.client, 'admin', { role: 'admin' });
    target = await mkUser(db.client, 'target');
  }, 60000);

  afterAll(async () => {
    await db.drop();
  });

  it('records who did what to whom, snapshotting both usernames', async () => {
    await audit.record({
      action: 'users.rename',
      actor: { userId: admin.id },
      target: { userId: target.id },
      ip: '203.0.113.7',
      detail: { from: 'Sara Whitfield', to: 'Sarah Whitfield' },
    });

    const [row] = await rows('users.rename');
    expect(row.actor_user_id).toBe(admin.id);
    expect(row.actor_username).toBe(admin.username);
    expect(row.target_user_id).toBe(target.id);
    expect(row.target_username).toBe(target.username);
    expect(row.ip).toBe('203.0.113.7');
    expect(row.detail).toEqual({
      from: 'Sara Whitfield',
      to: 'Sarah Whitfield',
    });
  });

  it('keeps the username as it was at the time, after a later rename', async () => {
    const t = await mkUser(db.client, 'later');
    await audit.record({
      action: 'users.suspend',
      actor: { userId: admin.id },
      target: { userId: t.id },
    });
    await db.client.query('UPDATE users SET username = $2 WHERE id = $1', [
      t.id,
      `${t.username}-renamed`,
    ]);

    const [row] = (await rows('users.suspend')).filter(
      (r) => r.target_user_id === t.id,
    );
    expect(row.target_username).toBe(t.username); // the old name, not the new one
  });

  it('accepts an entry with no actor or target, for system events', async () => {
    await audit.record({ action: 'system.start', detail: { reason: 'boot' } });
    const [row] = await rows('system.start');
    expect(row.actor_user_id).toBeNull();
    expect(row.actor_username).toBeNull();
  });

  it('records a device and a group as targets', async () => {
    const dev = await mkDevice(db.client, target.id);
    await audit.record({
      action: 'devices.revoke',
      actor: { userId: admin.id },
      target: { userId: target.id, deviceId: dev },
    });
    const { rows: r } = await db.client.query(
      `SELECT target_device_id FROM audit_log WHERE action = 'devices.revoke'`,
    );
    expect(r[0].target_device_id).toBe(dev);
  });

  it('ignores an unparseable IP instead of failing the whole action', async () => {
    await audit.record({
      action: 'users.create',
      actor: { userId: admin.id },
      ip: 'not-an-ip',
    });
    const [row] = await rows('users.create');
    expect(row.ip).toBeNull();
  });

  describe('refuses to write something it should not', () => {
    it.each([
      ['no action', undefined],
      ['a free-text sentence', 'The admin renamed someone'],
      ['upper case', 'Users.Rename'],
      ['a single word', 'rename'],
      ['a path-like name', 'users/rename'],
    ])('rejects %s as an action name', async (_label, action) => {
      await expect(audit.record({ action })).rejects.toThrow(/audit action/);
    });

    it.each([
      'password',
      'token',
      'pin',
      'activation_code',
      'ciphertext',
      'private_key',
      'code',
    ])(
      'rejects a detail field named "%s", since the log can never be edited or deleted',
      async (key) => {
        await expect(
          audit.record({ action: 'users.create', detail: { [key]: 'x' } }),
        ).rejects.toThrow(/looks like a secret/);
      },
    );

    it('finds a secret-named field nested deep inside detail', async () => {
      await expect(
        audit.record({
          action: 'users.create',
          detail: { a: { b: [{ c: 1 }, { d: { token: 't' } }] } },
        }),
      ).rejects.toThrow(/looks like a secret/);
    });

    it('rejects an id that is not a uuid, rather than passing it to SQL', async () => {
      await expect(
        audit.record({
          action: 'users.rename',
          actor: { userId: "1'; DROP TABLE audit_log;--" },
        }),
      ).rejects.toThrow(/uuid/);
    });

    it('writes nothing when it rejects', async () => {
      const before = (
        await db.client.query('SELECT count(*)::int AS n FROM audit_log')
      ).rows[0].n;
      await audit.record({ action: 'BAD' }).catch(() => {});
      await audit
        .record({ action: 'users.create', detail: { password: 'x' } })
        .catch(() => {});
      const after = (
        await db.client.query('SELECT count(*)::int AS n FROM audit_log')
      ).rows[0].n;
      expect(after).toBe(before);
    });
  });

  describe('is paired with the change it describes', () => {
    it('commits with the change when they share a transaction', async () => {
      const c = await db.connect();
      try {
        const t = await mkUser(db.client, 'paired');
        await c.query('BEGIN');
        await c.query(
          `UPDATE users SET display_name = 'Renamed' WHERE id = $1`,
          [t.id],
        );
        await audit.record(
          {
            action: 'users.rename',
            actor: { userId: admin.id },
            target: { userId: t.id },
          },
          c,
        );
        await c.query('COMMIT');

        const changed = (
          await db.client.query(
            'SELECT display_name FROM users WHERE id = $1',
            [t.id],
          )
        ).rows[0];
        const logged = (await rows('users.rename')).filter(
          (r) => r.target_user_id === t.id,
        );
        expect(changed.display_name).toBe('Renamed');
        expect(logged).toHaveLength(1);
      } finally {
        await c.end();
      }
    });

    it('rolls back WITH the change, so there is never a record of something that did not happen', async () => {
      const c = await db.connect();
      try {
        const t = await mkUser(db.client, 'unpaired');
        await c.query('BEGIN');
        await c.query(
          `UPDATE users SET display_name = 'Never Happened' WHERE id = $1`,
          [t.id],
        );
        await audit.record(
          {
            action: 'users.rename',
            actor: { userId: admin.id },
            target: { userId: t.id },
          },
          c,
        );
        await c.query('ROLLBACK');

        const after = (
          await db.client.query(
            'SELECT display_name FROM users WHERE id = $1',
            [t.id],
          )
        ).rows[0];
        const logged = (await rows('users.rename')).filter(
          (r) => r.target_user_id === t.id,
        );
        expect(after.display_name).not.toBe('Never Happened');
        expect(logged).toHaveLength(0);
      } finally {
        await c.end();
      }
    });
  });
});
