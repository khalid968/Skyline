import {
  Injectable,
  Dependencies,
  Logger,
  BadRequestException,
} from '@nestjs/common';
import { DatabaseService } from '../../database/database.service';
import { RedisService } from '../../redis/redis.module';
import { ConfigService } from '@nestjs/config';
import { PUSH_TRANSPORT, ringPayload } from './push.transport';

// Content-free wake-ups for devices whose app is closed (decisions.md, Phase
// 8). One live token per device; a wake-up per device at most every few
// seconds (a burst of messages needs only one); dead tokens are forgotten.
const COALESCE_SECONDS = 5;
// A call push is never merged with message wake-ups, only with itself (a
// caller who redials at once rings once).
const RING_COALESCE_SECONDS = 3;

@Injectable()
@Dependencies(DatabaseService, RedisService, ConfigService, PUSH_TRANSPORT)
export class PushService {
  constructor(db, redis, config, transport) {
    this.db = db;
    this.redis = redis;
    this.prefix = config.get('rateLimit.prefix');
    this.transport = transport;
    this.logger = new Logger('Push');
  }

  // This device's token (replacing any earlier one). A token that moved to
  // another device (the app was reinstalled) is taken from the old one.
  async register(deviceId, { provider, token }) {
    if (!['fcm', 'apns'].includes(provider)) {
      throw new BadRequestException(['provider must be fcm or apns']);
    }
    await this.db.transaction(async (client) => {
      await client.query(
        `UPDATE push_tokens SET revoked_at = now()
          WHERE revoked_at IS NULL AND (device_id = $1 OR (provider = $2 AND token = $3))`,
        [deviceId, provider, token],
      );
      await client.query(
        `INSERT INTO push_tokens (device_id, provider, token) VALUES ($1, $2, $3)`,
        [deviceId, provider, token],
      );
    });
  }

  async unregister(deviceId) {
    await this.db.query(
      'UPDATE push_tokens SET revoked_at = now() WHERE device_id = $1 AND revoked_at IS NULL',
      [deviceId],
    );
  }

  // Phase 14c: rings the recipient's devices among these for a call offer.
  // Returns the device ids it rang (they need no separate wake-up: ringing
  // makes the app pull its inbox too). Never throws.
  async ring(recipientUserId, deviceIds, messageId) {
    const rung = [];
    if (!deviceIds.length) return rung;
    try {
      const { rows } = await this.db.query(
        `SELECT p.id, p.device_id, p.provider, p.token
           FROM push_tokens p JOIN devices d ON d.id = p.device_id
          WHERE p.device_id = ANY($1::uuid[]) AND d.user_id = $2
            AND p.revoked_at IS NULL AND d.revoked_at IS NULL`,
        [deviceIds, recipientUserId],
      );
      for (const r of rows) {
        const fresh = await this.redis.client.set(
          `${this.prefix}:push:call:${r.device_id}`,
          '1',
          'EX',
          RING_COALESCE_SECONDS,
          'NX',
        );
        if (fresh !== 'OK') continue;
        const outcome = await this.transport.send(r.provider, r.token, ringPayload(messageId));
        if (outcome === 'ok') rung.push(r.device_id);
        if (outcome === 'invalid') {
          await this.db.query('UPDATE push_tokens SET revoked_at = now() WHERE id = $1', [r.id]);
        }
      }
    } catch (err) {
      this.logger.warn(`call push failed: ${err.message}`);
    }
    return rung;
  }

  // Wakes these devices. Never throws: a missed wake-up only delays delivery
  // until the app is next opened.
  async wake(deviceIds) {
    if (!deviceIds.length) return 0;
    let sent = 0;
    try {
      const { rows } = await this.db.query(
        `SELECT p.id, p.device_id, p.provider, p.token
           FROM push_tokens p JOIN devices d ON d.id = p.device_id
          WHERE p.device_id = ANY($1::uuid[]) AND p.revoked_at IS NULL AND d.revoked_at IS NULL`,
        [deviceIds],
      );
      for (const r of rows) {
        const fresh = await this.redis.client.set(
          `${this.prefix}:push:${r.device_id}`,
          '1',
          'EX',
          COALESCE_SECONDS,
          'NX',
        );
        if (fresh !== 'OK') continue; // woken moments ago; it will pull everything
        const outcome = await this.transport.send(r.provider, r.token);
        if (outcome === 'ok') sent++;
        if (outcome === 'invalid') {
          await this.db.query(
            'UPDATE push_tokens SET revoked_at = now() WHERE id = $1',
            [r.id],
          );
        }
      }
    } catch (err) {
      this.logger.warn(`wake-up failed: ${err.message}`);
    }
    return sent;
  }
}
