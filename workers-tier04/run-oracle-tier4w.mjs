// Run test-schema.sql (Tier 4) against the isolated Neon branch over the
// Neon serverless HTTP driver (this VM's egress answers Postgres TCP 5432
// with a non-Postgres byte, so pg/psql TCP cannot connect; the HTTP driver
// works). Handles the file's psql-only parts: \set variables and backslash
// meta-commands. The file's own begin/rollback and its final raise-on-failure
// DO block are dropped: the driver's transaction() commits on success, so an
// explicit cleanup afterwards removes every fixture row (by user/session id
// across all tables), the temp helpers, and the in-transaction role grant.
// DATABASE_URL from the environment only, never printed.
import { readFileSync } from 'node:fs';
import { neon } from '@neondatabase/serverless';
import { splitStatements } from './split-sql.mjs';

const url = process.env.DATABASE_URL;
if (!url) {
  console.error('DATABASE_URL env required');
  process.exit(2);
}

const raw = readFileSync(new URL('./test-schema.sql', import.meta.url), 'utf8');
const vars = new Map();
const lines = [];
for (const line of raw.split('\n')) {
  const m = /^\\set\s+(\S+)\s+'''(.*)'''$/.exec(line.trim());
  if (m) { vars.set(m[1], m[2]); continue; }
  if (line.trim().startsWith('\\')) continue; // psql meta-command
  lines.push(line);
}
let sqlText = lines.join('\n');
// Substitute :name / :'name' ONLY in code, never inside '...' strings,
// "..." identifiers, $tag$...$tag$ bodies or comments.
{
  const lits = new Map([...vars.entries()].map(([k, v]) => [k, `'${v.replaceAll("'", "''")}'`]));
  const names = [...lits.keys()].sort((a, b) => b.length - a.length);
  let out = '';
  let i = 0;
  let dollar = null, sq = false, dq = false, lineComment = false, blockComment = false;
  while (i < sqlText.length) {
    const ch = sqlText[i];
    const next = sqlText[i + 1] ?? '';
    if (lineComment) { out += ch; if (ch === '\n') lineComment = false; i++; continue; }
    if (blockComment) {
      out += ch;
      if (ch === '*' && next === '/') { out += next; i += 2; blockComment = false; continue; }
      i++; continue;
    }
    if (dollar) {
      out += ch;
      if (sqlText.startsWith(dollar, i)) { out += dollar.slice(1); i += dollar.length; dollar = null; continue; }
      i++; continue;
    }
    if (sq) {
      out += ch;
      if (ch === "'") {
        if (next === "'") { out += next; i += 2; continue; }
        sq = false;
      }
      i++; continue;
    }
    if (dq) { out += ch; if (ch === '"') dq = false; i++; continue; }
    if (ch === '-' && next === '-') { lineComment = true; out += ch; i++; continue; }
    if (ch === '/' && next === '*') { blockComment = true; out += ch; i++; continue; }
    if (ch === "'") { sq = true; out += ch; i++; continue; }
    if (ch === '"') { dq = true; out += ch; i++; continue; }
    if (ch === '$') {
      const m = /^\$[A-Za-z_][A-Za-z0-9_]*\$|^\$\$/.exec(sqlText.slice(i));
      if (m) { dollar = m[0]; out += dollar; i += dollar.length; continue; }
    }
    if (ch === ':') {
      let matched = false;
      for (const name of names) {
        if (sqlText.startsWith(`:'${name}'`, i)) { out += lits.get(name); i += name.length + 3; matched = true; break; }
        if (sqlText.startsWith(`:${name}`, i) && !/[A-Za-z0-9_]/.test(sqlText[i + name.length + 1] ?? '')) {
          out += lits.get(name); i += name.length + 1; matched = true; break;
        }
      }
      if (matched) continue;
    }
    out += ch;
    i++;
  }
  sqlText = out;
}
const statements = splitStatements(sqlText)
  .filter((s) => !/^\s*begin\s*$/i.test(s) && !/^\s*rollback\s*$/i.test(s));

const sql = neon(url);
const results = await sql.transaction(statements.map((s) => sql([s])));
let passedLine = null;
const failures = [];
for (const res of results) {
  for (const row of res ?? []) {
    const vals = Object.values(row);
    if (typeof vals[0] === 'string' && /passed$/.test(vals[0])) passedLine = vals[0];
    if (typeof vals[0] === 'string' && vals[0].startsWith('not ok')) failures.push(vals[0]);
  }
}
console.log(passedLine ?? 'no passed line captured');
if (failures.length) console.log(failures.join('\n'));

