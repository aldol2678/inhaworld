-- Database-side equivalence oracle for schema.sql (Tier 3).
-- Port of the pgTAP suites in aldol2678/inhagame (read-only) to plain SQL:
--   30_inha_mail_badge, 40_ranked_lifecycle, 84_world_collection_discovery_p0,
--   87_world_fishing_f2, 99_world_fishing_f3, 99_world_fishing_skill_effects_p1
-- plus the transitions those suites leave to the handlers' integration tests:
-- the fishing state machine, the ranked run lifecycle, duck observation idempotency
-- and the mail badge claim.
--
-- Adapted, not copied:
--  * auth.users fixtures became public.sessions rows; the Supabase roles (anon,
--    authenticated, service_role) became the Worker role inha_world_tier3_app.
--  * "anonymous accounts are refused" assertions are gone (decision A), and so are the
--    "no profile / banned profile is refused" ones for the five world account gates
--    (guest-open decision, 2026-11-12): any existing session is a full account there.
--    Ranked runs and the mail badge still read public.profiles.
--  * RLS assertions became table-privilege assertions.
--  * Not ported because the function is outside Tier 3: my_inha_mail_badge(),
--    abandon_ranked_session_v1(), world_life_node_unlock_v1(), world_life_tree_reset_v1()
--    (the skill-effect fixture writes the node / reset rows directly instead), and
--    account-deletion cascades (there is no cascade from sessions).
--
-- Run ONLY against a disposable database or an isolated Neon branch that has
-- schema.sql applied. One transaction, rolled back at the end:
--   psql "$TEST_PG_URL" -v ON_ERROR_STOP=1 -q -f test-schema.sql
-- Exit code 0 and a final "N/N passed" line mean success. Takes ~3 s (it waits for
-- real fishing timers).
begin;

-- A non-superuser owner (e.g. neondb_owner) may only SET ROLE to a role it is a
-- member of. Granted inside this transaction, so it is rolled back with it.
grant inha_world_tier3_app to current_user;

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
insert into public.sessions (id, nickname) values
  (:alice, 'alice'), (:bob, 'bob'), (:banned, 'banned'), (:noprofile, 'noprofile');
insert into public.profiles (user_id, nickname, is_banned) values
  (:alice, 'tier3alice', false), (:bob, 'tier3bob', false), (:banned, 'tier3banned', true);

-- =====================================================================
-- identity: sessions replace auth.users
-- =====================================================================
select public._t_throws(format($$insert into public.profiles (user_id, nickname) values (%L, 'ghost')$$, :stranger),
  '23503', 'a profile needs an existing session (was: FK to auth.users)');
select public._t_throws(format($$insert into public.ranked_sessions (user_id) values (%L)$$, :stranger),
  '23503', 'a ranked session needs an existing session');
select public._t_throws(format($$insert into private.world_player_items (user_id, item_id, quantity) values (%L, 'material.fish_carp', 1)$$, :stranger),
  '23503', 'world state needs an existing session');
select public._t_is(private.world_activity_account_ok_v1(:alice), true, 'a session with a profile is an account');
select public._t_is(private.world_activity_account_ok_v1(:noprofile), true, 'guest-open: a session without a profile row is an account');
select public._t_is(private.world_activity_account_ok_v1(:banned), true, 'guest-open: the world gates no longer read the ban flag');
select public._t_is(private.world_activity_account_ok_v1(:stranger), false, 'an unknown id is not');
select public._t_is(private.world_activity_account_ok_v1(null), false, 'a null id is not');
select public._t_is(array[private.world_activity_account_ok_v1(u), private.world_collection_account_ok_v1(u), private.world_creature_account_ok_v1(u),
  private.world_inventory_account_ok_v1(u), private.world_life_skill_account_ok_v1(u)], array[ok, ok, ok, ok, ok],
  format('all five account gates agree for %s', label))
  from (values (:alice::uuid, true, 'alice'), (:noprofile::uuid, true, 'a guest'), (:banned::uuid, true, 'a banned profile'),
    (:stranger::uuid, false, 'an unknown id')) t(u, ok, label);
select public._t_is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'private' and p.proname ~ '^world_[a-z_]+_account_ok_v1$'
    and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~ 'profiles'), 0,
  'no world account gate reads public.profiles (comments aside)');
select public._t_is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public', 'private') and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~ '\mauth\.(uid|role|jwt|users)'), 0,
  'no function reads the Supabase auth schema (comments aside)');

-- =====================================================================
-- privileges (was: RLS + anon / authenticated / service_role grants)
-- =====================================================================
select public._t_is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'private' and c.relkind = 'r'
    and (has_table_privilege('inha_world_tier3_app', c.oid, 'SELECT') or has_table_privilege('inha_world_tier3_app', c.oid, 'INSERT')
      or has_table_privilege('inha_world_tier3_app', c.oid, 'UPDATE') or has_table_privilege('inha_world_tier3_app', c.oid, 'DELETE'))), 0,
  'the Worker role has no privilege on any private table');
select public._t_is(has_schema_privilege('inha_world_tier3_app', 'private', 'USAGE'), false,
  'the Worker role cannot even resolve the private schema');
select public._t_is((select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('inha_world_tier3_app', p.oid, 'EXECUTE') and p.proname !~ '^_t_'
    and exists (select 1 from aclexplode(p.proacl) a join pg_roles r on r.oid = a.grantee where r.rolname = 'inha_world_tier3_app')),
  array['expire_ranked_sessions_v1', 'get_my_rank_v3', 'record_ranked_result_v4', 'record_ranked_result_v5',
    'world_collection_list_v1', 'world_fishing_input_v1', 'world_fishing_observe_position_v1', 'world_fishing_read_v1',
    'world_fishing_settle_v1', 'world_fishing_start_v1', 'world_inkyung_duck_observe_v1'],
  'the Worker role can execute exactly the RPCs its handlers call (observe_position for the position feed)');
select public._t_is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public', 'private') and p.proname !~ '^_t_'
    and exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')), 0,
  'no Tier 3 function is executable by PUBLIC');
set local role inha_world_tier3_app;
select public._t_throws($$select public.claim_inha_mail_badge(gen_random_uuid(), gen_random_uuid())$$, '42501',
  'the Worker role cannot claim a mail badge (handler is 501)');
