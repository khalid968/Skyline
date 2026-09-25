import {
  Injectable,
  Dependencies,
  BadRequestException,
  ConflictException,
  Logger,
} from '@nestjs/common';
import { DatabaseService } from '../../database/database.service';
import {
  RateLimitService,
  enforceLimit,
} from '../../common/rate-limit/rate-limit';
import { PublicBodyException } from '../../common/filters/all-exceptions.filter';
import { FanoutService } from '../websocket/fanout.service';
import { PushService } from '../notifications/push.service';
import { MediaService } from '../media/media.service';

// How messages move (decisions.md, 2026-09-24):
//
//   send    the sender's device uploads one ciphertext per live device: every
//           device of the recipient, and every OTHER device of the sender.
//   nudge   connected devices get a content-free "inbox" event.
//   inbox   each device pulls its own ciphertexts (and server system notices).
//   ack     the device confirms; the server erases the ciphertext and tells
//           the sender "delivered".
//
// The server stores and forwards bytes it cannot read, and forgets them as
// soon as they have arrived.

const PAGE = 100;
export const SEND_LIMIT = { limit: 120, windowSec: 60 };
const SIGNAL_LIMIT = { limit: 240, windowSec: 60 };
export const MAX_CIPHERTEXT = 48 * 1024;

// A device can be sent to once it has an identity and a signed prekey: until
// then nobody could have started a session with it.
export const REACHABLE_DEVICES = `
  SELECT d.id, d.user_id, d.device_number
    FROM devices d
   WHERE d.user_id = ANY($1::uuid[])
     AND d.revoked_at IS NULL
     AND d.identity_key IS NOT NULL
     AND d.device_number IS NOT NULL
     AND EXISTS (SELECT 1 FROM signed_prekeys s
                  WHERE s.device_id = d.id AND s.superseded_at IS NULL)`;

@Injectable()
@Dependencies(
  DatabaseService,
  RateLimitService,
  FanoutService,
  PushService,
  MediaService,
)
export class MessagesService {
  constructor(db, limiter, fanout, push, media) {
    this.media = media;
    this.db = db;
    this.limiter = limiter;
    this.fanout = fanout;
    this.push = push;
    this.logger = new Logger('Messages');
  }

  // ------------------------------------------------------------ directory

  // Everyone this person can message (a live DIRECT link), with each one's
  // reachable devices and their identity keys. The app uses the device list to
  // notice new devices and to check a first message's sender identity.
  async contacts(me) {
    const { rows } = await this.db.query(
      `SELECT u.id, u.username::text AS username, u.display_name, u.status,
              c.id AS chat_id
         FROM users u
         LEFT JOIN chats c ON c.kind = 'direct'
              AND c.user_a_id = LEAST(u.id, $1::uuid) AND c.user_b_id = GREATEST(u.id, $1::uuid)
        WHERE u.id <> $1 AND u.status <> 'deleted' AND are_linked($1, u.id)
        ORDER BY u.display_name`,
      [me],
    );
    const devices = await this.devicesOf(rows.map((r) => r.id));
    return rows.map((r) => ({
      userId: r.id,
      username: r.username,
      displayName: r.display_name,
      suspended: r.status === 'suspended',
      chatId: r.chat_id,
      devices: devices.get(r.id) || [],
    }));
  }

  async contactDevices(userId) {
    return (await this.devicesOf([userId])).get(userId) || [];
  }

  async devicesOf(userIds) {
    const byUser = new Map();
    if (userIds.length === 0) return byUser;
    const { rows } = await this.db.query(
      `SELECT d.user_id, d.device_number, d.identity_key, d.registration_id, d.platform, d.created_at
         FROM (${REACHABLE_DEVICES}) r JOIN devices d ON d.id = r.id
        ORDER BY d.device_number`,
      [userIds],
    );
    for (const d of rows) {
      if (!byUser.has(d.user_id)) byUser.set(d.user_id, []);
      byUser.get(d.user_id).push({
        deviceNumber: d.device_number,
        identityKey: d.identity_key.toString('base64'),
        registrationId: d.registration_id,
        platform: d.platform,
        addedAt: d.created_at,
      });
    }
    return byUser;
  }

