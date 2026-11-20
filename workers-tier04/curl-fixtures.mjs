// Curl-test fixtures on the isolated test branch. Deletes after use.
// Run: node curl-fixtures.mjs setup | teardown (TEST_OWNER_URL env).
// Lookups for the curl script (read-only): quiz-answer <questionId> prints the
// correct answer index; landlord-survivor <runId> prints the survivor actor.
// mcm-advance <userId> drives the server-only advance RPC (start + 3
// investigates) and prints the resulting stage.
import { neon } from '@neondatabase/serverless';
const owner = neon(process.env.TEST_OWNER_URL);
const A = 'd1000000-0000-4000-8000-000000000001'; // curl-alice (profile)
const B = 'd2000000-0000-4000-8000-000000000002'; // curl-bob (profile)
const N = 'd4000000-0000-4000-8000-000000000004'; // curl-noprofile (session only)
const X = 'd3000000-0000-4000-8000-000000000003'; // curl-banned (banned profile)
const D = 'd5000000-0000-4000-8000-000000000005'; // curl-dave (profile, friend-cycle target)
const E = 'e6000000-0000-4000-8000-000000000006'; // BCD profile-new (session only)
const F = 'e7000000-0000-4000-8000-000000000007'; // BCD mail-new (session only)
const G = 'e8000000-0000-4000-8000-000000000008'; // BCD online + nickname false-positive (session only)
const H = 'e9000000-0000-4000-8000-000000000009'; // BCD duplicate/banned probes + claim-without-profile (session only)
const USERS = [A, B, N, X, D, E, F, G, H];
const mode = process.argv[2];
if (mode === 'setup') {
  await owner`insert into public.sessions (id, nickname) values (${A}, 'curlalice'), (${B}, 'curlbob'), (${N}, 'curlnoprofile'), (${X}, 'curlbanned'), (${D}, 'curldave'), (${E}, 'curlprofile'), (${F}, 'curlmail'), (${G}, 'curlonline'), (${H}, 'curlprobe') on conflict (id) do nothing`;
  await owner`insert into public.profiles (user_id, nickname, department_id, title, is_banned, created_at) values (${A}, 'curlalice', 10, '주치의', false, '2026-11-01T00:00:00Z'), (${B}, 'curlbob', 1, null, false, '2026-11-01T00:00:00Z'), (${X}, 'curlbanned', 1, null, true, '2026-11-01T00:00:00Z'), (${D}, 'curldave', 1, null, false, '2026-11-01T00:00:00Z') on conflict (user_id) do nothing`;
  await owner`insert into private.world_wallets (user_id, currency_id, balance) values (${A}, 'currency.induck_coin', 500), (${B}, 'currency.induck_coin', 500) on conflict (user_id, currency_id) do nothing`;
  await owner`insert into private.world_item_grants (grant_id, user_id, item_id, result, quantity_requested, quantity_before, quantity_granted, quantity_after, source_type, source_ref) values ('e1000000-0000-4000-8000-000000000001', ${A}, 'head.induck_cap', 'GRANTED', 1, 0, 1, 1, 'SYSTEM', 'curl'), ('e2000000-0000-4000-8000-000000000002', ${A}, 'furniture.induck_chair', 'GRANTED', 1, 0, 1, 1, 'SYSTEM', 'curl'), ('e3000000-0000-4000-8000-000000000003', ${A}, 'material.fish_carp', 'GRANTED', 3, 0, 3, 3, 'SYSTEM', 'curl'), ('e4000000-0000-4000-8000-000000000004', ${A}, 'furniture.cooking_station', 'GRANTED', 1, 0, 1, 1, 'SYSTEM', 'curl') on conflict (grant_id) do nothing`;
  await owner`insert into private.world_player_items (user_id, item_id, quantity, source_type, source_ref, grant_id, acquired_at, updated_at) values (${A}, 'head.induck_cap', 1, 'test', 'curl', 'e1000000-0000-4000-8000-000000000001', '2026-11-05T00:00:00Z', '2026-11-05T00:00:00Z'), (${A}, 'furniture.induck_chair', 1, 'test', 'curl', 'e2000000-0000-4000-8000-000000000002', '2026-11-05T00:00:00Z', '2026-11-05T00:00:00Z'), (${A}, 'material.fish_carp', 3, 'test', 'curl', 'e3000000-0000-4000-8000-000000000003', '2026-11-05T00:00:00Z', '2026-11-05T00:00:00Z'), (${A}, 'furniture.cooking_station', 1, 'test', 'curl', 'e4000000-0000-4000-8000-000000000004', '2026-11-05T00:00:00Z', '2026-11-05T00:00:00Z') on conflict do nothing`;
  await owner`insert into public.inha_mail_badges (user_id, email, verified_at) values (${A}, 'alice@inha.edu', '2026-11-04T00:00:00Z') on conflict (user_id) do nothing`;
  await owner`insert into private.world_player_progression (user_id, total_exp) values (${A}, 250) on conflict (user_id) do nothing`; // level 2: sneakers (lv 2) buyable
  await owner`insert into public.world_friendships (user_low, user_high, status, requested_by, accepted_at) values (${A}, ${B}, 'accepted', ${A}, now()) on conflict (user_low, user_high) do nothing`;
  // A-3: alice has life.fishing 300 XP (level 3, SP 2); the MCM window is
  // flipped ACTIVE (seed ended 2026-09-30); one expired accompany session
  // is present for the expiry path.
  await owner`insert into private.world_player_life_skills (user_id, skill_id, total_xp, version) values (${A}, 'life.fishing', 300, 1) on conflict (user_id, skill_id) do update set total_xp = 300`;
  await owner([`update private.world_events set starts_at = now() - interval '1 hour', ends_at = now() + interval '1 hour' where event_id = 'event.mcm_2026'`]);
  await owner`insert into public.world_accompany_sessions (id, inviter_id, invitee_id, place_zone_id, poi_id, state, created_at, expires_at) values ('f1000000-0000-4000-8000-000000000001'::uuid, ${A}::uuid, ${B}::uuid, 'AREA_MAIN_GATE', 'poi.main-gate', 'offered', now() - interval '2 minutes', now() - interval '1 minute') on conflict (id) do nothing`;
  console.log('curl fixtures setup done');
} else if (mode === 'teardown') {
  await owner([`update private.world_events set starts_at = '2026-09-29T15:00:00Z', ends_at = '2026-09-30T16:00:00Z' where event_id = 'event.mcm_2026'`]);
  await owner`delete from public.sessions where id = any(${USERS}::text[])`;
  await owner`delete from private.world_room_knocks where visitor_user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_room_owner_presence where room_id in (select id from public.world_player_rooms where owner_user_id = any(${USERS}::uuid[]))`;
  await owner`delete from private.world_room_layouts where room_id in (select id from public.world_player_rooms where owner_user_id = any(${USERS}::uuid[]))`;
  await owner`delete from public.world_player_rooms where owner_user_id = any(${USERS}::uuid[])`;
  await owner`delete from public.world_friendships where user_low = any(${USERS}::uuid[]) or user_high = any(${USERS}::uuid[])`;
  await owner`delete from private.world_attendance_days where user_id = any(${USERS}::uuid[])`;
  await owner`delete from public.world_guestbook_entries where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_guestbook_post_log where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_jeongseok_pass_purchases where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_jeongseok_pass_entitlements where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_recipe_receipts where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_purchase_transactions where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_appearance_transactions where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_inventory_mutation_entries where mutation_id in (select mutation_id from private.world_inventory_mutations where user_id = any(${USERS}::uuid[]))`;
  await owner`delete from private.world_inventory_mutations where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_item_consumptions where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_currency_transactions where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_exp_transactions where user_id = any(${USERS}::uuid[])`;
  // A-3 cleanup (quiz runs reference reward transactions without ON DELETE
  // CASCADE, so quiz runs go before the reward deletes below; life nodes
  // reference the SP ledger, so nodes go before SP).
  await owner`delete from private.world_daily_quiz_answers where run_id in (select run_id from private.world_daily_quiz_runs where user_id = any(${USERS}::uuid[]))`;
  await owner`delete from private.world_daily_quiz_runs where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_player_life_nodes where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_life_sp_transactions where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_player_life_skills where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_life_tree_resets where user_id = any(${USERS}::uuid[])`;
  await owner`delete from public.world_user_reports where reporter_id = any(${USERS}::uuid[]) or target_id = any(${USERS}::uuid[])`;
  await owner`delete from public.world_user_blocks where blocker_id = any(${USERS}::uuid[]) or blocked_id = any(${USERS}::uuid[])`;
  await owner`delete from public.world_accompany_sessions where inviter_id = any(${USERS}::uuid[]) or invitee_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_biryong_progress_v1 where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_biryong_npc_relationship_events where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_player_biryong_npc_relationships where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_campus_npc_relationship_events where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_player_campus_npc_relationships where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_event_progress where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_landlord_first_clears where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_landlord_runs where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_mcm_reward_claims where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_reward_transaction_entries where reward_transaction_id in (select reward_transaction_id from private.world_reward_transactions where user_id = any(${USERS}::uuid[]))`;
  await owner`delete from private.world_reward_transactions where user_id = any(${USERS}::uuid[])`;
  await owner`delete from public.profiles where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_player_progression where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_wallets where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_player_items where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_item_grants where user_id = any(${USERS}::uuid[])`;
  await owner`delete from public.inha_mail_badges where user_id = any(${USERS}::uuid[])`;
  await owner`delete from private.world_mail_verify_requests where user_id = any(${USERS}::uuid[])`;
  await owner`delete from public.world_online_sessions where session_id = any(${USERS}::uuid[])`;
  await owner`delete from public.user_achievements where user_id = any(${USERS}::uuid[])`;
  const left = await owner([`select (select count(*) from public.sessions where id = any(array['${USERS.join("','")}'])) + (select count(*) from public.world_player_rooms where owner_user_id = any(array['${USERS.join("','")}']::uuid[])) + (select count(*) from private.world_purchase_transactions where user_id = any(array['${USERS.join("','")}']::uuid[])) + (select count(*) from private.world_daily_quiz_runs where user_id = any(array['${USERS.join("','")}']::uuid[])) + (select count(*) from private.world_event_progress where user_id = any(array['${USERS.join("','")}']::uuid[])) + (select count(*) from private.world_landlord_runs where user_id = any(array['${USERS.join("','")}']::uuid[])) + (select count(*) from public.world_accompany_sessions where inviter_id = any(array['${USERS.join("','")}']::uuid[]) or invitee_id = any(array['${USERS.join("','")}']::uuid[])) + (select count(*) from public.profiles where user_id = any(array['${USERS.join("','")}']::uuid[])) + (select count(*) from private.world_mail_verify_requests where user_id = any(array['${USERS.join("','")}']::uuid[])) + (select count(*) from public.world_online_sessions where session_id = any(array['${USERS.join("','")}']::uuid[])) as n`]);
  console.log('curl fixtures teardown done, leftover=' + left[0].n);
} else if (mode === 'quiz-answer') {
  // Prints the correct answer index (0..3) for a quiz question id.
  const rows = await owner`select correct_index from private.world_daily_quiz_questions where question_id = ${process.argv[3]}`;
  console.log(rows[0]?.correct_index ?? 'none');
} else if (mode === 'landlord-survivor') {
  // Prints the survivor actor id for a landlord run id.
  const rows = await owner`select survivor_actor_id from private.world_landlord_runs where run_id = ${process.argv[3]}::uuid`;
  console.log(rows[0]?.survivor_actor_id ?? 'none');
} else if (mode === 'mcm-advance') {
  // Drives the server-only advance RPC for a user (no HTTP endpoint exists
  // by design): start + investigate all three NPCs -> stage VENUE_UNLOCKED.
  // Prints the resulting stage. The main event only completes (stage 3)
  // once the landlord first clear exists too (try_complete on submit).
  const u = process.argv[3];
  await owner`select public.advance_mcm_2026_event_v1(${u}::uuid, 'start')`;
  for (const npc of ['staggering', 'dancing', 'hungry']) {
    await owner`select public.advance_mcm_2026_event_v1(${u}::uuid, ${'investigate_' + npc})`;
  }
  const rows = await owner`select public.get_my_mcm_2026_event_v1(${u}::uuid) as result`;
  console.log(rows[0]?.result?.progress?.stage ?? 'none');
} else {
  console.error('usage: node curl-fixtures.mjs setup|teardown');
  process.exit(2);
}
