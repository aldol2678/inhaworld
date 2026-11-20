// Apply schema.sql to the Neon branch named by DATABASE_URL (owner connection,
// via Neon HTTP driver). Splits on top-level ';' (split-sql.mjs). Failures are
// logged and the run exits non-zero, but every statement is attempted so one bad
// statement does not abort the whole run. DATABASE_URL comes from the
// environment only and is never printed.
import { readFileSync, writeFileSync } from 'node:fs';
import { neon } from '@neondatabase/serverless';
import { splitStatements } from './split-sql.mjs';

const url = process.env.DATABASE_URL;
if (!url) { console.error('DATABASE_URL env required'); process.exit(2); }
const sql = neon(url);
const statements = splitStatements(readFileSync(new URL('./schema.sql', import.meta.url), 'utf8'));
let ok = 0, failed = 0;
const failures = [];
for (let i = 0; i < statements.length; i++) {
  try {
    await sql([statements[i]]);
    ok++;
  } catch (e) {
    failed++;
    failures.push({ i, message: String(e?.message ?? e).slice(0, 300) });
    console.log(`FAIL #${i}: ${String(e?.message ?? e).slice(0, 200)}`);
  }
}
writeFileSync(new URL('./schema-apply-failures.json', import.meta.url), JSON.stringify(failures, null, 2));
console.log(`schema applied: ${ok} ok, ${failed} failed`);
process.exit(failed ? 3 : 0);