select public._t_throws($$select public.world_fishing_observe_position_v1(gen_random_uuid(), gen_random_uuid(), 1, 0, 0, 0, 'CAMPUS', 'ON_FOOT', clock_timestamp())$$,
  '22023', 'the Worker role may publish positions, but only for an existing session', 'ACCOUNT_UNAVAILABLE');
select public._t_throws($$select public.world_collection_discover_v1(gen_random_uuid(), 'collection.fish.carp', 'SYSTEM', 'x', null, 'k', null)$$,
  '42501', 'the Worker role cannot write discoveries directly');
select public._t_throws($$select * from public.inha_mail_badges$$, '42501', 'the Worker role cannot read the badge table');
select public._t_throws($$select * from public.ranked_runs$$, '42501', 'the Worker role cannot read stored runs');
select public._t_throws($$select nickname from public.profiles$$, '42501', 'the Worker role reads only user_id / is_banned of a profile');
select public._t_throws($$update public.profiles set is_banned = false$$, '42501', 'the Worker role cannot lift a ban');
select public._t_throws($$select nickname from public.sessions$$, '42501', 'the Worker role reads only the id of a session');
select public._t_throws($$insert into public.sessions (id, nickname) values ('x', 'x')$$, '42501', 'the Worker role cannot mint sessions');
select public._t_throws($$delete from public.ranked_sessions$$, '42501', 'the Worker role cannot delete ranked sessions');
select public._t_is((select is_banned from public.profiles where user_id = :banned), true, 'the Worker role can read a ban flag');
select public._t_is((select count(*)::int from public.sessions where id = :alice), 1, 'the Worker role can check that a session exists');
reset role;

-- =====================================================================
-- 84: collection discovery
-- =====================================================================
select public._t_is((select array_agg(entry_id || '|' || category || '|' || persistence_mode || '|' || coalesce(owner_domain, '-') || '|' || coalesce(owner_ref, '-') || '|' || status || '|' || definition_version order by entry_id)
  from private.world_collection_entry_catalog),
  array['collection.artifact.campus_fragment_01|ARTIFACT|SERVER_PERSISTED|-|-|COMING_SOON|1',
    'collection.fish.carp|FISH|SERVER_PERSISTED|-|-|ACTIVE|1',
    'collection.place.biryong_tower|PLACE|DERIVED_FROM_OWNER|BIRYONG|BR01|ACTIVE|1',
    'collection.plant.campus_leaf|PLANT|SERVER_PERSISTED|-|-|COMING_SOON|1'],
  'DB mirror matches the four code-registry authority rows (carp ACTIVE after 20261004161000)');
update private.world_collection_entry_catalog set status = 'COMING_SOON' where entry_id = 'collection.fish.carp';
select public._t_throws(format($$select public.world_collection_discover_v1(%L, 'collection.fish.carp', 'ACTIVITY', 'activity.fishing.inkyung', 'fishing_result:prelive', 'collection:test:prelive', null)$$, :alice),
  'P0001', 'COMING_SOON entry cannot be persistently discovered', 'COLLECTION_ENTRY_INACTIVE');
select public._t_throws(format($$select public.world_collection_discover_v1(%L, 'collection.place.biryong_tower', 'SYSTEM', 'BR01', null, 'collection:test:biryong', null)$$, :alice),
  'P0001', 'owner-derived Biryong fact cannot be duplicated', 'COLLECTION_WRITE_NOT_ALLOWED');
select public._t_is((select count(*)::int from private.world_collection_discovery_events), 0, 'refused writes create no discovery events');
update private.world_collection_entry_catalog set status = 'ACTIVE' where entry_id = 'collection.fish.carp';
select public._t_is(public.world_collection_discover_v1(:alice, 'collection.fish.carp', 'ACTIVITY', 'activity.fishing.inkyung',
  'fishing_result:catch_001', 'collection:fish:catch_001', '{"qualityBand":"COMMON"}'::jsonb)->>'status', 'DISCOVERED',
  'first verified result creates discovery');
select public._t_is(public.world_collection_discover_v1(:alice, 'collection.fish.carp', 'ACTIVITY', 'activity.fishing.inkyung',
  'fishing_result:catch_001', 'collection:fish:catch_001', '{"qualityBand":"COMMON"}'::jsonb)->>'status', 'ALREADY_PROCESSED',
  'same verified result replay is idempotent');
select public._t_throws(format($$select public.world_collection_discover_v1(%L, 'collection.fish.carp', 'ACTIVITY', 'activity.fishing.inkyung.spoof', 'fishing_result:catch_001', 'collection:fish:catch_001', '{"qualityBand":"COMMON"}'::jsonb)$$, :alice),
  '23505', 'same discovery key cannot change source identity', 'IDEMPOTENCY_CONFLICT');
select public._t_is((select count(*)::int from private.world_collection_discovery_events where idempotency_key = 'collection:fish:catch_001'), 1,
  'replay creates one event');
select public._t_is((select discovery_count || '|' || version || '|' || first_source_type || '|' || first_source_ref || '|' || first_result_ref
  from private.world_player_collection_discoveries where user_id = :alice and entry_id = 'collection.fish.carp'),
  '1|1|ACTIVITY|activity.fishing.inkyung|fishing_result:catch_001', 'first projection stores immutable first provenance');
select public._t_is(public.world_collection_discover_v1(:alice, 'collection.fish.carp', 'ACTIVITY', 'activity.fishing.inkyung',
  'fishing_result:catch_002', 'collection:fish:catch_002', '{"qualityBand":"UNCOMMON"}'::jsonb)->>'status', 'REDISCOVERED',
  'new verified result increments existing discovery');
select public._t_is((select discovery_count || '|' || version || '|' || first_result_ref
  from private.world_player_collection_discoveries where user_id = :alice and entry_id = 'collection.fish.carp'),
  '2|2|fishing_result:catch_001', 'rediscovery preserves first provenance and increments count/version');
set local role inha_world_tier3_app;
select public._t_is((select array_agg((x->>'entryId') || '|' || (x->>'persistenceMode') || '|' || (x->>'discoveryState') || '|' || coalesce(x->>'discovered', 'null') order by x->>'entryId')
  from jsonb_array_elements(public.world_collection_list_v1(:alice)->'entries') x),
  array['collection.artifact.campus_fragment_01|SERVER_PERSISTED|UNKNOWN|false',
    'collection.fish.carp|SERVER_PERSISTED|DISCOVERED|true',
    'collection.place.biryong_tower|DERIVED_FROM_OWNER|OWNER_DERIVED|null',
    'collection.plant.campus_leaf|SERVER_PERSISTED|UNKNOWN|false'],
  'server read distinguishes persisted unknown/discovered from owner-derived');
