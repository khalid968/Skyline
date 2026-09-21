import { ConfigService } from '@nestjs/config';
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
  app.enableShutdownHooks();
  return app;
}