  // ----------------------------------------------------------------- send

  async send(caller, recipientUserId, dto, res) {
    await enforceLimit(
      this.limiter,
      `send:device:${caller.deviceId}`,
      SEND_LIMIT,
      res,
      this.logger,
    );
    const envelopes = decodeEnvelopes(dto.envelopes);

    const result = await this.db.transaction(async (client) => {
      // A retry of a message that already went through: same answer, no
      // second delivery.
      const existing = await client.query(
        'SELECT sender_device_id, created_at FROM messages WHERE id = $1',
        [dto.messageId],
      );
      if (existing.rows[0]) {
        if (existing.rows[0].sender_device_id !== caller.deviceId) {
          throw new ConflictException();
        }
        return {
          messageId: dto.messageId,
          sentAt: existing.rows[0].created_at,
          duplicate: true,
        };
      }

      const targets = await this.coverage(
        client,
        caller,
        recipientUserId,
        envelopes,
      );

      const [lo, hi] = [caller.userId, recipientUserId].sort();
      await client.query(
        `INSERT INTO chats (kind, user_a_id, user_b_id) VALUES ('direct', $1, $2)
         ON CONFLICT (user_a_id, user_b_id) WHERE kind = 'direct' DO NOTHING`,
        [lo, hi],
      );
      const chat = await client.query(
        `SELECT id FROM chats WHERE kind = 'direct' AND user_a_id = $1 AND user_b_id = $2`,
        [lo, hi],
      );
      const msg = await client.query(
        `INSERT INTO messages (id, chat_id, kind, sender_user_id, sender_device_id)
         VALUES ($1, $2, 'user', $3, $4) RETURNING created_at`,
        [dto.messageId, chat.rows[0].id, caller.userId, caller.deviceId],
      );
      for (const e of envelopes) {
        await client.query(
          `INSERT INTO message_envelopes (message_id, recipient_device_id, envelope_kind, ciphertext)
           VALUES ($1, $2, $3, $4)`,
          [dto.messageId, targets.get(key(e)), e.kind, e.bytes],
        );
      }
      await this.media.claim(client, caller, dto.messageId, dto.attachmentIds);
      return {
        messageId: dto.messageId,
        chatId: chat.rows[0].id,
        sentAt: msg.rows[0].created_at,
        duplicate: false,
        devices: [...targets.values()],
      };
    });

    if (!result.duplicate) {
      // Open apps hear the socket nudge; closed ones get a content-free push.
      await this.nudge(caller.userId, [recipientUserId, caller.userId]);
      await this.push.wake(result.devices);
    }
    return { messageId: result.messageId, sentAt: result.sentAt };
  }

  // The envelopes must address EXACTLY the reachable devices of the recipient
  // plus the sender's other reachable devices. Anything else is a 409 that
  // names what to add or drop, so the client can fetch bundles and retry.
  async coverage(client, caller, recipientUserId, envelopes) {
    const { rows } = await client.query(REACHABLE_DEVICES, [
      [recipientUserId, caller.userId],
    ]);
    const expected = new Map();
    for (const d of rows) {
      if (d.id === caller.deviceId) continue; // not to itself
      expected.set(
        key({ userId: d.user_id, deviceNumber: d.device_number }),
        d.id,
      );
    }
    const given = new Set(envelopes.map(key));
    if (given.size !== envelopes.length) {
      throw new BadRequestException(['each device may appear only once']);
    }
    const missing = [...expected.keys()].filter((k) => !given.has(k));
    const extra = [...given].filter((k) => !expected.has(k));
    if (missing.length || extra.length) {
      throw new PublicBodyException(409, {
        statusCode: 409,
        error: 'Conflict',
        message: 'the device list changed',
        missing: missing.map(unkey),
        extra: extra.map(unkey),
      });
    }
    return expected;
  }