select public._t_is(public.world_collection_list_v1(:alice)->>'userId', :alice, 'the read is stamped with the session id it was made for');
select public._t_is((select x->>'discoveryState' from jsonb_array_elements(public.world_collection_list_v1(:bob)->'entries') x
  where x->>'entryId' = 'collection.fish.carp'), 'UNKNOWN', 'another session does not inherit discovery');
select public._t_is(jsonb_array_length(public.world_collection_list_v1(:noprofile)->'entries'), 4,
  'guest-open: a session without a profile has a collection book');
select public._t_is(public.world_collection_list_v1(:banned)->>'userId', :banned,
  'guest-open: a banned profile no longer blocks the collection book');
select public._t_throws(format($$select public.world_collection_list_v1(%L)$$, :stranger), '22023',
  'an unknown id has no collection book', 'ACCOUNT_UNAVAILABLE');
reset role;
select public._t_throws($$update private.world_collection_discovery_events set source_ref = 'changed' where idempotency_key = 'collection:fish:catch_001'$$,
  '42501', 'discovery event cannot be rewritten', 'COLLECTION_DISCOVERY_EVENT_APPEND_ONLY');
select public._t_throws(format($$update private.world_player_collection_discoveries set first_source_ref = 'changed', discovery_count = discovery_count + 1,
  version = version + 1, last_discovered_at = now(), updated_at = now() where user_id = %L and entry_id = 'collection.fish.carp'$$, :alice),
  '42501', 'first provenance cannot be rewritten', 'COLLECTION_FIRST_PROVENANCE_IMMUTABLE');
select public._t_throws(format($$update private.world_player_collection_discoveries set discovery_count = discovery_count + 2,
  version = version + 1, last_discovered_at = now(), updated_at = now() where user_id = %L and entry_id = 'collection.fish.carp'$$, :alice),
  '23514', 'projection count/version advance by one verified event', 'COLLECTION_PROJECTION_INVALID');
select public._t_is(public.world_collection_discover_v1(:noprofile, 'collection.fish.carp', 'SYSTEM', 'test', null, 'collection:guest:001', null)->>'status',
  'DISCOVERED', 'guest-open: a session without a profile can be credited a discovery');
select public._t_throws(format($$select public.world_collection_discover_v1(%L, 'collection.fish.carp', 'SYSTEM', 'test', null, 'collection:stranger:001', null)$$, :stranger),
  '22023', 'an unknown id has no persistent Collection Discovery', 'ACCOUNT_UNAVAILABLE');

-- =====================================================================
-- 87 / 99: fishing runtime, policy, presence, skill effects
-- =====================================================================
select public._t_is((select count(*)::int from pg_tables where schemaname = 'private' and tablename = 'world_fishing_settlements'), 0,
  'fishing has no per-activity settlement table');
select public._t_is((select bridge.activity_id from private.world_life_creature_bridge_catalog bridge where bridge.life_skill_id = 'life.fishing'),
  'activity.fishing.inkyung', 'fishing activity is the mapped Life -> Creature bridge activity');
select public._t_is((select enabled from private.world_fishing_runtime), true, 'runtime is enabled');
select public._t_is((select policy from private.world_fishing_runtime),
  '{"policyVersion":"fishing.candidate.v1","minWaitMs":3000,"maxWaitMs":9000,"responseWindowMs":1500,"attemptTtlMs":30000,"lifeXp":20}'::jsonb,
  'the candidate policy is explicit');
select public._t_is((select minimum_start_interval_ms from private.world_fishing_runtime), 2000::bigint, 'the candidate start interval is explicit');
select public._t_is((select presence_required from private.world_fishing_runtime), true, 'authoritative position is required by default');
select public._t_is((select count(*)::int from private.world_fishing_spots), 2, 'two shore spots have server geometry');
select public._t_is((select status from private.world_life_skill_catalog where skill_id = 'life.fishing'), 'ACTIVE', 'fishing skill is active');
select public._t_is((select count(*)::int from private.world_life_skill_catalog where status <> 'COMING_SOON'), 1, 'Fishing is the only active Life Skill');
select public._t_is((select array_agg(node_id order by node_id) from private.world_life_skill_tree_catalog where status = 'ACTIVE'),
  array['life.node.fishing.fish_sense', 'life.node.fishing.steady_hands'], 'only the two implemented Fishing timing nodes are active');
select public._t_is((select status from private.world_creature_activity_bridge_catalog where bridge_id = 'creature.bridge.activity.fishing'),
  'COMING_SOON', 'the fishing Creature bridge stays inactive');
select public._t_throws($$select private.world_fishing_policy_validate_v1(null)$$, '22023', 'missing policy refused', 'FISHING_POLICY_INVALID');
select public._t_throws($$select private.world_fishing_policy_validate_v1('{"policyVersion":"test.f2","minWaitMs":1,"maxWaitMs":1,"responseWindowMs":10,"attemptTtlMs":11,"lifeXp":1}')$$,
  '22023', 'TTL must exceed final response window', 'FISHING_POLICY_INVALID');
select public._t_throws($$select private.world_fishing_policy_validate_v1('{"policyVersion":"test.f2","minWaitMs":1,"maxWaitMs":1,"responseWindowMs":10,"attemptTtlMs":12,"lifeXp":-1}')$$,
  '22023', 'negative XP refused', 'FISHING_POLICY_INVALID');
select public._t_throws($$select private.world_fishing_policy_validate_v1('{"policyVersion":"test.f2","minWaitMs":1,"maxWaitMs":1,"responseWindowMs":10,"attemptTtlMs":12,"lifeXp":1000001}')$$,
  '22023', 'XP above the settlement plan cap refused', 'FISHING_POLICY_INVALID');

-- skill effects (fixture rows written directly: the unlock / reset RPCs are outside Tier 3)
select public._t_is(private.world_life_skill_xp_apply_v1(:bob, 'life.fishing', 1500, 'activity', 'activity.fishing.inkyung:effects', 'fishing-effects:xp')->>'status',
  'SUCCESS', 'fixture reaches Fishing Lv6');
