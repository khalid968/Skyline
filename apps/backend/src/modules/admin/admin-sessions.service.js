import { Injectable, Dependencies, NotFoundException } from '@nestjs/common';
import { DatabaseService } from '../../database/database.service';
import { AuditService } from '../audit/audit.service';
import { LIFETIME } from '../authorization/session.service';
import { isUuid } from '../../common/uuid';

// Board 39: dashboard sessions. Every operator sees and can end their own; the
// owner sees and can end everyone's (owner decision 2026-09-26). The session
// in use is never ended from here (that is "Sign out"). Anything the caller
// may not touch answers 404, the same as a session that does not exist.
//
// Ending a session takes effect on its next request: resolveDashboard checks
// revoked_at in Postgres every time, nothing is cached.
@Injectable()
@Dependencies(DatabaseService, AuditService)
export class AdminSessionsService {
  constructor(db, audit) {
    this.db = db;
    this.audit = audit;
  }

  async list(actor) {
    const { rows } = await this.db.query(
      `SELECT s.id, s.user_id, s.created_at, s.last_used_at, host(s.ip) AS ip, s.user_agent, s.two_factor,
              u.display_name, u.username::text AS username, u.role_key, u.is_owner,
              c.totp_enabled_at IS NOT NULL AS two_factor_on,
              -- An address this operator had never signed in from before.
              (s.ip IS NOT NULL AND NOT EXISTS (
                 SELECT 1 FROM admin_sessions p
                  WHERE p.user_id = s.user_id AND p.ip = s.ip AND p.created_at < s.created_at
                    AND p.state = 'active')) AS new_address,
              (SELECT count(*) FROM admin_sessions p WHERE p.user_id = s.user_id
                  AND p.created_at < s.created_at AND p.state = 'active') > 0 AS has_history
         FROM admin_sessions s
         JOIN users u ON u.id = s.user_id
         LEFT JOIN admin_credentials c ON c.user_id = u.id
        WHERE ${LIVE}
          AND ($1::boolean OR s.user_id = $2)
        ORDER BY u.is_owner DESC, u.display_name, s.last_used_at DESC`,
      [actor.isOwner === true, actor.userId, LIFETIME.dashboardIdleSec],
    );
    return rows.map((r) => ({
      sessionId: r.id,
      current: r.id === actor.sessionId,
      operator: {
        userId: r.user_id,
        displayName: r.display_name,
        username: r.username,
        role: r.role_key,
        isOwner: r.is_owner,
        twoFactorEnabled: r.two_factor_on,
      },
      ip: r.ip,
      userAgent: r.user_agent,
      usedTwoFactor: r.two_factor,
      // The very first session has no history to compare with.
      newAddress: r.new_address && r.has_history,
      signedInAt: r.created_at,
      lastActiveAt: r.last_used_at,
    }));
  }

  async revoke(actor, sessionId, ip) {
    if (!isUuid(sessionId) || sessionId === actor.sessionId) throw new NotFoundException();
    const { rows } = await this.db.query(
      `UPDATE admin_sessions s SET revoked_at = now()
        WHERE s.id = $4 AND ${LIVE} AND ($1::boolean OR s.user_id = $2)
        RETURNING s.user_id`,
      [actor.isOwner === true, actor.userId, LIFETIME.dashboardIdleSec, sessionId],
    );
    if (!rows[0]) throw new NotFoundException();
    await this.audit.record({
      action: 'admin_auth.session_revoke',
      actor: { userId: actor.userId },
      target: { userId: rows[0].user_id },
      ip,
    });
  }

  // The owner: every other session of every operator. Anyone else: their own
  // other sessions.
  async revokeOthers(actor, ip) {
    const { rows } = await this.db.query(
      `UPDATE admin_sessions s SET revoked_at = now()
        WHERE ${LIVE} AND s.id <> $4 AND ($1::boolean OR s.user_id = $2)
        RETURNING s.user_id`,
      [actor.isOwner === true, actor.userId, LIFETIME.dashboardIdleSec, actor.sessionId],
    );
    await this.audit.record({
      action: 'admin_auth.sessions_revoke_others',
      actor: { userId: actor.userId },
      ip,
      detail: { sessions: rows.length, everyone: actor.isOwner === true },
    });
    return { signedOut: rows.length };
  }
}

// A session that still works: active, not ended, not expired, not idle. The
// idle limit is parameter $3 in every query above.
const LIVE = `s.state = 'active' AND s.revoked_at IS NULL AND s.expires_at > now()
          AND s.last_used_at > now() - make_interval(secs => $3)`;
