import { Request, Response, NextFunction } from 'express';
import { logger } from '../utils/logger';
import { config } from '../config/env';

export function errorHandler(
  err: any,
  req: Request,
  res: Response,
  _next: NextFunction
): void {
  logger.error(err.message, { stack: err.stack, path: req.path, method: req.method });
  res.status(err.status || 500).json({
    success: false,
    message: config.isProduction ? 'Internal server error' : (err.message ?? 'Unknown error'),
  });
}