with tx as (
  insert into private.world_life_sp_transactions (user_id, node_id, sp_cost, sp_before, sp_after, idempotency_key, skill_id, rank, epoch)
  values (:bob, 'life.node.fishing.steady_hands', 1, 6, 5, 'fx:steady:3', 'life.fishing', 3, 0),
         (:bob, 'life.node.fishing.fish_sense', 1, 5, 4, 'fx:sense:3', 'life.fishing', 3, 0)
  returning transaction_id, node_id, rank
) insert into private.world_player_life_nodes (user_id, node_id, transaction_id, rank, epoch)
  select :bob, node_id, transaction_id, rank, 0 from tx;
select public._t_is(private.world_fishing_skill_effects_v1(:bob),
  jsonb_build_object('version', 'fishing.skill_effects.v1', 'steadyHandsRank', 3, 'fishSenseRank', 3, 'responseWindowBonusMs', 750, 'waitReductionMs', 750),
  'current tree epoch produces bounded Fishing effects');
select public._t_is(private.world_fishing_apply_skill_effects_v1(
  jsonb_build_object('policyVersion', 'fishing.candidate.v1', 'minWaitMs', 3000, 'maxWaitMs', 9000, 'responseWindowMs', 1500, 'attemptTtlMs', 30000, 'lifeXp', 20),
  private.world_fishing_skill_effects_v1(:bob)),
  jsonb_build_object('policyVersion', 'fishing.candidate.v1', 'minWaitMs', 2250, 'maxWaitMs', 8250, 'responseWindowMs', 2250, 'attemptTtlMs', 30000, 'lifeXp', 20),
  'rank 3 effects alter only wait and response timing');
select public._t_throws($$select private.world_fishing_apply_skill_effects_v1(
  jsonb_build_object('policyVersion', 'fishing.candidate.v1', 'minWaitMs', 3000, 'maxWaitMs', 9000, 'responseWindowMs', 1500, 'attemptTtlMs', 30000, 'lifeXp', 20),
  jsonb_build_object('version', 'fishing.skill_effects.v1', 'steadyHandsRank', 3, 'fishSenseRank', 3, 'responseWindowBonusMs', 751, 'waitReductionMs', 750))$$,
  '22023', 'forged effect numbers are refused', 'FISHING_SKILL_EFFECT_INVALID');
select public._t_is(private.world_fishing_project_v1(jsonb_build_object('attemptId', gen_random_uuid(),
  'policy', jsonb_build_object('policyVersion', 'fixture'), 'skillEffects', private.world_fishing_skill_effects_v1(:bob))) ? 'skillEffects', false,
  'server-private effect snapshot is not projected to the browser');
insert into private.world_life_tree_resets (user_id, skill_id, epoch, refunded_sp, cleared_ranks, cooldown_seconds, idempotency_key)
  values (:bob, 'life.fishing', 1, 2, '[]'::jsonb, 0, 'fx:reset');
select public._t_is(private.world_fishing_skill_effects_v1(:bob),
  jsonb_build_object('version', 'fishing.skill_effects.v1', 'steadyHandsRank', 0, 'fishSenseRank', 0, 'responseWindowBonusMs', 0, 'waitReductionMs', 0),
  'a new tree epoch immediately removes effects for the next cast');

-- =====================================================================
-- fishing state machine (as the Worker role, through the four RPCs)
-- =====================================================================
\set k1 '''f1000000-0000-4000-8000-000000000001'''
\set k2 '''f2000000-0000-4000-8000-000000000002'''
\set k3 '''f3000000-0000-4000-8000-000000000003'''
\set k4 '''f4000000-0000-4000-8000-000000000004'''
\set k5 '''f5000000-0000-4000-8000-000000000005'''
\set k6 '''f6000000-0000-4000-8000-000000000006'''
\set north '''fishing.inkyung.north_01'''
\set south '''fishing.inkyung.south_01'''
-- deterministic timing for the oracle: bite 1 ms after the cast, 20 s to respond
update private.world_fishing_runtime set presence_required = false, minimum_start_interval_ms = 1,
  policy = '{"policyVersion":"fishing.oracle.v1","minWaitMs":1,"maxWaitMs":1,"responseWindowMs":20000,"attemptTtlMs":30000,"lifeXp":20}';
set local role inha_world_tier3_app;
select public._t_throws(format($$select public.world_fishing_start_v1(%L, %L, %L)$$, :stranger, :north, :k1), '22023',
  'start: an unknown id is refused', 'ACCOUNT_UNAVAILABLE');
select public._t_is(public.world_fishing_read_v1(:noprofile)->'inventory'->>'itemId', 'material.fish_carp',
  'guest-open: a session without a profile can read its fishing state');
select public._t_throws(format($$select public.world_fishing_start_v1(%L, 'fishing.inkyung.west_01', %L)$$, :alice, :k1), '22023',
  'start: unknown spot', 'INVALID_FISHING_IDENTITY');
select public._t_throws(format($$select public.world_fishing_read_v1(%L, %L)$$, :alice, :k1), 'P0002', 'read: unknown attempt', 'ATTEMPT_NOT_FOUND');
select public._t_is(public.world_fishing_read_v1(:alice)->>'attempt', null, 'read with no attempt yet returns a null attempt');
select public._t_is(public.world_fishing_read_v1(:alice)->>'settlement', 'NOT_REQUIRED', 'and nothing to settle');
create temp table _fx on commit drop as select public.world_fishing_start_v1(:alice, :north, :k1) as r;
grant select on _fx to public;
select public._t_is((select r->>'status' from _fx), 'STARTED', 'start: ACTIVE attempt created');
select public._t_is((select r->'attempt'->>'status' from _fx), 'ACTIVE', 'the projected attempt is ACTIVE');
select public._t_is((select (r->'attempt') ?| array['actorUserId', 'policy', 'skillEffects', 'resolverVersion', 'terminalAction'] from _fx), false,
  'server-private fields are not projected');
