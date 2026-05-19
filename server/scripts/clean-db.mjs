import mysql from 'mysql2/promise';
import { config as dotenv } from 'dotenv';
dotenv({ path: new URL('../.env', import.meta.url).pathname.slice(1) });

const conn = await mysql.createConnection({
  host:               process.env.DB_HOST,
  port:               parseInt(process.env.DB_PORT || '3306'),
  user:               process.env.DB_USER,
  password:           process.env.DB_PASSWORD,
  database:           process.env.DB_NAME,
  ssl:                process.env.DB_SSL === 'true' ? { rejectUnauthorized: false } : undefined,
  multipleStatements: true,
});

console.log('Connected to', process.env.DB_HOST);

await conn.query('SET FOREIGN_KEY_CHECKS = 0');
const [tables] = await conn.query(
  `SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE()`
);

for (const row of tables) {
  const name = row.TABLE_NAME ?? row.table_name;
  await conn.query(`TRUNCATE TABLE \`${name}\``);
  console.log(`✓ Truncated ${name}`);
}

await conn.query('SET FOREIGN_KEY_CHECKS = 1');
await conn.end();
console.log('Done — database is clean.');
