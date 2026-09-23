// Creates an administrator who can sign in to the dashboard.
//
//   npm run admin:create -- --username amina --display-name "Amina Diallo"
//
// The password is asked for at the prompt (not echoed), or read from
// SKYLINE_ADMIN_PASSWORD for scripted setups. It must be at least 12 characters.
//
// By design this refuses to run once an administrator already exists: its job
// is bootstrapping the FIRST one. Later admins are created from the dashboard,
// which leaves an audit trail naming who created them. Pass --additional to
// override, which is itself recorded in the audit log.
import { loadConfig, connect, parseArgs, askHidden, run } from './cli-support';
import { hashPassword } from '../modules/auth/admin-auth.service';

run(async () => {
  const args = parseArgs(process.argv.slice(2));
  const username =
    typeof args.username === 'string' ? args.username.trim().toLowerCase() : '';
  const displayName =
    typeof args['display-name'] === 'string'
      ? args['display-name'].trim()
      : username;
  if (!username)
    throw new Error(
      'usage: npm run admin:create -- --username <name> [--display-name "Full Name"]',
    );

  const config = loadConfig();
  const { pool, audit } = connect(config);
  try {
    const existing = await pool.query(
      `SELECT count(*)::int AS n FROM users u JOIN admin_credentials c ON c.user_id = u.id
        WHERE u.role_key = 'admin' AND u.status = 'active'`,
    );
    if (existing.rows[0].n > 0 && !args.additional) {
      throw new Error(
        'an administrator already exists. Create further admins from the dashboard, or pass --additional.',
      );
    }

    const password =
      process.env.SKYLINE_ADMIN_PASSWORD ||
      (await askHidden('Password (12+ characters): '));
    if (!password || password.length < 12)
      throw new Error('the password must be at least 12 characters');
    if (!process.env.SKYLINE_ADMIN_PASSWORD) {
      const again = await askHidden('Repeat password: ');
      if (again !== password) throw new Error('the passwords do not match');
    }

    const passwordHash = await hashPassword(password);
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const { rows } = await client.query(
        // The first administrator becomes the protected owner (migration 010);
        // an --additional admin created here never does.
        `INSERT INTO users (username, display_name, role_key, status, is_owner)
         VALUES ($1, $2, 'admin', 'active',
                 NOT EXISTS (SELECT 1 FROM users WHERE is_owner) AND NOT $3::boolean)
         RETURNING id, is_owner`,
        [username, displayName, !!args.additional],
      );
      await client.query(
        'INSERT INTO admin_credentials (user_id, password_hash) VALUES ($1, $2)',
        [rows[0].id, passwordHash],
      );
      await audit.record(
        {
          action: 'users.create',
          target: { userId: rows[0].id },
          detail: {
            via: 'command_line',
            role: 'admin',
            additional: !!args.additional,
            owner: rows[0].is_owner,
          },
        },
        client,
      );
      await client.query('COMMIT');
      console.log(
        `\n${rows[0].is_owner ? 'Owner' : 'Administrator'} "${username}" created. Sign in to the dashboard with this password.`,
      );
      console.log(
        'Two-factor sign-in is off; it can be turned on from the dashboard once you are signed in.',
      );
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    } finally {
      client.release();
    }
  } finally {
    await pool.end();
  }
});
