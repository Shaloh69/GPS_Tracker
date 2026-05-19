import fs from 'fs';
import path from 'path';
import mysql from 'mysql2/promise';
import { config } from '../config/env';
import { logger } from '../utils/logger';

export async function runMigrations(): Promise<void> {
  const schemaPath = path.join(__dirname, 'schema.sql');
  const schema = fs.readFileSync(schemaPath, 'utf8');

  // Use a dedicated connection with multipleStatements so the whole
  // schema file runs in one shot — avoids comment-line filtering bugs.
  const conn = await mysql.createConnection({
    host:     config.database.host,
    port:     config.database.port,
    user:     config.database.user,
    password: config.database.password,
    database: config.database.name,
    multipleStatements: true,
    ...(config.database.ssl && { ssl: { rejectUnauthorized: false } }),
  });

  try {
    await conn.query(schema);
    logger.info('Migrations applied successfully');
  } finally {
    await conn.end();
  }
}
