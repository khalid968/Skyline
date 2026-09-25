import { isIP } from 'net';
import { Injectable, Dependencies } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { DatabaseService } from '../../database/database.service';
import { AuditService } from '../audit/audit.service';
import {
  TOKEN_PREFIX,
  hashToken,
  newToken,
  tokenKind,
  decodeFixed,
  verifyEd25519,
  signedMessage,
} from '../auth/auth-crypto';

export const LIFETIME = {
  deviceAccessSec: 15 * 60,
  deviceRefreshSec: 30 * 24 * 3600,
  dashboardAbsoluteSec: 12 * 3600,
  dashboardIdleSec: 60 * 60,
  mfaPendingSec: 5 * 60,
  // How far a device's clock may disagree with ours on a signed refresh.
  refreshClockSkewSec: 5 * 60,
};

// Every session and token in Skyline. Tokens are opaque random strings; only
// their keyed hashes are stored, and every lookup goes to Postgres, so revoking
// a session takes effect on the very next request (the no-caching rule).
@Injectable()
@Dependencies(DatabaseService, ConfigService, AuditService)
export class SessionService {
  constructor(db, config, audit) {
    this.db = db;
    this.audit = audit;
    this.pepper = Buffer.from(config.get('auth.tokenPepper'), 'utf8');
  }

  hash(token) {
    return hashToken(this.pepper, token);
  }

  // ---------------------------------------------------------------- devices

  // Called inside the activation transaction, with that transaction's client.
  async createDeviceSession(client, deviceId) {
    const access = newToken(TOKEN_PREFIX.deviceAccess);
    const refresh = newToken(TOKEN_PREFIX.deviceRefresh);
    const { rows } = await client.query(
      `INSERT INTO device_sessions
         (device_id, access_token_hash, access_expires_at, refresh_token_hash, expires_at)
       VALUES ($1, $2, now() + make_interval(secs => $3), $4, now() + make_interval(secs => $5))
       RETURNING id, access_expires_at, expires_at`,
      [
        deviceId,
        this.hash(access),
        LIFETIME.deviceAccessSec,
        this.hash(refresh),
        LIFETIME.deviceRefreshSec,
      ],
    );
    return tokenBundle(rows[0], access, refresh);
  }

  // Bearer access token -> { kind, userId, deviceId, sessionId }, or null. The
  // account's status is checked afterwards by AuthenticatedGuard.
  async resolveDeviceAccess(token) {
    if (tokenKind(token) !== 'deviceAccess') return null;
    const { rows } = await this.db.query(
      `SELECT s.id AS session_id, d.id AS device_id, d.user_id
         FROM device_sessions s
         JOIN devices d ON d.id = s.device_id
        WHERE s.access_token_hash = $1
          AND s.access_expires_at > now()
          AND s.expires_at > now()
          AND s.revoked_at IS NULL
          AND d.revoked_at IS NULL`,
      [this.hash(token)],
    );
    const r = rows[0];
    return r
      ? {
          kind: 'device',
          userId: r.user_id,
          deviceId: r.device_id,
          sessionId: r.session_id,
        }
      : null;
  }

  // Exchanges a refresh token for a new pair. The device must also sign
  // (timestamp, refresh token) with its registered Ed25519 key, so the refresh
  // token alone is worthless to a thief.
  //
  // Rotation: each refresh token works once. If an already-rotated token is
  // presented again, two parties hold it (the device and a thief) and there is
  // no way to tell which is which, so the whole session is revoked and the
  // device must be re-activated. Returns null for every failure alike.
  async refresh({ refreshToken, timestamp, signature }) {
    if (tokenKind(refreshToken) !== 'deviceRefresh') return null;
    const sig = decodeFixed(signature, 64);
    const ts = Number(timestamp);
    if (!sig || !Number.isInteger(ts)) return null;
    if (Math.abs(Date.now() / 1000 - ts) > LIFETIME.refreshClockSkewSec)
      return null;

    const h = this.hash(refreshToken);

    return this.db.transaction(async (client) => {
      const { rows } = await client.query(
        `SELECT s.id, s.device_id, d.signing_key, d.user_id
           FROM device_sessions s
           JOIN devices d ON d.id = s.device_id
           JOIN users u ON u.id = d.user_id
          WHERE s.refresh_token_hash = $1
            AND s.revoked_at IS NULL
            AND s.expires_at > now()
            AND d.revoked_at IS NULL
            AND u.status = 'active'
          FOR UPDATE OF s`,
        [h],
      );

      if (rows.length === 0) {
        await this.revokeOnReuse(client, h);
        return null;
      }

      const s = rows[0];
      if (
        !verifyEd25519(
          s.signing_key,
          signedMessage.refresh(ts, refreshToken),
          sig,
        )
      )
        return null;

      const access = newToken(TOKEN_PREFIX.deviceAccess);
      const refresh = newToken(TOKEN_PREFIX.deviceRefresh);
      const updated = await client.query(
        `UPDATE device_sessions
            SET previous_refresh_hash = refresh_token_hash,
                refresh_token_hash    = $2,
                access_token_hash     = $3,
                access_expires_at     = now() + make_interval(secs => $4),
                expires_at            = now() + make_interval(secs => $5),
                last_used_at          = now()
          WHERE id = $1
          RETURNING id, access_expires_at, expires_at`,
        [
          s.id,
          this.hash(refresh),
          this.hash(access),
          LIFETIME.deviceAccessSec,
          LIFETIME.deviceRefreshSec,
        ],
      );
      await client.query(
        'UPDATE devices SET last_seen_at = now() WHERE id = $1',
        [s.device_id],
      );
      return tokenBundle(updated.rows[0], access, refresh);
    });
  }

