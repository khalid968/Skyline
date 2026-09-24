import fs from 'fs';
// Fails fast at boot on missing or unsafe configuration.
//
// Every problem is collected and reported together, so an operator fixes them
// in one pass. Error messages name the variable and never print its value: a
// mistyped secret in a log line is still a leaked secret.

const ENVIRONMENTS = ['development', 'test', 'production'];
const LOG_LEVELS = ['error', 'warn', 'log', 'debug', 'verbose', 'silent'];

// Values that ship in .env.example or the dev compose file. Fine on a laptop,
// never acceptable in production.
const PLACEHOLDER_SECRETS = new Set([
  '',
  'skyline',
  'skyline-secret',
  'change-me',
  'password',
  'secret',
]);

function parsePort(name, raw, fallback, problems) {
  if (raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1 || n > 65535) {
    problems.push(`${name} must be an integer between 1 and 65535`);
    return fallback;
  }
  return n;
}

function databaseUrl(env, problems) {
  if (env.DATABASE_URL) {
    let u;
    try {
      u = new URL(env.DATABASE_URL);
    } catch {
      problems.push('DATABASE_URL is not a valid URL');
      return undefined;
    }
    if (u.protocol !== 'postgres:' && u.protocol !== 'postgresql:') {
      problems.push(
        'DATABASE_URL must use the postgres:// or postgresql:// scheme',
      );
      return undefined;
    }
    return env.DATABASE_URL;
  }

  const host = env.DATABASE_HOST || 'localhost';
  const port = parsePort('DATABASE_PORT', env.DATABASE_PORT, 5432, problems);
  const user = env.DATABASE_USER || 'skyline';
  const password = env.DATABASE_PASSWORD ?? 'skyline';
  const name = env.DATABASE_NAME || 'skyline';
  return `postgres://${encodeURIComponent(user)}:${encodeURIComponent(password)}@${host}:${port}/${name}`;
}

export function validateEnv(env) {
  const problems = [];

  const nodeEnv = env.NODE_ENV || 'development';
  if (!ENVIRONMENTS.includes(nodeEnv)) {
    problems.push(`NODE_ENV must be one of: ${ENVIRONMENTS.join(', ')}`);
  }

  const logLevel = env.LOG_LEVEL || (nodeEnv === 'test' ? 'silent' : 'log');
  if (!LOG_LEVELS.includes(logLevel)) {
    problems.push(`LOG_LEVEL must be one of: ${LOG_LEVELS.join(', ')}`);
  }

  const port = parsePort('PORT', env.PORT, 3000, problems);
  parsePort('REDIS_PORT', env.REDIS_PORT, 6379, problems);
  parsePort('STORAGE_PORT', env.STORAGE_PORT, 9000, problems);

  const dbUrl = databaseUrl(env, problems);

  if (env.RATE_LIMIT_SCALE !== undefined && env.RATE_LIMIT_SCALE !== '') {
    const scale = Number(env.RATE_LIMIT_SCALE);
    if (!Number.isFinite(scale) || scale <= 0) {
      problems.push('RATE_LIMIT_SCALE must be a positive number');
    } else if (nodeEnv === 'production' && scale !== 1) {
      problems.push('RATE_LIMIT_SCALE may only be changed outside production');
    }
  }

  if (nodeEnv === 'production') {
    // These keys protect every stored activation code, session token and 2FA
    // secret. Development falls back to fixed, clearly-labelled values;
    // production must supply real ones.
    for (const name of ['AUTH_TOKEN_PEPPER', 'AUTH_TOTP_KEY']) {
      const v = env[name];
      if (!v || v.length < 32 || v.startsWith('dev-only')) {
        problems.push(
          `${name} must be set to a random secret of at least 32 characters in production`,
        );
      }
    }
  }

  if (nodeEnv === 'production' && dbUrl) {
    let dbPassword = '';
    try {
      dbPassword = decodeURIComponent(new URL(dbUrl).password);
    } catch {
      // already reported above
    }
    if (PLACEHOLDER_SECRETS.has(dbPassword)) {
      problems.push(
        'the database password is empty or a development placeholder, which is not allowed in production',
      );
    }
    if (PLACEHOLDER_SECRETS.has(env.STORAGE_SECRET_KEY ?? 'skyline-secret')) {
      problems.push(
        'STORAGE_SECRET_KEY is missing or a development placeholder, which is not allowed in production',
      );
    }
    if (PLACEHOLDER_SECRETS.has(env.STORAGE_ACCESS_KEY ?? 'skyline')) {
      problems.push(
        'STORAGE_ACCESS_KEY is missing or a development placeholder, which is not allowed in production',
      );
    }
  }

  if (env.FCM_SERVICE_ACCOUNT_FILE) {
    try {
      const sa = JSON.parse(
        fs.readFileSync(env.FCM_SERVICE_ACCOUNT_FILE, 'utf8'),
      );
      if (!sa.project_id || !sa.client_email || !sa.private_key)
        throw new Error('fields');
    } catch {
      problems.push(
        'FCM_SERVICE_ACCOUNT_FILE must point to a readable Google service-account JSON file',
      );
    }
  }

  if (problems.length > 0) {
    throw new Error(
      `Invalid configuration:\n${problems.map((p) => `  - ${p}`).join('\n')}`,
    );
  }

  return { ...env, NODE_ENV: nodeEnv, LOG_LEVEL: logLevel, PORT: String(port) };
}
