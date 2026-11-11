-- Database-side equivalence oracle for schema.sql.
-- Port of the pgTAP suites in aldol2678/inhagame (read-only):
--   supabase/tests/database/10_hub_telemetry.test.sql
--   supabase/tests/database/91_world_asset_canary_remote_control.test.sql
-- to plain SQL (no pgTAP needed), with the Supabase `anon` role replaced by the
-- Worker's group role `inha_world_tier2_app`.
-- Not ported: get_inhagame_hub_ops_v1 (OPS summary) — out of Tier 2 scope.
--
-- Run ONLY against a disposable database or an isolated Neon branch that has
-- schema.sql applied. Everything happens in one transaction that is rolled
-- back, so nothing is left behind either way:
--   psql "$TEST_PG_URL" -v ON_ERROR_STOP=1 -q -f test-schema.sql
-- Exit code 0 and a final "N/N passed" line mean success.
begin;

-- A non-superuser owner (e.g. neondb_owner) may only SET ROLE to a role it is a
-- member of. Granted inside this transaction, so it is rolled back with it.
grant inha_world_tier2_app to current_user;

create table public._t_results (n serial, ok boolean not null, name text not null);
grant insert, select on public._t_results to public;
grant usage on sequence public._t_results_n_seq to public;

create function public._t_is(got anyelement, want anyelement, name text) returns void
language sql as $$
  insert into public._t_results(ok, name) values (got is not distinct from want, name);
$$;

-- passes when running `query` raises exactly `want_state`
create function public._t_throws(query text, want_state text, name text) returns void
language plpgsql as $$
begin
  begin
    execute query;
  exception when others then
    insert into public._t_results(ok, name) values (sqlstate = want_state, name);
    return;
  end;
  insert into public._t_results(ok, name) values (false, name);
end;
$$;

-- assertion calls print nothing; only the report at the end is shown
\o /dev/null

-- Fixed ids: s = session, v = visitor, c = hub click (= entry id), e = game stage event.
\set s1 '''a0000000-0000-4000-8000-000000000001'''
\set v1 '''b0000000-0000-4000-8000-000000000001'''
\set s2 '''a0000000-0000-4000-8000-000000000002'''
\set v2 '''b0000000-0000-4000-8000-000000000002'''
\set s3 '''a0000000-0000-4000-8000-000000000003'''
\set v3 '''b0000000-0000-4000-8000-000000000003'''
\set c_classic '''c0000000-0000-4000-8000-000000000001'''
\set c_induckup '''c0000000-0000-4000-8000-000000000002'''
\set c_campus '''c0000000-0000-4000-8000-000000000003'''
\set c_old '''c0000000-0000-4000-8000-000000000004'''
\set c_recent '''c0000000-0000-4000-8000-000000000005'''
\set c_profile '''c0000000-0000-4000-8000-000000000006'''
\set c_grow '''c0000000-0000-4000-8000-000000000007'''
\set e_land '''e0000000-0000-4000-8000-000000000001'''

-- ---- hub events (as the Worker role) ----
set local role inha_world_tier2_app;
select public._t_is(public.log_hub_event_v2(:c_classic, :s1, :v1, 'hub_game_click', 'home', 'classic'), true,
  'valid hub_game_click is accepted');
select public._t_is(public.log_hub_event_v2(:c_induckup, :s1, :v1, 'hub_game_click', 'ranking', 'induckup'), true,
  'hub_game_click from the ranking panel is accepted');
select public._t_is(public.log_hub_event_v2(:c_campus, :s1, :v1, 'campus_entry_click', 'home', 'campus'), true,
  'campus_entry_click is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s1, :v1, 'hub_visit', 'home'), true,
  'hub_visit with the default null target is accepted');
select public._t_is(public.log_hub_event_v2(:c_classic, :s1, :v1, 'hub_game_click', 'home', 'classic'), true,
  'a resent hub event_id is accepted (idempotent)');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s1, :v1, 'game_landing', 'game', 'classic'), false,
  'game stages cannot be written through the hub RPC');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s1, :v1, 'hub_purchase', 'home', null), false,
  'unsupported hub event type is refused');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s1, :v1, 'hub_game_click', 'home', 'campus'), false,
  'context check: hub_game_click cannot target campus');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s1, :v1, 'hub_game_click', 'home', 'tetris'), false,
  'unknown target is refused');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s1, :v1, 'hub_visit', 'lobby'), false,
  'unknown surface is refused');
