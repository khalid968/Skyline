import {
  Injectable,
  Dependencies,
  NotFoundException,
  BadRequestException,
} from '@nestjs/common';
import { DatabaseService } from '../../database/database.service';
import { AuditService } from '../audit/audit.service';
import { AbuseService } from '../abuse/abuse.service';
import { isUuid } from '../../common/uuid';
import { AdminUsersService } from './admin-users.service';

// Board 37: alerts raised by AbuseService, for the owner and admins
// (alerts.manage). An operator can lift an automatic limit early, and mark an
// alert reviewed, optionally suspending the person it is about. Suspending
// goes through AdminUsersService, so admin-policy's who-may-act-on-whom rules
// apply exactly as they do on the Users page.
@Injectable()
@Dependencies(DatabaseService, AuditService, AbuseService, AdminUsersService)
export class AdminAlertsService {
  constructor(db, audit, abuse, users) {
    this.db = db;
    this.audit = audit;
    this.abuse = abuse;
    this.users = users;
  }

  async list({ state }) {
    const reviewed = state === 'reviewed';
    const { rows } = await this.db.query(
      `SELECT a.*, host(a.subject_ip) AS ip,
              su.display_name AS subject_name, su.username::text AS subject_username,
              su.role_key AS subject_role, su.status AS subject_status, su.is_owner AS subject_owner,
              d.name AS device_name, d.platform AS device_platform,
              lu.display_name AS lifted_by_name, ru.display_name AS reviewed_by_name,
              (a.limit_until IS NOT NULL AND a.limit_until > now() AND a.lifted_at IS NULL) AS limit_active
         FROM alerts a
         LEFT JOIN users su ON su.id = a.subject_user_id
         LEFT JOIN devices d ON d.id = a.subject_device_id
         LEFT JOIN users lu ON lu.id = a.lifted_by
         LEFT JOIN users ru ON ru.id = a.reviewed_by
        WHERE ${reviewed ? 'a.reviewed_at IS NOT NULL' : 'a.reviewed_at IS NULL'}
        ORDER BY ${reviewed ? 'a.reviewed_at' : 'a.updated_at'} DESC
        LIMIT 100`,
    );
    const counts = await this.db.query(
      `SELECT count(*) FILTER (WHERE reviewed_at IS NULL)::int AS open,
              count(*) FILTER (WHERE reviewed_at IS NOT NULL)::int AS reviewed
         FROM alerts`,
    );
    return { alerts: rows.map(view), open: counts.rows[0].open, reviewed: counts.rows[0].reviewed };
  }

  async lift(actor, alertId, ip) {
    if (!isUuid(alertId) || !(await this.abuse.lift(alertId, actor, ip))) throw new NotFoundException();
    return this.one(alertId);
  }

  async review(actor, alertId, { suspend }, ip) {
    if (!isUuid(alertId)) throw new NotFoundException();
    const { rows } = await this.db.query(
      'SELECT subject_user_id, kind FROM alerts WHERE id = $1 AND reviewed_at IS NULL',
      [alertId],
    );
    const alert = rows[0];
    if (!alert) throw new NotFoundException();
    if (suspend) {
      if (!alert.subject_user_id) throw new BadRequestException(['This alert is not about a person']);
      // Policy-checked, audited and immediate (sockets closed), like the Users page.
      await this.users.suspend(actor, alert.subject_user_id, ip);
    }
    await this.db.transaction(async (client) => {
      const done = await client.query(
        `UPDATE alerts SET reviewed_at = now(), reviewed_by = $2, outcome = $3, updated_at = now()
          WHERE id = $1 AND reviewed_at IS NULL`,
        [alertId, actor.userId, suspend ? 'suspended' : 'none'],
      );
      if (done.rowCount === 0) throw new NotFoundException();
      await this.audit.record(
        {
          action: 'alerts.review',
          actor: { userId: actor.userId },
          target: { userId: alert.subject_user_id ?? undefined },
          ip,
          detail: { kind: alert.kind, outcome: suspend ? 'suspended' : 'none' },
        },
        client,
      );
    });
    return this.one(alertId);
  }

  async one(alertId) {
    const { rows } = await this.db.query(
      `SELECT a.*, host(a.subject_ip) AS ip,
              su.display_name AS subject_name, su.username::text AS subject_username,
              su.role_key AS subject_role, su.status AS subject_status, su.is_owner AS subject_owner,
              d.name AS device_name, d.platform AS device_platform,
              lu.display_name AS lifted_by_name, ru.display_name AS reviewed_by_name,
              (a.limit_until IS NOT NULL AND a.limit_until > now() AND a.lifted_at IS NULL) AS limit_active
         FROM alerts a
         LEFT JOIN users su ON su.id = a.subject_user_id
         LEFT JOIN devices d ON d.id = a.subject_device_id
         LEFT JOIN users lu ON lu.id = a.lifted_by
         LEFT JOIN users ru ON ru.id = a.reviewed_by
        WHERE a.id = $1`,
      [alertId],
    );
    if (!rows[0]) throw new NotFoundException();
    return view(rows[0]);
  }
}

function view(r) {
  return {
    alertId: r.id,
    kind: r.kind,
    level: r.level,
    subject: r.subject_user_id
      ? {
          userId: r.subject_user_id,
          displayName: r.subject_name,
          username: r.subject_username,
          role: r.subject_role,
          status: r.subject_status,
          isOwner: r.subject_owner === true,
        }
      : null,
    device: r.subject_device_id ? { deviceId: r.subject_device_id, name: r.device_name, platform: r.device_platform } : null,
    ip: r.ip,
    evidence: r.evidence,
    autoAction: r.auto_action,
    limitUntil: r.limit_until,
    limitActive: r.limit_active,
    liftedAt: r.lifted_at,
    liftedBy: r.lifted_by_name ?? null,
    reviewedAt: r.reviewed_at,
    reviewedBy: r.reviewed_by_name ?? null,
    outcome: r.outcome,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
  };
}
