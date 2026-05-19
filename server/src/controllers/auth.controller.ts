import { Request, Response } from 'express';
import { v4 as uuidv4 } from 'uuid';
import { pool } from '../config/database';
import { hashPassword, comparePassword, signAccessToken, signRefreshToken, verifyToken } from '../utils/auth';
import { logger } from '../utils/logger';
import { AuthRequest } from '../types';

export async function register(req: Request, res: Response): Promise<void> {
  const { email, password, name } = req.body;
  try {
    const [existing] = await pool.execute<any[]>(
      'SELECT id FROM users WHERE email = ?',
      [email]
    );
    if (existing.length) {
      res.status(409).json({ success: false, message: 'Email already registered' });
      return;
    }
    const id = uuidv4();
    const hash = await hashPassword(password);
    await pool.execute(
      'INSERT INTO users (id, email, password_hash, name) VALUES (?, ?, ?, ?)',
      [id, email, hash, name ?? null]
    );
    const payload = { id, email, role: 'user' as const };
    res.status(201).json({
      success: true,
      data: {
        accessToken: signAccessToken(payload),
        refreshToken: signRefreshToken(payload),
        user: { id, email, name: name ?? null, role: 'user' },
      },
    });
  } catch (err) {
    logger.error('register error', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
}

export async function login(req: Request, res: Response): Promise<void> {
  const { email, password } = req.body;
  try {
    const [rows] = await pool.execute<any[]>(
      'SELECT id, email, password_hash, name, role FROM users WHERE email = ?',
      [email]
    );
    const user = rows[0];
    if (!user || !(await comparePassword(password, user.password_hash))) {
      res.status(401).json({ success: false, message: 'Invalid credentials' });
      return;
    }
    const payload = { id: user.id, email: user.email, role: user.role as 'user' | 'admin' };
    const accessToken = signAccessToken(payload);
    const refreshToken = signRefreshToken(payload);

    const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);
    await pool.execute(
      'INSERT INTO refresh_tokens (id, user_id, token, expires_at) VALUES (?, ?, ?, ?)',
      [uuidv4(), user.id, refreshToken, expiresAt]
    );

    res.json({
      success: true,
      data: {
        accessToken,
        refreshToken,
        user: { id: user.id, email: user.email, name: user.name, role: user.role },
      },
    });
  } catch (err) {
    logger.error('login error', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
}

export async function refresh(req: Request, res: Response): Promise<void> {
  const { refreshToken } = req.body;
  if (!refreshToken) {
    res.status(400).json({ success: false, message: 'refreshToken required' });
    return;
  }
  try {
    const payload = verifyToken(refreshToken);
    if (payload.type !== 'refresh') throw new Error();

    const [rows] = await pool.execute<any[]>(
      'SELECT id FROM refresh_tokens WHERE token = ? AND expires_at > NOW()',
      [refreshToken]
    );
    if (!rows.length) {
      res.status(401).json({ success: false, message: 'Refresh token expired or revoked' });
      return;
    }

    const newPayload = { id: payload.id, email: payload.email, role: payload.role };
    res.json({
      success: true,
      data: { accessToken: signAccessToken(newPayload) },
    });
  } catch {
    res.status(401).json({ success: false, message: 'Invalid refresh token' });
  }
}

export async function logout(req: AuthRequest, res: Response): Promise<void> {
  const { refreshToken } = req.body;
  if (refreshToken) {
    await pool.execute('DELETE FROM refresh_tokens WHERE token = ?', [refreshToken]).catch(() => {});
  }
  res.json({ success: true, message: 'Logged out' });
}

export async function me(req: AuthRequest, res: Response): Promise<void> {
  try {
    const [rows] = await pool.execute<any[]>(
      'SELECT id, email, name, role, created_at FROM users WHERE id = ?',
      [req.user!.id]
    );
    if (!rows.length) {
      res.status(404).json({ success: false, message: 'User not found' });
      return;
    }
    res.json({ success: true, data: rows[0] });
  } catch (err) {
    res.status(500).json({ success: false, message: 'Server error' });
  }
}
