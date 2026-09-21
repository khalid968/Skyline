import { Global, Module, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Pool } from 'pg';
import { DatabaseService, PG_POOL } from './database.service';

@Global()
@Module({
  providers: [
    {
      provide: PG_POOL,
      inject: [ConfigService],
      useFactory: (config) => {
        const pool = new Pool({
          connectionString: config.get('database.url'),
          max: config.get('database.poolMax'),
          application_name: 'skyline-backend',
          // A runaway query or a forgotten open transaction must not be able
          // to pin a connection, or the whole API, forever.
          statement_timeout: 15000,
          idle_in_transaction_session_timeout: 30000,
          connectionTimeoutMillis: 5000,
        });
        // An unhandled 'error' on an idle client would crash the process.
        pool.on('error', (err) =>
          new Logger('Database').error(`idle client error: ${err.message}`),
        );
        return pool;
      },
    },
    DatabaseService,
  ],
  exports: [PG_POOL, DatabaseService],
})
export class DatabaseModule {}
