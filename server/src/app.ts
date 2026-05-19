import 'dotenv/config';
import http from 'http';
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import compression from 'compression';
import rateLimit from 'express-rate-limit';

import { config } from './config/env';
import { testConnection } from './config/database';
import { logger } from './utils/logger';
import { initSocket } from './services/websocket.service';
import { errorHandler } from './middleware/error.middleware';

import authRoutes    from './routes/auth.routes';
import trackerRoutes from './routes/tracker.routes';

const app = express();
const server = http.createServer(app);

// ── Security & parsing ───────────────────────────────────────────────────────
app.use(helmet());
app.use(compression());
app.use(cors({
  origin: config.cors.origin,
  credentials: true,
  methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
}));
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: true }));

// ── Rate limiting ────────────────────────────────────────────────────────────
app.use(rateLimit({
  windowMs: config.rateLimit.windowMs,
  max: config.rateLimit.maxRequests,
  standardHeaders: true,
  legacyHeaders: false,
  message: { success: false, message: 'Too many requests, please slow down.' },
}));

// ── Routes ───────────────────────────────────────────────────────────────────
const api = config.apiPrefix;
app.use(`${api}/auth`,    authRoutes);
app.use(`${api}/tracker`, trackerRoutes);

app.get('/health', (_req, res) => res.json({ status: 'ok', timestamp: new Date() }));

// ── 404 ──────────────────────────────────────────────────────────────────────
app.use((_req, res) => res.status(404).json({ success: false, message: 'Not found' }));

// ── Error handler ────────────────────────────────────────────────────────────
app.use(errorHandler);

// ── Bootstrap ────────────────────────────────────────────────────────────────
async function bootstrap(): Promise<void> {
  await testConnection();
  logger.info('Database connected');

  initSocket(server);

  server.listen(config.port, () => {
    logger.info(`GPS Tracker server running on port ${config.port}`);
    logger.info(`API prefix: ${api}`);
    logger.info(`Environment: ${config.nodeEnv}`);
  });
}

bootstrap().catch((err) => {
  logger.error('Failed to start server', err);
  process.exit(1);
});
