-- Database-side equivalence oracle for schema.sql (Tier 4, A-3 state machines; superset of A-1/A-2).
-- Port of the pgTAP suites in aldol2678/inhagame to plain SQL,
-- scoped to the 65 Tier 4 RPCs (A-1 reads + A-2 writes + A-3 state machines) and their helpers.
--
-- Adapted, not copied:
--  * auth.users fixtures became public.sessions rows; the Supabase roles (anon,
--    authenticated, service_role) became the Worker role inha_world_tier4_app.
--  * "anonymous accounts are refused" assertions are gone (decision A): any
--    existing session is a full account for the world account gates
--    (guest-open decision, 2026-11-12). /api/world-profile keeps the profile
--    rule: a missing or banned profile raises PROFILE_NOT_FOUND (42501),
--    which the Worker maps to 409 PROFILE_REQUIRED (the rank rule).
--  * get_world_shop_capabilities_v1 now returns purchaseRpc
--    'purchase_world_shop_listing_v2' / catalogLayout 'split' (the A-1
--    SHOP_API_UNAVAILABLE expectation is gone — the purchase RPCs exist now).
--  * The write sections run AFTER every A-1 read assertion, because their
--    fixtures (bob wallet, extra items) would change the A-1 read results.
--  * Jeongseok gate + pass catalog and the carp recipe ship COMING_SOON in the
--    seeds (faithful to the origin: activation needs a separate rollout). The
--    oracle flips them ACTIVE for the positive-path tests and flips them back
--    inside the same transaction, so the committed state is unchanged.
--  * Knock rate-limit is tested by inserting 5 expired PENDING knocks (the
--    count is per room+visitor over the last 2 minutes, any status).
--  * get_my_profile 'joinedAt' now comes from the profiles row (was
--    auth.users.created_at); the fixture sets both to the same value.
--  * get_my_achievements' inha_verified insert drops the auth.users email
--    branch; only the inha_mail_badges row verifies. The fixture has both a
--    badges row and (in the parity test, not here) an email-only case.
--  * RLS assertions became table/column-privilege assertions.
--  * Not ported: the ops/analytics mirror triggers (Tier 3 precedent) and
--    every object no Tier 4 RPC reaches.
--
-- Run ONLY against a disposable database or an isolated Neon branch that has
-- schema.sql applied. The runner (run-oracle-tier4.mjs) executes the file via
-- the Neon HTTP driver in one transaction and cleans the fixtures up
-- afterwards. Exit code 0 and a final "N/N passed" line mean success.

-- A non-superuser owner (e.g. neondb_owner) may only SET ROLE to a role it is a
-- member of. Granted inside this transaction, so it is rolled back with it.
grant inha_world_tier4_writes_app to current_user;

create table public._t_results (n serial, ok boolean not null, name text not null, note text);
grant insert, select on public._t_results to public;
grant usage on sequence public._t_results_n_seq to public;

create function public._t_is(got anyelement, want anyelement, name text) returns void
language sql as $$
  insert into public._t_results(ok, name, note)
  values (got is not distinct from want, name, 'got ' || coalesce(got::text, 'NULL'));
$$;

-- passes when running `query` raises exactly `want_state` (and `want_message` when given)
create function public._t_throws(query text, want_state text, name text, want_message text default null) returns void
language plpgsql as $$
begin
  begin
    execute query;
  exception when others then
    insert into public._t_results(ok, name, note)
    values (sqlstate = want_state and (want_message is null or sqlerrm = want_message), name, sqlstate || ' ' || sqlerrm);
    return;
  end;
  insert into public._t_results(ok, name, note) values (false, name, 'no error');
end;
$$;

-- assertion calls print nothing; only the report at the end is shown
\o /dev/null

-- ---- fixtures: sessions (identity) and profiles ----
\set alice '''a1000000-0000-4000-8000-000000000001'''
\set bob '''a2000000-0000-4000-8000-000000000002'''
\set banned '''a3000000-0000-4000-8000-000000000003'''
\set noprofile '''a4000000-0000-4000-8000-000000000004'''
\set stranger '''a9000000-0000-4000-8000-000000000009'''
\set runid '''c1000000-0000-4000-8000-000000000001'''
\set grant1 '''b1000000-0000-4000-8000-000000000001'''
\set grant2 '''b2000000-0000-4000-8000-000000000002'''
\set grant3 '''b3000000-0000-4000-8000-000000000003'''
\set grant4 '''b4000000-0000-4000-8000-000000000004'''
insert into public.sessions (id, nickname) values
  (:alice, 'alice'), (:bob, 'bob'), (:banned, 'banned'), (:noprofile, 'noprofile');
insert into public.profiles (user_id, nickname, department_id, title, is_banned, created_at) values
  (:alice, 'tier4alice', 10, '주치의', false, '2026-11-01T00:00:00Z'),
  (:bob, 'tier4bob', 1, null, false, '2026-11-01T00:00:00Z'),
  (:banned, 'tier4banned', 1, null, true, '2026-11-01T00:00:00Z');
insert into private.world_wallets (user_id, currency_id, balance) values
  (:alice, 'currency.induck_coin', 500);
insert into private.world_item_grants (grant_id, user_id, item_id, result, quantity_requested, quantity_before, quantity_granted, quantity_after, source_type, source_ref) values
  (:grant1, :alice, 'memorabilia.campus_mug', 'GRANTED', 2, 0, 2, 2, 'SYSTEM', 'oracle'),
  (:grant2, :alice, 'badge.main_gate', 'GRANTED', 1, 0, 1, 1, 'SYSTEM', 'oracle'),
  (:grant3, :alice, 'head.induck_cap', 'GRANTED', 1, 0, 1, 1, 'SYSTEM', 'oracle'),
  (:grant4, :alice, 'top.induck_hoodie', 'GRANTED', 1, 0, 1, 1, 'SYSTEM', 'oracle');
insert into private.world_player_items (user_id, item_id, quantity, source_type, source_ref, grant_id, acquired_at) values
  (:alice, 'memorabilia.campus_mug', 2, 'test', 'oracle', :grant1, '2026-11-05T00:00:00Z'),
  (:alice, 'head.induck_cap', 1, 'test', 'oracle', :grant3, '2026-11-04T12:00:00Z'),
  (:alice, 'top.induck_hoodie', 1, 'test', 'oracle', :grant4, '2026-11-04T06:00:00Z'),
  (:alice, 'badge.main_gate', 1, 'test', 'oracle', :grant2, '2026-11-04T00:00:00Z');
insert into private.world_player_progression (user_id, total_exp) values (:alice, 250);
insert into private.world_player_appearance_loadout (user_id, slot, item_id) values
  (:alice, 'HEAD', 'head.induck_cap'),
  (:alice, 'TOP', 'top.induck_hoodie');
insert into private.world_staff_assignments (user_id, role, active) values
  (:alice, 'world_admin', true),
  (:bob, 'sound_gm', false);
insert into public.game_events (id, user_id, event_type, game_id, created_at) values
  (9000001, :alice, 'stage_clear', (select id from public.games where slug = 'inha-duck'), '2026-11-02T00:00:00Z');
insert into public.ranked_sessions (run_id, user_id, stage_key, nonce, started_at, expires_at, status, run_type, ruleset_version) values
  (:runid, :alice, 'secret', :runid, '2026-11-05T00:00:00Z', '2026-11-05T01:00:00Z', 'accepted', 'ranked', 'secret-2.0-r1');
insert into public.ranked_runs (id, run_id, user_id, stage_key, score, max_combo, duration_ms, validation_status, run_type) values
  (:runid, :runid, :alice, 'secret', 999, 10, 60000, 'accepted', 'ranked');
insert into public.player_bests (user_id, stage_key, best_score, best_combo, best_run_id, achieved_at) values
  (:alice, 'secret', 12345, 67, :runid, '2026-11-02T00:00:00Z');
insert into public.general_stage_bests (user_id, stage_id, best_score, best_combo, achieved_at) values
  (:alice, 1, 100, 5, '2026-11-03T00:00:00Z');
insert into public.inha_mail_badges (user_id, email, verified_at) values
  (:alice, 'alice@inha.edu', '2026-11-04T00:00:00Z');
insert into public.classic_event_badges (event_key, user_id, placement, badge_code, best_run_id, final_score, final_combo, final_achieved_at) values
  ('inha_duck_s1', :alice, 2, 'inha_duck_s1_silver', :runid, 999, 10, '2026-11-05T00:00:00Z');
insert into public.user_achievements (user_id, achievement_key, earned_at, evidence_source) values
  (:alice, 'classic_inha_duck_s1_rank_2_v1', '2026-11-05T00:00:00Z', 'classic_event_final_rank');
insert into public.user_game_progress (user_id, game_id, progress) values
  (:alice, (select id from public.games where slug = 'inha-duck-survival'), '{"stages": {"1": {"clear": true, "bestKills": 7}, "2": {"clear": false}}}');

-- =====================================================================
-- seeds + shape: the schema arrived whole
-- =====================================================================
select public._t_is((select count(*) from public.games), 4::bigint, 'seed games = 4');
select public._t_is((select count(*) from public.departments), 67::bigint, 'seed departments = 67');
select public._t_is((select count(*) from private.world_currencies), 1::bigint, 'seed currencies = 1');
select public._t_is((select count(*) from private.world_item_catalog), 42::bigint, 'seed item catalog = 42 (scratch count)');
select public._t_is((select count(*) from private.world_level_thresholds), 10::bigint, 'seed level thresholds = 10');
select public._t_is((select count(*) from private.world_shops), 5::bigint, 'seed shops = 5');
select public._t_is((select count(*) from private.world_shop_listings), 16::bigint, 'seed shop listings = 16 (scratch count: 13 + 2 dorm + 1 poster move)');
-- A-3 seeds
select public._t_is((select count(*) from private.world_daily_quiz_questions), 100::bigint, 'seed quiz questions = 100');
select public._t_is((select count(*) from private.world_daily_quiz_questions where status = 'ACTIVE' and category = 'major'), 74::bigint, 'seed quiz major ACTIVE = 74');
select public._t_is((select count(*) from private.world_life_skill_catalog), 11::bigint, 'seed life skills = 11');
select public._t_is((select count(*) from private.world_life_skill_catalog where status = 'ACTIVE'), 1::bigint, 'seed life skills ACTIVE = 1 (fishing only)');
select public._t_is((select count(*) from private.world_life_skill_tree_catalog), 18::bigint, 'seed life tree nodes = 18');
select public._t_is((select count(*) from private.world_life_skill_tree_catalog where skill_id = 'life.fishing' and status = 'ACTIVE'), 2::bigint, 'seed fishing ACTIVE nodes = 2');
select public._t_is((select count(*) from private.world_life_skill_thresholds), 20::bigint, 'seed life skill thresholds = 20');
select public._t_is((select count(*) from private.world_life_progression_thresholds), 1::bigint, 'seed life progression thresholds = 1');
select public._t_is((select count(*) from private.world_events where event_id = 'event.mcm_2026'), 1::bigint, 'seed mcm event = 1');
select public._t_is((select count(*) from private.world_biryong_npc_relationship_npc_catalog), 8::bigint, 'seed biryong npcs = 8');
select public._t_is((select count(*) from private.world_campus_npc_relationship_npc_catalog), 10::bigint, 'seed campus npcs = 10');
select public._t_is((select count(*) from private.world_reward_grants where reward_id = 'reward.daily.campus_quiz'), 2::bigint, 'seed quiz reward grants = 2');
select public._t_is((select count(*) from private.world_reward_grants where reward_id = 'reward.event.mcm_2026_main_clear'), 4::bigint, 'seed mcm main reward grants = 4');
select public._t_is((select count(*) from private.world_reward_grants where reward_id = 'reward.minigame.landlord_first_clear'), 2::bigint, 'seed landlord reward grants = 2');
select public._t_is((select count(*) from pg_namespace where nspname = 'auth'), 0::bigint, 'no auth schema in Tier 4');
select public._t_is((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('public','private') and p.proname not in ('_t_is', '_t_throws')), 191::bigint, 'functions = 191 (183 closure + tier4_require_session_v1 + 7 BCD: profile create, mail request/claim, online touch/count, nickname normalize/banned)');
select public._t_is((select count(*) from pg_tables where schemaname in ('public','private') and tablename <> '_t_results'), 88::bigint, 'tables = 88 (82 closure + sessions + guestbook + progress FK targets + 3 BCD: banned words, mail requests, online sessions)');
select public._t_is((select count(*) from pg_trigger where tgname = 'tier4_session_ref'), 52::bigint, 'session-ref triggers = 52 (50 A-3 + 2 BCD tables)');
select public._t_is((select count(*) from pg_trigger where not tgisinternal and tgname <> 'tier4_session_ref'), 31::bigint, 'kept data triggers = 31 (42 closure - 11 ops)');
select public._t_is((select count(*) from pg_roles where rolname in ('inha_world_tier4_writes_app','authenticated','anon','service_role')), 4::bigint, 'roles exist');
select public._t_is((select array_agg(p.proname order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('public','private') and not p.prosecdef and p.proname not in ('_t_is', '_t_throws')),
  array['is_inha_mail','world_appearance_slot_ok_v1','world_appearance_transactions_append_only_v1','world_attendance_today_v1','world_biryong_relationship_event_append_only_v1','world_biryong_relationship_projection_guard_v1','world_campus_npc_relationship_event_append_only_v1','world_campus_npc_relationship_projection_guard_v1','world_campus_npc_relationship_tier_v1','world_currency_transactions_append_only_v1','world_daily_quiz_major_count_v1','world_daily_quiz_reward_view_v1','world_daily_quiz_today_v1','world_event_state_v1','world_exp_result_v1','world_exp_transactions_append_only_v1','world_guestbook_normalize','world_inventory_consume_result_v1','world_inventory_grant_result_v1','world_inventory_item_json_v1','world_inventory_mutation_append_only_v1','world_inventory_normalize_plan_v1','world_item_grants_append_only_v1','world_jeongseok_pass_purchase_append_only_v1','world_level_thresholds_immutable_v1','world_level_thresholds_validate_insert_v1','world_life_nodes_append_only_v1','world_life_progression_threshold_immutable_v1','world_life_progression_threshold_validate_insert_v1','world_life_skill_threshold_immutable_v1','world_life_skill_threshold_validate_insert_v1','world_life_sp_append_only_v1','world_life_tree_edge_validate_v1','world_life_tree_node_guard_v1','world_life_tree_resets_append_only_v1','world_mcm_reward_claims_final_v1','world_profile_nickname_banned_v1','world_profile_normalize_nickname_v1','world_purchase_transactions_append_only_v1','world_recipe_receipt_append_only_v1','world_reward_final_rows_v1','world_wallet_result_v1']::name[],
  'invoker functions = 42 expected (40 A-3 + 2 BCD nickname helpers)');

-- grants: the Worker role can execute the 65 RPCs; PUBLIC cannot
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_my_world_inventory_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant inventory');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_my_world_wallet_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant wallet');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_my_world_progression_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant progression');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_my_world_appearance_loadout_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant loadout');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_world_shop_v1(uuid, text)'::regprocedure, 'EXECUTE'), true, 'grant shop');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_world_shop_capabilities_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant capabilities');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_world_staff_badges_v1(uuid, uuid[])'::regprocedure, 'EXECUTE'), true, 'grant staff badges');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_my_profile(uuid)'::regprocedure, 'EXECUTE'), true, 'grant profile');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_my_achievements(uuid)'::regprocedure, 'EXECUTE'), true, 'grant achievements');
-- A-3 grants (35): daily quiz / life skills / social / accompany / biryong / campus NPC / MCM
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_my_world_daily_quiz_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant quiz get');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.start_my_world_daily_quiz_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant quiz start');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.answer_my_world_daily_quiz_v1(uuid, uuid, text, smallint)'::regprocedure, 'EXECUTE'), true, 'grant quiz answer');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_my_world_life_skills_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant life skills');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_my_world_life_skill_tree_v1(uuid, text)'::regprocedure, 'EXECUTE'), true, 'grant life tree');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.unlock_my_world_life_node_v1(uuid, text, uuid)'::regprocedure, 'EXECUTE'), true, 'grant life unlock');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.reset_my_world_life_tree_v1(uuid, text, uuid)'::regprocedure, 'EXECUTE'), true, 'grant life reset');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_my_world_social(uuid)'::regprocedure, 'EXECUTE'), true, 'grant social');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_world_public_profile(uuid, uuid)'::regprocedure, 'EXECUTE'), true, 'grant public profile');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_world_relationship(uuid, uuid)'::regprocedure, 'EXECUTE'), true, 'grant relationship');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.send_world_friend_request(uuid, uuid)'::regprocedure, 'EXECUTE'), true, 'grant friend send');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.respond_world_friend_request(uuid, uuid, boolean)'::regprocedure, 'EXECUTE'), true, 'grant friend respond');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.cancel_world_friend_request(uuid, uuid)'::regprocedure, 'EXECUTE'), true, 'grant friend cancel');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.remove_world_friend(uuid, uuid)'::regprocedure, 'EXECUTE'), true, 'grant friend remove');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.report_world_user(uuid, uuid, text, text)'::regprocedure, 'EXECUTE'), true, 'grant report');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.block_world_user(uuid, uuid)'::regprocedure, 'EXECUTE'), true, 'grant block');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.unblock_world_user(uuid, uuid)'::regprocedure, 'EXECUTE'), true, 'grant unblock');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_my_world_accompany(uuid)'::regprocedure, 'EXECUTE'), true, 'grant accompany get');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.propose_world_accompany(uuid, uuid, text, text)'::regprocedure, 'EXECUTE'), true, 'grant accompany propose');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.respond_world_accompany(uuid, uuid, boolean)'::regprocedure, 'EXECUTE'), true, 'grant accompany respond');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.end_world_accompany(uuid, uuid)'::regprocedure, 'EXECUTE'), true, 'grant accompany end');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_my_biryong_progress_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant biryong progress get');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.merge_my_biryong_progress_v1(uuid, jsonb, boolean)'::regprocedure, 'EXECUTE'), true, 'grant biryong progress merge');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_my_biryong_npc_relationship_v1(uuid, text)'::regprocedure, 'EXECUTE'), true, 'grant biryong npc get');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_my_biryong_npc_relationships_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant biryong npc list');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.world_biryong_npc_relationship_advance_v1(uuid, text, smallint, text, text, text, text)'::regprocedure, 'EXECUTE'), true, 'grant biryong npc advance');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_my_world_campus_npc_relationship_v1(uuid, text)'::regprocedure, 'EXECUTE'), true, 'grant campus npc get');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_my_world_campus_npc_relationships_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant campus npc list');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.world_campus_npc_relationship_apply_v1(uuid, text, integer, text, text, integer, smallint, text, text, text)'::regprocedure, 'EXECUTE'), true, 'grant campus npc apply');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_my_mcm_2026_event_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant mcm get');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.advance_mcm_2026_event_v1(uuid, text)'::regprocedure, 'EXECUTE'), true, 'grant mcm advance');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.claim_my_mcm_2026_main_reward_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant mcm claim main');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.claim_my_mcm_landlord_first_clear_reward_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant mcm claim landlord');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.start_mcm_landlord_run_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant mcm landlord start');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.submit_mcm_landlord_choice_v1(uuid, uuid, text)'::regprocedure, 'EXECUTE'), true, 'grant mcm landlord choice');
select public._t_is((select proacl::text from pg_proc where oid = 'public.get_my_world_inventory_v1(uuid)'::regprocedure) like '%inha_world_tier4_writes_app=X/%', true, 'inventory acl names the Worker role');
select public._t_is((select (proacl::text like '{=X/%' or proacl::text like '%,=X/%') from pg_proc where oid = 'public.get_my_world_inventory_v1(uuid)'::regprocedure), false, 'inventory acl grants nothing to PUBLIC (PUBLIC entry would be =X/ right after { or ,)');
select public._t_is((select count(*) from information_schema.column_privileges where grantee = 'inha_world_tier4_writes_app'), 3::bigint, 'Worker role column grants = 3 (sessions.id, profiles.user_id/is_banned)');
select public._t_is((select count(*) from information_schema.table_privileges where grantee = 'inha_world_tier4_writes_app'), 0::bigint, 'Worker role has no table-wide grants');

-- =====================================================================
-- identity: sessions replace auth.users (row trigger, was: FK)
-- =====================================================================
select public._t_throws(format($$insert into public.profiles (user_id, nickname) values (%L, 'ghost')$$, :stranger),
  '23503', 'a profile needs an existing session (was: FK to auth.users)');
select public._t_throws(format($$insert into private.world_player_items (user_id, item_id, quantity, source_type, source_ref, grant_id) values (%L, 'badge.main_gate', 1, 'test', 'oracle', 'b3000000-0000-4000-8000-000000000003')$$, :stranger),
  '23503', 'world state needs an existing session');
