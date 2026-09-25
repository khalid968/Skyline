import {
  Injectable,
  Dependencies,
  BadRequestException,
  ConflictException,
  NotFoundException,
  Logger,
} from '@nestjs/common';
import { DatabaseService } from '../../database/database.service';
import {
  RateLimitService,
  enforceLimit,
} from '../../common/rate-limit/rate-limit';
import { PublicBodyException } from '../../common/filters/all-exceptions.filter';
import { AuditService } from '../audit/audit.service';
import { PushService } from '../notifications/push.service';
import { FanoutService } from '../websocket/fanout.service';
import { MediaService } from '../media/media.service';
import { KeysService } from '../devices/keys.service';
import {
  MessagesService,
  REACHABLE_DEVICES,
  SEND_LIMIT,
  MAX_CIPHERTEXT,
  key,
  unkey,
  decodeEnvelopes,
} from '../messages/messages.service';
import { AbuseService } from '../abuse/abuse.service';
import { UsageService } from '../monitoring/usage.service';

// Groups, as members see them (Phase 8b, decisions.md 2026-09-25).
//
// A group message is encrypted ONCE on the sender's device with its libsignal
// Sender Key and uploaded once; the server stores a copy per recipient device
// (every live member's reachable devices, and the sender's other devices) and
// delivers it like any other envelope. The Sender Key itself travels to each
// device beforehand over the ordinary pairwise sessions ("key shares").
//
// Membership is checked on every request (the GroupTarget guard: a live member
// of a group that is not archived, else 404) and again at delivery.

const KEY_SHARE_LIMIT = { limit: 120, windowSec: 60 };
const SIGNAL_LIMIT = { limit: 240, windowSec: 60 };
const MAX_GROUP_DEVICES = 1000;

@Injectable()
@Dependencies(
  DatabaseService,
  RateLimitService,
  AuditService,
  PushService,
  MediaService,
  KeysService,
  MessagesService,
  FanoutService,
  AbuseService,
  UsageService,
)
export class GroupsService {
  constructor(db, limiter, audit, push, media, keys, messages, fanout, abuse, usage) {
    this.abuse = abuse;
    this.usage = usage;
    this.fanout = fanout;
    this.db = db;
    this.limiter = limiter;
    this.audit = audit;
    this.push = push;
    this.media = media;
    this.keys = keys;
    this.messages = messages;
    this.logger = new Logger('Groups');
  }

  // --------------------------------------------------------------- reading

  // Every group I am a live member of: its members with their reachable
  // devices (identity keys included, to check senders and set up sessions),
  // and whether each is also a direct contact. Archived groups are listed as
  // closed, without members.
  async mine(me) {
    const { rows: groups } = await this.db.query(
      `SELECT g.id, g.name, g.description, g.archived_at, c.id AS chat_id, gm.added_at
         FROM group_members gm
         JOIN groups g ON g.id = gm.group_id
         LEFT JOIN chats c ON c.kind = 'group' AND c.group_id = g.id
        WHERE gm.user_id = $1 AND gm.removed_at IS NULL
        ORDER BY g.name`,
      [me],
    );
    const live = groups.filter((g) => !g.archived_at).map((g) => g.id);
    const { rows: members } = live.length
      ? await this.db.query(
          `SELECT gm.group_id, u.id, u.username::text AS username, u.display_name, u.status,
                  are_linked($1, u.id) AS linked
             FROM group_members gm JOIN users u ON u.id = gm.user_id
            WHERE gm.group_id = ANY($2::uuid[]) AND gm.removed_at IS NULL
              AND u.status <> 'deleted'
            ORDER BY u.display_name`,
          [me, live],
        )
      : { rows: [] };
    const devices = await this.messages.devicesOf([
      ...new Set(members.map((m) => m.id)),
    ]);
    return groups.map((g) => ({
      groupId: g.id,
      chatId: g.chat_id,
      name: g.name,
      description: g.description,
      archived: g.archived_at !== null,
      joinedAt: g.added_at,
      members: g.archived_at
        ? []
        : members
            .filter((m) => m.group_id === g.id)
            .map((m) => ({
              userId: m.id,
              username: m.username,
              displayName: m.display_name,
              suspended: m.status === 'suspended',
              you: m.id === me,
              linked: m.id === me ? true : m.linked,
              devices: devices.get(m.id) || [],
            })),
    }));
  }

  // Prekey bundles for a fellow member's devices, to start the pairwise
  // session a Sender Key travels over. Anyone who is not a live member of
  // this group is the usual 404.
  async memberBundles(caller, groupId, userId, res) {
    if (userId === caller.userId) return this.keys.bundles(caller, userId, res);
    const { rows } = await this.db.query(
      `SELECT 1 FROM group_members gm JOIN users u ON u.id = gm.user_id
        WHERE gm.group_id = $1 AND gm.user_id = $2 AND gm.removed_at IS NULL
          AND u.status <> 'deleted'`,
      [groupId, userId],
    );
    if (!rows[0]) throw new NotFoundException();
    return this.keys.bundles(caller, userId, res);
  }