select public._t_is((select ((r->'attempt'->>'biteAtMs')::bigint - (r->'attempt'->>'startedAtMs')::bigint)::int from _fx), 1, 'bite time follows the frozen policy');
select public._t_is(public.world_fishing_start_v1(:alice, :north, :k1)->>'status', 'ALREADY_PROCESSED', 'start: same key replays');
select public._t_throws(format($$select public.world_fishing_start_v1(%L, %L, %L)$$, :alice, :south, :k1), '23505',
  'start: same key for another spot conflicts', 'IDEMPOTENCY_CONFLICT');
select public._t_throws(format($$select public.world_fishing_start_v1(%L, %L, %L)$$, :alice, :south, :k2), 'P0001',
  'start: one active attempt per session', 'ATTEMPT_ALREADY_ACTIVE');
select public._t_throws(format($$select public.world_fishing_settle_v1(%L, %L)$$, :alice, (select r->'attempt'->>'attemptId' from _fx)), 'P0001',
  'settle: an ACTIVE attempt cannot settle', 'FISHING_NOT_SUCCEEDED');
select public._t_throws(format($$select public.world_fishing_input_v1(%L, %L, %L, %L, 'HOOK')$$, :alice, (select r->'attempt'->>'attemptId' from _fx), :south, (select r->'attempt'->>'nonce' from _fx)),
  '22023', 'input: wrong spot', 'FISHING_IDENTITY_MISMATCH');
select public._t_throws(format($$select public.world_fishing_input_v1(%L, %L, %L, %L, 'HOOK')$$, :alice, (select r->'attempt'->>'attemptId' from _fx), :north, :k6),
  '22023', 'input: wrong nonce', 'FISHING_IDENTITY_MISMATCH');
select public._t_throws(format($$select public.world_fishing_input_v1(%L, %L, %L, %L, 'REEL')$$, :alice, (select r->'attempt'->>'attemptId' from _fx), :north, (select r->'attempt'->>'nonce' from _fx)),
  '22023', 'input: unknown action', 'INVALID_FISHING_ACTION');
select public._t_throws(format($$select public.world_fishing_input_v1(%L, %L, %L, %L, 'HOOK')$$, :bob, (select r->'attempt'->>'attemptId' from _fx), :north, (select r->'attempt'->>'nonce' from _fx)),
  'P0002', 'input: another session cannot touch the attempt', 'ATTEMPT_NOT_FOUND');
select pg_sleep(0.02);
create temp table _fh on commit drop as
  select public.world_fishing_input_v1(:alice, (r->'attempt'->>'attemptId')::uuid, :north, (r->'attempt'->>'nonce')::uuid, 'HOOK') as r from _fx;
grant select on _fh to public;
select public._t_is((select r->>'status' from _fh), 'RESOLVED', 'ACTIVE -> HOOK inside the window resolves');
select public._t_is((select r->'attempt'->>'status' from _fh), 'SUCCEEDED', 'ACTIVE -> SUCCEEDED');
select public._t_is((select r->'attempt'->'result'->>'reason' from _fh), 'CAUGHT', 'reason CAUGHT');
select public._t_is((select r->'attempt'->'result'->'catch'->>'itemId' from _fh), 'material.fish_carp', 'the catch is a carp');
select public._t_is(public.world_fishing_input_v1(:alice, (select (r->'attempt'->>'attemptId')::uuid from _fx), :north, (select (r->'attempt'->>'nonce')::uuid from _fx), 'HOOK')->>'status',
  'ALREADY_PROCESSED', 'HOOK replay on a terminal attempt is idempotent');
select public._t_throws(format($$select public.world_fishing_input_v1(%L, %L, %L, %L, 'CANCEL')$$, :alice, (select r->'attempt'->>'attemptId' from _fx), :north, (select r->'attempt'->>'nonce' from _fx)),
  '23505', 'a different terminal command conflicts', 'TERMINAL_COMMAND_CONFLICT');
select public._t_is(public.world_fishing_read_v1(:alice)->>'settlement', 'PENDING', 'SUCCEEDED and unsettled reads PENDING');
create temp table _fs on commit drop as select public.world_fishing_settle_v1(:alice, (r->'attempt'->>'attemptId')::uuid) as r from _fx;
grant select on _fs to public;
select public._t_is((select r->>'status' from _fs), 'SETTLED', 'SUCCEEDED -> SETTLED');
select public._t_is(public.world_fishing_settle_v1(:alice, (select (r->'attempt'->>'attemptId')::uuid from _fx))->>'status', 'ALREADY_PROCESSED',
  'settling again is idempotent');
select public._t_is(public.world_fishing_read_v1(:alice)->>'settlement', 'SETTLED', 'read reports SETTLED');
select public._t_is((public.world_fishing_read_v1(:alice)->'inventory'->>'quantity')::int, 1, 'one carp in the inventory');
select public._t_is((public.world_fishing_read_v1(:alice)->'lifeSkill'->>'totalXp')::int, 20, 'fishing XP granted once');
select public._t_is(public.world_fishing_read_v1(:alice)->'discovery'->>'discoveryState', 'DISCOVERED', 'carp is discovered');
-- CANCEL
create temp table _fc on commit drop as select public.world_fishing_start_v1(:alice, :south, :k2) as r;
grant select on _fc to public;
select public._t_is(public.world_fishing_input_v1(:alice, (select (r->'attempt'->>'attemptId')::uuid from _fc), :south, (select (r->'attempt'->>'nonce')::uuid from _fc), 'CANCEL')->'attempt'->>'status',
  'CANCELLED', 'ACTIVE -> CANCELLED');
select public._t_is(public.world_fishing_input_v1(:alice, (select (r->'attempt'->>'attemptId')::uuid from _fc), :south, (select (r->'attempt'->>'nonce')::uuid from _fc), 'CANCEL')->>'status',
  'ALREADY_PROCESSED', 'CANCEL replay is idempotent');
select public._t_throws(format($$select public.world_fishing_settle_v1(%L, %L)$$, :alice, (select r->'attempt'->>'attemptId' from _fc)), 'P0001',
  'a cancelled attempt cannot settle', 'FISHING_NOT_SUCCEEDED');
reset role;
-- premature HOOK
update private.world_fishing_runtime set policy = '{"policyVersion":"fishing.oracle.v1","minWaitMs":5000,"maxWaitMs":5000,"responseWindowMs":1000,"attemptTtlMs":30000,"lifeXp":20}';
set local role inha_world_tier3_app;
create temp table _fp on commit drop as select public.world_fishing_start_v1(:alice, :north, :k3) as r;
grant select on _fp to public;
select public._t_is(public.world_fishing_input_v1(:alice, (select (r->'attempt'->>'attemptId')::uuid from _fp), :north, (select (r->'attempt'->>'nonce')::uuid from _fp), 'HOOK')->'attempt'->'result'->>'reason',
  'PREMATURE_HOOK', 'ACTIVE -> FAILED (HOOK before the bite)');
