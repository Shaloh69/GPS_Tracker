import { Response } from 'express';
import { v4 as uuidv4 } from 'uuid';
import crypto from 'crypto';
import { pool } from '../config/database';
import { logger } from '../utils/logger';
import { AuthRequest, LocationPayload } from '../types';
import { getIO } from '../services/websocket.service';

// ── Device management ─────────────────────────────────────────────────────────

export async function createDevice(req: AuthRequest, res: Response): Promise<void> {
  const { name, api_key } = req.body;
  if (!name?.trim()) {
    res.status(400).json({ success: false, message: 'name is required' });
    return;
  }

  // Accept caller-supplied key (QR scan flow) or generate one (legacy flow)
  let apiKey: string;
  if (api_key) {
    if (!/^[0-9a-f]{64}$/.test(api_key)) {
      res.status(400).json({ success: false, message: 'Invalid api_key — must be 64 hex chars' });
      return;
    }
    apiKey = api_key;
  } else {
    apiKey = crypto.randomBytes(32).toString('hex');
  }

  try {
    const id = uuidv4();
    await pool.execute(
      'INSERT INTO devices (id, name, api_key, owner_id) VALUES (?, ?, ?, ?)',
      [id, name.trim(), apiKey, req.user!.id]
    );
    res.status(201).json({
      success: true,
      data: { id, name: name.trim(), api_key: apiKey },
      message: 'Device registered successfully.',
    });
  } catch (err: any) {
    if (err.code === 'ER_DUP_ENTRY') {
      res.status(409).json({ success: false, message: 'This device is already registered to an account' });
      return;
    }
    logger.error('createDevice error', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
}

export async function listDevices(req: AuthRequest, res: Response): Promise<void> {
  try {
    const [rows] = await pool.execute<any[]>(
      `SELECT d.id, d.name, d.is_active, d.last_seen, d.created_at,
              CASE WHEN d.last_seen IS NOT NULL
                    AND TIMESTAMPDIFF(SECOND, d.last_seen, NOW()) < 30
                   THEN 1 ELSE 0 END AS is_online,
              l.id AS loc_id, l.lat, l.lng, l.speed, l.course, l.altitude,
              l.satellites, l.hdop, l.gps_timestamp, l.created_at AS location_at
       FROM devices d
       LEFT JOIN locations l ON l.id = (
         SELECT id FROM locations WHERE device_id = d.id ORDER BY created_at DESC LIMIT 1
       )
       WHERE d.owner_id = ?
       ORDER BY d.created_at DESC`,
      [req.user!.id]
    );
    res.json({ success: true, data: rows });
  } catch (err) {
    logger.error('listDevices error', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
}

// ── Heartbeat ping (called by ESP32 every 10 s, no GPS needed) ───────────────

export async function pingDevice(req: AuthRequest, res: Response): Promise<void> {
  const device = req.device!;
  try {
    await pool.execute(
      'UPDATE devices SET last_seen = NOW(), is_online = TRUE WHERE id = ?',
      [device.id]
    );
    getIO().to(`device:${device.id}`).emit('device:status', {
      deviceId: device.id,
      isOnline: true,
    });
    res.json({ success: true });
  } catch (err) {
    logger.error('pingDevice error', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
}

export async function getDevice(req: AuthRequest, res: Response): Promise<void> {
  const { deviceId } = req.params;
  try {
    const [rows] = await pool.execute<any[]>(
      `SELECT d.id, d.name, d.is_active, d.is_online, d.last_seen, d.created_at,
              l.lat, l.lng, l.speed, l.course, l.altitude, l.satellites, l.created_at AS location_at
       FROM devices d
       LEFT JOIN locations l ON l.id = (
         SELECT id FROM locations WHERE device_id = d.id ORDER BY created_at DESC LIMIT 1
       )
       WHERE d.id = ? AND d.owner_id = ?`,
      [deviceId, req.user!.id]
    );
    if (!rows.length) {
      res.status(404).json({ success: false, message: 'Device not found' });
      return;
    }
    res.json({ success: true, data: rows[0] });
  } catch (err) {
    logger.error('getDevice error', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
}

export async function deleteDevice(req: AuthRequest, res: Response): Promise<void> {
  const { deviceId } = req.params;
  try {
    const [result] = await pool.execute<any>(
      'DELETE FROM devices WHERE id = ? AND owner_id = ?',
      [deviceId, req.user!.id]
    );
    if (!result.affectedRows) {
      res.status(404).json({ success: false, message: 'Device not found' });
      return;
    }
    res.json({ success: true, message: 'Device deleted' });
  } catch (err) {
    logger.error('deleteDevice error', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
}

// ── Location ingestion (called by ESP32) ─────────────────────────────────────

export async function postLocation(req: AuthRequest, res: Response): Promise<void> {
  const device = req.device!;
  const body = req.body as LocationPayload;

  const { lat, lng } = body;
  if (lat == null || lng == null || isNaN(lat) || isNaN(lng)) {
    res.status(400).json({ success: false, message: 'lat and lng are required' });
    return;
  }
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
    res.status(400).json({ success: false, message: 'Invalid coordinates' });
    return;
  }

  try {
    const now = new Date();
    const [result] = await pool.execute<any>(
      `INSERT INTO locations
         (device_id, lat, lng, speed, course, altitude, satellites, hdop, gps_timestamp)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        device.id,
        lat,
        lng,
        body.speed ?? null,
        body.course ?? null,
        body.altitude ?? null,
        body.satellites ?? null,
        body.hdop ?? null,
        body.gps_timestamp ?? null,
      ]
    );

    // Update device heartbeat
    await pool.execute(
      'UPDATE devices SET last_seen = NOW(), is_online = TRUE WHERE id = ?',
      [device.id]
    );

    const locationRow = {
      id: result.insertId as number,
      device_id: device.id,
      lat,
      lng,
      speed: body.speed ?? null,
      course: body.course ?? null,
      altitude: body.altitude ?? null,
      satellites: body.satellites ?? null,
      hdop: body.hdop ?? null,
      gps_timestamp: body.gps_timestamp ? new Date(body.gps_timestamp) : null,
      created_at: now,
    };

    // Broadcast real-time update to all subscribed dashboard clients
    getIO().to(`device:${device.id}`).emit('location:update', {
      deviceId: device.id,
      deviceName: device.name,
      location: locationRow,
    });

    logger.info(`[DEVICE] ${device.name} (${device.id.slice(0, 8)}) → lat=${lat.toFixed(6)} lng=${lng.toFixed(6)} sats=${body.satellites ?? '?'} spd=${body.speed?.toFixed(1) ?? '?'} km/h`);

    res.status(201).json({ success: true, data: locationRow });
  } catch (err) {
    logger.error('postLocation error', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
}

// ── Location queries (called by dashboard / Flutter app) ─────────────────────

export async function getLatestLocation(req: AuthRequest, res: Response): Promise<void> {
  const { deviceId } = req.params;
  try {
    const [rows] = await pool.execute<any[]>(
      `SELECT l.* FROM locations l
       JOIN devices d ON d.id = l.device_id
       WHERE l.device_id = ? AND d.owner_id = ?
       ORDER BY l.created_at DESC LIMIT 1`,
      [deviceId, req.user!.id]
    );
    if (!rows.length) {
      res.status(404).json({ success: false, message: 'No location data yet' });
      return;
    }
    res.json({ success: true, data: rows[0] });
  } catch (err) {
    logger.error('getLatestLocation error', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
}

export async function getLocationHistory(req: AuthRequest, res: Response): Promise<void> {
  const { deviceId } = req.params;
  const limit = Math.min(parseInt(req.query.limit as string) || 100, 1000);
  const from = req.query.from as string | undefined;
  const to = req.query.to as string | undefined;

  try {
    // Verify ownership
    const [devRows] = await pool.execute<any[]>(
      'SELECT id FROM devices WHERE id = ? AND owner_id = ?',
      [deviceId, req.user!.id]
    );
    if (!devRows.length) {
      res.status(404).json({ success: false, message: 'Device not found' });
      return;
    }

    let query = 'SELECT * FROM locations WHERE device_id = ?';
    const params: any[] = [deviceId];

    if (from) { query += ' AND created_at >= ?'; params.push(from); }
    if (to)   { query += ' AND created_at <= ?'; params.push(to); }

    query += ` ORDER BY created_at DESC LIMIT ${limit}`;

    const [rows] = await pool.execute<any[]>(query, params);
    res.json({ success: true, data: rows, count: rows.length });
  } catch (err) {
    logger.error('getLocationHistory error', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
}
