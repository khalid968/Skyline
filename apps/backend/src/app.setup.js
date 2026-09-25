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

export function configureApp(app) {
  const config = app.get(ConfigService);
  const logger = new JsonLogger(config.get('logLevel'));

  app.useLogger(logger);
  app.useWebSocketAdapter(new WsAdapter(app));

  // Do not advertise the framework to anyone probing the server.
  app.getHttpAdapter().getInstance().disable('x-powered-by');
  app.use(securityHeaders(config.get('env') === 'production'));

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
