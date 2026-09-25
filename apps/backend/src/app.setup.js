import { ConfigService } from '@nestjs/config';
import express from 'express';
import { WsAdapter } from '@nestjs/platform-ws';
import { JsonLogger } from './common/logging/json-logger';
import { requestContext } from './common/logging/request-context.middleware';

// Everything that must be true of a running app, in one place, so production
// (main.js) and the tests exercise exactly the same setup. If a test app were
// configured differently from the real one, the tests would prove nothing about
// the thing that ships.
export function configureApp(app) {
  const config = app.get(ConfigService);
  const logger = new JsonLogger(config.get('logLevel'));

  app.useLogger(logger);
  app.useWebSocketAdapter(new WsAdapter(app));

  // Do not advertise the framework to anyone probing the server.
  app.getHttpAdapter().getInstance().disable('x-powered-by');

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
