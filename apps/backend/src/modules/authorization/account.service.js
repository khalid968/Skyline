import { Injectable, Dependencies } from '@nestjs/common';
import { DatabaseService } from '../../database/database.service';
import { isUuid } from '../../common/uuid';

// Answers "is this caller still allowed to be here right now?". It hits the
// database on every call, deliberately and by the owner's decision: a cache
// would let a suspended user or a revoked device keep working until it
// expired, and revocation has to be immediate.
@Injectable()
@Dependencies(DatabaseService)
export class AccountService {
  constructor(db) {
    this.db = db;
  }

  // The account behind a user+device pair, or null. Null covers every reason
  // alike (unknown user, suspended, deleted, still pending, device revoked or
  // not theirs), so a caller can never learn which one it was.
  async loadActive(userId, deviceId) {
    if (!isUuid(userId) || !isUuid(deviceId)) return null;

    const { rows } = await this.db.query(
      `SELECT u.role_key
         FROM users u
         JOIN devices d ON d.user_id = u.id
        WHERE u.id = $1
          AND d.id = $2
          AND u.status = 'active'
          AND d.revoked_at IS NULL`,
      [userId, deviceId],
    );
    return rows[0] ? { userId, deviceId, role: rows[0].role_key } : null;
  }

  // Of these device ids, the ones whose device is not revoked and whose owner
  // is active. One batched query, used to sweep open WebSockets.
  async liveDeviceIds(deviceIds) {
    const ids = deviceIds.filter(isUuid);
    if (ids.length === 0) return new Set();

    const { rows } = await this.db.query(
      `SELECT d.id
         FROM devices d
         JOIN users u ON u.id = d.user_id
        WHERE d.id = ANY($1::uuid[])
          AND d.revoked_at IS NULL
          AND u.status = 'active'`,
      [ids],
    );
    return new Set(rows.map((r) => r.id));
  }

  async permissionsForRole(roleKey) {
    const { rows } = await this.db.query(
      'SELECT permission_key FROM role_permissions WHERE role_key = $1',
      [roleKey],
    );
    return new Set(rows.map((r) => r.permission_key));
  }
}