select public._t_throws(format($$insert into private.world_wallets (user_id, currency_id, balance) values (%L, 'currency.induck_coin', 0)$$, :stranger),
  '23503', 'a wallet needs an existing session');
select public._t_throws(format($$insert into public.players (auth_user_id) values (%L)$$, :stranger),
  '23503', 'a player link needs an existing session (auth_user_id)');
select public._t_throws($$insert into private.world_level_thresholds (level, min_total_exp) values (1, 0)$$,
  '23514', 'level thresholds refuse a duplicate level (PROGRESSION_CONFIG_INVALID)', 'PROGRESSION_CONFIG_INVALID');

-- =====================================================================
-- pure helpers
-- =====================================================================
select public._t_is(public.is_inha_mail('a@inha.edu'), true, 'is_inha_mail inha.edu');
select public._t_is(public.is_inha_mail('a@inha.ac.kr'), true, 'is_inha_mail inha.ac.kr');
select public._t_is(public.is_inha_mail('a@gmail.com'), false, 'is_inha_mail gmail');
select public._t_is(public.is_inha_mail('a@inha.edu.evil.com'), false, 'is_inha_mail suffix trick');
select public._t_is(public.is_inha_mail(''), false, 'is_inha_mail empty');
select public._t_is(public.is_inha_mail(null), false, 'is_inha_mail null');
select public._t_is(private.world_level_for_exp_v1(0), 1, 'level 0 exp -> 1');
select public._t_is(private.world_level_for_exp_v1(99), 1, 'level 99 exp -> 1');
select public._t_is(private.world_level_for_exp_v1(100), 2, 'level 100 exp -> 2');
select public._t_is(private.world_level_for_exp_v1(4499), 9, 'level 4499 exp -> 9');
select public._t_is(private.world_level_for_exp_v1(4500), 10, 'level 4500 exp -> 10');
select public._t_is(private.world_level_for_exp_v1(99999), 10, 'level huge exp -> 10 (max)');

-- =====================================================================
-- inventory / wallet / progression / loadout
-- =====================================================================
select public._t_is(jsonb_array_length(public.get_my_world_inventory_v1(:alice::uuid) -> 'items'), 4, 'inventory alice has 4 items');
select public._t_is(public.get_my_world_inventory_v1(:alice::uuid) -> 'items' -> 0 ->> 'itemId', 'memorabilia.campus_mug', 'inventory newest first');
select public._t_is((public.get_my_world_inventory_v1(:alice::uuid) -> 'items' -> 0 ->> 'quantity')::int, 2, 'inventory mug quantity 2');
select public._t_is(public.get_my_world_inventory_v1(:alice::uuid) -> 'items' -> 0 ->> 'catalogStatus', 'COMING_SOON', 'inventory mug catalog COMING_SOON (seed status)');
select public._t_is(public.get_my_world_inventory_v1(:alice::uuid) -> 'items' -> 1 ->> 'itemId', 'head.induck_cap', 'inventory second item cap');
select public._t_is(public.get_my_world_inventory_v1(:alice::uuid) -> 'items' -> 2 ->> 'itemId', 'top.induck_hoodie', 'inventory third item hoodie');
select public._t_is(public.get_my_world_inventory_v1(:alice::uuid) -> 'items' -> 3 ->> 'itemId', 'badge.main_gate', 'inventory fourth item badge');
select public._t_is(public.get_my_world_inventory_v1(:alice::uuid) -> 'items' -> 0 ->> 'grantId', null, 'inventory client view hides grantId');
select public._t_is(public.get_my_world_inventory_v1(:bob::uuid), '{"items": []}'::jsonb, 'inventory bob empty');
select public._t_throws(format($$select public.get_my_world_inventory_v1(%L::uuid)$$, :stranger),
  '42501', 'inventory unknown session refused', 'ACCOUNT_UNAVAILABLE');
select public._t_is(public.get_my_world_wallet_v1(:alice::uuid), '{"currencies": [{"id": "currency.induck_coin", "balance": 500}]}'::jsonb, 'wallet alice 500');
select public._t_is(public.get_my_world_wallet_v1(:bob::uuid), '{"currencies": [{"id": "currency.induck_coin", "balance": 0}]}'::jsonb, 'wallet bob zero');
select public._t_throws(format($$select public.get_my_world_wallet_v1(%L::uuid)$$, :stranger),
  '42501', 'wallet unknown session refused', 'ACCOUNT_UNAVAILABLE');
select public._t_is(public.get_my_world_progression_v1(:alice::uuid), '{"totalExp": 250, "level": 2, "currentLevelStartExp": 100, "nextLevelExp": 300, "progressExp": 150, "progressRequired": 200, "maxDefinedLevel": 10, "isMaxLevel": false}'::jsonb, 'progression alice 250 exp');
select public._t_is(public.get_my_world_progression_v1(:alice::uuid) ? 'userId', false, 'progression strips userId');
select public._t_is(public.get_my_world_progression_v1(:bob::uuid), '{"totalExp": 0, "level": 1, "currentLevelStartExp": 0, "nextLevelExp": 100, "progressExp": 0, "progressRequired": 100, "maxDefinedLevel": 10, "isMaxLevel": false}'::jsonb, 'progression bob no row');
select public._t_throws(format($$select public.get_my_world_progression_v1(%L::uuid)$$, :stranger),
  '42501', 'progression unknown session refused', 'ACCOUNT_UNAVAILABLE');
select public._t_is(public.get_my_world_appearance_loadout_v1(:alice::uuid) -> 'slots' -> 'HEAD' ->> 'itemId', 'head.induck_cap', 'loadout alice HEAD');
select public._t_is(public.get_my_world_appearance_loadout_v1(:alice::uuid) -> 'slots' -> 'TOP' ->> 'itemId', 'top.induck_hoodie', 'loadout alice TOP');
select public._t_is(public.get_my_world_appearance_loadout_v1(:alice::uuid) -> 'slots' -> 'BODY', 'null'::jsonb, 'loadout alice BODY empty');
select public._t_is(public.get_my_world_appearance_loadout_v1(:bob::uuid) -> 'slots' -> 'HEAD', 'null'::jsonb, 'loadout bob no row');
select public._t_throws(format($$select public.get_my_world_appearance_loadout_v1(%L::uuid)$$, :stranger),
  '42501', 'loadout unknown session refused', 'ACCOUNT_UNAVAILABLE');

-- =====================================================================
-- shop / capabilities / staff badges
-- =====================================================================
select public._t_is(public.get_world_shop_v1(:alice::uuid, 'shop.student_center') ->> 'shopId', 'shop.student_center', 'shop id');
select public._t_is(public.get_world_shop_v1(:alice::uuid, 'shop.student_center') ->> 'displayName', '학생회관 기념품점', 'shop display name');
select public._t_is(public.get_world_shop_v1(:alice::uuid, 'shop.student_center') ->> 'status', 'ACTIVE', 'shop status');
select public._t_is((public.get_world_shop_v1(:alice::uuid, 'shop.student_center') ->> 'playerLevel')::int, 2, 'shop player level from progression');
select public._t_is(jsonb_array_length(public.get_world_shop_v1(:alice::uuid, 'shop.student_center') -> 'offers'), 1, 'shop student_center 1 offer');
select public._t_is(public.get_world_shop_v1(:alice::uuid, 'shop.student_center') -> 'offers' -> 0 ->> 'listingId', 'offer.student_center.campus_mug', 'shop mug listing');
select public._t_is(public.get_world_shop_v1(:alice::uuid, 'shop.student_center') -> 'offers' -> 0 ->> 'purchasable', 'true', 'shop mug purchasable');
select public._t_is(public.get_world_shop_v1(:alice::uuid, 'shop.student_center') -> 'offers' -> 0 ->> 'unavailableReason', null, 'shop mug no reason');
select public._t_is(jsonb_array_length(public.get_world_shop_v1(:alice::uuid, 'shop.student_center_fashion') -> 'offers'), 4, 'shop fashion 4 offers');
select public._t_is((select jsonb_agg(o ->> 'listingId' order by o ->> 'listingId') from jsonb_array_elements(public.get_world_shop_v1(:alice::uuid, 'shop.student_center_fashion') -> 'offers') o),
  '["offer.student_center.campus_sneakers", "offer.student_center.induck_backpack", "offer.student_center.induck_cap", "offer.student_center.induck_hoodie"]'::jsonb, 'shop fashion listing ids');
select public._t_is((select o ->> 'unavailableReason' from jsonb_array_elements(public.get_world_shop_v1(:alice::uuid, 'shop.student_center_fashion') -> 'offers') o where o ->> 'listingId' = 'offer.student_center.induck_backpack'), 'LEVEL_REQUIRED', 'shop backpack needs level 3');
select public._t_is((select o ->> 'purchasable' from jsonb_array_elements(public.get_world_shop_v1(:alice::uuid, 'shop.student_center_fashion') -> 'offers') o where o ->> 'listingId' = 'offer.student_center.campus_sneakers'), 'true', 'shop sneakers purchasable at level 2');
select public._t_is(jsonb_array_length(public.get_world_shop_v1(:alice::uuid, 'shop.room_finishes') -> 'offers'), 2, 'shop room finishes 2 LOCKED offers');
select public._t_is((select o ->> 'unavailableReason' from jsonb_array_elements(public.get_world_shop_v1(:alice::uuid, 'shop.room_finishes') -> 'offers') o limit 1), 'LISTING_LOCKED', 'shop locked reason');
select public._t_throws($$select public.get_world_shop_v1('a1000000-0000-4000-8000-000000000001'::uuid, 'shop.nope')$$,
  'P0001', 'shop unknown id not found', 'SHOP_NOT_FOUND');
update private.world_shops set status = 'HIDDEN' where shop_id = 'shop.room_finishes';
select public._t_throws($$select public.get_world_shop_v1('a1000000-0000-4000-8000-000000000001'::uuid, 'shop.room_finishes')$$,
  'P0001', 'shop hidden not found', 'SHOP_NOT_FOUND');
update private.world_shops set status = 'ACTIVE' where shop_id = 'shop.room_finishes';
select public._t_is(public.get_world_shop_v1(:stranger::uuid, 'shop.student_center') ->> 'shopId', 'shop.student_center', 'shop has no account check (original behavior; Worker guards the session)');
select public._t_is(public.get_world_shop_capabilities_v1(:alice::uuid) ->> 'purchaseRpc', 'purchase_world_shop_listing_v2', 'capabilities purchaseRpc v2 (A-2: purchase RPCs exist)');
select public._t_is(public.get_world_shop_capabilities_v1(:alice::uuid) ->> 'catalogLayout', 'split', 'capabilities catalogLayout split (A-2)');
select public._t_is((public.get_world_shop_capabilities_v1(:alice::uuid) ->> 'version')::int, 1, 'capabilities version 1');
select public._t_is((select count(*) from public.get_world_staff_badges_v1(:alice::uuid, array[:alice::uuid, :bob::uuid])), 1::bigint, 'staff badges alice+Bob -> 1');
select public._t_is((select badge_code from public.get_world_staff_badges_v1(:alice::uuid, array[:alice::uuid, :bob::uuid])), 'gm', 'staff badge code gm');
select public._t_is((select user_id from public.get_world_staff_badges_v1(:alice::uuid, array[:alice::uuid, :bob::uuid])), :alice::uuid, 'staff badge user alice');
select public._t_is((select count(*) from public.get_world_staff_badges_v1(:alice::uuid, array[:bob::uuid])), 0::bigint, 'staff badges inactive bob -> 0');
select public._t_is((select count(*) from public.get_world_staff_badges_v1(:alice::uuid, array[]::uuid[])), 0::bigint, 'staff badges empty ids -> 0');
select public._t_is((select count(*) from public.get_world_staff_badges_v1(:alice::uuid, (select array_agg(:alice::uuid) from generate_series(1, 65)))), 0::bigint, 'staff badges 65 ids -> 0 (cardinality guard)');
select public._t_is((select count(*) from public.get_world_staff_badges_v1(:stranger::uuid, array[:alice::uuid])), 1::bigint, 'staff badges has no account check (original behavior; Worker guards the session)');

-- =====================================================================
-- profile + achievements
-- =====================================================================
select public._t_is(public.my_inha_mail_badge(:alice::uuid), true, 'mail badge alice true (badges row)');
select public._t_is(public.my_inha_mail_badge(:bob::uuid), false, 'mail badge bob false');
select public._t_is(public.get_my_profile(:alice::uuid) -> 'profile' ->> 'nickname', 'tier4alice', 'profile alice nickname');
select public._t_is(public.get_my_profile(:alice::uuid) -> 'profile' ->> 'department', '환경공학과', 'profile alice department');
select public._t_is(public.get_my_profile(:alice::uuid) -> 'profile' ->> 'title', '주치의', 'profile alice title');
select public._t_is((public.get_my_profile(:alice::uuid) -> 'profile' ->> 'joinedAt')::timestamptz, '2026-11-01T00:00:00Z'::timestamptz, 'profile joinedAt from profiles row');
select public._t_is(public.get_my_profile(:alice::uuid) -> 'profile' -> 'inhaVerified', 'true'::jsonb, 'profile alice inhaVerified');
select public._t_is(public.get_my_profile(:bob::uuid) -> 'profile' -> 'inhaVerified', 'false'::jsonb, 'profile bob inhaVerified false');
select public._t_is((public.get_my_profile(:alice::uuid) -> 'stats' ->> 'playedGames')::int, 2, 'profile alice playedGames 2 (inha-duck + survival progress)');
select public._t_is(jsonb_array_length(public.get_my_profile(:alice::uuid) -> 'games'), 4, 'profile games list = 4 seed games');
select public._t_is((select value ->> 'played' from jsonb_array_elements(public.get_my_profile(:alice::uuid) -> 'games') value where value ->> 'slug' = 'inha-duck'), 'true', 'profile inha-duck played');
select public._t_is((select value -> 'headline' from jsonb_array_elements(public.get_my_profile(:alice::uuid) -> 'games') value where value ->> 'slug' = 'inha-duck-survival'), '{"label": "최고 클리어 스테이지", "value": "1"}'::jsonb, 'profile survival headline');
select public._t_throws(format($$select public.get_my_profile(%L::uuid)$$, :noprofile),
  '42501', 'profile missing -> PROFILE_NOT_FOUND', 'PROFILE_NOT_FOUND');
select public._t_throws(format($$select public.get_my_profile(%L::uuid)$$, :banned),
  '42501', 'profile banned -> PROFILE_NOT_FOUND', 'PROFILE_NOT_FOUND');
select public._t_is((public.get_my_achievements(:alice::uuid) ->> 'earnedCount')::int, 4, 'achievements alice earnedCount 4');
select public._t_is((select count(*) from jsonb_array_elements(public.get_my_achievements(:alice::uuid) -> 'achievements') a where a ->> 'earned' = 'true'), 4::bigint, 'achievements alice 4 earned');
select public._t_is((select a ->> 'title' from jsonb_array_elements(public.get_my_achievements(:alice::uuid) -> 'achievements') a where a ->> 'key' = 'classic_inha_duck_s1_rank_2_v1'), '인하오리 S1 준우승', 'achievements event title rank 2');
select public._t_is((select (a ->> 'earnedAt')::timestamptz from jsonb_array_elements(public.get_my_achievements(:alice::uuid) -> 'achievements') a where a ->> 'key' = 'inha_verified_v1'), '2026-11-04T00:00:00Z'::timestamptz, 'achievements inha verifiedAt from badges row');
select public._t_is((select count(*) from public.user_achievements where user_id = :alice::uuid), 4::bigint, 'achievements materialized 4 rows (3 + pre-inserted event)');
select public._t_is(public.get_my_achievements(:alice::uuid) ->> 'earnedCount', public.get_my_achievements(:alice::uuid) ->> 'earnedCount', 'achievements second call same result (idempotent)');
select public._t_is((select count(*) from public.user_achievements where user_id = :alice::uuid), 4::bigint, 'achievements second call adds no rows');
select public._t_is((public.get_my_achievements(:bob::uuid) ->> 'earnedCount')::int, 0, 'achievements bob earnedCount 0');
select public._t_is((select count(*) from jsonb_array_elements(public.get_my_achievements(:bob::uuid) -> 'achievements') a where a ->> 'earned' = 'true'), 0::bigint, 'achievements bob none earned');
select public._t_throws(format($$select public.get_my_achievements(%L::uuid)$$, :noprofile),
  '42501', 'achievements missing profile -> PROFILE_NOT_FOUND', 'PROFILE_NOT_FOUND');
select public._t_throws(format($$select public.get_my_achievements(%L::uuid)$$, :banned),
  '42501', 'achievements banned profile -> PROFILE_NOT_FOUND', 'PROFILE_NOT_FOUND');

-- =====================================================================
-- A-2 seeds + grants
-- =====================================================================
select public._t_is((select count(*) from private.world_reward_definitions), 10::bigint, 'seed reward definitions = 10');
select public._t_is((select count(*) from private.world_reward_grants), 17::bigint, 'seed reward grants = 17');
select public._t_is((select count(*) from private.world_jeongseok_gate_policy), 1::bigint, 'seed jeongseok gate = 1');
select public._t_is((select count(*) from private.world_jeongseok_pass_catalog), 1::bigint, 'seed jeongseok pass catalog = 1');
select public._t_is((select count(*) from private.world_recipe_catalog), 1::bigint, 'seed recipe catalog = 1');
select public._t_is((select status from private.world_jeongseok_gate_policy), 'COMING_SOON', 'jeongseok gate ships COMING_SOON (origin rollout rule)');
select public._t_is((select status from private.world_jeongseok_pass_catalog), 'COMING_SOON', 'jeongseok pass ships COMING_SOON');
select public._t_is((select status from private.world_recipe_catalog where recipe_id = 'recipe.carp_grill'), 'COMING_SOON', 'carp recipe ships COMING_SOON');
select public._t_is((select price from private.world_jeongseok_pass_catalog), 100::bigint, 'jeongseok day pass price 100 (CONFIRMED basis)');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.equip_my_world_item_v1(uuid, text, text, text)'::regprocedure, 'EXECUTE'), true, 'grant equip');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.unequip_my_world_item_v1(uuid, text, text)'::regprocedure, 'EXECUTE'), true, 'grant unequip');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.purchase_world_shop_listing_v1(uuid, text, text)'::regprocedure, 'EXECUTE'), true, 'grant purchase v1');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.purchase_world_shop_listing_v2(uuid, text, text, text)'::regprocedure, 'EXECUTE'), true, 'grant purchase v2');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.claim_my_world_attendance_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant attendance claim');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_my_world_attendance_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant attendance read');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.create_world_guestbook_entry_v2(uuid, text, text)'::regprocedure, 'EXECUTE'), true, 'grant guestbook create');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.update_world_guestbook_entry_v2(uuid, uuid, text)'::regprocedure, 'EXECUTE'), true, 'grant guestbook update');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.delete_world_guestbook_entry_v2(uuid, uuid)'::regprocedure, 'EXECUTE'), true, 'grant guestbook delete');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_world_guestbook_v2(uuid, text, integer, timestamptz)'::regprocedure, 'EXECUTE'), true, 'grant guestbook read');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.purchase_jeongseok_pass_v1(uuid, text, text)'::regprocedure, 'EXECUTE'), true, 'grant jeongseok purchase');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_jeongseok_access_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant jeongseok access');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.cook_my_world_recipe_v1(uuid, text, uuid)'::regprocedure, 'EXECUTE'), true, 'grant cooking');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.save_my_room_furniture_v1(uuid, uuid, integer, jsonb)'::regprocedure, 'EXECUTE'), true, 'grant furniture save');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_world_room_furniture_v1(uuid, uuid)'::regprocedure, 'EXECUTE'), true, 'grant furniture read');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_or_create_my_personal_room_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant personal room ensure');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.set_my_personal_room_visibility_v1(uuid, text)'::regprocedure, 'EXECUTE'), true, 'grant personal room visibility');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.knock_friend_personal_room_v1(uuid, uuid)'::regprocedure, 'EXECUTE'), true, 'grant knock');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.get_my_room_knock_v1(uuid, uuid)'::regprocedure, 'EXECUTE'), true, 'grant knock get');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.list_my_room_knocks_v1(uuid)'::regprocedure, 'EXECUTE'), true, 'grant knock list');
select public._t_is(has_function_privilege('inha_world_tier4_writes_app', 'public.respond_room_knock_v1(uuid, uuid, boolean)'::regprocedure, 'EXECUTE'), true, 'grant knock respond');
select public._t_is((select (proacl::text like '{=X/%' or proacl::text like '%,=X/%') from pg_proc where oid = 'public.equip_my_world_item_v1(uuid, text, text, text)'::regprocedure), false, 'equip acl grants nothing to PUBLIC');

