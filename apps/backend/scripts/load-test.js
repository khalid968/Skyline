// Phase 12 load test (owner decision 2026-09-26: up to 500 people on one
// server). Development only, against a THROWAWAY database and server:
//
//   npx babel-node scripts/load-test.js [--people 500] [--rate 50] [--seconds 60] [--keep]
//
// 1. Creates a skyline_e2e_load_* database (it refuses any other name) and
//    seeds N people, one device each, each linked to 10 others.
// 2. Starts the server on :3079 against it, exactly as `npm start` runs it.
// 3. Connects every device's WebSocket, then sends messages at the given rate
//    from random people to random contacts, the way the app does: POST the
//    envelope; the recipient hears the "inbox" nudge, pulls its inbox and
//    acknowledges it.
// 4. Reports send and delivery latency (p50/p95/p99) against the budgets
//    (p95 send < 300 ms, p95 delivery < 1 s), plus the server's own view from
//    the admin overview, then stops the server and drops the database.
//
// The ciphertext is random bytes: the server never decrypts anything, so it
// cannot tell, and the load on it is the same.
import { spawn, spawnSync } from 'child_process';
import crypto from 'crypto';
import path from 'path';
import { Client } from 'pg';
import WebSocket from 'ws';
import dotenv from 'dotenv';
import configuration from '../src/config/configuration';
import { SessionService } from '../src/modules/authorization/session.service';
import { hashPassword } from '../src/modules/auth/admin-auth.service';

dotenv.config({ path: path.join(__dirname, '..', '.env'), quiet: true });

const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? Number(process.argv[i + 1]) : fallback;
};
const PEOPLE = arg('people', 500);
const RATE = arg('rate', 50); // messages per second
const SECONDS = arg('seconds', 60);
const KEEP = process.argv.includes('--keep');
const PORT = 3079;
const BASE = `http://127.0.0.1:${PORT}`;
const LINKS_EACH = 10;
const BUDGET = { sendP95: 300, deliveryP95: 1000 };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const pct = (xs, p) => {
  const s = [...xs].sort((a, b) => a - b);
  return s.length ? s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))] : NaN;
};

function urlFor(name) {
  const u = new URL(process.env.DATABASE_URL || 'postgres://skyline:skyline@localhost:5432/skyline');
  u.pathname = `/${name}`;
  return u.toString();
}

async function asAdmin(fn) {
  const c = new Client({ connectionString: urlFor('postgres') });
  await c.connect();
  try {
    return await fn(c);
  } finally {
    await c.end();
  }
}

async function seed(url) {
  const db = new Client({ connectionString: url });
  db.on('error', () => {}); // the drop at the end may cut it off
  await db.connect();
  try {
    return await seedWith(db);
  } finally {
    await db.end().catch(() => {});
  }
}

