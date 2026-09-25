// Media (migration 013): an attachment is claimed by one message only once it
// is fully uploaded, never moves, never changes identity, is never deleted as
// a row, and once marked deleted stays deleted. Everything expires in 30 days.
import crypto from 'crypto';
import {
  createTestDatabase,
  mkUser,
  mkDevice,
  failure,
  SQLSTATE,
} from './harness';

describe('attachments (database layer)', () => {
  let db;
  let device;
  let messages;

  beforeAll(async () => {
    db = await createTestDatabase('attachments');
    const a = await mkUser(db.client, 'from');
    const b = await mkUser(db.client, 'to');
    const [lo, hi] = [a.id, b.id].sort();
    const chat = await q(
      `INSERT INTO chats (kind, user_a_id, user_b_id) VALUES ('direct', $1, $2) RETURNING id`,
      [lo, hi],
    );
    device = await mkDevice(db.client, a.id);
    messages = [];
    for (let i = 0; i < 2; i++) {
      const m = await q(
        `INSERT INTO messages (chat_id, sender_user_id, sender_device_id) VALUES ($1, $2, $3) RETURNING id`,
        [chat.rows[0].id, a.id, device],
      );
      messages.push(m.rows[0].id);
    }
  }, 60000);

  afterAll(async () => {
    await db.drop();
  });

  const q = (text, params) => db.client.query(text, params);

  const attachment = async (bytes = 1000) => {
    const { rows } = await q(
      `INSERT INTO attachments (storage_key, ciphertext_bytes, ciphertext_sha256, uploaded_by_device_id)
       VALUES ($1, $2, $3, $4) RETURNING id, status, expires_at, created_at`,
      [crypto.randomUUID(), bytes, crypto.randomBytes(32), device],
    );
    return rows[0];
  };

  it('starts uploading, unclaimed, and expires 30 days after it was created', async () => {
    const a = await attachment();
    expect(a.status).toBe('uploading');
    const days = (a.expires_at - a.created_at) / 86400000;
    expect(days).toBeCloseTo(30, 3);
  });

  it('holds at most 2 GB of plaintext plus the tag', async () => {
    await attachment(2 * 1024 ** 3 + 16);
    const e = await failure(attachment(2 * 1024 ** 3 + 17));
    expect(e.constraint).toBe('attachments_max_size');
  });

  it('cannot be claimed by a message while still uploading', async () => {
    const a = await attachment();
    const e = await failure(
      q('UPDATE attachments SET message_id = $2 WHERE id = $1', [
        a.id,
        messages[0],
      ]),
    );
    expect(e.constraint).toBe('attachments_claimed_only_when_ready');
  });

  it('belongs to one message, for good', async () => {
    const a = await attachment();
    await q(
      `UPDATE attachments SET status = 'ready', message_id = $2 WHERE id = $1`,
      [a.id, messages[0]],
    );
    const moved = await failure(
      q('UPDATE attachments SET message_id = $2 WHERE id = $1', [
        a.id,
        messages[1],
      ]),
    );
    expect(moved.code).toBe(SQLSTATE.check);
    const cleared = await failure(
      q('UPDATE attachments SET message_id = NULL WHERE id = $1', [a.id]),
    );
    expect(cleared.code).toBe(SQLSTATE.check);
  });

  it('never changes its size, hash, object or uploader', async () => {
    const a = await attachment();
    for (const set of [
      'ciphertext_bytes = 5000',
      `ciphertext_sha256 = '\\x${'00'.repeat(32)}'`,
      `storage_key = 'elsewhere'`,
    ]) {
      const e = await failure(
        q(`UPDATE attachments SET ${set} WHERE id = $1`, [a.id]),
      );
      expect([set, e.code]).toEqual([set, SQLSTATE.check]);
    }
  });

  it('is never deleted as a row, and a deletion is never undone', async () => {
    const a = await attachment();
    expect(
      (await failure(q('DELETE FROM attachments WHERE id = $1', [a.id]))).code,
    ).toBe(SQLSTATE.check);
    const unstamped = await failure(
      q(`UPDATE attachments SET status = 'deleted' WHERE id = $1`, [a.id]),
    );
    expect(unstamped.constraint).toBe('attachments_deleted_stamp');
    await q(
      `UPDATE attachments SET status = 'deleted', deleted_at = now() WHERE id = $1`,
      [a.id],
    );
    const back = await failure(
      q(
        `UPDATE attachments SET status = 'ready', deleted_at = NULL WHERE id = $1`,
        [a.id],
      ),
    );
    expect(back.code).toBe(SQLSTATE.check);
  });

  it('records parts of at most 8 MB, numbered 1 to 10000, once each', async () => {
    const a = await attachment();
    const part = (n, bytes) =>
      q(
        `INSERT INTO attachment_parts (attachment_id, part_number, etag, bytes) VALUES ($1, $2, 'e', $3)`,
        [a.id, n, bytes],
      );
    await part(1, 8388608);
    expect((await failure(part(1, 10))).code).toBe(SQLSTATE.unique);
    expect((await failure(part(2, 8388609))).constraint).toBe(
      'attachment_parts_bytes',
    );
    expect((await failure(part(0, 10))).constraint).toBe(
      'attachment_parts_number',
    );
    expect((await failure(part(10001, 10))).constraint).toBe(
      'attachment_parts_number',
    );
  });
});