-- =====================================================================
-- A-2 fixtures (inserted here, after the A-1 read assertions, so the extra
-- items and the bob wallet do not change the A-1 read results)
-- =====================================================================
\set carol '''a5000000-0000-4000-8000-000000000005'''
\set dave '''d6000000-0000-4000-8000-000000000006'''
\set grant5 '''b5000000-0000-4000-8000-000000000005'''
\set grant6 '''b6000000-0000-4000-8000-000000000006'''
\set grant7 '''b7000000-0000-4000-8000-000000000007'''
insert into public.sessions (id, nickname) values (:carol, 'carol');
insert into public.sessions (id, nickname) values (:dave, 'dave');
insert into public.profiles (user_id, nickname, department_id, title, is_banned, created_at) values
  (:carol, 'tier4carol', 1, null, false, '2026-11-01T00:00:00Z'),
  (:dave, 'tier4dave', 1, null, false, '2026-11-01T00:00:00Z');
insert into private.world_wallets (user_id, currency_id, balance) values
  (:bob, 'currency.induck_coin', 50);
insert into public.world_friendships (user_low, user_high, status, requested_by, accepted_at) values
  (:alice, :bob, 'accepted', :alice, now()),
  (:alice, :carol, 'accepted', :alice, now()),
  (:bob, :carol, 'accepted', :bob, now());
insert into private.world_item_grants (grant_id, user_id, item_id, result, quantity_requested, quantity_before, quantity_granted, quantity_after, source_type, source_ref) values
  (:grant5, :alice, 'material.fish_carp', 'GRANTED', 3, 0, 3, 3, 'SYSTEM', 'oracle'),
  (:grant6, :alice, 'furniture.cooking_station', 'GRANTED', 1, 0, 1, 1, 'SYSTEM', 'oracle'),
  (:grant7, :alice, 'furniture.induck_chair', 'GRANTED', 1, 0, 1, 1, 'SYSTEM', 'oracle');
insert into private.world_player_items (user_id, item_id, quantity, source_type, source_ref, grant_id, acquired_at) values
  (:alice, 'material.fish_carp', 3, 'test', 'oracle', :grant5, '2026-11-05T00:00:00Z'),
  (:alice, 'furniture.cooking_station', 1, 'test', 'oracle', :grant6, '2026-11-05T00:00:00Z'),
  (:alice, 'furniture.induck_chair', 1, 'test', 'oracle', :grant7, '2026-11-05T00:00:00Z');

-- =====================================================================
-- loadout writes: equip / unequip + idempotency (DO block: each key is
-- called exactly once per assertion group — a plain SELECT per assertion
-- would re-execute the RPC and turn every second call into a replay)
-- =====================================================================
do $do$
declare
  v_alice constant uuid := 'a1000000-0000-4000-8000-000000000001';
  v_stranger constant uuid := 'a9000000-0000-4000-8000-000000000009';
  v_r jsonb; v_tx uuid;
begin
  v_r := public.equip_my_world_item_v1(v_alice, 'HEAD', 'head.induck_cap', 'oracle-equip-1');
  perform public._t_is(v_r ->> 'status', 'SUCCESS', 'equip already-equipped cap succeeds');
  perform public._t_is((v_r ->> 'replayed')::boolean, false, 'equip first call not replayed');
  perform public._t_is((v_r ->> 'changed')::boolean, false, 'equip same item unchanged');
  v_tx := (v_r ->> 'transactionId')::uuid;
  v_r := public.equip_my_world_item_v1(v_alice, 'HEAD', 'head.induck_cap', 'oracle-equip-1');
  perform public._t_is((v_r ->> 'replayed')::boolean, true, 'equip same key replays');
  perform public._t_is((v_r ->> 'transactionId')::uuid, v_tx, 'equip replay returns same transaction');
  perform public._t_is((select count(*) from private.world_appearance_transactions where user_id = v_alice and idempotency_key = 'oracle-equip-1'), 1::bigint, 'equip replay adds no transaction row');
  perform public._t_throws(format($$select public.equip_my_world_item_v1(%L::uuid, 'HEAD', 'top.induck_hoodie', 'oracle-equip-1')$$, v_alice),
    '23505', 'equip same key different item conflicts', 'IDEMPOTENCY_CONFLICT');
  v_r := public.unequip_my_world_item_v1(v_alice, 'HEAD', 'oracle-unequip-1');
  perform public._t_is(v_r ->> 'status', 'SUCCESS', 'unequip HEAD succeeds');
  perform public._t_is(v_r ->> 'previousItemId', 'head.induck_cap', 'unequip previous item cap');
  perform public._t_is((v_r ->> 'changed')::boolean, true, 'unequip changed');
  perform public._t_is(public.get_my_world_appearance_loadout_v1(v_alice) -> 'slots' -> 'HEAD', 'null'::jsonb, 'loadout HEAD empty after unequip');
  v_r := public.unequip_my_world_item_v1(v_alice, 'HEAD', 'oracle-unequip-2');
  perform public._t_is(v_r ->> 'previousItemId', null, 'unequip empty slot previous null');
  perform public._t_is((v_r ->> 'changed')::boolean, false, 'unequip empty slot unchanged');
  v_r := public.equip_my_world_item_v1(v_alice, 'HEAD', 'head.induck_cap', 'oracle-equip-2');
  perform public._t_is(v_r ->> 'status', 'SUCCESS', 're-equip cap succeeds');
  perform public._t_is(public.get_my_world_appearance_loadout_v1(v_alice) -> 'slots' -> 'HEAD' ->> 'itemId', 'head.induck_cap', 'loadout HEAD cap again');
  perform public._t_throws(format($$select public.equip_my_world_item_v1(%L::uuid, 'SHOES', 'shoes.campus_sneakers', 'oracle-equip-3')$$, v_alice),
    'P0001', 'equip not-owned item refused', 'ITEM_NOT_OWNED');
  perform public._t_throws(format($$select public.equip_my_world_item_v1(%L::uuid, 'NOPE', 'head.induck_cap', 'oracle-equip-4')$$, v_alice),
    '22023', 'equip invalid slot refused', 'INVALID_APPEARANCE_SLOT');
  perform public._t_throws(format($$select public.unequip_my_world_item_v1(%L::uuid, 'NOPE', 'oracle-unequip-3')$$, v_alice),
    '22023', 'unequip invalid slot refused', 'INVALID_APPEARANCE_SLOT');
  perform public._t_throws(format($$select public.equip_my_world_item_v1(%L::uuid, 'HEAD', 'head.induck_cap', null)$$, v_alice),
    '22023', 'equip null key refused', 'INVALID_IDEMPOTENCY_KEY');
  perform public._t_throws(format($$select public.equip_my_world_item_v1(%L::uuid, 'HEAD', 'head.induck_cap', 'oracle-equip-5')$$, v_stranger),
    '42501', 'equip unknown session refused', 'ACCOUNT_UNAVAILABLE');
end
$do$;

-- =====================================================================
-- shop purchase: v1 / v2, idempotency, atomicity (DO block, same reason:
-- one RPC call per key per assertion group)
-- =====================================================================
do $do$
declare
  v_alice constant uuid := 'a1000000-0000-4000-8000-000000000001';
  v_bob constant uuid := 'a2000000-0000-4000-8000-000000000002';
  v_r jsonb; v_pid uuid;
begin
  -- bob wallet 50 < mug 120, no level gate on the mug -> funds refuse first
  perform public._t_throws(format($$select public.purchase_world_shop_listing_v1(%L::uuid, 'offer.student_center.campus_mug', 'oracle-buy-bob-1')$$, v_bob),
    'P0001', 'bob cannot afford mug', 'INSUFFICIENT_FUNDS');
  perform public._t_is((select balance from private.world_wallets where user_id = v_bob and currency_id = 'currency.induck_coin'), 50::bigint, 'bob wallet unchanged after failed purchase');
  perform public._t_is((select count(*) from private.world_purchase_transactions where user_id = v_bob), 0::bigint, 'bob has no purchase row after failed purchase');
  perform public._t_is((select count(*) from private.world_player_items where user_id = v_bob and item_id = 'memorabilia.campus_mug'), 0::bigint, 'bob has no mug after failed purchase');
  v_r := public.purchase_world_shop_listing_v1(v_alice, 'offer.student_center.campus_sneakers', 'oracle-buy-1');
  perform public._t_is(v_r ->> 'status', 'SUCCESS', 'alice buys sneakers v1');
  perform public._t_is((v_r ->> 'replayed')::boolean, false, 'purchase first call not replayed');
  perform public._t_is((v_r -> 'wallet' ->> 'balanceBefore')::int, 500, 'purchase balance before 500');
  perform public._t_is((v_r -> 'wallet' ->> 'balanceAfter')::int, 260, 'purchase balance after 260');
  perform public._t_is((select quantity from private.world_player_items where user_id = v_alice and item_id = 'shoes.campus_sneakers'), 1, 'sneakers granted 1');
  v_pid := (v_r ->> 'purchaseId')::uuid;
  v_r := public.purchase_world_shop_listing_v1(v_alice, 'offer.student_center.campus_sneakers', 'oracle-buy-1');
  perform public._t_is((v_r ->> 'replayed')::boolean, true, 'purchase same key replays');
  perform public._t_is((v_r ->> 'purchaseId')::uuid, v_pid, 'purchase replay returns same purchase');
  perform public._t_is((v_r -> 'wallet' ->> 'balanceAfter')::int, 260, 'purchase replay does not debit again');
  perform public._t_is((select count(*) from private.world_purchase_transactions where user_id = v_alice and idempotency_key = 'oracle-buy-1'), 1::bigint, 'purchase replay adds no transaction row');
  perform public._t_throws(format($$select public.purchase_world_shop_listing_v1(%L::uuid, 'offer.student_center.campus_mug', 'oracle-buy-1')$$, v_alice),
    '23505', 'purchase same key different listing conflicts', 'IDEMPOTENCY_CONFLICT');
  perform public._t_throws(format($$select public.purchase_world_shop_listing_v1(%L::uuid, 'offer.student_center.campus_mug', 'oracle-buy-3')$$, v_alice),
    'P0001', 'mug already owned (UNIQUE)', 'ITEM_ALREADY_OWNED');
  perform public._t_throws(format($$select public.purchase_world_shop_listing_v1(%L::uuid, 'offer.student_center.induck_backpack', 'oracle-buy-4')$$, v_alice),
    'P0001', 'backpack needs level 3 (alice is 2)', 'LEVEL_REQUIRED');
  perform public._t_throws(format($$select public.purchase_world_shop_listing_v1(%L::uuid, 'offer.nope', 'oracle-buy-5')$$, v_alice),
    'P0001', 'unknown listing refused', 'INVALID_LISTING');
  perform public._t_throws(format($$select public.purchase_world_shop_listing_v1(%L::uuid, 'offer.student_center.campus_sneakers', null)$$, v_alice),
    '22023', 'purchase null key refused', 'INVALID_IDEMPOTENCY_KEY');
  v_r := public.purchase_world_shop_listing_v2(v_alice, 'shop.dorm_furniture', 'offer.dorm_furniture.induck_cushion', 'oracle-buy-6');
  perform public._t_is(v_r ->> 'status', 'SUCCESS', 'alice buys cushion v2 (scoped shop)');
  perform public._t_is((v_r -> 'wallet' ->> 'balanceAfter')::int, 40, 'cushion v2 balance after 40');
  v_pid := (v_r ->> 'purchaseId')::uuid;
  v_r := public.purchase_world_shop_listing_v2(v_alice, 'shop.dorm_furniture', 'offer.dorm_furniture.induck_cushion', 'oracle-buy-6');
  perform public._t_is((v_r ->> 'replayed')::boolean, true, 'v2 same key replays');
  perform public._t_is((v_r ->> 'purchaseId')::uuid, v_pid, 'v2 replay returns same purchase');
  perform public._t_is((v_r -> 'wallet' ->> 'balanceAfter')::int, 40, 'v2 replay does not debit again');
  perform public._t_throws(format($$select public.purchase_world_shop_listing_v2(%L::uuid, 'shop.student_center', 'offer.dorm_furniture.induck_cushion', 'oracle-buy-7')$$, v_alice),
    'P0001', 'v2 listing belongs to another shop', 'SHOP_LISTING_MISMATCH');
  perform public._t_throws(format($$select public.purchase_world_shop_listing_v2(%L::uuid, 'shop.dorm_furniture', 'offer.dorm_furniture.induck_cushion', 'oracle-buy-8')$$, v_alice),
    'P0001', 'v2 cushion already owned', 'ITEM_ALREADY_OWNED');
  perform public._t_throws(format($$select public.purchase_world_shop_listing_v2(%L::uuid, 'shop.nope', 'offer.dorm_furniture.induck_cushion', 'oracle-buy-9')$$, v_alice),
    'P0001', 'v2 unknown shop is a listing mismatch (shop existence is not checked first)', 'SHOP_LISTING_MISMATCH');
  perform public._t_is((select count(*) from private.world_purchase_transactions where user_id = v_alice), 2::bigint, 'alice has 2 purchase rows (v1 sneakers + v2 cushion)');
  perform public._t_is((select balance from private.world_wallets where user_id = v_alice and currency_id = 'currency.induck_coin'), 40::bigint, 'alice wallet 40 after both purchases');
end
$do$;

-- =====================================================================
-- attendance: claim + replay + milestone (bob has 2 prior days)
-- =====================================================================
select public._t_is(public.get_my_world_attendance_v1(:alice::uuid) ->> 'claimedToday', 'false', 'attendance alice not claimed yet');
select public._t_is((public.get_my_world_attendance_v1(:alice::uuid) ->> 'attendedDays')::int, 0, 'attendance alice 0 days');
select public._t_is((public.get_my_world_attendance_v1(:alice::uuid) ->> 'dailyCoin')::int, 10, 'attendance daily coin 10');
select public._t_is((public.get_my_world_attendance_v1(:alice::uuid) -> 'nextMilestone' ->> 'days')::int, 3, 'attendance next milestone 3');
select public._t_is(public.claim_my_world_attendance_v1(:alice::uuid) ->> 'claimed', 'true', 'attendance alice claim succeeds');
select public._t_is(public.claim_my_world_attendance_v1(:alice::uuid) ->> 'replayed', 'true', 'attendance second claim replays');
select public._t_is(public.claim_my_world_attendance_v1(:alice::uuid) ->> 'claimed', 'false', 'attendance replay claimed false');
select public._t_is(jsonb_array_length(public.claim_my_world_attendance_v1(:alice::uuid) -> 'rewards'), 0, 'attendance replay rewards empty');
select public._t_is((select balance from private.world_wallets where user_id = :alice::uuid and currency_id = 'currency.induck_coin'), 50::bigint, 'attendance daily +10 (40 -> 50), replay adds nothing');
select public._t_is(public.get_my_world_attendance_v1(:alice::uuid) ->> 'claimedToday', 'true', 'attendance alice claimed today');
select public._t_is((public.get_my_world_attendance_v1(:alice::uuid) ->> 'attendedDays')::int, 1, 'attendance alice 1 day');
select public._t_is((public.get_my_world_attendance_v1(:alice::uuid) -> 'nextMilestone' ->> 'days')::int, 3, 'attendance next milestone still 3');
select public._t_throws(format($$select public.claim_my_world_attendance_v1(%L::uuid)$$, :stranger),
  '42501', 'attendance unknown session refused', 'ACCOUNT_UNAVAILABLE');
do $do$
declare
  v_bob constant uuid := 'a2000000-0000-4000-8000-000000000002';
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_tx1 uuid; v_tx2 uuid; v_claim jsonb; v_state jsonb;
begin
  -- two prior days in the same month, each with a real daily reward transaction
  v_tx1 := (private.world_reward_grant_v1(v_bob, 'reward.attendance.daily', 'SYSTEM', 'attendance.daily',
    'attendance:daily:' || v_bob::text || ':' || to_char(v_today - 2, 'YYYY-MM-DD')) ->> 'rewardTransactionId')::uuid;
  v_tx2 := (private.world_reward_grant_v1(v_bob, 'reward.attendance.daily', 'SYSTEM', 'attendance.daily',
    'attendance:daily:' || v_bob::text || ':' || to_char(v_today - 1, 'YYYY-MM-DD')) ->> 'rewardTransactionId')::uuid;
  insert into private.world_attendance_days (user_id, attendance_date, claimed_at, daily_reward_transaction_id)
    values (v_bob, v_today - 2, now(), v_tx1), (v_bob, v_today - 1, now(), v_tx2);
  v_claim := public.claim_my_world_attendance_v1(v_bob);
  perform public._t_is(v_claim ->> 'claimed', 'true', 'attendance bob claim succeeds (3rd day)');
  perform public._t_is(jsonb_array_length(v_claim -> 'rewards'), 2, 'attendance bob gets daily + monthly_3 rewards');
  perform public._t_is((select balance from private.world_wallets where user_id = v_bob and currency_id = 'currency.induck_coin'), 110::bigint, 'attendance bob wallet 50 + 10 + 10 (two prior daily grants) + 10 daily + 30 milestone = 110');
  v_state := public.get_my_world_attendance_v1(v_bob);
  perform public._t_is((v_state ->> 'attendedDays')::int, 3, 'attendance bob 3 days');
  perform public._t_is((v_state -> 'nextMilestone' ->> 'days')::int, 7, 'attendance bob next milestone 7');
  perform public._t_is((v_state -> 'milestones' -> 0 ->> 'bonusCoin')::int, 30, 'attendance monthly_3 bonus 30');
end
$do$;

-- =====================================================================
-- guestbook: create / update / delete + owner check + limits (DO block:
-- the entry id must be carried between calls)
-- =====================================================================
do $do$
declare
  v_alice constant uuid := 'a1000000-0000-4000-8000-000000000001';
  v_bob constant uuid := 'a2000000-0000-4000-8000-000000000002';
  v_banned constant uuid := 'a3000000-0000-4000-8000-000000000003';
  v_noprofile constant uuid := 'a4000000-0000-4000-8000-000000000004';
  v_entry uuid; v_board jsonb; v_r jsonb;
begin
  -- bob already used his 3 daily posts (fixture log rows, no entries needed)
  insert into private.world_guestbook_post_log (id, entry_id, user_id, location_key, created_at)
    select gen_random_uuid(), gen_random_uuid(), v_bob, 'main_gate', now() from generate_series(1, 3);
  perform public._t_throws(format($$select public.create_world_guestbook_entry_v2(%L::uuid, 'too many', 'main_gate')$$, v_bob),
    'P0001', 'guestbook bob daily limit 3 reached', 'DAILY_LIMIT_REACHED');
  -- alice creates one entry
  v_entry := (public.create_world_guestbook_entry_v2(v_alice, 'hello oracle', 'main_gate') ->> 'id')::uuid;
  perform public._t_is(v_entry is not null, true, 'guestbook alice entry created');
  v_board := public.get_world_guestbook_v2(v_alice, 'main_gate', 20, null);
  perform public._t_is(jsonb_array_length(v_board -> 'entries'), 1, 'guestbook board has 1 entry');
  perform public._t_is(v_board -> 'entries' -> 0 ->> 'content', 'hello oracle', 'guestbook entry content');
  perform public._t_is((v_board -> 'entries' -> 0 ->> 'mine')::boolean, true, 'guestbook entry mine true for author');
  perform public._t_is((v_board ->> 'dailyUsed')::int, 1, 'guestbook daily used 1');
  perform public._t_is((v_board ->> 'dailyRemaining')::int, 2, 'guestbook daily remaining 2');
  -- second create within 60 s hits the cooldown
  perform public._t_throws(format($$select public.create_world_guestbook_entry_v2(%L::uuid, 'again', 'main_gate')$$, v_alice),
    'P0001', 'guestbook alice second create hits cooldown', 'GUESTBOOK_COOLDOWN');
  -- owner check: bob cannot touch alice's entry
  perform public._t_throws(format($$select public.update_world_guestbook_entry_v2(%L::uuid, %L::uuid, 'hacked')$$, v_bob, v_entry),
    '22023', 'guestbook bob cannot update alice entry', 'ENTRY_UNAVAILABLE');
  perform public._t_throws(format($$select public.delete_world_guestbook_entry_v2(%L::uuid, %L::uuid)$$, v_bob, v_entry),
    '22023', 'guestbook bob cannot delete alice entry', 'ENTRY_UNAVAILABLE');
  v_r := public.update_world_guestbook_entry_v2(v_alice, v_entry, 'hello oracle v2');
  perform public._t_is(v_r ->> 'content', 'hello oracle v2', 'guestbook alice update works');
  perform public._t_is(public.delete_world_guestbook_entry_v2(v_alice, v_entry), true, 'guestbook alice delete works');
  v_board := public.get_world_guestbook_v2(v_alice, 'main_gate', 20, null);
  perform public._t_is(jsonb_array_length(v_board -> 'entries'), 0, 'guestbook board empty after delete');
  -- profile gate: no profile / banned cannot write or read
  perform public._t_throws(format($$select public.create_world_guestbook_entry_v2(%L::uuid, 'x', 'main_gate')$$, v_noprofile),
    '42501', 'guestbook no-profile cannot create', 'PROFILE_NOT_FOUND');
  perform public._t_throws(format($$select public.create_world_guestbook_entry_v2(%L::uuid, 'x', 'main_gate')$$, v_banned),
    '42501', 'guestbook banned cannot create', 'PROFILE_NOT_FOUND');
  perform public._t_throws(format($$select public.get_world_guestbook_v2(%L::uuid, 'main_gate', 20, null)$$, v_noprofile),
    '42501', 'guestbook no-profile cannot read', 'PROFILE_NOT_FOUND');
  -- validation
  perform public._t_throws(format($$select public.create_world_guestbook_entry_v2(%L::uuid, '', 'main_gate')$$, v_alice),
    '22023', 'guestbook empty content refused', 'INVALID_CONTENT');
  perform public._t_throws(format($$select public.create_world_guestbook_entry_v2(%L::uuid, 'x', 'nope')$$, v_alice),
    '22023', 'guestbook bad location refused', 'INVALID_LOCATION');
