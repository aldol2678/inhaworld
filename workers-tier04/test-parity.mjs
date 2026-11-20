// Tier 4 parity (A-3 state machines; superset of A-1/A-2): static checks + direct
// comparison of the 65 ported RPCs against the ORIGINAL RPCs (scratch branch,
// auth stubs temporarily pointed at the fixture user), with the same fixture
// data on both sides. Tier 4 calls run as the Worker login role
// (TEST_LOGIN_URL) to prove the grants; fixtures run as the branch owners.
// Writes run the same sequence on both sides and compare scrubbed JSON:
// UUIDs and now()-derived timestamps are normalized (they differ by
// construction), while statuses, amounts, balances, counts and error codes
// must match exactly.
//
// EXPECTED DIFFERENCES (asserted as differences, not failures):
//   (1) get_my_achievements for a user verified by email only (no
//       inha_mail_badges row): the original earns inha_verified_v1 via the
//       auth.users email branch; Tier 4 does not (badges only).
//   (2) profile alice games[inha-duck] lastPlayedAt: the original's ops
//       mirror triggers (excluded from Tier 4 by design, Tier 3 precedent)
//       write game_events rows when ranked data is inserted, so the
//       original's lastPlayedAt is the trigger-run time (now). Tier 4 has
//       no ops triggers, so its lastPlayedAt is the classic last_at.
//   (3) jeongseok access for carol (email-only verification): the original
//       grants via INHA_MAIL (auth.users email); Tier 4 needs a pass
//       (badges only).
//   (4) Guest-open paths for a session without a profile (DELIBERATE
//       deviation, guest-open default): the original's room/attendance/
//       cooking callers require a non-banned profile, so noprofile gets
//       ACCOUNT_UNAVAILABLE; Tier 4 only needs the session:
//       - personal-room ensure: orig ACCOUNT_UNAVAILABLE, tier4 SUCCESS
//       - attendance claim: orig ACCOUNT_UNAVAILABLE, tier4 claimed
//       - banned setVisibility: orig ACCOUNT_UNAVAILABLE (profile banned),
//         tier4 ROOM_NOT_FOUND (session exists, no room)
//   (6) Social caller for a missing or banned profile: the original
//       raises ACCOUNT_UNAVAILABLE; Tier 4 raises PROFILE_NOT_FOUND so the
//       Worker can map it to 409 PROFILE_REQUIRED (rank rule, task
//       instruction). Affects guestbook create (banned/noprofile) and
//       knock (noprofile).
//   (7) capabilities: NO LONGER a difference — A-2 ports the purchase RPCs,
//       so both sides return {purchaseRpc: v2, catalogLayout: split}.
//   (8) Self-reads (wallet/inventory/progression) for a banned user with a
//       session: the original's account-ok requires a non-banned profile
//       (ACCOUNT_UNAVAILABLE); Tier 4 only needs a session, so it returns
//       data (fresh 0 wallet / empty inventory). Same guest-open family
//       as (4); inherited from the A-1 design, which never compared these
//       directly.
//   (9) advance_mcm_2026_event_v1 SERVER_ONLY: the original requires a
//       service_role JWT; Tier 4 has no service_role JWT and the Worker is
//       the server caller, so the gate is dropped (not weakened — the only
//       caller is the Worker, and the RPC has no HTTP endpoint). Asserted
//       as a difference with the auth.role() stub at 'authenticated'; the
//       direct comparisons run with the stub at 'service_role' so both
//       sides proceed identically.
//   (10) A-3 session-only gates (same guest-open family as #4/#8): the
//       quiz / life / MCM / biryong / campus-NPC account-ok helpers in the
//       original require a non-banned profile (ACCOUNT_UNAVAILABLE for a
//       session without a profile, or a banned profile); Tier 4 only needs
//       the session, so noprofile/banned succeed where the original
//       refuses. Social/accompany keep the profile rule (see #6).
//   (11) world_card inhaVerified for carol (email-only verification, same
//       family as #1/#3): the original computes it from auth.users email
//       confirmation (+ badges); Tier 4 is badges-only, so carol reads
//       false in Tier 4 and true in the original. The same flip applies
//       to dave's card and to carol's card inside get_my_world_social
//       (compared with the key stripped, flip asserted separately).
//   (12) Biryong merge for a session without an auth.users row: the
//       original's progress table has a FK to auth.users, so the merge
//       fails with a FK violation for the noprofile fixture; Tier 4's
//       sessions are the account, so the merge succeeds. Real users
//       always have an auth.users row, so the FK never fires live; the
//       merge RPC itself has no account_ok gate on either side.
//   (13) Online touch/count user_id (BCD): the original sets user_id from
//       auth.uid(), so a touched session counts as signedIn; Tier 4 has
//       no Supabase Auth, so user_id is always NULL and signedIn is 0
//       (guests === online). The count shape is unchanged. The original
//       has no touch rate limit; Tier 4 refuses a second touch within
//       10 seconds with RATE_LIMITED (C-DESIGN.md §5.3).
//   (14) Profile nickname uniqueness (BCD, D-2): the original has no
//       nickname UNIQUE constraint, so a duplicate nickname inserts
//       fine; Tier 4 refuses with NICKNAME_TAKEN (partial unique index
//       on lower(nickname) where not banned).
//   (15) Profile nickname banned-word filter (BCD, D-3): the original
//       has no filter, so a banned nickname inserts fine; Tier 4
//       refuses with INVALID_NICKNAME (patch35 list, 47 words).
// Env: TEST_OWNER_URL, TEST_LOGIN_URL, SCRATCH_URL. Never printed.
import { readFileSync } from 'node:fs';
import { neon } from '@neondatabase/serverless';
import { splitStatements } from './split-sql.mjs';

const testOwner = process.env.TEST_OWNER_URL;
const testLogin = process.env.TEST_LOGIN_URL;
const scratch = process.env.SCRATCH_URL;
if (!testOwner || !testLogin || !scratch) {
  console.error('TEST_OWNER_URL, TEST_LOGIN_URL and SCRATCH_URL env required');
  process.exit(2);
}
const owner = neon(testOwner);
const login = neon(testLogin);
const orig = neon(scratch);

let pass = 0, fail = 0;
const failures = [];
function check(ok, name, detail = '') {
  if (ok) { pass++; }
  else { fail++; failures.push(name + (detail ? ' — ' + detail : '')); console.log('FAIL:', name, detail); }
}
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// ---- static checks (no DB) ----
const schemaSql = readFileSync(new URL('./schema.sql', import.meta.url), 'utf8');
const stmts = splitStatements(schemaSql);
check(stmts.length > 300, `schema.sql splits into ${stmts.length} statements`);
function stripSqlComments(sqlText) {
  const out = [];
  let i = 0, dollar = null;
  while (i < sqlText.length) {
    if (dollar) {
      const end = sqlText.indexOf(dollar, i);
      if (end === -1) { out.push(sqlText.slice(i)); break; }
      out.push(sqlText.slice(i, end + dollar.length)); i = end + dollar.length; dollar = null; continue;
    }
    const m = /^\$[A-Za-z_][A-Za-z0-9_]*\$|^\$\$/.exec(sqlText.slice(i));
    if (m) { dollar = m[0]; out.push(dollar); i += dollar.length; continue; }
    if (sqlText.startsWith('--', i)) { const nl = sqlText.indexOf('\n', i); if (nl === -1) break; i = nl; continue; }
    out.push(sqlText[i]); i++;
  }
  return out.join('');
}
const codeOnly = stripSqlComments(schemaSql);
check(!/auth\./.test(codeOnly), 'no auth.* in schema.sql executable code');
for (const sig of [
  'get_my_world_inventory_v1(p_user uuid)',
  'get_my_world_wallet_v1(p_user uuid)',
  'get_my_world_progression_v1(p_user uuid)',
  'get_my_world_appearance_loadout_v1(p_user uuid)',
  'get_world_shop_v1(p_user uuid, p_shop_id text)',
  'get_world_shop_capabilities_v1(p_user uuid)',
  'get_world_staff_badges_v1(p_user uuid, p_user_ids uuid[])',
  'get_my_profile(p_user uuid)',
  'get_my_achievements(p_user uuid)',
  'equip_my_world_item_v1(p_user uuid, p_slot text, p_item_id text, p_idempotency_key text)',
  'unequip_my_world_item_v1(p_user uuid, p_slot text, p_idempotency_key text)',
  'purchase_world_shop_listing_v1(p_user uuid, p_listing_id text, p_idempotency_key text)',
  'purchase_world_shop_listing_v2(p_user uuid, p_shop_id text, p_listing_id text, p_idempotency_key text)',
  'claim_my_world_attendance_v1(p_user uuid)',
  'get_my_world_attendance_v1(p_user uuid)',
  'create_world_guestbook_entry_v2(p_user uuid, p_content text, p_location_key text)',
  'update_world_guestbook_entry_v2(p_user uuid, p_entry_id uuid, p_content text)',
  'delete_world_guestbook_entry_v2(p_user uuid, p_entry_id uuid)',
  'get_world_guestbook_v2(p_user uuid, p_location_key text, p_limit integer, p_before timestamp with time zone)',
  'purchase_jeongseok_pass_v1(p_user uuid, p_pass_type text, p_idempotency_key text)',
  'get_jeongseok_access_v1(p_user uuid)',
  'cook_my_world_recipe_v1(p_user uuid, p_recipe_id text, p_request_id uuid)',
  'save_my_room_furniture_v1(p_user uuid, p_room uuid, p_revision integer, p_objects jsonb)',
  'get_world_room_furniture_v1(p_user uuid, p_room uuid)',
  'get_or_create_my_personal_room_v1(p_user uuid)',
  'set_my_personal_room_visibility_v1(p_user uuid, p_visibility text)',
  'knock_friend_personal_room_v1(p_user uuid, p_owner uuid)',
  'get_my_room_knock_v1(p_user uuid, p_knock uuid)',
  'list_my_room_knocks_v1(p_user uuid)',
  'respond_room_knock_v1(p_user uuid, p_knock uuid, p_accept boolean)',
  // A-3 (35)
  'get_my_world_daily_quiz_v1(p_user uuid)',
  'start_my_world_daily_quiz_v1(p_user uuid)',
  'answer_my_world_daily_quiz_v1(p_user uuid, p_run_id uuid, p_question_id text, p_answer_index smallint)',
  'get_my_world_life_skills_v1(p_user uuid)',
  'get_my_world_life_skill_tree_v1(p_user uuid, p_skill_id text)',
  'unlock_my_world_life_node_v1(p_user uuid, p_node_id text, p_request_id uuid)',
  'reset_my_world_life_tree_v1(p_user uuid, p_skill_id text, p_request_id uuid)',
  'get_my_world_social(p_user uuid)',
  'get_world_public_profile(p_user uuid, p_target uuid)',
  'get_world_relationship(p_user uuid, p_target uuid)',
  'send_world_friend_request(p_user uuid, p_target uuid)',
  'respond_world_friend_request(p_user uuid, p_target uuid, p_accept boolean)',
  'cancel_world_friend_request(p_user uuid, p_target uuid)',
  'remove_world_friend(p_user uuid, p_target uuid)',
  'report_world_user(p_user uuid, p_target uuid, p_category text, p_place_zone_id text)',
  'block_world_user(p_user uuid, p_target uuid)',
  'unblock_world_user(p_user uuid, p_target uuid)',
  'get_my_world_accompany(p_user uuid)',
  'propose_world_accompany(p_user uuid, p_target uuid, p_poi_id text, p_place_zone_id text)',
  'respond_world_accompany(p_user uuid, p_session_id uuid, p_accept boolean)',
  'end_world_accompany(p_user uuid, p_session_id uuid)',
  'get_my_biryong_progress_v1(p_user uuid)',
  'merge_my_biryong_progress_v1(p_user uuid, p_progress jsonb, p_migrated_from_local boolean)',
  'get_my_biryong_npc_relationship_v1(p_user uuid, p_npc_id text)',
  'get_my_biryong_npc_relationships_v1(p_user uuid)',
  'world_biryong_npc_relationship_advance_v1(p_user uuid, p_npc_id text, p_target_stage smallint, p_source_type text, p_source_ref text, p_result_ref text, p_idempotency_key text)',
  'get_my_world_campus_npc_relationship_v1(p_user uuid, p_npc_id text)',
  'get_my_world_campus_npc_relationships_v1(p_user uuid)',
  'world_campus_npc_relationship_apply_v1(p_user uuid, p_npc_id text, p_definition_version integer, p_event_type text, p_signal text, p_occurrence integer, p_requested_delta smallint, p_source_type text, p_source_ref text, p_idempotency_key text)',
  'get_my_mcm_2026_event_v1(p_user uuid)',
  'advance_mcm_2026_event_v1(p_user uuid, p_event text)',
  'claim_my_mcm_2026_main_reward_v1(p_user uuid)',
  'claim_my_mcm_landlord_first_clear_reward_v1(p_user uuid)',
  'start_mcm_landlord_run_v1(p_user uuid)',
  // BCD (5)
  'create_my_world_profile_v1(p_user uuid, p_nickname text, p_department_id bigint, p_avatar_key text, p_title text)',
  'request_world_mail_verification_v1(p_user uuid, p_email text)',
  'admin_claim_world_mail_verification_v1(p_request_id uuid)',
  'touch_world_online_session_v2(p_user uuid, p_visitor_id uuid, p_place_zone_id text, p_space text)',
  'get_world_online_count_v1()',
  'submit_mcm_landlord_choice_v1(p_user uuid, p_run_id uuid, p_actor_id text)',
]) {
  check(schemaSql.includes(sig), 'schema.sql defines ' + sig);
}
// 56 CREATE TRIGGER statements over 50 distinct tables: six tables have
// two/three session-ref columns (friendships 3, reports/blocks/moderation 2
// each), and the generator emits drop+create per column with the same
// trigger name, so only the last column's trigger survives per table.
// (Same in A-1/A-2; the oracle counts 50 live triggers in pg_trigger.)
{
  // The trigger statement wraps across two lines in the addendum (and in
  // 6 A-3 statements), so the table regex must tolerate the newline.
  const tables = new Set([...schemaSql.matchAll(/create trigger tier4_session_ref before insert or update of \w+\s+on ([\w.]+)/g)].map((m) => m[1]));
  check(tables.size === 52, `schema.sql session-ref triggers cover 52 distinct tables (got ${tables.size})`);
  check((schemaSql.match(/create trigger tier4_session_ref/g) ?? []).length === 58, 'schema.sql has 58 tier4_session_ref CREATE TRIGGER statements');
}
check((schemaSql.match(/grant execute on function/g) ?? []).length === 72, 'schema.sql grants EXECUTE on 72 RPCs (65 A-3 + 7 BCD)');
const report = JSON.parse(readFileSync(new URL('./hash-report.json', import.meta.url), 'utf8'));
check(report.counts.identical === 92 && report.counts.modified === 91, `hash report 92 identical + 91 modified (got ${report.counts.identical} + ${report.counts.modified})`);
// BCD addendum report: the 7 BCD functions are hand-written Tier 4 SQL
// (no origin byte to compare for the 3 new ones; touch/count bodies are
// compared behaviourally below, not by hash).
const reportBcd = JSON.parse(readFileSync(new URL('./hash-report-bcd.json', import.meta.url), 'utf8'));
check(reportBcd.functions.length === 7 && reportBcd.functions.every((f) => f.schema && f.name), 'bcd hash report lists 7 functions');
check(reportBcd.bannedWords === 47, 'bcd hash report banned words = 47');
for (const f of report.functions) {
  if (f.status === 'identical') {
    check(f.origSrcSha256 === f.newSrcSha256, `identical: ${f.schema}.${f.name} hashes match`);
  } else {
    check(f.origSrcSha256 !== f.newSrcSha256 && f.changes.length > 0, `modified: ${f.schema}.${f.name} hash differs + changes listed`);
  }
}

// ---- fixtures ----
const ALICE = 'a1000000-0000-4000-8000-000000000001';
const BOB = 'a2000000-0000-4000-8000-000000000002';
const BANNED = 'a3000000-0000-4000-8000-000000000003';
const NOPROFILE = 'a4000000-0000-4000-8000-000000000004';
const CAROL = 'a5000000-0000-4000-8000-000000000005';
const STRANGER = 'a9000000-0000-4000-8000-000000000009';
const DAVE = 'd6000000-0000-4000-8000-000000000006';
const RUN = 'c1000000-0000-4000-8000-000000000001';
const G1 = 'b1000000-0000-4000-8000-000000000001';
const G2 = 'b2000000-0000-4000-8000-000000000002';
const G3 = 'b3000000-0000-4000-8000-000000000003';
const G4 = 'b4000000-0000-4000-8000-000000000004';
const G5 = 'b5000000-0000-4000-8000-000000000005';
const G6 = 'b6000000-0000-4000-8000-000000000006';
const G7 = 'b7000000-0000-4000-8000-000000000007';
const USERS = [ALICE, BOB, BANNED, NOPROFILE, CAROL, STRANGER, DAVE];

async function fixtureWorld(db, withSessions) {
  if (withSessions) {
    await db`insert into public.sessions (id, nickname) values (${ALICE}, 'alice'), (${BOB}, 'bob'), (${BANNED}, 'banned'), (${NOPROFILE}, 'noprofile'), (${CAROL}, 'carol'), (${DAVE}, 'dave') on conflict (id) do nothing`;
  } else {
    await db`insert into auth.users (id, email, email_confirmed_at, is_anonymous, created_at) values (${ALICE}, 'alice@inha.edu', '2026-11-04T00:00:00Z', false, '2026-11-01T00:00:00Z'), (${BOB}, 'bob@gmail.com', '2026-11-04T00:00:00Z', false, '2026-11-01T00:00:00Z'), (${BANNED}, 'banned@inha.edu', '2026-11-04T00:00:00Z', false, '2026-11-01T00:00:00Z'), (${CAROL}, 'carol@inha.edu', '2026-11-04T00:00:00Z', false, '2026-11-01T00:00:00Z'), (${DAVE}, 'dave@inha.edu', '2026-11-04T00:00:00Z', false, '2026-11-01T00:00:00Z') on conflict (id) do nothing`;
  }
  await db`insert into public.profiles (user_id, nickname, department_id, title, is_banned, created_at) values (${ALICE}, 'tier4alice', 10, '주치의', false, '2026-11-01T00:00:00Z'), (${BOB}, 'tier4bob', 1, null, false, '2026-11-01T00:00:00Z'), (${BANNED}, 'tier4banned', 1, null, true, '2026-11-01T00:00:00Z'), (${CAROL}, 'tier4carol', 1, null, false, '2026-11-01T00:00:00Z'), (${DAVE}, 'tier4dave', 1, null, false, '2026-11-01T00:00:00Z') on conflict (user_id) do nothing`;
  await db`insert into private.world_wallets (user_id, currency_id, balance) values (${ALICE}, 'currency.induck_coin', 500), (${BOB}, 'currency.induck_coin', 50) on conflict (user_id, currency_id) do nothing`;
  await db`insert into private.world_item_grants (grant_id, user_id, item_id, result, quantity_requested, quantity_before, quantity_granted, quantity_after, source_type, source_ref) values (${G1}, ${ALICE}, 'memorabilia.campus_mug', 'GRANTED', 2, 0, 2, 2, 'SYSTEM', 'parity'), (${G2}, ${ALICE}, 'badge.main_gate', 'GRANTED', 1, 0, 1, 1, 'SYSTEM', 'parity'), (${G3}, ${ALICE}, 'head.induck_cap', 'GRANTED', 1, 0, 1, 1, 'SYSTEM', 'parity'), (${G4}, ${ALICE}, 'top.induck_hoodie', 'GRANTED', 1, 0, 1, 1, 'SYSTEM', 'parity'), (${G5}, ${ALICE}, 'material.fish_carp', 'GRANTED', 3, 0, 3, 3, 'SYSTEM', 'parity'), (${G6}, ${ALICE}, 'furniture.cooking_station', 'GRANTED', 1, 0, 1, 1, 'SYSTEM', 'parity'), (${G7}, ${ALICE}, 'furniture.induck_chair', 'GRANTED', 1, 0, 1, 1, 'SYSTEM', 'parity') on conflict (grant_id) do nothing`;
  await db`insert into private.world_player_items (user_id, item_id, quantity, source_type, source_ref, grant_id, acquired_at, updated_at) values (${ALICE}, 'memorabilia.campus_mug', 2, 'test', 'parity', ${G1}, '2026-11-05T00:00:00Z', '2026-11-05T00:00:00Z'), (${ALICE}, 'head.induck_cap', 1, 'test', 'parity', ${G3}, '2026-11-04T12:00:00Z', '2026-11-04T12:00:00Z'), (${ALICE}, 'top.induck_hoodie', 1, 'test', 'parity', ${G4}, '2026-11-04T06:00:00Z', '2026-11-04T06:00:00Z'), (${ALICE}, 'badge.main_gate', 1, 'test', 'parity', ${G2}, '2026-11-04T00:00:00Z', '2026-11-04T00:00:00Z'), (${ALICE}, 'material.fish_carp', 3, 'test', 'parity', ${G5}, '2026-11-05T00:00:00Z', '2026-11-05T00:00:00Z'), (${ALICE}, 'furniture.cooking_station', 1, 'test', 'parity', ${G6}, '2026-11-05T00:00:00Z', '2026-11-05T00:00:00Z'), (${ALICE}, 'furniture.induck_chair', 1, 'test', 'parity', ${G7}, '2026-11-05T00:00:00Z', '2026-11-05T00:00:00Z') on conflict do nothing`;
  await db`insert into private.world_player_progression (user_id, total_exp) values (${ALICE}, 250) on conflict (user_id) do nothing`;
  await db`insert into private.world_player_appearance_loadout (user_id, slot, item_id, updated_at) values (${ALICE}, 'HEAD', 'head.induck_cap', '2026-11-05T00:00:00Z'), (${ALICE}, 'TOP', 'top.induck_hoodie', '2026-11-05T00:00:00Z') on conflict (user_id, slot) do nothing`;
  await db`insert into private.world_staff_assignments (user_id, role, active) values (${ALICE}, 'world_admin', true), (${BOB}, 'sound_gm', false) on conflict (user_id) do nothing`;
  await db`insert into public.game_events (id, user_id, event_type, game_id, created_at) values (9000001, ${ALICE}, 'stage_clear', (select id from public.games where slug = 'inha-duck'), '2026-11-02T00:00:00Z') on conflict (id) do nothing`;
  await db`insert into public.ranked_sessions (run_id, user_id, stage_key, nonce, started_at, expires_at, status, run_type, ruleset_version) values (${RUN}, ${ALICE}, 'secret', ${RUN}, '2026-11-05T00:00:00Z', '2026-11-05T01:00:00Z', 'accepted', 'ranked', 'secret-2.0-r1') on conflict (run_id) do nothing`;
  await db`insert into public.ranked_runs (id, run_id, user_id, stage_key, score, max_combo, duration_ms, validation_status, run_type) values (${RUN}, ${RUN}, ${ALICE}, 'secret', 999, 10, 60000, 'accepted', 'ranked') on conflict (id) do nothing`;
  await db`insert into public.player_bests (user_id, stage_key, best_score, best_combo, best_run_id, achieved_at) values (${ALICE}, 'secret', 12345, 67, ${RUN}, '2026-11-02T00:00:00Z') on conflict (user_id, stage_key) do nothing`;
  await db`insert into public.general_stage_bests (user_id, stage_id, best_score, best_combo, achieved_at) values (${ALICE}, 1, 100, 5, '2026-11-03T00:00:00Z') on conflict (user_id, stage_id) do nothing`;
  await db`insert into public.inha_mail_badges (user_id, email, verified_at) values (${ALICE}, 'alice@inha.edu', '2026-11-04T00:00:00Z') on conflict (user_id) do nothing`;
  await db`insert into public.classic_event_badges (event_key, user_id, placement, badge_code, best_run_id, final_score, final_combo, final_achieved_at) values ('inha_duck_s1', ${ALICE}, 2, 'inha_duck_s1_silver', ${RUN}, 999, 10, '2026-11-05T00:00:00Z') on conflict (event_key, user_id) do nothing`;
  await db`insert into public.user_achievements (user_id, achievement_key, earned_at, evidence_source) values (${ALICE}, 'classic_inha_duck_s1_rank_2_v1', '2026-11-05T00:00:00Z', 'classic_event_final_rank') on conflict (user_id, achievement_key) do nothing`;
  await db`insert into public.user_game_progress (user_id, game_id, progress, first_synced_at, updated_at) values (${ALICE}, (select id from public.games where slug = 'inha-duck-survival'), '{"stages": {"1": {"clear": true, "bestKills": 7}, "2": {"clear": false}}}', '2026-11-01T00:00:00Z', '2026-11-05T00:00:00Z') on conflict (user_id, game_id) do nothing`;
  await db`insert into public.world_friendships (user_low, user_high, status, requested_by, accepted_at) values (${ALICE}, ${BOB}, 'accepted', ${ALICE}, now()), (${ALICE}, ${CAROL}, 'accepted', ${ALICE}, now()), (${BOB}, ${CAROL}, 'accepted', ${BOB}, now()) on conflict (user_low, user_high) do nothing`;
}

