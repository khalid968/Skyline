// Real rate limits (production values, scale 1) against real Redis, and the
// operator command-line tools run exactly as an operator would run them.
import path from 'path';
import { spawnSync } from 'child_process';
import request from 'supertest';
import { createTestDatabase } from '../db/harness';
import { createTestApp } from './app-harness';
import { newDeviceKey, activationFields } from './device-key';
import {
  normalizeActivationCode,
} from '../../src/modules/auth/auth-crypto';

const BACKEND = path.join(__dirname, '..', '..');


describe('rate limits and operator tools (real Redis, real processes)', () => {
  let db;
  let t;
  const api = () => request(t.app.getHttpServer());

  const activate = (code, key = newDeviceKey()) =>
    api()
      .post('/auth/activate')
      .send({
        code,
        deviceName: 'Phone',
        platform: 'ios',
        ...activationFields(code, key, normalizeActivationCode(code) || 'x'),
      });

  const cli = (script, args, env = {}) =>
    spawnSync(`npx babel-node src/cli/${script}.js ${args}`, {
      cwd: BACKEND,
      shell: true,
      encoding: 'utf8',
      timeout: 60000,
      env: { ...process.env, DATABASE_URL: db.url, ...env },
    });

  beforeAll(async () => {
    db = await createTestDatabase('ratecli');
    t = await createTestApp({ db, realAuth: true, rateLimitScale: 1 });
  }, 90000);

  afterAll(async () => {
    await t.close();
    await db.drop();
  });

  describe('rate limits (production values)', () => {
    it('allows 10 activation attempts per address per 15 minutes, then answers 429 with Retry-After', async () => {
      const statuses = [];
      for (let i = 0; i < 11; i++)
        statuses.push((await activate('SKY-00000-00000-00000-00000')).status);
      expect(statuses.slice(0, 10)).toEqual(Array(10).fill(401));

      const blocked = await activate('SKY-00000-00000-00000-00000');
      expect(blocked.status).toBe(429);
      expect(Number(blocked.headers['retry-after'])).toBeGreaterThan(0);
      expect(blocked.body).toEqual({
        statusCode: 429,
        error: 'Too Many Requests',
        message: 'Too Many Requests',
      });
    });

    it('limits sign-in attempts per USERNAME, so one account cannot be hammered', async () => {
      const tries = [];
      for (let i = 0; i < 11; i++) {
        tries.push(
          (
            await api()
              .post('/admin/auth/login')
              .send({ username: 'Target', password: 'guess' })
          ).status,
        );
      }
      expect(tries.slice(0, 10)).toEqual(Array(10).fill(401));
      expect(tries[10]).toBe(429);

      // Case or spacing does not reset the counter...
      expect(
        (
          await api()
            .post('/admin/auth/login')
            .send({ username: ' target ', password: 'g' })
        ).status,
      ).toBe(429);
      // ...but a different username is still judged on its own.
      expect(
        (
          await api()
            .post('/admin/auth/login')
            .send({ username: 'someone-else', password: 'g' })
        ).status,
      ).toBe(401);
    });
  });

  describe('command-line tools', () => {
    let sarahCode;

    it('admin:create makes the first administrator, who can then sign in', async () => {
      const r = cli(
        'admin-create',
        '--username boss --display-name "The Boss"',
        {
          SKYLINE_ADMIN_PASSWORD: 'a long enough admin password',
        },
      );
      expect(r.status).toBe(0);
      expect(r.stdout).toMatch(/Owner "boss" created/); // the first admin is the protected owner

      const { rows } = await db.client.query(
        `SELECT u.role_key, u.status, c.password_hash FROM users u JOIN admin_credentials c ON c.user_id = u.id WHERE u.username = 'boss'`,
      );
      expect(rows[0]).toMatchObject({ role_key: 'admin', status: 'active' });
      expect(rows[0].password_hash).toMatch(/^\$argon2id\$/);

      // Its own app, so the sign-in rate limit exercised above does not interfere.
      const fresh = await createTestApp({ db, realAuth: true });
      try {
        const login = await request(fresh.app.getHttpServer())
          .post('/admin/auth/login')
          .send({ username: 'boss', password: 'a long enough admin password' });
        expect(login.status).toBe(200);
      } finally {
        await fresh.close();
      }
    }, 90000);

    it('admin:create refuses to make a second administrator by accident', () => {
      const r = cli('admin-create', '--username boss2', {
        SKYLINE_ADMIN_PASSWORD: 'another long password here',
      });
      expect(r.status).toBe(1);
      expect(r.stderr).toMatch(/already exists/);
    }, 60000);

    it('admin:create refuses a short password', () => {
      const r = cli('admin-create', '--username shorty --additional', {
        SKYLINE_ADMIN_PASSWORD: 'short',
      });
      expect(r.status).toBe(1);
      expect(r.stderr).toMatch(/at least 12/);
    }, 60000);

    it('user:invite creates a pending member and prints a code once', async () => {
      const r = cli(
        'invite',
        '--username sarah.w --display-name "Sarah Whitfield"',
      );
      expect(r.status).toBe(0);
      const match = r.stdout.match(/SKY(-[0-9A-Z]{5}){4}/);
      expect(match).not.toBeNull();
      sarahCode = match[0];

      const { rows } = await db.client.query(
        `SELECT status, display_name FROM users WHERE username = 'sarah.w'`,
      );
      expect(rows[0]).toEqual({
        status: 'pending',
        display_name: 'Sarah Whitfield',
      });
      // The code itself is nowhere in the database.
      const all = JSON.stringify(
        (await db.client.query('SELECT * FROM activation_codes')).rows,
      );
      expect(all).not.toContain(sarahCode);
      expect(all).not.toContain(normalizeActivationCode(sarahCode));
    }, 60000);

    it('a code printed by the tool activates a real device against the server', async () => {
      const fresh = await createTestApp({ db, realAuth: true });
      try {
        const key = newDeviceKey();
        const res = await request(fresh.app.getHttpServer())
          .post('/auth/activate')
          .send({
            code: sarahCode,
            deviceName: "Sarah's phone",
            platform: 'android',
            ...activationFields(sarahCode, key),
          });
        expect(res.status).toBe(201);
      } finally {
        await fresh.close();
      }
    }, 60000);

    it('inviting again issues a new code and kills any unused earlier one', async () => {
      const first = cli('invite', '--username newbie').stdout.match(
        /SKY(-[0-9A-Z]{5}){4}/,
      )[0];
      const second = cli('invite', '--username newbie').stdout.match(
        /SKY(-[0-9A-Z]{5}){4}/,
      )[0];
      expect(second).not.toBe(first);

      const fresh = await createTestApp({ db, realAuth: true });
      try {
        const attempt = (code) => {
          const key = newDeviceKey();
          return request(fresh.app.getHttpServer())
            .post('/auth/activate')
            .send({
              code,
              deviceName: 'Phone',
              platform: 'ios',
              ...activationFields(code, key),
            });
        };
        expect((await attempt(first)).status).toBe(401);
        expect((await attempt(second)).status).toBe(201);
      } finally {
        await fresh.close();
      }
    }, 120000);

    it('recorded every step in the audit log', async () => {
      const { rows } = await db.client.query(
        `SELECT action, count(*)::int AS n FROM audit_log WHERE action IN ('users.create', 'codes.issue', 'devices.activate') GROUP BY action`,
      );
      const counts = Object.fromEntries(rows.map((r) => [r.action, r.n]));
      expect(counts['users.create']).toBeGreaterThanOrEqual(3); // boss, sarah.w, newbie
      expect(counts['codes.issue']).toBeGreaterThanOrEqual(3);
      expect(counts['devices.activate']).toBeGreaterThanOrEqual(2);
    });
  });
});