select public._t_is(public.log_hub_event_v2(null, :s1, :v1, 'hub_visit', 'home'), false, 'null event_id is refused');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s1, :v1, 'hub_visit', 'home', null, 'javascript:bad', null), false,
  'unknown acquisition source is refused');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s1, :v1, 'hub_visit', 'home', null, 'direct', 'Bad Campaign!'), false,
  'malformed campaign is refused');
select public._t_throws($$select * from public.hub_events$$, '42501', 'the Worker role cannot read hub events');
select public._t_throws($$select * from public.game_entries$$, '42501', 'the Worker role cannot read game entries');
select public._t_throws($$select * from public.hub_events_all$$, '42501', 'the Worker role cannot read the combined view');
select public._t_throws(
  $$insert into public.hub_events(event_id, session_id, visitor_id, event_type, surface)
    values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'hub_visit', 'home')$$,
  '42501', 'the Worker role cannot insert hub events directly');
select public._t_throws(
  $$insert into public.game_entries(event_id, entry_id, session_id, visitor_id, event_type, target)
    values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'game_landing', 'classic')$$,
  '42501', 'the Worker role cannot insert game entries directly');
reset role;
select public._t_is((select count(*)::int from public.hub_events where event_id = :c_classic), 1,
  'the resent hub event is stored once');

-- ---- CORE-15 first-session funnel ----
set local role inha_world_tier2_app;
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'first_session_start', 'campus', null, 'direct', null), true,
  'CORE-15 first_session_start is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'first_goal_seen', 'campus', 'first_campus', 'direct', null), true,
  'CORE-15 first goal presentation is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'first_move', 'campus', null, 'direct', null), true,
  'CORE-15 first_move is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'first_zone_arrival', 'campus', null, 'direct', null), true,
  'CORE-15 first_zone_arrival is accepted without storing a raw zone id');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'first_npc_interaction', 'campus', null, 'direct', null), true,
  'CORE-15 first_npc_interaction is accepted without storing an NPC id');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'quest_started', 'campus', 'first_campus', 'direct', null), true,
  'CORE-15 first quest start is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'first_player_encounter', 'campus', null, 'direct', null), true,
  'CORE-15 first_player_encounter is accepted without storing another player id');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'first_activity_start', 'campus', 'inkyung_living', 'direct', null), true,
  'CORE-15 Inkyung activity start is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'first_activity_complete', 'campus', 'inkyung_living', 'direct', null), true,
  'CORE-15 Inkyung activity completion is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'first_reward', 'campus', 'first_campus', 'direct', null), true,
  'CORE-15 First Campus reward is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'reward_seen', 'campus', 'first_campus', 'direct', null), true,
  'CORE-15 visible First Campus reward is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'growth_seen', 'campus', 'first_campus', 'direct', null), true,
  'CORE-15 server growth readback is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'core_loop_complete', 'campus', 'first_campus', 'direct', null), true,
  'legacy CORE-15 reward-settlement loop completion is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'next_goal_seen', 'campus', 'main2_back_gate_guide', 'direct', null), true,
  'CORE-15 next goal presentation is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'core15_complete', 'campus', 'first_campus', 'direct', null), true,
  'Product CORE-15 completion is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'world_return', 'campus', null, 'direct', null), true,
  'CORE-15 world_return vocabulary is reserved for RETURN-1');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'next_discovery_click', 'campus', 'main2_back_gate_guide', 'direct', null), true,
  'CORE-15 next discovery click is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'first_reward', 'campus', null, 'direct', null), false,
  'CORE-15 reward must use the canonical first_campus target');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'first_player_encounter', 'campus', 'some-user-id', 'direct', null), false,
  'CORE-15 player encounter cannot store a player identifier');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s3, :v3, 'next_discovery_click', 'campus', 'unknown', 'direct', null), false,
  'CORE-15 next discovery target is allowlisted');
reset role;
select public._t_throws(
  format($$insert into public.hub_events(event_id, session_id, visitor_id, event_type, surface, target)
    values (gen_random_uuid(), %L, %L, 'first_reward', 'campus', null)$$, :s3, :v3),
  '23514', 'CORE-15 first_reward with a NULL target violates the table context check');
