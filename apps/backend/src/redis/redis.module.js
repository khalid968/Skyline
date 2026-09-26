import {
  Global,
  Module,
  Injectable,
  Dependencies,
  Logger,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import Redis from 'ioredis';

export const REDIS = 'REDIS';

// Redis is used ONLY for WebSocket fan-out, presence and rate limiting. It is
// never a system of record: if it is wiped, nothing is lost but in-flight
// events. Authorization is never cached here (see decisions.md).
@Injectable()
@Dependencies(REDIS)
export class RedisService {
  constructor(client) {
    this.client = client;
  }

  async ping() {
    const reply = await this.client.ping();
    if (reply !== 'PONG') throw new Error('unexpected reply from Redis');
  }

  publish(channel, message) {
    return this.client.publish(channel, message);
  }

  // A dedicated connection: a client in subscriber mode can run nothing else.
  duplicate() {
    return this.client.duplicate();
  }

  async onApplicationShutdown() {
    if (this.client.status !== 'end')
      await this.client.quit().catch(() => this.client.disconnect());
  }
}

@Global()
@Module({
  providers: [
    {
      provide: REDIS,
      inject: [ConfigService],
      useFactory: (config) => {
        const client = new Redis({
          host: config.get('redis.host'),
          port: config.get('redis.port'),
          password: config.get('redis.password'),
          // Fail a command quickly rather than queueing it forever while Redis
          // is down; callers decide what an outage means for them.
          maxRetriesPerRequest: 2,
          connectTimeout: 5000,
        });
        // Without a listener an 'error' event would crash the process.
        client.on('error', (err) => new Logger('Redis').error(err.message));
        return client;
      },
    },
    RedisService,
  ],
  exports: [REDIS, RedisService],
})
export class RedisModule {}
