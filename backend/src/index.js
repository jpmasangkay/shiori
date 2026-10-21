import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import rateLimit from 'express-rate-limit';
import mongoose from 'mongoose';
import { config } from './config.js';

import authRouter from './routes/auth.js';
import mangaRouter from './routes/manga.js';
import libraryRouter from './routes/library.js';
import progressRouter from './routes/progress.js';
import updatesRouter from './routes/updates.js';

const app = express();

// Security and standard middlewares
app.use(
  helmet({
    crossOriginResourcePolicy: { policy: 'cross-origin' },
  }),
);
app.use(
  cors({
    origin: (origin, callback) => {
      // Allow mobile apps (no Origin header) and configured origins
      if (!origin || config.corsOrigin === '*') return callback(null, true);
      const allowed = config.corsOrigin.split(',').map((o) => o.trim());
      if (allowed.includes(origin)) return callback(null, true);
      return callback(null, true); // Fallback permissive for mobile/local dev
    },
    credentials: true,
  }),
);
app.use(express.json({ limit: '1mb' }));

// General rate limiter: 120 reqs / min
const limiter = rateLimit({
  windowMs: 60 * 1000,
  max: 120,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many requests, please slow down.' },
});
app.use('/api/', limiter);

// Health check endpoint
app.get('/api/health', (req, res) => {
  res.json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    mongo: mongoose.connection.readyState === 1 ? 'connected' : 'disconnected',
  });
});

// Root welcome / API summary
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

// Mount modular routes
app.use('/api/auth', authRouter);
app.use('/api/manga', mangaRouter);
app.use('/api/library', libraryRouter);
app.use('/api/progress', progressRouter);
app.use('/api/updates', updatesRouter);

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Endpoint not found' });
});

// Central error handler
app.use((err, req, res, next) => {
  console.error('[Error]', err);
  res.status(err.status || 500).json({ error: err.message || 'Internal server error' });
});

// MongoDB connection with graceful degradation
async function startServer() {
  const uri = config.mongoUri;
  if (!uri || uri.includes('<password>')) {
    console.warn('\n⚠️ [MongoDB] MONGODB_URI is not configured in backend/.env.');
    console.warn('   Public MangaDex browsing, search, and reading will work without MongoDB.');
    console.warn('   To enable user accounts, saved library, and history, configure MONGODB_URI.\n');
  } else {
    try {
      console.log('Connecting to MongoDB...');
      await mongoose.connect(uri, { serverSelectionTimeoutMS: 8000 });
      console.log('✅ Connected to MongoDB successfully.');
    } catch (err) {
      console.error('⚠️ [MongoDB] Connection error:', err.message);
      console.warn('   Continuing server startup without database persistence.\n');
    }
  }

  app.listen(config.port, () => {
    console.log(`🚀 Shiori API server listening on http://localhost:${config.port}`);
  });
}

startServer();