select public._t_throws(
  format($$insert into public.hub_events(event_id, session_id, visitor_id, event_type, surface, target)
    values (gen_random_uuid(), %L, %L, 'core15_complete', 'campus', null)$$, :s3, :v3),
  '23514', 'CORE-15 v2 core15_complete with a NULL target violates the table context check');
select public._t_is((select count(*)::int from public.hub_events where session_id = :s3), 17,
  'CORE-15 stores exactly the 17 canonical milestones and rejects privacy/context violations');

-- ---- game entry stages (as the Worker role, like /api/hub-entry) ----
set local role inha_world_tier2_app;
select public._t_is(public.log_game_entry_v1(:e_land, :c_classic, 'game_landing', 'classic'), true,
  'landing after a click is accepted');
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), :c_classic, 'game_landing', 'classic'), true,
  'a second landing for the same entry is accepted (idempotent)');
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), :c_classic, 'classic_ranked_start', 'classic'), true,
  'ranked start after landing is accepted');
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), :c_classic, 'game_play_start', 'classic'), true,
  'play after landing is accepted');
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), :c_classic, 'game_first_result', 'classic'), true,
  'first result after play is accepted');
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), :c_classic, 'game_retry', 'classic'), true,
  'retry after first result is accepted');
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), :c_classic, 'game_first_clear', 'classic'), true,
  'first clear after first result is accepted');
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), :c_campus, 'game_landing', 'campus'), true,
  'campus landing after campus_entry_click is accepted');
select public._t_is(public.log_hub_event_v2(:c_profile, :s1, :v1, 'profile_game_click', 'profile', 'survival'), true,
  'profile_game_click is accepted');
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), :c_profile, 'game_landing', 'survival'), true,
  'landing after a profile_game_click is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s1, :v1, 'profile_view', 'profile'), true,
  'profile_view is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s2, :v2, 'hub_visit', 'home', null,
  'everytime', 'induck_grow_v1_launch_20260925'), true,
  'Everytime launch hub_visit is accepted');
select public._t_is(public.log_hub_event_v2(:c_grow, :s2, :v2, 'hub_game_click', 'home', 'induck-grow',
  'everytime', 'induck_grow_v1_launch_20260925'), true,
  'hub_game_click for induck-grow with acquisition metadata is accepted');
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), :c_grow, 'game_landing', 'induck-grow'), true,
  'induck-grow landing is accepted');
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), :c_grow, 'game_play_start', 'induck-grow'), true,
  'induck-grow play after landing is accepted');
reset role;
select public._t_is((select acquisition_source from public.game_entries where entry_id = :c_grow and event_type = 'game_landing'),
  'everytime', 'entry stage inherits source from the hub click');
select public._t_is((select campaign from public.game_entries where entry_id = :c_grow and event_type = 'game_play_start'),
  'induck_grow_v1_launch_20260925', 'entry stage inherits campaign from the hub click');
select public._t_is(
  (select array_agg(event_type || '|' || target || '|' || surface || '|' || session_id || '|' || visitor_id order by event_type)
     from public.hub_events_all where entry_id = :c_classic),
  (select array_agg(t || '|classic|game|a0000000-0000-4000-8000-000000000001|b0000000-0000-4000-8000-000000000001' order by t)
     from unnest(array['classic_ranked_start','game_first_clear','game_first_result','game_landing','game_play_start','game_retry']) t),
  'one row per stage, attributed to the click''s target, session and visitor');
select public._t_is((select entry_id from public.game_entries where event_id = :e_land), :c_classic::uuid,
  'the landing keeps the event id the game sent');

set local role inha_world_tier2_app;
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), gen_random_uuid(), 'game_landing', 'classic'), false,
  'missing click: refused');
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), :c_induckup, 'game_play_start', 'induckup'), false,
  'play before landing: refused');
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), :c_induckup, 'game_first_result', 'induckup'), false,
  'first result before play: refused');
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), :c_classic, 'game_landing', 'induckup'), false,
  'cross-game reuse of an entry: refused');
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), :c_classic, 'game_landing', 'tetris'), false,
  'unknown target: refused');
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), :c_classic, 'hub_visit', 'classic'), false,
  'unsupported stage: refused');
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), :c_induckup, 'classic_ranked_start', 'induckup'), false,
  'ranked start outside classic: refused');