async function seedWith(db) {
  const cfg = configuration();
  const sessions = new SessionService(
    { query: (q, p) => db.query(q, p) },
    { get: (k) => k.split('.').reduce((o, p) => o?.[p], cfg) },
    null,
  );
  const people = [];
  for (let i = 0; i < PEOPLE; i++) {
    const { rows } = await db.query(
      `INSERT INTO users (username, display_name, role_key, status) VALUES ($1, $2, 'member', 'active') RETURNING id`,
      [`load-${i}`, `Load ${i}`],
    );
    const d = await db.query(
      `INSERT INTO devices (user_id, name, platform, registration_id, identity_key, signing_key, device_number)
       VALUES ($1, 'load device', 'android', $2, $3, $4, 1) RETURNING id`,
      [rows[0].id, 1 + i, Buffer.concat([Buffer.from([5]), crypto.randomBytes(32)]), crypto.randomBytes(32)],
    );
    await db.query(
      `INSERT INTO signed_prekeys (device_id, key_id, public_key, signature) VALUES ($1, 1, $2, $3)`,
      [d.rows[0].id, Buffer.concat([Buffer.from([5]), crypto.randomBytes(32)]), crypto.randomBytes(64)],
    );
    const tokens = await sessions.createDeviceSession(db, d.rows[0].id);
    people.push({ id: rows[0].id, device: d.rows[0].id, token: tokens.accessToken, contacts: [] });
  }
  // Each person linked to the next LINKS_EACH / 2 on a ring: LINKS_EACH contacts each.
  const issuer = (
    await db.query(`INSERT INTO users (username, display_name, role_key, status) VALUES ('load-admin', 'Load Admin', 'admin', 'active') RETURNING id`)
  ).rows[0].id;
  await db.query('INSERT INTO admin_credentials (user_id, password_hash) VALUES ($1, $2)', [issuer, await hashPassword('load test password')]);
  for (let i = 0; i < PEOPLE; i++) {
    for (let k = 1; k <= LINKS_EACH / 2; k++) {
      const a = people[i];
      const b = people[(i + k) % PEOPLE];
      const [lo, hi] = [a.id, b.id].sort(); // links are stored in canonical order
      await db.query('INSERT INTO contact_links (user_a_id, user_b_id, created_by) VALUES ($1, $2, $3)', [lo, hi, issuer]);
      a.contacts.push(b);
      b.contacts.push(a);
    }
  }
  return people;
}

