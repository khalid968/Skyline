import {
  Injectable,
  Dependencies,
  BadRequestException,
  ConflictException,
  ForbiddenException,
  NotFoundException,
  Logger,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { DatabaseService } from '../../database/database.service';
import { AuditService } from '../audit/audit.service';
import { FanoutService } from '../websocket/fanout.service';
import { ConnectionRegistry } from '../websocket/connection-registry';
import { issueActivationCode } from '../auth/activation-codes';
import { hashPassword } from '../auth/admin-auth.service';
import { generateTemporaryPassword } from '../auth/auth-crypto';
import { isUuid } from '../../common/uuid';
import {
  loadTarget,
  assertCanManage,
  assertCanAssignRole,
} from './admin-policy';

const OPERATOR_ROLES = new Set(['admin', 'moderator']);

// Everything the dashboard does to people's accounts. Each change runs in ONE
// transaction together with its audit entry, so there is never a change without
// a record or a record without a change.
@Injectable()
@Dependencies(
  DatabaseService,
  ConfigService,
  AuditService,
  FanoutService,
  ConnectionRegistry,
)
export class AdminUsersService {
  constructor(db, config, audit, fanout, registry) {
    this.db = db;
    this.audit = audit;
    this.fanout = fanout;
    this.registry = registry;
    this.pepper = Buffer.from(config.get('auth.tokenPepper'), 'utf8');
    this.logger = new Logger('AdminUsers');
  }

  // ------------------------------------------------------------------ reads

  async list({ q, includeDeleted }) {
    const search =
      typeof q === 'string' && q.trim() ? `%${q.trim().toLowerCase()}%` : null;
    const { rows } = await this.db.query(
      `SELECT u.id, u.username::text AS username, u.display_name, u.role_key, u.status,
              u.is_owner, u.created_at,
              (SELECT count(*)::int FROM devices d WHERE d.user_id = u.id AND d.revoked_at IS NULL) AS devices,
              (SELECT count(*)::int FROM contact_links l
                 WHERE l.revoked_at IS NULL AND u.id IN (l.user_a_id, l.user_b_id)) AS contacts,
              (SELECT max(d.last_seen_at) FROM devices d WHERE d.user_id = u.id) AS last_seen_at,
              EXISTS (SELECT 1 FROM activation_codes a
                       WHERE a.user_id = u.id AND a.redeemed_at IS NULL
                         AND a.revoked_at IS NULL AND a.expires_at > now()) AS has_live_code
         FROM users u
        WHERE ($1::text IS NULL OR lower(u.username::text) LIKE $1 OR lower(u.display_name) LIKE $1)
          AND ($2::boolean OR u.status <> 'deleted')
        ORDER BY u.is_owner DESC, u.display_name`,
      [search, !!includeDeleted],
    );
    return rows.map(userRow);
  }

  async detail(userId) {
    const t = await loadTarget(this.db, userId, { allowDeleted: true });
    const [devices, codes, contacts] = await Promise.all([
      this.db.query(
        `SELECT id, name, platform, created_at, last_seen_at, revoked_at
           FROM devices WHERE user_id = $1 ORDER BY revoked_at NULLS FIRST, created_at DESC`,
        [t.id],
      ),
      this.db.query(
        `SELECT a.id, a.created_at, a.expires_at, a.redeemed_at, a.revoked_at, d.name AS device_name
           FROM activation_codes a LEFT JOIN devices d ON d.id = a.redeemed_by_device_id
          WHERE a.user_id = $1 ORDER BY a.created_at DESC LIMIT 10`,
        [t.id],
      ),
      this.db.query(
        `SELECT count(*)::int AS n FROM contact_links
          WHERE revoked_at IS NULL AND $1 IN (user_a_id, user_b_id)`,
        [t.id],
      ),
    ]);
    return {
      userId: t.id,
      username: t.username,
      displayName: t.display_name,
      role: t.role_key,
      status: t.status,
      isOwner: t.is_owner,
      contacts: contacts.rows[0].n,
      devices: devices.rows.map(deviceRow),
      // The code itself is never stored, so there is nothing here to leak; only
      // what happened to it.
      codes: codes.rows.map((c) => ({
        codeId: c.id,
        issuedAt: c.created_at,
        expiresAt: c.expires_at,
        state: c.redeemed_at
          ? 'spent'
          : c.revoked_at
            ? 'revoked'
            : new Date(c.expires_at) < new Date()
              ? 'expired'
              : 'live',
        redeemedAt: c.redeemed_at,
        redeemedOn: c.device_name,
      })),
    };
  }

  // The whole directory as seen from one person, each entry marked linked or
  // not: what the contact-graph editor shows. Deleted accounts are left out.
  async contactsOf(userId) {
    const t = await loadTarget(this.db, userId);
    const { rows } = await this.db.query(
      `SELECT u.id, u.username::text AS username, u.display_name, u.role_key, u.status,
              are_linked($1, u.id) AS linked
         FROM users u
        WHERE u.id <> $1 AND u.status <> 'deleted'
        ORDER BY u.display_name`,
      [t.id],
    );
    return rows.map((r) => ({
      userId: r.id,
      username: r.username,
      displayName: r.display_name,
      role: r.role_key,
      status: r.status,
      linked: r.linked,
    }));
  }

  // ---------------------------------------------------------------- create

  // A new person: pending account, their first activation code, optionally
  // their first contacts, and (for an operator) a temporary dashboard password.
  // The code and the password are returned ONCE and never stored.
  async create(actor, { username, displayName, role, contactIds = [] }, ip) {
    if (role === 'admin' && !actor.isOwner) throw new ForbiddenException();

    const out = await this.db.transaction(async (client) => {
      let user;
      try {
        ({
          rows: [user],
        } = await client.query(
          // A member stays pending until their first device activates. An
          // operator is active at once: their dashboard password is already a
          // credential, and dashboard access must not wait on a phone.
          `INSERT INTO users (username, display_name, role_key, status, created_by)
           VALUES ($1, $2, $3, $5::user_status, $4)
           RETURNING id, username::text AS username, display_name, role_key, status, is_owner`,
          [
            username,
            displayName,
            role,
            actor.userId,
            OPERATOR_ROLES.has(role) ? 'active' : 'pending',
          ],
        ));
      } catch (err) {
        throw friendlyUserError(err);
      }

      const linked = [];
      for (const other of new Set(contactIds)) {
        if (!isUuid(other) || other === user.id) continue;
        const ok = await client.query(
          `SELECT 1 FROM users WHERE id = $1 AND status <> 'deleted'`,
          [other],
        );
        if (ok.rowCount === 0)
          throw new BadRequestException([
            'one of the chosen contacts does not exist',
          ]);
        await grantLink(client, user.id, other, actor.userId);
        linked.push(other);
      }

      let temporaryPassword;
      if (OPERATOR_ROLES.has(role))
        temporaryPassword = await this.setTemporaryPassword(client, user.id);

      const code = await issueActivationCode(client, {
        pepper: this.pepper,
        userId: user.id,
        issuedBy: actor.userId,
        audit: this.audit,
      });
      await this.audit.record(
        {
          action: 'users.create',
          actor: { userId: actor.userId },
          target: { userId: user.id },
          ip,
          detail: { role, initialContacts: linked.length, via: 'dashboard' },
        },
        client,
      );
      return { user, code, temporaryPassword, linkedCount: linked.length };
    });

    return {
      user: userRow({ ...out.user, devices: 0, contacts: out.linkedCount }),
      activationCode: out.code.code,
      activationCodeExpiresAt: out.code.expiresAt,
      ...(out.temporaryPassword
        ? { temporaryPassword: out.temporaryPassword }
        : {}),
    };
  }

  // ---------------------------------------------------------------- rename

  // Renaming is announced in every conversation the person is in, and never
  // touches their keys, so a rename cannot quietly impersonate someone
  // (decisions.md, locked). Operators may rename themselves.
  async rename(actor, userId, { displayName, username }, ip) {
    if (displayName === undefined && username === undefined) {
      throw new BadRequestException(['nothing to change']);
    }
    const t = await loadTarget(this.db, userId);
    assertCanManage(actor, t, { self: true });

    const next = {
      displayName: displayName !== undefined ? displayName : t.display_name,
      username: username !== undefined ? username : t.username,
    };
    if (next.displayName === t.display_name && next.username === t.username) {
      return this.detail(t.id);
    }

    await this.db.transaction(async (client) => {
      try {
        await client.query(
          'UPDATE users SET display_name = $2, username = $3 WHERE id = $1',
          [t.id, next.displayName, next.username],
        );
      } catch (err) {
        throw friendlyUserError(err);
      }

      const event = {
        type: 'user_renamed',
        userId: t.id,
        from: { displayName: t.display_name, username: t.username },
        to: next,
        by: 'administrator',
      };
      const announced = await client.query(
        `INSERT INTO messages (chat_id, kind, system_event)
         SELECT c.id, 'system', $2::jsonb
           FROM chats c
          WHERE (c.kind = 'direct' AND $1 IN (c.user_a_id, c.user_b_id))
             OR (c.kind = 'group' AND c.group_id IN (
                  SELECT group_id FROM group_members WHERE user_id = $1 AND removed_at IS NULL))`,
        [t.id, JSON.stringify(event)],
      );

      await this.audit.record(
        {
          action: 'users.rename',
          actor: { userId: actor.userId },
          target: { userId: t.id },
          ip,
          detail: {
            from: event.from,
            to: event.to,
            announcedInChats: announced.rowCount,
          },
        },
        client,
      );
    });

    await this.notifyContacts(t.id, 'user.renamed', { userId: t.id, ...next });
    return this.detail(t.id);
  }

  // ---------------------------------------------------------------- status

  async suspend(actor, userId, ip) {
    const t = await loadTarget(this.db, userId);
    assertCanManage(actor, t);
    if (t.status === 'suspended') return this.detail(t.id);

    await this.db.transaction(async (client) => {
      try {
        await client.query(
          `UPDATE users SET status = 'suspended', suspended_at = now() WHERE id = $1`,
          [t.id],
        );
      } catch (err) {
        throw friendlyUserError(err); // the owner trigger, as a last line
      }
      await this.audit.record(
        {
          action: 'users.suspend',
          actor: { userId: actor.userId },
          target: { userId: t.id },
          ip,
        },
        client,
      );
    });
    // Other instances stop delivering at once (FanoutService re-checks) and
    // their sweep closes the socket; this closes it here immediately.
    this.registry.disconnectUser(t.id, 1008, 'suspended');
    return this.detail(t.id);
  }

  async reinstate(actor, userId, ip) {
    const t = await loadTarget(this.db, userId);
    assertCanManage(actor, t);
    if (t.status !== 'suspended') throw new ConflictException();

    await this.db.transaction(async (client) => {
      // A reinstated account that never activated goes back to pending.
      await client.query(
        `UPDATE users
            SET status = CASE WHEN EXISTS (SELECT 1 FROM devices WHERE user_id = $1) THEN 'active' ELSE 'pending' END::user_status,
                suspended_at = NULL
          WHERE id = $1`,
        [t.id],
      );
      await this.audit.record(
        {
          action: 'users.reinstate',
          actor: { userId: actor.userId },
          target: { userId: t.id },
          ip,
        },
        client,
      );
    });
    return this.detail(t.id);
  }

  async setRole(actor, userId, role, ip) {
    const t = await loadTarget(this.db, userId);
    assertCanAssignRole(actor, t, role);
    if (t.role_key === role) return { user: await this.detail(t.id) };

    const temporaryPassword = await this.db.transaction(async (client) => {
      try {
        await client.query('UPDATE users SET role_key = $2 WHERE id = $1', [
          t.id,
          role,
        ]);
      } catch (err) {
        throw friendlyUserError(err);
      }
      // Promoted to operator without a dashboard password yet: give them one.
      let temp;
      if (OPERATOR_ROLES.has(role)) {
        const has = await client.query(
          'SELECT 1 FROM admin_credentials WHERE user_id = $1',
          [t.id],
        );
        if (has.rowCount === 0)
          temp = await this.setTemporaryPassword(client, t.id);
        // A pending member promoted to operator can sign in to the dashboard now.
        await client.query(
          `UPDATE users SET status = 'active' WHERE id = $1 AND status = 'pending'`,
          [t.id],
        );
      } else {
        // Demoted: any open dashboard session ends now.
        await client.query(
          'UPDATE admin_sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL',
          [t.id],
        );
      }
      await this.audit.record(
        {
          action: 'users.role',
          actor: { userId: actor.userId },
          target: { userId: t.id },
          ip,
          detail: { from: t.role_key, to: role },
        },
        client,
      );
      return temp;
    });

    return {
      user: await this.detail(t.id),
      ...(temporaryPassword ? { temporaryPassword } : {}),
    };
  }

  // Soft delete (decisions.md: nothing is hard-deleted). Everything that lets
  // the person in or lets anyone reach them is revoked; the username stays burned.
  async remove(actor, userId, ip) {
    const t = await loadTarget(this.db, userId);
    assertCanManage(actor, t);

    await this.db.transaction(async (client) => {
      try {
        await client.query(
          `UPDATE users SET status = 'deleted', deleted_at = now() WHERE id = $1`,
          [t.id],
        );
      } catch (err) {
        throw friendlyUserError(err);
      }
      await client.query(
        `UPDATE devices SET revoked_at = now(), revoked_by = $2 WHERE user_id = $1 AND revoked_at IS NULL`,
        [t.id, actor.userId],
      );
      await client.query(
        `UPDATE device_sessions SET revoked_at = now()
          WHERE revoked_at IS NULL AND device_id IN (SELECT id FROM devices WHERE user_id = $1)`,
        [t.id],
      );
      await client.query(
        `UPDATE activation_codes SET revoked_at = now(), revoked_by = $2
          WHERE user_id = $1 AND redeemed_at IS NULL AND revoked_at IS NULL`,
        [t.id, actor.userId],
      );
      const links = await client.query(
        `UPDATE contact_links SET revoked_at = now(), revoked_by = $2
          WHERE revoked_at IS NULL AND $1 IN (user_a_id, user_b_id)`,
        [t.id, actor.userId],
      );
      await client.query(
        `UPDATE group_members SET removed_at = now(), removed_by = $2 WHERE user_id = $1 AND removed_at IS NULL`,
        [t.id, actor.userId],
      );
      await client.query(
        'UPDATE admin_sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL',
        [t.id],
      );
      await this.audit.record(
        {
          action: 'users.delete',
          actor: { userId: actor.userId },
          target: { userId: t.id },
          ip,
          detail: { linksRevoked: links.rowCount },
        },
        client,
      );
    });
    this.registry.disconnectUser(t.id, 1008, 'deleted');
  }

  // ------------------------------------------------------------------ codes

  async issueCode(actor, userId, ip) {
    const t = await loadTarget(this.db, userId);
    assertCanManage(actor, t);
    if (!['pending', 'active'].includes(t.status)) {
      throw new BadRequestException([
        'reinstate this account before issuing a code',
      ]);
    }
    const code = await this.db.transaction((client) =>
      issueActivationCode(client, {
        pepper: this.pepper,
        userId: t.id,
        issuedBy: actor.userId,
        audit: this.audit,
      }),
    );
    void ip;
    return {
      activationCode: code.code,
      activationCodeExpiresAt: code.expiresAt,
    };
  }

  async revokeCode(actor, userId, ip) {
    const t = await loadTarget(this.db, userId);
    assertCanManage(actor, t);
    await this.db.transaction(async (client) => {
      const r = await client.query(
        `UPDATE activation_codes SET revoked_at = now(), revoked_by = $2
          WHERE user_id = $1 AND redeemed_at IS NULL AND revoked_at IS NULL
          RETURNING id`,
        [t.id, actor.userId],
      );
      if (r.rowCount > 0) {
        await this.audit.record(
          {
            action: 'codes.revoke',
            actor: { userId: actor.userId },
            target: { userId: t.id },
            ip,
            detail: { codeId: r.rows[0].id },
          },
          client,
        );
      }
    });
  }

  // ------------------------------------------------------- operator resets

  // The owner (or an admin, for a moderator) gets a locked-out operator back
  // in: a new temporary password, optionally two-factor switched off, and every
  // open dashboard session of theirs ended. There is no self-service reset.
  async resetSignIn(actor, userId, { resetTwoFactor }, ip) {
    const t = await loadTarget(this.db, userId);
    assertCanManage(actor, t);
    if (!OPERATOR_ROLES.has(t.role_key)) throw new NotFoundException();

    const temporaryPassword = await this.db.transaction(async (client) => {
      const temp = await this.setTemporaryPassword(client, t.id);
      if (resetTwoFactor) {
        await client.query(
          `UPDATE admin_credentials SET totp_enabled_at = NULL, totp_secret_enc = NULL, totp_last_step = NULL
            WHERE user_id = $1`,
          [t.id],
        );
      }
      await client.query(
        'UPDATE admin_sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL',
        [t.id],
      );
      await this.audit.record(
        {
          action: 'admin_auth.reset',
          actor: { userId: actor.userId },
          target: { userId: t.id },
          ip,
          detail: { twoFactorCleared: !!resetTwoFactor },
        },
        client,
      );
      return temp;
    });
    return { temporaryPassword };
  }

  async setTemporaryPassword(client, userId) {
    const temp = generateTemporaryPassword();
    await client.query(
      `INSERT INTO admin_credentials (user_id, password_hash, must_change_password)
       VALUES ($1, $2, true)
       ON CONFLICT (user_id) DO UPDATE
         SET password_hash = EXCLUDED.password_hash,
             password_changed_at = now(),
             must_change_password = true`,
      [userId, await hashPassword(temp)],
    );
    return temp;
  }

  // ---------------------------------------------------------- contact links

  async setLink(actor, { userId, otherUserId, linked }, ip) {
    if (userId === otherUserId)
      throw new BadRequestException([
        'a person cannot be linked to themselves',
      ]);
    const a = await loadTarget(this.db, userId);
    const b = await loadTarget(this.db, otherUserId);

    const changed = await this.db.transaction(async (client) => {
      const did = linked
        ? await grantLink(client, a.id, b.id, actor.userId)
        : await revokeLink(client, a.id, b.id, actor.userId);
      if (did) {
        await this.audit.record(
          {
            action: linked ? 'contacts.grant' : 'contacts.revoke',
            actor: { userId: actor.userId },
            target: { userId: a.id },
            ip,
            detail: { otherUserId: b.id },
          },
          client,
        );
      }
      return did;
    });
    // Revocation needs nothing more: delivery re-checks the graph on every
    // event, and every request re-checks it too.
    return { linked, changed };
  }

  // --------------------------------------------------------------- devices

  async listDevices({ userId }) {
    if (userId !== undefined && !isUuid(userId)) throw new NotFoundException();
    const { rows } = await this.db.query(
      `SELECT d.id, d.name, d.platform, d.created_at, d.last_seen_at, d.revoked_at,
              u.id AS user_id, u.display_name, u.username::text AS username
         FROM devices d JOIN users u ON u.id = d.user_id
        WHERE d.revoked_at IS NULL
          AND ($1::uuid IS NULL OR d.user_id = $1)
        ORDER BY u.display_name, d.created_at`,
      [userId ?? null],
    );
    return rows.map((d) => ({
      ...deviceRow(d),
      userId: d.user_id,
      displayName: d.display_name,
      username: d.username,
    }));
  }

  // Signs the device out now and for good; coming back needs a new code.
  // Messages already on the device stay there: nothing can reach into a phone.
  async revokeDevice(actor, deviceId, ip) {
    if (!isUuid(deviceId)) throw new NotFoundException();
    const { rows } = await this.db.query(
      'SELECT id, user_id FROM devices WHERE id = $1 AND revoked_at IS NULL',
      [deviceId],
    );
    if (!rows[0]) throw new NotFoundException();
    const owner = await loadTarget(this.db, rows[0].user_id, {
      allowDeleted: true,
    });
    assertCanManage(actor, owner, { self: true });

    await this.db.transaction(async (client) => {
      await client.query(
        'UPDATE devices SET revoked_at = now(), revoked_by = $2 WHERE id = $1 AND revoked_at IS NULL',
        [deviceId, actor.userId],
      );
      await client.query(
        'UPDATE device_sessions SET revoked_at = now() WHERE device_id = $1 AND revoked_at IS NULL',
        [deviceId],
      );
      await this.audit.record(
        {
          action: 'devices.revoke',
          actor: { userId: actor.userId },
          target: { userId: owner.id, deviceId },
          ip,
          detail: { by: 'administrator' },
        },
        client,
      );
    });
    this.registry.disconnectDevice(deviceId, 1008, 'revoked');
  }

  // ---------------------------------------------------------------- helpers

  // Tell the person's contacts, over the live socket, so an open app updates
  // the name straight away. Best effort: the system message is the record.
  async notifyContacts(userId, type, payload) {
    try {
      const { rows } = await this.db.query(
        'SELECT user_id FROM visible_user_ids($1)',
        [userId],
      );
      const recipients = rows.map((r) => r.user_id).slice(0, 1000);
      if (recipients.length > 0) {
        await this.fanout.publish({
          type,
          senderUserId: userId,
          recipientUserIds: recipients,
          payload,
        });
      }
    } catch (err) {
      this.logger.warn(`could not notify contacts: ${err.message}`);
    }
  }
}

async function grantLink(client, a, b, by) {
  const [lo, hi] = a < b ? [a, b] : [b, a];
  const r = await client.query(
    `INSERT INTO contact_links (user_a_id, user_b_id, created_by)
     SELECT $1, $2, $3
      WHERE NOT are_linked($1, $2)`,
    [lo, hi, by],
  );
  return r.rowCount > 0;
}

async function revokeLink(client, a, b, by) {
  const [lo, hi] = a < b ? [a, b] : [b, a];
  const r = await client.query(
    `UPDATE contact_links SET revoked_at = now(), revoked_by = $3
      WHERE user_a_id = $1 AND user_b_id = $2 AND revoked_at IS NULL`,
    [lo, hi, by],
  );
  return r.rowCount > 0;
}

function userRow(r) {
  return {
    userId: r.id,
    username: r.username,
    displayName: r.display_name,
    role: r.role_key,
    status: r.status,
    isOwner: r.is_owner,
    devices: r.devices,
    contacts: r.contacts,
    lastSeenAt: r.last_seen_at || null,
    hasLiveCode: r.has_live_code || false,
    createdAt: r.created_at,
  };
}

function deviceRow(d) {
  return {
    deviceId: d.id,
    name: d.name,
    platform: d.platform,
    activatedAt: d.created_at,
    lastSeenAt: d.last_seen_at,
    revokedAt: d.revoked_at,
  };
}

// Database refusals that are the operator's own input, turned into a 400 with a
// readable reason (the exception filter passes 400 message LISTS through).
function friendlyUserError(err) {
  if (err && err.code === '23505' && /username/.test(err.constraint || '')) {
    return new BadRequestException([
      'that username is taken, or was used before and cannot be reused',
    ]);
  }
  if (
    err &&
    err.code === '23514' &&
    err.constraint === 'users_username_format'
  ) {
    return new BadRequestException(['that username is not allowed']);
  }
  if (err && err.code === '23000' && /owner/.test(err.message || '')) {
    return new ForbiddenException();
  }
  return err;
}
