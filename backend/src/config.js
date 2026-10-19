import 'dotenv/config';

export const config = {
  port: Number(process.env.PORT) || 3000,
  mongoUri: process.env.MONGODB_URI,
  jwtSecret: process.env.JWT_SECRET,
  corsOrigin: process.env.CORS_ORIGIN || '*',
};

/** Fail fast on startup instead of on the first request. */
export function assertConfig() {
  const missing = [];
  if (!config.mongoUri || config.mongoUri.includes('<password>')) missing.push('MONGODB_URI');
  if (!config.jwtSecret || config.jwtSecret.startsWith('change-me')) missing.push('JWT_SECRET');
  if (missing.length) {
    throw new Error(
      `Missing/placeholder env vars: ${missing.join(', ')}. Copy .env.example to .env and fill them in.`,
    );
  }
}
