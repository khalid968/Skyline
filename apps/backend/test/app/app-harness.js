// Builds the REAL AppModule, configured by the REAL configureApp(), against a
// throwaway database and the dev Redis. Only three things are substituted:
//   - the Postgres pool (pointed at the throwaway database),
//   - the WebSocket authenticator (Phase 5 does not exist yet), and
//   - a middleware that fakes "who is calling" from headers, standing in for the
//     token authentication that Phase 5 adds.
// Everything else, including every global guard, is what production runs.
import { randomUUID } from 'crypto';
import { Pool } from 'pg';
import { Test } from '@nestjs/testing';
import { AppModule } from '../../src/app.module';
import { configureApp } from '../../src/app.setup';
import { PG_POOL } from '../../src/database/database.service';
import { WS_AUTHENTICATOR } from '../../src/modules/websocket/ws-authenticator';

// Stands in for Phase 5. Reads a principal from test-only headers.
function fakeAuthentication(req, _res, next) {
  const userId = req.headers['x-test-user'];
  const deviceId = req.headers['x-test-device'];
  if (userId || deviceId) req.principal = { userId, deviceId };
  next();
}

// Stands in for Phase 5's WebSocket authenticator. Reads ?user=&device=.
export const queryAuthenticator = {
  async authenticate(req) {
    const url = new URL(req.url, 'http://localhost');
    const userId = url.searchParams.get('user');
    const deviceId = url.searchParams.get('device');
    return userId && deviceId ? { userId, deviceId } : null;
  },
};

export const newChannel = () => `skyline:test:${randomUUID()}`;

export async function createTestApp({
  db,
  controllers = [],
  channel = newChannel(),
  listen = false,
}) {
  const pool = new Pool({ connectionString: db.url, max: 5 });

  // configuration.js reads this when the module compiles.
  const previous = process.env.REDIS_EVENTS_CHANNEL;
  process.env.REDIS_EVENTS_CHANNEL = channel;

  const moduleRef = await Test.createTestingModule({
    imports: [AppModule],
    controllers,
  })
    .overrideProvider(PG_POOL)
    .useValue(pool)
    .overrideProvider(WS_AUTHENTICATOR)
    .useValue(queryAuthenticator)
    .compile();

  const app = moduleRef.createNestApplication();
  configureApp(app);
  app.use(fakeAuthentication);
  await app.init();

  if (listen) await app.listen(0);
  if (previous === undefined) delete process.env.REDIS_EVENTS_CHANNEL;
  else process.env.REDIS_EVENTS_CHANNEL = previous;

  return {
    app,
    pool,
    channel,
    get port() {
      return app.getHttpServer().address().port;
    },
    // The identity headers standing in for a Phase 5 token.
    as: (userId, deviceId) => ({
      'x-test-user': userId,
      'x-test-device': deviceId,
    }),
    async close() {
      await app.close();
    },
  };
}