// ---- cleanup: the transaction committed, so remove everything the oracle left
// ORDER MATTERS: the append-only trigger on world_item_grants refuses DELETEs
// while the session row still exists, so delete the sessions FIRST, then the
// dependent rows (none of this oracle's fixtures touch world_item_grants, but
// the order is kept for safety).
const users = [
  'a1000000-0000-4000-8000-000000000001', 'a2000000-0000-4000-8000-000000000002',
  'a3000000-0000-4000-8000-000000000003', 'a4000000-0000-4000-8000-000000000004',
  'a5000000-0000-4000-8000-000000000005',
  'a9000000-0000-4000-8000-000000000009',
  'd6000000-0000-4000-8000-000000000006',
];
const runId = 'c1000000-0000-4000-8000-000000000001';
const clean = neon(url);
await clean`delete from public.sessions where id = any(${users}::text[])`;
await clean`delete from public.profiles where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_wallets where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_player_items where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_item_grants where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_player_progression where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_player_appearance_loadout where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_staff_assignments where user_id = any(${users}::uuid[])`;
await clean`delete from public.game_events where id = 9000001`;
await clean`delete from public.player_bests where user_id = any(${users}::uuid[])`;
await clean`delete from public.general_stage_bests where user_id = any(${users}::uuid[])`;
await clean`delete from public.classic_event_badges where user_id = any(${users}::uuid[])`;
await clean`delete from public.user_achievements where user_id = any(${users}::uuid[])`;
await clean`delete from public.ranked_runs where id = ${runId}::uuid`;
await clean`delete from public.ranked_sessions where run_id = ${runId}::uuid`;
await clean`delete from public.inha_mail_badges where user_id = any(${users}::uuid[])`;
await clean`delete from public.user_game_progress where user_id = any(${users}::uuid[])`;
// A-2 writes: delete the sessions first (the jeongseok / recipe append-only
// triggers allow DELETE only once the session row is gone), then the rest.
// Knocks/layouts/presence go before the rooms they reference.
await clean`delete from private.world_room_knocks where visitor_user_id = any(${users}::uuid[])`;
await clean`delete from private.world_room_owner_presence where room_id in (select id from public.world_player_rooms where owner_user_id = any(${users}::uuid[]))`;
await clean`delete from private.world_room_layouts where room_id in (select id from public.world_player_rooms where owner_user_id = any(${users}::uuid[]))`;
await clean`delete from public.world_player_rooms where owner_user_id = any(${users}::uuid[])`;
await clean`delete from public.world_friendships where user_low = any(${users}::uuid[]) or user_high = any(${users}::uuid[])`;
await clean`delete from private.world_attendance_days where user_id = any(${users}::uuid[])`;
await clean`delete from public.world_guestbook_entries where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_guestbook_post_log where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_jeongseok_pass_purchases where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_jeongseok_pass_entitlements where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_recipe_receipts where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_purchase_transactions where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_appearance_transactions where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_inventory_mutation_entries where mutation_id in (select mutation_id from private.world_inventory_mutations where user_id = any(${users}::uuid[]))`;
await clean`delete from private.world_inventory_mutations where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_item_consumptions where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_currency_transactions where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_exp_transactions where user_id = any(${users}::uuid[])`;
// ---- A-3 cleanup (sessions already deleted above, so the append-only
// triggers on the life / relationship / mcm ledgers allow these DELETEs)
await clean`delete from private.world_daily_quiz_answers where run_id in (select run_id from private.world_daily_quiz_runs where user_id = any(${users}::uuid[]))`;
await clean`delete from private.world_daily_quiz_runs where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_player_life_skills where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_player_life_nodes where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_life_sp_transactions where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_life_tree_resets where user_id = any(${users}::uuid[])`;
await clean`delete from public.world_user_reports where reporter_id = any(${users}::uuid[]) or target_id = any(${users}::uuid[])`;
await clean`delete from public.world_user_blocks where blocker_id = any(${users}::uuid[]) or blocked_id = any(${users}::uuid[])`;
await clean`delete from public.world_accompany_sessions where inviter_id = any(${users}::uuid[]) or invitee_id = any(${users}::uuid[])`;
await clean`delete from private.world_biryong_progress_v1 where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_biryong_npc_relationship_events where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_player_biryong_npc_relationships where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_campus_npc_relationship_events where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_player_campus_npc_relationships where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_event_progress where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_landlord_runs where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_landlord_first_clears where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_mcm_reward_claims where user_id = any(${users}::uuid[])`;
await clean`delete from private.world_reward_transaction_entries where reward_transaction_id in (select reward_transaction_id from private.world_reward_transactions where user_id = any(${users}::uuid[]))`;
await clean`delete from private.world_reward_transactions where user_id = any(${users}::uuid[])`;
// ---- BCD cleanup (online rows + mail requests; the oracle's own BCD
// section deletes its mail/badge/achievement rows inside the transaction,
// the runner only removes what could survive a mid-run failure)
await clean`delete from public.world_online_sessions where session_id = any(${users}::uuid[])`;
await clean`delete from private.world_mail_verify_requests where user_id = any(${users}::uuid[])`;
await clean`delete from public.inha_mail_badges where user_id = any(${users}::uuid[])`;
await clean`delete from public.user_achievements where user_id = any(${users}::uuid[])`;
await clean`update private.world_shops set status = 'ACTIVE' where shop_id = 'shop.room_finishes'`;
await clean`drop table if exists public._t_results`;
await clean`drop function if exists public._t_is(anyelement, anyelement, text)`;
await clean`drop function if exists public._t_throws(text, text, text, text)`;
await clean`revoke inha_world_tier4_writes_app from neondb_owner`;
const left = await clean`select (select count(*) from public.sessions where id = any(${users}::text[])) + (select count(*) from public.profiles where user_id = any(${users}::uuid[])) as leftover`;
console.log('leftover fixture rows:', left[0]?.leftover);
process.exit(failures.length ? 1 : 0);
