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
    redis: {
      host: process.env.REDIS_HOST || 'localhost',
      port: parseInt(process.env.REDIS_PORT, 10) || 6379,
      channel: process.env.REDIS_EVENTS_CHANNEL || 'skyline:events',
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
