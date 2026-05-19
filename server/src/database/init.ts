import fs from 'fs';
import path from 'path';
import mysql from 'mysql2/promise';
import { config } from '../config/env';
import { logger } from '../utils/logger';

async function init(): Promise<void> {
  // Connect without selecting a database first so we can CREATE it
  const conn = await mysql.createConnection({
    host: config.database.host,
    port: config.database.port,
    user: config.database.user,
    password: config.database.password,
    multipleStatements: true,
  });

  const schema = fs.readFileSync(path.join(__dirname, 'schema.sql'), 'utf8');

  logger.info('Running schema…');
  await conn.query(schema);
  logger.info('Database initialised successfully.');

  await conn.end();
}

init().catch((err) => {
  console.error(err);
  process.exit(1);
});