end
$do$;

-- =====================================================================
-- jeongseok: seed-gated COMING_SOON, then fixture-activated positive path
-- =====================================================================
select public._t_is(public.get_jeongseok_access_v1(:alice::uuid) ->> 'decision', 'COMING_SOON', 'jeongseok access seed decision COMING_SOON');
select public._t_is((public.get_jeongseok_access_v1(:alice::uuid) ->> 'granted')::boolean, false, 'jeongseok access seed not granted');
select public._t_is(public.get_jeongseok_access_v1(:alice::uuid) -> 'offer', 'null'::jsonb, 'jeongseok access seed hides offer');
select public._t_throws($$select public.purchase_jeongseok_pass_v1('a1000000-0000-4000-8000-000000000001'::uuid, 'jeongseok.visitor.day', 'oracle-js-0')$$,
  'P0001', 'jeongseok purchase blocked while gate COMING_SOON', 'JEONGSEOK_GATE_UNAVAILABLE');
update private.world_jeongseok_gate_policy set status = 'ACTIVE' where singleton;
update private.world_jeongseok_pass_catalog set status = 'ACTIVE' where pass_type = 'jeongseok.visitor.day';
select public._t_is(public.get_jeongseok_access_v1(:bob::uuid) ->> 'decision', 'NEEDS_PASS', 'jeongseok bob needs pass after activation');
select public._t_is((public.get_jeongseok_access_v1(:bob::uuid) -> 'offer' ->> 'price')::int, 100, 'jeongseok offer price 100');
select public._t_is((public.get_jeongseok_access_v1(:bob::uuid) -> 'offer' ->> 'canPurchase')::boolean, true, 'jeongseok bob can purchase (wallet 110 >= 100)');
select public._t_is(public.get_jeongseok_access_v1(:alice::uuid) ->> 'decision', 'GRANTED', 'jeongseok alice granted via inha mail badge');
select public._t_is(public.get_jeongseok_access_v1(:alice::uuid) ->> 'via', 'INHA_MAIL', 'jeongseok alice via INHA_MAIL');
select public._t_throws($$select public.purchase_jeongseok_pass_v1('a1000000-0000-4000-8000-000000000001'::uuid, 'jeongseok.visitor.day', 'oracle-js-1')$$,
  'P0001', 'jeongseok alice has free access, purchase refused', 'FREE_ACCESS_ELIGIBLE');
select public._t_throws($$select public.purchase_jeongseok_pass_v1('a2000000-0000-4000-8000-000000000002'::uuid, 'nope', 'oracle-js-2')$$,
  '22023', 'jeongseok invalid pass type refused', 'INVALID_PASS_TYPE');
update private.world_wallets set balance = 500 where user_id = :bob::uuid and currency_id = 'currency.induck_coin';
select public._t_is(public.purchase_jeongseok_pass_v1(:bob::uuid, 'jeongseok.visitor.day', 'oracle-js-3') ->> 'status', 'SUCCESS', 'jeongseok bob purchase succeeds');
select public._t_is((public.purchase_jeongseok_pass_v1(:bob::uuid, 'jeongseok.visitor.day', 'oracle-js-3') ->> 'status'), 'ALREADY_PROCESSED', 'jeongseok same key replays as ALREADY_PROCESSED');
select public._t_is((select balance from private.world_wallets where user_id = :bob::uuid and currency_id = 'currency.induck_coin'), 400::bigint, 'jeongseok replay does not debit again (500 - 100 = 400)');
select public._t_is((select count(*) from private.world_jeongseok_pass_purchases where user_id = :bob::uuid and idempotency_key = 'oracle-js-3'), 1::bigint, 'jeongseok replay adds no purchase row');
select public._t_throws($$select public.purchase_jeongseok_pass_v1('a2000000-0000-4000-8000-000000000002'::uuid, 'jeongseok.visitor.week', 'oracle-js-3')$$,
  '23505', 'jeongseok same key different pass type conflicts (replay check precedes pass validation)', 'IDEMPOTENCY_CONFLICT');
select public._t_throws($$select public.purchase_jeongseok_pass_v1('a2000000-0000-4000-8000-000000000002'::uuid, 'jeongseok.visitor.day', 'oracle-js-4')$$,
  'P0001', 'jeongseok bob already has an active pass', 'PASS_ALREADY_ACTIVE');
select public._t_is(public.get_jeongseok_access_v1(:bob::uuid) ->> 'decision', 'GRANTED', 'jeongseok bob granted after purchase');
select public._t_is(public.get_jeongseok_access_v1(:bob::uuid) ->> 'via', 'VISITOR_PASS', 'jeongseok bob via VISITOR_PASS');
select public._t_is((select count(*) from private.world_jeongseok_pass_entitlements where user_id = :bob::uuid), 1::bigint, 'jeongseok bob has 1 entitlement');
-- revert the fixture activation: the committed seed state stays COMING_SOON
update private.world_jeongseok_gate_policy set status = 'COMING_SOON' where singleton;
update private.world_jeongseok_pass_catalog set status = 'COMING_SOON' where pass_type = 'jeongseok.visitor.day';
select public._t_is(public.get_jeongseok_access_v1(:alice::uuid) ->> 'decision', 'COMING_SOON', 'jeongseok gate reverted to COMING_SOON');

-- =====================================================================
-- personal room: ensure (idempotent create) + visibility
-- =====================================================================
select public._t_is(public.get_or_create_my_personal_room_v1(:alice::uuid) ->> 'ownerUserId', 'a1000000-0000-4000-8000-000000000001', 'personal room alice owner');
select public._t_is(public.get_or_create_my_personal_room_v1(:alice::uuid) ->> 'roomType', 'DORM_1_BASIC', 'personal room type DORM_1_BASIC');
select public._t_is(public.get_or_create_my_personal_room_v1(:alice::uuid) ->> 'visibility', 'friends', 'personal room default visibility friends');
select public._t_is(public.get_or_create_my_personal_room_v1(:alice::uuid) ->> 'roomId',
  public.get_or_create_my_personal_room_v1(:alice::uuid) ->> 'roomId', 'personal room ensure is idempotent (same room)');
select public._t_is((select count(*) from public.world_player_rooms where owner_user_id = :alice::uuid), 1::bigint, 'personal room alice has 1 room row');
select public._t_is(public.get_or_create_my_personal_room_v1(:bob::uuid) ->> 'ownerUserId', 'a2000000-0000-4000-8000-000000000002', 'personal room bob owner');
select public._t_is(public.get_or_create_my_personal_room_v1(:carol::uuid) ->> 'ownerUserId', 'a5000000-0000-4000-8000-000000000005', 'personal room carol owner');
select public._t_is(public.get_or_create_my_personal_room_v1(:noprofile::uuid) ->> 'ownerUserId', 'a4000000-0000-4000-8000-000000000004', 'personal room guest-open: no profile still gets a room');
select public._t_is(public.set_my_personal_room_visibility_v1(:alice::uuid, 'private') ->> 'visibility', 'private', 'personal room alice set private');
select public._t_is(public.set_my_personal_room_visibility_v1(:alice::uuid, 'private') ->> 'visibility', 'private', 'personal room same visibility is a no-op success');
select public._t_throws($$select public.set_my_personal_room_visibility_v1('a1000000-0000-4000-8000-000000000001'::uuid, 'public')$$,
  '22023', 'personal room invalid visibility refused', 'INVALID_VISIBILITY');
select public._t_throws(format($$select public.set_my_personal_room_visibility_v1(%L::uuid, 'friends')$$, :stranger),
  '42501', 'personal room unknown session refused first', 'ACCOUNT_UNAVAILABLE');
select public._t_throws(format($$select public.set_my_personal_room_visibility_v1(%L::uuid, 'friends')$$, :banned),
  'P0002', 'personal room session without a room -> not found', 'ROOM_NOT_FOUND');
select public._t_is(public.set_my_personal_room_visibility_v1(:bob::uuid, 'friends') ->> 'visibility', 'friends', 'personal room bob set friends');

-- =====================================================================
-- furniture: revision rules + owner check (DO block: room id is carried)
-- =====================================================================
do $do$
declare
  v_alice constant uuid := 'a1000000-0000-4000-8000-000000000001';
  v_bob constant uuid := 'a2000000-0000-4000-8000-000000000002';
  v_room uuid;
  v_chair0 jsonb := '[{"id":"f1000000-0000-4000-8000-000000000001","itemId":"furniture.induck_chair","surface":"floor","x":0,"z":0,"yaw":0}]'::jsonb;
  v_chair1 jsonb := '[{"id":"f1000000-0000-4000-8000-000000000001","itemId":"furniture.induck_chair","surface":"floor","x":1,"z":0,"yaw":0}]'::jsonb;
  v_both jsonb := '[{"id":"f1000000-0000-4000-8000-000000000001","itemId":"furniture.induck_chair","surface":"floor","x":1,"z":0,"yaw":0},{"id":"f2000000-0000-4000-8000-000000000002","itemId":"furniture.cooking_station","surface":"floor","x":3,"z":0,"yaw":0}]'::jsonb;
  v_bad jsonb := '[{"id":"f1000000-0000-4000-8000-000000000001","itemId":"furniture.induck_chair","surface":"wall","x":0,"z":0,"yaw":0}]'::jsonb;
  v_got jsonb;
begin
  v_room := (select id from public.world_player_rooms where owner_user_id = v_alice);
  v_got := public.get_world_room_furniture_v1(v_alice, v_room);
  perform public._t_is(v_got ->> 'role', 'owner', 'furniture alice is owner');
  perform public._t_is((v_got ->> 'revision')::int, 0, 'furniture revision 0 before save');
  perform public._t_is(jsonb_array_length(v_got -> 'objects'), 0, 'furniture no objects before save');
  v_got := public.save_my_room_furniture_v1(v_alice, v_room, 0, v_chair0);
  perform public._t_is((v_got ->> 'revision')::int, 1, 'furniture save rev 0 -> 1');
  perform public._t_throws(format($$select public.save_my_room_furniture_v1(%L::uuid, %L::uuid, 0, %L::jsonb)$$, v_alice, v_room, v_chair1),
    '40001', 'furniture stale revision refused', 'LAYOUT_CONFLICT');
  v_got := public.save_my_room_furniture_v1(v_alice, v_room, 0, v_chair0);
  perform public._t_is((v_got ->> 'revision')::int, 1, 'furniture identical retry does not bump revision');
  v_got := public.save_my_room_furniture_v1(v_alice, v_room, 1, v_chair1);
  perform public._t_is((v_got ->> 'revision')::int, 2, 'furniture save rev 1 -> 2');
  v_got := public.save_my_room_furniture_v1(v_alice, v_room, 2, v_both);
  perform public._t_is((v_got ->> 'revision')::int, 3, 'furniture save rev 2 -> 3 (chair + cooking station)');
  perform public._t_throws(format($$select public.save_my_room_furniture_v1(%L::uuid, %L::uuid, 3, %L::jsonb)$$, v_bob, v_room, v_both),
    '42501', 'furniture bob cannot save alice room (private)', 'LAYOUT_DENIED');
  perform public._t_throws(format($$select public.get_world_room_furniture_v1(%L::uuid, %L::uuid)$$, v_bob, v_room),
    '42501', 'furniture bob cannot read alice private room', 'LAYOUT_DENIED');
  perform public._t_throws(format($$select public.save_my_room_furniture_v1(%L::uuid, %L::uuid, 3, %L::jsonb)$$, v_alice, v_room, v_bad),
    '22023', 'furniture bad surface refused', 'INVALID_LAYOUT');
  perform public._t_throws(format($$select public.save_my_room_furniture_v1(%L::uuid, %L::uuid, -1, %L::jsonb)$$, v_alice, v_room, v_both),
    '22023', 'furniture negative revision refused', 'INVALID_LAYOUT');
  v_got := public.get_world_room_furniture_v1(v_alice, v_room);
  perform public._t_is((v_got ->> 'revision')::int, 3, 'furniture final revision 3');
  perform public._t_is(jsonb_array_length(v_got -> 'objects'), 2, 'furniture final objects 2');
end
$do$;

-- =====================================================================
-- cooking: seed-gated RECIPE_UNAVAILABLE, then fixture-activated cook + replay
-- =====================================================================
do $do$
declare
  v_alice constant uuid := 'a1000000-0000-4000-8000-000000000001';
  v_bob constant uuid := 'a2000000-0000-4000-8000-000000000002';
  v_req constant uuid := 'c2000000-0000-4000-8000-000000000001';
  v_r1 jsonb; v_r2 jsonb;
begin
  perform public._t_throws(format($$select public.cook_my_world_recipe_v1(%L::uuid, 'recipe.carp_grill', %L::uuid)$$, v_alice, v_req),
    'P0001', 'cooking seed recipe COMING_SOON', 'RECIPE_UNAVAILABLE');
  update private.world_recipe_catalog set status = 'ACTIVE' where recipe_id = 'recipe.carp_grill';
  perform public._t_throws(format($$select public.cook_my_world_recipe_v1(%L::uuid, 'recipe.carp_grill', %L::uuid)$$, v_bob, v_req),
    '42501', 'cooking bob has no station in his room', 'COOKING_STATION_REQUIRED');
  v_r1 := public.cook_my_world_recipe_v1(v_alice, 'recipe.carp_grill', v_req);
  perform public._t_is(v_r1 ->> 'status', 'SUCCESS', 'cooking alice carp grill succeeds');
  perform public._t_is(v_r1 ->> 'recipeId', 'recipe.carp_grill', 'cooking receipt recipe id');
  perform public._t_is(v_r1 ->> 'requestId', v_req::text, 'cooking receipt request id');
  perform public._t_is((v_r1 ->> 'layoutRevision')::int, 3, 'cooking receipt layout revision 3');
  perform public._t_is((select quantity from private.world_player_items where user_id = v_alice and item_id = 'material.fish_carp'), 2, 'cooking consumes 1 carp (3 -> 2)');
  perform public._t_is((select quantity from private.world_player_items where user_id = v_alice and item_id = 'consumable.grilled_carp'), 1, 'cooking grants 1 grilled carp');
  v_r2 := public.cook_my_world_recipe_v1(v_alice, 'recipe.carp_grill', v_req);
  perform public._t_is(v_r2, v_r1, 'cooking replay returns the identical receipt');
  perform public._t_is((select quantity from private.world_player_items where user_id = v_alice and item_id = 'material.fish_carp'), 2, 'cooking replay consumes nothing more');
  perform public._t_throws(format($$select public.cook_my_world_recipe_v1(%L::uuid, 'recipe.other_x', %L::uuid)$$, v_alice, v_req),
    '23505', 'cooking same request id different recipe conflicts', 'IDEMPOTENCY_CONFLICT');
  perform public._t_throws(format($$select public.cook_my_world_recipe_v1(%L::uuid, 'recipe.carp_grill', null)$$, v_alice),
    '22023', 'cooking null request id refused', 'INVALID_RECIPE_REQUEST');
  update private.world_recipe_catalog set status = 'COMING_SOON' where recipe_id = 'recipe.carp_grill';
end
$do$;

-- =====================================================================
-- room knock: polling flow (OPEN -> PENDING -> ACCEPTED / DECLINED, expiry,
-- rate limit). DO block: knock ids are carried between calls.
-- =====================================================================
do $do$
declare
  v_alice constant uuid := 'a1000000-0000-4000-8000-000000000001';
  v_bob constant uuid := 'a2000000-0000-4000-8000-000000000002';
  v_carol constant uuid := 'a5000000-0000-4000-8000-000000000005';
  v_noprofile constant uuid := 'a4000000-0000-4000-8000-000000000004';
  v_bob_room uuid; v_carol_room uuid;
  v_k jsonb; v_list jsonb; v_kid uuid; v_expired uuid := 'd1000000-0000-4000-8000-000000000001';
begin
  v_bob_room := (select id from public.world_player_rooms where owner_user_id = v_bob);
  v_carol_room := (select id from public.world_player_rooms where owner_user_id = v_carol);
  -- profile / target gates
  perform public._t_throws(format($$select public.knock_friend_personal_room_v1(%L::uuid, %L::uuid)$$, v_noprofile, v_bob),
    '42501', 'knock no-profile cannot knock', 'PROFILE_NOT_FOUND');
  perform public._t_throws(format($$select public.knock_friend_personal_room_v1(%L::uuid, %L::uuid)$$, v_alice, v_noprofile),
    '22023', 'knock target without profile is unavailable', 'TARGET_UNAVAILABLE');
  perform public._t_throws(format($$select public.knock_friend_personal_room_v1(%L::uuid, %L::uuid)$$, v_alice, v_alice),
    '22023', 'knock self is unavailable', 'TARGET_UNAVAILABLE');
  -- owner away: OPEN admission, 2 h (alice -> bob)
  v_k := public.knock_friend_personal_room_v1(v_alice, v_bob);
  perform public._t_is(v_k ->> 'status', 'OPEN', 'knock alice->bob OPEN (owner away)');
  perform public._t_is((v_k ->> 'ownerPresent')::boolean, false, 'knock owner away');
  v_kid := (v_k ->> 'knockId')::uuid;
  v_k := public.knock_friend_personal_room_v1(v_alice, v_bob);
  perform public._t_is((v_k ->> 'knockId')::uuid, v_kid, 'knock repeat reuses the OPEN admission');
  -- owner polls (heartbeat): OPEN is not a pending knock
  v_list := public.list_my_room_knocks_v1(v_bob);
  perform public._t_is(jsonb_array_length(v_list -> 'knocks'), 0, 'knock list empty while only OPEN');
  perform public._t_is((select count(*) from private.world_room_owner_presence where room_id = v_bob_room), 1::bigint, 'knock list writes owner presence (heartbeat)');
  -- PENDING + accept use a different pair (bob -> carol): carol polls first,
  -- so no OPEN admission exists yet for this pair
  perform public.list_my_room_knocks_v1(v_carol);
  v_k := public.knock_friend_personal_room_v1(v_bob, v_carol);
  perform public._t_is(v_k ->> 'status', 'PENDING', 'knock bob->carol PENDING (owner home, no admission yet)');
  perform public._t_is((v_k ->> 'ownerPresent')::boolean, true, 'knock owner home');
  v_kid := (v_k ->> 'knockId')::uuid;
  v_k := public.knock_friend_personal_room_v1(v_bob, v_carol);
  perform public._t_is((v_k ->> 'knockId')::uuid, v_kid, 'knock repeat reuses the PENDING knock');
  v_list := public.list_my_room_knocks_v1(v_carol);
  perform public._t_is(jsonb_array_length(v_list -> 'knocks'), 1, 'knock list has 1 pending');
  perform public._t_is(v_list -> 'knocks' -> 0 ->> 'visitorDisplayName', 'tier4bob', 'knock list visitor nickname');
  v_k := public.get_my_room_knock_v1(v_bob, v_kid);
  perform public._t_is(v_k ->> 'status', 'PENDING', 'knock get by visitor PENDING');
  -- owner accepts; a lost response may retry
  v_k := public.respond_room_knock_v1(v_carol, v_kid, true);
  perform public._t_is(v_k ->> 'status', 'ACCEPTED', 'knock respond accept');
  v_k := public.get_my_room_knock_v1(v_bob, v_kid);
  perform public._t_is(v_k ->> 'status', 'ACCEPTED', 'knock get after accept');
  v_k := public.respond_room_knock_v1(v_carol, v_kid, true);
  perform public._t_is(v_k ->> 'status', 'ACCEPTED', 'knock respond retry returns ACCEPTED unchanged');
  -- only the visitor may get it, only the owner may respond it
  perform public._t_throws(format($$select public.get_my_room_knock_v1(%L::uuid, %L::uuid)$$, v_alice, v_kid),
    'P0002', 'knock get by non-visitor refused', 'KNOCK_NOT_FOUND');
  perform public._t_throws(format($$select public.respond_room_knock_v1(%L::uuid, %L::uuid, true)$$, v_bob, v_kid),
    'P0002', 'knock respond by non-owner refused', 'KNOCK_NOT_FOUND');
  perform public._t_throws(format($$select public.respond_room_knock_v1(%L::uuid, %L::uuid, null)$$, v_carol, v_kid),
    '22023', 'knock respond null accept refused', 'INVALID_RESPONSE');
  -- decline flow with alice -> carol: carol polls first, alice knocks PENDING,
  -- carol declines, alice is blocked 10 min
  perform public.list_my_room_knocks_v1(v_carol);
  v_k := public.knock_friend_personal_room_v1(v_alice, v_carol);
  perform public._t_is(v_k ->> 'status', 'PENDING', 'knock alice->carol PENDING (owner home, no admission yet)');
  v_kid := (v_k ->> 'knockId')::uuid;
  v_k := public.respond_room_knock_v1(v_carol, v_kid, false);
  perform public._t_is(v_k ->> 'status', 'DECLINED', 'knock respond decline');
  perform public._t_throws(format($$select public.knock_friend_personal_room_v1(%L::uuid, %L::uuid)$$, v_alice, v_carol),
    '42501', 'knock after decline is blocked 10 min', 'VISIT_DECLINED');
  -- an expired PENDING knock answers EXPIRED
  insert into private.world_room_knocks (id, room_id, visitor_user_id, status, created_at, expires_at)
    values (v_expired, v_carol_room, v_alice, 'PENDING', now() - interval '2 minutes', now() - interval '1 minute');
  v_k := public.respond_room_knock_v1(v_carol, v_expired, true);
  perform public._t_is(v_k ->> 'status', 'EXPIRED', 'knock respond expired PENDING -> EXPIRED');
  -- rate limit: 5 knocks by carol to bob in the last 2 min -> the 6th is refused
  -- EXPIRED, not PENDING: the one_pending partial unique index allows only
  -- one PENDING row per (room, visitor). The rate-limit count has no status
  -- filter, so expired rows still count.
  insert into private.world_room_knocks (id, room_id, visitor_user_id, status, created_at, expires_at)
    select gen_random_uuid(), v_bob_room, v_carol, 'EXPIRED', now() - interval '90 seconds', now() - interval '60 seconds' from generate_series(1, 5);
  perform public.list_my_room_knocks_v1(v_bob);
  perform public._t_throws(format($$select public.knock_friend_personal_room_v1(%L::uuid, %L::uuid)$$, v_carol, v_bob),
    '54000', 'knock 6th in 2 min is rate limited', 'RATE_LIMITED');
  -- private room: alice set her room private, so carol cannot knock her
  perform public._t_throws(format($$select public.knock_friend_personal_room_v1(%L::uuid, %L::uuid)$$, v_carol, v_alice),
    '42501', 'knock private room refused', 'ROOM_PRIVATE');
