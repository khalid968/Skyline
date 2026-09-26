import { ConfigService } from '@nestjs/config';
import express from 'express';
import { WsAdapter } from '@nestjs/platform-ws';
import { JsonLogger } from './common/logging/json-logger';
import { requestContext } from './common/logging/request-context.middleware';

// Everything that must be true of a running app, in one place, so production
// (main.js) and the tests exercise exactly the same setup. If a test app were
// configured differently from the real one, the tests would prove nothing about
// the thing that ships.
// Every response (threat model, A1 and A2): the API serves JSON and
// ciphertext only, so nothing may be sniffed as another type, framed, cached
// by anything along the way, or given a referrer. HSTS only in production,
// where TLS is certain.
export function securityHeaders(production) {
  return (req, res, next) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader(
      'Content-Security-Policy',
      "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
    );
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
    res.setHeader('Cache-Control', 'no-store');
    if (production)
      res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
    next();
  };
}

// Board 42: the apps send "x-skyline-app: <version>+<platform>". One older
// than the minimum gets 426 with the versions, and shows "Please update"; the
// dashboard and tools send no such header and are unaffected. Health and the
// release manifest stay reachable, or an old app could never learn what to do.
export function minimumAppVersion(minimum) {
  const min = parseVersion(minimum);
  return (req, res, next) => {
    const raw = req.headers['x-skyline-app'];
    if (!raw || !min || req.path === '/app/releases' || req.path.startsWith('/health')) return next();
    const v = parseVersion(String(raw).split('+')[0]);
    if (v && compareVersions(v, min) < 0) {
      res.status(426).json({
        statusCode: 426,
        error: 'Upgrade Required',
        message: 'this version of Skyline is no longer supported',
        minimum,
      });
      return;
    }
    next();
  };
}

export function parseVersion(s) {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(String(s ?? '').trim());
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

export function compareVersions(a, b) {
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] - b[i];
  return 0;
}

export function configureApp(app) {
  const config = app.get(ConfigService);
  const logger = new JsonLogger(config.get('logLevel'));

  app.useLogger(logger);
  app.useWebSocketAdapter(new WsAdapter(app));

  // Do not advertise the framework to anyone probing the server.
  app.getHttpAdapter().getInstance().disable('x-powered-by');
  app.use(securityHeaders(config.get('env') === 'production'));
  const trustProxy = config.get('trustProxy');
  if (trustProxy !== null && trustProxy !== undefined) {
    app.getHttpAdapter().getInstance().set('trust proxy', trustProxy);
  }
  app.use(minimumAppVersion(config.get('app').minVersion));

  app.use(requestContext(logger));
  // Media upload parts arrive as raw ciphertext, at most one 8 MB part each.
  // Only for that route, and only for application/octet-stream; everything
  // else keeps the normal (small) JSON limit.
  app.use(
    /^\/attachments\/[^/]+\/parts$/,
    express.raw({ type: 'application/octet-stream', limit: 8 * 1024 * 1024 }),
  );
  app.enableShutdownHooks();
  return app;
}