  // ------------------------------------------------------------- sending

  // One Sender Key ciphertext, addressed to EXACTLY the reachable devices of
  // the live members (and the sender's other devices). Anything else is a
  // 409 naming what to add or drop, as for a direct message.
  async send(caller, groupId, dto, res) {
    await enforceLimit(
      this.limiter,
      `send:device:${caller.deviceId}`,
      SEND_LIMIT,
      res,
      this.logger,
    );
    await this.abuse.beforeSend(caller, res);
    const body = decodeBody(dto.body);

    const result = await this.db.transaction(async (client) => {
      const existing = await client.query(
        'SELECT sender_device_id, created_at FROM messages WHERE id = $1',
        [dto.messageId],
      );
      if (existing.rows[0]) {
        if (existing.rows[0].sender_device_id !== caller.deviceId)
          throw new ConflictException();
        return { sentAt: existing.rows[0].created_at, duplicate: true };
      }
      const targets = await this.coverage(client, caller, groupId, dto.devices);
      const chatId = await this.chatOf(client, groupId);
      const msg = await client.query(
        `INSERT INTO messages (id, chat_id, kind, sender_user_id, sender_device_id)
         VALUES ($1, $2, 'user', $3, $4) RETURNING created_at`,
        [dto.messageId, chatId, caller.userId, caller.deviceId],
      );
      for (const deviceId of targets.values()) {
        await client.query(
          `INSERT INTO message_envelopes (message_id, recipient_device_id, envelope_kind, ciphertext)
           VALUES ($1, $2, 'sender_key', $3)`,
          [dto.messageId, deviceId, body],
        );
      }
      await this.media.claim(client, caller, dto.messageId, dto.attachmentIds);
      return {
        sentAt: msg.rows[0].created_at,
        duplicate: false,
        devices: [...targets.values()],
      };
    });

    if (!result.duplicate) {
      await this.usage.bump('group_messages');
      await this.wake(groupId, caller.userId, result.devices);
    }
    return { messageId: dto.messageId, sentAt: result.sentAt };
  }

  // Pairwise envelopes (prekey/whisper) to some of the members' devices: how
  // a device hands out its Sender Key. Any subset is fine; each must be a
  // reachable device of a live member, or one of the sender's own.
  async shareKeys(caller, groupId, dto, res) {
    await enforceLimit(
      this.limiter,
      `keyshare:device:${caller.deviceId}`,
      KEY_SHARE_LIMIT,
      res,
      this.logger,
    );
    const envelopes = decodeEnvelopes(dto.envelopes);
    const result = await this.db.transaction(async (client) => {
      const reachable = await this.memberDevices(client, caller, groupId);
      const seen = new Set();
      for (const e of envelopes) {
        const k = key(e);
        if (seen.has(k))
          throw new BadRequestException(['each device may appear only once']);
        seen.add(k);
        if (!reachable.has(k)) {
          throw new PublicBodyException(409, {
            statusCode: 409,
            error: 'Conflict',
            message: 'the device list changed',
            missing: [],
            extra: [unkey(k)],
          });
        }
      }
      const chatId = await this.chatOf(client, groupId);
      const id = await client.query(
        `INSERT INTO messages (id, chat_id, kind, sender_user_id, sender_device_id)
         VALUES ($1, $2, 'user', $3, $4)
         ON CONFLICT (id) DO NOTHING RETURNING id`,
        [dto.messageId, chatId, caller.userId, caller.deviceId],
      );
      if (!id.rows[0]) return { duplicate: true, devices: [] };
      for (const e of envelopes) {
        await client.query(
          `INSERT INTO message_envelopes (message_id, recipient_device_id, envelope_kind, ciphertext)
           VALUES ($1, $2, $3, $4)`,
          [dto.messageId, reachable.get(key(e)), e.kind, e.bytes],
        );
      }
      return {
        duplicate: false,
        devices: envelopes.map((e) => reachable.get(key(e))),
      };
    });
    if (!result.duplicate)
      await this.wake(groupId, caller.userId, result.devices);
    return { messageId: dto.messageId };
  }

  // ------------------------------------------------------------- signals