end
$do$;

-- =====================================================================
-- A-3: daily quiz + life skills
-- (Tier 4 design: the quiz/life account gates are session-only — a
--  session without a profile still passes, unlike the origin. The
--  parity test records that as expected difference (a).)
-- =====================================================================
do $do$
declare
  v_alice uuid := 'a1000000-0000-4000-8000-000000000001'::uuid;
  v_bob uuid := 'a2000000-0000-4000-8000-000000000002'::uuid;
  v_banned uuid := 'a3000000-0000-4000-8000-000000000003'::uuid;
  v_noprofile uuid := 'a4000000-0000-4000-8000-000000000004'::uuid;
  v_q jsonb;
  v_s jsonb;
  v_run_id uuid;
  v_qids text[];
  v_q1 text; v_q2 text; v_q3 text;
  v_c1 int; v_c2 int; v_c3 int;
  v_w0 bigint; v_e0 bigint;
  v_rt uuid;
  v_expired uuid;
  v_l jsonb;
  v_t jsonb;
  v_u jsonb;
  v_r jsonb;
begin
  -- ---- daily quiz ----
  v_q := public.get_my_world_daily_quiz_v1(v_alice);
  perform public._t_is(v_q ->> 'status', 'AVAILABLE', 'quiz get AVAILABLE before start');
  perform public._t_is((v_q -> 'progress' ->> 'total')::int, 3, 'quiz total 3 questions');
  perform public._t_is((v_q -> 'progress' ->> 'answered')::int, 0, 'quiz answered 0 before start');
  perform public._t_is(v_q ->> 'rewardDate', to_char(now() at time zone 'Asia/Seoul', 'YYYY-MM-DD'), 'quiz rewardDate is KST today');
  perform public._t_is((select (e ->> 'amount')::int from jsonb_array_elements(v_q -> 'rewardPreview') e where e ->> 'targetId' = 'currency.induck_coin'), 50, 'quiz reward preview 50 coins');
  perform public._t_is((select (e ->> 'amount')::int from jsonb_array_elements(v_q -> 'rewardPreview') e where e ->> 'targetId' = 'exp.campus'), 25, 'quiz reward preview 25 exp');
  -- session-only gate: no-profile and banned sessions can still take the quiz (Tier 4 decision)
  perform public._t_is(public.get_my_world_daily_quiz_v1(v_noprofile) ->> 'status', 'AVAILABLE', 'quiz get noprofile succeeds (session-only gate)');
  perform public._t_is(public.get_my_world_daily_quiz_v1(v_banned) ->> 'status', 'AVAILABLE', 'quiz get banned succeeds (session-only gate)');
  -- start
  v_s := public.start_my_world_daily_quiz_v1(v_alice);
  v_run_id := (v_s ->> 'runId')::uuid;
  perform public._t_is(v_run_id is not null, true, 'quiz start returns runId');
  perform public._t_is(v_s ->> 'status', 'ACTIVE', 'quiz start ACTIVE');
  perform public._t_is((v_s -> 'question' ->> 'index')::int, 0, 'quiz start question index 0');
  perform public._t_is(jsonb_array_length(v_s -> 'question' -> 'options'), 4, 'quiz start 4 options');
  v_s := public.start_my_world_daily_quiz_v1(v_alice);
  perform public._t_is((v_s ->> 'runId')::uuid, v_run_id, 'quiz start twice returns same run');
  select question_ids into v_qids from private.world_daily_quiz_runs where run_id = v_run_id;
  v_q1 := v_qids[1]; v_q2 := v_qids[2]; v_q3 := v_qids[3];
  select correct_index into v_c1 from private.world_daily_quiz_questions where question_id = v_q1;
  select correct_index into v_c2 from private.world_daily_quiz_questions where question_id = v_q2;
  select correct_index into v_c3 from private.world_daily_quiz_questions where question_id = v_q3;
  -- wrong-question and invalid-index guards
  perform public._t_throws(format($$select public.answer_my_world_daily_quiz_v1(%L::uuid, %L::uuid, %L, %L::smallint)$$, v_alice, v_run_id, v_q2, v_c2),
    'P0001', 'quiz answer wrong question -> MISMATCH', 'QUIZ_QUESTION_MISMATCH');
  perform public._t_throws(format($$select public.answer_my_world_daily_quiz_v1(%L::uuid, %L::uuid, %L, 5::smallint)$$, v_alice, v_run_id, v_q1),
    '22023', 'quiz answer index 5 refused', 'INVALID_ANSWER');
  -- wallet/exp before the pass
  select balance into v_w0 from private.world_wallets where user_id = v_alice and currency_id = 'currency.induck_coin';
  select total_exp into v_e0 from private.world_player_progression where user_id = v_alice;
  -- Q1 correct
  v_s := public.answer_my_world_daily_quiz_v1(v_alice, v_run_id, v_q1, v_c1::smallint);
  perform public._t_is((v_s -> 'lastAnswer' ->> 'correct')::boolean, true, 'quiz Q1 correct');
  perform public._t_is((v_s -> 'progress' ->> 'answered')::int, 1, 'quiz answered 1 after Q1');
  perform public._t_is((v_s -> 'progress' ->> 'correct')::int, 1, 'quiz correct 1 after Q1');
  perform public._t_is(v_s ->> 'status', 'ACTIVE', 'quiz still ACTIVE after Q1');
  -- another account's run is indistinguishable from missing
  perform public._t_throws(format($$select public.answer_my_world_daily_quiz_v1(%L::uuid, %L::uuid, %L, %L::smallint)$$, v_bob, v_run_id, v_q2, v_c2),
    'P0001', 'quiz answer by other account refused', 'QUIZ_RUN_NOT_FOUND');
  -- Q2 wrong
  v_s := public.answer_my_world_daily_quiz_v1(v_alice, v_run_id, v_q2, ((v_c2 + 1) % 4)::smallint);
  perform public._t_is((v_s -> 'lastAnswer' ->> 'correct')::boolean, false, 'quiz Q2 wrong');
  perform public._t_is((v_s -> 'progress' ->> 'answered')::int, 2, 'quiz answered 2 after Q2');
  perform public._t_is((v_s -> 'progress' ->> 'correct')::int, 1, 'quiz correct still 1 after Q2');
  perform public._t_throws(format($$select public.answer_my_world_daily_quiz_v1(%L::uuid, %L::uuid, %L, %L::smallint)$$, v_alice, v_run_id, v_q2, v_c2),
    'P0001', 'quiz re-answer Q2 refused', 'QUIZ_ALREADY_ANSWERED');
  -- Q3 correct -> PASSED (2/3) + reward
  v_s := public.answer_my_world_daily_quiz_v1(v_alice, v_run_id, v_q3, v_c3::smallint);
  perform public._t_is(v_s ->> 'status', 'PASSED', 'quiz PASSED with 2/3 correct');
  perform public._t_is((v_s -> 'progress' ->> 'correct')::int, 2, 'quiz correct 2 at end');
  select reward_transaction_id into v_rt from private.world_daily_quiz_runs where run_id = v_run_id;
  perform public._t_is(v_rt is not null, true, 'quiz PASSED stores reward transaction');
  perform public._t_is((select balance from private.world_wallets where user_id = v_alice and currency_id = 'currency.induck_coin'), v_w0 + 50, 'quiz reward +50 coins');
  perform public._t_is((select total_exp from private.world_player_progression where user_id = v_alice), v_e0 + 25, 'quiz reward +25 exp');
  perform public._t_throws(format($$select public.answer_my_world_daily_quiz_v1(%L::uuid, %L::uuid, %L, %L::smallint)$$, v_alice, v_run_id, v_q3, v_c3),
    'P0001', 'quiz answer after completion refused', 'QUIZ_ALREADY_ANSWERED');
  v_q := public.get_my_world_daily_quiz_v1(v_alice);
  perform public._t_is(v_q ->> 'status', 'PASSED', 'quiz get PASSED after completion');
  -- an expired run (yesterday) answers EXPIRED
  insert into private.world_daily_quiz_runs (user_id, reward_date, question_ids)
  select v_bob, ((now() at time zone 'Asia/Seoul')::date - 1), array_agg(q.question_id)
    from (select question_id from private.world_daily_quiz_questions where status = 'ACTIVE' limit 3) q;
  select run_id into v_expired from private.world_daily_quiz_runs
   where user_id = v_bob and reward_date = ((now() at time zone 'Asia/Seoul')::date - 1);
  perform public._t_throws(format($$select public.answer_my_world_daily_quiz_v1(%L::uuid, %L::uuid, %L, 0::smallint)$$, v_bob, v_expired, v_q1),
    'P0001', 'quiz expired run refused', 'QUIZ_RUN_EXPIRED');

  -- ---- life skills ----
  -- seed 300 fishing XP for alice (level 3, earned SP 2); no XP-ledger table in Tier 4
  insert into private.world_player_life_skills (user_id, skill_id, total_xp, version)
  values (v_alice, 'life.fishing', 300, 1);
  v_l := public.get_my_world_life_skills_v1(v_alice);
  perform public._t_is((select (s ->> 'level')::int from jsonb_array_elements(v_l -> 'skills') s where s ->> 'skillId' = 'life.fishing'), 3, 'life fishing level 3 at 300 XP');
  perform public._t_is((select (s ->> 'totalXp')::int from jsonb_array_elements(v_l -> 'skills') s where s ->> 'skillId' = 'life.fishing'), 300, 'life fishing totalXp 300');
  perform public._t_is((select (s -> 'sp' ->> 'available')::int from jsonb_array_elements(v_l -> 'skills') s where s ->> 'skillId' = 'life.fishing'), 2, 'life fishing availableSp 2');
  perform public._t_is((v_l -> 'lifeLevel' ->> 'level')::int, 1, 'life level 1 (only level 1 threshold seeded)');
  perform public._t_is((public.get_my_world_life_skills_v1(v_noprofile) -> 'lifeLevel' ->> 'level')::int, 1, 'life skills noprofile succeeds (session-only gate)');
  v_t := public.get_my_world_life_skill_tree_v1(v_alice, 'life.fishing');
  perform public._t_is(jsonb_array_length(v_t -> 'nodes'), 2, 'life fishing tree 2 nodes (book view shows ACTIVE only)');
  perform public._t_is((select (n ->> 'canUnlock')::boolean from jsonb_array_elements(v_t -> 'nodes') n where n ->> 'nodeId' = 'life.node.fishing.steady_hands'), true, 'life steady_hands canUnlock');
  perform public._t_is((select n ->> 'lockReason' from jsonb_array_elements(v_t -> 'nodes') n where n ->> 'nodeId' = 'life.node.fishing.fish_sense'), 'PREREQUISITE', 'life fish_sense locked by prerequisite');
  perform public._t_is((v_t -> 'reset' ->> 'canReset')::boolean, false, 'life reset blocked on empty tree');
  perform public._t_is(v_t -> 'reset' ->> 'resetBlockedBy', 'EMPTY', 'life reset blockedBy EMPTY');
  perform public._t_throws(format($$select public.get_my_world_life_skill_tree_v1(%L::uuid, 'life.nope')$$, v_alice),
    'P0002', 'life tree unknown skill refused', 'LIFE_SKILL_NOT_FOUND');
  -- unlock steady_hands (skill 2, no prereq, cost 1)
  v_u := public.unlock_my_world_life_node_v1(v_alice, 'life.node.fishing.steady_hands', 'e1000000-0000-4000-8000-000000000101'::uuid);
  perform public._t_is(v_u ->> 'status', 'SUCCESS', 'life unlock steady_hands SUCCESS');
  perform public._t_is((v_u ->> 'rankAfter')::int, 1, 'life unlock steady_hands rank 1');
  perform public._t_is((select (s -> 'sp' ->> 'available')::int from jsonb_array_elements(public.get_my_world_life_skills_v1(v_alice) -> 'skills') s where s ->> 'skillId' = 'life.fishing'), 1, 'life availableSp 1 after steady_hands');
  v_u := public.unlock_my_world_life_node_v1(v_alice, 'life.node.fishing.steady_hands', 'e1000000-0000-4000-8000-000000000101'::uuid);
  perform public._t_is(v_u ->> 'status', 'ALREADY_PROCESSED', 'life unlock replay same key ALREADY_PROCESSED');
  perform public._t_is((v_u ->> 'rankAfter')::int, 1, 'life unlock replay rankAfter 1');
  perform public._t_throws(format($$select public.unlock_my_world_life_node_v1(%L::uuid, 'life.node.fishing.fish_sense', 'e1000000-0000-4000-8000-000000000101'::uuid)$$, v_alice),
    '23505', 'life unlock same key other node -> conflict', 'IDEMPOTENCY_CONFLICT');
  -- fish_sense prereq (steady_hands 1) now met
  v_u := public.unlock_my_world_life_node_v1(v_alice, 'life.node.fishing.fish_sense', 'e1000000-0000-4000-8000-000000000102'::uuid);
  perform public._t_is(v_u ->> 'status', 'SUCCESS', 'life unlock fish_sense SUCCESS');
  perform public._t_is((select (s -> 'sp' ->> 'available')::int from jsonb_array_elements(public.get_my_world_life_skills_v1(v_alice) -> 'skills') s where s ->> 'skillId' = 'life.fishing'), 0, 'life availableSp 0 after fish_sense');
  perform public._t_throws(format($$select public.unlock_my_world_life_node_v1(%L::uuid, 'life.node.fishing.fish_sense', 'e1000000-0000-4000-8000-000000000103'::uuid)$$, v_alice),
    'P0001', 'life unlock with 0 SP left refused', 'LIFE_SP_INSUFFICIENT');
  perform public._t_throws(format($$select public.unlock_my_world_life_node_v1(%L::uuid, 'life.node.fishing.baitcraft', 'e1000000-0000-4000-8000-000000000104'::uuid)$$, v_alice),
    'P0002', 'life unlock COMING_SOON node refused (wrapper pre-check)', 'LIFE_NODE_NOT_FOUND');
  perform public._t_throws(format($$select public.unlock_my_world_life_node_v1(%L::uuid, 'life.node.fishing.nope', 'e1000000-0000-4000-8000-000000000105'::uuid)$$, v_alice),
    'P0002', 'life unlock unknown node refused', 'LIFE_NODE_NOT_FOUND');
  perform public._t_throws(format($$select public.unlock_my_world_life_node_v1(%L::uuid, 'bad-id', 'e1000000-0000-4000-8000-000000000106'::uuid)$$, v_alice),
    'P0002', 'life unlock malformed node id refused (wrapper pre-check)', 'LIFE_NODE_NOT_FOUND');
  perform public._t_throws(format($$select public.unlock_my_world_life_node_v1(%L::uuid, 'life.node.fishing.steady_hands', 'e1000000-0000-4000-8000-000000000107'::uuid)$$, v_bob),
    'P0001', 'life unlock bob skill level 1 < 2 refused', 'LIFE_SKILL_LEVEL_REQUIRED');
  -- reset: refund 2 SP, clear both ranks
  v_r := public.reset_my_world_life_tree_v1(v_alice, 'life.fishing', 'e1000000-0000-4000-8000-000000000201'::uuid);
  perform public._t_is(v_r ->> 'status', 'SUCCESS', 'life reset SUCCESS');
  perform public._t_is((v_r ->> 'refundedSp')::int, 2, 'life reset refundedSp 2');
  perform public._t_is((select jsonb_array_length(cleared_ranks) from private.world_life_tree_resets where user_id = v_alice and skill_id = 'life.fishing'), 2, 'life reset row cleared 2 nodes');
  perform public._t_is((select epoch from private.world_life_tree_resets where user_id = v_alice and skill_id = 'life.fishing'), 1, 'life reset epoch 1');
  v_r := public.reset_my_world_life_tree_v1(v_alice, 'life.fishing', 'e1000000-0000-4000-8000-000000000201'::uuid);
  perform public._t_is(v_r ->> 'status', 'ALREADY_PROCESSED', 'life reset replay same key ALREADY_PROCESSED');
  v_t := public.get_my_world_life_skill_tree_v1(v_alice, 'life.fishing');
  perform public._t_is((select (n ->> 'rank')::int from jsonb_array_elements(v_t -> 'nodes') n where n ->> 'nodeId' = 'life.node.fishing.steady_hands'), 0, 'life tree rank 0 after reset');
  perform public._t_is((select (n ->> 'rank')::int from jsonb_array_elements(v_t -> 'nodes') n where n ->> 'nodeId' = 'life.node.fishing.fish_sense'), 0, 'life fish_sense rank 0 after reset');
  perform public._t_is((select (s -> 'sp' ->> 'available')::int from jsonb_array_elements(public.get_my_world_life_skills_v1(v_alice) -> 'skills') s where s ->> 'skillId' = 'life.fishing'), 2, 'life availableSp 2 after reset');
  perform public._t_throws(format($$select public.reset_my_world_life_tree_v1(%L::uuid, 'life.fishing', 'e1000000-0000-4000-8000-000000000202'::uuid)$$, v_alice),
    'P0001', 'life reset empty tree refused', 'LIFE_TREE_RESET_EMPTY');
  -- cooldown: unlock once, then reset again inside 86400s
  v_u := public.unlock_my_world_life_node_v1(v_alice, 'life.node.fishing.steady_hands', 'e1000000-0000-4000-8000-000000000108'::uuid);
  perform public._t_is(v_u ->> 'status', 'SUCCESS', 'life unlock after reset SUCCESS');
  perform public._t_throws(format($$select public.reset_my_world_life_tree_v1(%L::uuid, 'life.fishing', 'e1000000-0000-4000-8000-000000000203'::uuid)$$, v_alice),
    'P0001', 'life reset inside cooldown refused', 'LIFE_TREE_RESET_COOLDOWN');
  perform public._t_throws(format($$select public.reset_my_world_life_tree_v1(%L::uuid, 'life.nope', 'e1000000-0000-4000-8000-000000000204'::uuid)$$, v_alice),
    'P0002', 'life reset unknown skill refused', 'LIFE_SKILL_NOT_FOUND');
  perform public._t_throws(format($$select public.reset_my_world_life_tree_v1(%L::uuid, 'bad', 'e1000000-0000-4000-8000-000000000205'::uuid)$$, v_alice),
    'P0002', 'life reset malformed skill id refused (visible-skill check)', 'LIFE_SKILL_NOT_FOUND');
