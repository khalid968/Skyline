import {
  Controller,
  Get,
  Dependencies,
  Logger,
  HttpStatus,
} from '@nestjs/common';
import { Public } from '../../common/decorators/access.decorators';
import { PublicBodyException } from '../../common/filters/all-exceptions.filter';
import { DatabaseService } from '../../database/database.service';
import { RedisService } from '../../redis/redis.module';

// Liveness and readiness for the load balancer and the Compose healthcheck.
// Public by necessity, so they say the minimum: up or down per dependency.
// Never an error message, a hostname, or a version, since an unauthenticated
// endpoint that describes the infrastructure is reconnaissance.
@Controller('health')
@Dependencies(DatabaseService, RedisService)
export class HealthController {
  constructor(db, redis) {
    this.db = db;
    this.redis = redis;
    this.logger = new Logger('Health');
  }

  // Is the process alive? Deliberately touches nothing else, so a slow
  // database cannot make the orchestrator kill a healthy process.
  @Public()
  @Get()
  live() {
    return { status: 'ok' };
  }

  // Can it do its job? Every dependency is probed, with a hard timeout each.
  @Public()
  @Get('ready')
  async ready() {
    const [database, redis] = await Promise.all([
      this.probe('postgres', () => this.db.ping()),
      this.probe('redis', () => this.redis.ping()),
    ]);

    // Compared against 'up' explicitly: 'down' is a non-empty string and would
    // be truthy, which once made a dead database report as healthy.
    const healthy = database === 'up' && redis === 'up';
    const body = {
      status: healthy ? 'ok' : 'unavailable',
      checks: { database, redis },
    };
    // Thrown as a PublicBodyException so the up/down detail survives the
    // exception filter, which otherwise flattens every error body on purpose.
    if (body.status !== 'ok')
      throw new PublicBodyException(HttpStatus.SERVICE_UNAVAILABLE, body);
    return body;
  }

  async probe(name, fn) {
    let timer;
    try {
      await Promise.race([
        fn(),
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error('timed out')), 2000);
        }),
      ]);
      return 'up';
    } catch (err) {
      // The reason goes to the log; the caller only learns that it is down.
      this.logger.warn(`${name} check failed: ${err.message}`);
      return 'down';
    } finally {
      clearTimeout(timer);
    }
  }
}
