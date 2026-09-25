import {
  Injectable,
  Dependencies,
  HttpException,
  HttpStatus,
  Logger,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { DatabaseService } from '../../database/database.service';
import { RedisService } from '../../redis/redis.module';
import {
  RateLimitService,
  enforceLimit,
} from '../../common/rate-limit/rate-limit';
import { AuditService } from '../audit/audit.service';

// Abuse detection (Phase 11, decisions.md 2026-09-26). It looks ONLY at counts
// and timing: how often a device sends, how many codes an address gets wrong.
// Skyline cannot see content, so nothing here ever could.
//
// When a rule trips, Skyline raises one alert (board 37) and, for most rules,
// applies an automatic limit that slows things down. It never suspends anyone:
// that is always an operator's decision. Every automatic limit is in the audit
// log with no actor ("Skyline"), and an admin can lift it early.
//
// Counters and active limits live in Redis (rate limiting is one of its three
// jobs); the alerts themselves are rows in Postgres.
export const RULES = {
  // A device sending far faster than a person types. Normal is under 40 in
  // five minutes; the send limit (120 a minute) is the hard ceiling.
  send_rate: {
    level: 'high', count: 150, windowSec: 300, limitSec: 1800,
    action: 'Slowed automatically: this device can send 1 message every 5 seconds',
  },
  // Albums are up to 10 files, so 60 starts in 10 minutes is far past normal.
  upload_rate: {
    level: 'medium', count: 60, windowSec: 600, limitSec: 1800,
    action: 'Slowed automatically: this device can upload one file at a time',
  },
  // Below the activation rate limit (10 per 15 minutes per address), so it
  // trips before an attacker simply waits the limit out.
  code_guessing: {
    level: 'high', count: 8, windowSec: 3600, limitSec: 3600,
    action: 'Blocked automatically: this address cannot try codes',
  },
  admin_password: {
    level: 'medium', count: 5, windowSec: 600, limitSec: 900,
    action: 'Sign-in to this dashboard account paused automatically',
  },
  // Devices only arrive with codes an operator issued: alert only.
  device_burst: {
    level: 'medium', count: 3, windowSec: 3600, limitSec: 0,
    action: 'No automatic action: devices only arrive with codes you issued',
  },
};

// While a device is slowed for sending: one message per this many seconds.
const SLOW_SEND = { limit: 1, windowSec: 5 };

@Injectable()
@Dependencies(RedisService, ConfigService, DatabaseService, AuditService, RateLimitService)
export class AbuseService {
  constructor(redis, config, db, audit, limiter) {
    this.redis = redis;
    this.db = db;
    this.audit = audit;
    this.limiter = limiter;
    this.prefix = config.get('rateLimit.prefix');
    // Tests raise every limit together (RATE_LIMIT_SCALE); thresholds follow,
    // so a test server's dozens of messages do not look like abuse.
    this.scale = config.get('rateLimit.scale');
    this.logger = new Logger('Abuse');
  }

  // ------------------------------------------------------------ hot paths

  // Before a message (one to one or group) is accepted from this device.
  async beforeSend(caller, res) {
    if (await this.isLimited('send_rate', caller.deviceId)) {
      await enforceLimit(this.limiter, `abuse-slow:send:${caller.deviceId}`, SLOW_SEND, res, this.logger);
    }
    const n = await this.count(`send:${caller.deviceId}`, RULES.send_rate.windowSec);
    if (n === this.threshold('send_rate')) {
      await this.raise('send_rate', {
        subjectKey: caller.deviceId, userId: caller.userId, deviceId: caller.deviceId,
        evidence: { messages: n, minutes: RULES.send_rate.windowSec / 60 },
      });
    }
  }

  // Before an upload starts. While slowed, a device may have only one upload
  // in progress (anything older than an hour counts as abandoned).
  async beforeUpload(caller, res) {
    if (await this.isLimited('upload_rate', caller.deviceId)) {
      const { rows } = await this.db.query(
        `SELECT 1 FROM attachments
          WHERE uploaded_by_device_id = $1 AND status = 'uploading'
            AND created_at > now() - interval '1 hour'
          LIMIT 1`,
        [caller.deviceId],
      );
      if (rows.length) this.tooMany(res, await this.ttl('upload_rate', caller.deviceId));
    }
    const n = await this.count(`upload:${caller.deviceId}`, RULES.upload_rate.windowSec);
    if (n === this.threshold('upload_rate')) {
      await this.raise('upload_rate', {
        subjectKey: caller.deviceId, userId: caller.userId, deviceId: caller.deviceId,
        evidence: { uploads: n, minutes: RULES.upload_rate.windowSec / 60 },
      });
    }
  }

  // Activation, before anything else: a blocked address is refused with 429.
  // That says nothing about any code, only that this address must wait.
  async assertMayActivate(ip, res) {
    if (ip && (await this.isLimited('code_guessing', ip))) {
      this.tooMany(res, await this.ttl('code_guessing', ip));
    }
  }

  async noteActivationFailure(ip) {
    if (!ip) return;
    const n = await this.count(`activate:${ip}`, RULES.code_guessing.windowSec);
    if (n === this.threshold('code_guessing')) {
      await this.raise('code_guessing', {
        subjectKey: ip, ip,
        evidence: { wrongAttempts: n, minutes: RULES.code_guessing.windowSec / 60, address: ip },
      });
    }
  }

  // After a device was activated: several new devices for one person in an
  // hour raise an alert, and nothing else.
  async noteDeviceActivated(userId) {
    const { rows } = await this.db.query(
      `SELECT count(*)::int AS n FROM devices
        WHERE user_id = $1 AND created_at > now() - make_interval(secs => $2)`,
      [userId, RULES.device_burst.windowSec],
    );
    const n = rows[0].n;
    if (n >= this.threshold('device_burst')) {
      await this.raise('device_burst', {
        subjectKey: userId, userId,
        evidence: { devices: n, minutes: RULES.device_burst.windowSec / 60 },
      });
    }
  }

  // Dashboard sign-in. A paused account answers exactly like a wrong
  // password (the caller makes sure of that), so a pause never reveals that
  // a username belongs to an operator.
  async signInPaused(userId) {
    return this.isLimited('admin_password', userId);
  }

  async noteAdminLoginFailure(userId, ip) {
    const n = await this.count(`admin-login:${userId}`, RULES.admin_password.windowSec);
    if (n === this.threshold('admin_password')) {
      await this.raise('admin_password', {
        subjectKey: userId, userId, ip,
        evidence: { wrongAttempts: n, minutes: RULES.admin_password.windowSec / 60 },
      });
    }
  }

  // ---------------------------------------------------- operator actions

  // Board 37 "Lift now": the limit ends at once. Returns false when there was
  // nothing to lift.
  async lift(alertId, actor, ip) {
    return this.db.transaction(async (client) => {
      const { rows } = await client.query(
        `UPDATE alerts SET lifted_at = now(), lifted_by = $2, updated_at = now()
          WHERE id = $1 AND lifted_at IS NULL AND reviewed_at IS NULL
            AND limit_until IS NOT NULL AND limit_until > now()
          RETURNING kind, subject_key, subject_user_id, subject_device_id`,
        [alertId, actor.userId],
      );
      const a = rows[0];
      if (!a) return false;
      await this.redis.client.del(this.limitKey(a.kind, a.subject_key));
      await this.audit.record(
        {
          action: 'alerts.lift',
          actor: { userId: actor.userId },
          target: { userId: a.subject_user_id ?? undefined, deviceId: a.subject_device_id ?? undefined },
          ip,
          detail: { kind: a.kind },
        },
        client,
      );
      return true;
    });
  }

  // ------------------------------------------------------------ internals

  threshold(kind) {
    return Math.max(1, Math.round(RULES[kind].count * this.scale));
  }

  key(...parts) {
    return `${this.prefix}:abuse:${parts.join(':')}`;
  }

  limitKey(kind, subject) {
    return this.key('limit', kind, subject);
  }

  async isLimited(kind, subject) {
    return (await this.redis.client.exists(this.limitKey(kind, subject))) === 1;
  }

  async ttl(kind, subject) {
    const ms = await this.redis.client.pttl(this.limitKey(kind, subject));
    return Math.max(1, Math.ceil(ms / 1000));
  }

  // A fixed-window counter, like the rate limiter's.
  async count(name, windowSec) {
    const full = this.key('count', name);
    const [[e1, n], [e2, ttl]] = await this.redis.client.multi().incr(full).pttl(full).exec();
    if (e1 || e2) throw e1 || e2;
    if (ttl < 0) await this.redis.client.pexpire(full, windowSec * 1000);
    return n;
  }

  tooMany(res, retryAfterSec) {
    if (res?.setHeader) res.setHeader('Retry-After', String(retryAfterSec));
    throw new HttpException('Too Many Requests', HttpStatus.TOO_MANY_REQUESTS);
  }

  // One open alert per kind and subject: a repeat updates it. The automatic
  // limit starts (or restarts) in Redis first, so it holds even if writing
  // the alert fails; that failure is logged, never shown to the caller.
  async raise(kind, { subjectKey, userId, deviceId, ip, evidence }) {
    const rule = RULES[kind];
    if (rule.limitSec > 0) {
      await this.redis.client.set(this.limitKey(kind, subjectKey), '1', 'EX', rule.limitSec);
    }
    try {
      await this.db.transaction(async (client) => {
        const { rows } = await client.query(
          `INSERT INTO alerts (kind, level, subject_key, subject_user_id, subject_device_id,
                               subject_ip, evidence, auto_action, limit_until)
           VALUES ($1, $2, $3, $4::uuid, $5::uuid, $6::inet, $7::jsonb, $8,
                   CASE WHEN $9::int > 0 THEN now() + make_interval(secs => $9::int) END)
           ON CONFLICT (kind, subject_key) WHERE reviewed_at IS NULL DO UPDATE
             SET evidence = EXCLUDED.evidence, limit_until = EXCLUDED.limit_until,
                 lifted_at = NULL, lifted_by = NULL, updated_at = now()
           RETURNING id`,
          [kind, rule.level, subjectKey, userId ?? null, deviceId ?? null, ip ?? null,
           JSON.stringify(evidence), rule.action, rule.limitSec],
        );
        await this.audit.record(
          {
            action: rule.limitSec > 0 ? 'abuse.auto_limit' : 'abuse.alert',
            target: { userId: userId ?? undefined, deviceId: deviceId ?? undefined },
            detail: { kind, alertId: rows[0].id, limitMinutes: rule.limitSec / 60, ...evidence },
          },
          client,
        );
      });
    } catch (err) {
      this.logger.error(`could not record a ${kind} alert: ${err.message}`);
    }
  }
}