end
$do$;

-- =====================================================================
-- A-3: social + accompany
-- =====================================================================
do $do$
declare
  v_alice uuid := 'a1000000-0000-4000-8000-000000000001'::uuid;
  v_bob uuid := 'a2000000-0000-4000-8000-000000000002'::uuid;
  v_banned uuid := 'a3000000-0000-4000-8000-000000000003'::uuid;
  v_noprofile uuid := 'a4000000-0000-4000-8000-000000000004'::uuid;
  v_carol uuid := 'a5000000-0000-4000-8000-000000000005'::uuid;
  v_dave uuid := 'd6000000-0000-4000-8000-000000000006'::uuid;
  v_stranger uuid := 'a9000000-0000-4000-8000-000000000009'::uuid;
  v_s jsonb;
  v_a jsonb;
  v_sid uuid;
begin
  -- ---- social ----
  v_s := public.get_my_world_social(v_alice);
  perform public._t_is(jsonb_array_length(v_s -> 'friends'), 2, 'social alice friends 2 (bob, carol)');
  perform public._t_is(v_s::text like '%tier4bob%', true, 'social alice friends contain bob');
  perform public._t_is(v_s::text like '%tier4carol%', true, 'social alice friends contain carol');
  perform public._t_is(jsonb_array_length(v_s -> 'incoming'), 0, 'social alice incoming 0');
  perform public._t_is(jsonb_array_length(v_s -> 'outgoing'), 0, 'social alice outgoing 0');
  v_s := public.get_world_public_profile(v_alice, v_bob);
  perform public._t_is((v_s ->> 'available')::boolean, true, 'public profile bob available');
  perform public._t_is(v_s ->> 'relationship', 'friends', 'public profile bob relationship friends');
  perform public._t_is(v_s ->> 'nickname', 'tier4bob', 'public profile bob nickname');
  perform public._t_is((v_s ->> 'inhaVerified')::boolean, false, 'public profile bob inhaVerified false');
  v_s := public.get_world_public_profile(v_alice, v_carol);
  perform public._t_is((v_s ->> 'inhaVerified')::boolean, false, 'public profile carol inhaVerified false (badges-only card, no badge row)');
  perform public._t_throws(format($$select public.get_world_public_profile(%L::uuid, %L::uuid)$$, v_alice, v_alice),
    '22023', 'public profile self refused', 'TARGET_UNAVAILABLE');
  perform public._t_throws(format($$select public.get_world_public_profile(%L::uuid, %L::uuid)$$, v_alice, v_stranger),
    '22023', 'public profile stranger refused', 'TARGET_UNAVAILABLE');
  perform public._t_throws(format($$select public.get_world_public_profile(%L::uuid, %L::uuid)$$, v_alice, v_banned),
    '22023', 'public profile banned refused', 'TARGET_UNAVAILABLE');
  perform public._t_is(public.get_world_relationship(v_alice, v_bob) ->> 'relationship', 'friends', 'relationship alice-bob friends');
  perform public._t_is(public.get_world_relationship(v_alice, v_dave) ->> 'relationship', 'none', 'relationship alice-dave none');
  perform public._t_throws(format($$select public.get_my_world_social(%L::uuid)$$, v_noprofile),
    '42501', 'social noprofile -> PROFILE_NOT_FOUND', 'PROFILE_NOT_FOUND');
  perform public._t_throws(format($$select public.get_my_world_social(%L::uuid)$$, v_banned),
    '42501', 'social banned -> PROFILE_NOT_FOUND', 'PROFILE_NOT_FOUND');
  -- friend request lifecycle with dave
  v_s := public.send_world_friend_request(v_alice, v_dave);
  perform public._t_is(v_s ->> 'relationship', 'outgoing', 'friend send alice->dave outgoing');
  v_s := public.send_world_friend_request(v_alice, v_dave);
  perform public._t_is(v_s ->> 'relationship', 'outgoing', 'friend send duplicate stays outgoing');
  v_s := public.get_my_world_social(v_dave);
  perform public._t_is(jsonb_array_length(v_s -> 'incoming'), 1, 'social dave incoming 1');
  perform public._t_is(v_s::text like '%tier4alice%', true, 'social dave incoming is alice');
  v_s := public.respond_world_friend_request(v_dave, v_alice, true);
  perform public._t_is(v_s ->> 'relationship', 'friends', 'friend respond accept -> friends');
  perform public._t_is(public.get_world_relationship(v_alice, v_dave) ->> 'relationship', 'friends', 'relationship alice-dave friends after accept');
  v_s := public.send_world_friend_request(v_alice, v_dave);
  perform public._t_is(v_s ->> 'relationship', 'friends', 'friend send to existing friend returns friends');
  v_s := public.remove_world_friend(v_alice, v_dave);
  perform public._t_is(v_s ->> 'relationship', 'none', 'friend remove -> none');
  v_s := public.send_world_friend_request(v_alice, v_dave);
  perform public._t_is(v_s ->> 'relationship', 'outgoing', 'friend send again outgoing');
  v_s := public.cancel_world_friend_request(v_alice, v_dave);
  perform public._t_is(v_s ->> 'relationship', 'none', 'friend cancel -> none');
  v_s := public.send_world_friend_request(v_alice, v_dave);
  v_s := public.respond_world_friend_request(v_dave, v_alice, false);
  perform public._t_is(v_s ->> 'relationship', 'none', 'friend respond decline -> none');
  v_s := public.respond_world_friend_request(v_bob, v_alice, true);
  perform public._t_is(v_s ->> 'relationship', 'friends', 'friend respond with no pending returns current relationship');
  perform public._t_throws(format($$select public.respond_world_friend_request(%L::uuid, %L::uuid, null)$$, v_alice, v_dave),
    '22023', 'friend respond null accept refused', 'INVALID_ARGUMENT');
  perform public._t_throws(format($$select public.send_world_friend_request(%L::uuid, %L::uuid)$$, v_alice, v_alice),
    '22023', 'friend send to self refused', 'TARGET_UNAVAILABLE');
  -- report
  v_s := public.report_world_user(v_alice, v_dave, 'spam', null);
  perform public._t_is(v_s ->> 'status', 'received', 'report spam received');
  v_s := public.report_world_user(v_alice, v_dave, 'spam', null);
  perform public._t_is(v_s ->> 'status', 'duplicate', 'report same category in 24h duplicate');
  v_s := public.report_world_user(v_alice, v_dave, 'other', 'AREA_MAIN_GATE');
  perform public._t_is(v_s ->> 'status', 'received', 'report other category with zone received');
  perform public._t_throws(format($$select public.report_world_user(%L::uuid, %L::uuid, 'bogus', null)$$, v_alice, v_dave),
    '22023', 'report bad category refused', 'INVALID_CATEGORY');
  perform public._t_throws(format($$select public.report_world_user(%L::uuid, %L::uuid, 'spam', null)$$, v_alice, v_alice),
    '22023', 'report self refused', 'CANNOT_REPORT_SELF');
  perform public._t_throws(format($$select public.report_world_user(%L::uuid, %L::uuid, 'spam', null)$$, v_alice, v_stranger),
    '22023', 'report stranger refused', 'TARGET_UNAVAILABLE');
  perform public._t_throws(format($$select public.report_world_user(%L::uuid, %L::uuid, 'spam', 'ZONE_X')$$, v_alice, v_dave),
    '22023', 'report bad zone refused', 'INVALID_PLACE_ZONE');
  -- block removes the friendship; unblock does not restore it
  v_s := public.send_world_friend_request(v_alice, v_dave);
  v_s := public.respond_world_friend_request(v_dave, v_alice, true);
  v_s := public.block_world_user(v_alice, v_dave);
  perform public._t_is(v_s ->> 'relationship', 'blocked_by_me', 'block -> blocked_by_me');
  perform public._t_is(jsonb_array_length(public.get_my_world_social(v_alice) -> 'friends'), 2, 'social alice friends back to 2 after block');
  v_s := public.get_world_public_profile(v_alice, v_dave);
  perform public._t_is((v_s ->> 'available')::boolean, true, 'public profile blocked_by_me still available');
  perform public._t_is(v_s ->> 'relationship', 'blocked_by_me', 'public profile blocked_by_me relationship');
  perform public._t_throws(format($$select public.send_world_friend_request(%L::uuid, %L::uuid)$$, v_alice, v_dave),
    '42501', 'friend send while blocked refused', 'NOT_ALLOWED');
  v_s := public.unblock_world_user(v_alice, v_dave);
  perform public._t_is(v_s ->> 'relationship', 'none', 'unblock -> none (friendship not restored)');
  -- blocked by the target: profile unavailable, send refused
  v_s := public.block_world_user(v_dave, v_alice);
  perform public._t_is(v_s ->> 'relationship', 'blocked_by_me', 'dave blocks alice');
  v_s := public.get_world_public_profile(v_alice, v_dave);
  perform public._t_is((v_s ->> 'available')::boolean, false, 'public profile unavailable when target blocked caller');
  perform public._t_is(v_s ->> 'relationship', 'unavailable', 'public profile relationship unavailable');
  perform public._t_throws(format($$select public.send_world_friend_request(%L::uuid, %L::uuid)$$, v_alice, v_dave),
    '42501', 'friend send when target blocked caller refused', 'NOT_ALLOWED');
  v_s := public.unblock_world_user(v_dave, v_alice);
  perform public._t_is(v_s ->> 'relationship', 'none', 'dave unblocks alice -> none');
  perform public._t_throws(format($$select public.block_world_user(%L::uuid, %L::uuid)$$, v_alice, v_alice),
    '22023', 'block self refused', 'TARGET_UNAVAILABLE');
  perform public._t_throws(format($$select public.unblock_world_user(%L::uuid, %L::uuid)$$, v_alice, v_alice),
    '22023', 'unblock self refused', 'TARGET_UNAVAILABLE');
  perform public._t_is(jsonb_array_length(public.get_my_world_social(v_dave) -> 'friends'), 0, 'social dave friends 0 at end');

  -- ---- accompany ----
  perform public._t_is(jsonb_array_length(public.get_my_world_accompany(v_alice)), 0, 'accompany alice empty at start');
  perform public._t_throws(format($$select public.propose_world_accompany(%L::uuid, %L::uuid, 'poi.main-gate', 'AREA_MAIN_GATE')$$, v_alice, v_dave),
    '42501', 'accompany propose to non-friend refused', 'NOT_ALLOWED');
  v_a := public.propose_world_accompany(v_alice, v_bob, 'poi.main-gate', 'AREA_MAIN_GATE');
  perform public._t_is(v_a ->> 'state', 'offered', 'accompany propose offered');
  v_sid := (v_a ->> 'id')::uuid;
  perform public._t_is(v_sid is not null, true, 'accompany propose returns id');
  v_a := public.propose_world_accompany(v_alice, v_bob, 'poi.main-gate', 'AREA_MAIN_GATE');
  perform public._t_is((v_a ->> 'id')::uuid, v_sid, 'accompany propose repeat returns same session');
  perform public._t_throws(format($$select public.propose_world_accompany(%L::uuid, %L::uuid, 'poi.main-hall', 'AREA_MAIN_HALL')$$, v_alice, v_carol),
    '42501', 'accompany propose while offered -> busy', 'ALREADY_BUSY');
  v_a := public.get_my_world_accompany(v_bob);
  perform public._t_is(jsonb_array_length(v_a), 1, 'accompany bob sees 1 offered session');
  perform public._t_is(v_a -> 0 ->> 'poiId', 'poi.main-gate', 'accompany session poi main-gate');
  perform public._t_is(v_a -> 0 ->> 'state', 'offered', 'accompany session state offered');
  perform public._t_throws(format($$select public.respond_world_accompany(%L::uuid, %L::uuid, true)$$, v_carol, v_sid),
    '22023', 'accompany respond by non-invitee refused', 'TARGET_UNAVAILABLE');
  v_a := public.respond_world_accompany(v_bob, v_sid, true);
  perform public._t_is(v_a ->> 'state', 'active', 'accompany respond accept -> active');
  v_a := public.respond_world_accompany(v_bob, v_sid, true);
  perform public._t_is(v_a ->> 'state', 'active', 'accompany respond accept replay stays active');
  perform public._t_throws(format($$select public.propose_world_accompany(%L::uuid, %L::uuid, 'poi.main-hall', 'AREA_MAIN_HALL')$$, v_alice, v_carol),
    '42501', 'accompany propose while active -> busy', 'ALREADY_BUSY');
  v_a := public.end_world_accompany(v_bob, v_sid);
  perform public._t_is(v_a ->> 'state', 'ended', 'accompany end by invitee -> ended');
  v_a := public.end_world_accompany(v_alice, v_sid);
  perform public._t_is(v_a ->> 'state', 'ended', 'accompany end replay -> ended');
  perform public._t_is(jsonb_array_length(public.get_my_world_accompany(v_alice)), 0, 'accompany alice empty after end');
  perform public._t_throws(format($$select public.end_world_accompany(%L::uuid, %L::uuid)$$, v_carol, v_sid),
    '22023', 'accompany end by non-participant refused', 'TARGET_UNAVAILABLE');
  perform public._t_throws(format($$select public.propose_world_accompany(%L::uuid, %L::uuid, 'poi.nope', 'AREA_MAIN_GATE')$$, v_alice, v_bob),
    '22023', 'accompany bad poi refused', 'INVALID_DESTINATION');
  perform public._t_throws(format($$select public.propose_world_accompany(%L::uuid, %L::uuid, 'poi.main-gate', 'ZONE')$$, v_alice, v_bob),
    '22023', 'accompany bad zone refused', 'INVALID_PLACE_ZONE');
  perform public._t_throws(format($$select public.propose_world_accompany(%L::uuid, %L::uuid, 'poi.main-gate', 'AREA_MAIN_GATE')$$, v_alice, v_alice),
    '22023', 'accompany propose to self refused', 'TARGET_UNAVAILABLE');
  -- an expired offered session is gone from the list and cannot be answered
  insert into public.world_accompany_sessions (id, inviter_id, invitee_id, place_zone_id, poi_id, state, created_at, expires_at)
  values ('f1000000-0000-4000-8000-000000000001'::uuid, v_alice, v_bob, 'AREA_MAIN_GATE', 'poi.main-gate', 'offered', now() - interval '2 minutes', now() - interval '1 minute');
  perform public._t_is(jsonb_array_length(public.get_my_world_accompany(v_alice)), 0, 'accompany expired session not listed');
  perform public._t_throws(format($$select public.respond_world_accompany(%L::uuid, 'f1000000-0000-4000-8000-000000000001'::uuid, true)$$, v_bob),
    '22023', 'accompany respond expired refused', 'TARGET_UNAVAILABLE');
end
$do$;

-- =====================================================================
-- A-3: biryong progress + biryong/campus NPC relationships
-- =====================================================================
do $do$
declare
  v_alice uuid := 'a1000000-0000-4000-8000-000000000001'::uuid;
  v_noprofile uuid := 'a4000000-0000-4000-8000-000000000004'::uuid;
  v_p jsonb;
  v_r jsonb;
