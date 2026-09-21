import { NestFactory } from '@nestjs/core';
import { ConfigService } from '@nestjs/config';
import { Logger } from '@nestjs/common';
import { AppModule } from './app.module';
import { configureApp } from './app.setup';

async function bootstrap() {
  const app = await NestFactory.create(AppModule, { bufferLogs: true });
  configureApp(app);

  const port = app.get(ConfigService).get('port');
  await app.listen(port);
  new Logger('Bootstrap').log(`listening on port ${port}`);
}

bootstrap().catch((err) => {
  // A bad configuration is the usual cause and its message is safe to print
  // (it names variables, never values). No stack: it would only be noise.
  console.error(err.message);
  process.exit(1);
});