async function main() {
  const name = `skyline_e2e_load_${Date.now()}`;
  if (!/^skyline_e2e_load_\d+$/.test(name)) throw new Error('refusing: not a throwaway database');
  console.log(`database ${name}: creating and seeding ${PEOPLE} people...`);
  await asAdmin((c) => c.query(`CREATE DATABASE "${name}"`));
  const url = urlFor(name);
  let server;
  try {
    const migrated = spawnSync('npm run migrate:up', {
      cwd: path.join(__dirname, '..'),
      shell: true,
      encoding: 'utf8',
      env: { ...process.env, DATABASE_URL: url },
    });
    if (migrated.status !== 0) throw new Error(`migrations failed:\n${migrated.stderr}`);
    const people = await seed(url);

    server = spawn('npm run start', {
      cwd: path.join(__dirname, '..'),
      shell: true,
      env: { ...process.env, DATABASE_URL: url, PORT: String(PORT), LOG_LEVEL: 'warn', DATABASE_POOL_MAX: String(arg('pool', 10)), RATE_LIMIT_PREFIX: `skyline-load-${Date.now()}`, RATE_LIMIT_SCALE: '1' },
      stdio: ['ignore', 'ignore', 'inherit'],
    });
    for (let i = 0; i < 60; i++) {
      try {
        if ((await fetch(`${BASE}/health`)).ok) break;
      } catch {}
      await sleep(1000);
    }

    const auth = (p) => ({ Authorization: `Bearer ${p.token}` });
    const pending = new Map(); // messageId -> send start
    const sendMs = [];
    const deliveryMs = [];
    let errors = 0;

    // Every device online, the way the app is while open.
    // Like the app: a nudge during a pull means "pull again afterwards".
    const pulling = new Set();
    const again = new Set();
    const pull = async (p) => {
      if (pulling.has(p.id)) {
        again.add(p.id);
        return;
      }
      pulling.add(p.id);
      try {
        const box = await (await fetch(`${BASE}/me/inbox`, { headers: auth(p) })).json();
        const now = performance.now();
        for (const e of box.envelopes ?? []) {
          const t = pending.get(e.messageId);
          if (t !== undefined) {
            deliveryMs.push(now - t);
            pending.delete(e.messageId);
          }
        }
        if (box.envelopes?.length) {
          await fetch(`${BASE}/me/inbox/ack`, {
            method: 'POST',
            headers: { ...auth(p), 'content-type': 'application/json' },
            body: JSON.stringify({ envelopeIds: box.envelopes.map((e) => e.envelopeId) }),
          });
        }
      } catch {
        errors++;
      } finally {
        pulling.delete(p.id);
        if (again.delete(p.id)) pull(p);
      }
    };
    const sockets = await Promise.all(
      people.map(
        (p) =>
          new Promise((resolve, reject) => {
            const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws`, { headers: auth(p) });
            ws.on('message', (m) => {
              const ev = JSON.parse(m);
              if (ev.type === 'ready') resolve(ws);
              if (ev.type === 'inbox') pull(p);
            });
            ws.on('error', reject);
          }),
      ),
    );
    console.log(`${sockets.length} devices connected; sending ${RATE}/s for ${SECONDS}s...`);

    const send = async () => {
      const from = people[crypto.randomInt(PEOPLE)];
      const to = from.contacts[crypto.randomInt(from.contacts.length)];
      const messageId = crypto.randomUUID();
      const start = performance.now();
      pending.set(messageId, start);
      try {
        const r = await fetch(`${BASE}/users/${to.id}/messages`, {
          method: 'POST',
          headers: { ...auth(from), 'content-type': 'application/json' },
          body: JSON.stringify({
            messageId,
            envelopes: [{ userId: to.id, deviceNumber: 1, kind: 'whisper', body: crypto.randomBytes(300).toString('base64') }],
          }),
        });
        sendMs.push(performance.now() - start);
        if (r.status !== 201) {
          errors++;
          pending.delete(messageId);
        }
      } catch {
        errors++;
        pending.delete(messageId);
      }
    };

    const started = Date.now();
    const inflight = [];
    let sent = 0;
    while (Date.now() - started < SECONDS * 1000) {
      const due = Math.floor(((Date.now() - started) / 1000) * RATE);
      while (sent < due) {
        inflight.push(send());
        sent++;
      }
      await sleep(5);
    }
    await Promise.all(inflight);
    for (let i = 0; i < 100 && pending.size; i++) await sleep(100);

    // The server's own view (board 36): p95 and errors from its metrics.
    const login = await fetch(`${BASE}/admin/auth/login`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ username: 'load-admin', password: 'load test password' }),
    });
    const overview = await (
      await fetch(`${BASE}/admin/overview?days=7`, { headers: { Authorization: `Bearer ${(await login.json()).token}` } })
    ).json();

    const report = {
      people: PEOPLE,
      pool: arg('pool', 10),
      targetRate: RATE,
      achievedRate: +(sendMs.length / SECONDS).toFixed(1),
      messages: sendMs.length,
      errors,
      undelivered: pending.size,
      sendMs: { p50: Math.round(pct(sendMs, 50)), p95: Math.round(pct(sendMs, 95)), p99: Math.round(pct(sendMs, 99)) },
      deliveryMs: { p50: Math.round(pct(deliveryMs, 50)), p95: Math.round(pct(deliveryMs, 95)), p99: Math.round(pct(deliveryMs, 99)) },
      server: {
        p95Ms: overview.server?.p95Ms,
        errorsLastHour: overview.server?.errorsLastHour,
        memoryMB: Math.round((overview.server?.memoryBytes ?? 0) / 1048576),
        connectedDevices: overview.services?.find((s) => s.id === 'realtime')?.connectedDevices,
      },
    };
    report.withinBudget =
      report.sendMs.p95 < BUDGET.sendP95 && report.deliveryMs.p95 < BUDGET.deliveryP95 && errors === 0 && pending.size === 0;
    console.log(JSON.stringify(report, null, 2));
    for (const ws of sockets) ws.close();
    process.exitCode = report.withinBudget ? 0 : 1;
  } finally {
    if (server) {
      if (process.platform === 'win32') spawnSync('taskkill', ['/PID', String(server.pid), '/T', '/F']);
      else server.kill('SIGTERM');
    }
    if (!KEEP) {
      await sleep(1000);
      await asAdmin((c) => c.query(`DROP DATABASE IF EXISTS "${name}" WITH (FORCE)`));
      console.log(`database ${name} dropped`);
    } else console.log(`kept database ${name}`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