async function cleanupWorld(db, withSessions) {
  // Append-only triggers (jeongseok purchases, recipe receipts) allow a
  // DELETE only once the account row is gone, so the account row goes
  // FIRST on both sides (sessions for Tier 4, auth.users for the original).
  // On the original this also cascades most dependents away; the explicit
  // deletes below are no-ops for cascaded rows and catch the rest.
  if (withSessions) {
    await db`delete from public.sessions where id = any(${USERS}::text[])`;
  } else {
    await db`delete from auth.users where id = any(${USERS}::uuid[])`;
  }
  await db`delete from private.world_room_knocks where visitor_user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_room_owner_presence where room_id in (select id from public.world_player_rooms where owner_user_id = any(${USERS}::uuid[]))`;
  await db`delete from private.world_room_layouts where room_id in (select id from public.world_player_rooms where owner_user_id = any(${USERS}::uuid[]))`;
  await db`delete from public.world_player_rooms where owner_user_id = any(${USERS}::uuid[])`;
  await db`delete from public.world_friendships where user_low = any(${USERS}::uuid[]) or user_high = any(${USERS}::uuid[])`;
  await db`delete from private.world_attendance_days where user_id = any(${USERS}::uuid[])`;
  await db`delete from public.world_guestbook_entries where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_guestbook_post_log where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_jeongseok_pass_purchases where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_jeongseok_pass_entitlements where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_recipe_receipts where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_purchase_transactions where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_appearance_transactions where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_inventory_mutation_entries where mutation_id in (select mutation_id from private.world_inventory_mutations where user_id = any(${USERS}::uuid[]))`;
  await db`delete from private.world_inventory_mutations where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_item_consumptions where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_currency_transactions where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_exp_transactions where user_id = any(${USERS}::uuid[])`;
  // ---- A-3 cleanup (quiz runs reference reward transactions without
  // ON DELETE CASCADE, so quiz runs go before the reward deletes below)
  await db`delete from private.world_daily_quiz_answers where run_id in (select run_id from private.world_daily_quiz_runs where user_id = any(${USERS}::uuid[]))`;
  await db`delete from private.world_daily_quiz_runs where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_player_life_nodes where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_life_sp_transactions where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_player_life_skills where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_life_tree_resets where user_id = any(${USERS}::uuid[])`;
  await db`delete from public.world_user_reports where reporter_id = any(${USERS}::uuid[]) or target_id = any(${USERS}::uuid[])`;
  await db`delete from public.world_user_blocks where blocker_id = any(${USERS}::uuid[]) or blocked_id = any(${USERS}::uuid[])`;
  await db`delete from public.world_accompany_sessions where inviter_id = any(${USERS}::uuid[]) or invitee_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_biryong_progress_v1 where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_biryong_npc_relationship_events where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_player_biryong_npc_relationships where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_campus_npc_relationship_events where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_player_campus_npc_relationships where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_event_progress where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_landlord_first_clears where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_landlord_runs where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_mcm_reward_claims where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_reward_transaction_entries where reward_transaction_id in (select reward_transaction_id from private.world_reward_transactions where user_id = any(${USERS}::uuid[]))`;
  await db`delete from private.world_reward_transactions where user_id = any(${USERS}::uuid[])`;
  await db`delete from public.profiles where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_wallets where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_player_items where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_item_grants where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_player_progression where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_player_appearance_loadout where user_id = any(${USERS}::uuid[])`;
  await db`delete from private.world_staff_assignments where user_id = any(${USERS}::uuid[])`;
  await db`delete from public.game_events where id = 9000001`;
  await db`delete from public.player_bests where user_id = any(${USERS}::uuid[])`;
  await db`delete from public.general_stage_bests where user_id = any(${USERS}::uuid[])`;
  await db`delete from public.classic_event_badges where user_id = any(${USERS}::uuid[])`;
  await db`delete from public.user_achievements where user_id = any(${USERS}::uuid[])`;
  await db`delete from public.ranked_runs where id = ${RUN}::uuid`;
  await db`delete from public.ranked_sessions where run_id = ${RUN}::uuid`;
  await db`delete from public.inha_mail_badges where user_id = any(${USERS}::uuid[])`;
  await db`delete from public.world_online_sessions where session_id = any(${USERS}::uuid[])`;
  if (withSessions) {
    await db`delete from private.world_mail_verify_requests where user_id = any(${USERS}::uuid[])`;
  }
  await db`delete from public.user_game_progress where user_id = any(${USERS}::uuid[])`;
  if (!withSessions) {
    await db`delete from public.game_events where user_id is null and created_at > now() - interval '1 hour'`;
    await db`delete from public.players where auth_user_id is null and created_at > now() - interval '1 hour'`;
  }
}

// Point the scratch auth stubs at one fixture user at a time (the original
// RPCs read auth.uid() / auth.jwt()). Restored in the finally block.
async function setAuthStub(userId) {
  await orig([`create or replace function auth.uid() returns uuid language sql stable as $$ select '${userId}'::uuid $$`]);
  await orig([`create or replace function auth.jwt() returns jsonb language sql stable as $$ select '{"is_anonymous": false}'::jsonb $$`]);
}
async function restoreAuthStub() {
  await orig([`create or replace function auth.uid() returns uuid language sql stable as $$ select null::uuid $$`]);
  await orig([`create or replace function auth.jwt() returns jsonb language sql stable as $$ select '{}'::jsonb $$`]);
}
// advance_mcm_2026_event_v1 requires auth.role() = 'service_role' in the
// original; the stub prelude defaults to 'authenticated'. Tier 4 dropped
// the gate, so the role stub only gates the original side.
async function setAuthRole(role) {
  await orig([`create or replace function auth.role() returns text language sql stable as $$ select '${role}'::text $$`]);
}

async function callOrig(sql, text) {
  try {
    const rows = await sql([text]);
    return { ok: true, value: rows[0]?.result ?? rows };
  } catch (e) {
    return { ok: false, code: e?.message ?? String(e) };
  }
}
async function callTier4(text) {
  try {
    const rows = await login([text]);
    return { ok: true, value: rows[0]?.result ?? rows };
  } catch (e) {
    return { ok: false, code: e?.message ?? String(e) };
  }
}

let compared = 0;
// Normalize what differs by construction: random UUIDs and now()-derived
// timestamps. Statuses, amounts, balances, counts and error codes stay.
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TS_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$/;
function scrubWrite(v) {
  if (typeof v === 'string') {
    if (UUID_RE.test(v)) return 'UUID';
    if (TS_RE.test(v)) return 'NOW';
    return v;
  }
  if (Array.isArray(v)) return v.map(scrubWrite);
  if (v && typeof v === 'object') {
    const o = {};
    for (const [k, val] of Object.entries(v)) {
      // biryong progress carries epoch-ms numbers (discoveredAt/completedAt)
      // taken from now() on each side; they differ by construction.
      if ((k === 'discoveredAt' || k === 'completedAt') && typeof val === 'number') { o[k] = 'NOW'; continue; }
      o[k] = scrubWrite(val);
    }
    return o;
  }
  return v;
}
function deepDiff(a, b, path, out) {
  if (JSON.stringify(a) === JSON.stringify(b)) return;
  if (a && b && typeof a === 'object' && typeof b === 'object') {
    for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) deepDiff(a[k], b[k], path + '.' + k, out);
  } else {
    out.push(path + ' orig=' + JSON.stringify(a) + ' tier4=' + JSON.stringify(b));
  }
}
async function compare(name, origText, tier4Text) {
  compared++;
  const o = await callOrig(orig, origText);
  const t = await callTier4(tier4Text);
  if (!o.ok) { check(false, name, 'original call failed: ' + o.code); return { o, t }; }
  if (!t.ok) { check(false, name, 'tier4 call failed: ' + t.code); return { o, t }; }
  const ov = scrubWrite(o.value), tv = scrubWrite(t.value);
  if (eq(ov, tv)) { check(true, name); return { o, t }; }
  const d = [];
  deepDiff(ov, tv, name, d);
  check(false, name, d.join(' | ').slice(0, 2000));
  return { o, t };
}
async function compareErr(name, origText, tier4Text, wantMessage) {
  compared++;
  const o = await callOrig(orig, origText);
  const t = await callTier4(tier4Text);
  if (o.ok) { check(false, name, 'original did not raise (returned ' + JSON.stringify(scrubWrite(o.value)).slice(0, 300) + ')'); return; }
  if (t.ok) { check(false, name, 'tier4 did not raise (returned ' + JSON.stringify(scrubWrite(t.value)).slice(0, 300) + ')'); return; }
  check(o.code === wantMessage && t.code === wantMessage, name, `orig=${o.code} tier4=${t.code} want=${wantMessage}`);
}
// Expected difference #11 (world_card inhaVerified): any card/profile of an
// email-verified-only user (carol, dave) reads inhaVerified true on the
// original (auth.users email) and false on Tier 4 (badges-only). Strip the
// key on both sides before comparing; the difference itself is asserted
// explicitly at the call site.
function stripInhaVerified(v) {
  if (Array.isArray(v)) return v.map(stripInhaVerified);
  if (v && typeof v === 'object') {
    const out = {};
    for (const [k, val] of Object.entries(v)) if (k !== 'inhaVerified') out[k] = stripInhaVerified(val);
    return out;
  }
  return v;
}
function collectInhaVerified(v, acc = []) {
  if (Array.isArray(v)) v.forEach((x) => collectInhaVerified(x, acc));
  else if (v && typeof v === 'object') {
    for (const [k, val] of Object.entries(v)) {
      if (k === 'inhaVerified') acc.push(val);
      else collectInhaVerified(val, acc);
    }
  }
  return acc;
}
async function compareNoInha(name, origText, tier4Text) {
  compared++;
  const o = await callOrig(orig, origText);
  const t = await callTier4(tier4Text);
  if (!o.ok) { check(false, name, 'original call failed: ' + o.code); return { o, t }; }
  if (!t.ok) { check(false, name, 'tier4 call failed: ' + t.code); return { o, t }; }
  const ov = stripInhaVerified(scrubWrite(o.value)), tv = stripInhaVerified(scrubWrite(t.value));
  if (eq(ov, tv)) { check(true, name); return { o, t }; }
  const d = [];
  deepDiff(ov, tv, name, d);
  check(false, name, d.join(' | ').slice(0, 2000));
  return { o, t };
}

const T4 = (u) => `'${u}'::uuid`;

