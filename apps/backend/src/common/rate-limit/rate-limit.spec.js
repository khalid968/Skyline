import { HttpException, ServiceUnavailableException } from '@nestjs/common';
import { RateLimit, RateLimitGuard, RATE_LIMIT } from './rate-limit';

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
