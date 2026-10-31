import { HttpException, ServiceUnavailableException } from '@nestjs/common';
import {
  RateLimit,
  RateLimitGuard,
  RATE_LIMIT,
  addressBucket,
} from './rate-limit';

function context(meta, req = {}) {
  const headers = {};
  const res = { setHeader: (k, v) => (headers[k] = v) };
  const handler = () => {};
  if (meta) Reflect.defineMetadata(RATE_LIMIT, meta, handler);
  return {
    headers,
    ctx: {
      getType: () => 'http',
      getHandler: () => handler,
      switchToHttp: () => ({
        getRequest: () => ({ ip: '203.0.113.9', body: {}, ...req }),
        getResponse: () => res,
      }),
    },
  };
}

const reflector = { get: (key, handler) => Reflect.getMetadata(key, handler) };

describe('RateLimitGuard', () => {
  const meta = {
    name: 'login',
    rules: [{ by: 'ip', limit: 5, windowSec: 60 }],
  };

  it('lets a request through while under the limit', async () => {
    const guard = new RateLimitGuard(reflector, {
      hit: async () => ({ allowed: true, retryAfterSec: 60 }),
    });
    await expect(guard.canActivate(context(meta).ctx)).resolves.toBe(true);
  });

  it('refuses with 429 and a Retry-After header once over the limit', async () => {
    const guard = new RateLimitGuard(reflector, {
      hit: async () => ({ allowed: false, retryAfterSec: 42 }),
    });
    const { ctx, headers } = context(meta);
    const err = await guard.canActivate(ctx).catch((e) => e);
    expect(err).toBeInstanceOf(HttpException);
    expect(err.getStatus()).toBe(429);
    expect(headers['Retry-After']).toBe('42');
  });

  it('FAILS CLOSED: if the counter store is down, the route is refused, not left unthrottled', async () => {
    const guard = new RateLimitGuard(reflector, {
      hit: async () => {
        throw new Error('ECONNREFUSED');
      },
    });
    guard.logger = { error: () => {} };
    await expect(guard.canActivate(context(meta).ctx)).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );
  });

  it('ignores routes with no rate limit, touching nothing', async () => {
    const hit = jest.fn();
    const guard = new RateLimitGuard(reflector, { hit });
    await expect(guard.canActivate(context(undefined).ctx)).resolves.toBe(true);
    expect(hit).not.toHaveBeenCalled();
  });

  it('keys a per-username rule on the normalised username, so case and spacing cannot dodge it', async () => {
    const keys = [];
    const guard = new RateLimitGuard(reflector, {
      hit: async (key) => {
        keys.push(key);
        return { allowed: true, retryAfterSec: 1 };
      },
    });
    const m = {
      name: 'login',
      rules: [{ by: 'body.username', limit: 5, windowSec: 60 }],
    };
    await guard.canActivate(context(m, { body: { username: '  Amina ' } }).ctx);
    await guard.canActivate(context(m, { body: { username: 'amina' } }).ctx);
    expect(keys[0]).toBe(keys[1]);
  });

  it('skips a per-username rule when no username was sent (validation rejects that anyway)', async () => {
    const hit = jest.fn();
    const guard = new RateLimitGuard(reflector, { hit });
    const m = {
      name: 'login',
      rules: [{ by: 'body.username', limit: 5, windowSec: 60 }],
    };
    await expect(guard.canActivate(context(m, { body: {} }).ctx)).resolves.toBe(
      true,
    );
    expect(hit).not.toHaveBeenCalled();
  });

  it('refuses to declare a nonsensical rule', () => {
    expect(() =>
      RateLimit('x', [{ by: 'cookie', limit: 5, windowSec: 60 }]),
    ).toThrow();
    expect(() =>
      RateLimit('x', [{ by: 'ip', limit: 0, windowSec: 60 }]),
    ).toThrow();
    expect(() => RateLimit('x', [{ by: 'ip', limit: 5 }])).toThrow();
  });
});

describe('addressBucket', () => {
  it('leaves IPv4 addresses, mapped forms included, exactly as they were', () => {
    expect(addressBucket('203.0.113.9')).toBe('203.0.113.9');
    expect(addressBucket('::ffff:127.0.0.1')).toBe('::ffff:127.0.0.1');
    expect(addressBucket('unknown')).toBe('unknown');
    expect(addressBucket(undefined)).toBeUndefined();
  });

  it('counts an IPv6 address as its /64, however it is written', () => {
    const bucket = '2001:db8:1:2::/64';
    for (const ip of [
      '2001:db8:1:2::1',
      '2001:0db8:0001:0002:ffff:ffff:ffff:ffff',
      '2001:DB8:1:2:aaaa::',
      '2001:db8:1:2::1%eth0',
      '2001:db8:1:2::192.0.2.1',
    ]) {
      expect(addressBucket(ip)).toBe(bucket);
    }
    expect(addressBucket('2001:db8:1:3::1')).toBe('2001:db8:1:3::/64');
    expect(addressBucket('::1')).toBe('0:0:0:0::/64');
  });

  it('gives a rotating /64 one counter in the guard', async () => {
    const keys = [];
    const guard = new RateLimitGuard(reflector, {
      hit: async (key) => {
        keys.push(key);
        return { allowed: true, retryAfterSec: 60 };
      },
    });
    const meta = {
      name: 'activate',
      rules: [{ by: 'ip', limit: 10, windowSec: 900 }],
    };
    await guard.canActivate(context(meta, { ip: '2a01:4f8:1:2::1' }).ctx);
    await guard.canActivate(
      context(meta, { ip: '2a01:4f8:1:2:dead:beef:0:7' }).ctx,
    );
    expect(new Set(keys).size).toBe(1);
    expect(keys[0]).toBe('activate:ip:2a01:4f8:1:2::/64');
  });
});
