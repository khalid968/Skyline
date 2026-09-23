// Phase 7, the whole chain: two devices running the REAL crypto core (Signal's
// libsignal, compiled from crypto-core/) talk to this backend over HTTP. They
// activate, publish prekeys, fetch each other's bundles through the key
// directory, and exchange encrypted messages. See crypto-core/e2e.
//
// Needs the tool built first:  cd crypto-core && cargo build -p skyline_e2e
// Without it this suite is SKIPPED (and says so), so the backend suite does
// not require Rust. The phase sign-off runs it with the tool present.
import fs from 'fs';
import path from 'path';
import { spawn } from 'child_process';
import { createTestDatabase, mkUser, link } from '../db/harness';
import { createTestApp } from './app-harness';
import configuration from '../../src/config/configuration';
import { AuditService } from '../../src/modules/audit/audit.service';
import { issueActivationCode } from '../../src/modules/auth/activation-codes';
import { normalizeActivationCode } from '../../src/modules/auth/auth-crypto';

const TOOL = path.join(
  __dirname,
  '..',
  '..',
  '..',
  '..',
  'crypto-core',
  'target',
  'debug',
  process.platform === 'win32' ? 'skyline-e2e.exe' : 'skyline-e2e',
);
const haveTool = fs.existsSync(TOOL);
const suite = haveTool ? describe : describe.skip;
if (!haveTool) {
  // eslint-disable-next-line no-console
  console.warn(`crypto e2e skipped: build ${TOOL} first (cargo build -p skyline_e2e)`);
}

suite('crypto end to end (real libsignal devices, real backend)', () => {
  let db;
  let t;
  let pepper;
  let audit;
  let issuer;

  beforeAll(async () => {
    db = await createTestDatabase('cryptoe2e');
    audit = new AuditService({ query: (q, p) => db.client.query(q, p) });
    pepper = Buffer.from(configuration().auth.tokenPepper, 'utf8');
    issuer = await mkUser(db.client, 'issuer', { role: 'admin' });
    t = await createTestApp({ db, realAuth: true, listen: true });
  }, 90000);

  afterAll(async () => {
    await t.close();
    await db.drop();
  });

  const code = async (userId) =>
    normalizeActivationCode(
      (await issueActivationCode(db.client, { pepper, userId, issuedBy: issuer.id, audit }))
        .code,
    );

  // Asynchronous on purpose: the server under test runs in THIS process, so a
  // synchronous spawn would block it from answering the tool.
  const runTool = async (alice, bob) => {
    const args = [
      `http://127.0.0.1:${t.port}`,
      alice.id,
      await code(alice.id),
      bob.id,
      await code(bob.id),
    ];
    return new Promise((resolve, reject) => {
      const child = spawn(TOOL, args);
      let stdout = '';
      let stderr = '';
      child.stdout.on('data', (d) => (stdout += d));
      child.stderr.on('data', (d) => (stderr += d));
      child.on('error', reject);
      child.on('close', (status) => resolve({ status, stdout, stderr }));
    });
  };

  it('two linked devices set up a PQXDH session and talk; the server holds only public keys', async () => {
    const alice = await mkUser(db.client, 'alice', { status: 'pending' });
    const bob = await mkUser(db.client, 'bob', { status: 'pending' });
    await link(db.client, alice.id, bob.id, issuer.id);

    const r = await runTool(alice, bob);
    expect([r.status, r.stderr]).toEqual([0, '']);
    const out = JSON.parse(r.stdout);
    expect(out).toMatchObject({ ok: true, oneTimeKeysClaimed: 1 });
    expect(out.safetyNumber).toMatch(/^\d{60}$/);

    // The identity the server registered is the one libsignal generated.
    const { rows } = await db.client.query(
      'SELECT user_id, identity_key FROM devices ORDER BY created_at',
    );
    const byUser = Object.fromEntries(rows.map((d) => [d.user_id, d.identity_key.toString('base64')]));
    expect(byUser[alice.id]).toBe(out.alice.identityKey);
    expect(byUser[bob.id]).toBe(out.bob.identityKey);

    // Every key the server holds is a public-key-sized value: no 32-byte
    // private scalars, and no table for anything but public prekeys.
    const sizes = await db.client.query(`
      SELECT DISTINCT octet_length(public_key) AS n FROM signed_prekeys
      UNION SELECT DISTINCT octet_length(public_key) FROM one_time_prekeys
      UNION SELECT DISTINCT octet_length(public_key) FROM kyber_prekeys`);
    expect(sizes.rows.map((x) => x.n).sort((a, b) => a - b)).toEqual([33, 1569]);
  }, 120000);

  it('without a contact link, the key directory refuses (404) and no session can start', async () => {
    const alice = await mkUser(db.client, 'lonely', { status: 'pending' });
    const bob = await mkUser(db.client, 'unlinked', { status: 'pending' });
    const r = await runTool(alice, bob);
    expect(r.status).toBe(1);
    expect(r.stderr).toMatch(/HTTP 404/);
  }, 120000);
});
