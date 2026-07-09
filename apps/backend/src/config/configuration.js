// Central source of truth for environment-driven runtime configuration.
// Actual validation/schema (Joi) and secrets wiring land in Phase 2.
export default () => ({
  port: parseInt(process.env.PORT, 10) || 3000,
  database: {
    host: process.env.DATABASE_HOST || 'localhost',
    port: parseInt(process.env.DATABASE_PORT, 10) || 5432,
    username: process.env.DATABASE_USER || 'skyline',
    password: process.env.DATABASE_PASSWORD || 'skyline',
    name: process.env.DATABASE_NAME || 'skyline',
  },
  redis: {
    host: process.env.REDIS_HOST || 'localhost',
    port: parseInt(process.env.REDIS_PORT, 10) || 6379,
  },
  storage: {
    endpoint: process.env.STORAGE_ENDPOINT || 'localhost',
    port: parseInt(process.env.STORAGE_PORT, 10) || 9000,
    accessKey: process.env.STORAGE_ACCESS_KEY || 'skyline',
    secretKey: process.env.STORAGE_SECRET_KEY || 'skyline-secret',
    bucket: process.env.STORAGE_BUCKET || 'skyline-media',
  },
});
