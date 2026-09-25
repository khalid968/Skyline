import { Injectable, Dependencies } from '@nestjs/common';
import { DatabaseService } from '../../database/database.service';
import { isUuid } from '../../common/uuid';

// The contact graph, as questions the rest of the backend can ask. Each method
// is a thin wrapper over the SQL primitives from migration 006
// (are_linked, visible_user_ids), which are what the database tests exercise.
//
// Every method is DEFAULT DENY: a malformed id, an unknown id and an id outside
// the caller's graph all return false. The caller (a guard) turns false into
// one indistinguishable 404. Nothing here is cached; see AccountService.
@Injectable()
@Dependencies(DatabaseService)
export class GraphService {
  constructor(db) {
    this.db = db;
  }

  async _ask(sql, params) {
    if (!params.every(isUuid)) return false;
    const { rows } = await this.db.query(sql, params);
    return rows[0]?.ok === true;
  }

  // Can `me` see who `other` is? True for a direct contact or anyone sharing a
  // live group. A deleted account is invisible to everyone.
  canSeeUser(me, other) {
    if (me === other) return Promise.resolve(false);
    return this._ask(
      `SELECT EXISTS (
         SELECT 1 FROM visible_user_ids($1) v
           JOIN users t ON t.id = v.user_id
          WHERE v.user_id = $2 AND t.status <> 'deleted'
       ) AS ok`,
      [me, other],
    );
  }

  // Can `me` message `other` directly? Requires a live direct link; sharing a
  // group is not enough.
  canMessageUser(me, other) {
    if (me === other) return Promise.resolve(false);
    return this._ask(
      `SELECT (are_linked($1, $2)
               AND EXISTS (SELECT 1 FROM users t WHERE t.id = $2 AND t.status <> 'deleted')) AS ok`,
      [me, other],
    );
  }

  // A live device that belongs to `me`. Anyone else's device, and one already
  // revoked, is indistinguishable from one that does not exist.
  ownsDevice(me, deviceId) {
    return this._ask(
      `SELECT EXISTS (
         SELECT 1 FROM devices WHERE id = $2 AND user_id = $1 AND revoked_at IS NULL
       ) AS ok`,
      [me, deviceId],
    );
  }

  // A live member of a group that is not archived (an archived group is
  // closed: members keep what is on their devices, and nothing more).
  isGroupMember(me, groupId) {
    return this._ask(
      `SELECT EXISTS (
         SELECT 1 FROM group_members gm JOIN groups g ON g.id = gm.group_id
          WHERE gm.group_id = $2 AND gm.user_id = $1 AND gm.removed_at IS NULL
            AND g.archived_at IS NULL
       ) AS ok`,
      [me, groupId],
    );
  }

  // A direct chat is reachable only while its link is live, so revoking the
  // link takes the conversation away immediately (contact-graph.md rule 6). A
  // group chat is reachable only by live members.
  canAccessChat(me, chatId) {
    return this._ask(
      `SELECT EXISTS (
         SELECT 1 FROM chats c
          WHERE c.id = $2
            AND (
              (c.kind = 'direct'
                 AND $1 IN (c.user_a_id, c.user_b_id)
                 AND are_linked(c.user_a_id, c.user_b_id))
              OR
              (c.kind = 'group'
                 AND EXISTS (SELECT 1 FROM group_members gm
                              WHERE gm.group_id = c.group_id
                                AND gm.user_id = $1
                                AND gm.removed_at IS NULL))
            )
       ) AS ok`,
      [me, chatId],
    );
  }

  // An upload still in progress, started by one of `me`'s live devices.
  ownsUpload(me, attachmentId) {
    return this._ask(
      `SELECT EXISTS (
         SELECT 1 FROM attachments a JOIN devices d ON d.id = a.uploaded_by_device_id
          WHERE a.id = $2 AND a.status = 'uploading'
            AND d.user_id = $1 AND d.revoked_at IS NULL
       ) AS ok`,
      [me, attachmentId],
    );
  }

  // A ready file `me` may download: they uploaded it, or it rides on a message
  // in a chat they can still access. Expired and deleted files are gone.
  canDownloadAttachment(me, attachmentId) {
    return this._ask(
      `SELECT EXISTS (
         SELECT 1 FROM attachments a
           JOIN devices up ON up.id = a.uploaded_by_device_id
          WHERE a.id = $2 AND a.status = 'ready' AND a.expires_at > now()
            AND (
              up.user_id = $1
              OR EXISTS (
                SELECT 1 FROM messages m JOIN chats c ON c.id = m.chat_id
                 WHERE m.id = a.message_id
                   AND ((c.kind = 'direct' AND $1 IN (c.user_a_id, c.user_b_id)
                         AND are_linked(c.user_a_id, c.user_b_id))
                        OR (c.kind = 'group' AND EXISTS (
                             SELECT 1 FROM group_members gm
                              WHERE gm.group_id = c.group_id AND gm.user_id = $1
                                AND gm.removed_at IS NULL))))
            )
       ) AS ok`,
      [me, attachmentId],
    );
  }

  // Of these devices, the ones that may right now receive something from
  // `senderId`: not revoked, owner active, owner in the sender's graph. Used by
  // WebSocket fan-out so a delivery re-checks the graph at the moment it
  // happens, which is what makes revocation take effect on an open socket. The
  // sender's own other devices always qualify, so a message sent from a phone
  // still reaches the same person's desktop.
  async deliverableDevices(senderId, deviceIds) {
    if (!isUuid(senderId)) return new Set();
    const ids = deviceIds.filter(isUuid);
    if (ids.length === 0) return new Set();

    const { rows } = await this.db.query(
      `SELECT d.id
         FROM devices d
         JOIN users u ON u.id = d.user_id
        WHERE d.id = ANY($1::uuid[])
          AND d.revoked_at IS NULL
          AND u.status = 'active'
          AND (d.user_id = $2
               OR d.user_id IN (SELECT user_id FROM visible_user_ids($2)))`,
      [ids, senderId],
    );
    return new Set(rows.map((r) => r.id));
  }
}
