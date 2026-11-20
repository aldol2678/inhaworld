// Create the live Worker login role on tier4-live (owner connection).
// LOGIN_PASSWORD, LOGIN_ROLE and DATABASE_URL come from the environment only.
// Prints nothing secret: only "login role ready".
import { neon } from '@neondatabase/serverless';

const url = process.env.DATABASE_URL;
const pw = process.env.LOGIN_PASSWORD;
const role = process.env.LOGIN_ROLE;
if (!url || !pw || !role) {
  console.error('DATABASE_URL, LOGIN_PASSWORD and LOGIN_ROLE env required');
  process.exit(2);
}
const sql = neon(url);
// token_urlsafe password: [A-Za-z0-9_-] only, safe in a SQL literal.
await sql([`create role ${role} login password '${pw}'`]);
await sql([`grant inha_world_tier4_writes_app to ${role}`]);
console.log('login role ready');
