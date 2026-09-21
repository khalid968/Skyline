import { Injectable, Dependencies, Logger } from '@nestjs/common';

export const PG_POOL = 'PG_POOL';

// The single doorway to PostgreSQL. Everything is raw SQL on purpose (see
// decisions.md): the security properties live in constraints and functions the
// service layer calls, and an ORM would only obscure them.
@Injectable()
@Dependencies(PG_POOL)
export class DatabaseService {
  constructor(pool) {
    this.pool = pool;
    this.logger = new Logger('Database');
  }

  query(text, params) {
    return this.pool.query(text, params);
  }

  // Runs fn(client) inside one transaction. Commits if it resolves, rolls back
  // if it throws, and always returns the connection to the pool.
  async transaction(fn) {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const result = await fn(client);
      await client.query('COMMIT');
      return result;
    } catch (err) {
      try {
        await client.query('ROLLBACK');
      } catch (rollbackErr) {
        this.logger.error(`rollback failed: ${rollbackErr.message}`);
      }
      throw err;
    } finally {
      client.release();
    }
  }

  async ping() {
    await this.pool.query('SELECT 1');
  }

  async onApplicationShutdown() {
    // A test may hand us a pool it also owns; ending twice throws.
    if (!this.pool.ended) await this.pool.end();
  }
}
