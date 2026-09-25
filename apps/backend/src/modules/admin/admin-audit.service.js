import { Injectable, Dependencies } from '@nestjs/common';
import { DatabaseService } from '../../database/database.service';

const PAGE = 50;
const CSV_MAX = 10000;

// Board 38's filters, by action prefix.
export const AUDIT_CATEGORIES = {
  links: ['contacts.%'],
  groups: ['groups.%'],
  accounts: ['users.%', 'codes.%', 'devices.%'],
  signins: ['admin_auth.%', 'sessions.%'],
  automatic: ['abuse.%', 'alerts.%'],
};

// The audit log viewer (board 38): owner and admins only (audit.read). The log
// itself is append-only at the database (migration 008); this only reads it.
// It records who did what to whom, never content: there is none to record.
@Injectable()
@Dependencies(DatabaseService)
export class AdminAuditService {
  constructor(db) {
    this.db = db;
  }

  async list({ category, q, before, limit = PAGE }) {
    const size = Math.min(Math.max(1, Number(limit) || PAGE), 200);
    const rows = await this.query({ category, q, before, limit: size + 1 });
    const more = rows.length > size;
    const entries = rows.slice(0, size).map(entry);
    return { entries, next: more ? entries[entries.length - 1].id : null };
  }

  async csv({ category, q }) {
    const rows = (await this.query({ category, q, limit: CSV_MAX })).map(entry);
    const header = ['time', 'action', 'by', 'by_username', 'about', 'about_username', 'group', 'device', 'address', 'details'];
    const lines = rows.map((e) => [
      new Date(e.at).toISOString(), e.action,
      // No actor: Skyline itself for automatic actions, else nobody signed in.
      e.actor?.displayName ?? (e.action.startsWith('abuse.') ? 'Skyline' : 'not signed in'), e.actor?.username ?? '',
      [e.target?.displayName, e.other?.displayName].filter(Boolean).join(' + '), e.target?.username ?? '',
      e.group?.name ?? '', e.device?.name ?? '', e.ip ?? '',
      JSON.stringify(e.detail),
    ].map(csvCell).join(','));
    return [header.join(','), ...lines].join('\r\n') + '\r\n';
  }

  async query({ category, q, before, limit }) {
    const params = [];
    const where = [];
    const patterns = AUDIT_CATEGORIES[category];
    if (patterns) {
      params.push(patterns);
      where.push(`a.action LIKE ANY ($${params.length}::text[])`);
    }
    if (typeof q === 'string' && q.trim()) {
      params.push(`%${q.trim().replace(/[\\%_]/g, (c) => `\\${c}`)}%`);
      const p = `$${params.length}`;
      where.push(`(a.actor_username ILIKE ${p} OR a.target_username ILIKE ${p}
                   OR au.display_name ILIKE ${p} OR tu.display_name ILIKE ${p})`);
    }
    if (before != null && /^\d+$/.test(String(before))) {
      params.push(String(before));
      where.push(`a.id < $${params.length}::bigint`);
    }
    params.push(limit);
    const { rows } = await this.db.query(
      `SELECT a.id, a.action, a.created_at, host(a.actor_ip) AS ip, a.detail,
              a.actor_user_id, a.actor_username, au.display_name AS actor_name,
              a.target_user_id, a.target_username, tu.display_name AS target_name,
              a.target_group_id, g.name AS group_name,
              a.target_device_id, d.name AS device_name,
              ou.display_name AS other_name, ou.username::text AS other_username
         FROM audit_log a
         LEFT JOIN users au ON au.id = a.actor_user_id
         LEFT JOIN users tu ON tu.id = a.target_user_id
         LEFT JOIN groups g ON g.id = a.target_group_id
         LEFT JOIN devices d ON d.id = a.target_device_id
         -- A link names two people; the second is in the detail.
         LEFT JOIN users ou ON ou.id::text = a.detail->>'otherUserId'
        ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
        ORDER BY a.id DESC
        LIMIT $${params.length}`,
      params,
    );
    return rows;
  }
}

// Usernames are the snapshot taken when the entry was written; the display
// name is today's, for readability.
function entry(r) {
  return {
    id: String(r.id),
    at: r.created_at,
    action: r.action,
    actor: r.actor_user_id ? { userId: r.actor_user_id, username: r.actor_username, displayName: r.actor_name ?? r.actor_username } : null,
    target: r.target_user_id ? { userId: r.target_user_id, username: r.target_username, displayName: r.target_name ?? r.target_username } : null,
    group: r.target_group_id ? { groupId: r.target_group_id, name: r.group_name } : null,
    device: r.target_device_id ? { deviceId: r.target_device_id, name: r.device_name } : null,
    other: r.other_name ? { displayName: r.other_name, username: r.other_username } : null,
    ip: r.ip,
    detail: r.detail,
  };
}

// A cell a spreadsheet will not run: quoted, and a leading = + - @ neutralised.
export function csvCell(v) {
  let s = v == null ? '' : String(v);
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  return `"${s.replace(/"/g, '""')}"`;
}
