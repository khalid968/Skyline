// Phase 8a (migration 012): once a device has its copy the server erases the
// ciphertext, and that is one-way. Envelopes are never deleted or readdressed.
import crypto from 'crypto';
import {
  createTestDatabase,
  mkUser,
  mkDevice,
  failure,
  SQLSTATE,
} from './harness';

describe('message delivery (database layer)', () => {
  let db;

  beforeAll(async () => {
    db = await createTestDatabase('delivery');
  }, 60000);

  afterAll(async () => {
    await db.drop();
  });

  const q = (text, params) => db.client.query(text, params);

  const envelope = async () => {
    const a = await mkUser(db.client, 'from');
    const b = await mkUser(db.client, 'to');
    const [lo, hi] = [a.id, b.id].sort();
    const chat = await q(
      `INSERT INTO chats (kind, user_a_id, user_b_id) VALUES ('direct', $1, $2) RETURNING id`,
      [lo, hi],
    );
    const sender = await mkDevice(db.client, a.id);
    const recipient = await mkDevice(db.client, b.id);
    const m = await q(
      `INSERT INTO messages (chat_id, sender_user_id, sender_device_id) VALUES ($1, $2, $3) RETURNING id, seq`,
      [chat.rows[0].id, a.id, sender],
    );
    const e = await q(
      `INSERT INTO message_envelopes (message_id, recipient_device_id, envelope_kind, ciphertext)
       VALUES ($1, $2, 'whisper', $3) RETURNING id`,
      [m.rows[0].id, recipient, crypto.randomBytes(64)],
    );
    return { id: e.rows[0].id, messageSeq: m.rows[0].seq, recipient, sender };
  };

  it('erases ciphertext only together with delivery', async () => {
    const e = await envelope();
    const early = await failure(
      q('UPDATE message_envelopes SET ciphertext = NULL WHERE id = $1', [e.id]),
    );
    expect(early.constraint).toBe(
      'message_envelopes_erased_only_when_delivered',
    );
    await q(
      'UPDATE message_envelopes SET delivered_at = now(), ciphertext = NULL WHERE id = $1',
      [e.id],
    );
  });

  it('never changes or restores ciphertext, never undoes a delivery', async () => {
    const e = await envelope();
    const changed = await failure(
      q('UPDATE message_envelopes SET ciphertext = $2 WHERE id = $1', [
        e.id,
        crypto.randomBytes(64),
      ]),
    );
    expect(changed.code).toBe(SQLSTATE.check);

    await q(
      'UPDATE message_envelopes SET delivered_at = now(), ciphertext = NULL WHERE id = $1',
      [e.id],
    );
    for (const [sql, params] of [
      [
        'UPDATE message_envelopes SET ciphertext = $2 WHERE id = $1',
        [e.id, crypto.randomBytes(8)],
      ],
      [
        'UPDATE message_envelopes SET delivered_at = NULL WHERE id = $1',
        [e.id],
      ],
    ]) {
      expect((await failure(q(sql, params))).code).toBe(SQLSTATE.check);
    }
  });

  it('never deletes or readdresses an envelope', async () => {
    const e = await envelope();
    const other = await envelope();
    expect(
      (await failure(q('DELETE FROM message_envelopes WHERE id = $1', [e.id])))
        .code,
    ).toBe(SQLSTATE.check);
    const moved = await failure(
      q('UPDATE message_envelopes SET recipient_device_id = $2 WHERE id = $1', [
        e.id,
        other.recipient,
      ]),
    );
    expect(moved.code).toBe(SQLSTATE.check);
  });

  it('orders every message with a unique sequence number', async () => {
    const a = await envelope();
    const b = await envelope();
    expect(Number(b.messageSeq)).toBeGreaterThan(Number(a.messageSeq));
  });
});
