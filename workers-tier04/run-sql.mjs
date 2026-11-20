// Run one SQL statement from a file against DATABASE_URL and print rows as JSON.
// DATABASE_URL comes from the environment only, never printed.
import { readFileSync } from 'node:fs';
import { neon } from '@neondatabase/serverless';

const url = process.env.DATABASE_URL;
if (!url) { console.error('DATABASE_URL env required'); process.exit(2); }
const file = process.argv[2];
const statement = readFileSync(file, 'utf8');
const sql = neon(url);
const rows = await sql([statement]);
console.log(JSON.stringify(rows, null, 1));
