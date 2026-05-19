import fs from 'fs';
import path from 'path';
import { pool } from '../config/database';
import { logger } from '../utils/logger';

export async function runMigrations(): Promise<void> {
  const schemaPath = path.join(__dirname, 'schema.sql');
  const schema = fs.readFileSync(schemaPath, 'utf8');

  // Split on statement boundaries and run each individually
  const statements = schema
    .split(';')
    .map((s) => s.trim())
    .filter((s) => s.length > 0 && !s.startsWith('--'));

  const conn = await pool.getConnection();
  try {
    for (const sql of statements) {
      await conn.query(sql);
    }
    logger.info(`Ran ${statements.length} migration statements`);
  } finally {
    conn.release();
  }
}
