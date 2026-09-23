// Invites a member: creates their account if it does not exist yet, then
// issues a fresh one-time activation code and prints it ONCE.
//
//   npm run user:invite -- --username sarah.w --display-name "Sarah Whitfield"
//   npm run user:invite -- --username sarah.w          (a new code for an existing member)
//
// Any earlier unredeemed code for that person stops working. The code is
// shown here and nowhere else: it is not stored, logged or recoverable.
//
// This is a stop-gap until the dashboard (Phase 6) does the same thing with a
// screen. --by names the administrator the audit log records as the issuer
// (defaults to the longest-serving active admin).
import { loadConfig, connect, parseArgs, run } from './cli-support';
import { issueActivationCode } from '../modules/auth/activation-codes';

run(async () => {
  const args = parseArgs(process.argv.slice(2));
  const username =
    typeof args.username === 'string' ? args.username.trim().toLowerCase() : '';
  if (!username) {
    throw new Error(
      'usage: npm run user:invite -- --username <name> [--display-name "Full Name"] [--by <admin>]',
    );
  }

  const config = loadConfig();
  const { pool, audit } = connect(config);
  const client = await pool.connect();
  try {
    const issuer = await client.query(
      `SELECT id, username::text AS username FROM users
        WHERE role_key = 'admin' AND status = 'active' ${typeof args.by === 'string' ? 'AND username = $1' : ''}
        ORDER BY created_at LIMIT 1`,
      typeof args.by === 'string' ? [args.by] : [],
    );
    if (!issuer.rows[0])
      throw new Error(
        'no active administrator to issue the code. Run admin:create first.',
      );
    const issuedBy = issuer.rows[0].id;

    await client.query('BEGIN');
    let user = (
      await client.query('SELECT id, status FROM users WHERE username = $1', [
        username,
      ])
    ).rows[0];

    if (!user) {
      const displayName =
        typeof args['display-name'] === 'string'
          ? args['display-name'].trim()
          : username;
      const created = await client.query(
        `INSERT INTO users (username, display_name, role_key, status, created_by)
         VALUES ($1, $2, 'member', 'pending', $3) RETURNING id, status`,
        [username, displayName, issuedBy],
      );
      user = created.rows[0];
      await audit.record(
        {
          action: 'users.create',
          actor: { userId: issuedBy },
          target: { userId: user.id },
          detail: { via: 'command_line', role: 'member' },
        },
        client,
      );
    } else if (!['pending', 'active'].includes(user.status)) {
      throw new Error(
        `"${username}" is ${user.status}; reinstate the account before issuing a code`,
      );
    }

    const { code, expiresAt } = await issueActivationCode(client, {
      pepper: Buffer.from(config.auth.tokenPepper, 'utf8'),
      userId: user.id,
      issuedBy,
      audit,
    });
    await client.query('COMMIT');

    console.log(
      `\nActivation code for "${username}" (issued by ${issuer.rows[0].username}):\n`,
    );
    console.log(`    ${code}\n`);
    console.log(`Single use. Expires ${new Date(expiresAt).toLocaleString()}.`);
    console.log(
      'This is the only time it is shown. Any earlier code for this person no longer works.',
    );
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    client.release();
    await pool.end();
  }
});
