// Development only: a THROWAWAY database for end-to-end tests of the app.
//
//   npx babel-node scripts/e2e-fixture.js create   -> prints JSON: the database
//        URL, two linked people (alice, bob), a third (carol, NOT linked to
//        alice), a group of all three, and a one-time activation code each
//   npx babel-node scripts/e2e-fixture.js drop <database-name>
//
// It refuses any database whose name does not start with skyline_e2e_, so it
// can never touch a real one (progress-log 2026-09-23: prove the target is
// throwaway before creating accounts).
import { spawnSync } from 'child_process';
import path from 'path';
import { Client } from 'pg';
import dotenv from 'dotenv';
import configuration from '../src/config/configuration';
import { AuditService } from '../src/modules/audit/audit.service';
import { issueActivationCode } from '../src/modules/auth/activation-codes';
import { hashPassword } from '../src/modules/auth/admin-auth.service';
import crypto from 'crypto';

dotenv.config({ path: path.join(__dirname, '..', '.env'), quiet: true });

const PREFIX = 'skyline_e2e_';

function urlFor(name) {
  const u = new URL(process.env.DATABASE_URL);
  u.pathname = `/${name}`;
  return u.toString();
}

async function admin(fn) {
  const c = new Client({ connectionString: urlFor('postgres') });
  await c.connect();
  try {
    return await fn(c);
  } finally {
    await c.end();
  }
}

async function create() {
  const name = `${PREFIX}${Date.now()}`;
  await admin((c) => c.query(`CREATE DATABASE "${name}"`));
  const url = urlFor(name);
  const migrated = spawnSync('npm run migrate:up', {
    cwd: path.join(__dirname, '..'),
    shell: true,
    encoding: 'utf8',
    env: { ...process.env, DATABASE_URL: url },
  });
  if (migrated.status !== 0) throw new Error(`migrations failed:\n${migrated.stderr}`);

  const db = new Client({ connectionString: url });
  await db.connect();
  try {
    const audit = new AuditService({ query: (q, p) => db.query(q, p) });
    const pepper = Buffer.from(configuration().auth.tokenPepper, 'utf8');
    const mk = async (username, displayName, role = 'member', status = 'pending') =>
      (
        await db.query(
          `INSERT INTO users (username, display_name, role_key, status) VALUES ($1, $2, $3, $4) RETURNING id`,
          [username, displayName, role, status],
        )
      ).rows[0].id;
    const issuer = await mk('fixture.admin', 'Fixture Admin', 'admin', 'active');
    // A dashboard password for tests that act as an operator (suspending
    // someone, for board 40). Random, and only ever in this throwaway database.
    const operatorPassword = crypto.randomBytes(12).toString('base64url');
    await db.query('INSERT INTO admin_credentials (user_id, password_hash, must_change_password) VALUES ($1, $2, false)', [
      issuer,
      await hashPassword(operatorPassword),
    ]);
    const alice = await mk('alice.e2e', 'Alice Example');
    const bob = await mk('bob.e2e', 'Bob Example');
    const carol = await mk('carol.e2e', 'Carol Example');
    const [lo, hi] = [alice, bob].sort();
    await db.query(
      `INSERT INTO contact_links (user_a_id, user_b_id, created_by) VALUES ($1, $2, $3)`,
      [lo, hi, issuer],
    );
    // Phase 8b: a group with all three (carol shares it with alice, no link).
    const group = (
      await db.query(`INSERT INTO groups (name, created_by) VALUES ('Test group', $1) RETURNING id`, [issuer])
    ).rows[0].id;
    await db.query(`INSERT INTO chats (kind, group_id) VALUES ('group', $1)`, [group]);
    for (const m of [alice, bob, carol]) {
      await db.query(`INSERT INTO group_members (group_id, user_id, added_by) VALUES ($1, $2, $3)`, [group, m, issuer]);
    }
    const code = async (userId) =>
      (await issueActivationCode(db, { pepper, userId, issuedBy: issuer, audit })).code;
    process.stdout.write(
      JSON.stringify({
        database: name,
        url,
        alice: { userId: alice, code: await code(alice) },
        bob: { userId: bob, code: await code(bob) },
        carol: { userId: carol, code: await code(carol) },
        groupId: group,
        operator: { username: 'fixture.admin', password: operatorPassword },
      }),
    );
  } finally {
    await db.end();
  }
}

async function drop(name) {
  if (!name || !name.startsWith(PREFIX)) {
    throw new Error(`refusing to drop "${name}": not a ${PREFIX} database`);
  }
  await admin((c) => c.query(`DROP DATABASE IF EXISTS "${name}" WITH (FORCE)`));
}

const [cmd, arg] = process.argv.slice(2);
(cmd === 'create' ? create() : cmd === 'drop' ? drop(arg) : Promise.reject(new Error('usage: create | drop <name>')))
  .then(() => process.exit(0))
  .catch((err) => {
    process.stderr.write(`${err.message}\n`);
    process.exit(1);
  });