begin
  -- ---- biryong progress ----
  -- a fresh account has no progress row: get returns null (merge creates it)
  v_p := public.get_my_biryong_progress_v1(v_alice);
  perform public._t_is(v_p is null, true, 'biryong progress fresh returns null (no row yet)');
  v_p := public.merge_my_biryong_progress_v1(v_alice, '{"step":"FIND_CENTER","lore":["lore.a"],"shouts":2}'::jsonb, false);
  perform public._t_is(v_p ->> 'step', 'FIND_CENTER', 'biryong merge FIND_CENTER');
  perform public._t_is(v_p -> 'lore', '["lore.a"]'::jsonb, 'biryong merge lore [lore.a]');
  perform public._t_is((v_p ->> 'shouts')::int, 2, 'biryong merge shouts 2');
  perform public._t_is((v_p ->> 'discoveredAt')::bigint is not null, true, 'biryong merge discoveredAt set');
  v_p := public.merge_my_biryong_progress_v1(v_alice, '{"step":"INTRO","lore":["lore.b","lore.a"],"shouts":1}'::jsonb, false);
  perform public._t_is(v_p ->> 'step', 'FIND_CENTER', 'biryong merge older step keeps FIND_CENTER');
  perform public._t_is(v_p -> 'lore', '["lore.a","lore.b"]'::jsonb, 'biryong merge lore union sorted');
  perform public._t_is((v_p ->> 'shouts')::int, 2, 'biryong merge shouts keep max 2');
  v_p := public.merge_my_biryong_progress_v1(v_alice, '{"step":"SHOUT","lore":[],"shouts":5}'::jsonb, true);
  perform public._t_is(v_p ->> 'step', 'SHOUT', 'biryong merge SHOUT advances');
  perform public._t_is((v_p ->> 'shouts')::int, 5, 'biryong merge shouts 5');
  v_p := public.merge_my_biryong_progress_v1(v_alice, jsonb_build_object('step', 'COMPLETE', 'lore', jsonb_build_array('lore.c'), 'shouts', 3, 'completedAt', ((extract(epoch from now()) * 1000)::bigint)), false);
  perform public._t_is(v_p ->> 'step', 'COMPLETE', 'biryong merge COMPLETE');
  perform public._t_is((v_p ->> 'completedAt')::bigint is not null, true, 'biryong merge completedAt set');
  perform public._t_is((v_p ->> 'shouts')::int, 5, 'biryong merge shouts keep max 5 at COMPLETE');
  perform public._t_is(v_p -> 'lore', '["lore.a","lore.b","lore.c"]'::jsonb, 'biryong merge lore union 3');
  perform public._t_throws(format($$select public.merge_my_biryong_progress_v1(%L::uuid, '{"step":"BOGUS"}'::jsonb, false)$$, v_alice),
    '22023', 'biryong merge bad step refused', 'INVALID_BIRYONG_STEP');
  perform public._t_throws(format($$select public.merge_my_biryong_progress_v1(%L::uuid, null::jsonb, false)$$, v_alice),
    '22023', 'biryong merge null progress refused', 'INVALID_BIRYONG_PROGRESS');
  perform public._t_throws(format($$select public.merge_my_biryong_progress_v1(%L::uuid, '[]'::jsonb, false)$$, v_alice),
    '22023', 'biryong merge non-object refused', 'INVALID_BIRYONG_PROGRESS');
  perform public._t_throws(format($$select public.merge_my_biryong_progress_v1(%L::uuid, '{"step":"INTRO","shouts":"abc"}'::jsonb, false)$$, v_alice),
    '22023', 'biryong merge bad shouts refused', 'INVALID_BIRYONG_SHOUTS');
  perform public._t_throws(format($$select public.merge_my_biryong_progress_v1(%L::uuid, '{"step":"INTRO","lore":"x"}'::jsonb, false)$$, v_alice),
    '22023', 'biryong merge bad lore refused', 'INVALID_BIRYONG_LORE');
  perform public._t_is(public.get_my_biryong_progress_v1(v_noprofile) is null, true, 'biryong get noprofile succeeds (session-only gate, null before merge)');

  -- ---- biryong NPC relationships ----
  v_r := public.get_my_biryong_npc_relationships_v1(v_alice);
  perform public._t_is(jsonb_array_length(v_r -> 'relationships'), 8, 'biryong npc list 8');
  perform public._t_is((select (x ->> 'stage')::int from jsonb_array_elements(v_r -> 'relationships') x where x ->> 'npcId' = 'BR_NPC_001'), 1, 'biryong npc 001 stage 1');
  v_r := public.get_my_biryong_npc_relationship_v1(v_alice, 'BR_NPC_001');
  perform public._t_is((v_r ->> 'stage')::int, 1, 'biryong npc 001 get stage 1');
  perform public._t_is(v_r ->> 'stageState', 'ACQUAINTED', 'biryong npc 001 stageState ACQUAINTED');
  perform public._t_is((v_r ->> 'nextStage')::int, 2, 'biryong npc 001 nextStage 2');
  perform public._t_throws(format($$select public.get_my_biryong_npc_relationship_v1(%L::uuid, 'BR_NPC_999')$$, v_alice),
    'P0002', 'biryong npc unknown refused', 'BIRYONG_NPC_NOT_AVAILABLE');
  v_r := public.world_biryong_npc_relationship_advance_v1(v_alice, 'BR_NPC_001', 2::smallint, 'QUEST', 'quest/test', 'result/test', 'oracle-biryong-1');
  perform public._t_is(v_r ->> 'status', 'ADVANCED', 'biryong advance 1->2 ADVANCED');
  perform public._t_is((v_r -> 'relationship' ->> 'stage')::int, 2, 'biryong advance 1->2 stage 2');
  perform public._t_is((v_r ->> 'eventId') is not null, true, 'biryong advance returns eventId');
  v_r := public.world_biryong_npc_relationship_advance_v1(v_alice, 'BR_NPC_001', 2::smallint, 'QUEST', 'quest/test', 'result/test', 'oracle-biryong-1');
  perform public._t_is(v_r ->> 'status', 'ALREADY_PROCESSED', 'biryong advance replay ALREADY_PROCESSED');
  perform public._t_throws(format($$select public.world_biryong_npc_relationship_advance_v1(%L::uuid, 'BR_NPC_001', 3::smallint, 'QUEST', 'quest/test', 'result/test', 'oracle-biryong-1')$$, v_alice),
    '23505', 'biryong advance same key other target -> conflict', 'IDEMPOTENCY_CONFLICT');
  v_r := public.world_biryong_npc_relationship_advance_v1(v_alice, 'BR_NPC_001', 3::smallint, 'EVENT', 'event/test', 'result/test', 'oracle-biryong-2');
  perform public._t_is(v_r ->> 'status', 'ADVANCED', 'biryong advance 2->3 ADVANCED');
  perform public._t_is((v_r -> 'relationship' ->> 'stage')::int, 3, 'biryong advance 2->3 stage 3');
  perform public._t_is((v_r -> 'relationship' ->> 'stageState'), 'SHARED_RESPONSIBILITY', 'biryong npc 001 stageState SHARED_RESPONSIBILITY');
  v_r := public.world_biryong_npc_relationship_advance_v1(v_alice, 'BR_NPC_001', 3::smallint, 'SYSTEM', 'system/test', null, 'oracle-biryong-3');
  perform public._t_is(v_r ->> 'status', 'ALREADY_UNLOCKED', 'biryong advance to current stage ALREADY_UNLOCKED');
  perform public._t_throws(format($$select public.world_biryong_npc_relationship_advance_v1(%L::uuid, 'BR_NPC_002', 3::smallint, 'QUEST', 'quest/test', 'result/test', 'oracle-biryong-4')$$, v_alice),
    'P0001', 'biryong advance skip 1->3 refused', 'RELATIONSHIP_STAGE_STEP_REQUIRED');
  perform public._t_throws(format($$select public.world_biryong_npc_relationship_advance_v1(%L::uuid, 'BR_NPC_002', 1::smallint, 'QUEST', 'quest/test', 'result/test', 'oracle-biryong-5')$$, v_alice),
    '22023', 'biryong advance target 1 refused', 'INVALID_RELATIONSHIP_STAGE');
  perform public._t_throws(format($$select public.world_biryong_npc_relationship_advance_v1(%L::uuid, 'BR_NPC_999', 2::smallint, 'QUEST', 'quest/test', 'result/test', 'oracle-biryong-6')$$, v_alice),
    'P0002', 'biryong advance unknown npc refused', 'BIRYONG_NPC_NOT_AVAILABLE');
  perform public._t_throws(format($$select public.world_biryong_npc_relationship_advance_v1(%L::uuid, 'BR_NPC_002', 2::smallint, 'MAGIC', 'quest/test', 'result/test', 'oracle-biryong-7')$$, v_alice),
    '22023', 'biryong advance bad source refused', 'INVALID_RELATIONSHIP_SOURCE');
  perform public._t_throws(format($$select public.world_biryong_npc_relationship_advance_v1(%L::uuid, 'BR_NPC_002', 2::smallint, 'QUEST', 'quest/test', null, 'oracle-biryong-8')$$, v_alice),
    '22023', 'biryong advance QUEST without resultRef refused', 'RELATIONSHIP_RESULT_REF_REQUIRED');
  perform public._t_throws(format($$select public.world_biryong_npc_relationship_advance_v1(%L::uuid, 'BR_NPC_002', 2::smallint, 'QUEST', 'quest/test', 'result/test', 'bad key!')$$, v_alice),
    '22023', 'biryong advance bad key refused', 'INVALID_IDEMPOTENCY_KEY');
  v_r := public.get_my_biryong_npc_relationship_v1(v_alice, 'BR_NPC_002');
  perform public._t_is((v_r ->> 'stage')::int, 1, 'biryong npc 002 untouched stage 1');

  -- ---- campus NPC relationships ----
  v_r := public.get_my_world_campus_npc_relationships_v1(v_alice);
  perform public._t_is(jsonb_array_length(v_r -> 'relationships'), 10, 'campus npc list 10');
  perform public._t_is((select (x ->> 'affinity')::int from jsonb_array_elements(v_r -> 'relationships') x where x ->> 'npcId' = 'INKYUNG-NPC-001'), 0, 'campus npc 001 affinity 0');
  v_r := public.get_my_world_campus_npc_relationship_v1(v_alice, 'INKYUNG-NPC-001');
  perform public._t_is((v_r ->> 'affinity')::int, 0, 'campus npc 001 get affinity 0');
  perform public._t_is(v_r ->> 'tier', 'STRANGER', 'campus npc 001 tier STRANGER');
  perform public._t_is(v_r ->> 'relationshipClass', 'HERO', 'campus npc 001 class HERO');
  perform public._t_is((v_r ->> 'definitionVersion')::int, 1, 'campus npc 001 definitionVersion 1');
  perform public._t_throws(format($$select public.get_my_world_campus_npc_relationship_v1(%L::uuid, 'INKYUNG-NPC-999')$$, v_alice),
    'P0002', 'campus npc unknown refused', 'CAMPUS_NPC_NOT_AVAILABLE');
  v_r := public.world_campus_npc_relationship_apply_v1(v_alice, 'INKYUNG-NPC-001', 1, 'FIRST_MEETING', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'oracle-campus-1');
  perform public._t_is(v_r ->> 'status', 'APPLIED', 'campus apply FIRST_MEETING APPLIED');
  perform public._t_is((v_r -> 'relationship' ->> 'affinity')::int, 5, 'campus apply FIRST_MEETING affinity 5');
  perform public._t_is((v_r -> 'relationship' ->> 'encounterCount')::int, 1, 'campus apply FIRST_MEETING encounterCount 1');
  perform public._t_is((v_r ->> 'appliedDelta')::int, 5, 'campus apply appliedDelta 5');
  v_r := public.world_campus_npc_relationship_apply_v1(v_alice, 'INKYUNG-NPC-001', 1, 'FIRST_MEETING', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'oracle-campus-1');
  perform public._t_is(v_r ->> 'status', 'ALREADY_PROCESSED', 'campus apply replay ALREADY_PROCESSED');
  v_r := public.world_campus_npc_relationship_apply_v1(v_alice, 'INKYUNG-NPC-001', 1, 'FIRST_MEETING', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'oracle-campus-2');
  perform public._t_is(v_r ->> 'status', 'ALREADY_MET', 'campus apply second FIRST_MEETING ALREADY_MET');
  v_r := public.world_campus_npc_relationship_apply_v1(v_alice, 'INKYUNG-NPC-001', 1, 'MEANINGFUL_DIALOGUE', 'GREETING_WARM', 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'oracle-campus-3');
  perform public._t_is(v_r ->> 'status', 'APPLIED', 'campus apply MEANINGFUL_DIALOGUE APPLIED');
  perform public._t_is((v_r -> 'relationship' ->> 'affinity')::int, 10, 'campus apply affinity 10');
  perform public._t_is((v_r -> 'relationship' ->> 'meaningfulInteractionCount')::int, 1, 'campus apply meaningfulInteractionCount 1');
  v_r := public.world_campus_npc_relationship_apply_v1(v_alice, 'INKYUNG-NPC-001', 1, 'NEGATIVE_CHOICE', null, 1, (-3)::smallint, 'DIALOGUE', 'oracle/test', 'oracle-campus-4');
  perform public._t_is((v_r -> 'relationship' ->> 'affinity')::int, 7, 'campus apply NEGATIVE_CHOICE affinity 7');
  perform public._t_throws(format($$select public.world_campus_npc_relationship_apply_v1(%L::uuid, 'INKYUNG-NPC-001', 1, 'NEGATIVE_CHOICE', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'oracle-campus-5')$$, v_alice),
    '22023', 'campus apply NEGATIVE_CHOICE positive delta refused', 'RELATIONSHIP_DELTA_SIGN_MISMATCH');
  perform public._t_throws(format($$select public.world_campus_npc_relationship_apply_v1(%L::uuid, 'INKYUNG-NPC-001', 2, 'REUNION', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'oracle-campus-6')$$, v_alice),
    '22023', 'campus apply version mismatch refused', 'RELATIONSHIP_DEFINITION_VERSION_MISMATCH');
  perform public._t_throws(format($$select public.world_campus_npc_relationship_apply_v1(%L::uuid, 'INKYUNG-NPC-999', 1, 'REUNION', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'oracle-campus-7')$$, v_alice),
    'P0002', 'campus apply unknown npc refused', 'CAMPUS_NPC_NOT_AVAILABLE');
  perform public._t_throws(format($$select public.world_campus_npc_relationship_apply_v1(%L::uuid, 'INKYUNG-NPC-001', 1, 'REUNION', null, 1, 11::smallint, 'DIALOGUE', 'oracle/test', 'oracle-campus-8')$$, v_alice),
    '22023', 'campus apply delta 11 refused', 'INVALID_RELATIONSHIP_DELTA');
  perform public._t_throws(format($$select public.world_campus_npc_relationship_apply_v1(%L::uuid, 'INKYUNG-NPC-001', 1, 'REUNION', null, 1, 0::smallint, 'DIALOGUE', 'oracle/test', 'oracle-campus-9')$$, v_alice),
    '22023', 'campus apply delta 0 refused', 'INVALID_RELATIONSHIP_DELTA');
  perform public._t_throws(format($$select public.world_campus_npc_relationship_apply_v1(%L::uuid, 'INKYUNG-NPC-001', 1, 'HUG', null, 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'oracle-campus-10')$$, v_alice),
    '22023', 'campus apply bad event refused', 'INVALID_CAMPUS_NPC_RELATIONSHIP_EVENT');
  perform public._t_throws(format($$select public.world_campus_npc_relationship_apply_v1(%L::uuid, 'INKYUNG-NPC-001', 1, 'FIRST_MEETING', null, 2, 5::smallint, 'DIALOGUE', 'oracle/test', 'oracle-campus-11')$$, v_alice),
    '22023', 'campus apply FIRST_MEETING occurrence 2 refused', 'INVALID_FIRST_MEETING_OCCURRENCE');
  perform public._t_throws(format($$select public.world_campus_npc_relationship_apply_v1(%L::uuid, 'INKYUNG-NPC-001', 1, 'REUNION', 'lower', 1, 5::smallint, 'DIALOGUE', 'oracle/test', 'oracle-campus-12')$$, v_alice),
    '22023', 'campus apply bad signal refused', 'INVALID_RELATIONSHIP_SIGNAL');
  perform public._t_throws(format($$select public.world_campus_npc_relationship_apply_v1(%L::uuid, 'INKYUNG-NPC-001', 1, 'REUNION', null, 1, 5::smallint, 'MAGIC', 'oracle/test', 'oracle-campus-13')$$, v_alice),
    '22023', 'campus apply bad source refused', 'INVALID_RELATIONSHIP_SOURCE');
end
$do$;

-- =====================================================================
-- A-3: MCM 2026 event
-- (The seed event window ended 2026-09-30, so this section flips it
--  ACTIVE and restores the seed window in the same transaction, the
--  same pattern as the A-2 jeongseok gate flip. advance has no HTTP
--  endpoint: the Worker is the server caller, so the oracle calls it
--  directly in SQL.)
-- =====================================================================
do $do$
declare
  v_alice uuid := 'a1000000-0000-4000-8000-000000000001'::uuid;
  v_bob uuid := 'a2000000-0000-4000-8000-000000000002'::uuid;
  v_noprofile uuid := 'a4000000-0000-4000-8000-000000000004'::uuid;
  v_s0 timestamptz; v_we0 timestamptz;
  v_m jsonb;
  v_run jsonb;
  v_run_id uuid;
  v_survivor text;
  v_wrong text;
  v_c jsonb;
  v_w0 bigint; v_e0 bigint;
begin
  select starts_at, ends_at into v_s0, v_we0 from private.world_events where event_id = 'event.mcm_2026';
  -- ENDED window: reads work, writes refuse
  v_m := public.get_my_mcm_2026_event_v1(v_alice);
  perform public._t_is(v_m ->> 'eventState', 'ENDED', 'mcm get ENDED before flip');
  perform public._t_is(v_m -> 'progress' ->> 'stage', 'NOT_STARTED', 'mcm progress NOT_STARTED before flip');
  perform public._t_throws(format($$select public.advance_mcm_2026_event_v1(%L::uuid, 'start')$$, v_bob),
    'P0001', 'mcm advance while ENDED refused', 'EVENT_NOT_ACTIVE');
  perform public._t_throws(format($$select public.start_mcm_landlord_run_v1(%L::uuid)$$, v_bob),
    'P0001', 'mcm landlord start while ENDED refused', 'EVENT_NOT_ACTIVE');
  -- flip ACTIVE (restored at the end of this block)
  update private.world_events set starts_at = now() - interval '1 hour', ends_at = now() + interval '1 hour'
   where event_id = 'event.mcm_2026';
  v_m := public.get_my_mcm_2026_event_v1(v_alice);
  perform public._t_is(v_m ->> 'eventState', 'ACTIVE', 'mcm get ACTIVE after flip');
  perform public._t_is(public.get_my_mcm_2026_event_v1(v_noprofile) -> 'progress' ->> 'stage', 'NOT_STARTED', 'mcm get noprofile succeeds (session-only gate)');
  perform public._t_throws(format($$select public.advance_mcm_2026_event_v1(%L::uuid, 'bogus')$$, v_alice),
    '22023', 'mcm advance bad action refused', 'INVALID_EVENT_ACTION');
  perform public._t_throws(format($$select public.claim_my_mcm_2026_main_reward_v1(%L::uuid)$$, v_alice),
    'P0001', 'mcm claim main before complete refused', 'CLAIM_NOT_ELIGIBLE');
  perform public._t_throws(format($$select public.claim_my_mcm_landlord_first_clear_reward_v1(%L::uuid)$$, v_alice),
    'P0001', 'mcm claim landlord before first clear refused', 'CLAIM_NOT_ELIGIBLE');
  -- investigate before start cannot skip ahead
  v_m := public.advance_mcm_2026_event_v1(v_alice, 'investigate_staggering');
  perform public._t_is(v_m -> 'progress' ->> 'stage', 'NOT_STARTED', 'mcm investigate before start stays NOT_STARTED');
  v_m := public.advance_mcm_2026_event_v1(v_alice, 'status');
  perform public._t_is(v_m -> 'progress' ->> 'stage', 'NOT_STARTED', 'mcm advance status returns state');
  v_m := public.advance_mcm_2026_event_v1(v_alice, 'start');
  perform public._t_is(v_m -> 'progress' ->> 'stage', 'STARTED', 'mcm advance start -> STARTED');
  perform public._t_is((v_m -> 'progress' ->> 'startedAt') is not null, true, 'mcm startedAt set');
  v_m := public.advance_mcm_2026_event_v1(v_alice, 'start');
  perform public._t_is(v_m -> 'progress' ->> 'stage', 'STARTED', 'mcm advance start replay stays STARTED');
  v_m := public.advance_mcm_2026_event_v1(v_alice, 'investigate_staggering');
  perform public._t_is(v_m -> 'progress' ->> 'stage', 'STARTED', 'mcm 1/3 investigated still STARTED');
  v_m := public.advance_mcm_2026_event_v1(v_alice, 'investigate_dancing');
  perform public._t_is(v_m -> 'progress' ->> 'stage', 'STARTED', 'mcm 2/3 investigated still STARTED');
  v_m := public.advance_mcm_2026_event_v1(v_alice, 'investigate_hungry');
  perform public._t_is(v_m -> 'progress' ->> 'stage', 'VENUE_UNLOCKED', 'mcm 3/3 investigated -> VENUE_UNLOCKED');
  perform public._t_is(v_m -> 'progress' -> 'investigated', '["dancing","hungry","staggering"]'::jsonb, 'mcm investigated all 3 npcs sorted');
  perform public._t_is((v_m -> 'progress' ->> 'venueUnlockedAt') is not null, true, 'mcm venueUnlockedAt set');
  -- landlord run
  v_run := public.start_mcm_landlord_run_v1(v_alice);
  v_run_id := (v_run ->> 'runId')::uuid;
  perform public._t_is(v_run ->> 'status', 'ACTIVE', 'mcm landlord run ACTIVE');
  perform public._t_is((v_run ->> 'resumed')::boolean, false, 'mcm landlord run not resumed first start');
  perform public._t_is((v_run ->> 'durationMs')::int, 45000, 'mcm landlord run 45s');
  perform public._t_is((v_run ->> 'wrongPenaltyMs')::int, 5000, 'mcm landlord wrong penalty 5s');
  perform public._t_is(jsonb_array_length(v_run -> 'actorIds'), 5, 'mcm landlord 5 actors');
  perform public._t_is((v_run ->> 'wrongCount')::int, 0, 'mcm landlord wrongCount 0');
  v_run := public.start_mcm_landlord_run_v1(v_alice);
  perform public._t_is((v_run ->> 'resumed')::boolean, true, 'mcm landlord start again resumes');
  perform public._t_is((v_run ->> 'runId')::uuid, v_run_id, 'mcm landlord resume same run');
  select survivor_actor_id into v_survivor from private.world_landlord_runs where run_id = v_run_id;
  v_wrong := case when v_survivor = 'ZUE-MG-001' then 'ZUE-MG-002' else 'ZUE-MG-001' end;
  perform public._t_throws(format($$select public.submit_mcm_landlord_choice_v1(%L::uuid, %L::uuid, 'ZUE-MG-999')$$, v_alice, v_run_id),
    '22023', 'mcm landlord bad actor refused', 'INVALID_ACTOR');
  perform public._t_throws(format($$select public.submit_mcm_landlord_choice_v1(%L::uuid, %L::uuid, %L)$$, v_bob, v_run_id, v_survivor),
    'P0001', 'mcm landlord other account run refused', 'RUN_NOT_FOUND');
  v_run := public.submit_mcm_landlord_choice_v1(v_alice, v_run_id, v_wrong);
  perform public._t_is((v_run ->> 'correct')::boolean, false, 'mcm landlord wrong choice correct false');
  perform public._t_is((v_run ->> 'wrongCount')::int, 1, 'mcm landlord wrong choice wrongCount 1');
  perform public._t_is(v_run ->> 'status', 'ACTIVE', 'mcm landlord still ACTIVE after wrong choice');
  v_run := public.submit_mcm_landlord_choice_v1(v_alice, v_run_id, v_survivor);
  perform public._t_is((v_run ->> 'correct')::boolean, true, 'mcm landlord correct choice correct true');
  perform public._t_is(v_run ->> 'status', 'CLEARED', 'mcm landlord CLEARED');
  perform public._t_is((v_run ->> 'firstClear')::boolean, true, 'mcm landlord firstClear true');
  perform public._t_is((v_run ->> 'firstClearedAt') is not null, true, 'mcm landlord firstClearedAt set');
  v_run := public.submit_mcm_landlord_choice_v1(v_alice, v_run_id, v_survivor);
  perform public._t_is(v_run ->> 'status', 'CLEARED', 'mcm landlord resubmit stays CLEARED');
  perform public._t_is(v_run ->> 'correct', null, 'mcm landlord resubmit correct null');
  perform public._t_is((v_run ->> 'firstClear')::boolean, false, 'mcm landlord resubmit firstClear false');
  -- clearing with venue unlocked completes the event (try_complete)
  v_m := public.get_my_mcm_2026_event_v1(v_alice);
  perform public._t_is(v_m -> 'progress' ->> 'stage', 'COMPLETED', 'mcm COMPLETED after landlord first clear');
  perform public._t_is((v_m -> 'progress' ->> 'completedAt') is not null, true, 'mcm completedAt set');
  perform public._t_is((v_m -> 'landlord' ->> 'firstClearedAt') is not null, true, 'mcm landlord firstClearedAt in state');
  perform public._t_is(v_m -> 'landlord' ->> 'activeRun', null, 'mcm no active run after clear');
  -- claims
  select balance into v_w0 from private.world_wallets where user_id = v_alice and currency_id = 'currency.induck_coin';
  select total_exp into v_e0 from private.world_player_progression where user_id = v_alice;
  v_c := public.claim_my_mcm_landlord_first_clear_reward_v1(v_alice);
  perform public._t_is(v_c ->> 'status', 'CLAIMED', 'mcm claim landlord CLAIMED');
  perform public._t_is((v_c ->> 'replayed')::boolean, false, 'mcm claim landlord not replayed');
  perform public._t_is(v_c ->> 'rewardId', 'reward.minigame.landlord_first_clear', 'mcm claim landlord rewardId');
  v_c := public.claim_my_mcm_landlord_first_clear_reward_v1(v_alice);
  perform public._t_is(v_c ->> 'status', 'ALREADY_CLAIMED', 'mcm claim landlord replay ALREADY_CLAIMED');
  perform public._t_is((v_c ->> 'replayed')::boolean, true, 'mcm claim landlord replay replayed true');
  v_c := public.claim_my_mcm_2026_main_reward_v1(v_alice);
  perform public._t_is(v_c ->> 'status', 'CLAIMED', 'mcm claim main CLAIMED');
  perform public._t_is(v_c ->> 'rewardId', 'reward.event.mcm_2026_main_clear', 'mcm claim main rewardId');
  v_c := public.claim_my_mcm_2026_main_reward_v1(v_alice);
  perform public._t_is(v_c ->> 'status', 'ALREADY_CLAIMED', 'mcm claim main replay ALREADY_CLAIMED');
  perform public._t_is((select balance from private.world_wallets where user_id = v_alice and currency_id = 'currency.induck_coin'), v_w0 + 80, 'mcm main reward +80 coins');
  perform public._t_is((select total_exp from private.world_player_progression where user_id = v_alice), v_e0 + 200, 'mcm rewards +200 exp (150 main + 50 landlord)');
  perform public._t_is((select quantity from private.world_player_items where user_id = v_alice and item_id = 'top.mcm_2026_survivor'), 1, 'mcm main reward survivor top granted');
  perform public._t_is((select quantity from private.world_player_items where user_id = v_alice and item_id = 'furniture.mcm_2026_poster'), 1, 'mcm main reward poster granted');
  perform public._t_is((select quantity from private.world_player_items where user_id = v_alice and item_id = 'badge.mcm_2026_landlord'), 1, 'mcm landlord reward badge granted');
  -- restore the seed window
  update private.world_events set starts_at = v_s0, ends_at = v_we0 where event_id = 'event.mcm_2026';
  v_m := public.get_my_mcm_2026_event_v1(v_alice);
  perform public._t_is(v_m ->> 'eventState', 'ENDED', 'mcm get ENDED after window restore');
  perform public._t_is(v_m -> 'progress' ->> 'stage', 'COMPLETED', 'mcm progress stays COMPLETED after restore');
