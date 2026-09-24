// Central source of truth for environment-driven runtime configuration.
// Validation lives in validate-env.js and runs at boot, before this is read.
export default () => {
  const db = {
    host: process.env.DATABASE_HOST || 'localhost',
    port: parseInt(process.env.DATABASE_PORT, 10) || 5432,
    username: process.env.DATABASE_USER || 'skyline',
    password: process.env.DATABASE_PASSWORD ?? 'skyline',
    name: process.env.DATABASE_NAME || 'skyline',
  };

  return {
    env: process.env.NODE_ENV || 'development',
    port: parseInt(process.env.PORT, 10) || 3000,
    logLevel:
      process.env.LOG_LEVEL ||
      (process.env.NODE_ENV === 'test' ? 'silent' : 'log'),
    database: {
      ...db,
      // DATABASE_URL wins when set; otherwise it is assembled from the parts.
      url:
        process.env.DATABASE_URL ||
        `postgres://${encodeURIComponent(db.username)}:${encodeURIComponent(db.password)}@${db.host}:${db.port}/${db.name}`,
      poolMax: parseInt(process.env.DATABASE_POOL_MAX, 10) || 10,
    },
    push: {
      // Google service-account JSON for Firebase Cloud Messaging (Android
      // wake-ups). Unset: no push; the socket still works while the app runs.
      fcmServiceAccountFile: process.env.FCM_SERVICE_ACCOUNT_FILE || null,
    },
    redis: {
      host: process.env.REDIS_HOST || 'localhost',
      port: parseInt(process.env.REDIS_PORT, 10) || 6379,
      channel: process.env.REDIS_EVENTS_CHANNEL || 'skyline:events',
    },
    auth: {
      // HMAC key for every stored activation code and session token. Changing
      // it invalidates all of them at once: every device must re-activate.
      tokenPepper:
        process.env.AUTH_TOKEN_PEPPER ||
        'dev-only-token-pepper-never-use-in-production',
      // Encrypts each administrator's 2FA secret at rest. Changing it disables
      // everyone's 2FA until they set it up again.
      totpKey:
        process.env.AUTH_TOTP_KEY ||
        'dev-only-totp-key-never-use-in-production',
    },
    rateLimit: {
      prefix: process.env.RATE_LIMIT_PREFIX || 'skyline',
      // Multiplies every limit. Tests raise it so that dozens of requests from
      // one address do not trip limits meant for real attackers; production
      // refuses anything but 1 (validate-env.js).
      scale: Number(process.env.RATE_LIMIT_SCALE) || 1,
    },
    storage: {
      endpoint: process.env.STORAGE_ENDPOINT || 'localhost',
      port: parseInt(process.env.STORAGE_PORT, 10) || 9000,
      accessKey: process.env.STORAGE_ACCESS_KEY || 'skyline',
      secretKey: process.env.STORAGE_SECRET_KEY || 'skyline-secret',
      bucket: process.env.STORAGE_BUCKET || 'skyline-media',
    },
  };
};
