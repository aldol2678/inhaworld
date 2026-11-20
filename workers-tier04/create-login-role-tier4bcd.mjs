// Create the Worker login role on the isolated branch (owner connection).
// LOGIN_PASSWORD and DATABASE_URL come from the environment only.
// Prints nothing secret: only "login role ready".
import { neon } from '@neondatabase/serverless';

const url = process.env.DATABASE_URL;
const pw = process.env.LOGIN_PASSWORD;
if (!url || !pw) {
  console.error('DATABASE_URL and LOGIN_PASSWORD env required');
  process.exit(2);
}
const sql = neon(url);
// token_urlsafe password: [A-Za-z0-9_-] only, safe in a SQL literal.
await sql([`create role tier4_writes_app_login login password '${pw}'`]);
await sql([`grant inha_world_tier4_writes_app to tier4_writes_app_login`]);
console.log('login role ready');
