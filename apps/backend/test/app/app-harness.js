// Builds the REAL AppModule, configured by the REAL configureApp(), against a
// throwaway database and the dev Redis. By default three things are substituted:
//   - the Postgres pool (pointed at the throwaway database),
//   - the WebSocket authenticator (reads ?user=&device= instead of a token), and
//   - a middleware that sets "who is calling" from test headers, so tests of the
//     guards do not each have to activate a device first.
// Pass `realAuth: true` to drop the last two and run authentication exactly as
// production does: bearer tokens only. Everything else, including every global
// guard and the rate limiter, is always what production runs.
//
// THE FAKES LIVE HERE AND NOWHERE ELSE. Nothing in src/ may read x-test-* headers.
import { randomUUID } from 'crypto';
import { Pool } from 'pg';
import { PUSH_TRANSPORT } from '../../src/modules/notifications/push.transport';
import { Test } from '@nestjs/testing';
import { AppModule } from '../../src/app.module';
import { configureApp } from '../../src/app.setup';
import { PG_POOL } from '../../src/database/database.service';
import { WS_AUTHENTICATOR } from '../../src/modules/websocket/ws-authenticator';

function fakeAuthentication(req, _res, next) {
  const dashboardUser = req.headers['x-test-dashboard'];
  const userId = req.headers['x-test-user'];
  const deviceId = req.headers['x-test-device'];
  if (dashboardUser)
    req.principal = { kind: 'dashboard', userId: dashboardUser };
  else if (userId || deviceId)
    req.principal = { kind: 'device', userId, deviceId };
  next();
}

export const queryAuthenticator = {
  async authenticate(req) {
    const url = new URL(req.url, 'http://localhost');
    const userId = url.searchParams.get('user');
    const deviceId = url.searchParams.get('device');
    return userId && deviceId ? { userId, deviceId } : null;
  },
};

export const newChannel = () => `skyline:test:${randomUUID()}`;

// configuration.js reads process.env when the module compiles, so these are
// set around compilation and restored afterwards.
function withEnv(vars, fn) {
  const previous = {};
  for (const [k, v] of Object.entries(vars)) {
    previous[k] = process.env[k];
    process.env[k] = v;
  }
  return fn().finally(() => {
    for (const [k, v] of Object.entries(previous)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  });
}

// Records every wake-up instead of sending it. `outcome` decides the answer.
export class RecordingPushTransport {
  constructor() {
    this.sent = [];
    this.outcome = 'ok';
  }

  async send(provider, token) {
    this.sent.push({ provider, token });
    return this.outcome;
  }
}

export async function createTestApp({
  db,
  controllers = [],
  channel = newChannel(),
  listen = false,
  realAuth = false,
  // Tests make dozens of requests from one address; limits meant for attackers
  // would trip. Suites that TEST rate limiting pass 1.
  rateLimitScale = 1000,
  // Push wake-ups never leave a test: a recording fake by default.
  pushTransport = new RecordingPushTransport(),
}) {
  const pool = new Pool({ connectionString: db.url, max: 5 });

  const app = await withEnv(
    {
      REDIS_EVENTS_CHANNEL: channel,
      // A fresh namespace per app, so counters never leak between runs.
      RATE_LIMIT_PREFIX: `skyline:test:${randomUUID()}`,
      RATE_LIMIT_SCALE: String(rateLimitScale),
      // Tests use their own bucket in the dev object store.
      STORAGE_BUCKET: 'skyline-test',
    },
    async () => {
      let builder = Test.createTestingModule({
        imports: [AppModule],
        controllers,
      })
        .overrideProvider(PG_POOL)
        .useValue(pool)
        .overrideProvider(PUSH_TRANSPORT)
        .useValue(pushTransport);
      if (!realAuth)
        builder = builder
          .overrideProvider(WS_AUTHENTICATOR)
          .useValue(queryAuthenticator);

      const moduleRef = await builder.compile();
      const nest = moduleRef.createNestApplication();
      configureApp(nest);
      if (!realAuth) nest.use(fakeAuthentication);
      await nest.init();
      if (listen) await nest.listen(0);
      return nest;
    },
  );

  return {
    app,
    pool,
    channel,
    push: pushTransport,
    get port() {
      return app.getHttpServer().address().port;
    },
    // A member signed in on a device.
    as: (userId, deviceId) => ({
      'x-test-user': userId,
      'x-test-device': deviceId,
    }),
    // An operator signed in to the dashboard.
    asDashboard: (userId) => ({ 'x-test-dashboard': userId }),
    async close() {
      await app.close();
    },
  };
}
