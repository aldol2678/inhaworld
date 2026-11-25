// Apply housing-starter-f0-migration.sql to the Neon branch named by
// DATABASE_URL (owner connection, via Neon HTTP driver). Splits on top-level
// ';' (split-sql.mjs). Every statement is attempted; failures are logged and
// the run exits non-zero. DATABASE_URL comes from the environment only and
// is never printed. Pattern copied from apply-tier4-schema.mjs.
import { readFileSync, writeFileSync } from 'node:fs';
import { neon } from '@neondatabase/serverless';
import { splitStatements } from './split-sql.mjs';

const url = process.env.DATABASE_URL;
if (!url) { console.error('DATABASE_URL env required'); process.exit(2); }
const sql = neon(url);
const statements = splitStatements(readFileSync(new URL('./housing-starter-f0-migration.sql', import.meta.url), 'utf8'));
let ok = 0, failed = 0;
const failures = [];
for (let i = 0; i < statements.length; i++) {
  try {
    await sql([statements[i]]);
    ok++;
  } catch (e) {
    failed++;
    failures.push({ i, head: statements[i].slice(0, 120), message: String(e?.message ?? e).slice(0, 300) });
    console.log(`FAIL #${i}: ${String(e?.message ?? e).slice(0, 200)}`);
  }
}
writeFileSync(new URL('./housing-starter-apply-failures.json', import.meta.url), JSON.stringify(failures, null, 2));
console.log(`starter migration applied: ${ok} ok, ${failed} failed`);
process.exit(failed ? 3 : 0);