  async revokeOnReuse(client, refreshHash) {
    const { rows } = await client.query(
      `UPDATE device_sessions s
          SET revoked_at = now()
         FROM devices d
        WHERE s.previous_refresh_hash = $1
          AND s.revoked_at IS NULL
          AND d.id = s.device_id
        RETURNING s.id, s.device_id, d.user_id`,
      [refreshHash],
    );
    for (const r of rows) {
      await this.audit.record(
        {
          action: 'sessions.revoke',
          target: { userId: r.user_id, deviceId: r.device_id },
          detail: { reason: 'refresh_token_reused', session: r.id },
        },
        client,
      );
    }
  }

  async revokeDeviceSession(sessionId, client = this.db) {
    await client.query(
      'UPDATE device_sessions SET revoked_at = now() WHERE id = $1 AND revoked_at IS NULL',
      [sessionId],
    );
  }

  async revokeAllDeviceSessions(deviceId, client = this.db) {
    await client.query(
      'UPDATE device_sessions SET revoked_at = now() WHERE device_id = $1 AND revoked_at IS NULL',
      [deviceId],
    );
  }

  // -------------------------------------------------------------- dashboard

  // `meta` (board 39): the address and browser it signed in from, and
  // whether a two-factor code was used. Shown back to operators only.
  async createDashboardSession(userId, state = 'active', client = this.db, meta = {}) {
    const pending = state === 'pending_mfa';
    const token = newToken(
      pending ? TOKEN_PREFIX.mfaPending : TOKEN_PREFIX.dashboard,
    );
    const { rows } = await client.query(
      `INSERT INTO admin_sessions (user_id, token_hash, state, expires_at, ip, user_agent, two_factor)
       VALUES ($1, $2, $3, now() + make_interval(secs => $4), $5::inet, $6, $7)
       RETURNING id, expires_at`,
      [
        userId,
        this.hash(token),
        state,
        pending ? LIFETIME.mfaPendingSec : LIFETIME.dashboardAbsoluteSec,
        meta.ip && isIP(meta.ip) ? meta.ip : null,
        typeof meta.userAgent === 'string' ? meta.userAgent.slice(0, 300) : null,
        meta.twoFactor === true,
      ],
    );
    return { token, sessionId: rows[0].id, expiresAt: rows[0].expires_at };
  }

  // Bearer dashboard token -> { kind, userId, sessionId }, or null. Also slides
  // the idle timer, which is why this one query writes.
  async resolveDashboard(token) {
    if (tokenKind(token) !== 'dashboard') return null;
    const { rows } = await this.db.query(
      `UPDATE admin_sessions
          SET last_used_at = now()
        WHERE token_hash = $1
          AND state = 'active'
          AND revoked_at IS NULL
          AND expires_at > now()
          AND last_used_at > now() - make_interval(secs => $2)
        RETURNING id, user_id`,
      [this.hash(token), LIFETIME.dashboardIdleSec],
    );
    return rows[0]
      ? { kind: 'dashboard', userId: rows[0].user_id, sessionId: rows[0].id }
      : null;
  }

  // The half-signed-in state between a correct password and a correct 2FA code.
  // Claimed with FOR UPDATE so a code cannot be raced against itself.
  async findMfaPending(client, token) {
    if (tokenKind(token) !== 'mfaPending') return null;
    const { rows } = await client.query(
      `SELECT id, user_id FROM admin_sessions
        WHERE token_hash = $1 AND state = 'pending_mfa' AND revoked_at IS NULL AND expires_at > now()
        FOR UPDATE`,
      [this.hash(token)],
    );
    return rows[0] || null;
  }

  async revokeDashboardSession(sessionId, client = this.db) {
    await client.query(
      'UPDATE admin_sessions SET revoked_at = now() WHERE id = $1 AND revoked_at IS NULL',
      [sessionId],
    );
  }

  async revokeOtherDashboardSessions(userId, keepSessionId, client = this.db) {
    await client.query(
      `UPDATE admin_sessions SET revoked_at = now()
        WHERE user_id = $1 AND revoked_at IS NULL AND id IS DISTINCT FROM $2::uuid`,
      [userId, keepSessionId ?? null],
    );
  }
}

function tokenBundle(row, access, refresh) {
  return {
    sessionId: row.id,
    accessToken: access,
    accessExpiresAt: row.access_expires_at,
    refreshToken: refresh,
    refreshExpiresAt: row.expires_at,
  };
}
