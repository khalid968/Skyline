import net from 'net';
import fs from 'fs';
import crypto from 'crypto';
import { Injectable, Dependencies, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { DatabaseService } from '../../database/database.service';
import { RedisService } from '../../redis/redis.module';
import { StorageService } from '../media/storage.service';
import { ConnectionRegistry } from '../websocket/connection-registry';
import { MetricsService } from './metrics.service';
import pkg from '../../../package.json';

const PROBE_TIMEOUT_MS = 2000;

// Board 36: is every service up, and how much is Skyline used, in TOTALS.
// Nothing here is per person: no count of anyone's messages, no list of who
// talks to whom. The server could not count content anyway; it has none.
@Injectable()
@Dependencies(ConfigService, DatabaseService, RedisService, StorageService, ConnectionRegistry, MetricsService)
export class OverviewService {
  constructor(config, db, redis, storage, registry, metrics) {
    this.db = db;
    this.redis = redis;
    this.storage = storage;
    this.registry = registry;
    this.metrics = metrics;
    this.turnUrls = config.get('turn').urls;
    this.gitSha = (process.env.GIT_SHA || '').slice(0, 7);
    this.logger = new Logger('Overview');
  }

  async overview({ days }) {
    const [services, totals, perDay, storage] = await Promise.all([
      this.services(),
      this.totals(),
      this.perDay(days),
      this.storageUse(),
    ]);
    const m = this.metrics.snapshot();
    return {
      checkedAt: new Date().toISOString(),
      services,
      totals,
      perDay,
      storage,
      server: {
        version: this.gitSha ? `${pkg.version} · ${this.gitSha}` : pkg.version,
        uptimeSeconds: m.uptimeSeconds,
        requestsPerMinute: m.requestsPerMinute,
        errorsLastHour: m.errorsLastHour,
        p95Ms: m.p95Ms,
        memoryBytes: process.memoryUsage().rss,
      },
    };
  }

  // ------------------------------------------------------------- health

  async services() {
    const [database, redis, storage, relay] = await Promise.all([
      this.probe(() => this.db.ping()),
      this.probe(() => this.redis.ping()),
      this.probe(() => this.storage.ping()),
      this.probe(() => this.stunProbe()),
    ]);
    return [
      { id: 'server', ok: true, ms: 0 },
      { id: 'database', ...database },
      // Devices connected to THIS server instance (one instance in a
      // single-host deployment).
      { id: 'realtime', ...redis, connectedDevices: this.registry.byDevice.size },
      { id: 'storage', ...storage },
      { id: 'relay', ...relay },
    ];
  }

  // { ok, ms }. The reason for a failure goes to the log, not to the page.
  async probe(fn) {
    const start = Date.now();
    let timer;
    try {
      await Promise.race([
        fn(),
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error('timed out')), PROBE_TIMEOUT_MS);
        }),
      ]);
      return { ok: true, ms: Date.now() - start };
    } catch (err) {
      this.logger.warn(`health check failed: ${err.message}`);
      return { ok: false, ms: null };
    } finally {
      clearTimeout(timer);
    }
  }

  // The call relay answers a STUN binding request (over TCP, which needs no
  // credentials) at the first address devices are given.
  stunProbe() {
    const url = this.turnUrls[0] || '';
    const m = /^turns?:([^:?]+):?(\d+)?/.exec(url);
    if (!m) return Promise.reject(new Error('no relay configured'));
    const [host, port] = [m[1], Number(m[2] || 3478)];
    return new Promise((resolve, reject) => {
      const req = Buffer.alloc(20);
      req.writeUInt16BE(0x0001, 0); // binding request
      req.writeUInt16BE(0, 2);
      req.writeUInt32BE(0x2112a442, 4); // magic cookie
      crypto.randomBytes(12).copy(req, 8);
      const socket = net.connect(port, host, () => socket.write(req));
      socket.setTimeout(PROBE_TIMEOUT_MS);
      socket.once('data', (d) => {
        socket.destroy();
        if (d.length >= 20 && d.readUInt16BE(0) === 0x0101 && d.subarray(8, 20).equals(req.subarray(8, 20))) resolve();
        else reject(new Error('unexpected relay reply'));
      });
      socket.once('timeout', () => {
        socket.destroy();
        reject(new Error('relay timed out'));
      });
      socket.once('error', (err) => reject(err));
    });
  }

  // ------------------------------------------------------------- totals

  async totals() {
    const { rows } = await this.db.query(
      `SELECT
         (SELECT count(*) FROM users WHERE role_key = 'member' AND status <> 'deleted')::int      AS people,
         (SELECT count(*) FROM users WHERE role_key = 'member' AND status = 'pending')::int       AS not_activated,
         (SELECT count(*) FROM users WHERE role_key = 'member' AND status = 'suspended')::int     AS suspended,
         (SELECT count(DISTINCT user_id) FROM devices
           WHERE revoked_at IS NULL AND last_seen_at > now() - interval '24 hours')::int          AS active_today,
         (SELECT count(*) FROM devices WHERE revoked_at IS NULL)::int                              AS devices,
         (SELECT count(*) FROM message_envelopes WHERE delivered_at IS NULL)::int                  AS waiting`,
    );
    const r = rows[0];
    return {
      people: r.people,
      notActivated: r.not_activated,
      suspended: r.suspended,
      activeToday: r.active_today,
      devices: r.devices,
      waitingMessages: r.waiting,
    };
  }

  // Messages (one to one and group, each counted once) and calls per day.
  // The server never sees a call, only its relay credentials, which both
  // sides fetch: calls are those divided by two, rounded up.
  async perDay(days) {
    const { rows } = await this.db.query(
      `SELECT d::date::text AS day,
              COALESCE(sum(u.count) FILTER (WHERE u.metric IN ('messages', 'group_messages')), 0)::int AS messages,
              COALESCE(sum(u.count) FILTER (WHERE u.metric = 'relay_credentials'), 0)::int AS relay
         FROM generate_series(current_date - ($1::int - 1), current_date, interval '1 day') AS d
         LEFT JOIN usage_daily u ON u.day = d::date
        GROUP BY d ORDER BY d`,
      [days],
    );
    return rows.map((r) => ({ day: r.day, messages: r.messages, calls: Math.ceil(r.relay / 2) }));
  }

  async storageUse() {
    const { rows } = await this.db.query(
      `SELECT COALESCE(sum(ciphertext_bytes) FILTER (WHERE status = 'ready'), 0)::bigint AS media,
              count(*) FILTER (WHERE status = 'ready')::int AS files,
              pg_database_size(current_database())::bigint AS database
         FROM attachments`,
    );
    let disk = null;
    try {
      const s = await fs.promises.statfs(process.cwd());
      disk = { freeBytes: s.bavail * s.bsize, totalBytes: s.blocks * s.bsize };
    } catch (err) {
      this.logger.warn(`disk check failed: ${err.message}`);
    }
    return {
      mediaBytes: Number(rows[0].media),
      mediaFiles: rows[0].files,
      databaseBytes: Number(rows[0].database),
      disk,
    };
  }
}