end
$do$;

-- =====================================================================
-- BCD (2026-11-20): profile creation, mail fallback, online polling.
-- New sessions are BCD-only (e1/e2/e3 prefixes) so the A-1/A-2/A-3
-- assertions above are untouched. now() is frozen inside this transaction,
-- which makes the 10-second touch rate limit and the 1-hour mail limit
-- deterministic: a second touch / fourth request in the same transaction
-- always trips, and ageing a row is done with an explicit UPDATE.
-- =====================================================================
do $do$
declare
  v_noprofile uuid := 'a4000000-0000-4000-8000-000000000004';
  v_banned uuid := 'a3000000-0000-4000-8000-000000000003';
  v_alice uuid := 'a1000000-0000-4000-8000-000000000001';
  v_mail uuid := 'e2000000-0000-4000-8000-000000000002';
  v_dup uuid := 'e1000000-0000-4000-8000-000000000001';
  v_on1 uuid := 'e3000000-0000-4000-8000-000000000003';
  v_on2 uuid := 'e3000000-0000-4000-8000-000000000004';
  v_on3 uuid := 'e3000000-0000-4000-8000-000000000005';
  v_vis uuid := 'e3000000-0000-4000-8000-000000000006';
  v_p jsonb;
  v_req jsonb;
  v_req_id uuid;
  v_claim jsonb;
  v_count jsonb;
  v_n int;
begin
  insert into public.sessions (id, nickname) values
    (v_mail, 'bcdmail'), (v_dup, 'bcddup'),
    (v_on1, 'bcdon1'), (v_on2, 'bcdon2'), (v_on3, 'bcdon3')
    on conflict (id) do nothing;

  -- ---- static: BCD objects exist ----
  perform public._t_is((select count(*) from private.world_profile_banned_words), 47::bigint, 'bcd banned words = 47 (patch35)');
  perform public._t_is((select count(*) from pg_proc where proname in (
    'create_my_world_profile_v1', 'request_world_mail_verification_v1',
    'admin_claim_world_mail_verification_v1', 'touch_world_online_session_v2',
    'get_world_online_count_v1', 'world_profile_normalize_nickname_v1',
    'world_profile_nickname_banned_v1')), 7::bigint, 'bcd functions = 7');
  perform public._t_is((select to_regprocedure('public.create_my_world_profile_v1(uuid,text,bigint,text,text)') is not null), true, 'bcd profile rpc signature');
  perform public._t_is((select to_regprocedure('public.touch_world_online_session_v2(uuid,uuid,text,text)') is not null), true, 'bcd touch rpc signature');
  perform public._t_is((select to_regprocedure('public.get_world_online_count_v1()') is not null), true, 'bcd count rpc signature');
  perform public._t_is((select indexdef is not null from pg_indexes where schemaname = 'public' and indexname = 'profiles_nickname_unique_active'), true, 'bcd nickname partial unique index exists');
  perform public._t_is((select (proacl::text like '{=X/%' or proacl::text like '%,=X/%') from pg_proc where oid = 'public.create_my_world_profile_v1(uuid,text,bigint,text,text)'::regprocedure), false, 'bcd profile rpc grants nothing to PUBLIC');
  perform public._t_is((select proacl::text from pg_proc where oid = 'public.create_my_world_profile_v1(uuid,text,bigint,text,text)'::regprocedure) like '%inha_world_tier4_writes_app=X/%', true, 'bcd profile rpc acl names the Worker role');

  -- ---- nickname normalisation (patch35 semantics in SQL) ----
  perform public._t_is(private.world_profile_normalize_nickname_v1('씨 발'), '씨발', 'bcd normalize strips spaces');
  perform public._t_is(private.world_profile_normalize_nickname_v1('fuuuck'), 'fuck', 'bcd normalize collapses repeats');
  perform public._t_is(private.world_profile_normalize_nickname_v1('FUCK'), 'fuck', 'bcd normalize lowercases');
  perform public._t_is(private.world_profile_nickname_banned_v1('씨발왕'), true, 'bcd banned substring hit');
  perform public._t_is(private.world_profile_nickname_banned_v1('fuuuck'), true, 'bcd banned leet/repeat hit');
  perform public._t_is(private.world_profile_nickname_banned_v1('소년연금술사'), false, 'bcd no false positive on normal nickname');
  perform public._t_is(private.world_profile_nickname_banned_v1('인덕이'), false, 'bcd normal nickname clean');

  -- ---- profile creation ----
  v_p := public.create_my_world_profile_v1(v_noprofile, '새내기', 10, 'scholar', null);
  perform public._t_is(v_p ->> 'nickname', '새내기', 'bcd profile created nickname');
  perform public._t_is((v_p ->> 'created')::boolean, true, 'bcd profile created true');
  perform public._t_is(v_p ->> 'departmentName', '환경공학과', 'bcd profile department name');
  perform public._t_is(v_p ->> 'avatarKey', 'scholar', 'bcd profile avatar');
  perform public._t_is(v_p ->> 'title', null, 'bcd profile title null');
  perform public._t_is((v_p ->> 'isBanned')::boolean, false, 'bcd profile not banned');
  v_p := public.create_my_world_profile_v1(v_noprofile, '다른이름', 1, 'star', null);
  perform public._t_is((v_p ->> 'created')::boolean, false, 'bcd profile recreate created false');
  perform public._t_is(v_p ->> 'nickname', '새내기', 'bcd profile recreate keeps existing nickname');
  perform public._t_is(v_p ->> 'avatarKey', 'scholar', 'bcd profile recreate keeps existing avatar');
  perform public._t_throws(format($$select public.create_my_world_profile_v1(%L::uuid, 'tier4alice', 1, 'classic', null)$$, v_dup),
    'P0001', 'bcd profile duplicate nickname refused', 'NICKNAME_TAKEN');
  perform public._t_throws(format($$select public.create_my_world_profile_v1(%L::uuid, 'Tier4Alice', 1, 'classic', null)$$, v_dup),
    'P0001', 'bcd profile duplicate nickname case-insensitive', 'NICKNAME_TAKEN');
  perform public._t_throws(format($$select public.create_my_world_profile_v1(%L::uuid, '씨발왕', 1, 'classic', null)$$, v_dup),
    '22023', 'bcd profile banned word refused', 'INVALID_NICKNAME');
  perform public._t_throws(format($$select public.create_my_world_profile_v1(%L::uuid, 'fuuuck', 1, 'classic', null)$$, v_dup),
    '22023', 'bcd profile banned repeat refused', 'INVALID_NICKNAME');
  perform public._t_throws(format($$select public.create_my_world_profile_v1(%L::uuid, '가', 1, 'classic', null)$$, v_dup),
    '22023', 'bcd profile too short refused', 'INVALID_NICKNAME');
  perform public._t_throws(format($$select public.create_my_world_profile_v1(%L::uuid, 'a!b', 1, 'classic', null)$$, v_dup),
    '22023', 'bcd profile bad chars refused', 'INVALID_NICKNAME');
  perform public._t_throws(format($$select public.create_my_world_profile_v1(%L::uuid, '괜찮은이름', 99999, 'classic', null)$$, v_dup),
    '22023', 'bcd profile unknown department refused', 'INVALID_DEPARTMENT');
  insert into public.departments (id, name, active, sort_order) values (9999, '폐지학과', false, 9998);
  perform public._t_throws(format($$select public.create_my_world_profile_v1(%L::uuid, '괜찮은이름', 9999, 'classic', null)$$, v_dup),
    '22023', 'bcd profile inactive department refused', 'INVALID_DEPARTMENT');
  delete from public.departments where id = 9999;
  perform public._t_throws(format($$select public.create_my_world_profile_v1(%L::uuid, '괜찮은이름', 1, 'wizard', null)$$, v_dup),
    '22023', 'bcd profile bad avatar refused', 'INVALID_AVATAR');
  perform public._t_throws(format($$select public.create_my_world_profile_v1(%L::uuid, '괜찮은이름', 1, 'classic', '12345678901234567890123456789012345678901')$$, v_dup),
    '22023', 'bcd profile long title refused', 'INVALID_TITLE');
  perform public._t_throws(format($$select public.create_my_world_profile_v1(%L::uuid, '괜찮은이름', null, null, null)$$, v_banned),
    'P0001', 'bcd banned profile recreate concealed as missing', 'PROFILE_NOT_FOUND');
  perform public._t_throws($$select public.create_my_world_profile_v1(null, '괜찮은이름', 1, 'classic', null)$$,
    'P0001', 'bcd profile null user refused', 'PERMANENT_ACCOUNT_REQUIRED');
  -- banned nickname is reusable (partial unique index excludes banned rows)
  v_p := public.create_my_world_profile_v1(v_dup, 'tier4banned', 1, 'classic', null);
  perform public._t_is((v_p ->> 'created')::boolean, true, 'bcd banned nickname reusable');
  -- profile read-back through the A-1 getter
  perform public._t_is((public.get_my_profile(v_noprofile) -> 'profile' ->> 'nickname'), '새내기', 'bcd profile readable via get_my_profile');

  -- ---- mail verification requests (admin fallback; no mail is sent) ----
  perform public._t_throws(format($$select public.request_world_mail_verification_v1(%L::uuid, 'notinha@gmail.com')$$, v_mail),
    '22023', 'bcd mail non-inha address refused', 'INVALID_EMAIL');
  perform public._t_throws(format($$select public.request_world_mail_verification_v1(%L::uuid, 'a@inha.ac')$$, v_mail),
    '22023', 'bcd mail wrong domain refused', 'INVALID_EMAIL');
  v_req := public.request_world_mail_verification_v1(v_mail, 'Newbie@INHA.EDU');
  perform public._t_is(v_req ->> 'email', 'newbie@inha.edu', 'bcd mail email lowercased');
  perform public._t_is(v_req ->> 'status', 'PENDING', 'bcd mail request pending');
  perform public._t_is((v_req ->> 'duplicate')::boolean, false, 'bcd mail first request not duplicate');
  v_req_id := (v_req ->> 'requestId')::uuid;
  v_req := public.request_world_mail_verification_v1(v_mail, 'newbie@inha.edu');
  perform public._t_is((v_req ->> 'duplicate')::boolean, true, 'bcd mail repeat within 10m is duplicate');
  perform public._t_is((v_req ->> 'requestId')::uuid, v_req_id, 'bcd mail duplicate returns same request');
  perform public._t_throws(format($$select public.admin_claim_world_mail_verification_v1(%L::uuid)$$, 'e3000000-0000-4000-8000-000000000099'),
    'P0002', 'bcd mail claim unknown request refused', 'MAIL_REQUEST_NOT_FOUND');
  -- claim: no profile yet, so badge yes, achievement no
  v_claim := public.admin_claim_world_mail_verification_v1(v_req_id);
  perform public._t_is((v_claim ->> 'verified')::boolean, true, 'bcd mail claim verified');
  perform public._t_is((v_claim ->> 'achievementGranted')::boolean, false, 'bcd mail claim no profile no achievement');
  perform public._t_is((select email from public.inha_mail_badges where user_id = v_mail), 'newbie@inha.edu', 'bcd mail badge row created');
  perform public._t_is((select status from private.world_mail_verify_requests where request_id = v_req_id), 'CLAIMED', 'bcd mail request marked claimed');
  perform public._t_throws(format($$select public.admin_claim_world_mail_verification_v1(%L::uuid)$$, v_req_id),
    'P0002', 'bcd mail claim twice refused', 'MAIL_REQUEST_NOT_FOUND');
  -- rate limit: 3 requests/hour per user (the claim above does not count;
  -- the first request does). Two more distinct addresses, then the 4th trips.
  perform public.request_world_mail_verification_v1(v_mail, 'second@inha.edu');
  perform public.request_world_mail_verification_v1(v_mail, 'third@inha.ac.kr');
  perform public._t_throws(format($$select public.request_world_mail_verification_v1(%L::uuid, 'fourth@inha.edu')$$, v_mail),
    '54000', 'bcd mail 4th request in an hour rate limited', 'RATE_LIMITED');
  -- with a profile, a fresh claim grants the achievement too
  v_p := public.create_my_world_profile_v1(v_mail, '메일인증이', 1, 'classic', null);
  perform public._t_is((v_p ->> 'created')::boolean, true, 'bcd mail user profile created');
  v_req := public.request_world_mail_verification_v1(v_dup, 'dup@inha.edu');
  v_req_id := (v_req ->> 'requestId')::uuid;
  v_claim := public.admin_claim_world_mail_verification_v1(v_req_id);
  perform public._t_is((v_claim ->> 'achievementGranted')::boolean, true, 'bcd mail claim with profile grants achievement');
  perform public._t_is((select count(*) from public.user_achievements where user_id = v_dup and achievement_key = 'inha_verified_v1'), 1::bigint, 'bcd mail achievement row exists');
  perform public._t_is((select count(*) from jsonb_array_elements(public.get_my_achievements(v_dup) -> 'achievements') a where a ->> 'key' = 'inha_verified_v1' and a ->> 'earned' = 'true'), 1::bigint, 'bcd mail achievement visible via get_my_achievements');

  -- ---- online touch / count ----
  perform public.touch_world_online_session_v2(v_on1, v_vis, 'AREA_MAIN_GATE', 'campus');
  perform public._t_is((select user_id from public.world_online_sessions where session_id = v_on1), null, 'bcd touch user_id null');
  perform public._t_is((select visitor_id from public.world_online_sessions where session_id = v_on1), v_vis, 'bcd touch visitor stored');
  perform public._t_is((select space from public.world_online_sessions where session_id = v_on1), 'campus', 'bcd touch space stored');
  perform public._t_throws(format($$select public.touch_world_online_session_v2(%L::uuid, null, 'AREA_MAIN_GATE', 'campus')$$, v_on1),
    '54000', 'bcd touch immediate re-touch rate limited', 'RATE_LIMITED');
  update public.world_online_sessions set last_seen_at = now() - interval '20 seconds' where session_id = v_on1;
  perform public.touch_world_online_session_v2(v_on1, null, 'AREA_MAIN_GATE', 'campus');
  perform public._t_is((select visitor_id from public.world_online_sessions where session_id = v_on1), v_vis, 'bcd touch visitor coalesce keeps old');
  update public.world_online_sessions set last_seen_at = now() - interval '20 seconds' where session_id = v_on1;
  perform public.touch_world_online_session_v2(v_on1, 'e3000000-0000-4000-8000-000000000007', 'AREA_MAIN_GATE', 'lobby');
  perform public._t_is((select visitor_id from public.world_online_sessions where session_id = v_on1), 'e3000000-0000-4000-8000-000000000007'::uuid, 'bcd touch visitor replaced when given');
  perform public._t_is((select space from public.world_online_sessions where session_id = v_on1), 'lobby', 'bcd touch space updated');
  perform public._t_throws(format($$select public.touch_world_online_session_v2(%L::uuid, null, 'MAIN_HALL', 'campus')$$, v_on2),
    '22023', 'bcd touch bad place zone refused', 'INVALID_PLACE_ZONE');
  perform public._t_throws(format($$select public.touch_world_online_session_v2(%L::uuid, null, null, 'moon')$$, v_on2),
    '22023', 'bcd touch bad space refused', 'INVALID_SPACE');
  perform public._t_throws($$select public.touch_world_online_session_v2(null, null, null, 'campus')$$,
    '22023', 'bcd touch null user refused', 'SESSION_ID_REQUIRED');
  perform public.touch_world_online_session_v2(v_on2, null, null, 'campus');
  perform public.touch_world_online_session_v2(v_on3, null, 'AREA_LIBRARY', 'club_room');
  -- stale row (80 s old) must not count; fresh rows must
  insert into public.world_online_sessions (session_id, user_id, place_zone_id, space, started_at, last_seen_at)
    values ('e3000000-0000-4000-8000-000000000008', null, 'AREA_MAIN_GATE', 'campus', now() - interval '80 seconds', now() - interval '80 seconds');
  v_count := public.get_world_online_count_v1();
  perform public._t_is((v_count ->> 'online')::int, 3, 'bcd count online = 3 fresh rows');
  perform public._t_is((v_count ->> 'signedIn')::int, 0, 'bcd count signedIn = 0 (Tier 4 user_id always NULL)');
  perform public._t_is((v_count ->> 'guests')::int, 3, 'bcd count guests = online');
  perform public._t_is((v_count ->> 'lobby')::int, 1, 'bcd count lobby = 1');
  perform public._t_is((v_count ->> 'campus')::int, 1, 'bcd count campus = 1');
  perform public._t_is((v_count ->> 'clubRoom')::int, 1, 'bcd count clubRoom = 1');
  perform public._t_is((v_count ->> 'housingLobby')::int, 0, 'bcd count housingLobby = 0');
  perform public._t_is((v_count ->> 'personalRoom')::int, 0, 'bcd count personalRoom = 0');
  perform public._t_is((v_count ->> 'asOf') is not null, true, 'bcd count asOf set');
  -- 1-day-old rows are deleted by a touch
  insert into public.world_online_sessions (session_id, user_id, place_zone_id, space, started_at, last_seen_at)
    values ('e3000000-0000-4000-8000-000000000009', null, null, 'campus', now() - interval '2 days', now() - interval '2 days');
  update public.world_online_sessions set last_seen_at = now() - interval '20 seconds' where session_id = v_on2;
  perform public.touch_world_online_session_v2(v_on2, null, null, 'campus');
  perform public._t_is((select count(*) from public.world_online_sessions where session_id = 'e3000000-0000-4000-8000-000000000009'), 0::bigint, 'bcd touch deletes 1-day-old rows');
  -- BCD fixture cleanup inside the transaction (the runner deletes the
  -- sessions/profiles afterwards; online rows and mail rows go here)
  delete from public.world_online_sessions where session_id in (v_on1, v_on2, v_on3,
    'e3000000-0000-4000-8000-000000000008', 'e3000000-0000-4000-8000-000000000009');
  delete from private.world_mail_verify_requests where user_id in (v_mail, v_dup);
  delete from public.inha_mail_badges where user_id in (v_mail, v_dup);
  delete from public.user_achievements where user_id in (v_mail, v_dup) and achievement_key = 'inha_verified_v1';
  delete from public.profiles where user_id in (v_mail, v_dup);
  delete from public.sessions where id in (v_mail::text, v_dup::text, v_on1::text, v_on2::text, v_on3::text); -- sessions.id is text
  -- NOTE: v_noprofile keeps the profile created above until the runner's
  -- cleanup (it deletes profiles for the oracle users); the nickname
  -- '새내기' is BCD-only and collides with nothing.
end
$do$;

-- =====================================================================
-- report
-- =====================================================================
\o
select (select count(*) filter (where ok) from public._t_results) || '/' || (select count(*) from public._t_results) || ' passed' as result;
select 'not ok ' || n || ' ' || name || ' (' || note || ')' from public._t_results where not ok order by n;