reset role;
-- missed bite, then expiry
update private.world_fishing_runtime set policy = '{"policyVersion":"fishing.oracle.v1","minWaitMs":1,"maxWaitMs":1,"responseWindowMs":1,"attemptTtlMs":300,"lifeXp":20}';
set local role inha_world_tier3_app;
create temp table _fm on commit drop as select public.world_fishing_start_v1(:alice, :north, :k4) as r;
grant select on _fm to public;
select pg_sleep(0.05);
select public._t_is(public.world_fishing_input_v1(:alice, (select (r->'attempt'->>'attemptId')::uuid from _fm), :north, (select (r->'attempt'->>'nonce')::uuid from _fm), 'HOOK')->'attempt'->'result'->>'reason',
  'MISSED_BITE', 'ACTIVE -> FAILED (HOOK after the window)');
create temp table _fe on commit drop as select public.world_fishing_start_v1(:alice, :south, :k5) as r;
grant select on _fe to public;
select pg_sleep(0.4);
select public._t_is(public.world_fishing_read_v1(:alice)->'attempt'->>'status', 'EXPIRED', 'ACTIVE -> EXPIRED, reconciled by a read');
select public._t_is(public.world_fishing_input_v1(:alice, (select (r->'attempt'->>'attemptId')::uuid from _fe), :south, (select (r->'attempt'->>'nonce')::uuid from _fe), 'HOOK')->>'status',
  'ALREADY_PROCESSED', 'any command after expiry is ALREADY_PROCESSED');
reset role;
select public._t_is((select array_agg((snapshot->>'status') || ':' || coalesce(snapshot->>'terminalAction', '-') order by (snapshot->>'startedAtMs')::bigint)
  from private.world_fishing_attempt_snapshots where user_id = :alice),
  array['SUCCEEDED:HOOK', 'CANCELLED:CANCEL', 'FAILED:HOOK', 'FAILED:HOOK', 'EXPIRED:EXPIRE'], 'every terminal state was reached once');
select public._t_is((select count(*)::int from private.world_activity_settlements where user_id = :alice), 1, 'exactly one settlement receipt');
select public._t_throws(format($$update private.world_fishing_attempt_snapshots set snapshot = snapshot || '{"status":"SUCCEEDED"}' where user_id = %L and snapshot->>'status' = 'CANCELLED'$$, :alice),
  '42501', 'a terminal snapshot cannot be rewritten');
select public._t_throws($$delete from private.world_activity_settlements$$, '42501', 'settlement receipts are append-only while the session exists', 'ACTIVITY_SETTLEMENT_APPEND_ONLY');
-- rate limit, disabled runtime, presence
update private.world_fishing_runtime set minimum_start_interval_ms = 60000;
set local role inha_world_tier3_app;
select public._t_throws(format($$select public.world_fishing_start_v1(%L, %L, %L)$$, :alice, :north, :k6), 'P0001', 'start: minimum interval', 'FISHING_RATE_LIMITED');
reset role;
update private.world_fishing_runtime set minimum_start_interval_ms = 1, enabled = false;
set local role inha_world_tier3_app;
select public._t_throws(format($$select public.world_fishing_start_v1(%L, %L, %L)$$, :alice, :north, :k6), 'P0001', 'start: runtime disabled', 'FISHING_UNAVAILABLE');
reset role;
update private.world_fishing_runtime set enabled = true, presence_required = true,
  policy = '{"policyVersion":"fishing.oracle.v1","minWaitMs":1,"maxWaitMs":1,"responseWindowMs":20000,"attemptTtlMs":30000,"lifeXp":20}';
set local role inha_world_tier3_app;
select public._t_throws(format($$select public.world_fishing_start_v1(%L, %L, %L)$$, :alice, :north, :k6), 'P0001',
  'start: presence required and no position', 'FISHING_POSITION_UNAVAILABLE');
reset role;
select public._t_is(public.world_fishing_observe_position_v1(:alice, :k1, 1, (select x from private.world_fishing_spots where source_ref = :north) + 500,
  (select (min_y + max_y) / 2 from private.world_fishing_spots where source_ref = :north), (select z from private.world_fishing_spots where source_ref = :north),
  'CAMPUS', 'ON_FOOT', clock_timestamp())->>'status', 'OBSERVED', 'a trusted position is recorded');
set local role inha_world_tier3_app;
select public._t_throws(format($$select public.world_fishing_start_v1(%L, %L, %L)$$, :alice, :north, :k6), 'P0001', 'start: too far from the spot', 'FISHING_OUT_OF_RANGE');
reset role;
select public._t_is(public.world_fishing_observe_position_v1(:alice, :k1, 2, (select x from private.world_fishing_spots where source_ref = :north),
  (select (min_y + max_y) / 2 from private.world_fishing_spots where source_ref = :north), (select z from private.world_fishing_spots where source_ref = :north),
  'CAMPUS', 'ON_FOOT', clock_timestamp())->>'status', 'OBSERVED', 'a newer position replaces it');
select public._t_is(public.world_fishing_observe_position_v1(:bob, :k2, 1, (select x from private.world_fishing_spots where source_ref = :north),
  (select (min_y + max_y) / 2 from private.world_fishing_spots where source_ref = :north), (select z from private.world_fishing_spots where source_ref = :north),
  'CAMPUS', 'ON_FOOT', clock_timestamp())->>'status', 'OBSERVED', 'a second session stands on the same spot');
set local role inha_world_tier3_app;
select public._t_is(public.world_fishing_start_v1(:alice, :north, :k6)->>'status', 'STARTED', 'start: in range takes the spot lease');
select public._t_throws(format($$select public.world_fishing_start_v1(%L, %L, %L)$$, :bob, :north, :k5), 'P0001', 'start: the spot is leased', 'FISHING_SPOT_OCCUPIED');
select public._t_is(public.world_fishing_input_v1(:alice, (public.world_fishing_read_v1(:alice)->'attempt'->>'attemptId')::uuid, :north,
  (public.world_fishing_read_v1(:alice)->'attempt'->>'nonce')::uuid, 'CANCEL')->'attempt'->>'status', 'CANCELLED', 'CANCEL needs no live position');
