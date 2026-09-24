// Development only: sends ONE real, content-free wake-up through Firebase to
// the live push token of a device in a THROWAWAY (skyline_e2e_*) database.
// Used by the push integration test; never part of the server.
//
//   FCM_SERVICE_ACCOUNT_FILE=... npx babel-node scripts/push-probe.js <database-url> <device-id>
import { Client } from 'pg';
import { FcmTransport } from '../src/modules/notifications/push.transport';

const [url, deviceId] = process.argv.slice(2);

async function main() {
  if (!url || !/\/skyline_e2e_\d+$/.test(new URL(url).pathname)) {
    throw new Error('refusing: not a skyline_e2e_ database');
  }
  const db = new Client({ connectionString: url });
  await db.connect();
  try {
    const { rows } = await db.query(
      `SELECT provider, token FROM push_tokens WHERE device_id = $1 AND revoked_at IS NULL`,
      [deviceId],
    );
    if (!rows[0]) throw new Error('no live push token for that device');
    const t = new FcmTransport(process.env.FCM_SERVICE_ACCOUNT_FILE);
    const outcome = await t.send(rows[0].provider, rows[0].token);
    process.stdout.write(`${outcome}\n`);
    if (outcome !== 'ok') process.exit(2);
  } finally {
    await db.end();
  }
}

main().catch((err) => {
  process.stderr.write(`${err.message}\n`);
  process.exit(1);
});