  // -------------------------------------------------------------- signals

  // Typing indicators: encrypted, relayed live, never stored. Offline devices
  // simply miss them.
  async signal(caller, recipientUserId, dto, res) {
    await enforceLimit(
      this.limiter,
      `signal:device:${caller.deviceId}`,
      SIGNAL_LIMIT,
      res,
      this.logger,
    );
    const envelopes = decodeEnvelopes(dto.envelopes);
    for (const e of envelopes) {
      if (e.userId !== recipientUserId && e.userId !== caller.userId) {
        throw new BadRequestException([
          'signals go to the contact or your own devices',
        ]);
      }
    }
    const me = await this.db.query(
      'SELECT device_number FROM devices WHERE id = $1',
      [caller.deviceId],
    );
    await this.fanout.publish({
      type: 'signal',
      senderUserId: caller.userId,
      recipientUserIds: [...new Set([recipientUserId, caller.userId])],
      payload: {
        fromDevice: me.rows[0].device_number,
        envelopes: dto.envelopes.map((e) => ({
          userId: e.userId,
          deviceNumber: e.deviceNumber,
          kind: e.kind,
          body: e.body,
        })),
      },
    });
  }

  // ---------------------------------------------------------------- inbox

  // This device's undelivered copies, oldest first, and the system notices it
  // has not stored yet. Re-checks the contact graph NOW: a message from someone
  // whose link was revoked stays undelivered.
  async inbox(caller) {
    const envelopes = await this.db.query(
      `SELECT e.id, e.message_id, e.envelope_kind, e.ciphertext, m.chat_id, c.group_id,
              m.sender_user_id, sd.device_number AS sender_device_number, m.created_at
         FROM message_envelopes e
         JOIN messages m ON m.id = e.message_id
         JOIN chats c ON c.id = m.chat_id
         JOIN devices sd ON sd.id = m.sender_device_id
        WHERE e.recipient_device_id = $1
          AND e.delivered_at IS NULL
          AND (m.sender_user_id = $2
               OR (c.kind = 'direct' AND are_linked($2, m.sender_user_id))
               OR (c.kind = 'group' AND EXISTS (
                    SELECT 1 FROM group_members g JOIN groups gr ON gr.id = g.group_id
                     WHERE g.group_id = c.group_id AND g.user_id = $2
                       AND g.removed_at IS NULL AND gr.archived_at IS NULL
                       AND g.added_at <= m.created_at)))
        ORDER BY m.seq
        LIMIT ${PAGE}`,
      [caller.deviceId, caller.userId],
    );
    const system = await this.db.query(
      `SELECT m.seq, m.chat_id, c.group_id, m.system_event, m.created_at
         FROM messages m
         JOIN chats c ON c.id = m.chat_id
         JOIN devices d ON d.id = $1
        WHERE m.kind = 'system'
          AND m.seq > d.system_seq
          AND ((c.kind = 'direct' AND $2 IN (c.user_a_id, c.user_b_id)
                AND are_linked(c.user_a_id, c.user_b_id))
               OR (c.kind = 'group' AND EXISTS (
                    SELECT 1 FROM group_members g
                     WHERE g.group_id = c.group_id AND g.user_id = $2 AND g.removed_at IS NULL
                       AND g.added_at <= m.created_at)))
        ORDER BY m.seq
        LIMIT ${PAGE}`,
      [caller.deviceId, caller.userId],
    );
    return {
      envelopes: envelopes.rows.map((e) => ({
        envelopeId: e.id,
        messageId: e.message_id,
        chatId: e.chat_id,
        groupId: e.group_id ?? undefined,
        senderUserId: e.sender_user_id,
        senderDeviceNumber: e.sender_device_number,
        kind: e.envelope_kind,
        body: e.ciphertext.toString('base64'),
        sentAt: e.created_at,
      })),
      system: system.rows.map((s) => ({
        seq: Number(s.seq),
        chatId: s.chat_id,
        groupId: s.group_id ?? undefined,
        event: s.system_event,
        at: s.created_at,
      })),
      more: envelopes.rows.length === PAGE || system.rows.length === PAGE,
    };
  }