try {
  await fixtureWorld(owner, true);
  await fixtureWorld(orig, false);

  // ---- A-1 reads, kept (direct comparisons) ----
  await setAuthStub(ALICE);
  await compare('inventory alice', `select public.get_my_world_inventory_v1() as result`, `select public.get_my_world_inventory_v1(${T4(ALICE)}) as result`);
  await compare('wallet alice', `select public.get_my_world_wallet_v1() as result`, `select public.get_my_world_wallet_v1(${T4(ALICE)}) as result`);
  await compare('progression alice', `select public.get_my_world_progression_v1() as result`, `select public.get_my_world_progression_v1(${T4(ALICE)}) as result`);
  await compare('loadout alice', `select public.get_my_world_appearance_loadout_v1() as result`, `select public.get_my_world_appearance_loadout_v1(${T4(ALICE)}) as result`);
  await compare('shop student_center', `select public.get_world_shop_v1('shop.student_center') as result`, `select public.get_world_shop_v1(${T4(ALICE)}, 'shop.student_center') as result`);
  await compareErr('shop bogus', `select public.get_world_shop_v1('shop.bogus') as result`, `select public.get_world_shop_v1(${T4(ALICE)}, 'shop.bogus') as result`, 'SHOP_NOT_FOUND');
  await compare('capabilities v2/split (A-1 diff #1 GONE)', `select public.get_world_shop_capabilities_v1() as result`, `select public.get_world_shop_capabilities_v1(${T4(ALICE)}) as result`);
  await compare('staff badges', `select public.get_world_staff_badges_v1(array['${ALICE}'::uuid, '${BOB}'::uuid, '${STRANGER}'::uuid]) as result`, `select public.get_world_staff_badges_v1(${T4(ALICE)}, array['${ALICE}'::uuid, '${BOB}'::uuid, '${STRANGER}'::uuid]) as result`);
  await setAuthStub(BOB);
  await compare('profile bob (as bob)', `select public.get_my_profile() as result`, `select public.get_my_profile(${T4(BOB)}) as result`);
  await setAuthStub(ALICE);
  const profO = await callOrig(orig, `select public.get_my_profile() as result`);
  const profT = await callTier4(`select public.get_my_profile(${T4(ALICE)}) as result`);
  {
    const duckO = (profO.value.games || []).find((g) => g.slug === 'inha-duck');
    const duckT = (profT.value.games || []).find((g) => g.slug === 'inha-duck');
    check(profO.value.id === profT.value.id, 'profile alice id', String(profO.value.id) + ' vs ' + String(profT.value.id));
    check(profO.value.nickname === profT.value.nickname, 'profile alice nickname', String(profO.value.nickname) + ' vs ' + String(profT.value.nickname));
    check(profO.value.department_id === profT.value.department_id, 'profile alice department_id', String(profO.value.department_id) + ' vs ' + String(profT.value.department_id));
    check(profO.value.title === profT.value.title, 'profile alice title', String(profO.value.title) + ' vs ' + String(profT.value.title));
    check(profO.value.totalExperience === profT.value.totalExperience, 'profile alice totalExperience', String(profO.value.totalExperience) + ' vs ' + String(profT.value.totalExperience));
    check(profO.value.level === profT.value.level, 'profile alice level', String(profO.value.level) + ' vs ' + String(profT.value.level));
    check(duckO && duckT && duckO.slug === duckT.slug, 'profile alice games[inha-duck] slug', JSON.stringify(duckO) + ' vs ' + JSON.stringify(duckT));
    check(duckO && duckT && duckO.bestScore === duckT.bestScore, 'profile alice games[inha-duck] bestScore', String(duckO?.bestScore) + ' vs ' + String(duckT?.bestScore));
    check(duckO && duckT && duckO.bestCombo === duckT.bestCombo, 'profile alice games[inha-duck] bestCombo', String(duckO?.bestCombo) + ' vs ' + String(duckT?.bestCombo));
    check(duckO && duckT && duckO.bestRunId === duckT.bestRunId, 'profile alice games[inha-duck] bestRunId', String(duckO?.bestRunId) + ' vs ' + String(duckT?.bestRunId));
    // Expected difference #2: the original's ops mirror triggers write
    // game_events on ranked inserts; Tier 4 has no ops triggers.
    const oLast = duckO ? new Date(duckO.lastPlayedAt).getTime() : NaN;
    check(duckO && duckT && oLast > new Date('2026-11-03T00:00:00Z').getTime() && (Date.now() - oLast) < 10 * 60 * 1000, 'profile alice games[inha-duck] lastPlayedAt is trigger-generated now() in original (expected diff)', String(duckO?.lastPlayedAt));
    check(duckT?.lastPlayedAt === '2026-11-03T00:00:00+00:00', 'profile alice games[inha-duck] lastPlayedAt is classic last_at in tier4 (expected diff)', String(duckT?.lastPlayedAt));
    if (duckO && duckT) duckO.lastPlayedAt = duckT.lastPlayedAt;
    const d = [];
    deepDiff(scrubWrite(profO.value), scrubWrite(profT.value), 'profile alice', d);
    check(d.length === 0, 'profile alice identical except inha-duck lastPlayedAt', d.join(' | ').slice(0, 1000));
  }
  await compare('achievements alice', `select public.get_my_achievements() as result`, `select public.get_my_achievements(${T4(ALICE)}) as result`);
  await setAuthStub(CAROL);
  const achO = await callOrig(orig, `select public.get_my_achievements() as result`);
  const achT = await callTier4(`select public.get_my_achievements(${T4(CAROL)}) as result`);
  // Expected difference #1: carol is email-verified only (no badges row);
  // the original earns inha_verified_v1 via auth.users email, Tier 4 does not.
  {
    const oInha = achO.ok && (achO.value?.achievements ?? []).find((a) => a.key === 'inha_verified_v1');
    const tInha = achT.ok && (achT.value?.achievements ?? []).find((a) => a.key === 'inha_verified_v1');
    check(achO.ok && oInha?.earned === true, 'achievements carol original earns inha via email (expected diff)', JSON.stringify(achO.value));
    check(achT.ok && tInha?.earned === false, 'achievements carol tier4 does NOT earn inha (badges only, expected diff)', JSON.stringify(achT.value));
  }
  {
    // user_achievements rows: direct table reads run as the branch owner
    // (the login role has no table grants by design).
    const o = await orig`select achievement_key, earned_at, evidence_source from public.user_achievements where user_id = ${ALICE}::uuid order by achievement_key`;
    const t = await owner`select achievement_key, earned_at, evidence_source from public.user_achievements where user_id = ${ALICE}::uuid order by achievement_key`;
    check(eq(scrubWrite(o), scrubWrite(t)), 'user_achievements rows alice identical', JSON.stringify(scrubWrite(o)) + ' vs ' + JSON.stringify(scrubWrite(t)));
  }
  await setAuthStub(STRANGER);
  await compareErr('stranger inventory', `select public.get_my_world_inventory_v1() as result`, `select public.get_my_world_inventory_v1(${T4(STRANGER)}) as result`, 'ACCOUNT_UNAVAILABLE');
  // Expected difference (guest-open, same family as #4): the original's
  // wallet/inventory/progression account-ok requires a non-banned profile;
  // Tier 4 only needs a session, so a banned user with a session gets data
  // (a fresh 0-balance wallet / empty inventory) instead of an error.
  await setAuthStub(BANNED);
  {
    const wO = await callOrig(orig, `select public.get_my_world_wallet_v1() as result`);
    const wT = await callTier4(`select public.get_my_world_wallet_v1(${T4(BANNED)}) as result`);
    check(!wO.ok && wO.code === 'ACCOUNT_UNAVAILABLE' && wT.ok && wT.value.currencies?.[0]?.balance === 0, 'banned wallet (expected diff: orig ACCOUNT_UNAVAILABLE, tier4 fresh 0 wallet)', `orig=${wO.code} tier4=${JSON.stringify(scrubWrite(wT.value))}`);
    const iO = await callOrig(orig, `select public.get_my_world_inventory_v1() as result`);
    const iT = await callTier4(`select public.get_my_world_inventory_v1(${T4(BANNED)}) as result`);
    check(!iO.ok && iO.code === 'ACCOUNT_UNAVAILABLE' && iT.ok, 'banned inventory (expected diff: orig ACCOUNT_UNAVAILABLE, tier4 returns inventory)', `orig=${iO.code} tier4=${JSON.stringify(scrubWrite(iT.value)).slice(0, 200)}`);
    const pO = await callOrig(orig, `select public.get_my_world_progression_v1() as result`);
    const pT = await callTier4(`select public.get_my_world_progression_v1(${T4(BANNED)}) as result`);
    check(!pO.ok && pO.code === 'ACCOUNT_UNAVAILABLE' && pT.ok, 'banned progression (expected diff: orig ACCOUNT_UNAVAILABLE, tier4 returns progression)', `orig=${pO.code} tier4=${JSON.stringify(scrubWrite(pT.value)).slice(0, 200)}`);
  }
  await compareErr('banned profile', `select public.get_my_profile() as result`, `select public.get_my_profile(${T4(BANNED)}) as result`, 'PROFILE_NOT_FOUND');

  // ---- A-2 writes: loadout ----
  await setAuthStub(ALICE);
  await compare('loadout equip cap (same item)', `select public.equip_my_world_item_v1('HEAD', 'head.induck_cap', 'p-equip-1') as result`, `select public.equip_my_world_item_v1(${T4(ALICE)}, 'HEAD', 'head.induck_cap', 'p-equip-1') as result`);
  await compare('loadout equip cap replay', `select public.equip_my_world_item_v1('HEAD', 'head.induck_cap', 'p-equip-1') as result`, `select public.equip_my_world_item_v1(${T4(ALICE)}, 'HEAD', 'head.induck_cap', 'p-equip-1') as result`);
  await compareErr('loadout same key diff item', `select public.equip_my_world_item_v1('HEAD', 'top.induck_hoodie', 'p-equip-1') as result`, `select public.equip_my_world_item_v1(${T4(ALICE)}, 'HEAD', 'top.induck_hoodie', 'p-equip-1') as result`, 'IDEMPOTENCY_CONFLICT');
  await compare('loadout unequip HEAD', `select public.unequip_my_world_item_v1('HEAD', 'p-unequip-1') as result`, `select public.unequip_my_world_item_v1(${T4(ALICE)}, 'HEAD', 'p-unequip-1') as result`);
  await compare('loadout unequip HEAD again', `select public.unequip_my_world_item_v1('HEAD', 'p-unequip-2') as result`, `select public.unequip_my_world_item_v1(${T4(ALICE)}, 'HEAD', 'p-unequip-2') as result`);
  await compare('loadout re-equip cap', `select public.equip_my_world_item_v1('HEAD', 'head.induck_cap', 'p-equip-2') as result`, `select public.equip_my_world_item_v1(${T4(ALICE)}, 'HEAD', 'head.induck_cap', 'p-equip-2') as result`);
  await compareErr('loadout equip not-owned', `select public.equip_my_world_item_v1('SHOES', 'shoes.campus_sneakers', 'p-equip-3') as result`, `select public.equip_my_world_item_v1(${T4(ALICE)}, 'SHOES', 'shoes.campus_sneakers', 'p-equip-3') as result`, 'ITEM_NOT_OWNED');
  await compareErr('loadout equip invalid slot', `select public.equip_my_world_item_v1('ARMS', 'head.induck_cap', 'p-equip-4') as result`, `select public.equip_my_world_item_v1(${T4(ALICE)}, 'ARMS', 'head.induck_cap', 'p-equip-4') as result`, 'INVALID_APPEARANCE_SLOT');
  await compareErr('loadout equip null key', `select public.equip_my_world_item_v1('HEAD', 'head.induck_cap', null) as result`, `select public.equip_my_world_item_v1(${T4(ALICE)}, 'HEAD', 'head.induck_cap', null) as result`, 'INVALID_IDEMPOTENCY_KEY');
  await setAuthStub(STRANGER);
  await compareErr('loadout equip stranger', `select public.equip_my_world_item_v1('HEAD', 'head.induck_cap', 'p-equip-9') as result`, `select public.equip_my_world_item_v1(${T4(STRANGER)}, 'HEAD', 'head.induck_cap', 'p-equip-9') as result`, 'ACCOUNT_UNAVAILABLE');

  // ---- A-2 writes: purchase ----
  await setAuthStub(BOB);
  await compareErr('purchase bob mug insufficient funds (atomic: wallet+inventory unchanged, asserted via wallet read below)', `select public.purchase_world_shop_listing_v1('offer.student_center.campus_mug', 'p-buy-0') as result`, `select public.purchase_world_shop_listing_v1(${T4(BOB)}, 'offer.student_center.campus_mug', 'p-buy-0') as result`, 'INSUFFICIENT_FUNDS');
  await compare('wallet bob after failed purchase', `select public.get_my_world_wallet_v1() as result`, `select public.get_my_world_wallet_v1(${T4(BOB)}) as result`);
  await setAuthStub(ALICE);
  await compare('purchase v1 sneakers', `select public.purchase_world_shop_listing_v1('offer.student_center.campus_sneakers', 'p-buy-1') as result`, `select public.purchase_world_shop_listing_v1(${T4(ALICE)}, 'offer.student_center.campus_sneakers', 'p-buy-1') as result`);
  await compare('purchase v1 sneakers replay', `select public.purchase_world_shop_listing_v1('offer.student_center.campus_sneakers', 'p-buy-1') as result`, `select public.purchase_world_shop_listing_v1(${T4(ALICE)}, 'offer.student_center.campus_sneakers', 'p-buy-1') as result`);
  await compareErr('purchase same key mug', `select public.purchase_world_shop_listing_v1('offer.student_center.campus_mug', 'p-buy-1') as result`, `select public.purchase_world_shop_listing_v1(${T4(ALICE)}, 'offer.student_center.campus_mug', 'p-buy-1') as result`, 'IDEMPOTENCY_CONFLICT');
  await compareErr('purchase mug already owned', `select public.purchase_world_shop_listing_v1('offer.student_center.campus_mug', 'p-buy-2') as result`, `select public.purchase_world_shop_listing_v1(${T4(ALICE)}, 'offer.student_center.campus_mug', 'p-buy-2') as result`, 'ITEM_ALREADY_OWNED');
  await compareErr('purchase backpack level required', `select public.purchase_world_shop_listing_v1('offer.student_center.induck_backpack', 'p-buy-3') as result`, `select public.purchase_world_shop_listing_v1(${T4(ALICE)}, 'offer.student_center.induck_backpack', 'p-buy-3') as result`, 'LEVEL_REQUIRED');
  await compareErr('purchase unknown listing', `select public.purchase_world_shop_listing_v1('offer.student_center.nope', 'p-buy-4') as result`, `select public.purchase_world_shop_listing_v1(${T4(ALICE)}, 'offer.student_center.nope', 'p-buy-4') as result`, 'INVALID_LISTING');
  await compareErr('purchase null key', `select public.purchase_world_shop_listing_v1('offer.student_center.campus_sneakers', null) as result`, `select public.purchase_world_shop_listing_v1(${T4(ALICE)}, 'offer.student_center.campus_sneakers', null) as result`, 'INVALID_IDEMPOTENCY_KEY');
  await compare('wallet alice after v1 (500-240=260)', `select public.get_my_world_wallet_v1() as result`, `select public.get_my_world_wallet_v1(${T4(ALICE)}) as result`);
  await compare('purchase v2 cushion', `select public.purchase_world_shop_listing_v2('shop.dorm_furniture', 'offer.dorm_furniture.induck_cushion', 'p-buy-5') as result`, `select public.purchase_world_shop_listing_v2(${T4(ALICE)}, 'shop.dorm_furniture', 'offer.dorm_furniture.induck_cushion', 'p-buy-5') as result`);
  await compare('purchase v2 cushion replay', `select public.purchase_world_shop_listing_v2('shop.dorm_furniture', 'offer.dorm_furniture.induck_cushion', 'p-buy-5') as result`, `select public.purchase_world_shop_listing_v2(${T4(ALICE)}, 'shop.dorm_furniture', 'offer.dorm_furniture.induck_cushion', 'p-buy-5') as result`);
  await compareErr('purchase v2 wrong shop', `select public.purchase_world_shop_listing_v2('shop.student_center', 'offer.dorm_furniture.induck_cushion', 'p-buy-6') as result`, `select public.purchase_world_shop_listing_v2(${T4(ALICE)}, 'shop.student_center', 'offer.dorm_furniture.induck_cushion', 'p-buy-6') as result`, 'SHOP_LISTING_MISMATCH');
  await compareErr('purchase v2 cushion already owned', `select public.purchase_world_shop_listing_v2('shop.dorm_furniture', 'offer.dorm_furniture.induck_cushion', 'p-buy-7') as result`, `select public.purchase_world_shop_listing_v2(${T4(ALICE)}, 'shop.dorm_furniture', 'offer.dorm_furniture.induck_cushion', 'p-buy-7') as result`, 'ITEM_ALREADY_OWNED');
  await compareErr('purchase v2 unknown shop', `select public.purchase_world_shop_listing_v2('shop.bogus', 'offer.dorm_furniture.induck_cushion', 'p-buy-8') as result`, `select public.purchase_world_shop_listing_v2(${T4(ALICE)}, 'shop.bogus', 'offer.dorm_furniture.induck_cushion', 'p-buy-8') as result`, 'SHOP_LISTING_MISMATCH');
  await compare('wallet alice after v2 (260-220=40)', `select public.get_my_world_wallet_v1() as result`, `select public.get_my_world_wallet_v1(${T4(ALICE)}) as result`);

  // ---- A-2 writes: attendance ----
  await setAuthStub(ALICE);
  await compare('attendance state alice', `select public.get_my_world_attendance_v1() as result`, `select public.get_my_world_attendance_v1(${T4(ALICE)}) as result`);
  await compare('attendance claim alice', `select public.claim_my_world_attendance_v1() as result`, `select public.claim_my_world_attendance_v1(${T4(ALICE)}) as result`);
  await compare('attendance claim alice replay', `select public.claim_my_world_attendance_v1() as result`, `select public.claim_my_world_attendance_v1(${T4(ALICE)}) as result`);
  await compare('attendance state alice after', `select public.get_my_world_attendance_v1() as result`, `select public.get_my_world_attendance_v1(${T4(ALICE)}) as result`);
  // Bob milestone: 2 prior days with real reward txs, then today's claim is day 3.
  const kst = new Date().toLocaleString('en-CA', { timeZone: 'Asia/Seoul', year: 'numeric', month: '2-digit', day: '2-digit' });
  const dayMs = 24 * 60 * 60 * 1000;
  const d1 = new Date(new Date(kst + 'T00:00:00Z').getTime() - dayMs).toISOString().slice(0, 10);
  const d2 = new Date(new Date(kst + 'T00:00:00Z').getTime() - 2 * dayMs).toISOString().slice(0, 10);
  for (const db of [orig, owner]) {
    const g1 = await callOrig(db, `select private.world_reward_grant_v1('${BOB}'::uuid, 'reward.attendance.daily', 'SYSTEM', 'attendance.daily', 'attendance:daily:${BOB}:${d2}') as result`);
    const g2 = await callOrig(db, `select private.world_reward_grant_v1('${BOB}'::uuid, 'reward.attendance.daily', 'SYSTEM', 'attendance.daily', 'attendance:daily:${BOB}:${d1}') as result`);
    const tx1 = g1.value.rewardTransactionId, tx2 = g2.value.rewardTransactionId;
    await db`insert into private.world_attendance_days (user_id, attendance_date, claimed_at, daily_reward_transaction_id) values (${BOB}, ${d2}, now(), ${tx1}), (${BOB}, ${d1}, now(), ${tx2})`;
  }
  await setAuthStub(BOB);
  await compare('attendance claim bob day 3 (milestone_3 +30)', `select public.claim_my_world_attendance_v1() as result`, `select public.claim_my_world_attendance_v1(${T4(BOB)}) as result`);
  await compare('wallet bob after milestone claim (50+10+10+10+30=110)', `select public.get_my_world_wallet_v1() as result`, `select public.get_my_world_wallet_v1(${T4(BOB)}) as result`);
  await compare('attendance state bob', `select public.get_my_world_attendance_v1() as result`, `select public.get_my_world_attendance_v1(${T4(BOB)}) as result`);
  // Expected difference #4 (guest-open): noprofile has a session but no
  // profile; the original's attendance caller requires a profile.
  await setAuthStub(NOPROFILE);
  const attNoO = await callOrig(orig, `select public.claim_my_world_attendance_v1() as result`);
  const attNoT = await callTier4(`select public.claim_my_world_attendance_v1(${T4(NOPROFILE)}) as result`);
  check(!attNoO.ok && attNoO.code === 'ACCOUNT_UNAVAILABLE' && attNoT.ok && attNoT.value.claimed === true, 'attendance claim noprofile (expected diff: orig ACCOUNT_UNAVAILABLE, tier4 claimed)', `orig=${attNoO.code} tier4=${JSON.stringify(scrubWrite(attNoT.value))}`);

  // ---- A-2 writes: guestbook ----
  await setAuthStub(BOB);
  await orig([`insert into private.world_guestbook_post_log (id, entry_id, user_id, location_key, created_at) select gen_random_uuid(), gen_random_uuid(), '${BOB}'::uuid, 'main_gate', now() from generate_series(1,3)`]);
  await owner([`insert into private.world_guestbook_post_log (id, entry_id, user_id, location_key, created_at) select gen_random_uuid(), gen_random_uuid(), '${BOB}'::uuid, 'main_gate', now() from generate_series(1,3)`]);
  await compareErr('guestbook bob daily limit 3', `select public.create_world_guestbook_entry_v2('4th', 'main_gate') as result`, `select public.create_world_guestbook_entry_v2(${T4(BOB)}, '4th', 'main_gate') as result`, 'DAILY_LIMIT_REACHED');
  await setAuthStub(ALICE);
  const gbCreate = await compare('guestbook create alice', `select public.create_world_guestbook_entry_v2('hello inha', 'main_gate') as result`, `select public.create_world_guestbook_entry_v2(${T4(ALICE)}, 'hello inha', 'main_gate') as result`);
  const entryO = gbCreate.o.value.id, entryT = gbCreate.t.value.id;
  await compare('guestbook board alice', `select public.get_world_guestbook_v2('main_gate', 10, null) as result`, `select public.get_world_guestbook_v2(${T4(ALICE)}, 'main_gate', 10, null) as result`);
  await setAuthStub(BOB);
  await compareErr('guestbook bob update alice entry', `select public.update_world_guestbook_entry_v2('${entryO}'::uuid, 'hacked') as result`, `select public.update_world_guestbook_entry_v2(${T4(BOB)}, '${entryT}'::uuid, 'hacked') as result`, 'ENTRY_UNAVAILABLE');
  await compareErr('guestbook bob delete alice entry', `select public.delete_world_guestbook_entry_v2('${entryO}'::uuid) as result`, `select public.delete_world_guestbook_entry_v2(${T4(BOB)}, '${entryT}'::uuid) as result`, 'ENTRY_UNAVAILABLE');
  await setAuthStub(ALICE);
  await compare('guestbook alice update', `select public.update_world_guestbook_entry_v2('${entryO}'::uuid, 'hello inha v2') as result`, `select public.update_world_guestbook_entry_v2(${T4(ALICE)}, '${entryT}'::uuid, 'hello inha v2') as result`);
  await compare('guestbook alice delete', `select public.delete_world_guestbook_entry_v2('${entryO}'::uuid) as result`, `select public.delete_world_guestbook_entry_v2(${T4(ALICE)}, '${entryT}'::uuid) as result`);
  await compare('guestbook board empty', `select public.get_world_guestbook_v2('main_gate', 10, null) as result`, `select public.get_world_guestbook_v2(${T4(ALICE)}, 'main_gate', 10, null) as result`);
  await setAuthStub(BANNED);
  // Expected difference #6 (social caller): orig ACCOUNT_UNAVAILABLE,
  // tier4 PROFILE_NOT_FOUND (Worker maps to 409 PROFILE_REQUIRED).
  const gbBaO = await callOrig(orig, `select public.create_world_guestbook_entry_v2('x', 'main_gate') as result`);
  const gbBaT = await callTier4(`select public.create_world_guestbook_entry_v2(${T4(BANNED)}, 'x', 'main_gate') as result`);
  check(!gbBaO.ok && gbBaO.code === 'ACCOUNT_UNAVAILABLE' && !gbBaT.ok && gbBaT.code === 'PROFILE_NOT_FOUND', 'guestbook banned create (expected diff: orig ACCOUNT_UNAVAILABLE, tier4 PROFILE_NOT_FOUND)', `orig=${gbBaO.code} tier4=${gbBaT.code}`);
  await setAuthStub(NOPROFILE);
  const gbNoO = await callOrig(orig, `select public.create_world_guestbook_entry_v2('x', 'main_gate') as result`);
  const gbNoT = await callTier4(`select public.create_world_guestbook_entry_v2(${T4(NOPROFILE)}, 'x', 'main_gate') as result`);
  check(!gbNoO.ok && gbNoO.code === 'ACCOUNT_UNAVAILABLE' && !gbNoT.ok && gbNoT.code === 'PROFILE_NOT_FOUND', 'guestbook noprofile create (expected diff: orig ACCOUNT_UNAVAILABLE, tier4 PROFILE_NOT_FOUND)', `orig=${gbNoO.code} tier4=${gbNoT.code}`);
  await setAuthStub(ALICE);
  await compareErr('guestbook empty content', `select public.create_world_guestbook_entry_v2('', 'main_gate') as result`, `select public.create_world_guestbook_entry_v2(${T4(ALICE)}, '', 'main_gate') as result`, 'INVALID_CONTENT');
  await compareErr('guestbook bad location', `select public.create_world_guestbook_entry_v2('ok', 'nowhere') as result`, `select public.create_world_guestbook_entry_v2(${T4(ALICE)}, 'ok', 'nowhere') as result`, 'INVALID_LOCATION');

  // ---- A-2 writes: jeongseok ----
  await setAuthStub(ALICE);
  await compare('jeongseok access seed COMING_SOON', `select public.get_jeongseok_access_v1() as result`, `select public.get_jeongseok_access_v1(${T4(ALICE)}) as result`);
  await compareErr('jeongseok purchase gate closed', `select public.purchase_jeongseok_pass_v1('jeongseok.visitor.day', 'p-js-0') as result`, `select public.purchase_jeongseok_pass_v1(${T4(ALICE)}, 'jeongseok.visitor.day', 'p-js-0') as result`, 'JEONGSEOK_GATE_UNAVAILABLE');
  for (const db of [orig, owner]) {
    await db`update private.world_jeongseok_gate_policy set status = 'ACTIVE' where singleton`;
    await db`update private.world_jeongseok_pass_catalog set status = 'ACTIVE' where pass_type = 'jeongseok.visitor.day'`;
  }
  await setAuthStub(BOB);
  await compare('jeongseok access bob NEEDS_PASS', `select public.get_jeongseok_access_v1() as result`, `select public.get_jeongseok_access_v1(${T4(BOB)}) as result`);
  await setAuthStub(ALICE);
  await compare('jeongseok access alice GRANTED via mail', `select public.get_jeongseok_access_v1() as result`, `select public.get_jeongseok_access_v1(${T4(ALICE)}) as result`);
  await compareErr('jeongseok alice free access eligible', `select public.purchase_jeongseok_pass_v1('jeongseok.visitor.day', 'p-js-1') as result`, `select public.purchase_jeongseok_pass_v1(${T4(ALICE)}, 'jeongseok.visitor.day', 'p-js-1') as result`, 'FREE_ACCESS_ELIGIBLE');
  await setAuthStub(BOB);
  await compareErr('jeongseok bob invalid pass type', `select public.purchase_jeongseok_pass_v1('jeongseok.visitor.week', 'p-js-2') as result`, `select public.purchase_jeongseok_pass_v1(${T4(BOB)}, 'jeongseok.visitor.week', 'p-js-2') as result`, 'INVALID_PASS_TYPE');
  for (const db of [orig, owner]) {
    await db`update private.world_wallets set balance = 500 where user_id = ${BOB}::uuid and currency_id = 'currency.induck_coin'`;
  }
  await compare('jeongseok bob purchase SUCCESS', `select public.purchase_jeongseok_pass_v1('jeongseok.visitor.day', 'p-js-3') as result`, `select public.purchase_jeongseok_pass_v1(${T4(BOB)}, 'jeongseok.visitor.day', 'p-js-3') as result`);
  await compare('jeongseok bob purchase replay ALREADY_PROCESSED', `select public.purchase_jeongseok_pass_v1('jeongseok.visitor.day', 'p-js-3') as result`, `select public.purchase_jeongseok_pass_v1(${T4(BOB)}, 'jeongseok.visitor.day', 'p-js-3') as result`);
  await compareErr('jeongseok same key diff pass', `select public.purchase_jeongseok_pass_v1('jeongseok.visitor.week', 'p-js-3') as result`, `select public.purchase_jeongseok_pass_v1(${T4(BOB)}, 'jeongseok.visitor.week', 'p-js-3') as result`, 'IDEMPOTENCY_CONFLICT');
  await compareErr('jeongseok bob already active', `select public.purchase_jeongseok_pass_v1('jeongseok.visitor.day', 'p-js-4') as result`, `select public.purchase_jeongseok_pass_v1(${T4(BOB)}, 'jeongseok.visitor.day', 'p-js-4') as result`, 'PASS_ALREADY_ACTIVE');
  await compare('jeongseok access bob after GRANTED via pass', `select public.get_jeongseok_access_v1() as result`, `select public.get_jeongseok_access_v1(${T4(BOB)}) as result`);
  // Expected difference #3: carol is email-verified only; the original
  // grants via INHA_MAIL (auth.users email), Tier 4 needs a pass.
  await setAuthStub(CAROL);
  const jsO = await callOrig(orig, `select public.get_jeongseok_access_v1() as result`);
  const jsT = await callTier4(`select public.get_jeongseok_access_v1(${T4(CAROL)}) as result`);
  check(jsO.value.decision === 'GRANTED' && jsO.value.via === 'INHA_MAIL' && jsT.value.decision === 'NEEDS_PASS', 'jeongseok access carol (expected diff: orig GRANTED via INHA_MAIL, tier4 NEEDS_PASS)', `orig=${JSON.stringify(scrubWrite(jsO.value))} tier4=${JSON.stringify(scrubWrite(jsT.value))}`);
  for (const db of [orig, owner]) {
    await db`update private.world_jeongseok_gate_policy set status = 'COMING_SOON' where singleton`;
    await db`update private.world_jeongseok_pass_catalog set status = 'COMING_SOON' where pass_type = 'jeongseok.visitor.day'`;
  }

  // ---- A-2 writes: personal room ----
  await setAuthStub(ALICE);
  const roomA1 = await compare('personal room ensure alice', `select public.get_or_create_my_personal_room_v1() as result`, `select public.get_or_create_my_personal_room_v1(${T4(ALICE)}) as result`);
  const roomA2 = await compare('personal room ensure alice again (same room)', `select public.get_or_create_my_personal_room_v1() as result`, `select public.get_or_create_my_personal_room_v1(${T4(ALICE)}) as result`);
  check(roomA1.o.value.roomId === roomA2.o.value.roomId && roomA1.t.value.roomId === roomA2.t.value.roomId, 'personal room alice idempotent (same roomId twice)', `orig=${roomA1.o.value.roomId} vs ${roomA2.o.value.roomId}; tier4=${roomA1.t.value.roomId} vs ${roomA2.t.value.roomId}`);
  const roomAIdO = roomA1.o.value.roomId, roomAIdT = roomA1.t.value.roomId;
  await setAuthStub(BOB);
  const roomB = await compare('personal room ensure bob', `select public.get_or_create_my_personal_room_v1() as result`, `select public.get_or_create_my_personal_room_v1(${T4(BOB)}) as result`);
  const roomBIdO = roomB.o.value.roomId, roomBIdT = roomB.t.value.roomId;
  await setAuthStub(CAROL);
  await compare('personal room ensure carol', `select public.get_or_create_my_personal_room_v1() as result`, `select public.get_or_create_my_personal_room_v1(${T4(CAROL)}) as result`);
  await setAuthStub(ALICE);
  await compare('personal room alice set private', `select public.set_my_personal_room_visibility_v1('private') as result`, `select public.set_my_personal_room_visibility_v1(${T4(ALICE)}, 'private') as result`);
  await compareErr('personal room invalid visibility', `select public.set_my_personal_room_visibility_v1('public') as result`, `select public.set_my_personal_room_visibility_v1(${T4(ALICE)}, 'public') as result`, 'INVALID_VISIBILITY');
  await setAuthStub(STRANGER);
  await compareErr('personal room stranger setVisibility', `select public.set_my_personal_room_visibility_v1('friends') as result`, `select public.set_my_personal_room_visibility_v1(${T4(STRANGER)}, 'friends') as result`, 'ACCOUNT_UNAVAILABLE');
  await setAuthStub(BOB);
  await compare('personal room bob set friends', `select public.set_my_personal_room_visibility_v1('friends') as result`, `select public.set_my_personal_room_visibility_v1(${T4(BOB)}, 'friends') as result`);
  // Expected difference #4 (guest-open): noprofile has a session but no
  // profile; the original's room caller requires a profile.
  await setAuthStub(NOPROFILE);
  const roomNoO = await callOrig(orig, `select public.get_or_create_my_personal_room_v1() as result`);
  const roomNoT = await callTier4(`select public.get_or_create_my_personal_room_v1(${T4(NOPROFILE)}) as result`);
  check(!roomNoO.ok && roomNoO.code === 'ACCOUNT_UNAVAILABLE' && roomNoT.ok && roomNoT.value.roomId, 'personal room ensure noprofile (expected diff: orig ACCOUNT_UNAVAILABLE, tier4 SUCCESS)', `orig=${roomNoO.code} tier4=${JSON.stringify(scrubWrite(roomNoT.value))}`);
  // Expected difference #4 (guest-open): banned has a profile but it is
  // banned; the original's room caller refuses it, Tier 4 only needs a
  // session (banned has no room, so ROOM_NOT_FOUND).
  await setAuthStub(BANNED);
  const visBaO = await callOrig(orig, `select public.set_my_personal_room_visibility_v1('friends') as result`);
  const visBaT = await callTier4(`select public.set_my_personal_room_visibility_v1(${T4(BANNED)}, 'friends') as result`);
  check(!visBaO.ok && visBaO.code === 'ACCOUNT_UNAVAILABLE' && !visBaT.ok && visBaT.code === 'ROOM_NOT_FOUND', 'personal room banned setVisibility (expected diff: orig ACCOUNT_UNAVAILABLE, tier4 ROOM_NOT_FOUND)', `orig=${visBaO.code} tier4=${visBaT.code}`);

  // ---- A-2 writes: furniture (alice room private, bob room friends) ----
  await setAuthStub(ALICE);
  await compare('furniture get alice rev0', `select public.get_world_room_furniture_v1('${roomAIdO}'::uuid) as result`, `select public.get_world_room_furniture_v1(${T4(ALICE)}, '${roomAIdT}'::uuid) as result`);
  const chair1 = JSON.stringify([{ id: 'c1000000-0000-4000-8000-000000000001', itemId: 'furniture.induck_chair', surface: 'floor', x: 0, z: 0, yaw: 0 }]);
  const chairMoved = JSON.stringify([{ id: 'c1000000-0000-4000-8000-000000000001', itemId: 'furniture.induck_chair', surface: 'floor', x: 1, z: 0, yaw: 0 }]);
  await compare('furniture save rev0 chair -> rev1', `select public.save_my_room_furniture_v1('${roomAIdO}'::uuid, 0, '${chair1}'::jsonb) as result`, `select public.save_my_room_furniture_v1(${T4(ALICE)}, '${roomAIdT}'::uuid, 0, '${chair1}'::jsonb) as result`);
  await compareErr('furniture stale rev0 (moved chair)', `select public.save_my_room_furniture_v1('${roomAIdO}'::uuid, 0, '${chairMoved}'::jsonb) as result`, `select public.save_my_room_furniture_v1(${T4(ALICE)}, '${roomAIdT}'::uuid, 0, '${chairMoved}'::jsonb) as result`, 'LAYOUT_CONFLICT');
  await compare('furniture identical retry rev0 (no bump)', `select public.save_my_room_furniture_v1('${roomAIdO}'::uuid, 0, '${chair1}'::jsonb) as result`, `select public.save_my_room_furniture_v1(${T4(ALICE)}, '${roomAIdT}'::uuid, 0, '${chair1}'::jsonb) as result`);
  await compare('furniture save rev1 moved -> rev2', `select public.save_my_room_furniture_v1('${roomAIdO}'::uuid, 1, '${chairMoved}'::jsonb) as result`, `select public.save_my_room_furniture_v1(${T4(ALICE)}, '${roomAIdT}'::uuid, 1, '${chairMoved}'::jsonb) as result`);
  const both = JSON.stringify([{ id: 'c1000000-0000-4000-8000-000000000001', itemId: 'furniture.induck_chair', surface: 'floor', x: 1, z: 0, yaw: 0 }, { id: 'c2000000-0000-4000-8000-000000000002', itemId: 'furniture.cooking_station', surface: 'floor', x: 3, z: 0, yaw: 0 }]);
  await compare('furniture save rev2 both -> rev3', `select public.save_my_room_furniture_v1('${roomAIdO}'::uuid, 2, '${both}'::jsonb) as result`, `select public.save_my_room_furniture_v1(${T4(ALICE)}, '${roomAIdT}'::uuid, 2, '${both}'::jsonb) as result`);
  await compare('furniture get alice rev3', `select public.get_world_room_furniture_v1('${roomAIdO}'::uuid) as result`, `select public.get_world_room_furniture_v1(${T4(ALICE)}, '${roomAIdT}'::uuid) as result`);
  await setAuthStub(BOB);
  await compareErr('furniture bob save alice room', `select public.save_my_room_furniture_v1('${roomAIdO}'::uuid, 3, '${both}'::jsonb) as result`, `select public.save_my_room_furniture_v1(${T4(BOB)}, '${roomAIdT}'::uuid, 3, '${both}'::jsonb) as result`, 'LAYOUT_DENIED');
  await compareErr('furniture bob get alice room', `select public.get_world_room_furniture_v1('${roomAIdO}'::uuid) as result`, `select public.get_world_room_furniture_v1(${T4(BOB)}, '${roomAIdT}'::uuid) as result`, 'LAYOUT_DENIED');
  await setAuthStub(ALICE);
  const badSurface = JSON.stringify([{ id: 'c1000000-0000-4000-8000-000000000001', itemId: 'furniture.induck_chair', surface: 'ceiling', x: 0, z: 0, yaw: 0 }]);
  await compareErr('furniture bad surface', `select public.save_my_room_furniture_v1('${roomAIdO}'::uuid, 3, '${badSurface}'::jsonb) as result`, `select public.save_my_room_furniture_v1(${T4(ALICE)}, '${roomAIdT}'::uuid, 3, '${badSurface}'::jsonb) as result`, 'INVALID_LAYOUT');
  await compareErr('furniture negative revision', `select public.save_my_room_furniture_v1('${roomAIdO}'::uuid, -1, '${both}'::jsonb) as result`, `select public.save_my_room_furniture_v1(${T4(ALICE)}, '${roomAIdT}'::uuid, -1, '${both}'::jsonb) as result`, 'INVALID_LAYOUT');

  // ---- A-2 writes: cooking ----
  await setAuthStub(ALICE);
  await compareErr('cooking seed COMING_SOON', `select public.cook_my_world_recipe_v1('recipe.carp_grill', 'c2000000-0000-4000-8000-000000000001'::uuid) as result`, `select public.cook_my_world_recipe_v1(${T4(ALICE)}, 'recipe.carp_grill', 'c2000000-0000-4000-8000-000000000001'::uuid) as result`, 'RECIPE_UNAVAILABLE');
  for (const db of [orig, owner]) {
    await db`update private.world_recipe_catalog set status = 'ACTIVE' where recipe_id = 'recipe.carp_grill'`;
  }
  await setAuthStub(BOB);
  await compareErr('cooking bob no station', `select public.cook_my_world_recipe_v1('recipe.carp_grill', 'c2000000-0000-4000-8000-000000000002'::uuid) as result`, `select public.cook_my_world_recipe_v1(${T4(BOB)}, 'recipe.carp_grill', 'c2000000-0000-4000-8000-000000000002'::uuid) as result`, 'COOKING_STATION_REQUIRED');
  await setAuthStub(ALICE);
  await compare('cooking alice carp', `select public.cook_my_world_recipe_v1('recipe.carp_grill', 'c2000000-0000-4000-8000-000000000003'::uuid) as result`, `select public.cook_my_world_recipe_v1(${T4(ALICE)}, 'recipe.carp_grill', 'c2000000-0000-4000-8000-000000000003'::uuid) as result`);
  await compare('cooking alice replay', `select public.cook_my_world_recipe_v1('recipe.carp_grill', 'c2000000-0000-4000-8000-000000000003'::uuid) as result`, `select public.cook_my_world_recipe_v1(${T4(ALICE)}, 'recipe.carp_grill', 'c2000000-0000-4000-8000-000000000003'::uuid) as result`);
  await compareErr('cooking same req diff recipe', `select public.cook_my_world_recipe_v1('recipe.other_x', 'c2000000-0000-4000-8000-000000000003'::uuid) as result`, `select public.cook_my_world_recipe_v1(${T4(ALICE)}, 'recipe.other_x', 'c2000000-0000-4000-8000-000000000003'::uuid) as result`, 'IDEMPOTENCY_CONFLICT');
  await compareErr('cooking null request', `select public.cook_my_world_recipe_v1('recipe.carp_grill', null) as result`, `select public.cook_my_world_recipe_v1(${T4(ALICE)}, 'recipe.carp_grill', null) as result`, 'INVALID_RECIPE_REQUEST');
  for (const db of [orig, owner]) {
    await db`update private.world_recipe_catalog set status = 'COMING_SOON' where recipe_id = 'recipe.carp_grill'`;
  }

  // ---- A-2 writes: knock (polling) ----
  await setAuthStub(NOPROFILE);
  // Expected difference #6 (social caller): orig ACCOUNT_UNAVAILABLE,
  // tier4 PROFILE_NOT_FOUND (Worker maps to 409 PROFILE_REQUIRED).
  const knNoO = await callOrig(orig, `select public.knock_friend_personal_room_v1('${BOB}'::uuid) as result`);
  const knNoT = await callTier4(`select public.knock_friend_personal_room_v1(${T4(NOPROFILE)}, '${BOB}'::uuid) as result`);
  check(!knNoO.ok && knNoO.code === 'ACCOUNT_UNAVAILABLE' && !knNoT.ok && knNoT.code === 'PROFILE_NOT_FOUND', 'knock noprofile (expected diff: orig ACCOUNT_UNAVAILABLE, tier4 PROFILE_NOT_FOUND)', `orig=${knNoO.code} tier4=${knNoT.code}`);
  await setAuthStub(ALICE);
  await compareErr('knock target noprofile', `select public.knock_friend_personal_room_v1('${NOPROFILE}'::uuid) as result`, `select public.knock_friend_personal_room_v1(${T4(ALICE)}, '${NOPROFILE}'::uuid) as result`, 'TARGET_UNAVAILABLE');
  await compareErr('knock self', `select public.knock_friend_personal_room_v1('${ALICE}'::uuid) as result`, `select public.knock_friend_personal_room_v1(${T4(ALICE)}, '${ALICE}'::uuid) as result`, 'TARGET_UNAVAILABLE');
  // Alice -> bob: bob's room is friends + bob not home -> OPEN admission.
  const knockAB = await compare('knock alice->bob OPEN', `select public.knock_friend_personal_room_v1('${BOB}'::uuid) as result`, `select public.knock_friend_personal_room_v1(${T4(ALICE)}, '${BOB}'::uuid) as result`);
  const knockAB2 = await compare('knock alice->bob repeat OPEN (same knock)', `select public.knock_friend_personal_room_v1('${BOB}'::uuid) as result`, `select public.knock_friend_personal_room_v1(${T4(ALICE)}, '${BOB}'::uuid) as result`);
  check(knockAB.o.value.knockId === knockAB2.o.value.knockId && knockAB.t.value.knockId === knockAB2.t.value.knockId, 'knock alice->bob repeat returns same knockId', `orig=${knockAB.o.value.knockId} vs ${knockAB2.o.value.knockId}; tier4=${knockAB.t.value.knockId} vs ${knockAB2.t.value.knockId}`);
  await setAuthStub(BOB);
  await compare('knock bob list empty', `select public.list_my_room_knocks_v1() as result`, `select public.list_my_room_knocks_v1(${T4(BOB)}) as result`);
  // Bob -> carol: carol lists first (presence), then bob knocks -> PENDING.
  await setAuthStub(CAROL);
  await compare('knock carol list (presence)', `select public.list_my_room_knocks_v1() as result`, `select public.list_my_room_knocks_v1(${T4(CAROL)}) as result`);
  await setAuthStub(BOB);
  const knockBC = await compare('knock bob->carol PENDING', `select public.knock_friend_personal_room_v1('${CAROL}'::uuid) as result`, `select public.knock_friend_personal_room_v1(${T4(BOB)}, '${CAROL}'::uuid) as result`);
  const knockBIdO = knockBC.o.value.knockId, knockBIdT = knockBC.t.value.knockId;
  await compare('knock bob->carol repeat PENDING', `select public.knock_friend_personal_room_v1('${CAROL}'::uuid) as result`, `select public.knock_friend_personal_room_v1(${T4(BOB)}, '${CAROL}'::uuid) as result`);
  await setAuthStub(CAROL);
  await compare('knock carol list 1 pending', `select public.list_my_room_knocks_v1() as result`, `select public.list_my_room_knocks_v1(${T4(CAROL)}) as result`);
  await setAuthStub(BOB);
  await compare('knock bob get PENDING', `select public.get_my_room_knock_v1('${knockBIdO}'::uuid) as result`, `select public.get_my_room_knock_v1(${T4(BOB)}, '${knockBIdT}'::uuid) as result`);
  await setAuthStub(CAROL);
  await compare('knock carol accept', `select public.respond_room_knock_v1('${knockBIdO}'::uuid, true) as result`, `select public.respond_room_knock_v1(${T4(CAROL)}, '${knockBIdT}'::uuid, true) as result`);
  await setAuthStub(BOB);
  await compare('knock bob get ACCEPTED', `select public.get_my_room_knock_v1('${knockBIdO}'::uuid) as result`, `select public.get_my_room_knock_v1(${T4(BOB)}, '${knockBIdT}'::uuid) as result`);
  await setAuthStub(CAROL);
  await compare('knock carol accept retry (unchanged)', `select public.respond_room_knock_v1('${knockBIdO}'::uuid, true) as result`, `select public.respond_room_knock_v1(${T4(CAROL)}, '${knockBIdT}'::uuid, true) as result`);
  await setAuthStub(ALICE);
  await compareErr('knock get by non-visitor', `select public.get_my_room_knock_v1('${knockBIdO}'::uuid) as result`, `select public.get_my_room_knock_v1(${T4(ALICE)}, '${knockBIdT}'::uuid) as result`, 'KNOCK_NOT_FOUND');
  await compareErr('knock respond by non-owner', `select public.respond_room_knock_v1('${knockBIdO}'::uuid, false) as result`, `select public.respond_room_knock_v1(${T4(ALICE)}, '${knockBIdT}'::uuid, false) as result`, 'KNOCK_NOT_FOUND');
  await compareErr('knock respond null accept', `select public.respond_room_knock_v1('${knockBIdO}'::uuid, null) as result`, `select public.respond_room_knock_v1(${T4(CAROL)}, '${knockBIdT}'::uuid, null) as result`, 'INVALID_RESPONSE');
  // Decline: carol lists first (presence), alice knocks, carol declines.
  await setAuthStub(CAROL);
  await compare('knock carol list (presence, decline flow)', `select public.list_my_room_knocks_v1() as result`, `select public.list_my_room_knocks_v1(${T4(CAROL)}) as result`);
  await setAuthStub(ALICE);
  const knockAC = await compare('knock alice->carol PENDING', `select public.knock_friend_personal_room_v1('${CAROL}'::uuid) as result`, `select public.knock_friend_personal_room_v1(${T4(ALICE)}, '${CAROL}'::uuid) as result`);
  const knockAIdO = knockAC.o.value.knockId, knockAIdT = knockAC.t.value.knockId;
  await setAuthStub(CAROL);
  await compare('knock carol decline', `select public.respond_room_knock_v1('${knockAIdO}'::uuid, false) as result`, `select public.respond_room_knock_v1(${T4(CAROL)}, '${knockAIdT}'::uuid, false) as result`);
  await setAuthStub(ALICE);
  await compareErr('knock after decline (10 min block)', `select public.knock_friend_personal_room_v1('${CAROL}'::uuid) as result`, `select public.knock_friend_personal_room_v1(${T4(ALICE)}, '${CAROL}'::uuid) as result`, 'VISIT_DECLINED');
  // Expired PENDING: respond returns EXPIRED.
  const EXP_KNOCK = 'd1000000-0000-4000-8000-000000000001';
  for (const [db, roomId] of [[orig, null], [owner, null]]) {
    const roomRow = await db([`select id from public.world_player_rooms where owner_user_id = '${CAROL}'::uuid`]);
    const roomIdV = roomRow[0].id;
    await db([`insert into private.world_room_knocks (id, room_id, visitor_user_id, status, created_at, expires_at) values ('${EXP_KNOCK}'::uuid, '${roomIdV}'::uuid, '${BOB}'::uuid, 'PENDING', now() - interval '60 seconds', now() - interval '30 seconds')`]);
  }
  await setAuthStub(CAROL);
  await compare('knock respond expired', `select public.respond_room_knock_v1('${EXP_KNOCK}'::uuid, true) as result`, `select public.respond_room_knock_v1(${T4(CAROL)}, '${EXP_KNOCK}'::uuid, true) as result`);
  // Rate limit: 5 EXPIRED rows (carol->bob), then carol lists (presence),
  // then the 6th knock in 2 min is RATE_LIMITED.
  for (const db of [orig, owner]) {
    const roomRow = await db([`select id from public.world_player_rooms where owner_user_id = '${BOB}'::uuid`]);
    const roomIdV = roomRow[0].id;
    await db([`insert into private.world_room_knocks (room_id, visitor_user_id, status, created_at, expires_at) select '${roomIdV}'::uuid, '${CAROL}'::uuid, 'EXPIRED', now(), now() + interval '1 hour' from generate_series(1,5)`]);
  }
  await setAuthStub(BOB);
  await compare('knock bob list (presence, rate-limit flow)', `select public.list_my_room_knocks_v1() as result`, `select public.list_my_room_knocks_v1(${T4(BOB)}) as result`);
  await setAuthStub(CAROL);
  await compareErr('knock carol->bob rate limited', `select public.knock_friend_personal_room_v1('${BOB}'::uuid) as result`, `select public.knock_friend_personal_room_v1(${T4(CAROL)}, '${BOB}'::uuid) as result`, 'RATE_LIMITED');
  // Alice's room is private -> ROOM_PRIVATE.
  await compareErr('knock carol->alice private room', `select public.knock_friend_personal_room_v1('${ALICE}'::uuid) as result`, `select public.knock_friend_personal_room_v1(${T4(CAROL)}, '${ALICE}'::uuid) as result`, 'ROOM_PRIVATE');

  // ---- A-3: daily quiz ----
  // The 3 questions are drawn randomly per side, so start/answer results
  // are checked field-by-field (status/progress/correct counts) with each
  // side answering its OWN questions; only the deterministic shapes
  // (get, error codes, wallet deltas) go through compare()/compareErr().
  async function quizQuestions(db, user) {
    const runs = await db([`select question_ids from private.world_daily_quiz_runs where user_id = '${user}'::uuid order by started_at desc limit 1`]);
    const ids = runs[0].question_ids;
    const qs = await db([`select question_id, correct_index from private.world_daily_quiz_questions where question_id = any(array[${ids.map((x) => `'${x}'`).join(',')}]::text[])`]);
    const byId = Object.fromEntries(qs.map((q) => [q.question_id, q.correct_index]));
    return ids.map((id) => ({ id, correct: byId[id] }));
  }
  await setAuthStub(ALICE);
  await compare('quiz get alice', `select public.get_my_world_daily_quiz_v1() as result`, `select public.get_my_world_daily_quiz_v1(${T4(ALICE)}) as result`);
  // Expected difference #10 (guest-open): the original's quiz caller
  // requires a non-banned profile; Tier 4 only needs the session.
  for (const u of [NOPROFILE, BANNED]) {
    await setAuthStub(u);
    const qO = await callOrig(orig, `select public.get_my_world_daily_quiz_v1() as result`);
    const qT = await callTier4(`select public.get_my_world_daily_quiz_v1(${T4(u)}) as result`);
    check(!qO.ok && qO.code === 'ACCOUNT_UNAVAILABLE' && qT.ok && qT.value.status === 'AVAILABLE', `quiz get ${u === NOPROFILE ? 'noprofile' : 'banned'} (expected diff: orig ACCOUNT_UNAVAILABLE, tier4 AVAILABLE)`, `orig=${qO.code} tier4=${JSON.stringify(scrubWrite(qT.value))}`);
  }
  await setAuthStub(ALICE);
  const qStartO = await callOrig(orig, `select public.start_my_world_daily_quiz_v1() as result`);
  const qStartT = await callTier4(`select public.start_my_world_daily_quiz_v1(${T4(ALICE)}) as result`);
  check(qStartO.ok && qStartT.ok && qStartO.value.status === 'ACTIVE' && qStartT.value.status === 'ACTIVE' && qStartO.value.runId && qStartT.value.runId, 'quiz start ACTIVE with runId both sides', `orig=${JSON.stringify(scrubWrite(qStartO.value))} tier4=${JSON.stringify(scrubWrite(qStartT.value))}`);
  const qStartO2 = await callOrig(orig, `select public.start_my_world_daily_quiz_v1() as result`);
  const qStartT2 = await callTier4(`select public.start_my_world_daily_quiz_v1(${T4(ALICE)}) as result`);
  check(qStartO2.value.runId === qStartO.value.runId && qStartT2.value.runId === qStartT.value.runId, 'quiz start twice same runId per side');
  const qqO = await quizQuestions(orig, ALICE);
  const qqT = await quizQuestions(owner, ALICE);
  check(qqO.length === 3 && qqT.length === 3, 'quiz 3 questions per side');
  await compareErr('quiz answer wrong question', `select public.answer_my_world_daily_quiz_v1('${qStartO.value.runId}'::uuid, '${qqO[1].id}', ${qqO[1].correct}::smallint) as result`, `select public.answer_my_world_daily_quiz_v1(${T4(ALICE)}, '${qStartT.value.runId}'::uuid, '${qqT[1].id}', ${qqT[1].correct}::smallint) as result`, 'QUIZ_QUESTION_MISMATCH');
  await compareErr('quiz answer index 5', `select public.answer_my_world_daily_quiz_v1('${qStartO.value.runId}'::uuid, '${qqO[0].id}', 5::smallint) as result`, `select public.answer_my_world_daily_quiz_v1(${T4(ALICE)}, '${qStartT.value.runId}'::uuid, '${qqT[0].id}', 5::smallint) as result`, 'INVALID_ANSWER');
  const qA1O = await callOrig(orig, `select public.answer_my_world_daily_quiz_v1('${qStartO.value.runId}'::uuid, '${qqO[0].id}', ${qqO[0].correct}::smallint) as result`);
  const qA1T = await callTier4(`select public.answer_my_world_daily_quiz_v1(${T4(ALICE)}, '${qStartT.value.runId}'::uuid, '${qqT[0].id}', ${qqT[0].correct}::smallint) as result`);
  check(qA1O.ok && qA1T.ok && qA1O.value.lastAnswer.correct === true && qA1T.value.lastAnswer.correct === true && qA1O.value.progress.answered === 1 && qA1T.value.progress.answered === 1 && qA1O.value.status === 'ACTIVE' && qA1T.value.status === 'ACTIVE', 'quiz Q1 correct both sides');
  await setAuthStub(BOB);
  await compareErr('quiz answer by other account', `select public.answer_my_world_daily_quiz_v1('${qStartO.value.runId}'::uuid, '${qqO[1].id}', ${qqO[1].correct}::smallint) as result`, `select public.answer_my_world_daily_quiz_v1(${T4(BOB)}, '${qStartT.value.runId}'::uuid, '${qqT[1].id}', ${qqT[1].correct}::smallint) as result`, 'QUIZ_RUN_NOT_FOUND');
  await setAuthStub(ALICE);
  const qA2O = await callOrig(orig, `select public.answer_my_world_daily_quiz_v1('${qStartO.value.runId}'::uuid, '${qqO[1].id}', ${(qqO[1].correct + 1) % 4}::smallint) as result`);
  const qA2T = await callTier4(`select public.answer_my_world_daily_quiz_v1(${T4(ALICE)}, '${qStartT.value.runId}'::uuid, '${qqT[1].id}', ${(qqT[1].correct + 1) % 4}::smallint) as result`);
  check(qA2O.ok && qA2T.ok && qA2O.value.lastAnswer.correct === false && qA2T.value.lastAnswer.correct === false && qA2O.value.progress.answered === 2 && qA2T.value.progress.answered === 2 && qA2O.value.progress.correct === 1 && qA2T.value.progress.correct === 1, 'quiz Q2 wrong both sides');
  await compareErr('quiz re-answer Q2', `select public.answer_my_world_daily_quiz_v1('${qStartO.value.runId}'::uuid, '${qqO[1].id}', ${qqO[1].correct}::smallint) as result`, `select public.answer_my_world_daily_quiz_v1(${T4(ALICE)}, '${qStartT.value.runId}'::uuid, '${qqT[1].id}', ${qqT[1].correct}::smallint) as result`, 'QUIZ_ALREADY_ANSWERED');
  const qA3O = await callOrig(orig, `select public.answer_my_world_daily_quiz_v1('${qStartO.value.runId}'::uuid, '${qqO[2].id}', ${qqO[2].correct}::smallint) as result`);
  const qA3T = await callTier4(`select public.answer_my_world_daily_quiz_v1(${T4(ALICE)}, '${qStartT.value.runId}'::uuid, '${qqT[2].id}', ${qqT[2].correct}::smallint) as result`);
  check(qA3O.ok && qA3T.ok && qA3O.value.status === 'PASSED' && qA3T.value.status === 'PASSED' && qA3O.value.progress.correct === 2 && qA3T.value.progress.correct === 2 && qA3O.value.reward && qA3T.value.reward, 'quiz Q3 correct -> PASSED with reward both sides');
  {
    const rtO = await orig([`select reward_transaction_id from private.world_daily_quiz_runs where run_id = '${qStartO.value.runId}'::uuid`]);
    const rtT = await owner([`select reward_transaction_id from private.world_daily_quiz_runs where run_id = '${qStartT.value.runId}'::uuid`]);
    check(rtO[0].reward_transaction_id && rtT[0].reward_transaction_id, 'quiz PASSED stores reward transaction both sides');
  }
  await compareErr('quiz answer after completion', `select public.answer_my_world_daily_quiz_v1('${qStartO.value.runId}'::uuid, '${qqO[2].id}', ${qqO[2].correct}::smallint) as result`, `select public.answer_my_world_daily_quiz_v1(${T4(ALICE)}, '${qStartT.value.runId}'::uuid, '${qqT[2].id}', ${qqT[2].correct}::smallint) as result`, 'QUIZ_ALREADY_ANSWERED');
  await compare('quiz get after PASSED', `select public.get_my_world_daily_quiz_v1() as result`, `select public.get_my_world_daily_quiz_v1(${T4(ALICE)}) as result`);
  await compare('wallet alice after quiz (50+50=100)', `select public.get_my_world_wallet_v1() as result`, `select public.get_my_world_wallet_v1(${T4(ALICE)}) as result`);
  // Expired run (yesterday) on both sides, each with its own questions.
  const qKst = new Date().toLocaleString('en-CA', { timeZone: 'Asia/Seoul', year: 'numeric', month: '2-digit', day: '2-digit' });
  const qYest = new Date(new Date(qKst + 'T00:00:00Z').getTime() - 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
  for (const [db, qq] of [[orig, qqO], [owner, qqT]]) {
    await db([`insert into private.world_daily_quiz_runs (user_id, reward_date, question_ids) values ('${BOB}'::uuid, '${qYest}'::date, array['${qq[0].id}','${qq[1].id}','${qq[2].id}']::text[])`]);
  }
  const qExpO = await orig([`select run_id from private.world_daily_quiz_runs where user_id = '${BOB}'::uuid and reward_date = '${qYest}'::date`]);
  const qExpT = await owner([`select run_id from private.world_daily_quiz_runs where user_id = '${BOB}'::uuid and reward_date = '${qYest}'::date`]);
  await setAuthStub(BOB);
  await compareErr('quiz expired run', `select public.answer_my_world_daily_quiz_v1('${qExpO[0].run_id}'::uuid, '${qqO[0].id}', 0::smallint) as result`, `select public.answer_my_world_daily_quiz_v1(${T4(BOB)}, '${qExpT[0].run_id}'::uuid, '${qqT[0].id}', 0::smallint) as result`, 'QUIZ_RUN_EXPIRED');

  // ---- A-3: life skills ----
  for (const db of [orig, owner]) {
    await db([`insert into private.world_player_life_skills (user_id, skill_id, total_xp, version) values ('${ALICE}'::uuid, 'life.fishing', 300, 1) on conflict (user_id, skill_id) do update set total_xp = 300`]);
  }
  await setAuthStub(ALICE);
  await compare('life skills alice (fishing 300 XP)', `select public.get_my_world_life_skills_v1() as result`, `select public.get_my_world_life_skills_v1(${T4(ALICE)}) as result`);
  await compare('life tree fishing alice', `select public.get_my_world_life_skill_tree_v1('life.fishing') as result`, `select public.get_my_world_life_skill_tree_v1(${T4(ALICE)}, 'life.fishing') as result`);
  await compareErr('life tree unknown skill', `select public.get_my_world_life_skill_tree_v1('life.nope') as result`, `select public.get_my_world_life_skill_tree_v1(${T4(ALICE)}, 'life.nope') as result`, 'LIFE_SKILL_NOT_FOUND');
  // Expected difference #10 (guest-open): noprofile life skills.
  await setAuthStub(NOPROFILE);
  {
    const lNoO = await callOrig(orig, `select public.get_my_world_life_skills_v1() as result`);
    const lNoT = await callTier4(`select public.get_my_world_life_skills_v1(${T4(NOPROFILE)}) as result`);
    check(!lNoO.ok && lNoO.code === 'ACCOUNT_UNAVAILABLE' && lNoT.ok, 'life skills noprofile (expected diff: orig ACCOUNT_UNAVAILABLE, tier4 succeeds)', `orig=${lNoO.code}`);
  }
  await setAuthStub(ALICE);
  const L1 = 'e1000000-0000-4000-8000-000000000101';
  await compare('life unlock steady_hands', `select public.unlock_my_world_life_node_v1('life.node.fishing.steady_hands', '${L1}'::uuid) as result`, `select public.unlock_my_world_life_node_v1(${T4(ALICE)}, 'life.node.fishing.steady_hands', '${L1}'::uuid) as result`);
  await compare('life unlock steady_hands replay', `select public.unlock_my_world_life_node_v1('life.node.fishing.steady_hands', '${L1}'::uuid) as result`, `select public.unlock_my_world_life_node_v1(${T4(ALICE)}, 'life.node.fishing.steady_hands', '${L1}'::uuid) as result`);
  await compareErr('life unlock same key diff node', `select public.unlock_my_world_life_node_v1('life.node.fishing.fish_sense', '${L1}'::uuid) as result`, `select public.unlock_my_world_life_node_v1(${T4(ALICE)}, 'life.node.fishing.fish_sense', '${L1}'::uuid) as result`, 'IDEMPOTENCY_CONFLICT');
  await compare('life unlock fish_sense', `select public.unlock_my_world_life_node_v1('life.node.fishing.fish_sense', 'e1000000-0000-4000-8000-000000000102'::uuid) as result`, `select public.unlock_my_world_life_node_v1(${T4(ALICE)}, 'life.node.fishing.fish_sense', 'e1000000-0000-4000-8000-000000000102'::uuid) as result`);
  await compareErr('life unlock 0 SP left', `select public.unlock_my_world_life_node_v1('life.node.fishing.fish_sense', 'e1000000-0000-4000-8000-000000000103'::uuid) as result`, `select public.unlock_my_world_life_node_v1(${T4(ALICE)}, 'life.node.fishing.fish_sense', 'e1000000-0000-4000-8000-000000000103'::uuid) as result`, 'LIFE_SP_INSUFFICIENT');
  await compareErr('life unlock COMING_SOON node', `select public.unlock_my_world_life_node_v1('life.node.fishing.baitcraft', 'e1000000-0000-4000-8000-000000000104'::uuid) as result`, `select public.unlock_my_world_life_node_v1(${T4(ALICE)}, 'life.node.fishing.baitcraft', 'e1000000-0000-4000-8000-000000000104'::uuid) as result`, 'LIFE_NODE_NOT_FOUND');
  await compareErr('life unlock unknown node', `select public.unlock_my_world_life_node_v1('life.node.fishing.nope', 'e1000000-0000-4000-8000-000000000105'::uuid) as result`, `select public.unlock_my_world_life_node_v1(${T4(ALICE)}, 'life.node.fishing.nope', 'e1000000-0000-4000-8000-000000000105'::uuid) as result`, 'LIFE_NODE_NOT_FOUND');
  await compareErr('life unlock malformed node id', `select public.unlock_my_world_life_node_v1('bad-id', 'e1000000-0000-4000-8000-000000000106'::uuid) as result`, `select public.unlock_my_world_life_node_v1(${T4(ALICE)}, 'bad-id', 'e1000000-0000-4000-8000-000000000106'::uuid) as result`, 'LIFE_NODE_NOT_FOUND');
  await setAuthStub(BOB);
  await compareErr('life unlock bob skill level 1 < 2', `select public.unlock_my_world_life_node_v1('life.node.fishing.steady_hands', 'e1000000-0000-4000-8000-000000000107'::uuid) as result`, `select public.unlock_my_world_life_node_v1(${T4(BOB)}, 'life.node.fishing.steady_hands', 'e1000000-0000-4000-8000-000000000107'::uuid) as result`, 'LIFE_SKILL_LEVEL_REQUIRED');
  await setAuthStub(ALICE);
  await compare('life reset fishing', `select public.reset_my_world_life_tree_v1('life.fishing', 'e1000000-0000-4000-8000-000000000201'::uuid) as result`, `select public.reset_my_world_life_tree_v1(${T4(ALICE)}, 'life.fishing', 'e1000000-0000-4000-8000-000000000201'::uuid) as result`);
  await compare('life reset replay', `select public.reset_my_world_life_tree_v1('life.fishing', 'e1000000-0000-4000-8000-000000000201'::uuid) as result`, `select public.reset_my_world_life_tree_v1(${T4(ALICE)}, 'life.fishing', 'e1000000-0000-4000-8000-000000000201'::uuid) as result`);
  await compare('life tree after reset', `select public.get_my_world_life_skill_tree_v1('life.fishing') as result`, `select public.get_my_world_life_skill_tree_v1(${T4(ALICE)}, 'life.fishing') as result`);
  await compareErr('life reset empty tree', `select public.reset_my_world_life_tree_v1('life.fishing', 'e1000000-0000-4000-8000-000000000202'::uuid) as result`, `select public.reset_my_world_life_tree_v1(${T4(ALICE)}, 'life.fishing', 'e1000000-0000-4000-8000-000000000202'::uuid) as result`, 'LIFE_TREE_RESET_EMPTY');
  await compare('life unlock after reset', `select public.unlock_my_world_life_node_v1('life.node.fishing.steady_hands', 'e1000000-0000-4000-8000-000000000108'::uuid) as result`, `select public.unlock_my_world_life_node_v1(${T4(ALICE)}, 'life.node.fishing.steady_hands', 'e1000000-0000-4000-8000-000000000108'::uuid) as result`);
  await compareErr('life reset inside cooldown', `select public.reset_my_world_life_tree_v1('life.fishing', 'e1000000-0000-4000-8000-000000000203'::uuid) as result`, `select public.reset_my_world_life_tree_v1(${T4(ALICE)}, 'life.fishing', 'e1000000-0000-4000-8000-000000000203'::uuid) as result`, 'LIFE_TREE_RESET_COOLDOWN');
  await compareErr('life reset unknown skill', `select public.reset_my_world_life_tree_v1('life.nope', 'e1000000-0000-4000-8000-000000000204'::uuid) as result`, `select public.reset_my_world_life_tree_v1(${T4(ALICE)}, 'life.nope', 'e1000000-0000-4000-8000-000000000204'::uuid) as result`, 'LIFE_SKILL_NOT_FOUND');
  await compareErr('life reset malformed skill id', `select public.reset_my_world_life_tree_v1('bad', 'e1000000-0000-4000-8000-000000000205'::uuid) as result`, `select public.reset_my_world_life_tree_v1(${T4(ALICE)}, 'bad', 'e1000000-0000-4000-8000-000000000205'::uuid) as result`, 'LIFE_SKILL_NOT_FOUND');

  // ---- A-3: social ----
  await setAuthStub(ALICE);
  // Expected difference #11 inside the friend list: carol's card reads
  // inhaVerified true on the original and false on Tier 4. Compare with
  // the key stripped, then assert the flip is exactly one true->false.
  {
    const sA = await compareNoInha('social alice', `select public.get_my_world_social() as result`, `select public.get_my_world_social(${T4(ALICE)}) as result`);
    if (sA.o.ok && sA.t.ok) {
      const oI = collectInhaVerified(sA.o.value), tI = collectInhaVerified(sA.t.value);
      check(oI.length === tI.length && oI.filter(Boolean).length === tI.filter(Boolean).length + 1, 'social alice carol card (expected diff #11: exactly one inhaVerified true->false)', `orig=${JSON.stringify(oI)} tier4=${JSON.stringify(tI)}`);
    }
  }
  await compare('public profile alice->bob', `select public.get_world_public_profile('${BOB}'::uuid) as result`, `select public.get_world_public_profile(${T4(ALICE)}, '${BOB}'::uuid) as result`);
  // Expected difference #11 (world_card): carol is email-verified only;
  // the original's card reads inhaVerified true via auth.users email,
  // Tier 4 is badges-only so it reads false.
  {
    const pO = await callOrig(orig, `select public.get_world_public_profile('${CAROL}'::uuid) as result`);
    const pT = await callTier4(`select public.get_world_public_profile(${T4(ALICE)}, '${CAROL}'::uuid) as result`);
    check(pO.ok && pT.ok && pO.value.relationship === 'friends' && pT.value.relationship === 'friends' && pO.value.nickname === 'tier4carol' && pT.value.nickname === 'tier4carol' && pO.value.inhaVerified === true && pT.value.inhaVerified === false, 'public profile alice->carol (expected diff: orig inhaVerified true, tier4 false)', `orig=${JSON.stringify(scrubWrite(pO.value))} tier4=${JSON.stringify(scrubWrite(pT.value))}`);
  }
  await compareErr('public profile self', `select public.get_world_public_profile('${ALICE}'::uuid) as result`, `select public.get_world_public_profile(${T4(ALICE)}, '${ALICE}'::uuid) as result`, 'TARGET_UNAVAILABLE');
  await compareErr('public profile stranger', `select public.get_world_public_profile('${STRANGER}'::uuid) as result`, `select public.get_world_public_profile(${T4(ALICE)}, '${STRANGER}'::uuid) as result`, 'TARGET_UNAVAILABLE');
  await compareErr('public profile banned', `select public.get_world_public_profile('${BANNED}'::uuid) as result`, `select public.get_world_public_profile(${T4(ALICE)}, '${BANNED}'::uuid) as result`, 'TARGET_UNAVAILABLE');
  await compare('relationship alice->bob', `select public.get_world_relationship('${BOB}'::uuid) as result`, `select public.get_world_relationship(${T4(ALICE)}, '${BOB}'::uuid) as result`);
  await compare('relationship alice->dave', `select public.get_world_relationship('${DAVE}'::uuid) as result`, `select public.get_world_relationship(${T4(ALICE)}, '${DAVE}'::uuid) as result`);
  // Expected difference #6 (social caller): orig ACCOUNT_UNAVAILABLE,
  // tier4 PROFILE_NOT_FOUND (Worker maps to 409 PROFILE_REQUIRED).
  for (const u of [NOPROFILE, BANNED]) {
    await setAuthStub(u);
    const sO = await callOrig(orig, `select public.get_my_world_social() as result`);
    const sT = await callTier4(`select public.get_my_world_social(${T4(u)}) as result`);
    check(!sO.ok && sO.code === 'ACCOUNT_UNAVAILABLE' && !sT.ok && sT.code === 'PROFILE_NOT_FOUND', `social ${u === NOPROFILE ? 'noprofile' : 'banned'} (expected diff: orig ACCOUNT_UNAVAILABLE, tier4 PROFILE_NOT_FOUND)`, `orig=${sO.code} tier4=${sT.code}`);
  }
  await setAuthStub(ALICE);
  await compare('friend send alice->dave', `select public.send_world_friend_request('${DAVE}'::uuid) as result`, `select public.send_world_friend_request(${T4(ALICE)}, '${DAVE}'::uuid) as result`);
  await compare('friend send alice->dave again', `select public.send_world_friend_request('${DAVE}'::uuid) as result`, `select public.send_world_friend_request(${T4(ALICE)}, '${DAVE}'::uuid) as result`);
  await setAuthStub(DAVE);
  await compare('social dave incoming 1', `select public.get_my_world_social() as result`, `select public.get_my_world_social(${T4(DAVE)}) as result`);
  await compare('friend respond dave accept', `select public.respond_world_friend_request('${ALICE}'::uuid, true) as result`, `select public.respond_world_friend_request(${T4(DAVE)}, '${ALICE}'::uuid, true) as result`);
  await setAuthStub(ALICE);
  await compare('friend send to existing friend', `select public.send_world_friend_request('${DAVE}'::uuid) as result`, `select public.send_world_friend_request(${T4(ALICE)}, '${DAVE}'::uuid) as result`);
  await compare('friend remove alice->dave', `select public.remove_world_friend('${DAVE}'::uuid) as result`, `select public.remove_world_friend(${T4(ALICE)}, '${DAVE}'::uuid) as result`);
  await compare('friend send alice->dave (2nd)', `select public.send_world_friend_request('${DAVE}'::uuid) as result`, `select public.send_world_friend_request(${T4(ALICE)}, '${DAVE}'::uuid) as result`);
  await compare('friend cancel alice->dave', `select public.cancel_world_friend_request('${DAVE}'::uuid) as result`, `select public.cancel_world_friend_request(${T4(ALICE)}, '${DAVE}'::uuid) as result`);
  await compare('friend send alice->dave (3rd)', `select public.send_world_friend_request('${DAVE}'::uuid) as result`, `select public.send_world_friend_request(${T4(ALICE)}, '${DAVE}'::uuid) as result`);
  await setAuthStub(DAVE);
  await compare('friend respond dave decline', `select public.respond_world_friend_request('${ALICE}'::uuid, false) as result`, `select public.respond_world_friend_request(${T4(DAVE)}, '${ALICE}'::uuid, false) as result`);
  await setAuthStub(BOB);
  await compare('friend respond bob no pending', `select public.respond_world_friend_request('${ALICE}'::uuid, true) as result`, `select public.respond_world_friend_request(${T4(BOB)}, '${ALICE}'::uuid, true) as result`);
  await setAuthStub(ALICE);
  await compareErr('friend respond null accept', `select public.respond_world_friend_request('${DAVE}'::uuid, null) as result`, `select public.respond_world_friend_request(${T4(ALICE)}, '${DAVE}'::uuid, null) as result`, 'INVALID_ARGUMENT');
  await compareErr('friend send self', `select public.send_world_friend_request('${ALICE}'::uuid) as result`, `select public.send_world_friend_request(${T4(ALICE)}, '${ALICE}'::uuid) as result`, 'TARGET_UNAVAILABLE');
  await compare('report alice->dave spam', `select public.report_world_user('${DAVE}'::uuid, 'spam', null) as result`, `select public.report_world_user(${T4(ALICE)}, '${DAVE}'::uuid, 'spam', null) as result`);
  await compare('report alice->dave spam duplicate', `select public.report_world_user('${DAVE}'::uuid, 'spam', null) as result`, `select public.report_world_user(${T4(ALICE)}, '${DAVE}'::uuid, 'spam', null) as result`);
  await compare('report alice->dave other+zone', `select public.report_world_user('${DAVE}'::uuid, 'other', 'AREA_MAIN_GATE') as result`, `select public.report_world_user(${T4(ALICE)}, '${DAVE}'::uuid, 'other', 'AREA_MAIN_GATE') as result`);
  await compareErr('report bad category', `select public.report_world_user('${DAVE}'::uuid, 'bogus', null) as result`, `select public.report_world_user(${T4(ALICE)}, '${DAVE}'::uuid, 'bogus', null) as result`, 'INVALID_CATEGORY');
  await compareErr('report self', `select public.report_world_user('${ALICE}'::uuid, 'spam', null) as result`, `select public.report_world_user(${T4(ALICE)}, '${ALICE}'::uuid, 'spam', null) as result`, 'CANNOT_REPORT_SELF');
  await compareErr('report stranger', `select public.report_world_user('${STRANGER}'::uuid, 'spam', null) as result`, `select public.report_world_user(${T4(ALICE)}, '${STRANGER}'::uuid, 'spam', null) as result`, 'TARGET_UNAVAILABLE');
  await compareErr('report bad zone', `select public.report_world_user('${DAVE}'::uuid, 'spam', 'ZONE_X') as result`, `select public.report_world_user(${T4(ALICE)}, '${DAVE}'::uuid, 'spam', 'ZONE_X') as result`, 'INVALID_PLACE_ZONE');
  await compare('friend send alice->dave (block flow)', `select public.send_world_friend_request('${DAVE}'::uuid) as result`, `select public.send_world_friend_request(${T4(ALICE)}, '${DAVE}'::uuid) as result`);
  await setAuthStub(DAVE);
  await compare('friend respond dave accept (block flow)', `select public.respond_world_friend_request('${ALICE}'::uuid, true) as result`, `select public.respond_world_friend_request(${T4(DAVE)}, '${ALICE}'::uuid, true) as result`);
  await setAuthStub(ALICE);
  await compare('block alice->dave', `select public.block_world_user('${DAVE}'::uuid) as result`, `select public.block_world_user(${T4(ALICE)}, '${DAVE}'::uuid) as result`);
  // Expected difference #11: dave's profile card reads inhaVerified true
  // on the original (email-verified) and false on Tier 4 (badges-only).
  {
    const blk = await compareNoInha('public profile blocked_by_me', `select public.get_world_public_profile('${DAVE}'::uuid) as result`, `select public.get_world_public_profile(${T4(ALICE)}, '${DAVE}'::uuid) as result`);
    if (blk.o.ok && blk.t.ok) {
      check(blk.o.value.inhaVerified === true && blk.t.value.inhaVerified === false, 'public profile blocked_by_me dave inhaVerified (expected diff #11: orig true, tier4 false)');
    }
  }
  await compareErr('friend send while blocked', `select public.send_world_friend_request('${DAVE}'::uuid) as result`, `select public.send_world_friend_request(${T4(ALICE)}, '${DAVE}'::uuid) as result`, 'NOT_ALLOWED');
  await compare('unblock alice->dave', `select public.unblock_world_user('${DAVE}'::uuid) as result`, `select public.unblock_world_user(${T4(ALICE)}, '${DAVE}'::uuid) as result`);
  await setAuthStub(DAVE);
  await compare('block dave->alice', `select public.block_world_user('${ALICE}'::uuid) as result`, `select public.block_world_user(${T4(DAVE)}, '${ALICE}'::uuid) as result`);
  await setAuthStub(ALICE);
  await compare('public profile unavailable (target blocked caller)', `select public.get_world_public_profile('${DAVE}'::uuid) as result`, `select public.get_world_public_profile(${T4(ALICE)}, '${DAVE}'::uuid) as result`);
  await compareErr('friend send when target blocked caller', `select public.send_world_friend_request('${DAVE}'::uuid) as result`, `select public.send_world_friend_request(${T4(ALICE)}, '${DAVE}'::uuid) as result`, 'NOT_ALLOWED');
  await setAuthStub(DAVE);
  await compare('unblock dave->alice', `select public.unblock_world_user('${ALICE}'::uuid) as result`, `select public.unblock_world_user(${T4(DAVE)}, '${ALICE}'::uuid) as result`);
  await setAuthStub(ALICE);
  await compareErr('block self', `select public.block_world_user('${ALICE}'::uuid) as result`, `select public.block_world_user(${T4(ALICE)}, '${ALICE}'::uuid) as result`, 'TARGET_UNAVAILABLE');
  await compareErr('unblock self', `select public.unblock_world_user('${ALICE}'::uuid) as result`, `select public.unblock_world_user(${T4(ALICE)}, '${ALICE}'::uuid) as result`, 'TARGET_UNAVAILABLE');
  await setAuthStub(DAVE);
  await compare('social dave friends 0 at end', `select public.get_my_world_social() as result`, `select public.get_my_world_social(${T4(DAVE)}) as result`);

  // ---- A-3: accompany ----
  await setAuthStub(ALICE);
  await compare('accompany alice empty', `select public.get_my_world_accompany() as result`, `select public.get_my_world_accompany(${T4(ALICE)}) as result`);
  await compareErr('accompany propose non-friend', `select public.propose_world_accompany('${DAVE}'::uuid, 'poi.main-gate', 'AREA_MAIN_GATE') as result`, `select public.propose_world_accompany(${T4(ALICE)}, '${DAVE}'::uuid, 'poi.main-gate', 'AREA_MAIN_GATE') as result`, 'NOT_ALLOWED');
  const accP = await compare('accompany propose alice->bob', `select public.propose_world_accompany('${BOB}'::uuid, 'poi.main-gate', 'AREA_MAIN_GATE') as result`, `select public.propose_world_accompany(${T4(ALICE)}, '${BOB}'::uuid, 'poi.main-gate', 'AREA_MAIN_GATE') as result`);
  const accIdO = accP.o.value.id, accIdT = accP.t.value.id;
  const accP2 = await compare('accompany propose repeat same session', `select public.propose_world_accompany('${BOB}'::uuid, 'poi.main-gate', 'AREA_MAIN_GATE') as result`, `select public.propose_world_accompany(${T4(ALICE)}, '${BOB}'::uuid, 'poi.main-gate', 'AREA_MAIN_GATE') as result`);
  check(accP2.o.value.id === accIdO && accP2.t.value.id === accIdT, 'accompany propose repeat same id per side');
  await compareErr('accompany propose while offered busy', `select public.propose_world_accompany('${CAROL}'::uuid, 'poi.main-hall', 'AREA_MAIN_HALL') as result`, `select public.propose_world_accompany(${T4(ALICE)}, '${CAROL}'::uuid, 'poi.main-hall', 'AREA_MAIN_HALL') as result`, 'ALREADY_BUSY');
  await setAuthStub(BOB);
  await compare('accompany bob sees offered', `select public.get_my_world_accompany() as result`, `select public.get_my_world_accompany(${T4(BOB)}) as result`);
  await setAuthStub(CAROL);
  await compareErr('accompany respond non-invitee', `select public.respond_world_accompany('${accIdO}'::uuid, true) as result`, `select public.respond_world_accompany(${T4(CAROL)}, '${accIdT}'::uuid, true) as result`, 'TARGET_UNAVAILABLE');
  await setAuthStub(BOB);
  await compare('accompany respond accept', `select public.respond_world_accompany('${accIdO}'::uuid, true) as result`, `select public.respond_world_accompany(${T4(BOB)}, '${accIdT}'::uuid, true) as result`);
  await compare('accompany respond accept replay', `select public.respond_world_accompany('${accIdO}'::uuid, true) as result`, `select public.respond_world_accompany(${T4(BOB)}, '${accIdT}'::uuid, true) as result`);
  await setAuthStub(ALICE);
  await compareErr('accompany propose while active busy', `select public.propose_world_accompany('${CAROL}'::uuid, 'poi.main-hall', 'AREA_MAIN_HALL') as result`, `select public.propose_world_accompany(${T4(ALICE)}, '${CAROL}'::uuid, 'poi.main-hall', 'AREA_MAIN_HALL') as result`, 'ALREADY_BUSY');
  await setAuthStub(BOB);
  await compare('accompany end by invitee', `select public.end_world_accompany('${accIdO}'::uuid) as result`, `select public.end_world_accompany(${T4(BOB)}, '${accIdT}'::uuid) as result`);
  await setAuthStub(ALICE);
  await compare('accompany end replay', `select public.end_world_accompany('${accIdO}'::uuid) as result`, `select public.end_world_accompany(${T4(ALICE)}, '${accIdT}'::uuid) as result`);
  await compare('accompany alice empty after end', `select public.get_my_world_accompany() as result`, `select public.get_my_world_accompany(${T4(ALICE)}) as result`);
  await setAuthStub(CAROL);
  await compareErr('accompany end non-participant', `select public.end_world_accompany('${accIdO}'::uuid) as result`, `select public.end_world_accompany(${T4(CAROL)}, '${accIdT}'::uuid) as result`, 'TARGET_UNAVAILABLE');
  await setAuthStub(ALICE);
  await compareErr('accompany bad poi', `select public.propose_world_accompany('${BOB}'::uuid, 'poi.nope', 'AREA_MAIN_GATE') as result`, `select public.propose_world_accompany(${T4(ALICE)}, '${BOB}'::uuid, 'poi.nope', 'AREA_MAIN_GATE') as result`, 'INVALID_DESTINATION');
  await compareErr('accompany bad zone', `select public.propose_world_accompany('${BOB}'::uuid, 'poi.main-gate', 'ZONE') as result`, `select public.propose_world_accompany(${T4(ALICE)}, '${BOB}'::uuid, 'poi.main-gate', 'ZONE') as result`, 'INVALID_PLACE_ZONE');
  await compareErr('accompany propose self', `select public.propose_world_accompany('${ALICE}'::uuid, 'poi.main-gate', 'AREA_MAIN_GATE') as result`, `select public.propose_world_accompany(${T4(ALICE)}, '${ALICE}'::uuid, 'poi.main-gate', 'AREA_MAIN_GATE') as result`, 'TARGET_UNAVAILABLE');
  const EXP_ACC = 'f1000000-0000-4000-8000-000000000001';
  for (const db of [orig, owner]) {
    await db([`insert into public.world_accompany_sessions (id, inviter_id, invitee_id, place_zone_id, poi_id, state, created_at, expires_at) values ('${EXP_ACC}'::uuid, '${ALICE}'::uuid, '${BOB}'::uuid, 'AREA_MAIN_GATE', 'poi.main-gate', 'offered', now() - interval '2 minutes', now() - interval '1 minute')`]);
  }
  await compare('accompany expired not listed', `select public.get_my_world_accompany() as result`, `select public.get_my_world_accompany(${T4(ALICE)}) as result`);
  await setAuthStub(BOB);
  await compareErr('accompany respond expired', `select public.respond_world_accompany('${EXP_ACC}'::uuid, true) as result`, `select public.respond_world_accompany(${T4(BOB)}, '${EXP_ACC}'::uuid, true) as result`, 'TARGET_UNAVAILABLE');

  // ---- A-3: biryong progress + NPC relationships ----
  await setAuthStub(ALICE);
  await compare('biryong progress fresh null', `select public.get_my_biryong_progress_v1() as result`, `select public.get_my_biryong_progress_v1(${T4(ALICE)}) as result`);
  await compare('biryong merge FIND_CENTER', `select public.merge_my_biryong_progress_v1('{"step":"FIND_CENTER","lore":["lore.a"],"shouts":2}'::jsonb, false) as result`, `select public.merge_my_biryong_progress_v1(${T4(ALICE)}, '{"step":"FIND_CENTER","lore":["lore.a"],"shouts":2}'::jsonb, false) as result`);
  await compare('biryong merge older step keeps state', `select public.merge_my_biryong_progress_v1('{"step":"INTRO","lore":["lore.b","lore.a"],"shouts":1}'::jsonb, false) as result`, `select public.merge_my_biryong_progress_v1(${T4(ALICE)}, '{"step":"INTRO","lore":["lore.b","lore.a"],"shouts":1}'::jsonb, false) as result`);
  await compare('biryong merge SHOUT', `select public.merge_my_biryong_progress_v1('{"step":"SHOUT","lore":[],"shouts":5}'::jsonb, true) as result`, `select public.merge_my_biryong_progress_v1(${T4(ALICE)}, '{"step":"SHOUT","lore":[],"shouts":5}'::jsonb, true) as result`);
  await compare('biryong merge COMPLETE', `select public.merge_my_biryong_progress_v1(jsonb_build_object('step', 'COMPLETE', 'lore', jsonb_build_array('lore.c'), 'shouts', 3, 'completedAt', ((extract(epoch from now()) * 1000)::bigint))) as result`, `select public.merge_my_biryong_progress_v1(${T4(ALICE)}, jsonb_build_object('step', 'COMPLETE', 'lore', jsonb_build_array('lore.c'), 'shouts', 3, 'completedAt', ((extract(epoch from now()) * 1000)::bigint)), false) as result`);
  await compareErr('biryong merge bad step', `select public.merge_my_biryong_progress_v1('{"step":"BOGUS"}'::jsonb, false) as result`, `select public.merge_my_biryong_progress_v1(${T4(ALICE)}, '{"step":"BOGUS"}'::jsonb, false) as result`, 'INVALID_BIRYONG_STEP');
  await compareErr('biryong merge null', `select public.merge_my_biryong_progress_v1(null::jsonb, false) as result`, `select public.merge_my_biryong_progress_v1(${T4(ALICE)}, null::jsonb, false) as result`, 'INVALID_BIRYONG_PROGRESS');
  await compareErr('biryong merge bad shouts', `select public.merge_my_biryong_progress_v1('{"step":"INTRO","shouts":"abc"}'::jsonb, false) as result`, `select public.merge_my_biryong_progress_v1(${T4(ALICE)}, '{"step":"INTRO","shouts":"abc"}'::jsonb, false) as result`, 'INVALID_BIRYONG_SHOUTS');
  await compareErr('biryong merge bad lore', `select public.merge_my_biryong_progress_v1('{"step":"INTRO","lore":"x"}'::jsonb, false) as result`, `select public.merge_my_biryong_progress_v1(${T4(ALICE)}, '{"step":"INTRO","lore":"x"}'::jsonb, false) as result`, 'INVALID_BIRYONG_LORE');
  await setAuthStub(NOPROFILE);
  // Expected difference (biryong merge has no account_ok gate): the
  // original's progress table has a FK to auth.users, and the noprofile
  // fixture has no auth.users row, so the original fails with a FK
  // violation; Tier 4's sessions are the account, so the merge succeeds.
  // (Real users always have an auth.users row, so the FK never fires live.)
  {
    const mNoO = await callOrig(orig, `select public.merge_my_biryong_progress_v1('{"step":"INTRO"}'::jsonb, false) as result`);
    const mNoT = await callTier4(`select public.merge_my_biryong_progress_v1(${T4(NOPROFILE)}, '{"step":"INTRO"}'::jsonb, false) as result`);
    check(!mNoO.ok && mNoO.code.includes('world_biryong_progress_v1_user_id_fkey') && mNoT.ok && mNoT.value.step === 'INTRO', 'biryong merge noprofile INTRO (expected diff: orig FK violation, tier4 succeeds)', `orig=${mNoO.code}`);
  }
  await setAuthStub(ALICE);
  await compare('biryong npc list', `select public.get_my_biryong_npc_relationships_v1() as result`, `select public.get_my_biryong_npc_relationships_v1(${T4(ALICE)}) as result`);
  await compare('biryong npc 001 get', `select public.get_my_biryong_npc_relationship_v1('BR_NPC_001') as result`, `select public.get_my_biryong_npc_relationship_v1(${T4(ALICE)}, 'BR_NPC_001') as result`);
  await compareErr('biryong npc unknown', `select public.get_my_biryong_npc_relationship_v1('BR_NPC_999') as result`, `select public.get_my_biryong_npc_relationship_v1(${T4(ALICE)}, 'BR_NPC_999') as result`, 'BIRYONG_NPC_NOT_AVAILABLE');
  await compare('biryong advance 1->2', `select public.world_biryong_npc_relationship_advance_v1('${ALICE}'::uuid, 'BR_NPC_001', 2::smallint, 'QUEST', 'quest/test', 'result/test', 'p-biryong-1') as result`, `select public.world_biryong_npc_relationship_advance_v1(${T4(ALICE)}, 'BR_NPC_001', 2::smallint, 'QUEST', 'quest/test', 'result/test', 'p-biryong-1') as result`);
  await compare('biryong advance replay', `select public.world_biryong_npc_relationship_advance_v1('${ALICE}'::uuid, 'BR_NPC_001', 2::smallint, 'QUEST', 'quest/test', 'result/test', 'p-biryong-1') as result`, `select public.world_biryong_npc_relationship_advance_v1(${T4(ALICE)}, 'BR_NPC_001', 2::smallint, 'QUEST', 'quest/test', 'result/test', 'p-biryong-1') as result`);
  await compareErr('biryong advance same key other target', `select public.world_biryong_npc_relationship_advance_v1('${ALICE}'::uuid, 'BR_NPC_001', 3::smallint, 'QUEST', 'quest/test', 'result/test', 'p-biryong-1') as result`, `select public.world_biryong_npc_relationship_advance_v1(${T4(ALICE)}, 'BR_NPC_001', 3::smallint, 'QUEST', 'quest/test', 'result/test', 'p-biryong-1') as result`, 'IDEMPOTENCY_CONFLICT');
  await compare('biryong advance 2->3', `select public.world_biryong_npc_relationship_advance_v1('${ALICE}'::uuid, 'BR_NPC_001', 3::smallint, 'EVENT', 'event/test', 'result/test', 'p-biryong-2') as result`, `select public.world_biryong_npc_relationship_advance_v1(${T4(ALICE)}, 'BR_NPC_001', 3::smallint, 'EVENT', 'event/test', 'result/test', 'p-biryong-2') as result`);
  await compare('biryong advance to current stage', `select public.world_biryong_npc_relationship_advance_v1('${ALICE}'::uuid, 'BR_NPC_001', 3::smallint, 'SYSTEM', 'system/test', null, 'p-biryong-3') as result`, `select public.world_biryong_npc_relationship_advance_v1(${T4(ALICE)}, 'BR_NPC_001', 3::smallint, 'SYSTEM', 'system/test', null, 'p-biryong-3') as result`);
  await compareErr('biryong advance skip 1->3', `select public.world_biryong_npc_relationship_advance_v1('${ALICE}'::uuid, 'BR_NPC_002', 3::smallint, 'QUEST', 'quest/test', 'result/test', 'p-biryong-4') as result`, `select public.world_biryong_npc_relationship_advance_v1(${T4(ALICE)}, 'BR_NPC_002', 3::smallint, 'QUEST', 'quest/test', 'result/test', 'p-biryong-4') as result`, 'RELATIONSHIP_STAGE_STEP_REQUIRED');
  await compareErr('biryong advance target 1', `select public.world_biryong_npc_relationship_advance_v1('${ALICE}'::uuid, 'BR_NPC_002', 1::smallint, 'QUEST', 'quest/test', 'result/test', 'p-biryong-5') as result`, `select public.world_biryong_npc_relationship_advance_v1(${T4(ALICE)}, 'BR_NPC_002', 1::smallint, 'QUEST', 'quest/test', 'result/test', 'p-biryong-5') as result`, 'INVALID_RELATIONSHIP_STAGE');
  await compareErr('biryong advance unknown npc', `select public.world_biryong_npc_relationship_advance_v1('${ALICE}'::uuid, 'BR_NPC_999', 2::smallint, 'QUEST', 'quest/test', 'result/test', 'p-biryong-6') as result`, `select public.world_biryong_npc_relationship_advance_v1(${T4(ALICE)}, 'BR_NPC_999', 2::smallint, 'QUEST', 'quest/test', 'result/test', 'p-biryong-6') as result`, 'BIRYONG_NPC_NOT_AVAILABLE');
  await compareErr('biryong advance bad source', `select public.world_biryong_npc_relationship_advance_v1('${ALICE}'::uuid, 'BR_NPC_002', 2::smallint, 'MAGIC', 'quest/test', 'result/test', 'p-biryong-7') as result`, `select public.world_biryong_npc_relationship_advance_v1(${T4(ALICE)}, 'BR_NPC_002', 2::smallint, 'MAGIC', 'quest/test', 'result/test', 'p-biryong-7') as result`, 'INVALID_RELATIONSHIP_SOURCE');
  await compareErr('biryong advance QUEST no resultRef', `select public.world_biryong_npc_relationship_advance_v1('${ALICE}'::uuid, 'BR_NPC_002', 2::smallint, 'QUEST', 'quest/test', null, 'p-biryong-8') as result`, `select public.world_biryong_npc_relationship_advance_v1(${T4(ALICE)}, 'BR_NPC_002', 2::smallint, 'QUEST', 'quest/test', null, 'p-biryong-8') as result`, 'RELATIONSHIP_RESULT_REF_REQUIRED');
  await compareErr('biryong advance bad key', `select public.world_biryong_npc_relationship_advance_v1('${ALICE}'::uuid, 'BR_NPC_002', 2::smallint, 'QUEST', 'quest/test', 'result/test', 'bad key!') as result`, `select public.world_biryong_npc_relationship_advance_v1(${T4(ALICE)}, 'BR_NPC_002', 2::smallint, 'QUEST', 'quest/test', 'result/test', 'bad key!') as result`, 'INVALID_IDEMPOTENCY_KEY');
  // Expected difference #10 (guest-open): the original's biryong account-ok
  // requires a profile; Tier 4 only needs the session.
  await setAuthStub(NOPROFILE);
  {
    const bNoO = await callOrig(orig, `select public.world_biryong_npc_relationship_advance_v1('${NOPROFILE}'::uuid, 'BR_NPC_002', 2::smallint, 'QUEST', 'quest/test', 'result/test', 'p-biryong-9') as result`);
    const bNoT = await callTier4(`select public.world_biryong_npc_relationship_advance_v1(${T4(NOPROFILE)}, 'BR_NPC_002', 2::smallint, 'QUEST', 'quest/test', 'result/test', 'p-biryong-9') as result`);
    check(!bNoO.ok && bNoO.code === 'ACCOUNT_UNAVAILABLE' && bNoT.ok && bNoT.value.status === 'ADVANCED', 'biryong advance noprofile (expected diff: orig ACCOUNT_UNAVAILABLE, tier4 ADVANCED)', `orig=${bNoO.code} tier4=${JSON.stringify(scrubWrite(bNoT.value))}`);
  }
  await setAuthStub(ALICE);
  await compare('campus npc list', `select public.get_my_world_campus_npc_relationships_v1() as result`, `select public.get_my_world_campus_npc_relationships_v1(${T4(ALICE)}) as result`);
  await compare('campus npc 001 get', `select public.get_my_world_campus_npc_relationship_v1('INKYUNG-NPC-001') as result`, `select public.get_my_world_campus_npc_relationship_v1(${T4(ALICE)}, 'INKYUNG-NPC-001') as result`);
  await compareErr('campus npc unknown', `select public.get_my_world_campus_npc_relationship_v1('INKYUNG-NPC-999') as result`, `select public.get_my_world_campus_npc_relationship_v1(${T4(ALICE)}, 'INKYUNG-NPC-999') as result`, 'CAMPUS_NPC_NOT_AVAILABLE');
  await compare('campus apply FIRST_MEETING', `select public.world_campus_npc_relationship_apply_v1('${ALICE}'::uuid, 'INKYUNG-NPC-001', 1, 'FIRST_MEETING', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-1') as result`, `select public.world_campus_npc_relationship_apply_v1(${T4(ALICE)}, 'INKYUNG-NPC-001', 1, 'FIRST_MEETING', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-1') as result`);
  await compare('campus apply replay', `select public.world_campus_npc_relationship_apply_v1('${ALICE}'::uuid, 'INKYUNG-NPC-001', 1, 'FIRST_MEETING', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-1') as result`, `select public.world_campus_npc_relationship_apply_v1(${T4(ALICE)}, 'INKYUNG-NPC-001', 1, 'FIRST_MEETING', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-1') as result`);
  await compare('campus apply second FIRST_MEETING', `select public.world_campus_npc_relationship_apply_v1('${ALICE}'::uuid, 'INKYUNG-NPC-001', 1, 'FIRST_MEETING', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-2') as result`, `select public.world_campus_npc_relationship_apply_v1(${T4(ALICE)}, 'INKYUNG-NPC-001', 1, 'FIRST_MEETING', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-2') as result`);
  await compare('campus apply MEANINGFUL_DIALOGUE', `select public.world_campus_npc_relationship_apply_v1('${ALICE}'::uuid, 'INKYUNG-NPC-001', 1, 'MEANINGFUL_DIALOGUE', 'GREETING_WARM', 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-3') as result`, `select public.world_campus_npc_relationship_apply_v1(${T4(ALICE)}, 'INKYUNG-NPC-001', 1, 'MEANINGFUL_DIALOGUE', 'GREETING_WARM', 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-3') as result`);
  await compare('campus apply NEGATIVE_CHOICE', `select public.world_campus_npc_relationship_apply_v1('${ALICE}'::uuid, 'INKYUNG-NPC-001', 1, 'NEGATIVE_CHOICE', null, 1, (-3)::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-4') as result`, `select public.world_campus_npc_relationship_apply_v1(${T4(ALICE)}, 'INKYUNG-NPC-001', 1, 'NEGATIVE_CHOICE', null, 1, (-3)::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-4') as result`);
  await compareErr('campus apply NEGATIVE_CHOICE positive delta', `select public.world_campus_npc_relationship_apply_v1('${ALICE}'::uuid, 'INKYUNG-NPC-001', 1, 'NEGATIVE_CHOICE', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-5') as result`, `select public.world_campus_npc_relationship_apply_v1(${T4(ALICE)}, 'INKYUNG-NPC-001', 1, 'NEGATIVE_CHOICE', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-5') as result`, 'RELATIONSHIP_DELTA_SIGN_MISMATCH');
  await compareErr('campus apply version mismatch', `select public.world_campus_npc_relationship_apply_v1('${ALICE}'::uuid, 'INKYUNG-NPC-001', 2, 'REUNION', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-6') as result`, `select public.world_campus_npc_relationship_apply_v1(${T4(ALICE)}, 'INKYUNG-NPC-001', 2, 'REUNION', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-6') as result`, 'RELATIONSHIP_DEFINITION_VERSION_MISMATCH');
  await compareErr('campus apply unknown npc', `select public.world_campus_npc_relationship_apply_v1('${ALICE}'::uuid, 'INKYUNG-NPC-999', 1, 'REUNION', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-7') as result`, `select public.world_campus_npc_relationship_apply_v1(${T4(ALICE)}, 'INKYUNG-NPC-999', 1, 'REUNION', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-7') as result`, 'CAMPUS_NPC_NOT_AVAILABLE');
  await compareErr('campus apply delta 11', `select public.world_campus_npc_relationship_apply_v1('${ALICE}'::uuid, 'INKYUNG-NPC-001', 1, 'REUNION', null, 1, 11::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-8') as result`, `select public.world_campus_npc_relationship_apply_v1(${T4(ALICE)}, 'INKYUNG-NPC-001', 1, 'REUNION', null, 1, 11::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-8') as result`, 'INVALID_RELATIONSHIP_DELTA');
  await compareErr('campus apply delta 0', `select public.world_campus_npc_relationship_apply_v1('${ALICE}'::uuid, 'INKYUNG-NPC-001', 1, 'REUNION', null, 1, 0::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-9') as result`, `select public.world_campus_npc_relationship_apply_v1(${T4(ALICE)}, 'INKYUNG-NPC-001', 1, 'REUNION', null, 1, 0::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-9') as result`, 'INVALID_RELATIONSHIP_DELTA');
  await compareErr('campus apply bad event', `select public.world_campus_npc_relationship_apply_v1('${ALICE}'::uuid, 'INKYUNG-NPC-001', 1, 'HUG', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-10') as result`, `select public.world_campus_npc_relationship_apply_v1(${T4(ALICE)}, 'INKYUNG-NPC-001', 1, 'HUG', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-10') as result`, 'INVALID_CAMPUS_NPC_RELATIONSHIP_EVENT');
  await compareErr('campus apply FIRST_MEETING occurrence 2', `select public.world_campus_npc_relationship_apply_v1('${ALICE}'::uuid, 'INKYUNG-NPC-001', 1, 'FIRST_MEETING', null, 2, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-11') as result`, `select public.world_campus_npc_relationship_apply_v1(${T4(ALICE)}, 'INKYUNG-NPC-001', 1, 'FIRST_MEETING', null, 2, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-11') as result`, 'INVALID_FIRST_MEETING_OCCURRENCE');
  await compareErr('campus apply bad signal', `select public.world_campus_npc_relationship_apply_v1('${ALICE}'::uuid, 'INKYUNG-NPC-001', 1, 'REUNION', 'lower', 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-12') as result`, `select public.world_campus_npc_relationship_apply_v1(${T4(ALICE)}, 'INKYUNG-NPC-001', 1, 'REUNION', 'lower', 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-12') as result`, 'INVALID_RELATIONSHIP_SIGNAL');
  await compareErr('campus apply bad source', `select public.world_campus_npc_relationship_apply_v1('${ALICE}'::uuid, 'INKYUNG-NPC-001', 1, 'REUNION', null, 1, 5::smallint, 'MAGIC', 'oracle/test', 'p-campus-13') as result`, `select public.world_campus_npc_relationship_apply_v1(${T4(ALICE)}, 'INKYUNG-NPC-001', 1, 'REUNION', null, 1, 5::smallint, 'MAGIC', 'oracle/test', 'p-campus-13') as result`, 'INVALID_RELATIONSHIP_SOURCE');
  // Expected difference #10 (guest-open): the original's campus account-ok
  // requires a profile; Tier 4 only needs the session.
  await setAuthStub(NOPROFILE);
  {
    const cNoO = await callOrig(orig, `select public.world_campus_npc_relationship_apply_v1('${NOPROFILE}'::uuid, 'INKYUNG-NPC-002', 1, 'FIRST_MEETING', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-14') as result`);
    const cNoT = await callTier4(`select public.world_campus_npc_relationship_apply_v1(${T4(NOPROFILE)}, 'INKYUNG-NPC-002', 1, 'FIRST_MEETING', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'p-campus-14') as result`);
    check(!cNoO.ok && cNoO.code === 'ACCOUNT_UNAVAILABLE' && cNoT.ok && cNoT.value.status === 'APPLIED', 'campus apply noprofile (expected diff: orig ACCOUNT_UNAVAILABLE, tier4 APPLIED)', `orig=${cNoO.code} tier4=${JSON.stringify(scrubWrite(cNoT.value))}`);
  }

  // ---- A-3: MCM 2026 event ----
  // The seed window ended 2026-09-30; flip it ACTIVE on both sides and
  // restore it at the end (same pattern as the jeongseok gate flip).
  await setAuthStub(ALICE);
  await compare('mcm get ENDED', `select public.get_my_mcm_2026_event_v1() as result`, `select public.get_my_mcm_2026_event_v1(${T4(ALICE)}) as result`);
  // Expected difference #9 (SERVER_ONLY): with the role stub at its
  // default 'authenticated', the original refuses advance; Tier 4 (no
  // service_role JWT, Worker is the server caller) proceeds. This check
  // must run BEFORE setAuthRole('service_role') below.
  await setAuthStub(ALICE);
  {
    const advO = await callOrig(orig, `select public.advance_mcm_2026_event_v1('${ALICE}'::uuid, 'status') as result`);
    const advT = await callTier4(`select public.advance_mcm_2026_event_v1(${T4(ALICE)}, 'status') as result`);
    check(!advO.ok && advO.code === 'SERVER_ONLY' && advT.ok && advT.value.progress.stage === 'NOT_STARTED', 'mcm advance authenticated role (expected diff: orig SERVER_ONLY, tier4 returns state)', `orig=${advO.code} tier4=${JSON.stringify(scrubWrite(advT.value))}`);
  }
  // The original checks the role gate BEFORE the window, so the ENDED
  // checks below need the role stub at 'service_role'.
  await setAuthRole('service_role');
  await setAuthStub(BOB);
  await compareErr('mcm advance while ENDED', `select public.advance_mcm_2026_event_v1('${BOB}'::uuid, 'start') as result`, `select public.advance_mcm_2026_event_v1(${T4(BOB)}, 'start') as result`, 'EVENT_NOT_ACTIVE');
  await compareErr('mcm landlord start while ENDED', `select public.start_mcm_landlord_run_v1() as result`, `select public.start_mcm_landlord_run_v1(${T4(BOB)}) as result`, 'EVENT_NOT_ACTIVE');
  for (const db of [orig, owner]) {
    await db([`update private.world_events set starts_at = now() - interval '1 hour', ends_at = now() + interval '1 hour' where event_id = 'event.mcm_2026'`]);
  }
  await compare('mcm get ACTIVE', `select public.get_my_mcm_2026_event_v1() as result`, `select public.get_my_mcm_2026_event_v1(${T4(ALICE)}) as result`);
  // Expected difference #10 (guest-open): noprofile mcm get.
  await setAuthStub(NOPROFILE);
  {
    const mNoO = await callOrig(orig, `select public.get_my_mcm_2026_event_v1() as result`);
    const mNoT = await callTier4(`select public.get_my_mcm_2026_event_v1(${T4(NOPROFILE)}) as result`);
    check(!mNoO.ok && mNoO.code === 'ACCOUNT_UNAVAILABLE' && mNoT.ok && mNoT.value.progress.stage === 'NOT_STARTED', 'mcm get noprofile (expected diff: orig ACCOUNT_UNAVAILABLE, tier4 NOT_STARTED)', `orig=${mNoO.code}`);
  }
  await setAuthStub(ALICE);
  await compareErr('mcm advance bad action', `select public.advance_mcm_2026_event_v1('${ALICE}'::uuid, 'bogus') as result`, `select public.advance_mcm_2026_event_v1(${T4(ALICE)}, 'bogus') as result`, 'INVALID_EVENT_ACTION');
  await compareErr('mcm claim main before complete', `select public.claim_my_mcm_2026_main_reward_v1() as result`, `select public.claim_my_mcm_2026_main_reward_v1(${T4(ALICE)}) as result`, 'CLAIM_NOT_ELIGIBLE');
  await compareErr('mcm claim landlord before first clear', `select public.claim_my_mcm_landlord_first_clear_reward_v1() as result`, `select public.claim_my_mcm_landlord_first_clear_reward_v1(${T4(ALICE)}) as result`, 'CLAIM_NOT_ELIGIBLE');
  await compare('mcm investigate before start', `select public.advance_mcm_2026_event_v1('${ALICE}'::uuid, 'investigate_staggering') as result`, `select public.advance_mcm_2026_event_v1(${T4(ALICE)}, 'investigate_staggering') as result`);
  await compare('mcm advance status', `select public.advance_mcm_2026_event_v1('${ALICE}'::uuid, 'status') as result`, `select public.advance_mcm_2026_event_v1(${T4(ALICE)}, 'status') as result`);
  await compare('mcm advance start', `select public.advance_mcm_2026_event_v1('${ALICE}'::uuid, 'start') as result`, `select public.advance_mcm_2026_event_v1(${T4(ALICE)}, 'start') as result`);
  await compare('mcm advance start replay', `select public.advance_mcm_2026_event_v1('${ALICE}'::uuid, 'start') as result`, `select public.advance_mcm_2026_event_v1(${T4(ALICE)}, 'start') as result`);
  await compare('mcm investigate staggering', `select public.advance_mcm_2026_event_v1('${ALICE}'::uuid, 'investigate_staggering') as result`, `select public.advance_mcm_2026_event_v1(${T4(ALICE)}, 'investigate_staggering') as result`);
  await compare('mcm investigate dancing', `select public.advance_mcm_2026_event_v1('${ALICE}'::uuid, 'investigate_dancing') as result`, `select public.advance_mcm_2026_event_v1(${T4(ALICE)}, 'investigate_dancing') as result`);
  await compare('mcm investigate hungry', `select public.advance_mcm_2026_event_v1('${ALICE}'::uuid, 'investigate_hungry') as result`, `select public.advance_mcm_2026_event_v1(${T4(ALICE)}, 'investigate_hungry') as result`);
  const mRunO = await callOrig(orig, `select public.start_mcm_landlord_run_v1() as result`);
  const mRunT = await callTier4(`select public.start_mcm_landlord_run_v1(${T4(ALICE)}) as result`);
  check(mRunO.ok && mRunT.ok && eq(scrubWrite(mRunO.value), scrubWrite(mRunT.value)), 'mcm landlord start', `orig=${JSON.stringify(scrubWrite(mRunO.value))} tier4=${JSON.stringify(scrubWrite(mRunT.value))}`);
  compared++;
  const mRunO2 = await callOrig(orig, `select public.start_mcm_landlord_run_v1() as result`);
  const mRunT2 = await callTier4(`select public.start_mcm_landlord_run_v1(${T4(ALICE)}) as result`);
  check(mRunO2.ok && mRunT2.ok && mRunO2.value.resumed === true && mRunT2.value.resumed === true && mRunO2.value.runId === mRunO.value.runId && mRunT2.value.runId === mRunT.value.runId, 'mcm landlord start again resumes same run');
  compared++;
  const survO = await orig([`select survivor_actor_id from private.world_landlord_runs where run_id = '${mRunO.value.runId}'::uuid`]);
  const survT = await owner([`select survivor_actor_id from private.world_landlord_runs where run_id = '${mRunT.value.runId}'::uuid`]);
  const wrongO = survO[0].survivor_actor_id === 'ZUE-MG-001' ? 'ZUE-MG-002' : 'ZUE-MG-001';
  const wrongT = survT[0].survivor_actor_id === 'ZUE-MG-001' ? 'ZUE-MG-002' : 'ZUE-MG-001';
  await compareErr('mcm landlord bad actor', `select public.submit_mcm_landlord_choice_v1('${mRunO.value.runId}'::uuid, 'ZUE-MG-999') as result`, `select public.submit_mcm_landlord_choice_v1(${T4(ALICE)}, '${mRunT.value.runId}'::uuid, 'ZUE-MG-999') as result`, 'INVALID_ACTOR');
  await setAuthStub(BOB);
  await compareErr('mcm landlord other account run', `select public.submit_mcm_landlord_choice_v1('${mRunO.value.runId}'::uuid, '${survO[0].survivor_actor_id}') as result`, `select public.submit_mcm_landlord_choice_v1(${T4(BOB)}, '${mRunT.value.runId}'::uuid, '${survT[0].survivor_actor_id}') as result`, 'RUN_NOT_FOUND');
  await setAuthStub(ALICE);
  await compare('mcm landlord wrong choice', `select public.submit_mcm_landlord_choice_v1('${mRunO.value.runId}'::uuid, '${wrongO}') as result`, `select public.submit_mcm_landlord_choice_v1(${T4(ALICE)}, '${mRunT.value.runId}'::uuid, '${wrongT}') as result`);
  await compare('mcm landlord correct choice', `select public.submit_mcm_landlord_choice_v1('${mRunO.value.runId}'::uuid, '${survO[0].survivor_actor_id}') as result`, `select public.submit_mcm_landlord_choice_v1(${T4(ALICE)}, '${mRunT.value.runId}'::uuid, '${survT[0].survivor_actor_id}') as result`);
  await compare('mcm landlord resubmit', `select public.submit_mcm_landlord_choice_v1('${mRunO.value.runId}'::uuid, '${survO[0].survivor_actor_id}') as result`, `select public.submit_mcm_landlord_choice_v1(${T4(ALICE)}, '${mRunT.value.runId}'::uuid, '${survT[0].survivor_actor_id}') as result`);
  await compare('mcm get COMPLETED', `select public.get_my_mcm_2026_event_v1() as result`, `select public.get_my_mcm_2026_event_v1(${T4(ALICE)}) as result`);
  await compare('mcm claim landlord', `select public.claim_my_mcm_landlord_first_clear_reward_v1() as result`, `select public.claim_my_mcm_landlord_first_clear_reward_v1(${T4(ALICE)}) as result`);
  await compare('mcm claim landlord replay', `select public.claim_my_mcm_landlord_first_clear_reward_v1() as result`, `select public.claim_my_mcm_landlord_first_clear_reward_v1(${T4(ALICE)}) as result`);
  await compare('mcm claim main', `select public.claim_my_mcm_2026_main_reward_v1() as result`, `select public.claim_my_mcm_2026_main_reward_v1(${T4(ALICE)}) as result`);
  await compare('mcm claim main replay', `select public.claim_my_mcm_2026_main_reward_v1() as result`, `select public.claim_my_mcm_2026_main_reward_v1(${T4(ALICE)}) as result`);
  await compare('wallet alice after mcm (100+80=180)', `select public.get_my_world_wallet_v1() as result`, `select public.get_my_world_wallet_v1(${T4(ALICE)}) as result`);
  await compare('inventory alice after mcm rewards', `select public.get_my_world_inventory_v1() as result`, `select public.get_my_world_inventory_v1(${T4(ALICE)}) as result`);
  for (const db of [orig, owner]) {
    await db([`update private.world_events set starts_at = '2026-09-29T15:00:00Z', ends_at = '2026-09-30T16:00:00Z' where event_id = 'event.mcm_2026'`]);
  }
  await compare('mcm get ENDED after restore', `select public.get_my_mcm_2026_event_v1() as result`, `select public.get_my_mcm_2026_event_v1(${T4(ALICE)}) as result`);
  // ---- BCD: profile creation, mail fallback, online polling ----
  // The origin has no profile-create RPC (direct INSERT) and no mail
  // request RPC (claim_inha_mail_badge takes two auth user ids), so those
  // compare end-states instead of call results. Touch/count compare
  // directly; their expected differences are #13/#14/#15 above.
  const VIS = 'e3000000-0000-4000-8000-000000000006';
  const STALE_SESS = 'e3000000-0000-4000-8000-000000000008';
  const W2 = 'e4000000-0000-4000-8000-000000000001';
  const stripSigned = (v) => {
    if (!v || typeof v !== 'object') return v;
    const { signedIn, guests, asOf, ...rest } = v;
    return rest;
  };
  await setAuthStub(ALICE);
  // Touch the same sequence on both sides.
  {
    const tO1 = await callOrig(orig, `select public.touch_world_online_session_v2('${ALICE}'::uuid, '${VIS}'::uuid, 'AREA_MAIN_GATE', 'campus')`);
    const tT1 = await callTier4(`select public.touch_world_online_session_v2(${T4(ALICE)}, '${VIS}'::uuid, 'AREA_MAIN_GATE', 'campus')`);
    check(tO1.ok && tT1.ok, 'bcd touch alice first', `orig=${tO1.code ?? 'ok'} tier4=${tT1.code ?? 'ok'}`);
    compared++;
    // Expected difference #13: the original has no touch rate limit, so
    // the immediate re-touch succeeds there and 429s on Tier 4.
    const tO2 = await callOrig(orig, `select public.touch_world_online_session_v2('${ALICE}'::uuid, null, 'AREA_MAIN_GATE', 'campus')`);
    const tT2 = await callTier4(`select public.touch_world_online_session_v2(${T4(ALICE)}, null, 'AREA_MAIN_GATE', 'campus')`);
    check(tO2.ok && !tT2.ok && tT2.code === 'RATE_LIMITED', 'bcd touch immediate re-touch (expected diff: orig ok, tier4 RATE_LIMITED)', `orig=${tO2.code ?? 'ok'} tier4=${tT2.code}`);
    compared++;
    await owner([`update public.world_online_sessions set last_seen_at = now() - interval '20 seconds' where session_id = '${ALICE}'::uuid`]);
    const tT3 = await callTier4(`select public.touch_world_online_session_v2(${T4(ALICE)}, null, 'AREA_MAIN_GATE', 'campus')`);
    check(tT3.ok, 'bcd touch tier4 after ageing succeeds', `tier4=${tT3.code ?? 'ok'}`);
    compared++;
    const rowO = (await orig([`select session_id::text, user_id::text, visitor_id::text, place_zone_id, space from public.world_online_sessions where session_id = '${ALICE}'::uuid`]))[0];
    const rowT = (await owner([`select session_id::text, user_id::text, visitor_id::text, place_zone_id, space from public.world_online_sessions where session_id = '${ALICE}'::uuid`]))[0];
    check(rowO.visitor_id === VIS && rowT.visitor_id === VIS && rowO.place_zone_id === rowT.place_zone_id && rowO.space === rowT.space,
      'bcd touch rows match except user_id', `orig=${JSON.stringify(rowO)} tier4=${JSON.stringify(rowT)}`);
    compared++;
    check(rowO.user_id === ALICE && rowT.user_id === null, 'bcd touch user_id (expected diff #13: orig auth.uid, tier4 NULL)', `orig=${rowO.user_id} tier4=${rowT.user_id}`);
    compared++;
  }
  await setAuthStub(BOB);
  {
    const tO = await callOrig(orig, `select public.touch_world_online_session_v2('${BOB}'::uuid, null, null, 'lobby')`);
    const tT = await callTier4(`select public.touch_world_online_session_v2(${T4(BOB)}, null, null, 'lobby')`);
    check(tO.ok && tT.ok, 'bcd touch bob lobby', `orig=${tO.code ?? 'ok'} tier4=${tT.code ?? 'ok'}`);
    compared++;
    const cO = await callOrig(orig, `select public.get_world_online_count_v1() as result`);
    const cT = await callTier4(`select public.get_world_online_count_v1() as result`);
    check(cO.ok && cT.ok && eq(stripSigned(scrubWrite(cO.value)), stripSigned(scrubWrite(cT.value))), 'bcd count matches except signedIn/guests',
      `orig=${JSON.stringify(scrubWrite(cO.value))} tier4=${JSON.stringify(scrubWrite(cT.value))}`);
    compared++;
    check(cO.value.online === 2 && cO.value.signedIn === 2 && cO.value.guests === 0 && cT.value.online === 2 && cT.value.signedIn === 0 && cT.value.guests === 2,
      'bcd count signedIn flip (expected diff #13)', `orig=${JSON.stringify(cO.value)} tier4=${JSON.stringify(cT.value)}`);
    compared++;
    // A stale (80 s old) row must not count on either side.
    for (const db of [orig, owner]) {
      await db([`insert into public.world_online_sessions (session_id, user_id, place_zone_id, space, started_at, last_seen_at) values ('${STALE_SESS}'::uuid, null, 'AREA_MAIN_GATE', 'campus', now() - interval '80 seconds', now() - interval '80 seconds')`]);
    }
    const cO2 = await callOrig(orig, `select public.get_world_online_count_v1() as result`);
    const cT2 = await callTier4(`select public.get_world_online_count_v1() as result`);
    check(cO2.ok && cT2.ok && cO2.value.online === 2 && cT2.value.online === 2, 'bcd count ignores stale row', `orig=${cO2.value?.online} tier4=${cT2.value?.online}`);
    compared++;
  }
  await compareErr('bcd touch bad zone', `select public.touch_world_online_session_v2('${ALICE}'::uuid, null, 'MAIN_HALL', 'campus')`, `select public.touch_world_online_session_v2(${T4(ALICE)}, null, 'MAIN_HALL', 'campus')`, 'INVALID_PLACE_ZONE');
  await compareErr('bcd touch bad space', `select public.touch_world_online_session_v2('${ALICE}'::uuid, null, null, 'moon')`, `select public.touch_world_online_session_v2(${T4(ALICE)}, null, null, 'moon')`, 'INVALID_SPACE');
  await compareErr('bcd touch null user', `select public.touch_world_online_session_v2(null, null, null, 'campus')`, `select public.touch_world_online_session_v2(null, null, null, 'campus')`, 'SESSION_ID_REQUIRED');
  // --- profile creation: origin direct INSERT vs Tier 4 RPC, same end state.
  await orig([`insert into auth.users (id, email, email_confirmed_at, is_anonymous, created_at) values ('${STRANGER}'::uuid, 'stranger@inha.edu', '2026-11-04T00:00:00Z', false, '2026-11-01T00:00:00Z'), ('${NOPROFILE}'::uuid, 'noprofile@inha.edu', '2026-11-04T00:00:00Z', false, '2026-11-01T00:00:00Z'), ('${W2}'::uuid, 'w2@inha.edu', '2026-11-04T00:00:00Z', false, '2026-11-01T00:00:00Z') on conflict (id) do nothing`]);
  await owner([`insert into public.sessions (id, nickname) values ('${STRANGER}', 'stranger'), ('${W2}', 'w2') on conflict (id) do nothing`]);
  {
    const insO = await callOrig(orig, `insert into public.profiles (user_id, nickname, department_id, title, avatar_key) values ('${STRANGER}'::uuid, 'paritynew', 10, null, 'scholar') returning user_id`);
    const creT = await callTier4(`select public.create_my_world_profile_v1(${T4(STRANGER)}, 'paritynew', 10, 'scholar', null) as result`);
    check(insO.ok && creT.ok && creT.value.created === true, 'bcd profile create stranger', `orig=${insO.code ?? 'ok'} tier4=${JSON.stringify(scrubWrite(creT.value))}`);
    compared++;
    const pO = (await orig([`select nickname, department_id, title, avatar_key, is_banned from public.profiles where user_id = '${STRANGER}'::uuid`]))[0];
    const pT = (await owner([`select nickname, department_id, title, avatar_key, is_banned from public.profiles where user_id = '${STRANGER}'::uuid`]))[0];
    check(eq(pO, pT), 'bcd profile end state matches origin direct insert', `orig=${JSON.stringify(pO)} tier4=${JSON.stringify(pT)}`);
    compared++;
    const reT = await callTier4(`select public.create_my_world_profile_v1(${T4(STRANGER)}, 'othername', 1, 'star', null) as result`);
    check(reT.ok && reT.value.created === false && reT.value.nickname === 'paritynew' && reT.value.avatarKey === 'scholar', 'bcd profile recreate returns existing', JSON.stringify(scrubWrite(reT.value)));
    compared++;
    // Expected difference #14: duplicate nicknames insert fine on the
    // origin (no UNIQUE) and refuse on Tier 4.
    const dupO = await callOrig(orig, `insert into public.profiles (user_id, nickname, department_id, title, avatar_key) values ('${NOPROFILE}'::uuid, 'tier4alice', 1, null, 'classic') returning user_id`);
    const dupT = await callTier4(`select public.create_my_world_profile_v1(${T4(NOPROFILE)}, 'tier4alice', 1, 'classic', null) as result`);
    check(dupO.ok && !dupT.ok && dupT.code === 'NICKNAME_TAKEN', 'bcd profile duplicate (expected diff #14: orig inserts, tier4 NICKNAME_TAKEN)', `orig=${dupO.code ?? 'ok'} tier4=${dupT.code}`);
    compared++;
    // Expected difference #15: banned nicknames insert fine on the
    // origin (no filter) and refuse on Tier 4.
    const banO = await callOrig(orig, `insert into public.profiles (user_id, nickname, department_id, title, avatar_key) values ('${W2}'::uuid, '씨발왕', 1, null, 'classic') returning user_id`);
    const banT = await callTier4(`select public.create_my_world_profile_v1(${T4(W2)}, '씨발왕', 1, 'classic', null) as result`);
    check(banO.ok && !banT.ok && banT.code === 'INVALID_NICKNAME', 'bcd profile banned word (expected diff #15: orig inserts, tier4 INVALID_NICKNAME)', `orig=${banO.code ?? 'ok'} tier4=${banT.code}`);
    compared++;
    const banReT = await callTier4(`select public.create_my_world_profile_v1(${T4(BANNED)}, 'newname', 1, 'classic', null) as result`);
    check(!banReT.ok && banReT.code === 'PROFILE_NOT_FOUND', 'bcd banned profile recreate concealed (tier4-only)', `tier4=${banReT.code}`);
    compared++;
  }
  // --- mail: origin claim_inha_mail_badge vs Tier 4 request + admin claim.
  {
    const reqT = await callTier4(`select public.request_world_mail_verification_v1(${T4(DAVE)}, 'carol@inha.edu') as result`);
    check(reqT.ok && reqT.value.status === 'PENDING' && reqT.value.duplicate === false, 'bcd mail request dave', JSON.stringify(scrubWrite(reqT.value)));
    compared++;
    const badReqT = await callTier4(`select public.request_world_mail_verification_v1(${T4(DAVE)}, 'dave@gmail.com') as result`);
    check(!badReqT.ok && badReqT.code === 'INVALID_EMAIL', 'bcd mail request bad domain refused', `tier4=${badReqT.code}`);
    compared++;
    const dupReqT = await callTier4(`select public.request_world_mail_verification_v1(${T4(DAVE)}, 'carol@inha.edu') as result`);
    check(dupReqT.ok && dupReqT.value.duplicate === true && dupReqT.value.requestId === reqT.value.requestId, 'bcd mail request duplicate returns same id', JSON.stringify(scrubWrite(dupReqT.value)));
    compared++;
    const claimO = await callOrig(orig, `select public.claim_inha_mail_badge('${DAVE}'::uuid, '${CAROL}'::uuid) as result`);
    const claimT = await callTier4(`select public.admin_claim_world_mail_verification_v1('${reqT.value.requestId}'::uuid) as result`);
    check(claimO.ok && claimO.value === true && claimT.ok && claimT.value.verified === true && claimT.value.achievementGranted === true,
      'bcd mail claim both verify', `orig=${JSON.stringify(claimO.value)} tier4=${JSON.stringify(scrubWrite(claimT.value))}`);
    compared++;
    const bO = (await orig([`select user_id::text, email from public.inha_mail_badges where user_id = '${DAVE}'::uuid`]))[0];
    const bT = (await owner([`select user_id::text, email from public.inha_mail_badges where user_id = '${DAVE}'::uuid`]))[0];
    check(eq(bO, bT) && bT.email === 'carol@inha.edu', 'bcd mail badge end state matches', `orig=${JSON.stringify(bO)} tier4=${JSON.stringify(bT)}`);
    compared++;
    const aO = (await orig([`select count(*)::int as n from public.user_achievements where user_id = '${DAVE}'::uuid and achievement_key = 'inha_verified_v1'`]))[0].n;
    const aT = (await owner([`select count(*)::int as n from public.user_achievements where user_id = '${DAVE}'::uuid and achievement_key = 'inha_verified_v1'`]))[0].n;
    check(aO === 1 && aT === 1, 'bcd mail achievement granted both sides', `orig=${aO} tier4=${aT}`);
    compared++;
    const claimT2 = await callTier4(`select public.admin_claim_world_mail_verification_v1('${reqT.value.requestId}'::uuid) as result`);
    check(!claimT2.ok && claimT2.code === 'MAIL_REQUEST_NOT_FOUND', 'bcd mail claim twice refused', `tier4=${claimT2.code}`);
    compared++;
  }
  // BCD section cleanup (the shared finally-block cleanup does not know
  // these rows): online rows on both sides, Tier 4 mail requests, and the
  // W2 fixture user on both sides.
  for (const db of [orig, owner]) {
    await db([`delete from public.world_online_sessions where session_id in ('${ALICE}'::uuid, '${BOB}'::uuid, '${STALE_SESS}'::uuid)`]).catch(() => {});
  }
  await owner([`delete from private.world_mail_verify_requests where user_id = '${DAVE}'::uuid`]).catch(() => {});
  await owner([`delete from public.sessions where id = '${W2}'`]).catch(() => {});
  await orig([`delete from auth.users where id = '${W2}'::uuid`]).catch(() => {});
  await setAuthRole('authenticated');
} catch (e) {
  console.log('PARITY FLOW EXCEPTION:', e?.stack ?? e);
  fail++;
  failures.push('flow exception: ' + (e?.message ?? String(e)));
} finally {
  await restoreAuthStub().catch(() => {});
  await setAuthRole('authenticated').catch(() => {});
  // Restore the MCM window on BOTH branches in case the A-3 section
  // failed after flipping it ACTIVE.
  await orig([`update private.world_events set starts_at = '2026-09-29T15:00:00Z', ends_at = '2026-09-30T16:00:00Z' where event_id = 'event.mcm_2026'`]).catch(() => {});
  await owner([`update private.world_events set starts_at = '2026-09-29T15:00:00Z', ends_at = '2026-09-30T16:00:00Z' where event_id = 'event.mcm_2026'`]).catch(() => {});
  // Revert seed flags on BOTH branches in case a mid-run failure
  // skipped the in-flow reverts.
  await orig([`update private.world_jeongseok_gate_policy set status = 'COMING_SOON' where singleton`]).catch(() => {});
  await orig([`update private.world_jeongseok_pass_catalog set status = 'COMING_SOON' where pass_type = 'jeongseok.visitor.day'`]).catch(() => {});
  await orig([`update private.world_recipe_catalog set status = 'COMING_SOON' where recipe_id = 'recipe.carp_grill'`]).catch(() => {});
  await owner([`update private.world_jeongseok_gate_policy set status = 'COMING_SOON' where singleton`]).catch(() => {});
  await owner([`update private.world_jeongseok_pass_catalog set status = 'COMING_SOON' where pass_type = 'jeongseok.visitor.day'`]).catch(() => {});
  await owner([`update private.world_recipe_catalog set status = 'COMING_SOON' where recipe_id = 'recipe.carp_grill'`]).catch(() => {});
  await cleanupWorld(owner, true).catch((e) => { console.log('cleanup owner failed:', e.message); });
  await cleanupWorld(orig, false).catch((e) => { console.log('cleanup orig failed:', e.message); });
  const leftoverOwner = await owner([`select (select count(*) from public.sessions where id = any(array['${USERS.join("','")}'])) + (select count(*) from public.world_player_rooms where owner_user_id = any(array['${USERS.join("','")}']::uuid[])) + (select count(*) from private.world_purchase_transactions where user_id = any(array['${USERS.join("','")}']::uuid[])) as leftover`]).catch(() => [{ leftover: '?' }]);
  const leftoverOrig = await orig([`select (select count(*) from auth.users where id = any(array['${USERS.join("','")}']::uuid[])) + (select count(*) from public.world_player_rooms where owner_user_id = any(array['${USERS.join("','")}']::uuid[])) as leftover`]).catch(() => [{ leftover: '?' }]);
  console.log(`parity: pass=${pass} fail=${fail} compared=${compared} leftoverOwner=${leftoverOwner[0].leftover} leftoverOrig=${leftoverOrig[0].leftover}`);
  if (failures.length) console.log('failures:\n- ' + failures.join('\n- '));
  process.exit(fail > 0 ? 1 : 0);
}
