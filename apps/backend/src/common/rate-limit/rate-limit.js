import {
  Injectable,
  Dependencies,
  HttpException,
  HttpStatus,
  ServiceUnavailableException,
  Logger,
  SetMetadata,
  Global,
  Module,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { ConfigService } from '@nestjs/config';
import { RedisService } from '../../redis/redis.module';

export const RATE_LIMIT = 'skyline:rate-limit';

// Declares throttling rules for a route. Every rule must pass.
//
//   @RateLimit('activate', [{ by: 'ip', limit: 10, windowSec: 900 }])
//   @RateLimit('admin-login', [
//     { by: 'ip', limit: 20, windowSec: 900 },
//     { by: 'body.username', limit: 10, windowSec: 900 },
//   ])
//
// `by: 'body.<field>'` limits per value of a request field, so an attacker
// spreading attempts over many addresses still cannot hammer one account.
export const RateLimit = (name, rules) => {
  for (const r of rules) {
    if (
      !(r.by === 'ip' || /^body\.[A-Za-z]+$/.test(r.by)) ||
      !(r.limit > 0) ||
      !(r.windowSec > 0)
    ) {
      throw new Error(
        `invalid rate limit rule for ${name}: ${JSON.stringify(r)}`,
      );
    }
  }
  return SetMetadata(RATE_LIMIT, { name, rules });
};

// Fixed-window counters in Redis, shared by every backend instance.
@Injectable()
@Dependencies(RedisService, ConfigService)
export class RateLimitService {
  constructor(redis, config) {
    this.redis = redis;
    this.prefix = config.get('rateLimit.prefix');
    this.scale = config.get('rateLimit.scale');
  }

  // Counts one attempt against `key`. Returns { allowed, retryAfterSec }.
  // Throws if Redis is unreachable; the caller decides what that means.
  async hit(key, limit, windowSec) {
    const full = `${this.prefix}:rl:${key}`;
    const [[e1, count], [e2, ttl]] = await this.redis.client
      .multi()
      .incr(full)
      .pttl(full)
      .exec();
    if (e1 || e2) throw e1 || e2;
    // First hit in the window (or a key that somehow lost its expiry): start the clock.
    if (ttl < 0) await this.redis.client.pexpire(full, windowSec * 1000);

    const effectiveLimit = Math.max(1, Math.round(limit * this.scale));
    const retryAfterSec = Math.ceil((ttl < 0 ? windowSec * 1000 : ttl) / 1000);
    return { allowed: count <= effectiveLimit, retryAfterSec };
  }
}

// Runs before authentication, so unauthenticated floods are throttled too.
//
// FAILS CLOSED: if Redis cannot be reached, a rate-limited route is refused
// (503) rather than served unthrottled. Those routes are the ones an attacker
// would most like to hit without limits (activation, login), so an outage
// there must not quietly become an open door.
@Injectable()
@Dependencies(Reflector, RateLimitService)
export class RateLimitGuard {
  constructor(reflector, limiter) {
    this.reflector = reflector;
    this.limiter = limiter;
    this.logger = new Logger('RateLimit');
  }

  async canActivate(context) {
    if (context.getType() !== 'http') return true;
    const meta = this.reflector.get(RATE_LIMIT, context.getHandler());
    if (!meta) return true;

    const req = context.switchToHttp().getRequest();
    const res = context.switchToHttp().getResponse();

    for (const rule of meta.rules) {
      const subject = subjectOf(req, rule.by);
      if (subject === null) continue; // e.g. no username supplied: validation will reject it anyway

      await enforceLimit(
        this.limiter,
        `${meta.name}:${rule.by}:${subject}`,
        rule,
        res,
        this.logger,
      );
    }
    return true;
  }
}

// One rule, applied now: 429 with Retry-After when over, 503 when Redis is
// unreachable (fails closed). The guard uses it for per-address and per-field
// rules; a service uses it directly for limits that need to know WHO is
// calling, which the guard cannot, since it runs before authentication.
export async function enforceLimit(limiter, key, rule, res, logger) {
  let result;
  try {
    result = await limiter.hit(key, rule.limit, rule.windowSec);
  } catch (err) {
    (logger || new Logger('RateLimit')).error(
      `rate limiter unavailable, refusing ${key.split(':')[0]}: ${err.message}`,
    );
    throw new ServiceUnavailableException();
  }
  if (!result.allowed) {
    if (res) res.setHeader('Retry-After', String(result.retryAfterSec));
    throw new HttpException('Too Many Requests', HttpStatus.TOO_MANY_REQUESTS);
  }
}

function subjectOf(req, by) {
  if (by === 'ip')
    return req.ip || (req.socket && req.socket.remoteAddress) || 'unknown';
  const field = by.slice('body.'.length);
  const v = req.body && req.body[field];
  if (typeof v !== 'string' || v.length === 0) return null;
  // Normalised and bounded, so "Admin" and "admin " share one counter and a
  // huge value cannot bloat a Redis key.
  return v.trim().toLowerCase().slice(0, 64);
}

// Global so a service can apply a per-caller limit with enforceLimit().
@Global()
@Module({ providers: [RateLimitService], exports: [RateLimitService] })
export class RateLimitModule {}