select public._t_is(public.world_fishing_start_v1(:bob, :north, :k5)->>'status', 'STARTED', 'the lease is released with the attempt');
reset role;

-- =====================================================================
-- world_inkyung_duck_observe_v1
-- =====================================================================
select public._t_is((select array_agg(duck_id || ':' || kind || ':' || status order by duck_id) from private.world_inkyung_duck_observation_subjects),
  array['inkyung_duck_mallard_01:mallard:ACTIVE', 'inkyung_duck_white_01:white:ACTIVE', 'inkyung_duck_white_02:white:ACTIVE', 'inkyung_duck_white_03:white:ACTIVE'],
  'the four observation subjects are seeded');
set local role inha_world_tier3_app;
select public._t_is(public.world_inkyung_duck_observe_v1(:alice, 'inkyung_duck_white_01', 'duck-observation:a:1', 'duck-observe:a:1')->>'status', 'SUCCESS',
  'first observation of a duck succeeds');
select public._t_is(public.world_inkyung_duck_observe_v1(:alice, 'inkyung_duck_white_01', 'duck-observation:a:1', 'duck-observe:a:1')->>'status', 'ALREADY_PROCESSED',
  'observing the same duck again is idempotent');
select public._t_is(public.world_inkyung_duck_observe_v1(:alice, 'inkyung_duck_white_02', 'duck-observation:a:2', 'duck-observe:a:2')->>'duckId', 'inkyung_duck_white_02',
  'a second duck is a second observation');
select public._t_throws(format($$select public.world_inkyung_duck_observe_v1(%L, 'inkyung_duck_mechanical_01', 'r', 'k')$$, :alice), 'P0001',
  'an unknown duck is not observable (handler: 409)', 'INKYUNG_DUCK_NOT_OBSERVABLE');
select public._t_throws(format($$select public.world_inkyung_duck_observe_v1(%L, 'Not A Duck', 'r', 'k')$$, :alice), '22023',
  'a malformed duck id is refused', 'INVALID_INKYUNG_DUCK_ID');
select public._t_is(public.world_inkyung_duck_observe_v1(:noprofile, 'inkyung_duck_white_03', 'r3', 'k3')->>'status', 'SUCCESS',
  'guest-open: a session without a profile can observe');
select public._t_is(public.world_inkyung_duck_observe_v1(:banned, 'inkyung_duck_white_03', 'r4', 'k4')->>'status', 'SUCCESS',
  'guest-open: a banned profile no longer blocks observation');
select public._t_throws(format($$select public.world_inkyung_duck_observe_v1(%L, 'inkyung_duck_white_03', 'r5', 'k5')$$, :stranger), '22023',
  'an unknown id cannot observe (handler: 403)');
reset role;
select public._t_is((select count(*)::int from private.world_creature_observation_events where user_id = :alice), 2, 'two ducks, two ledger rows');
select public._t_throws($$delete from private.world_creature_observation_events$$, '42501', 'the observation ledger is append-only while the session exists');

-- =====================================================================
-- 40: ranked run lifecycle
-- =====================================================================
\set run_open '''f1000000-0000-4000-8000-0000000000a1'''
\set run_stale '''f2000000-0000-4000-8000-0000000000a2'''
\set run_bob '''f3000000-0000-4000-8000-0000000000a3'''
\set run_qa '''f4000000-0000-4000-8000-0000000000a4'''
\set run_v5 '''f5000000-0000-4000-8000-0000000000a5'''
insert into public.ranked_sessions (run_id, user_id, started_at, expires_at, status) values
  (:run_open, :alice, now(), now() + interval '5 minutes', 'started'),
  (:run_stale, :alice, now() - interval '10 minutes', now() - interval '5 minutes', 'started'),
  (:run_bob, :bob, now(), now() + interval '5 minutes', 'started');
select public.ranked_grade_code(100, 0, 0, 0, 0) as grade100 \gset
select public._t_is((select nonce is not null and expires_at > started_at from public.ranked_sessions where run_id = :run_open), true,
  'sessions get a nonce and an expiry');
set local role inha_world_tier3_app;
select public._t_is((public.expire_ranked_sessions_v1() >= 1), true, 'overdue sessions are expired');
reset role;
select public._t_is((select status || ':' || (expired_at = expires_at) from public.ranked_sessions where run_id = :run_stale), 'expired:true',
  'expired_at is the session''s own expiry');
select public._t_is((select status from public.ranked_sessions where run_id = :run_bob), 'started', 'open sessions are left alone');
set local role inha_world_tier3_app;
select public._t_throws(format($$select public.record_ranked_result_v4(%L, %L, 100, 5, 0, 0, 0, 20, 0, 20, 0, 0, 0, 0, 30000, 'c', 0, 0, 0, false, '{}')$$, :run_open, :alice),
  'P0001', 'a result needs a submitted session', 'ranked session not submitted');
update public.ranked_sessions set status = 'submitted', submitted_at = now() where run_id = :run_open and status = 'started';
select public._t_throws(format($$select public.record_ranked_result_v4(%L, %L, 100, 5, 0, 0, 0, 20, 0, 20, 0, 0, 0, 0, 30000, 'c', 0, 0, 0, false, '{}')$$, :run_open, :bob),
  'P0001', 'a result cannot be recorded for another session''s run', 'ranked session not submitted');
select public._t_is(public.record_ranked_result_v4(:run_open, :alice, 100, 5, 0, 0, 0, 20, 0, 20, 0, 0, 0, 0, 30000, 'c', 0, 0, 0, false, '{}') is not null, true,
  'v4 records an accepted run');
select public._t_is((select status from public.ranked_sessions where run_id = :run_open), 'accepted', 'submitted -> accepted');
select public._t_throws(format($$select public.record_ranked_result_v4(%L, %L, 100, 5, 0, 0, 0, 20, 0, 20, 0, 0, 0, 0, 30000, 'c', 0, 0, 0, false, '{}')$$, :run_open, :alice),
  'P0001', 'an accepted run cannot be recorded twice', 'ranked session not submitted');
