import {
  Injectable,
  Dependencies,
  BadRequestException,
  ConflictException,
  NotFoundException,
  Logger,
} from '@nestjs/common';
import { DatabaseService } from '../../database/database.service';
import { AuditService } from '../audit/audit.service';
import { FanoutService } from '../websocket/fanout.service';
import { isUuid } from '../../common/uuid';
import { announce } from '../groups/groups.service';
import { loadTarget, assertCanManage } from './admin-policy';

// Groups, as operators manage them (board 31; decisions.md 2026-09-25).
// Admins and moderators create, rename, archive and change membership. Each
// change runs in ONE transaction with its audit entry and its announcement in
// the group. Operators never see what members write.
@Injectable()
@Dependencies(DatabaseService, AuditService, FanoutService)
export class AdminGroupsService {
  constructor(db, audit, fanout) {
    this.db = db;
    this.audit = audit;
    this.fanout = fanout;
    this.logger = new Logger('AdminGroups');
  }

  // ------------------------------------------------------------------ reads

  async list() {
    const { rows } = await this.db.query(
      `SELECT g.id, g.name, g.description, g.created_at, g.archived_at,
              count(gm.id) FILTER (WHERE gm.removed_at IS NULL) AS members
         FROM groups g
         LEFT JOIN group_members gm ON gm.group_id = g.id
        GROUP BY g.id
        ORDER BY g.archived_at IS NOT NULL, g.name`,
    );
    return rows.map(groupRow);
  }

  async detail(groupId) {
    const g = await this.load(groupId);
    const { rows } = await this.db.query(
      `SELECT gm.user_id, gm.added_at, gm.removed_at, gm.removed_by,
              u.display_name, u.username::text AS username, u.status
         FROM group_members gm JOIN users u ON u.id = gm.user_id
        WHERE gm.group_id = $1
        ORDER BY gm.removed_at IS NOT NULL, u.display_name, gm.added_at DESC`,
      [groupId],
    );
    // One row per person: their current membership, or their latest one.
    const seen = new Set();
    const members = [];
    for (const r of rows) {
      if (seen.has(r.user_id)) continue;
      seen.add(r.user_id);
      members.push({
        userId: r.user_id,
        displayName: r.display_name,
        username: r.username,
        status: r.status,
        addedAt: r.added_at,
        removedAt: r.removed_at,
        left: r.removed_at !== null && r.removed_by === r.user_id,
      });
    }
    return {
      ...groupRow({
        ...g,
        members: members.filter((m) => !m.removedAt).length,
      }),
      history: members,
    };
  }

  // ---------------------------------------------------------------- changes

  async create(actor, { name, description, memberIds = [] }, ip) {
    const people = [];
    for (const id of new Set(memberIds)) {
      const t = await loadTarget(this.db, id);
      assertCanManage(actor, t, { self: true });
      people.push(t);
    }
    const groupId = await this.db.transaction(async (client) => {
      const { rows } = await client.query(
        `INSERT INTO groups (name, description, created_by) VALUES ($1, $2, $3) RETURNING id`,
        [name.trim(), blankToNull(description), actor.userId],
      );
      const id = rows[0].id;
      await client.query(
        `INSERT INTO chats (kind, group_id) VALUES ('group', $1)`,
        [id],
      );
      await announce(client, id, {
        type: 'group_created',
        groupId: id,
        name: name.trim(),
      });
      for (const p of people) {
        await client.query(
          `INSERT INTO group_members (group_id, user_id, added_by) VALUES ($1, $2, $3)`,
          [id, p.id, actor.userId],
        );
      }
      await this.audit.record(
        {
          action: 'groups.create',
          actor: { userId: actor.userId },
          target: { groupId: id },
          ip,
          detail: { name: name.trim(), members: people.length },
        },
        client,
      );
      return id;
    });
    await this.nudge(people.map((p) => p.id));
    return this.detail(groupId);
  }

  async update(actor, groupId, { name, description }, ip) {
    const g = await this.load(groupId);
    if (g.archived_at) throw new ConflictException();
    const next = {
      name: name !== undefined ? name.trim() : g.name,
      description:
        description !== undefined ? blankToNull(description) : g.description,
    };
    if (next.name === g.name && next.description === g.description)
      return this.detail(groupId);
    await this.db.transaction(async (client) => {
      await client.query(
        'UPDATE groups SET name = $2, description = $3 WHERE id = $1',
        [groupId, next.name, next.description],
      );
      // A rename is announced, like a user rename: nobody can quietly make a
      // group look like another.
      if (next.name !== g.name) {
        await announce(client, groupId, {
          type: 'group_renamed',
          groupId,
          from: g.name,
          to: next.name,
        });
      }
      await this.audit.record(
        {
          action: 'groups.update',
          actor: { userId: actor.userId },
          target: { groupId },
          ip,
          detail: {
            from: { name: g.name },
            to: { name: next.name },
            descriptionChanged: next.description !== g.description,
          },
        },
        client,
      );
    });
    await this.nudge(await this.liveMembers(groupId));
    return this.detail(groupId);
  }

