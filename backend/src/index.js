import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import rateLimit from 'express-rate-limit';
import mongoose from 'mongoose';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { assertConfig, config } from './config.js';

import authRouter from './routes/auth.js';
import mangaRouter from './routes/manga.js';
import libraryRouter from './routes/library.js';
import progressRouter from './routes/progress.js';
import updatesRouter from './routes/updates.js';

function logJson(level, msg, extra = {}) {
  const line = JSON.stringify({
    ts: new Date().toISOString(),
    level,
    msg,
    ...extra,
  });
  if (level === 'error') console.error(line);
  else if (level === 'warn') console.warn(line);
  else console.log(line);
}

export function createApp() {
  const app = express();

  app.set('trust proxy', 1);

  app.use(
    helmet({
      crossOriginResourcePolicy: { policy: 'cross-origin' },
    }),
  );

  const corsOriginSetting = config.corsOrigin.trim();
  const isWildcard = corsOriginSetting === '*';
  const allowedOrigins = isWildcard
    ? []
    : corsOriginSetting
        .split(',')
        .map((o) => o.trim())
        .filter(Boolean);

  app.use(
    cors({
      origin: (origin, callback) => {
        // Native mobile clients & curl omit Origin header
        if (!origin) return callback(null, true);
        if (isWildcard) return callback(null, true);
        if (allowedOrigins.includes(origin)) return callback(null, true);
        return callback(null, false);
      },
      // Never combine credentials: true with wildcard origin
      credentials: !isWildcard,
    }),
  );

  app.use(express.json({ limit: '1mb' }));

  const limiter = rateLimit({
    windowMs: 60 * 1000,
    max: 120,
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: 'Too many requests, please slow down.' },
  });
  app.use('/api/', limiter);

  app.get('/api/health', (req, res) => {
    res.json({
      status: 'ok',
      timestamp: new Date().toISOString(),
      mongo: mongoose.connection.readyState === 1 ? 'connected' : 'disconnected',
      database: mongoose.connection.readyState === 1 ? 'connected' : 'disconnected',
    });
  });

  app.get('/', (req, res) => {
    res.json({
      app: 'Shiori Manga Reader API',
      endpoints: {
        health: '/api/health',
        auth: '/api/auth',
        manga: '/api/manga',
        library: '/api/library',
        progress: '/api/progress',
        updates: '/api/updates',
      },
    });
  });

  app.use('/api/auth', authRouter);
  app.use('/api/manga', mangaRouter);
  app.use('/api/library', libraryRouter);
  app.use('/api/progress', progressRouter);
  app.use('/api/updates', updatesRouter);

  app.use((req, res) => {
    res.status(404).json({ error: 'Endpoint not found' });
  });

  app.use((err, req, res, next) => {
    logJson('error', 'unhandled_route_error', { path: req.path, error: err.message });
    res.status(err.status || 500).json({ error: err.message || 'Internal server error' });
  });

  return app;
}

async function startServer() {
  // Fail fast if JWT_SECRET is missing or insecure
  assertConfig({ requireMongo: false });

  const uri = config.mongoUri;
  if (!uri || uri.includes('<password>')) {
    logJson('warn', 'mongodb_not_configured', {
      note: 'Public MangaDex browsing works without MongoDB; configure MONGODB_URI for sync.',
    });
  } else {
    try {
      logJson('info', 'mongodb_connecting');
      await mongoose.connect(uri, { serverSelectionTimeoutMS: 8000 });
      logJson('info', 'mongodb_connected');
    } catch (err) {
      logJson('error', 'mongodb_connection_failed', { error: err.message });
    }
  }

  const app = createApp();
  const server = app.listen(config.port, () => {
    logJson('info', 'server_listening', { port: config.port });
  });

  let shuttingDown = false;
  async function shutdown(signal) {
    if (shuttingDown) return;
    shuttingDown = true;
    logJson('info', 'shutdown_started', { signal });
    server.close(async () => {
      try {
        if (mongoose.connection.readyState !== 0) {
          await mongoose.connection.close();
        }
      } catch (err) {
        logJson('error', 'mongodb_close_error', { error: err.message });
      }
      logJson('info', 'shutdown_complete');
      process.exit(0);
    });
    setTimeout(() => process.exit(1), 10_000).unref();
  }

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

const isMainModule =
  process.argv[1] &&
  path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));

if (isMainModule) {
  startServer();
}
