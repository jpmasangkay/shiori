import 'dotenv/config';

export const config = {
  get port() {
    return Number(process.env.PORT) || 3000;
  },
  get mongoUri() {
    return process.env.MONGODB_URI || '';
  },
  get jwtSecret() {
    return process.env.JWT_SECRET || '';
  },
  get corsOrigin() {
    return process.env.CORS_ORIGIN || '*';
  },
  get nodeEnv() {
    return process.env.NODE_ENV || 'development';
  },
};

export function getJwtSecret() {
  const secret = config.jwtSecret.trim();
  if (!secret || secret.startsWith('change-me') || secret === 'dev-fallback-secret' || secret.length < 16) {
    throw new Error(
      'JWT_SECRET is missing, insecure, or shorter than 16 characters. Set a strong JWT_SECRET in your environment.',
    );
  }
  return secret;
}

/** Fail fast on startup instead of silently falling back to insecure defaults. */
export function assertConfig({ requireMongo = false } = {}) {
  const missing = [];
  if (requireMongo && (!config.mongoUri || config.mongoUri.includes('<password>'))) {
    missing.push('MONGODB_URI');
  }
  try {
    getJwtSecret();
  } catch {
    missing.push('JWT_SECRET (>= 16 chars, non-placeholder)');
  }
  if (missing.length) {
    throw new Error(
      `Missing/invalid env vars: ${missing.join(', ')}. Copy .env.example to .env and configure them.`,
    );
  }
}