  async setMember(actor, groupId, { userId, member }, ip) {
    const g = await this.load(groupId);
    if (g.archived_at) throw new ConflictException();
    const t = await loadTarget(this.db, userId);
    assertCanManage(actor, t, { self: true });
    const before = await this.liveMembers(groupId);
    const changed = await this.db.transaction(async (client) => {
      const r = member
        ? await client.query(
            `INSERT INTO group_members (group_id, user_id, added_by)
             SELECT $1, $2, $3
              WHERE NOT EXISTS (SELECT 1 FROM group_members
                                 WHERE group_id = $1 AND user_id = $2 AND removed_at IS NULL)`,
            [groupId, t.id, actor.userId],
          )
        : await client.query(
            `UPDATE group_members SET removed_at = now(), removed_by = $3
              WHERE group_id = $1 AND user_id = $2 AND removed_at IS NULL`,
            [groupId, t.id, actor.userId],
          );
      if (r.rowCount === 0) return false;
      await announce(client, groupId, {
        type: member ? 'group_member_added' : 'group_member_removed',
        groupId,
        userId: t.id,
        displayName: t.display_name,
        by: 'administrator',
      });
      await this.audit.record(
        {
          action: member ? 'groups.add_member' : 'groups.remove_member',
          actor: { userId: actor.userId },
          target: { userId: t.id, groupId },
          ip,
        },
        client,
      );
      return true;
    });
    if (changed) await this.nudge([...new Set([...before, t.id])]);
    return { member, changed };
  }

  // Archiving closes a group: nothing more can be sent, and members stop
  // seeing each other through it. Reopening brings it back as it was.
  async setArchived(actor, groupId, archived, ip) {
    const g = await this.load(groupId);
    if (Boolean(g.archived_at) === archived) return this.detail(groupId);
    await this.db.transaction(async (client) => {
      await client.query(
        `UPDATE groups SET archived_at = ${archived ? 'now()' : 'NULL'} WHERE id = $1`,
        [groupId],
      );
      await announce(client, groupId, {
        type: archived ? 'group_archived' : 'group_reopened',
        groupId,
      });
      await this.audit.record(
        {
          action: archived ? 'groups.archive' : 'groups.reopen',
          actor: { userId: actor.userId },
          target: { groupId },
          ip,
        },
        client,
      );
    });
    await this.nudge(await this.liveMembers(groupId));
    return this.detail(groupId);
  }

  // ---------------------------------------------------------------- helpers

  async load(groupId) {
    if (!isUuid(groupId)) throw new NotFoundException();
    const { rows } = await this.db.query('SELECT * FROM groups WHERE id = $1', [
      groupId,
    ]);
    if (!rows[0]) throw new NotFoundException();
    return rows[0];
  }

  async liveMembers(groupId) {
    const { rows } = await this.db.query(
      'SELECT user_id FROM group_members WHERE group_id = $1 AND removed_at IS NULL',
      [groupId],
    );
    return rows.map((r) => r.user_id);
  }

  // Tell each affected person's open apps to pull (the system notice is the
  // record; this only makes it arrive at once). Each nudge goes from the
  // person to themselves, so delivery never depends on the operator.
  async nudge(userIds) {
    for (const id of userIds) {
      try {
        await this.fanout.publish({
          type: 'inbox',
          senderUserId: id,
          recipientUserIds: [id],
          payload: {},
        });
      } catch (err) {
        this.logger.warn(`nudge not published: ${err.message}`);
      }
    }
  }
}

function groupRow(g) {
  return {
    groupId: g.id,
    name: g.name,
    description: g.description,
    createdAt: g.created_at,
    archivedAt: g.archived_at,
    members: Number(g.members ?? 0),
  };
}

function blankToNull(s) {
  if (s === undefined || s === null) return null;
  const t = String(s).trim();
  if (t.length > 500)
    throw new BadRequestException(['description is at most 500 characters']);
  return t.length ? t : null;
}
