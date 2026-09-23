// Test harness for schema-invariant tests. Each suite gets its own throwaway
// database, built by applying the real migration files in order, and dropped
// afterwards. Nothing here touches the dev database.
import fs from 'fs';
import path from 'path';
import { Client } from 'pg';
import crypto from 'crypto';
import dotenv from 'dotenv';

dotenv.config({ path: path.join(__dirname, '..', '..', '.env'), quiet: true });

const MIGRATIONS_DIR = path.join(
  __dirname,
  '..',
  '..',
  'src',
  'database',
  'migrations',
);
const BASE_URL =
  process.env.DATABASE_URL ||
  'postgres://skyline:skyline@localhost:5432/skyline';

function urlForDatabase(name) {
  const u = new URL(BASE_URL);
  u.pathname = `/${name}`;
  return u.toString();
}

// The "Up" half of a migration file: everything between the two markers.
function upSection(sql) {
  const up = sql.indexOf('-- Up Migration');
  const down = sql.indexOf('-- Down Migration');
  if (up === -1 || down === -1)
    throw new Error('migration is missing an Up/Down marker');
  return sql.slice(up, down);
}

export async function createTestDatabase(label) {
  const name = `skyline_test_${label}_${process.pid}_${Date.now()}`;

  const admin = new Client({ connectionString: urlForDatabase('postgres') });
  await admin.connect();
  await admin.query(`CREATE DATABASE "${name}"`);
  await admin.end();

  const files = fs
    .readdirSync(MIGRATIONS_DIR)
    .filter((f) => f.endsWith('.sql'))
    .sort();

  const client = new Client({ connectionString: urlForDatabase(name) });
  await client.connect();
  for (const f of files) {
    await client.query(
      upSection(fs.readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')),
    );
  }

  return {
    name,
    client,
    url: urlForDatabase(name),
    // A brand new connection, for tests that need genuine concurrency.
    async connect() {
      const c = new Client({ connectionString: urlForDatabase(name) });
      await c.connect();
      return c;
    },
    async drop() {
      await client.end();
      const a = new Client({ connectionString: urlForDatabase('postgres') });
      await a.connect();
      await a.query(`DROP DATABASE IF EXISTS "${name}" WITH (FORCE)`);
      await a.end();
    },
  };
}

// Small fixtures. Usernames must be globally unique and never reused, exactly
// like production, so every call gets a fresh suffix.
let seq = 0;
export const next = () => ++seq;

export async function mkUser(db, name = 'user', opts = {}) {
  const { role = 'member', status = 'active' } = opts;
  const username = `${name}-${next()}`; // "-" keeps short names above the 3-char minimum
  const { rows } = await db.query(
    `INSERT INTO users (username, display_name, role_key, status)
     VALUES ($1, $2, $3, $4) RETURNING id`,
    [username, name, role, status],
  );
  return { id: rows[0].id, username };
}

export async function mkDevice(db, userId) {
  const { rows } = await db.query(
    `INSERT INTO devices (user_id, name, platform, registration_id, identity_key, signing_key)
     VALUES ($1, 'test device', 'android', $2, $3, $4) RETURNING id`,
    // signing_key must be unique among live devices, so each fixture gets fresh bytes.
    [userId, next() % 16000 || 1, Buffer.alloc(32, 7), crypto.randomBytes(32)],
  );
  return rows[0].id;
}

// 32 bytes derived from a number via SHA-256, standing in for an HMAC output.
// Distinct inputs give distinct hashes, so tests never collide by accident.
export const hashOf = (n) =>
  crypto.createHash('sha256').update(String(n)).digest();

export async function mkCode(db, userId, issuedBy, opts = {}) {
  const { hash = hashOf(next()), expiresSql = `now() + interval '72 hours'` } =
    opts;
  // created_at is set explicitly so that already-expired codes satisfy the
  // expires_at > created_at CHECK.
  const created = opts.createdSql || 'now()';
  const { rows } = await db.query(
    `INSERT INTO activation_codes (user_id, code_hash, issued_by, created_at, expires_at)
     VALUES ($1, $2, $3, ${created}, ${expiresSql}) RETURNING id`,
    [userId, hash, issuedBy],
  );
  return { id: rows[0].id, hash };
}

export async function link(db, a, b, createdBy) {
  const [lo, hi] = a < b ? [a, b] : [b, a];
  const { rows } = await db.query(
    `INSERT INTO contact_links (user_a_id, user_b_id, created_by) VALUES ($1, $2, $3) RETURNING id`,
    [lo, hi, createdBy],
  );
  return rows[0].id;
}

export async function mkGroup(db, createdBy, memberIds = []) {
  const { rows } = await db.query(
    `INSERT INTO groups (name, created_by) VALUES ('group', $1) RETURNING id`,
    [createdBy],
  );
  for (const m of memberIds) {
    await db.query(
      `INSERT INTO group_members (group_id, user_id, added_by) VALUES ($1, $2, $3)`,
      [rows[0].id, m, createdBy],
    );
  }
  return rows[0].id;
}

// Runs a query that is expected to fail and returns the Postgres error, or
// throws if it unexpectedly succeeds. Returning the error lets a test assert on
// the SQLSTATE instead of on fragile message text.
export async function failure(promise) {
  try {
    await promise;
  } catch (e) {
    return e;
  }
  throw new Error('expected the statement to fail, but it succeeded');
}

export const SQLSTATE = {
  integrity: '23000',
  notNull: '23502',
  foreignKey: '23503',
  unique: '23505',
  check: '23514',
  restrict: '23001',
  insufficientPrivilege: '42501',
};