select public._t_is((select best_score::text || '|' || overall_rank || '|' || department_rank || '|' || ranked_grade from public.get_my_rank_v3(:alice)),
  '100|1|1|' || :'grade100', 'get_my_rank_v3 takes the session id and ranks the first best');
select public._t_is((select count(*)::int from public.get_my_rank_v3(:bob)), 0, 'a session without a best has no rank row');
-- a lower score never replaces the best; a qa run never touches it
insert into public.ranked_sessions (run_id, user_id, status, run_type, ruleset_version) values
  (:run_qa, :alice, 'submitted', 'qa', 'secret-2.1-r1'), (:run_v5, :bob, 'submitted', 'ranked', 'secret-2.2-r1');
select public._t_is(public.record_ranked_result_v4(:run_qa, :alice, 900, 9, 0, 0, 0, 60, 0, 60, 0, 0, 0, 0, 30000, null, 0, 0, 0, false, null) is not null, true,
  'a qa run is recorded');
select public._t_is(public.record_ranked_result_v5(:run_v5, :bob, 250, 9, 0, 0, 0, 60, 0, 60, 0, 0, 0, 0, 30000, null, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, true, array['HIGH_INPUT_RATE']) is not null, true,
  'v5 records a 2.2 run with its ledger');
select public._t_is((select best_score from public.get_my_rank_v3(:alice)), 100, 'the qa score did not become the ranked best');
select public._t_is((select overall_rank::int from public.get_my_rank_v3(:alice)), 2, 'a higher best from another session moves the rank');
select public._t_is((select overall_rank::int from public.get_my_rank_v3(:bob)), 1, 'and that session is first');
reset role;
select public._t_is((select run_type || '|' || ruleset_version || '|' || validation_status || '|' || combo_bonus || '|' || suspicious_flag || '|' || suspicion_reasons::text
  from public.ranked_runs where run_id = :run_v5), 'ranked|secret-2.2-r1|accepted|10|true|{HIGH_INPUT_RATE}', 'the v5 row keeps ruleset, ledger and suspicion flags');
select public._t_is((select count(*)::int from pg_trigger t where t.tgrelid in ('public.ranked_sessions'::regclass, 'public.ranked_runs'::regclass)
  and not t.tgisinternal and t.tgname <> 'tier3_session_ref'), 0, 'the ops/analytics mirror triggers are not carried over');
update public.profiles set is_banned = true where user_id = :bob;
select public._t_is((select overall_rank::int from public.get_my_rank_v3(:alice)), 1, 'a banned profile leaves the ranking');
update public.profiles set is_banned = false where user_id = :bob;

-- =====================================================================
-- 30: Inha mail badge (table + functions only; the handler is 501)
-- =====================================================================
select public._t_is(public.is_inha_mail(e), ok, format('is_inha_mail(%L) = %s', e, ok)) from (values
  ('s@inha.edu', true), ('S@INHA.AC.KR', true), ('s@inha.ac.kr', true),
  ('s@inha.edu.evil.example', false), ('s@mail.inha.edu', false), ('s@notinha.edu', false),
  ('@inha.edu', false), ('a b@inha.edu', false), (null, false)
) as t(e, ok);
\set school_ok '''d3000000-0000-4000-8000-000000000003'''
\set school_unconfirmed '''d4000000-0000-4000-8000-000000000004'''
\set school_gmail '''d5000000-0000-4000-8000-000000000005'''
-- Stand-in for the confirmed school mailboxes the original read from auth.users.
-- Nothing in Tier 3 writes this table; these rows exist only inside this transaction.
insert into private.inha_mail_verified_mailboxes (school_id, email, confirmed_at) values
  (:school_ok, 'Duck.12201234@INHA.EDU', now()), (:school_unconfirmed, 'late@inha.ac.kr', null), (:school_gmail, 'duck@gmail.example', now());
select public._t_throws(format('select public.claim_inha_mail_badge(%L, %L)', :alice, :alice), 'P0001',
  'primary and school must be different accounts', 'A second mailbox is required');
select public._t_throws(format('select public.claim_inha_mail_badge(%L, %L)', :stranger, :school_ok), 'P0001',
  'primary must be an existing session', 'Primary account is not confirmed');
select public._t_throws(format('select public.claim_inha_mail_badge(%L, %L)', :alice, :school_unconfirmed), 'P0001',
  'school mailbox must be confirmed', 'School mailbox is not confirmed');
select public._t_throws(format('select public.claim_inha_mail_badge(%L, %L)', :alice, :school_gmail), 'P0001',
  'school mailbox must be an Inha address', 'School mailbox is not confirmed');
select public._t_throws(format('select public.claim_inha_mail_badge(%L, %L)', :alice, :stranger), 'P0001',
  'an unknown school id fails closed', 'School mailbox is not confirmed');
select public._t_is(public.claim_inha_mail_badge(:alice, :school_ok), true, 'a valid claim succeeds');
select public._t_is((select email from public.inha_mail_badges where user_id = :alice), 'duck.12201234@inha.edu',
  'the badge stores the lower-cased school address');
select public._t_is(public.claim_inha_mail_badge(:alice, :school_ok), true, 'claiming again is idempotent');
select public._t_is((select count(*)::int from public.inha_mail_badges where user_id = :alice), 1, 'and stores one badge');
select public._t_throws(format('select public.claim_inha_mail_badge(%L, %L)', :bob, :school_ok), '23505',
  'one school mailbox cannot back two sessions (original handler: 409)');
select public._t_is((select evidence_source from public.user_achievements where user_id = :alice and achievement_key = 'inha_verified_v1'),
  'inha_mail_verified', 'the verified achievement is granted to an unbanned profile');
delete from private.inha_mail_verified_mailboxes;
select public._t_throws(format('select public.claim_inha_mail_badge(%L, %L)', :noprofile, :school_ok), 'P0001',
  'with no verified mailbox on record every claim fails closed', 'School mailbox is not confirmed');

-- ---- report ----
\o
\pset tuples_only on
\pset format unaligned
select 'not ok ' || n || ' - ' || name || '  [' || coalesce(note, '') || ']' from public._t_results where not ok order by n;
select count(*) filter (where ok) || '/' || count(*) || ' passed' from public._t_results;
do $$
begin
  if exists (select 1 from public._t_results where not ok) then
    raise exception 'schema oracle failed';
  end if;
end;
$$;
rollback;
