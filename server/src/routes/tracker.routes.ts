import { Router } from 'express';
import { body, param } from 'express-validator';
import {
  createDevice,
  listDevices,
  getDevice,
  updateDevice,
  deleteDevice,
  postLocation,
  pingDevice,
  getLatestLocation,
  getLocationHistory,
} from '../controllers/tracker.controller';
import { requireAuth, requireDeviceKey } from '../middleware/auth.middleware';

const router = Router();

// ── Device management (requires user JWT) ─────────────────────────────────────
router.post(
  '/devices',
  requireAuth,
  body('name').trim().notEmpty(),
  body('api_key').optional().isHexadecimal().isLength({ min: 64, max: 64 }),
  createDevice
);
router.get('/devices', requireAuth, listDevices);
router.get('/devices/:deviceId', requireAuth, param('deviceId').isUUID(), getDevice);
router.patch('/devices/:deviceId', requireAuth, param('deviceId').isUUID(), body('name').trim().notEmpty(), updateDevice);
router.delete('/devices/:deviceId', requireAuth, param('deviceId').isUUID(), deleteDevice);

// ── Device heartbeat (requires device X-Api-Key) ─────────────────────────────
router.post('/ping', requireDeviceKey, pingDevice);

// ── Location ingestion (requires device X-Api-Key) ────────────────────────────
router.post(
  '/location',
  requireDeviceKey,
  [
    body('lat').isFloat({ min: -90, max: 90 }),
    body('lng').isFloat({ min: -180, max: 180 }),
    body('speed').optional().isFloat({ min: 0 }),
    body('course').optional().isFloat({ min: 0, max: 360 }),
    body('altitude').optional().isFloat(),
    body('satellites').optional().isInt({ min: 0 }),
    body('hdop').optional().isFloat({ min: 0 }),
  ],
  postLocation
);

// ── Location queries (requires user JWT) ──────────────────────────────────────
router.get('/locations/:deviceId/latest', requireAuth, getLatestLocation);
router.get('/locations/:deviceId', requireAuth, getLocationHistory);

export default router;
