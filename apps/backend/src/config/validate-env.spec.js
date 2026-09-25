import { validateEnv } from './validate-env';

describe('validateEnv', () => {
  it('accepts an empty environment, applying development defaults', () => {
    const out = validateEnv({});
    expect(out.NODE_ENV).toBe('development');
    expect(out.PORT).toBe('3000');
  });

  it('defaults to silent logging under test so test output stays readable', () => {
    expect(validateEnv({ NODE_ENV: 'test' }).LOG_LEVEL).toBe('silent');
  });

  it('reports every problem at once, not just the first', () => {
    let message = '';
    try {
      validateEnv({
        NODE_ENV: 'staging',
        PORT: '99999',
        REDIS_PORT: 'abc',
        LOG_LEVEL: 'shouty',
      });
    } catch (e) {
      message = e.message;
    }
    expect(message).toMatch(/NODE_ENV/);
    expect(message).toMatch(/PORT must/);
    expect(message).toMatch(/REDIS_PORT/);
    expect(message).toMatch(/LOG_LEVEL/);
  });

  it('rejects a DATABASE_URL that is not a postgres URL', () => {
    expect(() => validateEnv({ DATABASE_URL: 'mysql://u:p@h/db' })).toThrow(
      /postgres/,
    );
    expect(() => validateEnv({ DATABASE_URL: 'not a url' })).toThrow(
      /valid URL/,
    );
  });

  describe('production refuses development placeholders', () => {
    const good = {
      NODE_ENV: 'production',
      DATABASE_URL:
        'postgres://skyline:Xy7-strong-and-long-9Qp@db:5432/skyline',
      STORAGE_ACCESS_KEY: 'AKIA-real-access-key',
      STORAGE_SECRET_KEY: 'a-genuinely-long-random-storage-secret',
      AUTH_TOKEN_PEPPER: 'Qk3v9-a-genuinely-random-pepper-value-8Hn2',
      AUTH_TOTP_KEY: 'Zp7w1-a-genuinely-random-totp-key-value-4Rt6',
      TURN_SECRET: 'Qm3v8-a-genuinely-random-relay-secret-9Kd2',
      TURN_URLS: 'turn:relay.example.org:3478?transport=udp',
    };

    it('accepts properly configured production settings', () => {
      expect(() => validateEnv(good)).not.toThrow();
    });

    it.each([
      [
        'a placeholder database password',
        { DATABASE_URL: 'postgres://skyline:change-me@db:5432/skyline' },
      ],
      [
        'the dev database password',
        { DATABASE_URL: 'postgres://skyline:skyline@db:5432/skyline' },
      ],
      [
        'an empty database password',
        { DATABASE_URL: 'postgres://skyline:@db:5432/skyline' },
      ],
      ['the dev storage secret', { STORAGE_SECRET_KEY: 'skyline-secret' }],
      ['a missing storage secret', { STORAGE_SECRET_KEY: undefined }],
      ['the dev storage access key', { STORAGE_ACCESS_KEY: 'skyline' }],
      ['a missing token pepper', { AUTH_TOKEN_PEPPER: undefined }],
      ['a short token pepper', { AUTH_TOKEN_PEPPER: 'too-short' }],
      [
        'the dev token pepper',
        { AUTH_TOKEN_PEPPER: 'dev-only-token-pepper-never-use-in-production' },
      ],
      ['a missing 2FA key', { AUTH_TOTP_KEY: undefined }],
      ['a missing relay secret', { TURN_SECRET: undefined }],
      ['the development relay secret', { TURN_SECRET: 'dev-only-turn-secret' }],
      ['no relay address', { TURN_URLS: undefined }],
      ['a scaled-up rate limit', { RATE_LIMIT_SCALE: '100' }],
    ])('rejects %s', (_label, override) => {
      expect(() => validateEnv({ ...good, ...override })).toThrow(/production/);
    });

    it('is only enforced in production, so laptops keep working', () => {
      expect(() =>
        validateEnv({
          NODE_ENV: 'development',
          DATABASE_URL: 'postgres://skyline:skyline@localhost/skyline',
        }),
      ).not.toThrow();
    });
  });

  it('rejects a nonsensical rate-limit scale anywhere', () => {
    expect(() => validateEnv({ RATE_LIMIT_SCALE: '0' })).toThrow(
      /RATE_LIMIT_SCALE/,
    );
    expect(() => validateEnv({ RATE_LIMIT_SCALE: 'lots' })).toThrow(
      /RATE_LIMIT_SCALE/,
    );
    expect(() => validateEnv({ RATE_LIMIT_SCALE: '50' })).not.toThrow();
  });

  it('never echoes a secret value in its error message', () => {
    const secret = 'super-secret-value-that-must-not-leak';
    let message = '';
    try {
      validateEnv({
        NODE_ENV: 'production',
        DATABASE_URL: `postgres://skyline:${secret}@db/skyline`,
        STORAGE_SECRET_KEY: 'skyline-secret',
      });
    } catch (e) {
      message = e.message;
    }
    expect(message).not.toContain(secret);
    expect(message).not.toContain('skyline-secret');
  });
});
