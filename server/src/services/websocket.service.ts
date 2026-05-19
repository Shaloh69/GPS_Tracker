import { Server as HttpServer } from 'http';
import { Server as SocketServer, Socket } from 'socket.io';
import { verifyToken } from '../utils/auth';
import { pool } from '../config/database';
import { logger } from '../utils/logger';
import { config } from '../config/env';

let io: SocketServer;

export function initSocket(server: HttpServer): SocketServer {
  io = new SocketServer(server, {
    cors: {
      origin: config.cors.origin,
      methods: ['GET', 'POST'],
      credentials: true,
    },
    pingTimeout: 20000,
    pingInterval: 25000,
  });

  // ── Auth middleware ───────────────────────────────────────────────────────
  io.use((socket, next) => {
    const token = socket.handshake.auth?.token as string | undefined;
    if (!token) {
      next(new Error('Authentication required'));
      return;
    }
    try {
      const payload = verifyToken(token);
      if (payload.type !== 'access') throw new Error();
      (socket as any).userId = payload.id;
      next();
    } catch {
      next(new Error('Invalid token'));
    }
  });

  io.on('connection', (socket: Socket) => {
    const userId: string = (socket as any).userId;
    logger.debug(`WS connected: ${socket.id} (user ${userId})`);

    // ── Subscribe to a device's live feed ─────────────────────────────────
    socket.on('join:device', async (deviceId: string) => {
      if (typeof deviceId !== 'string') return;
      try {
        // Verify the requesting user owns this device
        const [rows] = await pool.execute<any[]>(
          'SELECT id FROM devices WHERE id = ? AND owner_id = ?',
          [deviceId, userId]
        );
        if (!rows.length) {
          socket.emit('error', { message: 'Device not found or access denied' });
          return;
        }
        socket.join(`device:${deviceId}`);
        logger.debug(`${socket.id} joined device:${deviceId}`);
        socket.emit('joined:device', { deviceId });
      } catch (err) {
        logger.error('join:device error', err);
      }
    });

    // ── Unsubscribe ────────────────────────────────────────────────────────
    socket.on('leave:device', (deviceId: string) => {
      if (typeof deviceId !== 'string') return;
      socket.leave(`device:${deviceId}`);
      logger.debug(`${socket.id} left device:${deviceId}`);
    });

    socket.on('disconnect', (reason) => {
      logger.debug(`WS disconnected: ${socket.id} — ${reason}`);
    });
  });

  logger.info('WebSocket server initialised');
  return io;
}

export function getIO(): SocketServer {
  if (!io) throw new Error('Socket.IO not initialised — call initSocket first');
  return io;
}
