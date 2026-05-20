import { Response, NextFunction } from 'express';
import { verifyToken } from '../utils/auth';
import { pool } from '../config/database';
import { logger } from '../utils/logger';
import { AuthRequest } from '../types';

export function requireAuth(req: AuthRequest, res: Response, next: NextFunction): void {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) {
    res.status(401).json({ success: false, message: 'Unauthorized' });
    return;
  }
  try {
    const payload = verifyToken(header.slice(7));
    if (payload.type !== 'access') throw new Error();
    req.user = { id: payload.id, email: payload.email, role: payload.role };
    next();
  } catch {
    res.status(401).json({ success: false, message: 'Invalid or expired token' });
  }
}

export function requireAdmin(req: AuthRequest, res: Response, next: NextFunction): void {
  requireAuth(req, res, () => {
    if (req.user?.role !== 'admin') {
      res.status(403).json({ success: false, message: 'Forbidden' });
      return;
    }
    next();
  });
}

export async function requireDeviceKey(
  req: AuthRequest,
  res: Response,
  next: NextFunction
): Promise<void> {
  const apiKey = req.headers['x-api-key'] as string | undefined;
  if (!apiKey) {
    logger.warn('[AUTH] Device request missing X-Api-Key header');
    res.status(401).json({ success: false, message: 'X-Api-Key header required' });
    return;
  }
  try {
    const [rows] = await pool.execute<any[]>(
      'SELECT id, name FROM devices WHERE api_key = ? AND is_active = TRUE',
      [apiKey]
    );
    if (!rows.length) {
      logger.warn(`[AUTH] Invalid API key: ${apiKey.slice(0, 8)}… — no matching active device`);
      res.status(401).json({ success: false, message: 'Invalid API key' });
      return;
    }
    req.device = { id: rows[0].id, name: rows[0].name };
    logger.debug(`[AUTH] Device authenticated: "${rows[0].name}" (${rows[0].id.slice(0, 8)}…)`);
    next();
  } catch (err) {
    logger.error('[AUTH] requireDeviceKey DB error', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
}