  // The device has stored these: erase the ciphertext for good, move the
  // system cursor, and tell each sender "delivered".
  async ack(caller, { envelopeIds = [], systemSeq }) {
    const acked = await this.db.transaction(async (client) => {
      const { rows } = await client.query(
        `UPDATE message_envelopes e
            SET delivered_at = now(), ciphertext = NULL
           FROM messages m
          WHERE e.id = ANY($1::uuid[])
            AND e.recipient_device_id = $2
            AND e.delivered_at IS NULL
            AND m.id = e.message_id
          RETURNING e.message_id, m.sender_user_id`,
        [envelopeIds, caller.deviceId],
      );
      if (systemSeq !== undefined) {
        await client.query(
          `UPDATE devices SET system_seq = GREATEST(system_seq, LEAST($2::bigint,
                    (SELECT COALESCE(max(seq), 0) FROM messages)))
            WHERE id = $1`,
          [caller.deviceId, systemSeq],
        );
      }
      return rows;
    });

    // Delivery receipts go to the other person only; your own devices' copies
    // are not "delivered" to anyone.
    const bySender = new Map();
    for (const r of acked) {
      if (r.sender_user_id === caller.userId) continue;
      if (!bySender.has(r.sender_user_id)) bySender.set(r.sender_user_id, []);
      bySender.get(r.sender_user_id).push(r.message_id);
    }
    for (const [sender, messageIds] of bySender) {
      await this.publishQuietly({
        type: 'receipt',
        senderUserId: caller.userId,
        recipientUserIds: [sender],
        payload: { state: 'delivered', messageIds },
      });
    }
    return { acknowledged: acked.length };
  }

  // Delivery status of messages this person sent: for the ticks after an app
  // restart. Delivered = at least one of the recipient's devices has it.
  async status(caller, messageIds) {
    const { rows } = await this.db.query(
      `SELECT m.id,
              bool_or(e.delivered_at IS NOT NULL AND rd.user_id <> m.sender_user_id) AS delivered
         FROM messages m
         JOIN message_envelopes e ON e.message_id = m.id
         JOIN devices rd ON rd.id = e.recipient_device_id
        WHERE m.id = ANY($1::uuid[]) AND m.sender_user_id = $2
        GROUP BY m.id`,
      [messageIds, caller.userId],
    );
    return rows.map((r) => ({ messageId: r.id, delivered: r.delivered }));
  }

  // -------------------------------------------------------------- helpers

  async nudge(senderUserId, recipientUserIds) {
    await this.publishQuietly({
      type: 'inbox',
      senderUserId,
      recipientUserIds: [...new Set(recipientUserIds)],
      payload: {},
    });
  }

  // The message is stored; a failed nudge only delays it until the next pull.
  async publishQuietly(event) {
    try {
      await this.fanout.publish(event);
    } catch (err) {
      this.logger.warn(`nudge not published: ${err.message}`);
    }
  }
}

export const key = (e) => `${e.userId}:${e.deviceNumber}`;
export const unkey = (k) => {
  const [userId, n] = k.split(':');
  return { userId, deviceNumber: Number(n) };
};

export function decodeEnvelopes(list) {
  return list.map((e, i) => {
    const bytes =
      typeof e.body === 'string' && /^[A-Za-z0-9+/_-]+={0,2}$/.test(e.body)
        ? Buffer.from(e.body.replace(/-/g, '+').replace(/_/g, '/'), 'base64')
        : null;
    if (!bytes || bytes.length === 0 || bytes.length > MAX_CIPHERTEXT) {
      throw new BadRequestException([
        `envelopes.${i}.body is not valid base64 ciphertext`,
      ]);
    }
    return {
      userId: e.userId,
      deviceNumber: e.deviceNumber,
      kind: e.kind,
      bytes,
    };
  });
}