select public._t_is(public.log_game_entry_v1(null, :c_classic, 'game_landing', 'classic'), false,
  'null event_id: refused');
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), :e_land, 'game_landing', 'classic'), false,
  'a stage event is not a valid entry id');
select public._t_is(public.log_game_entry_v1(:e_land, :c_campus, 'game_play_start', 'campus'), true,
  'a duplicate event_id is accepted without effect (idempotent)');
-- event_id was unique across hub events and game stages in the original table
select public._t_is(public.log_game_entry_v1(:c_induckup, :c_campus, 'game_play_start', 'campus'), true,
  'an event_id already used by a hub event is accepted without effect');
select public._t_is(public.log_hub_event_v2(:e_land, :s1, :v1, 'hub_visit', 'home'), true,
  'an event_id already used by a game stage is accepted without effect');
reset role;
select public._t_is((select entry_id from public.game_entries where event_id = :e_land), :c_classic::uuid,
  'a duplicate event_id never overwrites the stored row');
select public._t_is((select count(*)::int from public.game_entries where entry_id = :c_campus and event_type = 'game_play_start'), 0,
  'the duplicate event_id did not create a play for the other entry');
select public._t_is((select count(*)::int from public.hub_events_all where event_id in (:e_land, :c_induckup)), 2,
  'event_id stays unique across hub events and game stages');

-- ---- entry expiry (30 minutes from the click) ----
insert into public.hub_events(event_id, session_id, visitor_id, event_type, surface, target, created_at) values
  (:c_old, :s1, :v1, 'hub_game_click', 'home', 'survival', now() - interval '31 minutes'),
  (:c_recent, :s1, :v1, 'hub_game_click', 'home', 'survival', now() - interval '29 minutes');
set local role inha_world_tier2_app;
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), :c_old, 'game_landing', 'survival'), false,
  'expired entry (31 minutes): refused');
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), :c_recent, 'game_landing', 'survival'), true,
  'entry within 30 minutes: accepted');
reset role;

-- ---- per-session rate limit: 120 events per hour, hub events + game stages ----
insert into public.hub_events(event_id, session_id, visitor_id, event_type, surface)
select gen_random_uuid(), 'a0000000-0000-4000-8000-0000000000ff', :v1, 'hub_visit', 'home' from generate_series(1, 120);
insert into public.hub_events(event_id, session_id, visitor_id, event_type, surface)
select gen_random_uuid(), 'a0000000-0000-4000-8000-0000000000fe', :v1, 'hub_visit', 'home' from generate_series(1, 119);
insert into public.hub_events(event_id, session_id, visitor_id, event_type, surface, target)
values ('c0000000-0000-4000-8000-0000000000fd', 'a0000000-0000-4000-8000-0000000000fd', :v1, 'hub_game_click', 'home', 'classic');
insert into public.hub_events(event_id, session_id, visitor_id, event_type, surface)
select gen_random_uuid(), 'a0000000-0000-4000-8000-0000000000fd', :v1, 'hub_visit', 'home' from generate_series(1, 118);
set local role inha_world_tier2_app;
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), 'a0000000-0000-4000-8000-0000000000ff', :v1, 'hub_visit', 'home'), false,
  'the 121st hub event in an hour for one session is refused');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), 'a0000000-0000-4000-8000-0000000000fe', :v1, 'hub_visit', 'home'), true,
  'the 120th hub event in an hour for one session is still accepted');
select public._t_is(public.log_game_entry_v1(gen_random_uuid(), 'c0000000-0000-4000-8000-0000000000fd', 'game_landing', 'classic'), true,
  'a game stage is stored for a session with 119 hub events');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), 'a0000000-0000-4000-8000-0000000000fd', :v1, 'hub_visit', 'home'), false,
  'game stages count toward the session limit, as in the single original table');
reset role;

-- ---- runtime flag: remote kill switch ----
select public._t_is((select count(*)::int from information_schema.tables
  where table_schema = 'public' and table_name = 'runtime_flags'), 1, 'runtime flag table exists');
set local role inha_world_tier2_app;
select public._t_is((select enabled from public.runtime_flags where flag = 'asset_glb_canary_v1'), false,
  'asset canary remote flag defaults disabled');
