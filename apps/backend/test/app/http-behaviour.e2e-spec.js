// Health checks, the uniform error shape, request validation, and the response
// headers. Together these decide what an outsider can learn from the API.
import request from 'supertest';
import { createTestDatabase, mkUser, mkDevice } from '../db/harness';
import { createTestApp } from './app-harness';
import { TestController } from './test-routes';

describe('HTTP behaviour (real database and Redis)', () => {
  let db;
  let t;
  let alice;

  const api = () => request(t.app.getHttpServer());
  const asAlice = () => t.as(alice.id, alice.device);

  beforeAll(async () => {
    db = await createTestDatabase('http');
    alice = await mkUser(db.client, 'alice');
    alice.device = await mkDevice(db.client, alice.id);
    t = await createTestApp({ db, controllers: [TestController] });
  }, 90000);

  afterAll(async () => {
    await t.close();
    await db.drop();
  });

  describe('security headers (threat model A1, A2)', () => {
    it('sends them on every response: success, refusal and not found', async () => {
      for (const res of [
        await api().get('/health'),
        await api().get('/me/inbox'),
        await api().get('/no-such-route'),
      ]) {
        expect(res.headers['x-content-type-options']).toBe('nosniff');
        expect(res.headers['x-frame-options']).toBe('DENY');
        expect(res.headers['content-security-policy']).toContain("default-src 'none'");
        expect(res.headers['content-security-policy']).toContain("frame-ancestors 'none'");
        expect(res.headers['referrer-policy']).toBe('no-referrer');
        expect(res.headers['cache-control']).toBe('no-store');
        expect(res.headers['x-powered-by']).toBeUndefined();
        // HSTS is production's, behind TLS.
        expect(res.headers['strict-transport-security']).toBeUndefined();
      }
    });
  });

  describe('health', () => {
    it('reports liveness without needing any credentials', async () => {
      const res = await api().get('/health');
      expect(res.status).toBe(200);
      expect(res.body).toEqual({ status: 'ok' });
    });

    it('reports readiness with each dependency named up or down, and nothing else', async () => {
      const res = await api().get('/health/ready');
      expect(res.status).toBe(200);
      expect(res.body).toEqual({
        status: 'ok',
        checks: { database: 'up', redis: 'up' },
      });
    });

    it('returns 503 with a bare up/down when a dependency is unavailable, never an error message', async () => {
      const broken = await createTestApp({ db, controllers: [TestController] });
      try {
        await broken.pool.end(); // every later query on this pool now fails

        const res = await request(broken.app.getHttpServer()).get(
          '/health/ready',
        );
        expect(res.status).toBe(503);
        expect(res.body.status).toBe('unavailable');
        expect(res.body.checks.database).toBe('down');
        expect(res.body.checks.redis).toBe('up');
        // Nothing about hosts, ports, drivers or reasons.
        expect(JSON.stringify(res.body)).not.toMatch(
          /pool|ECONN|password|localhost|postgres|Cannot/i,
        );

        // Liveness must stay green so the orchestrator does not kill a healthy process.
        expect(
          (await request(broken.app.getHttpServer()).get('/health')).status,
        ).toBe(200);
      } finally {
        // Always release the app, or one failure here would leak connections
        // and keep the whole test run from exiting.
        await broken.close();
      }
    });
  });

  describe('errors reveal nothing', () => {
    it('turns an unexpected exception into a generic 500 with no internal detail', async () => {
      const res = await api().get('/t/boom').set(asAlice());
      expect(res.status).toBe(500);
      expect(res.body).toEqual({
        statusCode: 500,
        error: 'Internal Server Error',
        message: 'Internal Server Error',
      });
      expect(JSON.stringify(res.body)).not.toMatch(
        /secret_table|SELECT|stack|at /,
      );
    });

    it('gives an unmatched route the same 404 as a guard does', async () => {
      const a = await api().get('/definitely/not/a/route').set(asAlice());
      const b = await api()
        .get('/t/user/00000000-0000-4000-8000-000000000001')
        .set(asAlice());
      expect(a.status).toBe(404);
      expect(b.status).toBe(404);
      expect(a.body).toEqual(b.body);
    });

    it('rejects malformed JSON with a plain 400', async () => {
      const res = await api()
        .post('/t/echo')
        .set(asAlice())
        .set('content-type', 'application/json')
        .send('{"name": ');
      expect(res.status).toBe(400);
      expect(JSON.stringify(res.body)).not.toMatch(
        /Unexpected|SyntaxError|position|JSON/,
      );
    });

    it('rejects an oversized body', async () => {
      const res = await api()
        .post('/t/echo')
        .set(asAlice())
        .send({ name: 'x'.repeat(300 * 1024) });
      expect(res.status).toBe(413);
    });
  });

  describe('request validation', () => {
    it('accepts a valid body', async () => {
      const res = await api()
        .post('/t/echo')
        .set(asAlice())
        .send({ name: 'sarah' });
      expect(res.status).toBe(201);
      expect(res.body).toEqual({ name: 'sarah' });
    });

    it('rejects a constraint violation', async () => {
      const res = await api().post('/t/echo').set(asAlice()).send({ name: '' });
      expect(res.status).toBe(400);
    });

    it('REJECTS an undeclared field rather than dropping it (mass assignment)', async () => {
      const res = await api()
        .post('/t/echo')
        .set(asAlice())
        .send({ name: 'sarah', role: 'admin' });
      expect(res.status).toBe(400);
    });

    it('does not echo submitted values back in the error', async () => {
      const res = await api()
        .post('/t/echo')
        .set(asAlice())
        .send({ name: 'sarah', role: 'SUPERSECRETVALUE' });
      expect(res.status).toBe(400);
      expect(JSON.stringify(res.body)).not.toContain('SUPERSECRETVALUE');
    });

    it('validates BEFORE the handler runs, so an invalid request never reaches it', async () => {
      const res = await api().post('/t/echo').set(asAlice()).send({});
      expect(res.status).toBe(400);
    });
  });

  describe('headers', () => {
    it('does not advertise the framework', async () => {
      const res = await api().get('/health');
      expect(res.headers['x-powered-by']).toBeUndefined();
    });

    it('gives every response a request id', async () => {
      const res = await api().get('/health');
      expect(res.headers['x-request-id']).toMatch(/^[0-9a-f-]{36}$/);
    });

    it('honours a sensible inbound request id', async () => {
      const res = await api()
        .get('/health')
        .set('x-request-id', 'trace-abc12345');
      expect(res.headers['x-request-id']).toBe('trace-abc12345');
    });

    it('replaces a hostile inbound request id instead of echoing it into logs', async () => {
      const res = await api()
        .get('/health')
        .set('x-request-id', 'bad id <script>alert(1)</script>');
      expect(res.headers['x-request-id']).not.toContain('bad');
      expect(res.headers['x-request-id']).toMatch(/^[0-9a-f-]{36}$/);
    });
  });
});
