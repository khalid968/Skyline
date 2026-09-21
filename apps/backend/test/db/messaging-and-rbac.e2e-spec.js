// Message and chat shape, the no-hard-delete foreign keys, and RBAC. The server
// must never hold message plaintext, and no permission may grant access to it.
import {
  createTestDatabase,
  mkUser,
  mkDevice,
  mkGroup,
  failure,
  SQLSTATE,
} from './harness';

describe('messaging and RBAC (database layer)', () => {
  let db;
  let admin;

  beforeAll(async () => {
    db = await createTestDatabase('messaging');
    admin = await mkUser(db.client, 'admin', { role: 'admin' });
  }, 60000);

  afterAll(async () => {
    await db.drop();
  });

  const directChat = async (a, b) => {
    const [lo, hi] = a < b ? [a, b] : [b, a];
    const { rows } = await db.client.query(
      `INSERT INTO chats (kind, user_a_id, user_b_id) VALUES ('direct', $1, $2) RETURNING id`,
      [lo, hi],
    );
    return rows[0].id;
  };

  describe('chats', () => {
    it('rejects a direct chat stored in non-canonical order', async () => {
      const a = await mkUser(db.client, 'a');
      const b = await mkUser(db.client, 'b');
      const [lo, hi] = a.id < b.id ? [a.id, b.id] : [b.id, a.id];
      const err = await failure(
        db.client.query(`INSERT INTO chats (kind, user_a_id, user_b_id) VALUES ('direct', $1, $2)`, [
          hi,
          lo,
        ]),
      );
      expect(err.code).toBe(SQLSTATE.check);
      expect(err.constraint).toBe('chats_shape');
    });

    it('allows only one direct chat per pair', async () => {
      const a = await mkUser(db.client, 'c');
      const b = await mkUser(db.client, 'd');
      await directChat(a.id, b.id);
      const err = await failure(directChat(a.id, b.id));
      expect(err.code).toBe(SQLSTATE.unique);
    });

    it('rejects a group chat that also names users, and a direct chat that names a group', async () => {
      const a = await mkUser(db.client, 'e');
      const b = await mkUser(db.client, 'f');
      const groupId = await mkGroup(db.client, admin.id, [a.id]);
      const [lo, hi] = a.id < b.id ? [a.id, b.id] : [b.id, a.id];

      const groupWithUsers = await failure(
        db.client.query(
          `INSERT INTO chats (kind, group_id, user_a_id, user_b_id) VALUES ('group', $1, $2, $3)`,
          [groupId, lo, hi],
        ),
      );
      expect(groupWithUsers.code).toBe(SQLSTATE.check);

      const directWithGroup = await failure(
        db.client.query(
          `INSERT INTO chats (kind, group_id, user_a_id, user_b_id) VALUES ('direct', $1, $2, $3)`,
          [groupId, lo, hi],
        ),
      );
      expect(directWithGroup.code).toBe(SQLSTATE.check);
    });

    it('allows only one chat per group', async () => {
      const a = await mkUser(db.client, 'g');
      const groupId = await mkGroup(db.client, admin.id, [a.id]);
      await db.client.query(`INSERT INTO chats (kind, group_id) VALUES ('group', $1)`, [groupId]);
      const err = await failure(
        db.client.query(`INSERT INTO chats (kind, group_id) VALUES ('group', $1)`, [groupId]),
      );
      expect(err.code).toBe(SQLSTATE.unique);
    });

    it('rejects a disappearing-message timer outside the sane range', async () => {
      const a = await mkUser(db.client, 'h');
      const b = await mkUser(db.client, 'i');
      const [lo, hi] = a.id < b.id ? [a.id, b.id] : [b.id, a.id];
      const err = await failure(
        db.client.query(
          `INSERT INTO chats (kind, user_a_id, user_b_id, disappear_seconds) VALUES ('direct', $1, $2, 1)`,
          [lo, hi],
        ),
      );
      expect(err.code).toBe(SQLSTATE.check);
    });
  });

  describe('messages', () => {
    let sender;
    let device;
    let chatId;

    beforeAll(async () => {
      sender = await mkUser(db.client, 'sender');
      const other = await mkUser(db.client, 'other');
      device = await mkDevice(db.client, sender.id);
      chatId = await directChat(sender.id, other.id);
    });

    it('has no column that could hold a message body', async () => {
      const { rows } = await db.client.query(
        `SELECT column_name FROM information_schema.columns WHERE table_name = 'messages'`,
      );
      const names = rows.map((r) => r.column_name);
      for (const forbidden of ['body', 'text', 'content', 'plaintext', 'message']) {
        expect(names).not.toContain(forbidden);
      }
    });

    it('accepts a user message that names its sender and device', async () => {
      const { rows } = await db.client.query(
        `INSERT INTO messages (chat_id, kind, sender_user_id, sender_device_id) VALUES ($1, 'user', $2, $3) RETURNING id`,
        [chatId, sender.id, device],
      );
      expect(rows[0].id).toBeDefined();
    });

    it('rejects a user message with no sender', async () => {
      const err = await failure(
        db.client.query(`INSERT INTO messages (chat_id, kind) VALUES ($1, 'user')`, [chatId]),
      );
      expect(err.code).toBe(SQLSTATE.check);
      expect(err.constraint).toBe('messages_shape');
    });

    it('rejects a system message with no event, and a user message carrying one', async () => {
      const noEvent = await failure(
        db.client.query(`INSERT INTO messages (chat_id, kind) VALUES ($1, 'system')`, [chatId]),
      );
      expect(noEvent.code).toBe(SQLSTATE.check);

      const userWithEvent = await failure(
        db.client.query(
          `INSERT INTO messages (chat_id, kind, sender_user_id, sender_device_id, system_event) VALUES ($1, 'user', $2, $3, '{}')`,
          [chatId, sender.id, device],
        ),
      );
      expect(userWithEvent.code).toBe(SQLSTATE.check);
    });

    it('accepts a server-composed system message, which is how a rename is announced', async () => {
      const { rows } = await db.client.query(
        `INSERT INTO messages (chat_id, kind, system_event) VALUES ($1, 'system', $2) RETURNING id`,
        [chatId, JSON.stringify({ type: 'user_renamed', from: 'Sara', to: 'Sarah', by: 'admin' })],
      );
      expect(rows[0].id).toBeDefined();
    });

    it('cannot delete a device that has sent a message -- devices are revoked, not deleted', async () => {
      const err = await failure(db.client.query('DELETE FROM devices WHERE id = $1', [device]));
      expect([SQLSTATE.restrict, SQLSTATE.foreignKey]).toContain(err.code);
    });
  });

  describe('message envelopes', () => {
    let messageId;
    let recipientDevice;

    beforeAll(async () => {
      const a = await mkUser(db.client, 'ea');
      const b = await mkUser(db.client, 'eb');
      const aDevice = await mkDevice(db.client, a.id);
      recipientDevice = await mkDevice(db.client, b.id);
      const chatId = await directChat(a.id, b.id);
      const { rows } = await db.client.query(
        `INSERT INTO messages (chat_id, kind, sender_user_id, sender_device_id) VALUES ($1, 'user', $2, $3) RETURNING id`,
        [chatId, a.id, aDevice],
      );
      messageId = rows[0].id;
    });

    const envelope = (ciphertext, extra = '') =>
      db.client.query(
        `INSERT INTO message_envelopes (message_id, recipient_device_id, envelope_kind, ciphertext ${extra ? ', ' + extra.cols : ''})
         VALUES ($1, $2, 'whisper', $3 ${extra ? ', ' + extra.vals : ''}) RETURNING id`,
        [messageId, recipientDevice, ciphertext],
      );

    it('rejects an empty ciphertext', async () => {
      const err = await failure(envelope(Buffer.alloc(0)));
      expect(err.code).toBe(SQLSTATE.check);
    });

    it('rejects a read receipt on an envelope that was never delivered', async () => {
      const err = await failure(envelope(Buffer.from('opaque'), { cols: 'read_at', vals: 'now()' }));
      expect(err.code).toBe(SQLSTATE.check);
      expect(err.constraint).toBe('message_envelopes_read_after_delivery');
    });

    it('stores one envelope per recipient device, and only one', async () => {
      await envelope(Buffer.from('opaque-1'));
      const err = await failure(envelope(Buffer.from('opaque-2')));
      expect(err.code).toBe(SQLSTATE.unique);
    });
  });

  describe('devices', () => {
    it('stores only a public-key-sized identity key', async () => {
      const u = await mkUser(db.client, 'keyed');
      const err = await failure(
        db.client.query(
          `INSERT INTO devices (user_id, name, platform, registration_id, identity_key) VALUES ($1, 'x', 'ios', 5, $2)`,
          [u.id, Buffer.alloc(64)],
        ),
      );
      expect(err.code).toBe(SQLSTATE.check);
      expect(err.constraint).toBe('devices_identity_key_len');
    });
  });

  describe('RBAC', () => {
    const permsOf = async (role) =>
      (
        await db.client.query(
          'SELECT permission_key FROM role_permissions WHERE role_key = $1 ORDER BY 1',
          [role],
        )
      ).rows.map((r) => r.permission_key);

    it('defines exactly the three roles', async () => {
      const { rows } = await db.client.query('SELECT key FROM roles ORDER BY rank');
      expect(rows.map((r) => r.key)).toEqual(['member', 'moderator', 'admin']);
    });

    it('gives an ordinary member no operator permissions at all', async () => {
      expect(await permsOf('member')).toEqual([]);
    });

    it('gives the administrator every permission', async () => {
      const all = (await db.client.query('SELECT key FROM permissions ORDER BY 1')).rows.map(
        (r) => r.key,
      );
      expect(await permsOf('admin')).toEqual(all);
    });

    it('does not let a moderator create, rename or delete accounts, or manage activation codes', async () => {
      const mod = await permsOf('moderator');
      for (const denied of [
        'users.create',
        'users.rename',
        'users.delete',
        'codes.issue',
        'codes.revoke',
        'groups.create',
        'devices.revoke',
      ]) {
        expect(mod).not.toContain(denied);
      }
    });

    it('has NO permission -- for any role -- that could grant access to message plaintext', async () => {
      const { rows } = await db.client.query('SELECT key, description FROM permissions');
      for (const p of rows) {
        expect(`${p.key} ${p.description}`).not.toMatch(/message|plaintext|content|decrypt|read_all/i);
      }
    });
  });
});