select public._t_is((select count(*)::int from public.runtime_flags where flag = 'unknown'), 0,
  'no unknown runtime flag row exists');
select public._t_throws(
  $$update public.runtime_flags set enabled = true where flag = 'asset_glb_canary_v1'$$,
  '42501', 'the Worker role cannot mutate runtime flags');
select public._t_throws(
  $$delete from public.runtime_flags where flag = 'asset_glb_canary_v1'$$,
  '42501', 'the Worker role cannot delete runtime flags');
select public._t_throws(
  $$insert into public.runtime_flags(flag, enabled) values ('asset_glb_canary_v1', true)$$,
  '42501', 'the Worker role cannot insert runtime flags');
reset role;
select public._t_throws(
  $$insert into public.runtime_flags(flag, enabled) values ('some_other_flag', true)$$,
  '23514', 'only the allowlisted flag name can exist');
update public.runtime_flags set enabled = true, updated_at = now() where flag = 'asset_glb_canary_v1';
set local role inha_world_tier2_app;
select public._t_is((select enabled from public.runtime_flags where flag = 'asset_glb_canary_v1'), true,
  'an operator update is visible to the Worker read path');

-- ---- asset canary telemetry ----
\set s '''93000000-0000-4000-8000-000000000001'''
\set v '''94000000-0000-4000-8000-000000000001'''
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s, :v,
  'asset_canary_selected', 'campus', 'induck_v3', 'direct', null), true,
  'asset canary selected telemetry is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s, :v,
  'asset_canary_active', 'campus', 'induck_v3', 'direct', null), true,
  'asset canary active telemetry is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s, :v,
  'asset_canary_rollback', 'campus', 'induck_v3', 'direct', null), true,
  'asset canary rollback telemetry is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s, :v,
  'asset_canary_failure', 'campus', 'induck_v3', 'direct', null), true,
  'asset canary failure telemetry is accepted');
select public._t_is(public.log_hub_event_v2(gen_random_uuid(), :s, :v,
  'asset_canary_active', 'campus', 'some-user-or-secret', 'direct', null), false,
  'asset canary telemetry target is fixed and cannot carry user context');
reset role;
select public._t_is((select count(*)::int from public.hub_events where session_id = :s), 4,
  'exactly four canonical asset canary telemetry events are stored');

-- ---- retention purge (new in Tier 2, not in the ported pgTAP suites) ----
reset role;
insert into public.hub_events(event_id, session_id, visitor_id, event_type, surface, target, created_at)
values ('f0000000-0000-4000-8000-000000000001', :s2, :v2, 'hub_visit', 'home', null, now() - interval '100 days'),
       ('f0000000-0000-4000-8000-000000000002', :s2, :v2, 'hub_visit', 'home', null, now());
insert into public.game_entries(event_id, entry_id, session_id, visitor_id, event_type, target, created_at)
values ('f0000000-0000-4000-8000-000000000003', :c_induckup, :s2, :v2, 'game_landing', 'induckup', now() - interval '100 days'),
       ('f0000000-0000-4000-8000-000000000004', :c_induckup, :s2, :v2, 'game_play_start', 'induckup', now());
set local role inha_world_tier2_app;
select public._t_is(public.purge_telemetry_90d(), 2,
  'purge deletes one old row from each table');
select public._t_is(public.purge_telemetry_90d(), 0,
  'purge is idempotent on a second run');
reset role;
select public._t_is((select count(*)::int from public.hub_events where event_id = 'f0000000-0000-4000-8000-000000000001'), 0,
  'the old hub row is gone');
select public._t_is((select count(*)::int from public.hub_events where event_id = 'f0000000-0000-4000-8000-000000000002'), 1,
  'the young hub row is kept');
select public._t_is((select count(*)::int from public.game_entries where event_id = 'f0000000-0000-4000-8000-000000000004'), 1,
  'the young game row is kept');

-- ---- report ----
\o
\pset tuples_only on
\pset format unaligned
select 'not ok ' || n || ' - ' || name from public._t_results where not ok order by n;
select count(*) filter (where ok) || '/' || count(*) || ' passed' from public._t_results;
do $$
begin
  if exists (select 1 from public._t_results where not ok) then
    raise exception 'schema oracle failed';
  end if;
end;
$$;
rollback;