  // Typing in a group: pairwise-encrypted, relayed live to the members'
  // connected devices, never stored (like a direct typing signal).
  async signal(caller, groupId, dto, res) {
    await enforceLimit(
      this.limiter,
      `signal:device:${caller.deviceId}`,
      SIGNAL_LIMIT,
      res,
      this.logger,
    );
    const { rows: members } = await this.db.query(
      'SELECT user_id FROM group_members WHERE group_id = $1 AND removed_at IS NULL',
      [groupId],
    );
    const live = new Set(members.map((m) => m.user_id));
    for (const e of dto.envelopes) {
      if (!live.has(e.userId))
        throw new BadRequestException(['signals go to members of this group']);
    }
    const me = await this.db.query(
      'SELECT device_number FROM devices WHERE id = $1',
      [caller.deviceId],
    );
    await this.fanout.publish({
      type: 'signal',
      senderUserId: caller.userId,
      recipientUserIds: [...new Set(dto.envelopes.map((e) => e.userId))].slice(
        0,
        500,
      ),
      payload: {
        groupId,
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

  // ------------------------------------------------------------- leaving

  // A member leaves on their own (owner decision). Only an operator can add
  // them back. Announced in the group; recorded in the audit log.
  async leave(caller, groupId, ip) {
    const members = await this.db.transaction(async (client) => {
      const { rowCount } = await client.query(
        `UPDATE group_members SET removed_at = now(), removed_by = $2
          WHERE group_id = $1 AND user_id = $2 AND removed_at IS NULL`,
        [groupId, caller.userId],
      );
      if (rowCount === 0) throw new NotFoundException();
      const me = await client.query(
        'SELECT display_name FROM users WHERE id = $1',
        [caller.userId],
      );
      await announce(client, groupId, {
        type: 'group_member_left',
        groupId,
        userId: caller.userId,
        displayName: me.rows[0].display_name,
      });
      await this.audit.record(
        {
          action: 'groups.leave',
          actor: { userId: caller.userId },
          target: { userId: caller.userId, groupId },
          ip,
          detail: { left: true },
        },
        client,
      );
      const { rows } = await client.query(
        'SELECT user_id FROM group_members WHERE group_id = $1 AND removed_at IS NULL',
        [groupId],
      );
      return rows.map((r) => r.user_id);
    });
    await this.messages.nudge(caller.userId, [caller.userId]);
    for (const m of members) await this.messages.nudge(m, [m]);
  }

  // -------------------------------------------------------------- helpers

  // userId:deviceNumber -> device id, for every reachable device of a live
  // member, minus the caller's own device. A suspended member is left out
  // (board 40): the group carries on without them, and what is sent while
  // they are suspended is not theirs.
  async memberDevices(client, caller, groupId) {
    const { rows: members } = await client.query(
      `SELECT gm.user_id FROM group_members gm JOIN users u ON u.id = gm.user_id
        WHERE gm.group_id = $1 AND gm.removed_at IS NULL AND u.status = 'active'`,
      [groupId],
    );
    const { rows } = await client.query(REACHABLE_DEVICES, [
      members.map((m) => m.user_id),
    ]);
    const out = new Map();
    for (const d of rows) {
      if (d.id === caller.deviceId) continue;
      out.set(key({ userId: d.user_id, deviceNumber: d.device_number }), d.id);
    }
    return out;
  }

  async coverage(client, caller, groupId, devices) {
    if (devices.length > MAX_GROUP_DEVICES)
      throw new BadRequestException(['too many devices']);
    const expected = await this.memberDevices(client, caller, groupId);
    const given = new Set(devices.map(key));
    if (given.size !== devices.length)
      throw new BadRequestException(['each device may appear only once']);
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

  async chatOf(client, groupId) {
    await client.query(
      `INSERT INTO chats (kind, group_id) VALUES ('group', $1)
       ON CONFLICT (group_id) WHERE kind = 'group' DO NOTHING`,
      [groupId],
    );
    const { rows } = await client.query(
      `SELECT id FROM chats WHERE kind = 'group' AND group_id = $1`,
      [groupId],
    );
    return rows[0].id;
  }

  // Open apps hear the socket nudge; closed ones get a content-free push.
  async wake(groupId, senderUserId, deviceIds) {
    const { rows } = await this.db.query(
      'SELECT user_id FROM group_members WHERE group_id = $1 AND removed_at IS NULL',
      [groupId],
    );
    await this.messages.nudge(
      senderUserId,
      rows.map((r) => r.user_id).concat(senderUserId),
    );
    await this.push.wake(deviceIds);
  }
}

// A group system notice, composed by the server from facts it already knows
// (who joined, who left, the group's name). Never message content.
export async function announce(client, groupId, event) {
  const { rows } = await client.query(
    `INSERT INTO chats (kind, group_id) VALUES ('group', $1)
     ON CONFLICT (group_id) WHERE kind = 'group' DO NOTHING RETURNING id`,
    [groupId],
  );
  const chatId =
    rows[0]?.id ??
    (
      await client.query(
        `SELECT id FROM chats WHERE kind = 'group' AND group_id = $1`,
        [groupId],
      )
    ).rows[0].id;
  await client.query(
    `INSERT INTO messages (chat_id, kind, system_event) VALUES ($1, 'system', $2::jsonb)`,
    [chatId, JSON.stringify(event)],
  );
}

function decodeBody(b64) {
  const bytes =
    typeof b64 === 'string' && /^[A-Za-z0-9+/_-]+={0,2}$/.test(b64)
      ? Buffer.from(b64.replace(/-/g, '+').replace(/_/g, '/'), 'base64')
      : null;
  if (!bytes || bytes.length === 0 || bytes.length > MAX_CIPHERTEXT) {
    throw new BadRequestException(['body is not valid base64 ciphertext']);
  }
  return bytes;
}
