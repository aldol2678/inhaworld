-- INHA WORLD — Tier 4 (A-3 state machines; superset of the A-1 reads + A-2 writes) data-layer
-- schema for Neon (Postgres 16+). A-1 reads (inventory, wallet, progression, loadout
-- read, shop, shop capabilities, staff badges, profile + achievements) plus the A-2
-- writes: loadout equip/unequip, shop purchase v1/v2, attendance claim (+read),
-- guestbook CRUD (+read), jeongseok pass purchase (+access read), cooking, room
-- furniture save (+read), personal room get-or-create + visibility, room knock
-- knock/get/list/respond, plus the A-3 state machines: daily quiz (3), life
-- skills (4), social (10), accompany (4), biryong progress (2) + biryong NPC
-- relationships (3), campus NPC relationships (3), MCM 2026 event (6).
-- 65 public RPCs in total.
--
-- Apply ONLY to an isolated Neon branch (or a disposable local database) until
-- the owner approves a cutover. Never apply it to the live `inha-world-sync`
-- main branch as part of this tier's verification. Idempotent: safe to re-run.
-- No secrets, no role passwords.
--
-- HOW THIS FILE WAS PRODUCED
-- The original Supabase migrations (aldol2678/inhagame HEAD 0b72d259, all 52, in
-- order) were applied to an isolated scratch Neon branch (tier4-scratch). Every
-- table and function that the 65 Tier 4 RPCs reach — directly, through private
-- helpers, foreign keys, triggers or column defaults — was then read back from
-- the catalog (extract-closure.mjs), so each definition is the FINAL state after
-- every redefinition. Function bodies are otherwise untouched; see hash-report.json.
--
-- WHAT IS DIFFERENT FROM THE ORIGINAL (also listed in README.md)
--  1. Identity. Every `user_id uuid` / `p_user uuid` now names a row of
--     public.sessions (the v0.1 guest session, `X-Session-Id`), not auth.users.
--     sessions.id is TEXT holding a lower-case UUID, so the uuid is compared as
--     `sessions.id = <uuid>::text`. The 9 no-arg RPCs take `p_user uuid` as
--     their first parameter; shop takes (p_user, p_shop_id), staff badges
--     takes (p_user, p_user_ids).
--  2. FOREIGN KEY (user_id | auth_user_id) REFERENCES auth.users is replaced by
--     the row trigger `tier4_session_ref` (private.tier4_require_session_v1): a uuid
--     column cannot reference a text column. It raises foreign_key_violation (23503)
--     like the constraint did. There is NO on-delete cascade from sessions.
--  3. private.world_*_account_ok_v1 (3 functions): the original required an auth.users
--     row that is not anonymous AND a public.profiles row with is_banned = false. Both
--     are gone (guest-open decision, 2026-11-12): the session existing in
--     public.sessions is the whole check. These paths no longer check a ban.
--     EXCEPTION: /api/world-profile keeps the profile rule — get_my_profile raises
--     PROFILE_NOT_FOUND (42501) and get_my_achievements raises PROFILE_NOT_FOUND
--     when the profiles row is missing or banned; the Worker maps it to
--     409 PROFILE_REQUIRED (same rule as ranked runs).
--  4. get_my_profile 'joinedAt' came from auth.users.created_at; it now comes from
--     the profiles row (i.created_at). get_my_achievements' inha_verified insert
--     drops the auth.users email branch; the inha_mail_badges row is the only
--     verification source left. public.my_inha_mail_badge(p_user) likewise reads
--     only inha_mail_badges (email-confirmation branch dropped — no Supabase Auth
--     in Tier 4).
--  5. get_world_shop_capabilities_v1 probes the PORTED purchase signatures
--     (uuid first); A-1 kept the original probes, which now resolve to NULL.
--     has_function_privilege checks. The purchase functions are now present
--     (A-2), so it returns {purchaseRpc: 'purchase_world_shop_listing_v2',
--     catalogLayout: 'split'} as the original does.
--  8. A-2 guest-open defaults (see README.md; all reversible by an Aldol decision):
--     self-only writes (equip/unequip, purchase, attendance claim, jeongseok pass,
--     cooking, furniture save, personal room) need only a session; the profile +
--     ban checks in world_room_caller_v1 / world_attendance_caller_v1 are replaced
--     by the session check. Writes visible to others (guestbook create/update/
--     delete, room knock) keep the profile rule: world_social_caller raises
--     PROFILE_NOT_FOUND (42501) when the profile is missing or banned, and the
--     Worker maps it to 409 PROFILE_REQUIRED (same rule as ranked runs). The
--     moderation check (interaction_restriction_24h -> SOCIAL_RESTRICTED) is kept.
--     world_room_access_v1 keeps its profile rule for VISITORs (friendship needs
--     profiles) but reads profiles only, not auth.users.
--  9. Guestbook visibility: get_world_guestbook_v2 and world_guestbook_entry_json
--     drop the auth.users join; entries show when the author has a non-banned
--     profile, and inhaVerified comes from inha_mail_badges only (A-1 precedent).
--  10. Append-only DELETE allowances (jeongseok pass purchases, recipe receipts)
--     check public.sessions instead of auth.users: a receipt row may be deleted
--     only once its session row is gone.
--  12. A-3 account-ok helpers (daily quiz, life skills, MCM, biryong + campus
--     NPC relationships) are session-only, like the A-1/A-2 account-ok
--     helpers: a session row is the whole check, no profile/ban rule. The
--     social caller keeps the A-2 profile rule (PROFILE_NOT_FOUND), so
--     social/accompany still need a non-banned profile.
--  13. A-3 SERVER_ONLY gates are dropped, not weakened: advance_mcm_2026_event_v1
--     and the public.world_reward_grant_v1 wrapper required a service_role JWT.
--     Tier 4 has no such JWT; the only caller is the Worker (server). No HTTP
--     endpoint exposes advance_mcm; the reward wrapper is never called by a
--     client (the claim path uses the private grant). See README.md #9.
--  14. private.world_card drops the auth.users join; inhaVerified comes from
--     inha_mail_badges only (same family as A-1 #1/#3). pgcrypto is created in
--     the extensions schema for world_landlord_pick_survivor_v1
--     (extensions.gen_random_bytes).
--  11. Atomicity (verified from the original bodies, see README.md): purchase v1,
--     jeongseok purchase, cooking and attendance claim are each a single plpgsql
--     function call, so each runs as one transaction; every refusal happens
--     before any value moves, and each ends with an in-transaction readback.
--     v2 delegates to v1 inside the same transaction (nested call).
--  6. get_my_achievements performs idempotent INSERT ... ON CONFLICT DO NOTHING
--     materialization into public.user_achievements (3 keys). It is a read that
--     writes its own cache; the Worker role needs no table grant for it because
--     the function is SECURITY DEFINER and runs as the schema owner.
--  7. Not carried over: row level security and policies (the Worker role has
--     table-level grants only), the ops/analytics mirror triggers on
--     ranked_sessions / ranked_runs / game_events / game_sessions /
--     general_stage_bests (log_*_event, trg_sync_inha_duck_*, touch_*_ops_refresh,
--     attach_inha_duck_event_context) and their tables (Tier 3 precedent), and
--     every object no Tier 4 RPC reaches.

create schema if not exists private;

-- pgcrypto (gen_random_bytes), used by world_landlord_pick_survivor_v1.
-- The stub-prelude creates the same extension in the scratch branch only;
-- the test branch needs it too, or the landlord survivor pick fails at call time.
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- Roles referenced by has_function_privilege('authenticated', ...) and by the
-- original GRANTs. NOLOGIN; the Worker never logs in as these.
do $$ begin if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if; end $$;
do $$ begin if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if; end $$;
do $$ begin if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin; end if; end $$;
do $$ begin if not exists (select 1 from pg_roles where rolname = 'inha_world_tier4_writes_app') then create role inha_world_tier4_writes_app nologin; end if; end $$;

-- v0.1 sync schema already owns this table. It is NOT redefined here: the statement
-- only creates it when it is missing (e.g. a disposable test database), with the
-- same columns as reference/schema-v01-sync.sql.
create table if not exists public.sessions (
  id text primary key,
  nickname text not null,
  created_at timestamptz not null default now()
);

-- Replacement for FOREIGN KEY (user_id | auth_user_id) REFERENCES auth.users(id).
-- Checks whichever of the two columns the row has, via to_jsonb so one function
-- serves every table.
create or replace function private.tier4_require_session_v1()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if (to_jsonb(new) ->> 'user_id') is not null
     and not exists (select 1 from public.sessions s where s.id = (to_jsonb(new) ->> 'user_id')) then
    raise exception 'user_id % is not a session', (to_jsonb(new) ->> 'user_id')
      using errcode = 'foreign_key_violation';
  end if;
  if (to_jsonb(new) ->> 'auth_user_id') is not null
     and not exists (select 1 from public.sessions s where s.id = (to_jsonb(new) ->> 'auth_user_id')) then
    raise exception 'auth_user_id % is not a session', (to_jsonb(new) ->> 'auth_user_id')
      using errcode = 'foreign_key_violation';
  end if;
  return new;
end;
$fn$;


-- ================= Tables =================

create table if not exists private.world_appearance_transactions (
  transaction_id uuid default gen_random_uuid() not null,
  idempotency_key text not null,
  user_id uuid not null,
  action text not null,
  slot text not null,
  requested_item_id text,
  previous_item_id text,
  next_item_id text,
  created_at timestamp with time zone default clock_timestamp() not null
);

CREATE INDEX IF NOT EXISTS world_appearance_transactions_user_idx ON private.world_appearance_transactions USING btree (user_id, created_at DESC);

create table if not exists private.world_attendance_days (
  user_id uuid not null,
  attendance_date date not null,
  claimed_at timestamp with time zone default now() not null,
  daily_reward_transaction_id uuid not null,
  milestone smallint,
  milestone_reward_transaction_id uuid
);

create table if not exists private.world_biryong_npc_relationship_events (
  relationship_event_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  npc_id text not null,
  from_stage smallint not null,
  to_stage smallint not null,
  source_type text not null,
  source_ref text not null,
  result_ref text,
  idempotency_key text not null,
  definition_version integer not null,
  advanced_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS world_biryong_relationship_events_user_npc_idx ON private.world_biryong_npc_relationship_events USING btree (user_id, npc_id, advanced_at DESC);

create table if not exists private.world_biryong_npc_relationship_fact_catalog (
  fact_id text not null,
  npc_id text not null,
  unlock_stage smallint not null,
  topic_id text not null,
  topic_label text not null,
  fact_text text not null,
  dialogue_line text not null,
  generative_safe boolean default false not null,
  status text default 'ACTIVE'::text not null,
  definition_version integer default 1 not null
);

CREATE INDEX IF NOT EXISTS world_biryong_relationship_fact_npc_stage_idx ON private.world_biryong_npc_relationship_fact_catalog USING btree (npc_id, unlock_stage, status);

create table if not exists private.world_biryong_npc_relationship_npc_catalog (
  npc_id text not null,
  display_name text not null,
  status text default 'ACTIVE'::text not null,
  definition_version integer default 1 not null
);

create table if not exists private.world_biryong_progress_v1 (
  user_id uuid not null,
  discovered_at timestamp with time zone,
  step text default 'INTRO'::text not null,
  lore text[] default '{}'::text[] not null,
  shouts integer default 0 not null,
  completed_at timestamp with time zone,
  migrated_from_local boolean default false not null,
  updated_at timestamp with time zone default now() not null
);

create table if not exists private.world_campus_npc_relationship_events (
  relationship_event_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  npc_id text not null,
  event_type text not null,
  signal text,
  occurrence integer not null,
  requested_delta smallint not null,
  applied_delta smallint not null,
  affinity_before smallint not null,
  affinity_after smallint not null,
  source_type text not null,
  source_ref text not null,
  idempotency_key text not null,
  definition_version integer not null,
  applied_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS world_campus_npc_relationship_events_user_npc_idx ON private.world_campus_npc_relationship_events USING btree (user_id, npc_id, applied_at DESC);

create table if not exists private.world_campus_npc_relationship_npc_catalog (
  npc_id text not null,
  relationship_class text not null,
  status text default 'ACTIVE'::text not null,
  definition_version integer default 1 not null
);

create table if not exists private.world_currencies (
  currency_id text not null,
  display_name text not null,
  created_at timestamp with time zone default now() not null
);

create table if not exists private.world_currency_transactions (
  transaction_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  currency_id text not null,
  type text not null,
  amount bigint not null,
  balance_before bigint not null,
  balance_after bigint not null,
  source_type text not null,
  source_id text not null,
  reason text,
  idempotency_key text not null,
  created_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS world_currency_transactions_user_created_idx ON private.world_currency_transactions USING btree (user_id, currency_id, created_at DESC);

create table if not exists private.world_daily_quiz_answers (
  run_id uuid not null,
  question_index smallint not null,
  question_id text not null,
  selected_index smallint not null,
  correct boolean not null,
  answered_at timestamp with time zone default now() not null
);

create table if not exists private.world_daily_quiz_questions (
  question_id text not null,
  status text default 'ACTIVE'::text not null,
  position integer not null,
  category text not null,
  prompt text not null,
  options jsonb not null,
  correct_index smallint not null,
  version integer default 1 not null,
  created_at timestamp with time zone default now() not null
);

create table if not exists private.world_daily_quiz_runs (
  run_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  reward_date date not null,
  status text default 'ACTIVE'::text not null,
  question_ids text[] not null,
  answered_count smallint default 0 not null,
  correct_count smallint default 0 not null,
  started_at timestamp with time zone default now() not null,
  completed_at timestamp with time zone,
  reward_transaction_id uuid
);

create table if not exists private.world_event_progress (
  user_id uuid not null,
  event_id text not null,
  stage smallint not null,
  investigated text[] default '{}'::text[] not null,
  started_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  venue_unlocked_at timestamp with time zone,
  completed_at timestamp with time zone
);

create table if not exists private.world_events (
  event_id text not null,
  title text not null,
  starts_at timestamp with time zone not null,
  ends_at timestamp with time zone not null,
  is_disabled boolean default false not null,
  created_at timestamp with time zone default now() not null
);

create table if not exists private.world_exp_transactions (
  transaction_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  amount bigint not null,
  exp_before bigint not null,
  exp_after bigint not null,
  level_before integer not null,
  level_after integer not null,
  source_type text not null,
  source_id text not null,
  idempotency_key text not null,
  created_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS world_exp_transactions_user_created_idx ON private.world_exp_transactions USING btree (user_id, created_at DESC);

create table if not exists private.world_guestbook_post_log (
  id uuid default gen_random_uuid() not null,
  entry_id uuid not null,
  user_id uuid not null,
  location_key text not null,
  created_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS world_guestbook_post_log_user_place_created_idx ON private.world_guestbook_post_log USING btree (user_id, location_key, created_at DESC);

create table if not exists private.world_inventory_mutation_entries (
  mutation_id uuid not null,
  position integer not null,
  direction text not null,
  item_id text not null,
  quantity integer not null,
  quantity_before integer not null,
  quantity_after integer not null,
  child_idempotency_key text not null,
  child_ref text not null
);

create table if not exists private.world_inventory_mutations (
  mutation_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  mutation_type text not null,
  source_type text not null,
  source_ref text not null,
  idempotency_key text not null,
  plan jsonb not null,
  status text default 'COMPLETED'::text not null,
  created_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS world_inventory_mutations_user_created_idx ON private.world_inventory_mutations USING btree (user_id, created_at DESC);

create table if not exists private.world_item_catalog (
  item_id text not null,
  category text not null,
  ownership_policy text not null,
  max_stack integer,
  status text not null
);

create table if not exists private.world_item_consumptions (
  consume_id text not null,
  user_id uuid not null,
  item_id text not null,
  quantity_requested integer not null,
  quantity_before integer not null,
  quantity_consumed integer not null,
  quantity_after integer not null,
  source_type text not null,
  source_ref text not null,
  parent_mutation_id uuid,
  metadata jsonb,
  created_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS world_item_consumptions_user_created_idx ON private.world_item_consumptions USING btree (user_id, created_at DESC);

create table if not exists private.world_item_grants (
  grant_id text not null,
  user_id uuid not null,
  item_id text not null,
  result text not null,
  quantity_requested integer not null,
  quantity_before integer not null,
  quantity_granted integer not null,
  quantity_after integer not null,
  source_type text not null,
  source_ref text not null,
  event_id text,
  acquisition_metadata jsonb,
  created_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS world_item_grants_user_idx ON private.world_item_grants USING btree (user_id, created_at DESC);

create table if not exists private.world_jeongseok_gate_policy (
  singleton boolean default true not null,
  status text not null,
  updated_at timestamp with time zone default now() not null
);

create table if not exists private.world_jeongseok_pass_catalog (
  pass_type text not null,
  duration_seconds integer not null,
  currency_id text not null,
  price bigint not null,
  price_basis text not null,
  status text not null
);

create table if not exists private.world_jeongseok_pass_entitlements (
  user_id uuid not null,
  pass_type text not null,
  issued_at timestamp with time zone not null,
  expires_at timestamp with time zone not null,
  last_purchase_id uuid not null,
  updated_at timestamp with time zone default now() not null
);

create table if not exists private.world_jeongseok_pass_purchases (
  purchase_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  pass_type text not null,
  currency_id text not null,
  price bigint not null,
  balance_before bigint not null,
  balance_after bigint not null,
  issued_at timestamp with time zone not null,
  expires_at timestamp with time zone not null,
  wallet_transaction_id uuid not null,
  idempotency_key text not null,
  created_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS world_jeongseok_pass_purchases_user_idx ON private.world_jeongseok_pass_purchases USING btree (user_id, issued_at DESC);

create table if not exists private.world_landlord_first_clears (
  user_id uuid not null,
  event_id text not null,
  run_id uuid not null,
  first_cleared_at timestamp with time zone default now() not null
);

create table if not exists private.world_landlord_runs (
  run_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  event_id text not null,
  status text not null,
  survivor_actor_id text not null,
  wrong_count integer default 0 not null,
  started_at timestamp with time zone default now() not null,
  deadline_at timestamp with time zone not null,
  ended_at timestamp with time zone
);

CREATE UNIQUE INDEX IF NOT EXISTS world_landlord_runs_one_active ON private.world_landlord_runs USING btree (user_id) WHERE (status = 'ACTIVE'::text);

create table if not exists private.world_level_thresholds (
  level integer not null,
  min_total_exp bigint not null,
  created_at timestamp with time zone default now() not null
);

create table if not exists private.world_life_progression_thresholds (
  curve_id text not null,
  level integer not null,
  min_total_skill_xp bigint not null,
  cumulative_sp integer not null,
  created_at timestamp with time zone default now() not null
);

create table if not exists private.world_life_skill_catalog (
  skill_id text not null,
  curve_id text not null,
  status text not null
);

create table if not exists private.world_life_skill_thresholds (
  curve_id text not null,
  level integer not null,
  min_total_xp bigint not null,
  created_at timestamp with time zone default now() not null,
  cumulative_sp integer default 0 not null
);

create table if not exists private.world_life_skill_tree_catalog (
  node_id text not null,
  skill_id text not null,
  status text not null,
  sp_cost integer not null,
  required_life_level integer not null,
  required_skill_level integer not null,
  max_rank integer default 1 not null
);

create table if not exists private.world_life_skill_tree_edges (
  node_id text not null,
  prerequisite_node_id text not null,
  required_rank integer default 1 not null
);

create table if not exists private.world_life_sp_transactions (
  transaction_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  node_id text not null,
  sp_cost integer not null,
  sp_before integer not null,
  sp_after integer not null,
  idempotency_key text not null,
  created_at timestamp with time zone default now() not null,
  skill_id text not null,
  rank integer not null,
  epoch integer default 0 not null
);

CREATE INDEX IF NOT EXISTS world_life_sp_transactions_user_skill_idx ON private.world_life_sp_transactions USING btree (user_id, skill_id);

CREATE INDEX IF NOT EXISTS world_life_sp_transactions_user_created_idx ON private.world_life_sp_transactions USING btree (user_id, created_at DESC);

create table if not exists private.world_life_tree_reset_policy (
  policy_id text not null,
  cooldown_seconds integer not null,
  updated_at timestamp with time zone default now() not null
);

create table if not exists private.world_life_tree_resets (
  reset_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  skill_id text not null,
  epoch integer not null,
  refunded_sp integer not null,
  cleared_ranks jsonb not null,
  cooldown_seconds integer not null,
  idempotency_key text not null,
  created_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS world_life_tree_resets_user_skill_idx ON private.world_life_tree_resets USING btree (user_id, skill_id, epoch DESC);

create table if not exists private.world_mcm_reward_claims (
  user_id uuid not null,
  claim_type text not null,
  event_id text not null,
  reward_id text not null,
  idempotency_key text not null,
  reward_transaction_id uuid not null,
  reward_status text not null,
  source_completed_at timestamp with time zone not null,
  claimed_at timestamp with time zone default now() not null
);

create table if not exists private.world_player_appearance_loadout (
  user_id uuid not null,
  slot text not null,
  item_id text not null,
  updated_at timestamp with time zone default now() not null
);

create table if not exists private.world_player_biryong_npc_relationships (
  user_id uuid not null,
  npc_id text not null,
  stage smallint not null,
  revision bigint default 1 not null,
  stage2_unlocked_at timestamp with time zone not null,
  stage3_unlocked_at timestamp with time zone,
  updated_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS world_biryong_relationship_state_user_updated_idx ON private.world_player_biryong_npc_relationships USING btree (user_id, updated_at DESC);

create table if not exists private.world_player_campus_npc_relationships (
  user_id uuid not null,
  npc_id text not null,
  affinity smallint not null,
  encounter_count integer default 0 not null,
  meaningful_interaction_count integer default 0 not null,
  first_interaction_at timestamp with time zone not null,
  last_interaction_at timestamp with time zone not null,
  last_meaningful_at timestamp with time zone,
  revision bigint default 1 not null,
  updated_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS world_campus_npc_relationship_state_user_updated_idx ON private.world_player_campus_npc_relationships USING btree (user_id, updated_at DESC);

create table if not exists private.world_player_items (
  id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  item_id text not null,
  quantity integer not null,
  source_type text not null,
  source_ref text not null,
  event_id text,
  grant_id text not null,
  acquisition_metadata jsonb,
  acquired_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

create table if not exists private.world_player_life_nodes (
  user_id uuid not null,
  node_id text not null,
  transaction_id uuid not null,
  unlocked_at timestamp with time zone default now() not null,
  rank integer default 1 not null,
  epoch integer default 0 not null
);

create table if not exists private.world_player_life_skills (
  user_id uuid not null,
  skill_id text not null,
  total_xp bigint default 0 not null,
  version bigint default 0 not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

create table if not exists private.world_player_progression (
  user_id uuid not null,
  total_exp bigint default 0 not null,
  version bigint default 0 not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

create table if not exists private.world_purchase_transactions (
  purchase_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  shop_id text not null,
  listing_id text not null,
  item_id text not null,
  quantity integer not null,
  currency_id text not null,
  price bigint not null,
  balance_before bigint not null,
  balance_after bigint not null,
  wallet_transaction_id uuid not null,
  inventory_grant_id text not null,
  idempotency_key text not null,
  status text default 'COMPLETED'::text not null,
  created_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS world_purchase_transactions_user_listing_idx ON private.world_purchase_transactions USING btree (user_id, listing_id);

create table if not exists private.world_recipe_catalog (
  recipe_id text not null,
  definition_version integer not null,
  mutation_type text not null,
  required_capability text not null,
  required_item_id text not null,
  status text not null,
  plan jsonb not null
);

create table if not exists private.world_recipe_receipts (
  user_id uuid not null,
  request_id uuid not null,
  recipe_id text not null,
  receipt jsonb not null,
  created_at timestamp with time zone default now() not null
);

create table if not exists private.world_reward_definitions (
  reward_id text not null,
  status text not null,
  version integer default 1 not null,
  event_id text,
  tags text[] default '{}'::text[] not null,
  description text not null,
  created_at timestamp with time zone default now() not null
);

create table if not exists private.world_reward_grants (
  reward_id text not null,
  grant_entry_id text not null,
  position smallint not null,
  grant_type text not null,
  target_id text not null,
  amount bigint not null
);

create table if not exists private.world_reward_transaction_entries (
  reward_transaction_id uuid not null,
  grant_entry_id text not null,
  position smallint not null,
  grant_type text not null,
  target_id text not null,
  requested bigint not null,
  granted bigint default 0 not null,
  status text not null,
  reason text,
  child_idempotency_key text not null,
  child_transaction_id text,
  attempts integer default 0 not null,
  updated_at timestamp with time zone default now() not null
);

create table if not exists private.world_reward_transactions (
  reward_transaction_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  reward_id text not null,
  reward_version integer not null,
  event_id text,
  source_type text not null,
  source_id text not null,
  idempotency_key text not null,
  status text not null,
  attempts integer default 1 not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  completed_at timestamp with time zone
);

CREATE INDEX IF NOT EXISTS world_reward_transactions_user_idx ON private.world_reward_transactions USING btree (user_id, created_at DESC);

create table if not exists private.world_room_knocks (
  id uuid default gen_random_uuid() not null,
  room_id uuid not null,
  visitor_user_id uuid not null,
  status text default 'PENDING'::text not null,
  created_at timestamp with time zone default now() not null,
  expires_at timestamp with time zone not null,
  responded_at timestamp with time zone
);

CREATE UNIQUE INDEX IF NOT EXISTS world_room_knocks_one_pending ON private.world_room_knocks USING btree (room_id, visitor_user_id) WHERE (status = 'PENDING'::text);

CREATE INDEX IF NOT EXISTS world_room_knocks_room_pending ON private.world_room_knocks USING btree (room_id, created_at) WHERE (status = 'PENDING'::text);

CREATE INDEX IF NOT EXISTS world_room_knocks_room_visitor_recent ON private.world_room_knocks USING btree (room_id, visitor_user_id, created_at DESC);

create table if not exists private.world_room_layouts (
  room_id uuid not null,
  revision integer default 0 not null,
  objects jsonb default '[]'::jsonb not null,
  updated_at timestamp with time zone default now() not null
);

create table if not exists private.world_room_owner_presence (
  room_id uuid not null,
  seen_at timestamp with time zone default now() not null
);

create table if not exists private.world_shop_listings (
  listing_id text not null,
  shop_id text not null,
  position smallint not null,
  item_id text not null,
  currency_id text not null,
  price bigint not null,
  quantity integer default 1 not null,
  required_level integer,
  purchase_limit integer,
  start_at timestamp with time zone,
  end_at timestamp with time zone,
  status text not null,
  created_at timestamp with time zone default now() not null
);

create table if not exists private.world_shops (
  shop_id text not null,
  display_name text not null,
  status text not null,
  vendor_id text,
  tags text[] default '{}'::text[] not null,
  created_at timestamp with time zone default now() not null
);

create table if not exists private.world_staff_assignments (
  user_id uuid not null,
  role text not null,
  active boolean default true not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

create table if not exists private.world_user_moderation_actions (
  id bigint generated by default as identity not null,
  report_id bigint,
  target_id uuid not null,
  action text not null,
  starts_at timestamp with time zone default now() not null,
  ends_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  actor_id uuid,
  actor_source text default 'ops_token'::text not null
);

CREATE INDEX IF NOT EXISTS world_user_moderation_report_idx ON private.world_user_moderation_actions USING btree (report_id, created_at DESC);

CREATE INDEX IF NOT EXISTS world_user_moderation_actions_actor_idx ON private.world_user_moderation_actions USING btree (actor_id, created_at DESC) WHERE (actor_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS world_user_moderation_target_active_idx ON private.world_user_moderation_actions USING btree (target_id, ends_at DESC) WHERE (action = 'interaction_restriction_24h'::text);

create table if not exists private.world_wallets (
  user_id uuid not null,
  currency_id text not null,
  balance bigint default 0 not null,
  version bigint default 0 not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

create table if not exists public.classic_event_badges (
  event_key text not null,
  user_id uuid not null,
  placement smallint not null,
  badge_code text not null,
  best_run_id uuid not null,
  final_score integer not null,
  final_combo integer not null,
  final_achieved_at timestamp with time zone not null,
  awarded_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS classic_event_badges_best_run_idx ON public.classic_event_badges USING btree (best_run_id);

CREATE INDEX IF NOT EXISTS classic_event_badges_user_idx ON public.classic_event_badges USING btree (user_id);

create table if not exists public.departments (
  id bigint generated by default as identity not null,
  name text not null,
  active boolean default true not null,
  sort_order integer default 0 not null,
  created_at timestamp with time zone default now() not null
);

create table if not exists public.game_builds (
  id uuid default gen_random_uuid() not null,
  game_id uuid not null,
  version text not null,
  client_version text,
  balance_version text,
  ruleset_version text,
  git_commit text,
  deployed_at timestamp with time zone,
  metadata jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null
);

create table if not exists public.game_events (
  id bigint generated by default as identity not null,
  user_id uuid,
  event_type text not null,
  stage_id smallint,
  run_id uuid,
  score integer,
  combo integer,
  stars smallint,
  status text,
  metadata jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  game_id uuid,
  player_id uuid,
  game_session_id uuid,
  build_id uuid,
  event_version smallint default 1 not null
);

CREATE INDEX IF NOT EXISTS game_events_player_created_idx ON public.game_events USING btree (player_id, created_at DESC);

CREATE INDEX IF NOT EXISTS game_events_game_session_created_idx ON public.game_events USING btree (game_session_id, created_at) WHERE (game_session_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS game_events_game_player_created_idx ON public.game_events USING btree (game_id, player_id, created_at DESC) WHERE (player_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS game_events_run_idx ON public.game_events USING btree (run_id) WHERE (run_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS game_events_user_created_idx ON public.game_events USING btree (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS game_events_created_at_idx ON public.game_events USING btree (created_at DESC);

CREATE INDEX IF NOT EXISTS game_events_game_created_idx ON public.game_events USING btree (game_id, created_at DESC);

CREATE INDEX IF NOT EXISTS game_events_type_created_idx ON public.game_events USING btree (event_type, created_at DESC);

CREATE INDEX IF NOT EXISTS game_events_game_type_created_idx ON public.game_events USING btree (game_id, event_type, created_at DESC);

create table if not exists public.game_sessions (
  id uuid default gen_random_uuid() not null,
  game_id uuid not null,
  player_id uuid,
  build_id uuid,
  client_session_id uuid not null,
  source text,
  device text,
  platform text,
  started_at timestamp with time zone default now() not null,
  ended_at timestamp with time zone,
  metadata jsonb default '{}'::jsonb not null
);

CREATE INDEX IF NOT EXISTS game_sessions_game_started_idx ON public.game_sessions USING btree (game_id, started_at DESC);

CREATE INDEX IF NOT EXISTS game_sessions_player_started_idx ON public.game_sessions USING btree (player_id, started_at DESC) WHERE (player_id IS NOT NULL);

create table if not exists public.games (
  id uuid default gen_random_uuid() not null,
  slug text not null,
  name text not null,
  status text default 'prototype'::text not null,
  released_at timestamp with time zone,
  metadata jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

create table if not exists public.general_stage_bests (
  user_id uuid not null,
  stage_id smallint not null,
  best_score integer default 0 not null,
  best_combo integer default 0 not null,
  achieved_at timestamp with time zone default now() not null,
  best_stars smallint default 0 not null
);

create table if not exists public.induckup_ranked_bests (
  user_id uuid not null,
  best_wave integer default 0 not null,
  best_score integer default 0 not null,
  best_duration_ms integer default 0 not null,
  achieved_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS induckup_ranked_order_idx ON public.induckup_ranked_bests USING btree (best_wave DESC, best_score DESC, best_duration_ms DESC, achieved_at);

create table if not exists public.inha_mail_badges (
  user_id uuid not null,
  email text not null,
  verified_at timestamp with time zone default now() not null
);

create table if not exists public.player_bests (
  user_id uuid not null,
  stage_key text default 'secret'::text not null,
  best_score integer not null,
  best_combo integer default 0 not null,
  best_run_id uuid not null,
  achieved_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS player_bests_best_run_idx ON public.player_bests USING btree (best_run_id);

CREATE INDEX IF NOT EXISTS player_bests_score_idx ON public.player_bests USING btree (stage_key, best_score DESC, achieved_at);

create table if not exists public.players (
  id uuid default gen_random_uuid() not null,
  auth_user_id uuid,
  visitor_id uuid,
  first_seen_at timestamp with time zone default now() not null,
  last_seen_at timestamp with time zone default now() not null,
  metadata jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null
);

create table if not exists public.profiles (
  user_id uuid not null,
  nickname text not null,
  department_id bigint,
  title text,
  is_banned boolean default false not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  avatar_key text default 'classic'::text not null
);

CREATE INDEX IF NOT EXISTS profiles_department_idx ON public.profiles USING btree (department_id);

create table if not exists public.ranked_runs (
  id uuid default gen_random_uuid() not null,
  run_id uuid not null,
  user_id uuid not null,
  stage_key text default 'secret'::text not null,
  score integer not null,
  max_combo integer not null,
  annyongi_hits integer default 0 not null,
  indeoki_hits integer default 0 not null,
  gold_hits integer default 0 not null,
  total_hits integer default 0 not null,
  dragon_bursts integer default 0 not null,
  duration_ms integer not null,
  client_version text,
  validation_status text not null,
  reject_reason text,
  created_at timestamp with time zone default now() not null,
  run_type text default 'ranked'::text not null,
  ruleset_version text default 'secret-2.0-r1'::text not null,
  normal_hits integer default 0 not null,
  speedy_hits integer default 0 not null,
  dragon_calls integer default 0 not null,
  moon_bonus_hits integer default 0 not null,
  flight_hits integer default 0 not null,
  input_count integer default 0 not null,
  reaction_sample_count integer default 0 not null,
  ultra_fast_reaction_count integer default 0 not null,
  suspicious_flag boolean default false not null,
  suspicion_reasons text[] default '{}'::text[] not null,
  completed_calls integer default 0 not null,
  combo_bonus integer default 0 not null,
  flight_base_points integer default 0 not null,
  tier1_hits integer default 0 not null,
  tier2_hits integer default 0 not null,
  tier1_ground_award integer default 0 not null,
  tier2_ground_award integer default 0 not null,
  ascension_bonus integer default 0 not null
);

CREATE INDEX IF NOT EXISTS ranked_runs_user_created_idx ON public.ranked_runs USING btree (user_id, created_at DESC);

create table if not exists public.ranked_sessions (
  run_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  stage_key text default 'secret'::text not null,
  nonce uuid default gen_random_uuid() not null,
  started_at timestamp with time zone default now() not null,
  expires_at timestamp with time zone default (now() + '00:05:00'::interval) not null,
  finished_at timestamp with time zone,
  status text default 'started'::text not null,
  client_version text,
  created_at timestamp with time zone default now() not null,
  run_type text default 'ranked'::text not null,
  ruleset_version text default 'secret-2.0-r1'::text not null,
  submitted_at timestamp with time zone,
  abandoned_at timestamp with time zone,
  expired_at timestamp with time zone
);

CREATE INDEX IF NOT EXISTS ranked_sessions_user_started_idx ON public.ranked_sessions USING btree (user_id, started_at DESC);

create table if not exists public.user_achievements (
  user_id uuid not null,
  achievement_key text not null,
  earned_at timestamp with time zone not null,
  awarded_at timestamp with time zone default now() not null,
  condition_version smallint default 1 not null,
  evidence_source text not null
);

create table if not exists public.user_game_progress (
  user_id uuid not null,
  game_id uuid not null,
  progress jsonb default '{}'::jsonb not null,
  schema_version integer default 1 not null,
  migrated_from_local boolean default false not null,
  first_synced_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS user_game_progress_updated_at_idx ON public.user_game_progress USING btree (updated_at DESC);

create table if not exists public.world_accompany_sessions (
  id uuid default gen_random_uuid() not null,
  inviter_id uuid not null,
  invitee_id uuid not null,
  place_zone_id text not null,
  poi_id text not null,
  state text default 'offered'::text not null,
  created_at timestamp with time zone default now() not null,
  expires_at timestamp with time zone default (now() + '00:01:00'::interval) not null,
  accepted_at timestamp with time zone,
  ended_at timestamp with time zone,
  ended_reason text
);

CREATE INDEX IF NOT EXISTS world_accompany_inviter_idx ON public.world_accompany_sessions USING btree (inviter_id, state, expires_at);

CREATE INDEX IF NOT EXISTS world_accompany_invitee_idx ON public.world_accompany_sessions USING btree (invitee_id, state, expires_at);

create table if not exists public.world_friendships (
  user_low uuid not null,
  user_high uuid not null,
  status text not null,
  requested_by uuid not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  accepted_at timestamp with time zone
);

CREATE INDEX IF NOT EXISTS world_friendships_high_idx ON public.world_friendships USING btree (user_high);

create table if not exists public.world_guestbook_entries (
  id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  location_key text default 'main_gate'::text not null,
  content text not null,
  is_hidden boolean default false not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS world_guestbook_user_place_created_idx ON public.world_guestbook_entries USING btree (user_id, location_key, created_at DESC);

CREATE INDEX IF NOT EXISTS world_guestbook_location_created_idx ON public.world_guestbook_entries USING btree (location_key, created_at DESC) WHERE (is_hidden = false);

create table if not exists public.world_player_rooms (
  id uuid default gen_random_uuid() not null,
  owner_user_id uuid not null,
  room_type text default 'DORM_1_BASIC'::text not null,
  visibility text default 'friends'::text not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

create table if not exists public.world_user_blocks (
  blocker_id uuid not null,
  blocked_id uuid not null,
  created_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS world_user_blocks_blocked_idx ON public.world_user_blocks USING btree (blocked_id);

create table if not exists public.world_user_reports (
  id bigint generated always as identity not null,
  reporter_id uuid not null,
  target_id uuid not null,
  category text not null,
  place_zone_id text,
  created_at timestamp with time zone default now() not null,
  status text default 'pending'::text not null,
  reviewed_at timestamp with time zone,
  resolution text,
  updated_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS world_user_reports_target_created_idx ON public.world_user_reports USING btree (target_id, created_at DESC);

CREATE INDEX IF NOT EXISTS world_user_reports_status_created_idx ON public.world_user_reports USING btree (status, created_at DESC);

CREATE INDEX IF NOT EXISTS world_user_reports_reporter_idx ON public.world_user_reports USING btree (reporter_id, created_at DESC);

-- ================= Constraints (after all tables, so FK targets exist) =================

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_appearance_transactions_action_check' and conrelid = 'private.world_appearance_transactions'::regclass) then alter table private.world_appearance_transactions add constraint world_appearance_transactions_action_check check ((action = ANY (ARRAY['EQUIP'::text, 'UNEQUIP'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_appearance_transactions_idempotency_key_check' and conrelid = 'private.world_appearance_transactions'::regclass) then alter table private.world_appearance_transactions add constraint world_appearance_transactions_idempotency_key_check check ((idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_appearance_transactions_idempotency_key_key' and conrelid = 'private.world_appearance_transactions'::regclass) then alter table private.world_appearance_transactions add constraint world_appearance_transactions_idempotency_key_key unique (idempotency_key); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_appearance_transactions_pkey' and conrelid = 'private.world_appearance_transactions'::regclass) then alter table private.world_appearance_transactions add constraint world_appearance_transactions_pkey primary key (transaction_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_appearance_transactions_shape' and conrelid = 'private.world_appearance_transactions'::regclass) then alter table private.world_appearance_transactions add constraint world_appearance_transactions_shape check ((((action = 'EQUIP'::text) AND (requested_item_id IS NOT NULL) AND (next_item_id = requested_item_id)) OR ((action = 'UNEQUIP'::text) AND (requested_item_id IS NULL) AND (next_item_id IS NULL)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_appearance_transactions_slot_check' and conrelid = 'private.world_appearance_transactions'::regclass) then alter table private.world_appearance_transactions add constraint world_appearance_transactions_slot_check check ((slot = ANY (ARRAY['BODY'::text, 'FACE'::text, 'HAIR'::text, 'HEAD'::text, 'TOP'::text, 'BOTTOM'::text, 'SHOES'::text, 'BACK'::text, 'ACCESSORY'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_attendance_days_daily_reward_transaction_id_fkey' and conrelid = 'private.world_attendance_days'::regclass) then alter table private.world_attendance_days add constraint world_attendance_days_daily_reward_transaction_id_fkey foreign key (daily_reward_transaction_id) REFERENCES private.world_reward_transactions(reward_transaction_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_attendance_days_milestone_check' and conrelid = 'private.world_attendance_days'::regclass) then alter table private.world_attendance_days add constraint world_attendance_days_milestone_check check (((milestone IS NULL) OR (milestone = ANY (ARRAY[3, 7, 14, 21])))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_attendance_days_milestone_reward_transaction_id_fkey' and conrelid = 'private.world_attendance_days'::regclass) then alter table private.world_attendance_days add constraint world_attendance_days_milestone_reward_transaction_id_fkey foreign key (milestone_reward_transaction_id) REFERENCES private.world_reward_transactions(reward_transaction_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_attendance_days_milestone_tx' and conrelid = 'private.world_attendance_days'::regclass) then alter table private.world_attendance_days add constraint world_attendance_days_milestone_tx check (((milestone IS NULL) = (milestone_reward_transaction_id IS NULL))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_attendance_days_pkey' and conrelid = 'private.world_attendance_days'::regclass) then alter table private.world_attendance_days add constraint world_attendance_days_pkey primary key (user_id, attendance_date); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_events_definition_version_check' and conrelid = 'private.world_biryong_npc_relationship_events'::regclass) then alter table private.world_biryong_npc_relationship_events add constraint world_biryong_npc_relationship_events_definition_version_check check ((definition_version >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_events_from_stage_check' and conrelid = 'private.world_biryong_npc_relationship_events'::regclass) then alter table private.world_biryong_npc_relationship_events add constraint world_biryong_npc_relationship_events_from_stage_check check (((from_stage >= 1) AND (from_stage <= 2))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_events_idempotency_key_check' and conrelid = 'private.world_biryong_npc_relationship_events'::regclass) then alter table private.world_biryong_npc_relationship_events add constraint world_biryong_npc_relationship_events_idempotency_key_check check (((idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text) AND (char_length(idempotency_key) <= 200))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_events_idempotency_key_key' and conrelid = 'private.world_biryong_npc_relationship_events'::regclass) then alter table private.world_biryong_npc_relationship_events add constraint world_biryong_npc_relationship_events_idempotency_key_key unique (idempotency_key); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_events_npc_id_fkey' and conrelid = 'private.world_biryong_npc_relationship_events'::regclass) then alter table private.world_biryong_npc_relationship_events add constraint world_biryong_npc_relationship_events_npc_id_fkey foreign key (npc_id) REFERENCES private.world_biryong_npc_relationship_npc_catalog(npc_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_events_pkey' and conrelid = 'private.world_biryong_npc_relationship_events'::regclass) then alter table private.world_biryong_npc_relationship_events add constraint world_biryong_npc_relationship_events_pkey primary key (relationship_event_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_events_result_ref_check' and conrelid = 'private.world_biryong_npc_relationship_events'::regclass) then alter table private.world_biryong_npc_relationship_events add constraint world_biryong_npc_relationship_events_result_ref_check check (((result_ref IS NULL) OR ((result_ref ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text) AND (char_length(result_ref) <= 200)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_events_source_ref_check' and conrelid = 'private.world_biryong_npc_relationship_events'::regclass) then alter table private.world_biryong_npc_relationship_events add constraint world_biryong_npc_relationship_events_source_ref_check check (((source_ref ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text) AND (char_length(source_ref) <= 200))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_events_source_type_check' and conrelid = 'private.world_biryong_npc_relationship_events'::regclass) then alter table private.world_biryong_npc_relationship_events add constraint world_biryong_npc_relationship_events_source_type_check check ((source_type = ANY (ARRAY['QUEST'::text, 'EVENT'::text, 'SYSTEM'::text, 'ADMIN'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_events_to_stage_check' and conrelid = 'private.world_biryong_npc_relationship_events'::regclass) then alter table private.world_biryong_npc_relationship_events add constraint world_biryong_npc_relationship_events_to_stage_check check (((to_stage >= 2) AND (to_stage <= 3))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_relationship_event_step' and conrelid = 'private.world_biryong_npc_relationship_events'::regclass) then alter table private.world_biryong_npc_relationship_events add constraint world_biryong_relationship_event_step check ((to_stage = (from_stage + 1))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_fact_ca_definition_version_check' and conrelid = 'private.world_biryong_npc_relationship_fact_catalog'::regclass) then alter table private.world_biryong_npc_relationship_fact_catalog add constraint world_biryong_npc_relationship_fact_ca_definition_version_check check ((definition_version >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_fact_catalog_dialogue_line_check' and conrelid = 'private.world_biryong_npc_relationship_fact_catalog'::regclass) then alter table private.world_biryong_npc_relationship_fact_catalog add constraint world_biryong_npc_relationship_fact_catalog_dialogue_line_check check (((char_length(dialogue_line) >= 1) AND (char_length(dialogue_line) <= 500))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_fact_catalog_fact_id_check' and conrelid = 'private.world_biryong_npc_relationship_fact_catalog'::regclass) then alter table private.world_biryong_npc_relationship_fact_catalog add constraint world_biryong_npc_relationship_fact_catalog_fact_id_check check (((fact_id ~ '^biryong\.relationship\.br_npc_00[1-8]\.s[23]\.[a-z][a-z0-9_]{1,80}$'::text) AND (char_length(fact_id) <= 140))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_fact_catalog_fact_text_check' and conrelid = 'private.world_biryong_npc_relationship_fact_catalog'::regclass) then alter table private.world_biryong_npc_relationship_fact_catalog add constraint world_biryong_npc_relationship_fact_catalog_fact_text_check check (((char_length(fact_text) >= 1) AND (char_length(fact_text) <= 500))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_fact_catalog_npc_id_fact_id_key' and conrelid = 'private.world_biryong_npc_relationship_fact_catalog'::regclass) then alter table private.world_biryong_npc_relationship_fact_catalog add constraint world_biryong_npc_relationship_fact_catalog_npc_id_fact_id_key unique (npc_id, fact_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_fact_catalog_npc_id_fkey' and conrelid = 'private.world_biryong_npc_relationship_fact_catalog'::regclass) then alter table private.world_biryong_npc_relationship_fact_catalog add constraint world_biryong_npc_relationship_fact_catalog_npc_id_fkey foreign key (npc_id) REFERENCES private.world_biryong_npc_relationship_npc_catalog(npc_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_fact_catalog_pkey' and conrelid = 'private.world_biryong_npc_relationship_fact_catalog'::regclass) then alter table private.world_biryong_npc_relationship_fact_catalog add constraint world_biryong_npc_relationship_fact_catalog_pkey primary key (fact_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_fact_catalog_status_check' and conrelid = 'private.world_biryong_npc_relationship_fact_catalog'::regclass) then alter table private.world_biryong_npc_relationship_fact_catalog add constraint world_biryong_npc_relationship_fact_catalog_status_check check ((status = ANY (ARRAY['ACTIVE'::text, 'DISABLED'::text, 'HIDDEN'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_fact_catalog_topic_id_check' and conrelid = 'private.world_biryong_npc_relationship_fact_catalog'::regclass) then alter table private.world_biryong_npc_relationship_fact_catalog add constraint world_biryong_npc_relationship_fact_catalog_topic_id_check check ((topic_id ~ '^[a-z][a-z0-9_]{1,40}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_fact_catalog_topic_label_check' and conrelid = 'private.world_biryong_npc_relationship_fact_catalog'::regclass) then alter table private.world_biryong_npc_relationship_fact_catalog add constraint world_biryong_npc_relationship_fact_catalog_topic_label_check check (((char_length(topic_label) >= 1) AND (char_length(topic_label) <= 40))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_fact_catalog_unlock_stage_check' and conrelid = 'private.world_biryong_npc_relationship_fact_catalog'::regclass) then alter table private.world_biryong_npc_relationship_fact_catalog add constraint world_biryong_npc_relationship_fact_catalog_unlock_stage_check check ((unlock_stage = ANY (ARRAY[2, 3]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_npc_cat_definition_version_check' and conrelid = 'private.world_biryong_npc_relationship_npc_catalog'::regclass) then alter table private.world_biryong_npc_relationship_npc_catalog add constraint world_biryong_npc_relationship_npc_cat_definition_version_check check ((definition_version >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_npc_catalog_display_name_check' and conrelid = 'private.world_biryong_npc_relationship_npc_catalog'::regclass) then alter table private.world_biryong_npc_relationship_npc_catalog add constraint world_biryong_npc_relationship_npc_catalog_display_name_check check (((char_length(display_name) >= 1) AND (char_length(display_name) <= 40))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_npc_catalog_npc_id_check' and conrelid = 'private.world_biryong_npc_relationship_npc_catalog'::regclass) then alter table private.world_biryong_npc_relationship_npc_catalog add constraint world_biryong_npc_relationship_npc_catalog_npc_id_check check ((npc_id ~ '^BR_NPC_00[1-8]$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_npc_catalog_pkey' and conrelid = 'private.world_biryong_npc_relationship_npc_catalog'::regclass) then alter table private.world_biryong_npc_relationship_npc_catalog add constraint world_biryong_npc_relationship_npc_catalog_pkey primary key (npc_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_npc_relationship_npc_catalog_status_check' and conrelid = 'private.world_biryong_npc_relationship_npc_catalog'::regclass) then alter table private.world_biryong_npc_relationship_npc_catalog add constraint world_biryong_npc_relationship_npc_catalog_status_check check ((status = ANY (ARRAY['ACTIVE'::text, 'DISABLED'::text, 'HIDDEN'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_complete_time' and conrelid = 'private.world_biryong_progress_v1'::regclass) then alter table private.world_biryong_progress_v1 add constraint world_biryong_complete_time check (((step = 'COMPLETE'::text) = (completed_at IS NOT NULL))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_progress_v1_pkey' and conrelid = 'private.world_biryong_progress_v1'::regclass) then alter table private.world_biryong_progress_v1 add constraint world_biryong_progress_v1_pkey primary key (user_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_progress_v1_shouts_check' and conrelid = 'private.world_biryong_progress_v1'::regclass) then alter table private.world_biryong_progress_v1 add constraint world_biryong_progress_v1_shouts_check check ((shouts >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_progress_v1_step_check' and conrelid = 'private.world_biryong_progress_v1'::regclass) then alter table private.world_biryong_progress_v1 add constraint world_biryong_progress_v1_step_check check ((step = ANY (ARRAY['INTRO'::text, 'FIND_CENTER'::text, 'SHOUT'::text, 'REACTION'::text, 'COMPLETE'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_first_meeting_occurrence_check' and conrelid = 'private.world_campus_npc_relationship_events'::regclass) then alter table private.world_campus_npc_relationship_events add constraint world_campus_npc_first_meeting_occurrence_check check (((event_type <> 'FIRST_MEETING'::text) OR (occurrence = 1))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_delta_check' and conrelid = 'private.world_campus_npc_relationship_events'::regclass) then alter table private.world_campus_npc_relationship_events add constraint world_campus_npc_relationship_delta_check check (((affinity_after - affinity_before) = applied_delta)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_events_affinity_after_check' and conrelid = 'private.world_campus_npc_relationship_events'::regclass) then alter table private.world_campus_npc_relationship_events add constraint world_campus_npc_relationship_events_affinity_after_check check (((affinity_after >= 0) AND (affinity_after <= 100))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_events_affinity_before_check' and conrelid = 'private.world_campus_npc_relationship_events'::regclass) then alter table private.world_campus_npc_relationship_events add constraint world_campus_npc_relationship_events_affinity_before_check check (((affinity_before >= 0) AND (affinity_before <= 100))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_events_applied_delta_check' and conrelid = 'private.world_campus_npc_relationship_events'::regclass) then alter table private.world_campus_npc_relationship_events add constraint world_campus_npc_relationship_events_applied_delta_check check (((applied_delta >= '-10'::integer) AND (applied_delta <= 10))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_events_definition_version_check' and conrelid = 'private.world_campus_npc_relationship_events'::regclass) then alter table private.world_campus_npc_relationship_events add constraint world_campus_npc_relationship_events_definition_version_check check ((definition_version >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_events_event_type_check' and conrelid = 'private.world_campus_npc_relationship_events'::regclass) then alter table private.world_campus_npc_relationship_events add constraint world_campus_npc_relationship_events_event_type_check check ((event_type = ANY (ARRAY['FIRST_MEETING'::text, 'REUNION'::text, 'MEANINGFUL_DIALOGUE'::text, 'SHARED_ACTIVITY'::text, 'HELPED_NPC'::text, 'PERSONAL_QUEST_STEP'::text, 'PERSONAL_QUEST_COMPLETE'::text, 'MEANINGFUL_CHOICE'::text, 'NEGATIVE_CHOICE'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_events_idempotency_key_check' and conrelid = 'private.world_campus_npc_relationship_events'::regclass) then alter table private.world_campus_npc_relationship_events add constraint world_campus_npc_relationship_events_idempotency_key_check check (((idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text) AND (char_length(idempotency_key) <= 200))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_events_idempotency_key_key' and conrelid = 'private.world_campus_npc_relationship_events'::regclass) then alter table private.world_campus_npc_relationship_events add constraint world_campus_npc_relationship_events_idempotency_key_key unique (idempotency_key); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_events_npc_id_fkey' and conrelid = 'private.world_campus_npc_relationship_events'::regclass) then alter table private.world_campus_npc_relationship_events add constraint world_campus_npc_relationship_events_npc_id_fkey foreign key (npc_id) REFERENCES private.world_campus_npc_relationship_npc_catalog(npc_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_events_occurrence_check' and conrelid = 'private.world_campus_npc_relationship_events'::regclass) then alter table private.world_campus_npc_relationship_events add constraint world_campus_npc_relationship_events_occurrence_check check (((occurrence >= 1) AND (occurrence <= 1000))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_events_pkey' and conrelid = 'private.world_campus_npc_relationship_events'::regclass) then alter table private.world_campus_npc_relationship_events add constraint world_campus_npc_relationship_events_pkey primary key (relationship_event_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_events_requested_delta_check' and conrelid = 'private.world_campus_npc_relationship_events'::regclass) then alter table private.world_campus_npc_relationship_events add constraint world_campus_npc_relationship_events_requested_delta_check check ((((requested_delta >= '-10'::integer) AND (requested_delta <= 10)) AND (requested_delta <> 0))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_events_signal_check' and conrelid = 'private.world_campus_npc_relationship_events'::regclass) then alter table private.world_campus_npc_relationship_events add constraint world_campus_npc_relationship_events_signal_check check (((signal IS NULL) OR ((signal ~ '^[A-Z][A-Z0-9_]{1,63}$'::text) AND (char_length(signal) <= 64)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_events_source_ref_check' and conrelid = 'private.world_campus_npc_relationship_events'::regclass) then alter table private.world_campus_npc_relationship_events add constraint world_campus_npc_relationship_events_source_ref_check check (((source_ref ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text) AND (char_length(source_ref) <= 200))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_events_source_type_check' and conrelid = 'private.world_campus_npc_relationship_events'::regclass) then alter table private.world_campus_npc_relationship_events add constraint world_campus_npc_relationship_events_source_type_check check ((source_type = ANY (ARRAY['DIALOGUE'::text, 'ACTIVITY'::text, 'QUEST'::text, 'WORLD'::text, 'SYSTEM'::text, 'ADMIN'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_sign_check' and conrelid = 'private.world_campus_npc_relationship_events'::regclass) then alter table private.world_campus_npc_relationship_events add constraint world_campus_npc_relationship_sign_check check ((((event_type = 'NEGATIVE_CHOICE'::text) AND (requested_delta < 0)) OR ((event_type <> 'NEGATIVE_CHOICE'::text) AND (requested_delta > 0)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_npc_cata_definition_version_check' and conrelid = 'private.world_campus_npc_relationship_npc_catalog'::regclass) then alter table private.world_campus_npc_relationship_npc_catalog add constraint world_campus_npc_relationship_npc_cata_definition_version_check check ((definition_version >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_npc_cata_relationship_class_check' and conrelid = 'private.world_campus_npc_relationship_npc_catalog'::regclass) then alter table private.world_campus_npc_relationship_npc_catalog add constraint world_campus_npc_relationship_npc_cata_relationship_class_check check ((relationship_class = ANY (ARRAY['HERO'::text, 'RESIDENT'::text, 'CROWD'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_npc_catalog_npc_id_check' and conrelid = 'private.world_campus_npc_relationship_npc_catalog'::regclass) then alter table private.world_campus_npc_relationship_npc_catalog add constraint world_campus_npc_relationship_npc_catalog_npc_id_check check ((npc_id ~ '^INKYUNG-NPC-[0-9]{3}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_npc_catalog_pkey' and conrelid = 'private.world_campus_npc_relationship_npc_catalog'::regclass) then alter table private.world_campus_npc_relationship_npc_catalog add constraint world_campus_npc_relationship_npc_catalog_pkey primary key (npc_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_npc_catalog_status_check' and conrelid = 'private.world_campus_npc_relationship_npc_catalog'::regclass) then alter table private.world_campus_npc_relationship_npc_catalog add constraint world_campus_npc_relationship_npc_catalog_status_check check ((status = ANY (ARRAY['ACTIVE'::text, 'DISABLED'::text, 'HIDDEN'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_currencies_currency_id_check' and conrelid = 'private.world_currencies'::regclass) then alter table private.world_currencies add constraint world_currencies_currency_id_check check ((currency_id ~ '^currency\.[a-z][a-z0-9_]{0,47}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_currencies_display_name_check' and conrelid = 'private.world_currencies'::regclass) then alter table private.world_currencies add constraint world_currencies_display_name_check check (((char_length(display_name) >= 1) AND (char_length(display_name) <= 40))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_currencies_pkey' and conrelid = 'private.world_currencies'::regclass) then alter table private.world_currencies add constraint world_currencies_pkey primary key (currency_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_currency_transactions_amount_check' and conrelid = 'private.world_currency_transactions'::regclass) then alter table private.world_currency_transactions add constraint world_currency_transactions_amount_check check ((amount <> 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_currency_transactions_balance_after_check' and conrelid = 'private.world_currency_transactions'::regclass) then alter table private.world_currency_transactions add constraint world_currency_transactions_balance_after_check check ((balance_after >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_currency_transactions_balance_before_check' and conrelid = 'private.world_currency_transactions'::regclass) then alter table private.world_currency_transactions add constraint world_currency_transactions_balance_before_check check ((balance_before >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_currency_transactions_balance_math' and conrelid = 'private.world_currency_transactions'::regclass) then alter table private.world_currency_transactions add constraint world_currency_transactions_balance_math check ((balance_after = (balance_before + amount))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_currency_transactions_direction' and conrelid = 'private.world_currency_transactions'::regclass) then alter table private.world_currency_transactions add constraint world_currency_transactions_direction check ((((type = ANY (ARRAY['REWARD'::text, 'REFUND'::text])) AND (amount > 0)) OR ((type = 'PURCHASE'::text) AND (amount < 0)) OR (type = ANY (ARRAY['ADMIN'::text, 'ADJUSTMENT'::text])))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_currency_transactions_idempotency_key_check' and conrelid = 'private.world_currency_transactions'::regclass) then alter table private.world_currency_transactions add constraint world_currency_transactions_idempotency_key_check check ((idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_currency_transactions_idempotency_key_key' and conrelid = 'private.world_currency_transactions'::regclass) then alter table private.world_currency_transactions add constraint world_currency_transactions_idempotency_key_key unique (idempotency_key); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_currency_transactions_operator_reason' and conrelid = 'private.world_currency_transactions'::regclass) then alter table private.world_currency_transactions add constraint world_currency_transactions_operator_reason check (((type <> ALL (ARRAY['ADMIN'::text, 'ADJUSTMENT'::text])) OR (reason IS NOT NULL))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_currency_transactions_pkey' and conrelid = 'private.world_currency_transactions'::regclass) then alter table private.world_currency_transactions add constraint world_currency_transactions_pkey primary key (transaction_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_currency_transactions_reason_check' and conrelid = 'private.world_currency_transactions'::regclass) then alter table private.world_currency_transactions add constraint world_currency_transactions_reason_check check (((reason IS NULL) OR ((char_length(reason) >= 1) AND (char_length(reason) <= 500)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_currency_transactions_source_id_check' and conrelid = 'private.world_currency_transactions'::regclass) then alter table private.world_currency_transactions add constraint world_currency_transactions_source_id_check check (((char_length(source_id) >= 1) AND (char_length(source_id) <= 200))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_currency_transactions_source_type_check' and conrelid = 'private.world_currency_transactions'::regclass) then alter table private.world_currency_transactions add constraint world_currency_transactions_source_type_check check ((source_type ~ '^[a-z][a-z0-9_]{0,31}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_currency_transactions_type_check' and conrelid = 'private.world_currency_transactions'::regclass) then alter table private.world_currency_transactions add constraint world_currency_transactions_type_check check ((type = ANY (ARRAY['REWARD'::text, 'PURCHASE'::text, 'REFUND'::text, 'ADMIN'::text, 'ADJUSTMENT'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_currency_transactions_wallet_fkey' and conrelid = 'private.world_currency_transactions'::regclass) then alter table private.world_currency_transactions add constraint world_currency_transactions_wallet_fkey foreign key (user_id, currency_id) REFERENCES private.world_wallets(user_id, currency_id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_answers_pkey' and conrelid = 'private.world_daily_quiz_answers'::regclass) then alter table private.world_daily_quiz_answers add constraint world_daily_quiz_answers_pkey primary key (run_id, question_index); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_answers_question_id_fkey' and conrelid = 'private.world_daily_quiz_answers'::regclass) then alter table private.world_daily_quiz_answers add constraint world_daily_quiz_answers_question_id_fkey foreign key (question_id) REFERENCES private.world_daily_quiz_questions(question_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_answers_question_index_check' and conrelid = 'private.world_daily_quiz_answers'::regclass) then alter table private.world_daily_quiz_answers add constraint world_daily_quiz_answers_question_index_check check (((question_index >= 0) AND (question_index <= 2))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_answers_run_id_fkey' and conrelid = 'private.world_daily_quiz_answers'::regclass) then alter table private.world_daily_quiz_answers add constraint world_daily_quiz_answers_run_id_fkey foreign key (run_id) REFERENCES private.world_daily_quiz_runs(run_id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_answers_selected_index_check' and conrelid = 'private.world_daily_quiz_answers'::regclass) then alter table private.world_daily_quiz_answers add constraint world_daily_quiz_answers_selected_index_check check (((selected_index >= 0) AND (selected_index <= 3))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_questions_category_check' and conrelid = 'private.world_daily_quiz_questions'::regclass) then alter table private.world_daily_quiz_questions add constraint world_daily_quiz_questions_category_check check ((category ~ '^[a-z][a-z0-9_]{0,31}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_questions_correct_index_check' and conrelid = 'private.world_daily_quiz_questions'::regclass) then alter table private.world_daily_quiz_questions add constraint world_daily_quiz_questions_correct_index_check check (((correct_index >= 0) AND (correct_index <= 3))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_questions_options_check' and conrelid = 'private.world_daily_quiz_questions'::regclass) then alter table private.world_daily_quiz_questions add constraint world_daily_quiz_questions_options_check check (((jsonb_typeof(options) = 'array'::text) AND (jsonb_array_length(options) = 4) AND (jsonb_typeof((options -> 0)) = 'string'::text) AND (jsonb_typeof((options -> 1)) = 'string'::text) AND (jsonb_typeof((options -> 2)) = 'string'::text) AND (jsonb_typeof((options -> 3)) = 'string'::text))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_questions_pkey' and conrelid = 'private.world_daily_quiz_questions'::regclass) then alter table private.world_daily_quiz_questions add constraint world_daily_quiz_questions_pkey primary key (question_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_questions_position_check' and conrelid = 'private.world_daily_quiz_questions'::regclass) then alter table private.world_daily_quiz_questions add constraint world_daily_quiz_questions_position_check check (("position" >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_questions_position_key' and conrelid = 'private.world_daily_quiz_questions'::regclass) then alter table private.world_daily_quiz_questions add constraint world_daily_quiz_questions_position_key unique ("position"); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_questions_prompt_check' and conrelid = 'private.world_daily_quiz_questions'::regclass) then alter table private.world_daily_quiz_questions add constraint world_daily_quiz_questions_prompt_check check (((char_length(prompt) >= 4) AND (char_length(prompt) <= 200))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_questions_question_id_check' and conrelid = 'private.world_daily_quiz_questions'::regclass) then alter table private.world_daily_quiz_questions add constraint world_daily_quiz_questions_question_id_check check ((question_id ~ '^quiz\.campus\.[a-z0-9_]{1,60}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_questions_status_check' and conrelid = 'private.world_daily_quiz_questions'::regclass) then alter table private.world_daily_quiz_questions add constraint world_daily_quiz_questions_status_check check ((status = ANY (ARRAY['ACTIVE'::text, 'DISABLED'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_questions_version_check' and conrelid = 'private.world_daily_quiz_questions'::regclass) then alter table private.world_daily_quiz_questions add constraint world_daily_quiz_questions_version_check check ((version >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_runs_answered_count_check' and conrelid = 'private.world_daily_quiz_runs'::regclass) then alter table private.world_daily_quiz_runs add constraint world_daily_quiz_runs_answered_count_check check (((answered_count >= 0) AND (answered_count <= 3))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_runs_check' and conrelid = 'private.world_daily_quiz_runs'::regclass) then alter table private.world_daily_quiz_runs add constraint world_daily_quiz_runs_check check (((correct_count >= 0) AND (correct_count <= answered_count))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_runs_final' and conrelid = 'private.world_daily_quiz_runs'::regclass) then alter table private.world_daily_quiz_runs add constraint world_daily_quiz_runs_final check ((((status = 'ACTIVE'::text) AND (answered_count < 3) AND (completed_at IS NULL) AND (reward_transaction_id IS NULL)) OR ((status = 'PASSED'::text) AND (answered_count = 3) AND (correct_count >= 2) AND (completed_at IS NOT NULL) AND (reward_transaction_id IS NOT NULL)) OR ((status = 'FAILED'::text) AND (answered_count = 3) AND (correct_count < 2) AND (completed_at IS NOT NULL) AND (reward_transaction_id IS NULL)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_runs_pkey' and conrelid = 'private.world_daily_quiz_runs'::regclass) then alter table private.world_daily_quiz_runs add constraint world_daily_quiz_runs_pkey primary key (run_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_runs_question_ids_check' and conrelid = 'private.world_daily_quiz_runs'::regclass) then alter table private.world_daily_quiz_runs add constraint world_daily_quiz_runs_question_ids_check check ((cardinality(question_ids) = 3)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_runs_reward_transaction_id_fkey' and conrelid = 'private.world_daily_quiz_runs'::regclass) then alter table private.world_daily_quiz_runs add constraint world_daily_quiz_runs_reward_transaction_id_fkey foreign key (reward_transaction_id) REFERENCES private.world_reward_transactions(reward_transaction_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_runs_status_check' and conrelid = 'private.world_daily_quiz_runs'::regclass) then alter table private.world_daily_quiz_runs add constraint world_daily_quiz_runs_status_check check ((status = ANY (ARRAY['ACTIVE'::text, 'PASSED'::text, 'FAILED'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_daily_quiz_runs_user_id_reward_date_key' and conrelid = 'private.world_daily_quiz_runs'::regclass) then alter table private.world_daily_quiz_runs add constraint world_daily_quiz_runs_user_id_reward_date_key unique (user_id, reward_date); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_event_progress_completed' and conrelid = 'private.world_event_progress'::regclass) then alter table private.world_event_progress add constraint world_event_progress_completed check (((stage = 3) = (completed_at IS NOT NULL))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_event_progress_event_id_check' and conrelid = 'private.world_event_progress'::regclass) then alter table private.world_event_progress add constraint world_event_progress_event_id_check check ((event_id = 'event.mcm_2026'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_event_progress_event_id_fkey' and conrelid = 'private.world_event_progress'::regclass) then alter table private.world_event_progress add constraint world_event_progress_event_id_fkey foreign key (event_id) REFERENCES private.world_events(event_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_event_progress_investigated_check' and conrelid = 'private.world_event_progress'::regclass) then alter table private.world_event_progress add constraint world_event_progress_investigated_check check ((investigated <@ ARRAY['staggering'::text, 'dancing'::text, 'hungry'::text])); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_event_progress_pkey' and conrelid = 'private.world_event_progress'::regclass) then alter table private.world_event_progress add constraint world_event_progress_pkey primary key (user_id, event_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_event_progress_stage_check' and conrelid = 'private.world_event_progress'::regclass) then alter table private.world_event_progress add constraint world_event_progress_stage_check check (((stage >= 1) AND (stage <= 3))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_event_progress_venue' and conrelid = 'private.world_event_progress'::regclass) then alter table private.world_event_progress add constraint world_event_progress_venue check (((stage >= 2) = (venue_unlocked_at IS NOT NULL))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_event_progress_venue_needs_all' and conrelid = 'private.world_event_progress'::regclass) then alter table private.world_event_progress add constraint world_event_progress_venue_needs_all check (((stage < 2) OR (investigated @> ARRAY['staggering'::text, 'dancing'::text, 'hungry'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_events_event_id_check' and conrelid = 'private.world_events'::regclass) then alter table private.world_events add constraint world_events_event_id_check check ((event_id ~ '^event\.[a-z0-9_]+$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_events_pkey' and conrelid = 'private.world_events'::regclass) then alter table private.world_events add constraint world_events_pkey primary key (event_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_events_title_check' and conrelid = 'private.world_events'::regclass) then alter table private.world_events add constraint world_events_title_check check (((char_length(title) >= 1) AND (char_length(title) <= 80))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_events_window' and conrelid = 'private.world_events'::regclass) then alter table private.world_events add constraint world_events_window check ((starts_at < ends_at)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_exp_transactions_amount_check' and conrelid = 'private.world_exp_transactions'::regclass) then alter table private.world_exp_transactions add constraint world_exp_transactions_amount_check check ((amount > 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_exp_transactions_exp_after_check' and conrelid = 'private.world_exp_transactions'::regclass) then alter table private.world_exp_transactions add constraint world_exp_transactions_exp_after_check check ((exp_after >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_exp_transactions_exp_before_check' and conrelid = 'private.world_exp_transactions'::regclass) then alter table private.world_exp_transactions add constraint world_exp_transactions_exp_before_check check ((exp_before >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_exp_transactions_idempotency_key_check' and conrelid = 'private.world_exp_transactions'::regclass) then alter table private.world_exp_transactions add constraint world_exp_transactions_idempotency_key_check check ((idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_exp_transactions_idempotency_key_key' and conrelid = 'private.world_exp_transactions'::regclass) then alter table private.world_exp_transactions add constraint world_exp_transactions_idempotency_key_key unique (idempotency_key); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_exp_transactions_level_after_check' and conrelid = 'private.world_exp_transactions'::regclass) then alter table private.world_exp_transactions add constraint world_exp_transactions_level_after_check check ((level_after >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_exp_transactions_level_before_check' and conrelid = 'private.world_exp_transactions'::regclass) then alter table private.world_exp_transactions add constraint world_exp_transactions_level_before_check check ((level_before >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_exp_transactions_level_monotonic' and conrelid = 'private.world_exp_transactions'::regclass) then alter table private.world_exp_transactions add constraint world_exp_transactions_level_monotonic check ((level_after >= level_before)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_exp_transactions_math' and conrelid = 'private.world_exp_transactions'::regclass) then alter table private.world_exp_transactions add constraint world_exp_transactions_math check ((exp_after = (exp_before + amount))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_exp_transactions_pkey' and conrelid = 'private.world_exp_transactions'::regclass) then alter table private.world_exp_transactions add constraint world_exp_transactions_pkey primary key (transaction_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_exp_transactions_source_id_check' and conrelid = 'private.world_exp_transactions'::regclass) then alter table private.world_exp_transactions add constraint world_exp_transactions_source_id_check check (((char_length(source_id) >= 1) AND (char_length(source_id) <= 200))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_exp_transactions_source_type_check' and conrelid = 'private.world_exp_transactions'::regclass) then alter table private.world_exp_transactions add constraint world_exp_transactions_source_type_check check ((source_type ~ '^[a-z][a-z0-9_]{0,31}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_exp_transactions_user_id_fkey' and conrelid = 'private.world_exp_transactions'::regclass) then alter table private.world_exp_transactions add constraint world_exp_transactions_user_id_fkey foreign key (user_id) REFERENCES private.world_player_progression(user_id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_guestbook_post_log_entry_id_key' and conrelid = 'private.world_guestbook_post_log'::regclass) then alter table private.world_guestbook_post_log add constraint world_guestbook_post_log_entry_id_key unique (entry_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_guestbook_post_log_pkey' and conrelid = 'private.world_guestbook_post_log'::regclass) then alter table private.world_guestbook_post_log add constraint world_guestbook_post_log_pkey primary key (id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_inventory_mutation_entries_child_idempotency_key_check' and conrelid = 'private.world_inventory_mutation_entries'::regclass) then alter table private.world_inventory_mutation_entries add constraint world_inventory_mutation_entries_child_idempotency_key_check check ((child_idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_inventory_mutation_entries_child_ref_check' and conrelid = 'private.world_inventory_mutation_entries'::regclass) then alter table private.world_inventory_mutation_entries add constraint world_inventory_mutation_entries_child_ref_check check (((char_length(child_ref) >= 1) AND (char_length(child_ref) <= 200))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_inventory_mutation_entries_direction_check' and conrelid = 'private.world_inventory_mutation_entries'::regclass) then alter table private.world_inventory_mutation_entries add constraint world_inventory_mutation_entries_direction_check check ((direction = ANY (ARRAY['CONSUME'::text, 'GRANT'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_inventory_mutation_entries_item_id_check' and conrelid = 'private.world_inventory_mutation_entries'::regclass) then alter table private.world_inventory_mutation_entries add constraint world_inventory_mutation_entries_item_id_check check (((item_id ~ '^[a-z][a-z0-9_]*\.[a-z0-9_]+$'::text) AND (char_length(item_id) <= 80))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_inventory_mutation_entries_mutation_id_fkey' and conrelid = 'private.world_inventory_mutation_entries'::regclass) then alter table private.world_inventory_mutation_entries add constraint world_inventory_mutation_entries_mutation_id_fkey foreign key (mutation_id) REFERENCES private.world_inventory_mutations(mutation_id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_inventory_mutation_entries_pkey' and conrelid = 'private.world_inventory_mutation_entries'::regclass) then alter table private.world_inventory_mutation_entries add constraint world_inventory_mutation_entries_pkey primary key (mutation_id, "position"); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_inventory_mutation_entries_position_check' and conrelid = 'private.world_inventory_mutation_entries'::regclass) then alter table private.world_inventory_mutation_entries add constraint world_inventory_mutation_entries_position_check check ((("position" >= 0) AND ("position" < 32))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_inventory_mutation_entries_quantity_after_check' and conrelid = 'private.world_inventory_mutation_entries'::regclass) then alter table private.world_inventory_mutation_entries add constraint world_inventory_mutation_entries_quantity_after_check check ((quantity_after >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_inventory_mutation_entries_quantity_before_check' and conrelid = 'private.world_inventory_mutation_entries'::regclass) then alter table private.world_inventory_mutation_entries add constraint world_inventory_mutation_entries_quantity_before_check check ((quantity_before >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_inventory_mutation_entries_quantity_check' and conrelid = 'private.world_inventory_mutation_entries'::regclass) then alter table private.world_inventory_mutation_entries add constraint world_inventory_mutation_entries_quantity_check check ((quantity >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_inventory_mutations_idempotency_key_check' and conrelid = 'private.world_inventory_mutations'::regclass) then alter table private.world_inventory_mutations add constraint world_inventory_mutations_idempotency_key_check check ((idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,159}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_inventory_mutations_idempotency_key_key' and conrelid = 'private.world_inventory_mutations'::regclass) then alter table private.world_inventory_mutations add constraint world_inventory_mutations_idempotency_key_key unique (idempotency_key); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_inventory_mutations_mutation_type_check' and conrelid = 'private.world_inventory_mutations'::regclass) then alter table private.world_inventory_mutations add constraint world_inventory_mutations_mutation_type_check check ((mutation_type = ANY (ARRAY['CONSUME'::text, 'CRAFT'::text, 'PROCESS'::text, 'COOK'::text, 'DISASSEMBLE'::text, 'ENHANCE'::text, 'RESEARCH'::text, 'SYSTEM_EXCHANGE'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_inventory_mutations_pkey' and conrelid = 'private.world_inventory_mutations'::regclass) then alter table private.world_inventory_mutations add constraint world_inventory_mutations_pkey primary key (mutation_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_inventory_mutations_plan_check' and conrelid = 'private.world_inventory_mutations'::regclass) then alter table private.world_inventory_mutations add constraint world_inventory_mutations_plan_check check ((jsonb_typeof(plan) = 'object'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_inventory_mutations_source_ref_check' and conrelid = 'private.world_inventory_mutations'::regclass) then alter table private.world_inventory_mutations add constraint world_inventory_mutations_source_ref_check check (((char_length(source_ref) >= 1) AND (char_length(source_ref) <= 200))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_inventory_mutations_source_type_check' and conrelid = 'private.world_inventory_mutations'::regclass) then alter table private.world_inventory_mutations add constraint world_inventory_mutations_source_type_check check ((source_type = ANY (ARRAY['DEFAULT'::text, 'QUEST'::text, 'EXPLORATION'::text, 'ACHIEVEMENT'::text, 'EVENT'::text, 'MINIGAME'::text, 'SHOP'::text, 'INHAGAME_REWARD'::text, 'ACTIVITY'::text, 'CRAFTING'::text, 'EQUIPMENT'::text, 'RESEARCH'::text, 'SYSTEM'::text, 'ADMIN'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_inventory_mutations_status_check' and conrelid = 'private.world_inventory_mutations'::regclass) then alter table private.world_inventory_mutations add constraint world_inventory_mutations_status_check check ((status = 'COMPLETED'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_catalog_category_check' and conrelid = 'private.world_item_catalog'::regclass) then alter table private.world_item_catalog add constraint world_item_catalog_category_check check ((category = ANY (ARRAY['WEARABLE'::text, 'BADGE'::text, 'EMOTE'::text, 'FURNITURE'::text, 'MOUNT'::text, 'MOUNT_COSMETIC'::text, 'MEMORABILIA'::text, 'MATERIAL'::text, 'CONSUMABLE'::text, 'ROOM_FINISH'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_catalog_item_id_check' and conrelid = 'private.world_item_catalog'::regclass) then alter table private.world_item_catalog add constraint world_item_catalog_item_id_check check (((item_id ~ '^[a-z][a-z0-9_]*\.[a-z0-9_]+$'::text) AND (char_length(item_id) <= 80))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_catalog_ownership_policy_check' and conrelid = 'private.world_item_catalog'::regclass) then alter table private.world_item_catalog add constraint world_item_catalog_ownership_policy_check check ((ownership_policy = ANY (ARRAY['UNIQUE'::text, 'STACKABLE'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_catalog_pkey' and conrelid = 'private.world_item_catalog'::regclass) then alter table private.world_item_catalog add constraint world_item_catalog_pkey primary key (item_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_catalog_stack_policy' and conrelid = 'private.world_item_catalog'::regclass) then alter table private.world_item_catalog add constraint world_item_catalog_stack_policy check ((((ownership_policy = 'UNIQUE'::text) AND (max_stack IS NULL)) OR ((ownership_policy = 'STACKABLE'::text) AND (max_stack >= 2)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_catalog_status_check' and conrelid = 'private.world_item_catalog'::regclass) then alter table private.world_item_catalog add constraint world_item_catalog_status_check check ((status = ANY (ARRAY['ACTIVE'::text, 'LOCKED'::text, 'COMING_SOON'::text, 'DISABLED'::text, 'HIDDEN'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_consumptions_consume_id_check' and conrelid = 'private.world_item_consumptions'::regclass) then alter table private.world_item_consumptions add constraint world_item_consumptions_consume_id_check check ((consume_id ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_consumptions_item_id_check' and conrelid = 'private.world_item_consumptions'::regclass) then alter table private.world_item_consumptions add constraint world_item_consumptions_item_id_check check (((item_id ~ '^[a-z][a-z0-9_]*\.[a-z0-9_]+$'::text) AND (char_length(item_id) <= 80))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_consumptions_math' and conrelid = 'private.world_item_consumptions'::regclass) then alter table private.world_item_consumptions add constraint world_item_consumptions_math check (((quantity_consumed = quantity_requested) AND (quantity_after = (quantity_before - quantity_consumed)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_consumptions_metadata_check' and conrelid = 'private.world_item_consumptions'::regclass) then alter table private.world_item_consumptions add constraint world_item_consumptions_metadata_check check (((metadata IS NULL) OR ((jsonb_typeof(metadata) = 'object'::text) AND (octet_length((metadata)::text) <= 2048)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_consumptions_parent_mutation_id_fkey' and conrelid = 'private.world_item_consumptions'::regclass) then alter table private.world_item_consumptions add constraint world_item_consumptions_parent_mutation_id_fkey foreign key (parent_mutation_id) REFERENCES private.world_inventory_mutations(mutation_id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_consumptions_pkey' and conrelid = 'private.world_item_consumptions'::regclass) then alter table private.world_item_consumptions add constraint world_item_consumptions_pkey primary key (consume_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_consumptions_quantity_after_check' and conrelid = 'private.world_item_consumptions'::regclass) then alter table private.world_item_consumptions add constraint world_item_consumptions_quantity_after_check check ((quantity_after >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_consumptions_quantity_before_check' and conrelid = 'private.world_item_consumptions'::regclass) then alter table private.world_item_consumptions add constraint world_item_consumptions_quantity_before_check check ((quantity_before >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_consumptions_quantity_consumed_check' and conrelid = 'private.world_item_consumptions'::regclass) then alter table private.world_item_consumptions add constraint world_item_consumptions_quantity_consumed_check check ((quantity_consumed >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_consumptions_quantity_requested_check' and conrelid = 'private.world_item_consumptions'::regclass) then alter table private.world_item_consumptions add constraint world_item_consumptions_quantity_requested_check check ((quantity_requested >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_consumptions_source_ref_check' and conrelid = 'private.world_item_consumptions'::regclass) then alter table private.world_item_consumptions add constraint world_item_consumptions_source_ref_check check (((char_length(source_ref) >= 1) AND (char_length(source_ref) <= 200))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_consumptions_source_type_check' and conrelid = 'private.world_item_consumptions'::regclass) then alter table private.world_item_consumptions add constraint world_item_consumptions_source_type_check check ((source_type = ANY (ARRAY['DEFAULT'::text, 'QUEST'::text, 'EXPLORATION'::text, 'ACHIEVEMENT'::text, 'EVENT'::text, 'MINIGAME'::text, 'SHOP'::text, 'INHAGAME_REWARD'::text, 'ACTIVITY'::text, 'CRAFTING'::text, 'EQUIPMENT'::text, 'RESEARCH'::text, 'SYSTEM'::text, 'ADMIN'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_grants_acquisition_metadata_check' and conrelid = 'private.world_item_grants'::regclass) then alter table private.world_item_grants add constraint world_item_grants_acquisition_metadata_check check (((acquisition_metadata IS NULL) OR ((jsonb_typeof(acquisition_metadata) = 'object'::text) AND (octet_length((acquisition_metadata)::text) <= 2048)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_grants_event_id_check' and conrelid = 'private.world_item_grants'::regclass) then alter table private.world_item_grants add constraint world_item_grants_event_id_check check (((event_id IS NULL) OR (event_id ~ '^[a-z][a-z0-9_]*\.[a-z0-9_]+$'::text))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_grants_grant_id_check' and conrelid = 'private.world_item_grants'::regclass) then alter table private.world_item_grants add constraint world_item_grants_grant_id_check check ((grant_id ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_grants_pkey' and conrelid = 'private.world_item_grants'::regclass) then alter table private.world_item_grants add constraint world_item_grants_pkey primary key (grant_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_grants_quantity_after_check' and conrelid = 'private.world_item_grants'::regclass) then alter table private.world_item_grants add constraint world_item_grants_quantity_after_check check ((quantity_after >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_grants_quantity_before_check' and conrelid = 'private.world_item_grants'::regclass) then alter table private.world_item_grants add constraint world_item_grants_quantity_before_check check ((quantity_before >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_grants_quantity_granted_check' and conrelid = 'private.world_item_grants'::regclass) then alter table private.world_item_grants add constraint world_item_grants_quantity_granted_check check ((quantity_granted >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_grants_quantity_math' and conrelid = 'private.world_item_grants'::regclass) then alter table private.world_item_grants add constraint world_item_grants_quantity_math check ((quantity_after = (quantity_before + quantity_granted))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_grants_quantity_requested_check' and conrelid = 'private.world_item_grants'::regclass) then alter table private.world_item_grants add constraint world_item_grants_quantity_requested_check check ((quantity_requested >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_grants_result' and conrelid = 'private.world_item_grants'::regclass) then alter table private.world_item_grants add constraint world_item_grants_result check ((((result = 'GRANTED'::text) AND (quantity_granted = quantity_requested)) OR ((result = 'ALREADY_OWNED'::text) AND (quantity_granted = 0)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_grants_result_check' and conrelid = 'private.world_item_grants'::regclass) then alter table private.world_item_grants add constraint world_item_grants_result_check check ((result = ANY (ARRAY['GRANTED'::text, 'ALREADY_OWNED'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_grants_source_ref_check' and conrelid = 'private.world_item_grants'::regclass) then alter table private.world_item_grants add constraint world_item_grants_source_ref_check check (((char_length(source_ref) >= 1) AND (char_length(source_ref) <= 200))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_item_grants_source_type_check' and conrelid = 'private.world_item_grants'::regclass) then alter table private.world_item_grants add constraint world_item_grants_source_type_check check ((source_type = ANY (ARRAY['DEFAULT'::text, 'QUEST'::text, 'EXPLORATION'::text, 'ACHIEVEMENT'::text, 'EVENT'::text, 'MINIGAME'::text, 'SHOP'::text, 'INHAGAME_REWARD'::text, 'ACTIVITY'::text, 'CRAFTING'::text, 'EQUIPMENT'::text, 'RESEARCH'::text, 'SYSTEM'::text, 'ADMIN'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_gate_policy_pkey' and conrelid = 'private.world_jeongseok_gate_policy'::regclass) then alter table private.world_jeongseok_gate_policy add constraint world_jeongseok_gate_policy_pkey primary key (singleton); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_gate_policy_singleton_check' and conrelid = 'private.world_jeongseok_gate_policy'::regclass) then alter table private.world_jeongseok_gate_policy add constraint world_jeongseok_gate_policy_singleton_check check (singleton); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_gate_policy_status_check' and conrelid = 'private.world_jeongseok_gate_policy'::regclass) then alter table private.world_jeongseok_gate_policy add constraint world_jeongseok_gate_policy_status_check check ((status = ANY (ARRAY['COMING_SOON'::text, 'ACTIVE'::text, 'DISABLED'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_catalog_confirmed_active' and conrelid = 'private.world_jeongseok_pass_catalog'::regclass) then alter table private.world_jeongseok_pass_catalog add constraint world_jeongseok_pass_catalog_confirmed_active check (((status <> 'ACTIVE'::text) OR (price_basis = 'CONFIRMED'::text))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_catalog_currency_id_fkey' and conrelid = 'private.world_jeongseok_pass_catalog'::regclass) then alter table private.world_jeongseok_pass_catalog add constraint world_jeongseok_pass_catalog_currency_id_fkey foreign key (currency_id) REFERENCES private.world_currencies(currency_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_catalog_duration_seconds_check' and conrelid = 'private.world_jeongseok_pass_catalog'::regclass) then alter table private.world_jeongseok_pass_catalog add constraint world_jeongseok_pass_catalog_duration_seconds_check check (((duration_seconds >= 3600) AND (duration_seconds <= 2592000))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_catalog_pass_type_check' and conrelid = 'private.world_jeongseok_pass_catalog'::regclass) then alter table private.world_jeongseok_pass_catalog add constraint world_jeongseok_pass_catalog_pass_type_check check ((pass_type ~ '^jeongseok\.visitor\.[a-z0-9_]+$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_catalog_pkey' and conrelid = 'private.world_jeongseok_pass_catalog'::regclass) then alter table private.world_jeongseok_pass_catalog add constraint world_jeongseok_pass_catalog_pkey primary key (pass_type); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_catalog_price_basis_check' and conrelid = 'private.world_jeongseok_pass_catalog'::regclass) then alter table private.world_jeongseok_pass_catalog add constraint world_jeongseok_pass_catalog_price_basis_check check ((price_basis = ANY (ARRAY['CANDIDATE'::text, 'CONFIRMED'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_catalog_price_check' and conrelid = 'private.world_jeongseok_pass_catalog'::regclass) then alter table private.world_jeongseok_pass_catalog add constraint world_jeongseok_pass_catalog_price_check check ((price > 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_catalog_status_check' and conrelid = 'private.world_jeongseok_pass_catalog'::regclass) then alter table private.world_jeongseok_pass_catalog add constraint world_jeongseok_pass_catalog_status_check check ((status = ANY (ARRAY['COMING_SOON'::text, 'ACTIVE'::text, 'DISABLED'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_entitlements_last_purchase_id_fkey' and conrelid = 'private.world_jeongseok_pass_entitlements'::regclass) then alter table private.world_jeongseok_pass_entitlements add constraint world_jeongseok_pass_entitlements_last_purchase_id_fkey foreign key (last_purchase_id) REFERENCES private.world_jeongseok_pass_purchases(purchase_id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_entitlements_last_purchase_id_key' and conrelid = 'private.world_jeongseok_pass_entitlements'::regclass) then alter table private.world_jeongseok_pass_entitlements add constraint world_jeongseok_pass_entitlements_last_purchase_id_key unique (last_purchase_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_entitlements_pass_type_fkey' and conrelid = 'private.world_jeongseok_pass_entitlements'::regclass) then alter table private.world_jeongseok_pass_entitlements add constraint world_jeongseok_pass_entitlements_pass_type_fkey foreign key (pass_type) REFERENCES private.world_jeongseok_pass_catalog(pass_type); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_entitlements_pkey' and conrelid = 'private.world_jeongseok_pass_entitlements'::regclass) then alter table private.world_jeongseok_pass_entitlements add constraint world_jeongseok_pass_entitlements_pkey primary key (user_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_entitlements_window' and conrelid = 'private.world_jeongseok_pass_entitlements'::regclass) then alter table private.world_jeongseok_pass_entitlements add constraint world_jeongseok_pass_entitlements_window check ((expires_at > issued_at)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_purchases_balance_after_check' and conrelid = 'private.world_jeongseok_pass_purchases'::regclass) then alter table private.world_jeongseok_pass_purchases add constraint world_jeongseok_pass_purchases_balance_after_check check ((balance_after >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_purchases_balance_before_check' and conrelid = 'private.world_jeongseok_pass_purchases'::regclass) then alter table private.world_jeongseok_pass_purchases add constraint world_jeongseok_pass_purchases_balance_before_check check ((balance_before >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_purchases_idempotency_key_check' and conrelid = 'private.world_jeongseok_pass_purchases'::regclass) then alter table private.world_jeongseok_pass_purchases add constraint world_jeongseok_pass_purchases_idempotency_key_check check ((idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,119}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_purchases_idempotency_key_key' and conrelid = 'private.world_jeongseok_pass_purchases'::regclass) then alter table private.world_jeongseok_pass_purchases add constraint world_jeongseok_pass_purchases_idempotency_key_key unique (idempotency_key); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_purchases_pass_type_fkey' and conrelid = 'private.world_jeongseok_pass_purchases'::regclass) then alter table private.world_jeongseok_pass_purchases add constraint world_jeongseok_pass_purchases_pass_type_fkey foreign key (pass_type) REFERENCES private.world_jeongseok_pass_catalog(pass_type); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_purchases_pkey' and conrelid = 'private.world_jeongseok_pass_purchases'::regclass) then alter table private.world_jeongseok_pass_purchases add constraint world_jeongseok_pass_purchases_pkey primary key (purchase_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_purchases_price_check' and conrelid = 'private.world_jeongseok_pass_purchases'::regclass) then alter table private.world_jeongseok_pass_purchases add constraint world_jeongseok_pass_purchases_price_check check ((price > 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_purchases_price_math' and conrelid = 'private.world_jeongseok_pass_purchases'::regclass) then alter table private.world_jeongseok_pass_purchases add constraint world_jeongseok_pass_purchases_price_math check ((balance_after = (balance_before - price))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_purchases_wallet_transaction_id_fkey' and conrelid = 'private.world_jeongseok_pass_purchases'::regclass) then alter table private.world_jeongseok_pass_purchases add constraint world_jeongseok_pass_purchases_wallet_transaction_id_fkey foreign key (wallet_transaction_id) REFERENCES private.world_currency_transactions(transaction_id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_purchases_wallet_transaction_id_key' and conrelid = 'private.world_jeongseok_pass_purchases'::regclass) then alter table private.world_jeongseok_pass_purchases add constraint world_jeongseok_pass_purchases_wallet_transaction_id_key unique (wallet_transaction_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_jeongseok_pass_purchases_window' and conrelid = 'private.world_jeongseok_pass_purchases'::regclass) then alter table private.world_jeongseok_pass_purchases add constraint world_jeongseok_pass_purchases_window check ((expires_at > issued_at)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_landlord_first_clears_event_id_fkey' and conrelid = 'private.world_landlord_first_clears'::regclass) then alter table private.world_landlord_first_clears add constraint world_landlord_first_clears_event_id_fkey foreign key (event_id) REFERENCES private.world_events(event_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_landlord_first_clears_pkey' and conrelid = 'private.world_landlord_first_clears'::regclass) then alter table private.world_landlord_first_clears add constraint world_landlord_first_clears_pkey primary key (user_id, event_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_landlord_first_clears_run_id_fkey' and conrelid = 'private.world_landlord_first_clears'::regclass) then alter table private.world_landlord_first_clears add constraint world_landlord_first_clears_run_id_fkey foreign key (run_id) REFERENCES private.world_landlord_runs(run_id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_landlord_runs_event_id_fkey' and conrelid = 'private.world_landlord_runs'::regclass) then alter table private.world_landlord_runs add constraint world_landlord_runs_event_id_fkey foreign key (event_id) REFERENCES private.world_events(event_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_landlord_runs_pkey' and conrelid = 'private.world_landlord_runs'::regclass) then alter table private.world_landlord_runs add constraint world_landlord_runs_pkey primary key (run_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_landlord_runs_status_check' and conrelid = 'private.world_landlord_runs'::regclass) then alter table private.world_landlord_runs add constraint world_landlord_runs_status_check check ((status = ANY (ARRAY['ACTIVE'::text, 'CLEARED'::text, 'FAILED'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_landlord_runs_survivor_actor_id_check' and conrelid = 'private.world_landlord_runs'::regclass) then alter table private.world_landlord_runs add constraint world_landlord_runs_survivor_actor_id_check check ((survivor_actor_id = ANY (ARRAY['ZUE-MG-001'::text, 'ZUE-MG-002'::text, 'ZUE-MG-003'::text, 'ZUE-MG-004'::text, 'ZUE-MG-005'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_landlord_runs_terminal' and conrelid = 'private.world_landlord_runs'::regclass) then alter table private.world_landlord_runs add constraint world_landlord_runs_terminal check (((status = 'ACTIVE'::text) = (ended_at IS NULL))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_landlord_runs_wrong_count_check' and conrelid = 'private.world_landlord_runs'::regclass) then alter table private.world_landlord_runs add constraint world_landlord_runs_wrong_count_check check ((wrong_count >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_level_thresholds_level1_zero' and conrelid = 'private.world_level_thresholds'::regclass) then alter table private.world_level_thresholds add constraint world_level_thresholds_level1_zero check (((level <> 1) OR (min_total_exp = 0))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_level_thresholds_level_check' and conrelid = 'private.world_level_thresholds'::regclass) then alter table private.world_level_thresholds add constraint world_level_thresholds_level_check check ((level >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_level_thresholds_min_total_exp_check' and conrelid = 'private.world_level_thresholds'::regclass) then alter table private.world_level_thresholds add constraint world_level_thresholds_min_total_exp_check check ((min_total_exp >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_level_thresholds_min_total_exp_key' and conrelid = 'private.world_level_thresholds'::regclass) then alter table private.world_level_thresholds add constraint world_level_thresholds_min_total_exp_key unique (min_total_exp); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_level_thresholds_pkey' and conrelid = 'private.world_level_thresholds'::regclass) then alter table private.world_level_thresholds add constraint world_level_thresholds_pkey primary key (level); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_progression_thresholds_cumulative_sp_check' and conrelid = 'private.world_life_progression_thresholds'::regclass) then alter table private.world_life_progression_thresholds add constraint world_life_progression_thresholds_cumulative_sp_check check ((cumulative_sp >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_progression_thresholds_curve_id_check' and conrelid = 'private.world_life_progression_thresholds'::regclass) then alter table private.world_life_progression_thresholds add constraint world_life_progression_thresholds_curve_id_check check (((curve_id ~ '^life\.[a-z][a-z0-9_]*\.v[0-9]+$'::text) AND (char_length(curve_id) <= 80))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_progression_thresholds_level_check' and conrelid = 'private.world_life_progression_thresholds'::regclass) then alter table private.world_life_progression_thresholds add constraint world_life_progression_thresholds_level_check check ((level >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_progression_thresholds_min_total_skill_xp_check' and conrelid = 'private.world_life_progression_thresholds'::regclass) then alter table private.world_life_progression_thresholds add constraint world_life_progression_thresholds_min_total_skill_xp_check check ((min_total_skill_xp >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_progression_thresholds_pkey' and conrelid = 'private.world_life_progression_thresholds'::regclass) then alter table private.world_life_progression_thresholds add constraint world_life_progression_thresholds_pkey primary key (curve_id, level); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_catalog_curve_id_check' and conrelid = 'private.world_life_skill_catalog'::regclass) then alter table private.world_life_skill_catalog add constraint world_life_skill_catalog_curve_id_check check (((curve_id ~ '^life\.[a-z][a-z0-9_]*\.v[0-9]+$'::text) AND (char_length(curve_id) <= 80))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_catalog_pkey' and conrelid = 'private.world_life_skill_catalog'::regclass) then alter table private.world_life_skill_catalog add constraint world_life_skill_catalog_pkey primary key (skill_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_catalog_skill_id_check' and conrelid = 'private.world_life_skill_catalog'::regclass) then alter table private.world_life_skill_catalog add constraint world_life_skill_catalog_skill_id_check check (((skill_id ~ '^life\.[a-z][a-z0-9_]*$'::text) AND (char_length(skill_id) <= 80))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_catalog_status_check' and conrelid = 'private.world_life_skill_catalog'::regclass) then alter table private.world_life_skill_catalog add constraint world_life_skill_catalog_status_check check ((status = ANY (ARRAY['ACTIVE'::text, 'COMING_SOON'::text, 'DISABLED'::text, 'HIDDEN'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_thresholds_cumulative_sp_check' and conrelid = 'private.world_life_skill_thresholds'::regclass) then alter table private.world_life_skill_thresholds add constraint world_life_skill_thresholds_cumulative_sp_check check ((cumulative_sp >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_thresholds_curve_id_check' and conrelid = 'private.world_life_skill_thresholds'::regclass) then alter table private.world_life_skill_thresholds add constraint world_life_skill_thresholds_curve_id_check check (((curve_id ~ '^life\.[a-z][a-z0-9_]*\.v[0-9]+$'::text) AND (char_length(curve_id) <= 80))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_thresholds_level_check' and conrelid = 'private.world_life_skill_thresholds'::regclass) then alter table private.world_life_skill_thresholds add constraint world_life_skill_thresholds_level_check check ((level >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_thresholds_min_total_xp_check' and conrelid = 'private.world_life_skill_thresholds'::regclass) then alter table private.world_life_skill_thresholds add constraint world_life_skill_thresholds_min_total_xp_check check ((min_total_xp >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_thresholds_pkey' and conrelid = 'private.world_life_skill_thresholds'::regclass) then alter table private.world_life_skill_thresholds add constraint world_life_skill_thresholds_pkey primary key (curve_id, level); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_tree_catalog_max_rank_check' and conrelid = 'private.world_life_skill_tree_catalog'::regclass) then alter table private.world_life_skill_tree_catalog add constraint world_life_skill_tree_catalog_max_rank_check check (((max_rank >= 1) AND (max_rank <= 10))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_tree_catalog_node_id_check' and conrelid = 'private.world_life_skill_tree_catalog'::regclass) then alter table private.world_life_skill_tree_catalog add constraint world_life_skill_tree_catalog_node_id_check check (((node_id ~ '^life\.node\.[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'::text) AND (char_length(node_id) <= 120))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_tree_catalog_node_skill_key' and conrelid = 'private.world_life_skill_tree_catalog'::regclass) then alter table private.world_life_skill_tree_catalog add constraint world_life_skill_tree_catalog_node_skill_key unique (node_id, skill_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_tree_catalog_pkey' and conrelid = 'private.world_life_skill_tree_catalog'::regclass) then alter table private.world_life_skill_tree_catalog add constraint world_life_skill_tree_catalog_pkey primary key (node_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_tree_catalog_required_life_level_check' and conrelid = 'private.world_life_skill_tree_catalog'::regclass) then alter table private.world_life_skill_tree_catalog add constraint world_life_skill_tree_catalog_required_life_level_check check ((required_life_level >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_tree_catalog_required_skill_level_check' and conrelid = 'private.world_life_skill_tree_catalog'::regclass) then alter table private.world_life_skill_tree_catalog add constraint world_life_skill_tree_catalog_required_skill_level_check check ((required_skill_level >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_tree_catalog_skill_id_fkey' and conrelid = 'private.world_life_skill_tree_catalog'::regclass) then alter table private.world_life_skill_tree_catalog add constraint world_life_skill_tree_catalog_skill_id_fkey foreign key (skill_id) REFERENCES private.world_life_skill_catalog(skill_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_tree_catalog_sp_cost_check' and conrelid = 'private.world_life_skill_tree_catalog'::regclass) then alter table private.world_life_skill_tree_catalog add constraint world_life_skill_tree_catalog_sp_cost_check check (((sp_cost >= 1) AND (sp_cost <= 99))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_tree_catalog_status_check' and conrelid = 'private.world_life_skill_tree_catalog'::regclass) then alter table private.world_life_skill_tree_catalog add constraint world_life_skill_tree_catalog_status_check check ((status = ANY (ARRAY['ACTIVE'::text, 'COMING_SOON'::text, 'DISABLED'::text, 'HIDDEN'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_tree_edges_check' and conrelid = 'private.world_life_skill_tree_edges'::regclass) then alter table private.world_life_skill_tree_edges add constraint world_life_skill_tree_edges_check check ((node_id <> prerequisite_node_id)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_tree_edges_node_id_fkey' and conrelid = 'private.world_life_skill_tree_edges'::regclass) then alter table private.world_life_skill_tree_edges add constraint world_life_skill_tree_edges_node_id_fkey foreign key (node_id) REFERENCES private.world_life_skill_tree_catalog(node_id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_tree_edges_pkey' and conrelid = 'private.world_life_skill_tree_edges'::regclass) then alter table private.world_life_skill_tree_edges add constraint world_life_skill_tree_edges_pkey primary key (node_id, prerequisite_node_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_tree_edges_prerequisite_node_id_fkey' and conrelid = 'private.world_life_skill_tree_edges'::regclass) then alter table private.world_life_skill_tree_edges add constraint world_life_skill_tree_edges_prerequisite_node_id_fkey foreign key (prerequisite_node_id) REFERENCES private.world_life_skill_tree_catalog(node_id) ON DELETE RESTRICT; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_tree_edges_required_rank_check' and conrelid = 'private.world_life_skill_tree_edges'::regclass) then alter table private.world_life_skill_tree_edges add constraint world_life_skill_tree_edges_required_rank_check check ((required_rank >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_sp_transactions_epoch_check' and conrelid = 'private.world_life_sp_transactions'::regclass) then alter table private.world_life_sp_transactions add constraint world_life_sp_transactions_epoch_check check ((epoch >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_sp_transactions_idempotency_key_check' and conrelid = 'private.world_life_sp_transactions'::regclass) then alter table private.world_life_sp_transactions add constraint world_life_sp_transactions_idempotency_key_check check ((idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_sp_transactions_idempotency_key_key' and conrelid = 'private.world_life_sp_transactions'::regclass) then alter table private.world_life_sp_transactions add constraint world_life_sp_transactions_idempotency_key_key unique (idempotency_key); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_sp_transactions_math' and conrelid = 'private.world_life_sp_transactions'::regclass) then alter table private.world_life_sp_transactions add constraint world_life_sp_transactions_math check ((sp_after = (sp_before - sp_cost))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_sp_transactions_node_id_fkey' and conrelid = 'private.world_life_sp_transactions'::regclass) then alter table private.world_life_sp_transactions add constraint world_life_sp_transactions_node_id_fkey foreign key (node_id) REFERENCES private.world_life_skill_tree_catalog(node_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_sp_transactions_node_skill_fk' and conrelid = 'private.world_life_sp_transactions'::regclass) then alter table private.world_life_sp_transactions add constraint world_life_sp_transactions_node_skill_fk foreign key (node_id, skill_id) REFERENCES private.world_life_skill_tree_catalog(node_id, skill_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_sp_transactions_pkey' and conrelid = 'private.world_life_sp_transactions'::regclass) then alter table private.world_life_sp_transactions add constraint world_life_sp_transactions_pkey primary key (transaction_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_sp_transactions_rank_check' and conrelid = 'private.world_life_sp_transactions'::regclass) then alter table private.world_life_sp_transactions add constraint world_life_sp_transactions_rank_check check ((rank >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_sp_transactions_sp_after_check' and conrelid = 'private.world_life_sp_transactions'::regclass) then alter table private.world_life_sp_transactions add constraint world_life_sp_transactions_sp_after_check check ((sp_after >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_sp_transactions_sp_before_check' and conrelid = 'private.world_life_sp_transactions'::regclass) then alter table private.world_life_sp_transactions add constraint world_life_sp_transactions_sp_before_check check ((sp_before >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_sp_transactions_sp_cost_check' and conrelid = 'private.world_life_sp_transactions'::regclass) then alter table private.world_life_sp_transactions add constraint world_life_sp_transactions_sp_cost_check check ((sp_cost > 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_tree_reset_policy_cooldown_seconds_check' and conrelid = 'private.world_life_tree_reset_policy'::regclass) then alter table private.world_life_tree_reset_policy add constraint world_life_tree_reset_policy_cooldown_seconds_check check (((cooldown_seconds >= 0) AND (cooldown_seconds <= 31536000))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_tree_reset_policy_pkey' and conrelid = 'private.world_life_tree_reset_policy'::regclass) then alter table private.world_life_tree_reset_policy add constraint world_life_tree_reset_policy_pkey primary key (policy_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_tree_reset_policy_policy_id_check' and conrelid = 'private.world_life_tree_reset_policy'::regclass) then alter table private.world_life_tree_reset_policy add constraint world_life_tree_reset_policy_policy_id_check check ((policy_id = 'life.tree_reset.v1'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_tree_resets_cleared_ranks_check' and conrelid = 'private.world_life_tree_resets'::regclass) then alter table private.world_life_tree_resets add constraint world_life_tree_resets_cleared_ranks_check check ((jsonb_typeof(cleared_ranks) = 'array'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_tree_resets_cooldown_seconds_check' and conrelid = 'private.world_life_tree_resets'::regclass) then alter table private.world_life_tree_resets add constraint world_life_tree_resets_cooldown_seconds_check check ((cooldown_seconds >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_tree_resets_epoch_check' and conrelid = 'private.world_life_tree_resets'::regclass) then alter table private.world_life_tree_resets add constraint world_life_tree_resets_epoch_check check ((epoch >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_tree_resets_epoch_key' and conrelid = 'private.world_life_tree_resets'::regclass) then alter table private.world_life_tree_resets add constraint world_life_tree_resets_epoch_key unique (user_id, skill_id, epoch); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_tree_resets_idempotency_key_check' and conrelid = 'private.world_life_tree_resets'::regclass) then alter table private.world_life_tree_resets add constraint world_life_tree_resets_idempotency_key_check check ((idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_tree_resets_idempotency_key_key' and conrelid = 'private.world_life_tree_resets'::regclass) then alter table private.world_life_tree_resets add constraint world_life_tree_resets_idempotency_key_key unique (idempotency_key); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_tree_resets_pkey' and conrelid = 'private.world_life_tree_resets'::regclass) then alter table private.world_life_tree_resets add constraint world_life_tree_resets_pkey primary key (reset_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_tree_resets_refunded_sp_check' and conrelid = 'private.world_life_tree_resets'::regclass) then alter table private.world_life_tree_resets add constraint world_life_tree_resets_refunded_sp_check check ((refunded_sp > 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_tree_resets_skill_id_fkey' and conrelid = 'private.world_life_tree_resets'::regclass) then alter table private.world_life_tree_resets add constraint world_life_tree_resets_skill_id_fkey foreign key (skill_id) REFERENCES private.world_life_skill_catalog(skill_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_mcm_reward_claims_claim_type_check' and conrelid = 'private.world_mcm_reward_claims'::regclass) then alter table private.world_mcm_reward_claims add constraint world_mcm_reward_claims_claim_type_check check ((claim_type = ANY (ARRAY['MAIN_CLEAR'::text, 'LANDLORD_FIRST_CLEAR'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_mcm_reward_claims_event_id_fkey' and conrelid = 'private.world_mcm_reward_claims'::regclass) then alter table private.world_mcm_reward_claims add constraint world_mcm_reward_claims_event_id_fkey foreign key (event_id) REFERENCES private.world_events(event_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_mcm_reward_claims_idempotency_key_key' and conrelid = 'private.world_mcm_reward_claims'::regclass) then alter table private.world_mcm_reward_claims add constraint world_mcm_reward_claims_idempotency_key_key unique (idempotency_key); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_mcm_reward_claims_pkey' and conrelid = 'private.world_mcm_reward_claims'::regclass) then alter table private.world_mcm_reward_claims add constraint world_mcm_reward_claims_pkey primary key (user_id, claim_type); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_mcm_reward_claims_reward_id_fkey' and conrelid = 'private.world_mcm_reward_claims'::regclass) then alter table private.world_mcm_reward_claims add constraint world_mcm_reward_claims_reward_id_fkey foreign key (reward_id) REFERENCES private.world_reward_definitions(reward_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_mcm_reward_claims_reward_status_check' and conrelid = 'private.world_mcm_reward_claims'::regclass) then alter table private.world_mcm_reward_claims add constraint world_mcm_reward_claims_reward_status_check check ((reward_status = ANY (ARRAY['SUCCESS'::text, 'PARTIAL_SUCCESS'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_mcm_reward_claims_reward_transaction_id_fkey' and conrelid = 'private.world_mcm_reward_claims'::regclass) then alter table private.world_mcm_reward_claims add constraint world_mcm_reward_claims_reward_transaction_id_fkey foreign key (reward_transaction_id) REFERENCES private.world_reward_transactions(reward_transaction_id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_mcm_reward_claims_reward_transaction_key' and conrelid = 'private.world_mcm_reward_claims'::regclass) then alter table private.world_mcm_reward_claims add constraint world_mcm_reward_claims_reward_transaction_key unique (reward_transaction_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_appearance_loadout_item_id_check' and conrelid = 'private.world_player_appearance_loadout'::regclass) then alter table private.world_player_appearance_loadout add constraint world_player_appearance_loadout_item_id_check check (((item_id ~ '^[a-z][a-z0-9_]*\.[a-z0-9_]+$'::text) AND (char_length(item_id) <= 80))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_appearance_loadout_owned' and conrelid = 'private.world_player_appearance_loadout'::regclass) then alter table private.world_player_appearance_loadout add constraint world_player_appearance_loadout_owned foreign key (user_id, item_id) REFERENCES private.world_player_items(user_id, item_id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_appearance_loadout_pkey' and conrelid = 'private.world_player_appearance_loadout'::regclass) then alter table private.world_player_appearance_loadout add constraint world_player_appearance_loadout_pkey primary key (user_id, slot); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_appearance_loadout_slot_check' and conrelid = 'private.world_player_appearance_loadout'::regclass) then alter table private.world_player_appearance_loadout add constraint world_player_appearance_loadout_slot_check check ((slot = ANY (ARRAY['BODY'::text, 'FACE'::text, 'HAIR'::text, 'HEAD'::text, 'TOP'::text, 'BOTTOM'::text, 'SHOES'::text, 'BACK'::text, 'ACCESSORY'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_appearance_loadout_slot_prefix' and conrelid = 'private.world_player_appearance_loadout'::regclass) then alter table private.world_player_appearance_loadout add constraint world_player_appearance_loadout_slot_prefix check ((slot = upper(split_part(item_id, '.'::text, 1)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_biryong_relationship_stage3_time' and conrelid = 'private.world_player_biryong_npc_relationships'::regclass) then alter table private.world_player_biryong_npc_relationships add constraint world_biryong_relationship_stage3_time check ((((stage = 2) AND (stage3_unlocked_at IS NULL)) OR ((stage = 3) AND (stage3_unlocked_at IS NOT NULL) AND (stage3_unlocked_at >= stage2_unlocked_at)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_biryong_npc_relationships_npc_id_fkey' and conrelid = 'private.world_player_biryong_npc_relationships'::regclass) then alter table private.world_player_biryong_npc_relationships add constraint world_player_biryong_npc_relationships_npc_id_fkey foreign key (npc_id) REFERENCES private.world_biryong_npc_relationship_npc_catalog(npc_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_biryong_npc_relationships_pkey' and conrelid = 'private.world_player_biryong_npc_relationships'::regclass) then alter table private.world_player_biryong_npc_relationships add constraint world_player_biryong_npc_relationships_pkey primary key (user_id, npc_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_biryong_npc_relationships_revision_check' and conrelid = 'private.world_player_biryong_npc_relationships'::regclass) then alter table private.world_player_biryong_npc_relationships add constraint world_player_biryong_npc_relationships_revision_check check ((revision >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_biryong_npc_relationships_stage_check' and conrelid = 'private.world_player_biryong_npc_relationships'::regclass) then alter table private.world_player_biryong_npc_relationships add constraint world_player_biryong_npc_relationships_stage_check check (((stage >= 2) AND (stage <= 3))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_campus_npc_relationship_time_order' and conrelid = 'private.world_player_campus_npc_relationships'::regclass) then alter table private.world_player_campus_npc_relationships add constraint world_campus_npc_relationship_time_order check (((last_interaction_at >= first_interaction_at) AND ((last_meaningful_at IS NULL) OR (last_meaningful_at >= first_interaction_at)) AND (updated_at >= first_interaction_at))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_campus_npc_rela_meaningful_interaction_count_check' and conrelid = 'private.world_player_campus_npc_relationships'::regclass) then alter table private.world_player_campus_npc_relationships add constraint world_player_campus_npc_rela_meaningful_interaction_count_check check ((meaningful_interaction_count >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_campus_npc_relationships_affinity_check' and conrelid = 'private.world_player_campus_npc_relationships'::regclass) then alter table private.world_player_campus_npc_relationships add constraint world_player_campus_npc_relationships_affinity_check check (((affinity >= 0) AND (affinity <= 100))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_campus_npc_relationships_encounter_count_check' and conrelid = 'private.world_player_campus_npc_relationships'::regclass) then alter table private.world_player_campus_npc_relationships add constraint world_player_campus_npc_relationships_encounter_count_check check ((encounter_count >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_campus_npc_relationships_npc_id_fkey' and conrelid = 'private.world_player_campus_npc_relationships'::regclass) then alter table private.world_player_campus_npc_relationships add constraint world_player_campus_npc_relationships_npc_id_fkey foreign key (npc_id) REFERENCES private.world_campus_npc_relationship_npc_catalog(npc_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_campus_npc_relationships_pkey' and conrelid = 'private.world_player_campus_npc_relationships'::regclass) then alter table private.world_player_campus_npc_relationships add constraint world_player_campus_npc_relationships_pkey primary key (user_id, npc_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_campus_npc_relationships_revision_check' and conrelid = 'private.world_player_campus_npc_relationships'::regclass) then alter table private.world_player_campus_npc_relationships add constraint world_player_campus_npc_relationships_revision_check check ((revision >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_items_grant_id_fkey' and conrelid = 'private.world_player_items'::regclass) then alter table private.world_player_items add constraint world_player_items_grant_id_fkey foreign key (grant_id) REFERENCES private.world_item_grants(grant_id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_items_item_id_check' and conrelid = 'private.world_player_items'::regclass) then alter table private.world_player_items add constraint world_player_items_item_id_check check ((item_id ~ '^[a-z][a-z0-9_]*\.[a-z0-9_]+$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_items_pkey' and conrelid = 'private.world_player_items'::regclass) then alter table private.world_player_items add constraint world_player_items_pkey primary key (id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_items_quantity_check' and conrelid = 'private.world_player_items'::regclass) then alter table private.world_player_items add constraint world_player_items_quantity_check check ((quantity >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_items_user_item_key' and conrelid = 'private.world_player_items'::regclass) then alter table private.world_player_items add constraint world_player_items_user_item_key unique (user_id, item_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_life_nodes_epoch_check' and conrelid = 'private.world_player_life_nodes'::regclass) then alter table private.world_player_life_nodes add constraint world_player_life_nodes_epoch_check check ((epoch >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_life_nodes_node_id_fkey' and conrelid = 'private.world_player_life_nodes'::regclass) then alter table private.world_player_life_nodes add constraint world_player_life_nodes_node_id_fkey foreign key (node_id) REFERENCES private.world_life_skill_tree_catalog(node_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_life_nodes_pkey' and conrelid = 'private.world_player_life_nodes'::regclass) then alter table private.world_player_life_nodes add constraint world_player_life_nodes_pkey primary key (user_id, node_id, epoch, rank); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_life_nodes_rank_check' and conrelid = 'private.world_player_life_nodes'::regclass) then alter table private.world_player_life_nodes add constraint world_player_life_nodes_rank_check check ((rank >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_life_nodes_transaction_id_fkey' and conrelid = 'private.world_player_life_nodes'::regclass) then alter table private.world_player_life_nodes add constraint world_player_life_nodes_transaction_id_fkey foreign key (transaction_id) REFERENCES private.world_life_sp_transactions(transaction_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_life_nodes_transaction_id_key' and conrelid = 'private.world_player_life_nodes'::regclass) then alter table private.world_player_life_nodes add constraint world_player_life_nodes_transaction_id_key unique (transaction_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_life_skills_pkey' and conrelid = 'private.world_player_life_skills'::regclass) then alter table private.world_player_life_skills add constraint world_player_life_skills_pkey primary key (user_id, skill_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_life_skills_skill_id_check' and conrelid = 'private.world_player_life_skills'::regclass) then alter table private.world_player_life_skills add constraint world_player_life_skills_skill_id_check check (((skill_id ~ '^life\.[a-z][a-z0-9_]*$'::text) AND (char_length(skill_id) <= 80))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_life_skills_total_xp_check' and conrelid = 'private.world_player_life_skills'::regclass) then alter table private.world_player_life_skills add constraint world_player_life_skills_total_xp_check check ((total_xp >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_life_skills_version_check' and conrelid = 'private.world_player_life_skills'::regclass) then alter table private.world_player_life_skills add constraint world_player_life_skills_version_check check ((version >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_progression_pkey' and conrelid = 'private.world_player_progression'::regclass) then alter table private.world_player_progression add constraint world_player_progression_pkey primary key (user_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_progression_total_exp_check' and conrelid = 'private.world_player_progression'::regclass) then alter table private.world_player_progression add constraint world_player_progression_total_exp_check check ((total_exp >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_progression_version_check' and conrelid = 'private.world_player_progression'::regclass) then alter table private.world_player_progression add constraint world_player_progression_version_check check ((version >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_purchase_transactions_balance_after_check' and conrelid = 'private.world_purchase_transactions'::regclass) then alter table private.world_purchase_transactions add constraint world_purchase_transactions_balance_after_check check ((balance_after >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_purchase_transactions_balance_before_check' and conrelid = 'private.world_purchase_transactions'::regclass) then alter table private.world_purchase_transactions add constraint world_purchase_transactions_balance_before_check check ((balance_before >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_purchase_transactions_idempotency_key_check' and conrelid = 'private.world_purchase_transactions'::regclass) then alter table private.world_purchase_transactions add constraint world_purchase_transactions_idempotency_key_check check ((idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,119}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_purchase_transactions_idempotency_key_key' and conrelid = 'private.world_purchase_transactions'::regclass) then alter table private.world_purchase_transactions add constraint world_purchase_transactions_idempotency_key_key unique (idempotency_key); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_purchase_transactions_pkey' and conrelid = 'private.world_purchase_transactions'::regclass) then alter table private.world_purchase_transactions add constraint world_purchase_transactions_pkey primary key (purchase_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_purchase_transactions_price_check' and conrelid = 'private.world_purchase_transactions'::regclass) then alter table private.world_purchase_transactions add constraint world_purchase_transactions_price_check check ((price > 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_purchase_transactions_price_math' and conrelid = 'private.world_purchase_transactions'::regclass) then alter table private.world_purchase_transactions add constraint world_purchase_transactions_price_math check ((balance_after = (balance_before - price))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_purchase_transactions_quantity_check' and conrelid = 'private.world_purchase_transactions'::regclass) then alter table private.world_purchase_transactions add constraint world_purchase_transactions_quantity_check check ((quantity >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_purchase_transactions_status_check' and conrelid = 'private.world_purchase_transactions'::regclass) then alter table private.world_purchase_transactions add constraint world_purchase_transactions_status_check check ((status = 'COMPLETED'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_recipe_catalog_definition_version_check' and conrelid = 'private.world_recipe_catalog'::regclass) then alter table private.world_recipe_catalog add constraint world_recipe_catalog_definition_version_check check ((definition_version > 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_recipe_catalog_mutation_type_check' and conrelid = 'private.world_recipe_catalog'::regclass) then alter table private.world_recipe_catalog add constraint world_recipe_catalog_mutation_type_check check ((mutation_type = ANY (ARRAY['COOK'::text, 'CRAFT'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_recipe_catalog_pkey' and conrelid = 'private.world_recipe_catalog'::regclass) then alter table private.world_recipe_catalog add constraint world_recipe_catalog_pkey primary key (recipe_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_recipe_catalog_plan_check' and conrelid = 'private.world_recipe_catalog'::regclass) then alter table private.world_recipe_catalog add constraint world_recipe_catalog_plan_check check ((jsonb_typeof(plan) = 'object'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_recipe_catalog_recipe_id_check' and conrelid = 'private.world_recipe_catalog'::regclass) then alter table private.world_recipe_catalog add constraint world_recipe_catalog_recipe_id_check check ((recipe_id ~ '^recipe\.[a-z0-9_]+$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_recipe_catalog_required_capability_check' and conrelid = 'private.world_recipe_catalog'::regclass) then alter table private.world_recipe_catalog add constraint world_recipe_catalog_required_capability_check check ((required_capability = ANY (ARRAY['COOKING_STATION'::text, 'WORKBENCH'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_recipe_catalog_required_item_id_fkey' and conrelid = 'private.world_recipe_catalog'::regclass) then alter table private.world_recipe_catalog add constraint world_recipe_catalog_required_item_id_fkey foreign key (required_item_id) REFERENCES private.world_item_catalog(item_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_recipe_catalog_status_check' and conrelid = 'private.world_recipe_catalog'::regclass) then alter table private.world_recipe_catalog add constraint world_recipe_catalog_status_check check ((status = ANY (ARRAY['COMING_SOON'::text, 'ACTIVE'::text, 'DISABLED'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_recipe_receipts_pkey' and conrelid = 'private.world_recipe_receipts'::regclass) then alter table private.world_recipe_receipts add constraint world_recipe_receipts_pkey primary key (user_id, request_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_recipe_receipts_receipt_check' and conrelid = 'private.world_recipe_receipts'::regclass) then alter table private.world_recipe_receipts add constraint world_recipe_receipts_receipt_check check ((jsonb_typeof(receipt) = 'object'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_definitions_description_check' and conrelid = 'private.world_reward_definitions'::regclass) then alter table private.world_reward_definitions add constraint world_reward_definitions_description_check check (((char_length(description) >= 1) AND (char_length(description) <= 200))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_definitions_event_id_check' and conrelid = 'private.world_reward_definitions'::regclass) then alter table private.world_reward_definitions add constraint world_reward_definitions_event_id_check check (((event_id IS NULL) OR (event_id ~ '^[a-z][a-z0-9_]*\.[a-z0-9_]+$'::text))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_definitions_pkey' and conrelid = 'private.world_reward_definitions'::regclass) then alter table private.world_reward_definitions add constraint world_reward_definitions_pkey primary key (reward_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_definitions_reward_id_check' and conrelid = 'private.world_reward_definitions'::regclass) then alter table private.world_reward_definitions add constraint world_reward_definitions_reward_id_check check (((reward_id ~ '^reward\.[a-z][a-z0-9_]*\.[a-z0-9_]+$'::text) AND (char_length(reward_id) <= 80))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_definitions_status_check' and conrelid = 'private.world_reward_definitions'::regclass) then alter table private.world_reward_definitions add constraint world_reward_definitions_status_check check ((status = ANY (ARRAY['ACTIVE'::text, 'DISABLED'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_definitions_version_check' and conrelid = 'private.world_reward_definitions'::regclass) then alter table private.world_reward_definitions add constraint world_reward_definitions_version_check check ((version >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_grants_amount_check' and conrelid = 'private.world_reward_grants'::regclass) then alter table private.world_reward_grants add constraint world_reward_grants_amount_check check ((amount >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_grants_grant_entry_id_check' and conrelid = 'private.world_reward_grants'::regclass) then alter table private.world_reward_grants add constraint world_reward_grants_grant_entry_id_check check (((grant_entry_id ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){0,3}$'::text) AND (char_length(grant_entry_id) <= 60))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_grants_grant_type_check' and conrelid = 'private.world_reward_grants'::regclass) then alter table private.world_reward_grants add constraint world_reward_grants_grant_type_check check ((grant_type = ANY (ARRAY['CURRENCY'::text, 'ITEM'::text, 'EXP'::text, 'COLLECTION'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_grants_pkey' and conrelid = 'private.world_reward_grants'::regclass) then alter table private.world_reward_grants add constraint world_reward_grants_pkey primary key (reward_id, grant_entry_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_grants_position_check' and conrelid = 'private.world_reward_grants'::regclass) then alter table private.world_reward_grants add constraint world_reward_grants_position_check check (("position" >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_grants_position_key' and conrelid = 'private.world_reward_grants'::regclass) then alter table private.world_reward_grants add constraint world_reward_grants_position_key unique (reward_id, "position"); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_grants_reward_id_fkey' and conrelid = 'private.world_reward_grants'::regclass) then alter table private.world_reward_grants add constraint world_reward_grants_reward_id_fkey foreign key (reward_id) REFERENCES private.world_reward_definitions(reward_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_grants_target_id_check' and conrelid = 'private.world_reward_grants'::regclass) then alter table private.world_reward_grants add constraint world_reward_grants_target_id_check check (((char_length(target_id) >= 1) AND (char_length(target_id) <= 80))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_grants_target_key' and conrelid = 'private.world_reward_grants'::regclass) then alter table private.world_reward_grants add constraint world_reward_grants_target_key unique (reward_id, grant_type, target_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_entries_result' and conrelid = 'private.world_reward_transaction_entries'::regclass) then alter table private.world_reward_transaction_entries add constraint world_reward_entries_result check ((((status = 'GRANTED'::text) AND (granted = requested) AND (child_transaction_id IS NOT NULL)) OR ((status = ANY (ARRAY['SKIPPED'::text, 'FAILED'::text])) AND (granted = 0) AND (reason IS NOT NULL)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_transaction_entries_attempts_check' and conrelid = 'private.world_reward_transaction_entries'::regclass) then alter table private.world_reward_transaction_entries add constraint world_reward_transaction_entries_attempts_check check ((attempts >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_transaction_entries_grant_type_check' and conrelid = 'private.world_reward_transaction_entries'::regclass) then alter table private.world_reward_transaction_entries add constraint world_reward_transaction_entries_grant_type_check check ((grant_type = ANY (ARRAY['CURRENCY'::text, 'ITEM'::text, 'EXP'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_transaction_entries_granted_check' and conrelid = 'private.world_reward_transaction_entries'::regclass) then alter table private.world_reward_transaction_entries add constraint world_reward_transaction_entries_granted_check check ((granted >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_transaction_entries_pkey' and conrelid = 'private.world_reward_transaction_entries'::regclass) then alter table private.world_reward_transaction_entries add constraint world_reward_transaction_entries_pkey primary key (reward_transaction_id, grant_entry_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_transaction_entries_reason_check' and conrelid = 'private.world_reward_transaction_entries'::regclass) then alter table private.world_reward_transaction_entries add constraint world_reward_transaction_entries_reason_check check (((reason IS NULL) OR (char_length(reason) <= 200))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_transaction_entries_requested_check' and conrelid = 'private.world_reward_transaction_entries'::regclass) then alter table private.world_reward_transaction_entries add constraint world_reward_transaction_entries_requested_check check ((requested >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_transaction_entries_reward_transaction_id_fkey' and conrelid = 'private.world_reward_transaction_entries'::regclass) then alter table private.world_reward_transaction_entries add constraint world_reward_transaction_entries_reward_transaction_id_fkey foreign key (reward_transaction_id) REFERENCES private.world_reward_transactions(reward_transaction_id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_transaction_entries_status_check' and conrelid = 'private.world_reward_transaction_entries'::regclass) then alter table private.world_reward_transaction_entries add constraint world_reward_transaction_entries_status_check check ((status = ANY (ARRAY['GRANTED'::text, 'SKIPPED'::text, 'FAILED'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_transactions_attempts_check' and conrelid = 'private.world_reward_transactions'::regclass) then alter table private.world_reward_transactions add constraint world_reward_transactions_attempts_check check ((attempts >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_transactions_completion' and conrelid = 'private.world_reward_transactions'::regclass) then alter table private.world_reward_transactions add constraint world_reward_transactions_completion check (((status = 'FAILED'::text) = (completed_at IS NULL))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_transactions_idempotency_key_check' and conrelid = 'private.world_reward_transactions'::regclass) then alter table private.world_reward_transactions add constraint world_reward_transactions_idempotency_key_check check ((idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,119}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_transactions_idempotency_key_key' and conrelid = 'private.world_reward_transactions'::regclass) then alter table private.world_reward_transactions add constraint world_reward_transactions_idempotency_key_key unique (idempotency_key); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_transactions_pkey' and conrelid = 'private.world_reward_transactions'::regclass) then alter table private.world_reward_transactions add constraint world_reward_transactions_pkey primary key (reward_transaction_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_transactions_reward_id_fkey' and conrelid = 'private.world_reward_transactions'::regclass) then alter table private.world_reward_transactions add constraint world_reward_transactions_reward_id_fkey foreign key (reward_id) REFERENCES private.world_reward_definitions(reward_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_transactions_source_id_check' and conrelid = 'private.world_reward_transactions'::regclass) then alter table private.world_reward_transactions add constraint world_reward_transactions_source_id_check check (((char_length(source_id) >= 1) AND (char_length(source_id) <= 200))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_transactions_source_type_check' and conrelid = 'private.world_reward_transactions'::regclass) then alter table private.world_reward_transactions add constraint world_reward_transactions_source_type_check check ((source_type = ANY (ARRAY['QUEST'::text, 'EXPLORATION'::text, 'ACHIEVEMENT'::text, 'EVENT'::text, 'MINIGAME'::text, 'INHAGAME_REWARD'::text, 'SYSTEM'::text, 'ADMIN'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_reward_transactions_status_check' and conrelid = 'private.world_reward_transactions'::regclass) then alter table private.world_reward_transactions add constraint world_reward_transactions_status_check check ((status = ANY (ARRAY['SUCCESS'::text, 'PARTIAL_SUCCESS'::text, 'FAILED'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_room_knocks_check' and conrelid = 'private.world_room_knocks'::regclass) then alter table private.world_room_knocks add constraint world_room_knocks_check check ((expires_at > created_at)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_room_knocks_check1' and conrelid = 'private.world_room_knocks'::regclass) then alter table private.world_room_knocks add constraint world_room_knocks_check1 check ((((status = 'PENDING'::text) = (responded_at IS NULL)) OR (status = 'EXPIRED'::text))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_room_knocks_pkey' and conrelid = 'private.world_room_knocks'::regclass) then alter table private.world_room_knocks add constraint world_room_knocks_pkey primary key (id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_room_knocks_room_id_fkey' and conrelid = 'private.world_room_knocks'::regclass) then alter table private.world_room_knocks add constraint world_room_knocks_room_id_fkey foreign key (room_id) REFERENCES world_player_rooms(id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_room_knocks_status_check' and conrelid = 'private.world_room_knocks'::regclass) then alter table private.world_room_knocks add constraint world_room_knocks_status_check check ((status = ANY (ARRAY['PENDING'::text, 'ACCEPTED'::text, 'DECLINED'::text, 'EXPIRED'::text, 'OPEN'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_room_layouts_objects_check' and conrelid = 'private.world_room_layouts'::regclass) then alter table private.world_room_layouts add constraint world_room_layouts_objects_check check (((jsonb_typeof(objects) = 'array'::text) AND (jsonb_array_length(objects) <= 32))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_room_layouts_pkey' and conrelid = 'private.world_room_layouts'::regclass) then alter table private.world_room_layouts add constraint world_room_layouts_pkey primary key (room_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_room_layouts_revision_check' and conrelid = 'private.world_room_layouts'::regclass) then alter table private.world_room_layouts add constraint world_room_layouts_revision_check check ((revision >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_room_layouts_room_id_fkey' and conrelid = 'private.world_room_layouts'::regclass) then alter table private.world_room_layouts add constraint world_room_layouts_room_id_fkey foreign key (room_id) REFERENCES world_player_rooms(id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_room_owner_presence_pkey' and conrelid = 'private.world_room_owner_presence'::regclass) then alter table private.world_room_owner_presence add constraint world_room_owner_presence_pkey primary key (room_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_room_owner_presence_room_id_fkey' and conrelid = 'private.world_room_owner_presence'::regclass) then alter table private.world_room_owner_presence add constraint world_room_owner_presence_room_id_fkey foreign key (room_id) REFERENCES world_player_rooms(id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_shop_listings_currency_id_fkey' and conrelid = 'private.world_shop_listings'::regclass) then alter table private.world_shop_listings add constraint world_shop_listings_currency_id_fkey foreign key (currency_id) REFERENCES private.world_currencies(currency_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_shop_listings_item_key' and conrelid = 'private.world_shop_listings'::regclass) then alter table private.world_shop_listings add constraint world_shop_listings_item_key unique (shop_id, item_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_shop_listings_listing_id_check' and conrelid = 'private.world_shop_listings'::regclass) then alter table private.world_shop_listings add constraint world_shop_listings_listing_id_check check (((listing_id ~ '^offer\.[a-z][a-z0-9_]*\.[a-z0-9_]+$'::text) AND (char_length(listing_id) <= 80))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_shop_listings_pkey' and conrelid = 'private.world_shop_listings'::regclass) then alter table private.world_shop_listings add constraint world_shop_listings_pkey primary key (listing_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_shop_listings_position_check' and conrelid = 'private.world_shop_listings'::regclass) then alter table private.world_shop_listings add constraint world_shop_listings_position_check check (("position" >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_shop_listings_position_key' and conrelid = 'private.world_shop_listings'::regclass) then alter table private.world_shop_listings add constraint world_shop_listings_position_key unique (shop_id, "position"); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_shop_listings_price_check' and conrelid = 'private.world_shop_listings'::regclass) then alter table private.world_shop_listings add constraint world_shop_listings_price_check check ((price > 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_shop_listings_purchase_limit_check' and conrelid = 'private.world_shop_listings'::regclass) then alter table private.world_shop_listings add constraint world_shop_listings_purchase_limit_check check (((purchase_limit IS NULL) OR (purchase_limit >= 1))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_shop_listings_quantity_check' and conrelid = 'private.world_shop_listings'::regclass) then alter table private.world_shop_listings add constraint world_shop_listings_quantity_check check ((quantity >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_shop_listings_required_level_check' and conrelid = 'private.world_shop_listings'::regclass) then alter table private.world_shop_listings add constraint world_shop_listings_required_level_check check (((required_level IS NULL) OR (required_level >= 1))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_shop_listings_shop_id_fkey' and conrelid = 'private.world_shop_listings'::regclass) then alter table private.world_shop_listings add constraint world_shop_listings_shop_id_fkey foreign key (shop_id) REFERENCES private.world_shops(shop_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_shop_listings_status_check' and conrelid = 'private.world_shop_listings'::regclass) then alter table private.world_shop_listings add constraint world_shop_listings_status_check check ((status = ANY (ARRAY['ACTIVE'::text, 'LOCKED'::text, 'DISABLED'::text, 'HIDDEN'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_shop_listings_window' and conrelid = 'private.world_shop_listings'::regclass) then alter table private.world_shop_listings add constraint world_shop_listings_window check (((start_at IS NULL) OR (end_at IS NULL) OR (start_at < end_at))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_shops_display_name_check' and conrelid = 'private.world_shops'::regclass) then alter table private.world_shops add constraint world_shops_display_name_check check (((char_length(display_name) >= 1) AND (char_length(display_name) <= 40))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_shops_pkey' and conrelid = 'private.world_shops'::regclass) then alter table private.world_shops add constraint world_shops_pkey primary key (shop_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_shops_shop_id_check' and conrelid = 'private.world_shops'::regclass) then alter table private.world_shops add constraint world_shops_shop_id_check check (((shop_id ~ '^shop\.[a-z][a-z0-9_]*$'::text) AND (char_length(shop_id) <= 60))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_shops_status_check' and conrelid = 'private.world_shops'::regclass) then alter table private.world_shops add constraint world_shops_status_check check ((status = ANY (ARRAY['ACTIVE'::text, 'DISABLED'::text, 'HIDDEN'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_shops_vendor_id_check' and conrelid = 'private.world_shops'::regclass) then alter table private.world_shops add constraint world_shops_vendor_id_check check (((vendor_id IS NULL) OR ((char_length(vendor_id) >= 1) AND (char_length(vendor_id) <= 80)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_staff_assignments_pkey' and conrelid = 'private.world_staff_assignments'::regclass) then alter table private.world_staff_assignments add constraint world_staff_assignments_pkey primary key (user_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_staff_assignments_role_check' and conrelid = 'private.world_staff_assignments'::regclass) then alter table private.world_staff_assignments add constraint world_staff_assignments_role_check check ((role = ANY (ARRAY['world_admin'::text, 'sound_gm'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_user_moderation_action_end_check' and conrelid = 'private.world_user_moderation_actions'::regclass) then alter table private.world_user_moderation_actions add constraint world_user_moderation_action_end_check check ((((action = 'interaction_restriction_24h'::text) AND (ends_at IS NOT NULL) AND (ends_at > starts_at)) OR ((action <> 'interaction_restriction_24h'::text) AND (ends_at IS NULL)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_user_moderation_actions_action_check' and conrelid = 'private.world_user_moderation_actions'::regclass) then alter table private.world_user_moderation_actions add constraint world_user_moderation_actions_action_check check ((action = ANY (ARRAY['reviewing'::text, 'warning'::text, 'interaction_restriction_24h'::text, 'dismissed'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_user_moderation_actions_pkey' and conrelid = 'private.world_user_moderation_actions'::regclass) then alter table private.world_user_moderation_actions add constraint world_user_moderation_actions_pkey primary key (id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_user_moderation_actions_report_id_fkey' and conrelid = 'private.world_user_moderation_actions'::regclass) then alter table private.world_user_moderation_actions add constraint world_user_moderation_actions_report_id_fkey foreign key (report_id) REFERENCES world_user_reports(id) ON DELETE SET NULL; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_user_moderation_actor_source_check' and conrelid = 'private.world_user_moderation_actions'::regclass) then alter table private.world_user_moderation_actions add constraint world_user_moderation_actor_source_check check ((actor_source = ANY (ARRAY['ops_token'::text, 'account_admin'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_wallets_balance_check' and conrelid = 'private.world_wallets'::regclass) then alter table private.world_wallets add constraint world_wallets_balance_check check ((balance >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_wallets_currency_id_fkey' and conrelid = 'private.world_wallets'::regclass) then alter table private.world_wallets add constraint world_wallets_currency_id_fkey foreign key (currency_id) REFERENCES private.world_currencies(currency_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_wallets_pkey' and conrelid = 'private.world_wallets'::regclass) then alter table private.world_wallets add constraint world_wallets_pkey primary key (user_id, currency_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_wallets_version_check' and conrelid = 'private.world_wallets'::regclass) then alter table private.world_wallets add constraint world_wallets_version_check check ((version >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'classic_event_badges_badge_code_check' and conrelid = 'public.classic_event_badges'::regclass) then alter table public.classic_event_badges add constraint classic_event_badges_badge_code_check check ((badge_code ~ '^[a-z0-9_]{3,80}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'classic_event_badges_best_run_id_fkey' and conrelid = 'public.classic_event_badges'::regclass) then alter table public.classic_event_badges add constraint classic_event_badges_best_run_id_fkey foreign key (best_run_id) REFERENCES ranked_runs(id) ON DELETE RESTRICT; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'classic_event_badges_event_key_check' and conrelid = 'public.classic_event_badges'::regclass) then alter table public.classic_event_badges add constraint classic_event_badges_event_key_check check ((event_key ~ '^[a-z0-9_]{3,80}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'classic_event_badges_event_key_placement_key' and conrelid = 'public.classic_event_badges'::regclass) then alter table public.classic_event_badges add constraint classic_event_badges_event_key_placement_key unique (event_key, placement); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'classic_event_badges_final_combo_check' and conrelid = 'public.classic_event_badges'::regclass) then alter table public.classic_event_badges add constraint classic_event_badges_final_combo_check check ((final_combo >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'classic_event_badges_final_score_check' and conrelid = 'public.classic_event_badges'::regclass) then alter table public.classic_event_badges add constraint classic_event_badges_final_score_check check ((final_score >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'classic_event_badges_inha_duck_s1_code_check' and conrelid = 'public.classic_event_badges'::regclass) then alter table public.classic_event_badges add constraint classic_event_badges_inha_duck_s1_code_check check (((event_key <> 'inha_duck_s1'::text) OR ((placement = 1) AND (badge_code = 'inha_duck_s1_gold'::text)) OR ((placement = 2) AND (badge_code = 'inha_duck_s1_silver'::text)) OR ((placement = 3) AND (badge_code = 'inha_duck_s1_bronze'::text)) OR ((placement >= 4) AND (placement <= 10) AND (badge_code = 'inha_duck_s1_top10'::text)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'classic_event_badges_pkey' and conrelid = 'public.classic_event_badges'::regclass) then alter table public.classic_event_badges add constraint classic_event_badges_pkey primary key (event_key, user_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'classic_event_badges_placement_check' and conrelid = 'public.classic_event_badges'::regclass) then alter table public.classic_event_badges add constraint classic_event_badges_placement_check check (((placement >= 1) AND (placement <= 10))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'departments_name_key' and conrelid = 'public.departments'::regclass) then alter table public.departments add constraint departments_name_key unique (name); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'departments_name_len' and conrelid = 'public.departments'::regclass) then alter table public.departments add constraint departments_name_len check (((char_length(name) >= 1) AND (char_length(name) <= 80))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'departments_pkey' and conrelid = 'public.departments'::regclass) then alter table public.departments add constraint departments_pkey primary key (id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'game_builds_game_id_fkey' and conrelid = 'public.game_builds'::regclass) then alter table public.game_builds add constraint game_builds_game_id_fkey foreign key (game_id) REFERENCES games(id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'game_builds_game_id_version_key' and conrelid = 'public.game_builds'::regclass) then alter table public.game_builds add constraint game_builds_game_id_version_key unique (game_id, version); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'game_builds_pkey' and conrelid = 'public.game_builds'::regclass) then alter table public.game_builds add constraint game_builds_pkey primary key (id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'game_events_build_id_fkey' and conrelid = 'public.game_events'::regclass) then alter table public.game_events add constraint game_events_build_id_fkey foreign key (build_id) REFERENCES game_builds(id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'game_events_event_type_check' and conrelid = 'public.game_events'::regclass) then alter table public.game_events add constraint game_events_event_type_check check (((char_length(event_type) >= 1) AND (char_length(event_type) <= 64))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'game_events_game_id_fkey' and conrelid = 'public.game_events'::regclass) then alter table public.game_events add constraint game_events_game_id_fkey foreign key (game_id) REFERENCES games(id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'game_events_game_session_id_fkey' and conrelid = 'public.game_events'::regclass) then alter table public.game_events add constraint game_events_game_session_id_fkey foreign key (game_session_id) REFERENCES game_sessions(id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'game_events_pkey' and conrelid = 'public.game_events'::regclass) then alter table public.game_events add constraint game_events_pkey primary key (id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'game_events_player_id_fkey' and conrelid = 'public.game_events'::regclass) then alter table public.game_events add constraint game_events_player_id_fkey foreign key (player_id) REFERENCES players(id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'game_events_stage_id_check' and conrelid = 'public.game_events'::regclass) then alter table public.game_events add constraint game_events_stage_id_check check (((stage_id IS NULL) OR ((stage_id >= 1) AND (stage_id <= 4)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'game_events_stars_check' and conrelid = 'public.game_events'::regclass) then alter table public.game_events add constraint game_events_stars_check check (((stars IS NULL) OR ((stars >= 0) AND (stars <= 3)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'game_sessions_build_id_fkey' and conrelid = 'public.game_sessions'::regclass) then alter table public.game_sessions add constraint game_sessions_build_id_fkey foreign key (build_id) REFERENCES game_builds(id) ON DELETE SET NULL; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'game_sessions_game_id_client_session_id_key' and conrelid = 'public.game_sessions'::regclass) then alter table public.game_sessions add constraint game_sessions_game_id_client_session_id_key unique (game_id, client_session_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'game_sessions_game_id_fkey' and conrelid = 'public.game_sessions'::regclass) then alter table public.game_sessions add constraint game_sessions_game_id_fkey foreign key (game_id) REFERENCES games(id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'game_sessions_pkey' and conrelid = 'public.game_sessions'::regclass) then alter table public.game_sessions add constraint game_sessions_pkey primary key (id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'game_sessions_player_id_fkey' and conrelid = 'public.game_sessions'::regclass) then alter table public.game_sessions add constraint game_sessions_player_id_fkey foreign key (player_id) REFERENCES players(id) ON DELETE SET NULL; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'games_pkey' and conrelid = 'public.games'::regclass) then alter table public.games add constraint games_pkey primary key (id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'games_slug_key' and conrelid = 'public.games'::regclass) then alter table public.games add constraint games_slug_key unique (slug); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'games_status_check' and conrelid = 'public.games'::regclass) then alter table public.games add constraint games_status_check check ((status = ANY (ARRAY['prototype'::text, 'testing'::text, 'production'::text, 'paused'::text, 'retired'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'general_stage_bests_best_combo_check' and conrelid = 'public.general_stage_bests'::regclass) then alter table public.general_stage_bests add constraint general_stage_bests_best_combo_check check ((best_combo >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'general_stage_bests_best_score_check' and conrelid = 'public.general_stage_bests'::regclass) then alter table public.general_stage_bests add constraint general_stage_bests_best_score_check check ((best_score >= 0)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'general_stage_bests_best_stars_check' and conrelid = 'public.general_stage_bests'::regclass) then alter table public.general_stage_bests add constraint general_stage_bests_best_stars_check check (((best_stars >= 0) AND (best_stars <= 3))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'general_stage_bests_pkey' and conrelid = 'public.general_stage_bests'::regclass) then alter table public.general_stage_bests add constraint general_stage_bests_pkey primary key (user_id, stage_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'general_stage_bests_stage_id_check' and conrelid = 'public.general_stage_bests'::regclass) then alter table public.general_stage_bests add constraint general_stage_bests_stage_id_check check (((stage_id >= 1) AND (stage_id <= 4))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'induckup_ranked_bests_best_duration_ms_check' and conrelid = 'public.induckup_ranked_bests'::regclass) then alter table public.induckup_ranked_bests add constraint induckup_ranked_bests_best_duration_ms_check check (((best_duration_ms >= 0) AND (best_duration_ms <= 86400000))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'induckup_ranked_bests_best_score_check' and conrelid = 'public.induckup_ranked_bests'::regclass) then alter table public.induckup_ranked_bests add constraint induckup_ranked_bests_best_score_check check (((best_score >= 0) AND (best_score <= 2000000000))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'induckup_ranked_bests_best_wave_check' and conrelid = 'public.induckup_ranked_bests'::regclass) then alter table public.induckup_ranked_bests add constraint induckup_ranked_bests_best_wave_check check (((best_wave >= 0) AND (best_wave <= 10000))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'induckup_ranked_bests_pkey' and conrelid = 'public.induckup_ranked_bests'::regclass) then alter table public.induckup_ranked_bests add constraint induckup_ranked_bests_pkey primary key (user_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'inha_mail_badges_email_key' and conrelid = 'public.inha_mail_badges'::regclass) then alter table public.inha_mail_badges add constraint inha_mail_badges_email_key unique (email); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'inha_mail_badges_pkey' and conrelid = 'public.inha_mail_badges'::regclass) then alter table public.inha_mail_badges add constraint inha_mail_badges_pkey primary key (user_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'inha_mail_badges_valid_email' and conrelid = 'public.inha_mail_badges'::regclass) then alter table public.inha_mail_badges add constraint inha_mail_badges_valid_email check ((lower(email) ~ '^[^@[:space:]]+@(inha[.]edu|inha[.]ac[.]kr)$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'player_bests_best_run_id_fkey' and conrelid = 'public.player_bests'::regclass) then alter table public.player_bests add constraint player_bests_best_run_id_fkey foreign key (best_run_id) REFERENCES ranked_runs(id) ON DELETE RESTRICT; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'player_bests_nonnegative' and conrelid = 'public.player_bests'::regclass) then alter table public.player_bests add constraint player_bests_nonnegative check (((best_score >= 0) AND (best_combo >= 0))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'player_bests_pkey' and conrelid = 'public.player_bests'::regclass) then alter table public.player_bests add constraint player_bests_pkey primary key (user_id, stage_key); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'player_bests_stage' and conrelid = 'public.player_bests'::regclass) then alter table public.player_bests add constraint player_bests_stage check ((stage_key = 'secret'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'players_auth_user_id_key' and conrelid = 'public.players'::regclass) then alter table public.players add constraint players_auth_user_id_key unique (auth_user_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'players_pkey' and conrelid = 'public.players'::regclass) then alter table public.players add constraint players_pkey primary key (id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'players_visitor_id_key' and conrelid = 'public.players'::regclass) then alter table public.players add constraint players_visitor_id_key unique (visitor_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'profiles_avatar_key_check' and conrelid = 'public.profiles'::regclass) then alter table public.profiles add constraint profiles_avatar_key_check check ((avatar_key = ANY (ARRAY['classic'::text, 'scholar'::text, 'explorer'::text, 'star'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'profiles_department_id_fkey' and conrelid = 'public.profiles'::regclass) then alter table public.profiles add constraint profiles_department_id_fkey foreign key (department_id) REFERENCES departments(id) ON DELETE SET NULL; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'profiles_nickname_chars' and conrelid = 'public.profiles'::regclass) then alter table public.profiles add constraint profiles_nickname_chars check ((nickname ~ '^[0-9A-Za-z가-힣_ ]+$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'profiles_nickname_len' and conrelid = 'public.profiles'::regclass) then alter table public.profiles add constraint profiles_nickname_len check (((char_length(nickname) >= 2) AND (char_length(nickname) <= 12))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'profiles_pkey' and conrelid = 'public.profiles'::regclass) then alter table public.profiles add constraint profiles_pkey primary key (user_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'profiles_title_len' and conrelid = 'public.profiles'::regclass) then alter table public.profiles add constraint profiles_title_len check (((title IS NULL) OR (char_length(title) <= 40))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_runs_anticheat_counts_check' and conrelid = 'public.ranked_runs'::regclass) then alter table public.ranked_runs add constraint ranked_runs_anticheat_counts_check check (((normal_hits >= 0) AND (speedy_hits >= 0) AND ((dragon_calls >= 0) AND (dragon_calls <= 2)) AND (moon_bonus_hits >= 0) AND (flight_hits >= 0) AND (input_count >= 0) AND (reaction_sample_count >= 0) AND (ultra_fast_reaction_count >= 0) AND (ultra_fast_reaction_count <= reaction_sample_count))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_runs_ascension_award_plausible' and conrelid = 'public.ranked_runs'::regclass) then alter table public.ranked_runs add constraint ranked_runs_ascension_award_plausible check (((validation_status <> 'accepted'::text) OR (ruleset_version <> 'secret-2.2-r1'::text) OR ((tier1_ground_award + tier2_ground_award) <= ((((normal_hits + (speedy_hits * 2)) + (gold_hits * 3)) + (indeoki_hits * 5)) + combo_bonus)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_runs_ascension_bonus_exact' and conrelid = 'public.ranked_runs'::regclass) then alter table public.ranked_runs add constraint ranked_runs_ascension_bonus_exact check (((validation_status <> 'accepted'::text) OR (ruleset_version <> 'secret-2.2-r1'::text) OR (ascension_bonus = ((tier1_ground_award / 5) + (tier2_ground_award / 2))))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_runs_combo_bonus_plausible' and conrelid = 'public.ranked_runs'::regclass) then alter table public.ranked_runs add constraint ranked_runs_combo_bonus_plausible check (((validation_status <> 'accepted'::text) OR (ruleset_version <> 'secret-2.2-r1'::text) OR (combo_bonus <= (((((normal_hits + (speedy_hits * 2)) + (gold_hits * 3)) + (indeoki_hits * 5)) + (moon_bonus_hits * 2)) + flight_base_points)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_runs_completed_calls_check' and conrelid = 'public.ranked_runs'::regclass) then alter table public.ranked_runs add constraint ranked_runs_completed_calls_check check (((completed_calls >= 0) AND (completed_calls <= 2))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_runs_flight_ledger_bounds' and conrelid = 'public.ranked_runs'::regclass) then alter table public.ranked_runs add constraint ranked_runs_flight_ledger_bounds check (((validation_status <> 'accepted'::text) OR (ruleset_version <> 'secret-2.2-r1'::text) OR ((flight_hits = 0) AND (flight_base_points = 0)) OR ((flight_hits > 0) AND ((flight_base_points >= flight_hits) AND (flight_base_points <= (flight_hits * 5)))))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_runs_ledger_nonnegative' and conrelid = 'public.ranked_runs'::regclass) then alter table public.ranked_runs add constraint ranked_runs_ledger_nonnegative check (((combo_bonus >= 0) AND (flight_base_points >= 0) AND (tier1_hits >= 0) AND (tier2_hits >= 0) AND (tier1_ground_award >= 0) AND (tier2_ground_award >= 0) AND (ascension_bonus >= 0))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_runs_nonnegative' and conrelid = 'public.ranked_runs'::regclass) then alter table public.ranked_runs add constraint ranked_runs_nonnegative check (((score >= 0) AND (max_combo >= 0) AND (annyongi_hits >= 0) AND (indeoki_hits >= 0) AND (gold_hits >= 0) AND (total_hits >= 0) AND (dragon_bursts >= 0) AND (duration_ms >= 0))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_runs_pkey' and conrelid = 'public.ranked_runs'::regclass) then alter table public.ranked_runs add constraint ranked_runs_pkey primary key (id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_runs_run_id_fkey' and conrelid = 'public.ranked_runs'::regclass) then alter table public.ranked_runs add constraint ranked_runs_run_id_fkey foreign key (run_id) REFERENCES ranked_sessions(run_id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_runs_run_id_key' and conrelid = 'public.ranked_runs'::regclass) then alter table public.ranked_runs add constraint ranked_runs_run_id_key unique (run_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_runs_run_type_check' and conrelid = 'public.ranked_runs'::regclass) then alter table public.ranked_runs add constraint ranked_runs_run_type_check check ((run_type = ANY (ARRAY['ranked'::text, 'qa'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_runs_stage' and conrelid = 'public.ranked_runs'::regclass) then alter table public.ranked_runs add constraint ranked_runs_stage check ((stage_key = 'secret'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_runs_tier1_award_bounds' and conrelid = 'public.ranked_runs'::regclass) then alter table public.ranked_runs add constraint ranked_runs_tier1_award_bounds check (((validation_status <> 'accepted'::text) OR (ruleset_version <> 'secret-2.2-r1'::text) OR ((tier1_hits = 0) AND (tier1_ground_award = 0)) OR ((tier1_hits > 0) AND ((tier1_ground_award >= tier1_hits) AND (tier1_ground_award <= (tier1_hits * 10)))))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_runs_tier2_award_bounds' and conrelid = 'public.ranked_runs'::regclass) then alter table public.ranked_runs add constraint ranked_runs_tier2_award_bounds check (((validation_status <> 'accepted'::text) OR (ruleset_version <> 'secret-2.2-r1'::text) OR ((tier2_hits = 0) AND (tier2_ground_award = 0)) OR ((tier2_hits > 0) AND ((tier2_ground_award >= tier2_hits) AND (tier2_ground_award <= (tier2_hits * 10)))))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_runs_tier_hits_within_total' and conrelid = 'public.ranked_runs'::regclass) then alter table public.ranked_runs add constraint ranked_runs_tier_hits_within_total check (((validation_status <> 'accepted'::text) OR (ruleset_version <> 'secret-2.2-r1'::text) OR ((tier1_hits + tier2_hits) <= total_hits))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_runs_validation' and conrelid = 'public.ranked_runs'::regclass) then alter table public.ranked_runs add constraint ranked_runs_validation check ((validation_status = ANY (ARRAY['accepted'::text, 'rejected'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_sessions_pkey' and conrelid = 'public.ranked_sessions'::regclass) then alter table public.ranked_sessions add constraint ranked_sessions_pkey primary key (run_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_sessions_run_type_check' and conrelid = 'public.ranked_sessions'::regclass) then alter table public.ranked_sessions add constraint ranked_sessions_run_type_check check ((run_type = ANY (ARRAY['ranked'::text, 'qa'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_sessions_stage' and conrelid = 'public.ranked_sessions'::regclass) then alter table public.ranked_sessions add constraint ranked_sessions_stage check ((stage_key = 'secret'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_sessions_status' and conrelid = 'public.ranked_sessions'::regclass) then alter table public.ranked_sessions add constraint ranked_sessions_status check ((status = ANY (ARRAY['started'::text, 'submitted'::text, 'accepted'::text, 'rejected'::text, 'abandoned'::text, 'expired'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'user_achievements_achievement_key_check' and conrelid = 'public.user_achievements'::regclass) then alter table public.user_achievements add constraint user_achievements_achievement_key_check check (((achievement_key = ANY (ARRAY['classic_recorded_v1'::text, 'classic_ranked_accepted_v1'::text, 'inha_verified_v1'::text])) OR (achievement_key ~ '^classic_inha_duck_s1_rank_([1-9]|10)_v1$'::text))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'user_achievements_condition_version_check' and conrelid = 'public.user_achievements'::regclass) then alter table public.user_achievements add constraint user_achievements_condition_version_check check ((condition_version = 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'user_achievements_evidence_source_check' and conrelid = 'public.user_achievements'::regclass) then alter table public.user_achievements add constraint user_achievements_evidence_source_check check ((((achievement_key = 'classic_recorded_v1'::text) AND (evidence_source = 'classic_record'::text)) OR ((achievement_key = 'classic_ranked_accepted_v1'::text) AND (evidence_source = 'classic_ranked_accepted'::text)) OR ((achievement_key = 'inha_verified_v1'::text) AND (evidence_source = 'inha_mail_verified'::text)) OR ((achievement_key ~ '^classic_inha_duck_s1_rank_([1-9]|10)_v1$'::text) AND (evidence_source = 'classic_event_final_rank'::text)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'user_achievements_pkey' and conrelid = 'public.user_achievements'::regclass) then alter table public.user_achievements add constraint user_achievements_pkey primary key (user_id, achievement_key); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'user_game_progress_game_id_fkey' and conrelid = 'public.user_game_progress'::regclass) then alter table public.user_game_progress add constraint user_game_progress_game_id_fkey foreign key (game_id) REFERENCES games(id) ON DELETE CASCADE; end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'user_game_progress_pkey' and conrelid = 'public.user_game_progress'::regclass) then alter table public.user_game_progress add constraint user_game_progress_pkey primary key (user_id, game_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'user_game_progress_schema_version_check' and conrelid = 'public.user_game_progress'::regclass) then alter table public.user_game_progress add constraint user_game_progress_schema_version_check check ((schema_version >= 1)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_accompany_not_self' and conrelid = 'public.world_accompany_sessions'::regclass) then alter table public.world_accompany_sessions add constraint world_accompany_not_self check ((inviter_id <> invitee_id)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_accompany_poi' and conrelid = 'public.world_accompany_sessions'::regclass) then alter table public.world_accompany_sessions add constraint world_accompany_poi check ((poi_id = ANY (ARRAY['poi.main-gate'::text, 'poi.main-hall'::text, 'poi.inkyung-pond'::text, 'poi.jungseok'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_accompany_sessions_pkey' and conrelid = 'public.world_accompany_sessions'::regclass) then alter table public.world_accompany_sessions add constraint world_accompany_sessions_pkey primary key (id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_accompany_state' and conrelid = 'public.world_accompany_sessions'::regclass) then alter table public.world_accompany_sessions add constraint world_accompany_state check ((state = ANY (ARRAY['offered'::text, 'active'::text, 'ended'::text, 'declined'::text, 'expired'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_accompany_zone' and conrelid = 'public.world_accompany_sessions'::regclass) then alter table public.world_accompany_sessions add constraint world_accompany_zone check ((place_zone_id ~ '^AREA_[A-Z0-9_]{1,60}$'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_friendships_accepted_at' and conrelid = 'public.world_friendships'::regclass) then alter table public.world_friendships add constraint world_friendships_accepted_at check (((status = 'accepted'::text) = (accepted_at IS NOT NULL))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_friendships_canonical' and conrelid = 'public.world_friendships'::regclass) then alter table public.world_friendships add constraint world_friendships_canonical check ((user_low < user_high)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_friendships_pkey' and conrelid = 'public.world_friendships'::regclass) then alter table public.world_friendships add constraint world_friendships_pkey primary key (user_low, user_high); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_friendships_requester_member' and conrelid = 'public.world_friendships'::regclass) then alter table public.world_friendships add constraint world_friendships_requester_member check (((requested_by = user_low) OR (requested_by = user_high))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_friendships_status' and conrelid = 'public.world_friendships'::regclass) then alter table public.world_friendships add constraint world_friendships_status check ((status = ANY (ARRAY['pending'::text, 'accepted'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_friendships_times' and conrelid = 'public.world_friendships'::regclass) then alter table public.world_friendships add constraint world_friendships_times check (((updated_at >= created_at) AND ((accepted_at IS NULL) OR (accepted_at >= created_at)))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_guestbook_content_length_check' and conrelid = 'public.world_guestbook_entries'::regclass) then alter table public.world_guestbook_entries add constraint world_guestbook_content_length_check check (((char_length(btrim(content)) >= 1) AND (char_length(btrim(content)) <= 150))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_guestbook_entries_pkey' and conrelid = 'public.world_guestbook_entries'::regclass) then alter table public.world_guestbook_entries add constraint world_guestbook_entries_pkey primary key (id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_guestbook_location_p0_check' and conrelid = 'public.world_guestbook_entries'::regclass) then alter table public.world_guestbook_entries add constraint world_guestbook_location_p0_check check ((location_key = 'main_gate'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_rooms_owner_unique' and conrelid = 'public.world_player_rooms'::regclass) then alter table public.world_player_rooms add constraint world_player_rooms_owner_unique unique (owner_user_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_rooms_pkey' and conrelid = 'public.world_player_rooms'::regclass) then alter table public.world_player_rooms add constraint world_player_rooms_pkey primary key (id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_rooms_room_type_check' and conrelid = 'public.world_player_rooms'::regclass) then alter table public.world_player_rooms add constraint world_player_rooms_room_type_check check ((room_type = 'DORM_1_BASIC'::text)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_rooms_visibility_check' and conrelid = 'public.world_player_rooms'::regclass) then alter table public.world_player_rooms add constraint world_player_rooms_visibility_check check ((visibility = ANY (ARRAY['private'::text, 'friends'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_user_blocks_not_self' and conrelid = 'public.world_user_blocks'::regclass) then alter table public.world_user_blocks add constraint world_user_blocks_not_self check ((blocker_id <> blocked_id)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_user_blocks_pkey' and conrelid = 'public.world_user_blocks'::regclass) then alter table public.world_user_blocks add constraint world_user_blocks_pkey primary key (blocker_id, blocked_id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_user_reports_category' and conrelid = 'public.world_user_reports'::regclass) then alter table public.world_user_reports add constraint world_user_reports_category check ((category = ANY (ARRAY['spam'::text, 'harassment'::text, 'inappropriate_name'::text, 'other'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_user_reports_not_self' and conrelid = 'public.world_user_reports'::regclass) then alter table public.world_user_reports add constraint world_user_reports_not_self check ((reporter_id <> target_id)); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_user_reports_pkey' and conrelid = 'public.world_user_reports'::regclass) then alter table public.world_user_reports add constraint world_user_reports_pkey primary key (id); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_user_reports_resolution_check' and conrelid = 'public.world_user_reports'::regclass) then alter table public.world_user_reports add constraint world_user_reports_resolution_check check (((resolution IS NULL) OR (resolution = ANY (ARRAY['warning'::text, 'interaction_restriction_24h'::text, 'dismissed'::text])))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_user_reports_status_check' and conrelid = 'public.world_user_reports'::regclass) then alter table public.world_user_reports add constraint world_user_reports_status_check check ((status = ANY (ARRAY['pending'::text, 'reviewing'::text, 'resolved'::text, 'dismissed'::text]))); end if; end $$;

do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_user_reports_zone' and conrelid = 'public.world_user_reports'::regclass) then alter table public.world_user_reports add constraint world_user_reports_zone check (((place_zone_id IS NULL) OR (place_zone_id ~ '^AREA_[A-Z0-9_]{1,60}$'::text))); end if; end $$;

-- ================= Functions =================

CREATE OR REPLACE FUNCTION private.validate_world_room_furniture_v1(p_user uuid, p_objects jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_object jsonb; v_def record; v_fixed record; v_prior jsonb;
  v_seen text[] := array[]::text[]; v_boxes jsonb := '[]'::jsonb;
  v_x float8; v_z float8; v_yaw float8; v_hw float8; v_hd float8;
  v_x1 float8; v_x2 float8; v_z1 float8; v_z2 float8;
  v_surface text; v_id text; v_count integer; v_owned integer;
  v_epsilon constant float8 := .0000001;
begin
  if p_objects is null or jsonb_typeof(p_objects) <> 'array' then
    raise exception 'INVALID_LAYOUT' using errcode = '22023';
  end if;
  if jsonb_array_length(p_objects) > 32 or octet_length(p_objects::text) > 16384 then
    raise exception 'INVALID_LAYOUT' using errcode = '22023';
  end if;
  for v_object in select value from jsonb_array_elements(p_objects) loop
    if jsonb_typeof(v_object) <> 'object' then raise exception 'INVALID_LAYOUT' using errcode = '22023'; end if;
    if (select count(*) from jsonb_object_keys(v_object)) <> 6 or not v_object ?& array['id','itemId','surface','x','z','yaw'] or
      jsonb_typeof(v_object->'id') <> 'string' or jsonb_typeof(v_object->'itemId') <> 'string' or jsonb_typeof(v_object->'surface') <> 'string' or
      jsonb_typeof(v_object->'x') <> 'number' or jsonb_typeof(v_object->'z') <> 'number' or jsonb_typeof(v_object->'yaw') <> 'number' then
      raise exception 'INVALID_LAYOUT' using errcode = '22023';
    end if;
    v_id := v_object->>'id'; v_surface := v_object->>'surface';
    if v_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or v_id = any(v_seen) then
      raise exception 'INVALID_LAYOUT' using errcode = '22023';
    end if;
    v_seen := array_append(v_seen, v_id);
    select * into v_def from private.world_room_furniture_v1() where item_id = v_object->>'itemId';
    if not found or not v_surface = any(v_def.surfaces) then raise exception 'INVALID_LAYOUT' using errcode = '22023'; end if;
    -- Reject enormous JSON numbers before casting to float8. Coordinates are small room-local values.
    if abs((v_object->>'x')::numeric) > 16 or abs((v_object->>'z')::numeric) > 16 or
      (v_object->>'yaw')::numeric < 0 or (v_object->>'yaw')::numeric >= 360 or mod((v_object->>'yaw')::numeric,45) <> 0 then
      raise exception 'INVALID_LAYOUT' using errcode = '22023';
    end if;
    v_x := (v_object->>'x')::float8; v_z := (v_object->>'z')::float8; v_yaw := (v_object->>'yaw')::float8;
    if (v_surface in ('floor','desk','bed') and (mod((v_object->>'x')::numeric,.25) <> 0 or mod((v_object->>'z')::numeric,.25) <> 0)) or
      (v_surface = 'north' and (abs(v_z-4.15) > v_epsilon or v_yaw <> 0 or mod((v_object->>'x')::numeric,.25) <> 0)) or
      (v_surface = 'south' and (abs(v_z+4.15) > v_epsilon or v_yaw <> 180 or mod((v_object->>'x')::numeric,.25) <> 0)) or
      (v_surface = 'east' and (abs(v_x-5.35) > v_epsilon or v_yaw <> 90 or mod((v_object->>'z')::numeric,.25) <> 0)) or
      (v_surface = 'west' and (abs(v_x+5.35) > v_epsilon or v_yaw <> 270 or mod((v_object->>'z')::numeric,.25) <> 0)) then
      raise exception 'INVALID_LAYOUT' using errcode = '22023';
    end if;
    select count(*) into v_count from jsonb_array_elements(p_objects) o where o->>'itemId' = v_def.item_id;
    select i.quantity into v_owned from private.world_player_items i join private.world_item_catalog c on c.item_id = i.item_id
      where i.user_id = p_user and i.item_id = v_def.item_id and c.category = 'FURNITURE';
    if v_count > coalesce(v_owned,0) then raise exception 'ITEM_NOT_OWNED' using errcode = '42501'; end if;
    v_hw := (abs(cos(radians(v_yaw))) * v_def.width + abs(sin(radians(v_yaw))) * v_def.depth)/2;
    v_hd := (abs(sin(radians(v_yaw))) * v_def.width + abs(cos(radians(v_yaw))) * v_def.depth)/2;
    v_x1 := v_x-v_hw; v_x2 := v_x+v_hw; v_z1 := v_z-v_hd; v_z2 := v_z+v_hd;
    if v_surface = 'floor' then
      if v_x1 < -7.04-v_epsilon or v_x2 > 7.04+v_epsilon or v_z1 < -4.1-v_epsilon or v_z2 > 4.1+v_epsilon then
        raise exception 'ROOM_BOUNDS' using errcode = '22023';
      end if;
      if v_x1 < .9-v_epsilon and v_x2 > -.9+v_epsilon and v_z1 < -2.25-v_epsilon and v_z2 > -4.2+v_epsilon then
        raise exception 'EXIT_BLOCKED' using errcode = '22023';
      end if;
      for v_fixed in select * from (values
        (-4.6::float8,-3.0::float8,.55::float8,3.25::float8,false), -- bed
        (2.0,3.9,1.325,2.075,false), -- desk
        (2.675,3.225,.575,1.125,false), -- fixed chair
        (4.35,4.95,1.4,2.9,false), -- bookshelf
        (4.275,4.725,-3.125,-2.675,false), -- plant
        (-1.4,1.4,-.4,1.7,true) -- base rug: only another rug conflicts
      ) as fixture(x1,x2,z1,z2,flat) loop
        if (not v_fixed.flat or v_def.flat) and v_x1 < v_fixed.x2-v_epsilon and v_x2 > v_fixed.x1+v_epsilon and
          v_z1 < v_fixed.z2-v_epsilon and v_z2 > v_fixed.z1+v_epsilon then
          raise exception 'FURNITURE_OVERLAP' using errcode = '22023';
        end if;
      end loop;
    elsif v_surface = 'desk' then
      if v_x1 < 2.05-v_epsilon or v_x2 > 3.85+v_epsilon or v_z1 < 1.375-v_epsilon or v_z2 > 2.025+v_epsilon then
        raise exception 'ROOM_BOUNDS' using errcode = '22023';
      end if;
      if v_x1 < 3.51-v_epsilon and v_x2 > 3.09+v_epsilon and v_z1 < 1.84-v_epsilon and v_z2 > 1.56+v_epsilon then
        raise exception 'FURNITURE_OVERLAP' using errcode = '22023';
      end if;
    elsif v_surface = 'bed' then
      if v_x1 < -4.55-v_epsilon or v_x2 > -3.05+v_epsilon or v_z1 < .6-v_epsilon or v_z2 > 3.2+v_epsilon then
        raise exception 'ROOM_BOUNDS' using errcode = '22023';
      end if;
      if v_x1 < -3.304-v_epsilon and v_x2 > -4.296+v_epsilon and v_z1 < 3.11-v_epsilon and v_z2 > 2.63+v_epsilon then
        raise exception 'FURNITURE_OVERLAP' using errcode = '22023';
      end if;
    else
      if (v_surface in ('north','south') and abs(v_x)+v_def.width/2 > 5.3+v_epsilon) or
        (v_surface in ('east','west') and abs(v_z)+v_def.width/2 > 4.1+v_epsilon) then
        raise exception 'ROOM_BOUNDS' using errcode = '22023';
      end if;
      if v_surface = 'north' and v_x-v_def.width/2 < 1.8 and v_x+v_def.width/2 > -.8 then
        raise exception 'FURNITURE_OVERLAP' using errcode = '22023';
      end if;
      if v_surface = 'south' and abs(v_x) < .68+v_def.width/2 then raise exception 'EXIT_BLOCKED' using errcode = '22023'; end if;
    end if;
    for v_prior in select value from jsonb_array_elements(v_boxes) loop
      if v_prior->>'surface' <> v_surface or (v_surface = 'floor' and (v_prior->>'flat')::boolean <> v_def.flat) then continue; end if;
      if v_x1 < (v_prior->>'x2')::float8-v_epsilon and v_x2 > (v_prior->>'x1')::float8+v_epsilon and
        v_z1 < (v_prior->>'z2')::float8-v_epsilon and v_z2 > (v_prior->>'z1')::float8+v_epsilon then
        raise exception 'FURNITURE_OVERLAP' using errcode = '22023';
      end if;
    end loop;
    v_boxes := v_boxes || jsonb_build_array(jsonb_build_object('surface',v_surface,'flat',v_def.flat,'x1',v_x1,'x2',v_x2,'z1',v_z1,'z2',v_z2));
  end loop;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_accompany_expire(p_user uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update public.world_accompany_sessions s
     set state = 'expired', ended_at = now(), ended_reason = 'timeout'
   where (s.inviter_id = p_user or s.invitee_id = p_user)
     and s.state in ('offered', 'active') and s.expires_at <= now();
  update public.world_accompany_sessions s
     set state = 'ended', ended_at = now(), ended_reason = 'relationship'
   where (s.inviter_id = p_user or s.invitee_id = p_user)
     and s.state in ('offered', 'active')
     and private.world_relationship(s.inviter_id, s.invitee_id) <> 'friends';
$function$
;

CREATE OR REPLACE FUNCTION private.world_accompany_lock_users(p_a uuid, p_b uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform pg_advisory_xact_lock(hashtextextended('world_accompany:' || least(p_a, p_b)::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('world_accompany:' || greatest(p_a, p_b)::text, 0));
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_appearance_caller_v1(p_user uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
begin
  if not private.world_inventory_account_ok_v1(v_uid) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '42501';
  end if;
  return v_uid;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_appearance_loadout_json_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object('slots', jsonb_object_agg(s.slot, case when l.item_id is null then 'null'::jsonb
    else jsonb_build_object('itemId', l.item_id, 'catalogStatus', coalesce(c.status, 'UNKNOWN_ITEM'),
                            'equippedAt', l.updated_at) end))
  from unnest(array['BODY', 'FACE', 'HAIR', 'HEAD', 'TOP', 'BOTTOM', 'SHOES', 'BACK', 'ACCESSORY']) as s(slot)
  left join private.world_player_appearance_loadout l on l.user_id = p_user and l.slot = s.slot
  left join private.world_item_catalog c on c.item_id = l.item_id;
$function$
;

CREATE OR REPLACE FUNCTION private.world_appearance_record_v1(p_user uuid, p_key text, p_action text, p_slot text, p_requested text, p_previous text, p_next text)
 RETURNS private.world_appearance_transactions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tx private.world_appearance_transactions;
begin
  insert into private.world_appearance_transactions
    (idempotency_key, user_id, action, slot, requested_item_id, previous_item_id, next_item_id)
  values (p_key, p_user, p_action, p_slot, p_requested, p_previous, p_next)
  returning * into v_tx;
  return v_tx;
exception when unique_violation then
  raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_appearance_result_v1(p_tx private.world_appearance_transactions, p_replayed boolean)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'status', 'SUCCESS',
    'replayed', p_replayed,
    'transactionId', p_tx.transaction_id,
    'action', p_tx.action,
    'slot', p_tx.slot,
    'previousItemId', p_tx.previous_item_id,
    'itemId', p_tx.next_item_id,
    'changed', p_tx.previous_item_id is distinct from p_tx.next_item_id,
    'createdAt', p_tx.created_at,
    -- The loadout as it is now (on a replay: now, not at the original call).
    'loadout', private.world_appearance_loadout_json_v1(p_tx.user_id));
$function$
;

CREATE OR REPLACE FUNCTION private.world_appearance_slot_ok_v1(p_slot text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select p_slot is not null
     and p_slot = any (array['BODY', 'FACE', 'HAIR', 'HEAD', 'TOP', 'BOTTOM', 'SHOES', 'BACK', 'ACCESSORY']);
$function$
;

CREATE OR REPLACE FUNCTION private.world_appearance_transactions_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  raise exception 'APPEARANCE_LOG_APPEND_ONLY' using errcode = '42501';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_attendance_caller_v1(p_user uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
begin
  if not private.world_inventory_account_ok_v1(v_uid) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '42501';
  end if;
  return v_uid;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_attendance_claim_v1(p_user uuid, p_today date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
  v_today date := p_today;
  v_count integer;
  v_milestone smallint;
  v_daily jsonb;
  v_bonus jsonb;
  v_rewards jsonb := '[]'::jsonb;
begin
  -- One attendance decision per account at a time: concurrent claims wait, then see today's row.
  perform pg_advisory_xact_lock(hashtextextended('world_attendance:' || v_uid::text, 0));
  if exists (select 1 from private.world_attendance_days a where a.user_id = v_uid and a.attendance_date = v_today) then
    return private.world_attendance_state_v1(v_uid, v_today)
      || jsonb_build_object('claimed', false, 'replayed', true, 'rewards', '[]'::jsonb);
  end if;

  select count(*) + 1 into v_count from private.world_attendance_days a
   where a.user_id = v_uid and a.attendance_date >= date_trunc('month', v_today)::date and a.attendance_date < v_today;
  v_milestone := case when v_count in (3, 7, 14, 21) then v_count end;

  v_daily := private.world_reward_grant_v1(v_uid, 'reward.attendance.daily', 'SYSTEM', 'attendance.daily',
    'attendance:daily:' || v_uid::text || ':' || to_char(v_today, 'YYYY-MM-DD'));
  if coalesce(v_daily ->> 'status', 'FAILED') not in ('SUCCESS', 'PARTIAL_SUCCESS') then
    raise exception 'ATTENDANCE_REWARD_FAILED' using errcode = 'P0001';
  end if;
  v_rewards := v_rewards || jsonb_build_array(private.world_daily_quiz_reward_view_v1(v_daily));

  if v_milestone is not null then
    v_bonus := private.world_reward_grant_v1(v_uid, 'reward.attendance.monthly_' || v_milestone, 'SYSTEM',
      'attendance.monthly.' || v_milestone,
      'attendance:monthly:' || v_uid::text || ':' || to_char(v_today, 'YYYY-MM') || ':' || v_milestone);
    if coalesce(v_bonus ->> 'status', 'FAILED') not in ('SUCCESS', 'PARTIAL_SUCCESS') then
      raise exception 'ATTENDANCE_REWARD_FAILED' using errcode = 'P0001';
    end if;
    v_rewards := v_rewards || jsonb_build_array(private.world_daily_quiz_reward_view_v1(v_bonus));
  end if;

  insert into private.world_attendance_days (user_id, attendance_date, daily_reward_transaction_id, milestone,
    milestone_reward_transaction_id)
  values (v_uid, v_today, (v_daily ->> 'rewardTransactionId')::uuid, v_milestone,
    (v_bonus ->> 'rewardTransactionId')::uuid);

  return private.world_attendance_state_v1(v_uid, v_today)
    || jsonb_build_object('claimed', true, 'replayed', false, 'rewards', v_rewards);
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_attendance_milestone_coin_v1(p_days integer)
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select g.amount from private.world_reward_grants g
    join private.world_reward_definitions d on d.reward_id = g.reward_id
   where p_days in (3, 7, 14, 21) and g.reward_id = 'reward.attendance.monthly_' || p_days
     and d.status = 'ACTIVE' and g.grant_type = 'CURRENCY';
$function$
;

CREATE OR REPLACE FUNCTION private.world_attendance_state_v1(p_user uuid, p_today date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with bounds as (
    select date_trunc('month', p_today)::date as month_start,
           (date_trunc('month', p_today) + interval '1 month')::date as next_month),
  days as (
    select a.attendance_date, a.milestone from private.world_attendance_days a, bounds b
     where a.user_id = p_user and a.attendance_date >= b.month_start and a.attendance_date < b.next_month
       and a.attendance_date <= p_today),
  counted as (select count(*)::int as n from days),
  steps as (select m, private.world_attendance_milestone_coin_v1(m) as coin from unnest(array[3, 7, 14, 21]) m)
  select jsonb_build_object(
    'rewardDate', to_char(p_today, 'YYYY-MM-DD'),
    'month', to_char(p_today, 'YYYY-MM'),
    'claimedToday', exists (select 1 from days where attendance_date = p_today),
    'attendedDays', (select n from counted),
    'attendedDates', coalesce((select jsonb_agg(to_char(attendance_date, 'YYYY-MM-DD') order by attendance_date) from days), '[]'::jsonb),
    'dailyCoin', (select g.amount from private.world_reward_grants g where g.reward_id = 'reward.attendance.daily' and g.grant_type = 'CURRENCY'),
    'nextMilestone', (select jsonb_build_object('days', s.m, 'bonusCoin', s.coin) from steps s
                       where s.m > (select n from counted) order by s.m limit 1),
    'milestones', (select jsonb_agg(jsonb_build_object('days', s.m, 'bonusCoin', s.coin,
                     'claimed', exists (select 1 from days d where d.milestone = s.m)) order by s.m) from steps s));
$function$
;

CREATE OR REPLACE FUNCTION private.world_attendance_today_v1(p_now timestamp with time zone DEFAULT now())
 RETURNS date
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select (p_now at time zone 'Asia/Seoul')::date;
$function$
;

CREATE OR REPLACE FUNCTION private.world_biryong_relationship_account_ok_v1(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select p_user is not null and exists (select 1 from public.sessions s where s.id = p_user::text);
$function$
;

CREATE OR REPLACE FUNCTION private.world_biryong_relationship_advance_v1(p_user uuid, p_npc_id text, p_target_stage smallint, p_source_type text, p_source_ref text, p_result_ref text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_npc private.world_biryong_npc_relationship_npc_catalog%rowtype;
  v_event private.world_biryong_npc_relationship_events%rowtype;
  v_state private.world_player_biryong_npc_relationships%rowtype;
  v_current_stage smallint := 1;
  v_current_revision bigint := 0;
  v_now timestamptz := now();
begin
  if p_target_stage not in (2,3) then
    raise exception 'INVALID_RELATIONSHIP_STAGE' using errcode = '22023';
  end if;
  if p_source_type is null or p_source_type not in ('QUEST','EVENT','SYSTEM','ADMIN') then
    raise exception 'INVALID_RELATIONSHIP_SOURCE' using errcode = '22023';
  end if;
  if p_source_ref is null
     or p_source_ref !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'
     or char_length(p_source_ref) > 200 then
    raise exception 'INVALID_RELATIONSHIP_SOURCE_REF' using errcode = '22023';
  end if;
  if p_result_ref is not null and (
       p_result_ref !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'
       or char_length(p_result_ref) > 200) then
    raise exception 'INVALID_RELATIONSHIP_RESULT_REF' using errcode = '22023';
  end if;
  if p_source_type in ('QUEST','EVENT') and p_result_ref is null then
    raise exception 'RELATIONSHIP_RESULT_REF_REQUIRED' using errcode = '22023';
  end if;
  if p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'
     or char_length(p_idempotency_key) > 200 then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = '22023';
  end if;
  if not private.world_biryong_relationship_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  select * into v_npc
    from private.world_biryong_npc_relationship_npc_catalog n
   where n.npc_id = p_npc_id;
  if not found or v_npc.status <> 'ACTIVE' then
    raise exception 'BIRYONG_NPC_NOT_AVAILABLE' using errcode = 'P0002';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('world_biryong_relationship:' || p_user::text || ':' || p_npc_id,0));

  select * into v_event
    from private.world_biryong_npc_relationship_events e
   where e.idempotency_key = p_idempotency_key;
  if found then
    if (v_event.user_id,v_event.npc_id,v_event.to_stage,v_event.source_type,
        v_event.source_ref,v_event.result_ref)
       is distinct from
       (p_user,p_npc_id,p_target_stage,p_source_type,p_source_ref,p_result_ref) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return jsonb_build_object(
      'status','ALREADY_PROCESSED',
      'eventId',v_event.relationship_event_id,
      'relationship',private.world_biryong_relationship_snapshot_v1(p_user,p_npc_id)
    );
  end if;

  select * into v_state
    from private.world_player_biryong_npc_relationships r
   where r.user_id = p_user
     and r.npc_id = p_npc_id
   for update;

  if found then
    v_current_stage := v_state.stage;
    v_current_revision := v_state.revision;
  end if;

  if p_target_stage <= v_current_stage then
    return jsonb_build_object(
      'status','ALREADY_UNLOCKED',
      'relationship',private.world_biryong_relationship_snapshot_v1(p_user,p_npc_id)
    );
  end if;
  if p_target_stage <> v_current_stage + 1 then
    raise exception 'RELATIONSHIP_STAGE_STEP_REQUIRED' using errcode = 'P0001';
  end if;

  insert into private.world_biryong_npc_relationship_events(
    user_id,npc_id,from_stage,to_stage,source_type,source_ref,result_ref,
    idempotency_key,definition_version,advanced_at)
  values (
    p_user,p_npc_id,v_current_stage,p_target_stage,p_source_type,p_source_ref,p_result_ref,
    p_idempotency_key,v_npc.definition_version,v_now)
  returning * into v_event;

  if v_current_stage = 1 then
    insert into private.world_player_biryong_npc_relationships(
      user_id,npc_id,stage,revision,stage2_unlocked_at,stage3_unlocked_at,updated_at)
    values (
      p_user,p_npc_id,2,1,v_now,null,v_now);
  else
    update private.world_player_biryong_npc_relationships r
       set stage = 3,
           revision = v_current_revision + 1,
           stage3_unlocked_at = v_now,
           updated_at = v_now
     where r.user_id = p_user
       and r.npc_id = p_npc_id;
  end if;

  return jsonb_build_object(
    'status','ADVANCED',
    'eventId',v_event.relationship_event_id,
    'relationship',private.world_biryong_relationship_snapshot_v1(p_user,p_npc_id)
  );
exception when unique_violation then
  select * into v_event
    from private.world_biryong_npc_relationship_events e
   where e.idempotency_key = p_idempotency_key;
  if found
     and (v_event.user_id,v_event.npc_id,v_event.to_stage,v_event.source_type,
          v_event.source_ref,v_event.result_ref)
         is not distinct from
         (p_user,p_npc_id,p_target_stage,p_source_type,p_source_ref,p_result_ref) then
    return jsonb_build_object(
      'status','ALREADY_PROCESSED',
      'eventId',v_event.relationship_event_id,
      'relationship',private.world_biryong_relationship_snapshot_v1(p_user,p_npc_id)
    );
  end if;
  raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_biryong_relationship_event_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'DELETE' and not exists (select 1 from public.sessions s where s.id = old.user_id::text) then return old; end if;
  raise exception 'BIRYONG_RELATIONSHIP_EVENT_APPEND_ONLY' using errcode = '42501';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_biryong_relationship_list_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not private.world_biryong_relationship_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;
  return jsonb_build_object(
    'relationships',coalesce((
      select jsonb_agg(
        private.world_biryong_relationship_snapshot_v1(p_user,n.npc_id)
        order by n.npc_id
      )
      from private.world_biryong_npc_relationship_npc_catalog n
      where n.status = 'ACTIVE'
    ),'[]'::jsonb)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_biryong_relationship_projection_guard_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if (new.user_id,new.npc_id,new.stage2_unlocked_at)
     is distinct from
     (old.user_id,old.npc_id,old.stage2_unlocked_at) then
    raise exception 'BIRYONG_RELATIONSHIP_PROJECTION_IMMUTABLE' using errcode = '42501';
  end if;
  if new.stage <> old.stage + 1
     or new.revision <> old.revision + 1
     or new.updated_at < old.updated_at then
    raise exception 'BIRYONG_RELATIONSHIP_PROJECTION_INVALID' using errcode = '23514';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_biryong_relationship_snapshot_v1(p_user uuid, p_npc_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_npc private.world_biryong_npc_relationship_npc_catalog%rowtype;
  v_state private.world_player_biryong_npc_relationships%rowtype;
  v_stage smallint := 1;
  v_revision bigint := 0;
  v_stage2 timestamptz := null;
  v_stage3 timestamptz := null;
  v_updated timestamptz := null;
begin
  if not private.world_biryong_relationship_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  select * into v_npc
    from private.world_biryong_npc_relationship_npc_catalog n
   where n.npc_id = p_npc_id;
  if not found or v_npc.status <> 'ACTIVE' then
    raise exception 'BIRYONG_NPC_NOT_AVAILABLE' using errcode = 'P0002';
  end if;

  select * into v_state
    from private.world_player_biryong_npc_relationships r
   where r.user_id = p_user
     and r.npc_id = p_npc_id;

  if found then
    v_stage := v_state.stage;
    v_revision := v_state.revision;
    v_stage2 := v_state.stage2_unlocked_at;
    v_stage3 := v_state.stage3_unlocked_at;
    v_updated := v_state.updated_at;
  end if;

  return jsonb_build_object(
    'npcId',v_npc.npc_id,
    'stage',v_stage,
    'stageState',case v_stage
      when 1 then 'ACQUAINTED'
      when 2 then 'TRUSTED'
      else 'SHARED_RESPONSIBILITY'
    end,
    'nextStage',case when v_stage < 3 then v_stage + 1 else null end,
    'revision',v_revision,
    'stage2UnlockedAt',v_stage2,
    'stage3UnlockedAt',v_stage3,
    'updatedAt',v_updated,
    'unlockedFacts',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'factId',f.fact_id,
          'npcId',f.npc_id,
          'unlockStage',f.unlock_stage,
          'topicId',f.topic_id,
          'topicLabel',f.topic_label,
          'factText',f.fact_text,
          'dialogueLine',f.dialogue_line,
          'generativeSafe',f.generative_safe,
          'definitionVersion',f.definition_version
        )
        order by f.unlock_stage,f.fact_id
      )
      from private.world_biryong_npc_relationship_fact_catalog f
      where f.npc_id = p_npc_id
        and f.status = 'ACTIVE'
        and f.unlock_stage <= v_stage
    ),'[]'::jsonb)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_campus_npc_relationship_account_ok_v1(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select p_user is not null and exists (select 1 from public.sessions s where s.id = p_user::text);
$function$
;

CREATE OR REPLACE FUNCTION private.world_campus_npc_relationship_apply_v1(p_user uuid, p_npc_id text, p_definition_version integer, p_event_type text, p_signal text, p_occurrence integer, p_requested_delta smallint, p_source_type text, p_source_ref text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_npc private.world_campus_npc_relationship_npc_catalog%rowtype;
  v_event private.world_campus_npc_relationship_events%rowtype;
  v_state private.world_player_campus_npc_relationships%rowtype;
  v_before smallint := 0;
  v_after smallint := 0;
  v_applied smallint := 0;
  v_encounter_inc integer := 0;
  v_meaningful_inc integer := 0;
  v_state_found boolean := false;
  v_now timestamptz := now();
begin
  if p_event_type is null or p_event_type not in (
    'FIRST_MEETING','REUNION','MEANINGFUL_DIALOGUE','SHARED_ACTIVITY','HELPED_NPC',
    'PERSONAL_QUEST_STEP','PERSONAL_QUEST_COMPLETE','MEANINGFUL_CHOICE','NEGATIVE_CHOICE'
  ) then
    raise exception 'INVALID_CAMPUS_NPC_RELATIONSHIP_EVENT' using errcode = '22023';
  end if;
  if p_event_type = 'FIRST_MEETING' and p_occurrence <> 1 then
    raise exception 'INVALID_FIRST_MEETING_OCCURRENCE' using errcode = '22023';
  end if;
  if p_occurrence is null or p_occurrence < 1 or p_occurrence > 1000 then
    raise exception 'INVALID_RELATIONSHIP_OCCURRENCE' using errcode = '22023';
  end if;
  if p_requested_delta is null or p_requested_delta = 0 or p_requested_delta < -10 or p_requested_delta > 10 then
    raise exception 'INVALID_RELATIONSHIP_DELTA' using errcode = '22023';
  end if;
  if (p_event_type = 'NEGATIVE_CHOICE' and p_requested_delta > 0)
     or (p_event_type <> 'NEGATIVE_CHOICE' and p_requested_delta < 0) then
    raise exception 'RELATIONSHIP_DELTA_SIGN_MISMATCH' using errcode = '22023';
  end if;
  if p_signal is not null and (
       p_signal !~ '^[A-Z][A-Z0-9_]{1,63}$' or char_length(p_signal) > 64) then
    raise exception 'INVALID_RELATIONSHIP_SIGNAL' using errcode = '22023';
  end if;
  if p_source_type is null or p_source_type not in ('DIALOGUE','ACTIVITY','QUEST','WORLD','SYSTEM','ADMIN') then
    raise exception 'INVALID_RELATIONSHIP_SOURCE' using errcode = '22023';
  end if;
  if p_source_ref is null
     or p_source_ref !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'
     or char_length(p_source_ref) > 200 then
    raise exception 'INVALID_RELATIONSHIP_SOURCE_REF' using errcode = '22023';
  end if;
  if p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'
     or char_length(p_idempotency_key) > 200 then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = '22023';
  end if;
  if not private.world_campus_npc_relationship_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  select * into v_npc
    from private.world_campus_npc_relationship_npc_catalog n
   where n.npc_id = p_npc_id;
  if not found or v_npc.status <> 'ACTIVE' then
    raise exception 'CAMPUS_NPC_NOT_AVAILABLE' using errcode = 'P0002';
  end if;
  if p_definition_version is distinct from v_npc.definition_version then
    raise exception 'RELATIONSHIP_DEFINITION_VERSION_MISMATCH' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('world_campus_npc_relationship:' || p_user::text || ':' || p_npc_id,0));

  select * into v_event
    from private.world_campus_npc_relationship_events e
   where e.idempotency_key = p_idempotency_key;
  if found then
    if (v_event.user_id,v_event.npc_id,v_event.definition_version,v_event.event_type,
        v_event.signal,v_event.occurrence,v_event.requested_delta,v_event.source_type,v_event.source_ref)
       is distinct from
       (p_user,p_npc_id,p_definition_version,p_event_type,p_signal,p_occurrence,p_requested_delta,p_source_type,p_source_ref) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return jsonb_build_object(
      'status','ALREADY_PROCESSED',
      'eventId',v_event.relationship_event_id,
      'relationship',private.world_campus_npc_relationship_snapshot_v1(p_user,p_npc_id)
    );
  end if;

  if p_event_type = 'FIRST_MEETING' and exists (
    select 1 from private.world_campus_npc_relationship_events e
     where e.user_id = p_user and e.npc_id = p_npc_id and e.event_type = 'FIRST_MEETING'
  ) then
    return jsonb_build_object(
      'status','ALREADY_MET',
      'relationship',private.world_campus_npc_relationship_snapshot_v1(p_user,p_npc_id)
    );
  end if;

  select * into v_state
    from private.world_player_campus_npc_relationships r
   where r.user_id = p_user and r.npc_id = p_npc_id
   for update;

  v_state_found := found;
  if v_state_found then v_before := v_state.affinity; end if;
  v_after := greatest(0,least(100,v_before + p_requested_delta));
  v_applied := v_after - v_before;
  v_encounter_inc := case when p_event_type in ('FIRST_MEETING','REUNION') then 1 else 0 end;
  v_meaningful_inc := case when p_event_type in ('FIRST_MEETING','REUNION') then 0 else 1 end;

  insert into private.world_campus_npc_relationship_events(
    user_id,npc_id,event_type,signal,occurrence,requested_delta,applied_delta,
    affinity_before,affinity_after,source_type,source_ref,idempotency_key,
    definition_version,applied_at)
  values (
    p_user,p_npc_id,p_event_type,p_signal,p_occurrence,p_requested_delta,v_applied,
    v_before,v_after,p_source_type,p_source_ref,p_idempotency_key,
    v_npc.definition_version,v_now)
  returning * into v_event;

  if not v_state_found then
    insert into private.world_player_campus_npc_relationships(
      user_id,npc_id,affinity,encounter_count,meaningful_interaction_count,
      first_interaction_at,last_interaction_at,last_meaningful_at,revision,updated_at)
    values (
      p_user,p_npc_id,v_after,v_encounter_inc,v_meaningful_inc,
      v_now,v_now,case when v_meaningful_inc = 1 then v_now else null end,1,v_now);
  else
    update private.world_player_campus_npc_relationships r
       set affinity = v_after,
           encounter_count = r.encounter_count + v_encounter_inc,
           meaningful_interaction_count = r.meaningful_interaction_count + v_meaningful_inc,
           last_interaction_at = v_now,
           last_meaningful_at = case when v_meaningful_inc = 1 then v_now else r.last_meaningful_at end,
           revision = r.revision + 1,
           updated_at = v_now
     where r.user_id = p_user and r.npc_id = p_npc_id;
  end if;

  return jsonb_build_object(
    'status','APPLIED',
    'eventId',v_event.relationship_event_id,
    'requestedDelta',p_requested_delta,
    'appliedDelta',v_applied,
    'relationship',private.world_campus_npc_relationship_snapshot_v1(p_user,p_npc_id)
  );
exception when unique_violation then
  select * into v_event
    from private.world_campus_npc_relationship_events e
   where e.idempotency_key = p_idempotency_key;
  if found and
     (v_event.user_id,v_event.npc_id,v_event.definition_version,v_event.event_type,
      v_event.signal,v_event.occurrence,v_event.requested_delta,v_event.source_type,v_event.source_ref)
     is not distinct from
     (p_user,p_npc_id,p_definition_version,p_event_type,p_signal,p_occurrence,p_requested_delta,p_source_type,p_source_ref) then
    return jsonb_build_object(
      'status','ALREADY_PROCESSED',
      'eventId',v_event.relationship_event_id,
      'relationship',private.world_campus_npc_relationship_snapshot_v1(p_user,p_npc_id)
    );
  end if;
  raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_campus_npc_relationship_event_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'DELETE' and not exists (select 1 from public.sessions s where s.id = old.user_id::text) then return old; end if;
  raise exception 'CAMPUS_NPC_RELATIONSHIP_EVENT_APPEND_ONLY' using errcode = '42501';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_campus_npc_relationship_list_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not private.world_campus_npc_relationship_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;
  return jsonb_build_object(
    'relationships',coalesce((
      select jsonb_agg(
        private.world_campus_npc_relationship_snapshot_v1(p_user,n.npc_id)
        order by n.npc_id
      )
      from private.world_campus_npc_relationship_npc_catalog n
      where n.status = 'ACTIVE'
    ),'[]'::jsonb)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_campus_npc_relationship_projection_guard_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if (new.user_id,new.npc_id,new.first_interaction_at)
     is distinct from
     (old.user_id,old.npc_id,old.first_interaction_at) then
    raise exception 'CAMPUS_NPC_RELATIONSHIP_PROJECTION_IMMUTABLE' using errcode = '42501';
  end if;
  if new.revision <> old.revision + 1
     or abs(new.affinity - old.affinity) > 10
     or new.encounter_count < old.encounter_count
     or new.encounter_count > old.encounter_count + 1
     or new.meaningful_interaction_count < old.meaningful_interaction_count
     or new.meaningful_interaction_count > old.meaningful_interaction_count + 1
     or new.last_interaction_at < old.last_interaction_at
     or (old.last_meaningful_at is not null and new.last_meaningful_at is null)
     or (old.last_meaningful_at is not null and new.last_meaningful_at < old.last_meaningful_at)
     or new.updated_at < old.updated_at then
    raise exception 'CAMPUS_NPC_RELATIONSHIP_PROJECTION_INVALID' using errcode = '23514';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_campus_npc_relationship_snapshot_v1(p_user uuid, p_npc_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_npc private.world_campus_npc_relationship_npc_catalog%rowtype;
  v_state private.world_player_campus_npc_relationships%rowtype;
  v_affinity smallint := 0;
  v_encounters integer := 0;
  v_meaningful integer := 0;
  v_revision bigint := 0;
begin
  if not private.world_campus_npc_relationship_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  select * into v_npc
    from private.world_campus_npc_relationship_npc_catalog n
   where n.npc_id = p_npc_id;
  if not found or v_npc.status <> 'ACTIVE' then
    raise exception 'CAMPUS_NPC_NOT_AVAILABLE' using errcode = 'P0002';
  end if;

  select * into v_state
    from private.world_player_campus_npc_relationships r
   where r.user_id = p_user
     and r.npc_id = p_npc_id;

  if found then
    v_affinity := v_state.affinity;
    v_encounters := v_state.encounter_count;
    v_meaningful := v_state.meaningful_interaction_count;
    v_revision := v_state.revision;
  end if;

  return jsonb_build_object(
    'npcId',v_npc.npc_id,
    'relationshipClass',v_npc.relationship_class,
    'definitionVersion',v_npc.definition_version,
    'affinity',v_affinity,
    'tier',private.world_campus_npc_relationship_tier_v1(v_affinity),
    'encounterCount',v_encounters,
    'meaningfulInteractionCount',v_meaningful,
    'firstInteractionAt',case when found then v_state.first_interaction_at else null end,
    'lastInteractionAt',case when found then v_state.last_interaction_at else null end,
    'lastMeaningfulAt',case when found then v_state.last_meaningful_at else null end,
    'revision',v_revision,
    'updatedAt',case when found then v_state.updated_at else null end
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_campus_npc_relationship_tier_v1(p_affinity integer)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case
    when p_affinity between 0 and 9 then 'STRANGER'
    when p_affinity between 10 and 24 then 'FAMILIAR'
    when p_affinity between 25 and 44 then 'FRIENDLY'
    when p_affinity between 45 and 69 then 'FRIEND'
    when p_affinity between 70 and 100 then 'TRUSTED'
    else null
  end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_card(p_user uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'userId', p.user_id,
    'nickname', p.nickname,
    'title', p.title,
    'avatar', p.avatar_key,
    'inhaVerified',
      exists (
        select 1
        from public.inha_mail_badges b
        where b.user_id = p_user
      )
  )
  from public.profiles p
  where p.user_id = p_user
    and p.is_banned = false;
$function$
;

CREATE OR REPLACE FUNCTION private.world_currency_transactions_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  raise exception 'LEDGER_APPEND_ONLY' using errcode = '42501';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_daily_quiz_account_ok_v1(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select p_user is not null and exists (select 1 from public.sessions s where s.id = p_user::text);
$function$
;

CREATE OR REPLACE FUNCTION private.world_daily_quiz_caller_v1(p_user uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
begin
  if v_uid is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;
  if not private.world_daily_quiz_account_ok_v1(v_uid) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '42501';
  end if;
  return v_uid;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_daily_quiz_major_count_v1(p_user uuid, p_date date)
 RETURNS smallint
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case
    when mod(
      pg_catalog.get_byte(pg_catalog.uuid_send(p_user), 0)
      + (p_date - date '2000-01-01'),
      5
    ) = 0 then 1
    else 2
  end::smallint;
$function$
;

CREATE OR REPLACE FUNCTION private.world_daily_quiz_reward_view_v1(p_reward jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'rewardId', p_reward -> 'rewardId',
    'rewardVersion', p_reward -> 'rewardVersion',
    'rewardTransactionId', p_reward -> 'rewardTransactionId',
    'status', p_reward -> 'status',
    'replayed', p_reward -> 'replayed',
    'completedAt', p_reward -> 'completedAt',
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'grantType', e -> 'grantType', 'targetId', e -> 'targetId', 'requested', e -> 'requested',
        'granted', e -> 'granted', 'status', e -> 'status', 'reason', e -> 'reason') order by x.ord)
      from jsonb_array_elements(p_reward -> 'entries') with ordinality as x(e, ord)), '[]'::jsonb));
$function$
;

CREATE OR REPLACE FUNCTION private.world_daily_quiz_state_v1(p_user uuid, p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_run private.world_daily_quiz_runs%rowtype;
  v_question private.world_daily_quiz_questions%rowtype;
  v_result jsonb;
begin
  v_result := jsonb_build_object(
    'rewardDate', to_char(p_date, 'YYYY-MM-DD'),
    'rewardPreview', coalesce((
      select jsonb_agg(jsonb_build_object('grantType', g.grant_type, 'targetId', g.target_id, 'amount', g.amount)
                       order by g.position)
        from private.world_reward_grants g
        join private.world_reward_definitions d on d.reward_id = g.reward_id
       where g.reward_id = 'reward.daily.campus_quiz' and d.status = 'ACTIVE'), '[]'::jsonb));
  select * into v_run from private.world_daily_quiz_runs r where r.user_id = p_user and r.reward_date = p_date;
  if not found then
    return v_result || jsonb_build_object('status', 'AVAILABLE',
      'progress', jsonb_build_object('answered', 0, 'total', 3, 'correct', 0));
  end if;
  v_result := v_result || jsonb_build_object(
    'status', v_run.status,
    'runId', v_run.run_id,
    'progress', jsonb_build_object('answered', v_run.answered_count, 'total', 3, 'correct', v_run.correct_count),
    'completedAt', v_run.completed_at);
  if v_run.status = 'ACTIVE' then
    select * into v_question from private.world_daily_quiz_questions q
     where q.question_id = v_run.question_ids[v_run.answered_count + 1];
    v_result := v_result || jsonb_build_object('question', jsonb_build_object(
      'questionId', v_question.question_id,
      'index', v_run.answered_count,
      'prompt', v_question.prompt,
      'options', v_question.options));
  end if;
  return v_result;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_daily_quiz_today_v1(p_now timestamp with time zone DEFAULT now())
 RETURNS date
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select (p_now at time zone 'Asia/Seoul')::date;
$function$
;

CREATE OR REPLACE FUNCTION private.world_event_state_v1(p_event private.world_events, p_now timestamp with time zone)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case
    when p_event.event_id is null then null
    when p_event.is_disabled then 'DISABLED'
    when p_now < p_event.starts_at then 'SCHEDULED'
    when p_now < p_event.ends_at then 'ACTIVE'
    else 'ENDED' end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_exp_apply_v1(p_user uuid, p_amount bigint, p_source_type text, p_source_id text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_total bigint;
  v_before_level integer;
  v_after_level integer;
  v_tx private.world_exp_transactions%rowtype;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'INVALID_AMOUNT' using errcode = '22023';
  end if;
  if p_source_type is null or p_source_type !~ '^[a-z][a-z0-9_]{0,31}$'
     or p_source_id is null or char_length(p_source_id) not between 1 and 200 then
    raise exception 'INVALID_SOURCE' using errcode = '22023';
  end if;
  if p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$' then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = '22023';
  end if;
  if not private.world_progression_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  insert into private.world_player_progression(user_id)
  values (p_user)
  on conflict (user_id) do nothing;

  select p.total_exp into strict v_total
    from private.world_player_progression p
   where p.user_id = p_user
   for update;

  select * into v_tx
    from private.world_exp_transactions t
   where t.idempotency_key = p_idempotency_key;
  if found then
    if (v_tx.user_id, v_tx.amount, v_tx.source_type, v_tx.source_id)
       is distinct from (p_user, p_amount, p_source_type, p_source_id) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return private.world_exp_result_v1(v_tx, 'ALREADY_PROCESSED');
  end if;

  if v_total > 9223372036854775807::bigint - p_amount then
    raise exception 'INVALID_AMOUNT' using errcode = '22023';
  end if;

  v_before_level := private.world_level_for_exp_v1(v_total);
  v_after_level := private.world_level_for_exp_v1(v_total + p_amount);

  begin
    insert into private.world_exp_transactions(
      user_id, amount, exp_before, exp_after, level_before, level_after,
      source_type, source_id, idempotency_key)
    values (
      p_user, p_amount, v_total, v_total + p_amount, v_before_level, v_after_level,
      p_source_type, p_source_id, p_idempotency_key)
    returning * into v_tx;
  exception when unique_violation then
    select * into strict v_tx
      from private.world_exp_transactions t
     where t.idempotency_key = p_idempotency_key;
    if (v_tx.user_id, v_tx.amount, v_tx.source_type, v_tx.source_id)
       is distinct from (p_user, p_amount, p_source_type, p_source_id) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return private.world_exp_result_v1(v_tx, 'ALREADY_PROCESSED');
  end;

  update private.world_player_progression p
     set total_exp = v_tx.exp_after,
         version = p.version + 1,
         updated_at = now()
   where p.user_id = p_user;

  return private.world_exp_result_v1(v_tx, 'SUCCESS');
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_exp_result_v1(p_tx private.world_exp_transactions, p_status text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'status', p_status,
    'transactionId', p_tx.transaction_id,
    'userId', p_tx.user_id,
    'amount', p_tx.amount,
    'expBefore', p_tx.exp_before,
    'expAfter', p_tx.exp_after,
    'levelBefore', p_tx.level_before,
    'levelAfter', p_tx.level_after,
    'leveledUp', p_tx.level_after > p_tx.level_before,
    'sourceType', p_tx.source_type,
    'sourceId', p_tx.source_id,
    'idempotencyKey', p_tx.idempotency_key,
    'createdAt', p_tx.created_at
  );
$function$
;

CREATE OR REPLACE FUNCTION private.world_exp_transactions_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  raise exception 'LEDGER_APPEND_ONLY' using errcode = '42501';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_guestbook_entry_json(p_entry_id uuid, p_viewer uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'id', g.id,
    'userId', g.user_id,
    'nickname', p.nickname,
    'avatar', p.avatar_key,
    'inhaVerified',
      exists (
        select 1
        from public.inha_mail_badges b
        where b.user_id = g.user_id
      ),
    'content', g.content,
    'createdAt', g.created_at,
    'updatedAt', g.updated_at,
    'mine', g.user_id = p_viewer
  )
  from public.world_guestbook_entries g
  join public.profiles p on p.user_id = g.user_id and p.is_banned = false
  where g.id = p_entry_id
    and g.is_hidden = false;
$function$
;

CREATE OR REPLACE FUNCTION private.world_guestbook_normalize()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  new.content := btrim(new.content);
  if tg_op = 'UPDATE' then
    new.updated_at := now();
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_inventory_account_ok_v1(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select p_user is not null and exists (select 1 from public.sessions s where s.id = p_user::text);
$function$
;

CREATE OR REPLACE FUNCTION private.world_inventory_consume_result_v1(p_consumption private.world_item_consumptions, p_status text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'status', p_status,
    'consumeId', p_consumption.consume_id,
    'userId', p_consumption.user_id,
    'itemId', p_consumption.item_id,
    'quantityBefore', p_consumption.quantity_before,
    'quantityConsumed', p_consumption.quantity_consumed,
    'quantityAfter', p_consumption.quantity_after,
    'ownedAfter', p_consumption.quantity_after > 0,
    'sourceType', p_consumption.source_type,
    'sourceRef', p_consumption.source_ref,
    'parentMutationId', p_consumption.parent_mutation_id,
    'consumedAt', p_consumption.created_at
  );
$function$
;

CREATE OR REPLACE FUNCTION private.world_inventory_consume_v1(p_user uuid, p_item_id text, p_quantity integer, p_source_type text, p_source_ref text, p_idempotency_key text, p_parent_mutation_id uuid DEFAULT NULL::uuid, p_metadata jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_catalog private.world_item_catalog%rowtype;
  v_owned private.world_player_items%rowtype;
  v_consumption private.world_item_consumptions%rowtype;
  v_after integer;
begin
  if p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$' then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = '22023';
  end if;
  if p_item_id is null or p_item_id !~ '^[a-z][a-z0-9_]*\.[a-z0-9_]+$'
     or char_length(p_item_id) > 80 then
    raise exception 'INVALID_ITEM_ID' using errcode = '22023';
  end if;
  if p_quantity is null or p_quantity < 1 then
    raise exception 'INVALID_QUANTITY' using errcode = '22023';
  end if;
  if p_source_type is null or p_source_type not in (
       'DEFAULT','QUEST','EXPLORATION','ACHIEVEMENT','EVENT','MINIGAME','SHOP','INHAGAME_REWARD',
       'ACTIVITY','CRAFTING','EQUIPMENT','RESEARCH','SYSTEM','ADMIN')
     or p_source_ref is null or char_length(p_source_ref) not between 1 and 200 then
    raise exception 'INVALID_SOURCE' using errcode = '22023';
  end if;
  if p_metadata is not null and (jsonb_typeof(p_metadata) <> 'object'
      or octet_length(p_metadata::text) > 2048) then
    raise exception 'INVALID_METADATA' using errcode = '22023';
  end if;
  if not private.world_inventory_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('world_inventory:' || p_user::text, 0));

  select * into v_consumption
    from private.world_item_consumptions c
   where c.consume_id = p_idempotency_key;
  if found then
    if (v_consumption.user_id, v_consumption.item_id, v_consumption.quantity_requested,
        v_consumption.source_type, v_consumption.source_ref, v_consumption.parent_mutation_id)
       is distinct from
       (p_user, p_item_id, p_quantity, p_source_type, p_source_ref, p_parent_mutation_id) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return private.world_inventory_consume_result_v1(v_consumption, 'ALREADY_PROCESSED');
  end if;

  select * into v_catalog
    from private.world_item_catalog c
   where c.item_id = p_item_id;
  if not found then
    raise exception 'UNKNOWN_ITEM' using errcode = '22023';
  end if;
  if v_catalog.status in ('DISABLED','HIDDEN') then
    raise exception 'ITEM_UNAVAILABLE' using errcode = 'P0001';
  end if;
  if v_catalog.ownership_policy <> 'STACKABLE' then
    raise exception 'CONSUME_POLICY_UNSUPPORTED' using errcode = 'P0001';
  end if;

  select * into v_owned
    from private.world_player_items i
   where i.user_id = p_user and i.item_id = p_item_id
   for update;
  if not found then
    raise exception 'ITEM_NOT_OWNED' using errcode = 'P0002';
  end if;
  if v_owned.quantity < p_quantity then
    raise exception 'INSUFFICIENT_QUANTITY' using errcode = 'P0001';
  end if;

  v_after := v_owned.quantity - p_quantity;

  begin
    insert into private.world_item_consumptions(
      consume_id, user_id, item_id, quantity_requested, quantity_before,
      quantity_consumed, quantity_after, source_type, source_ref, parent_mutation_id, metadata)
    values (
      p_idempotency_key, p_user, p_item_id, p_quantity, v_owned.quantity,
      p_quantity, v_after, p_source_type, p_source_ref, p_parent_mutation_id, p_metadata)
    returning * into v_consumption;
  exception when unique_violation then
    select * into strict v_consumption
      from private.world_item_consumptions c
     where c.consume_id = p_idempotency_key;
    if (v_consumption.user_id, v_consumption.item_id, v_consumption.quantity_requested,
        v_consumption.source_type, v_consumption.source_ref, v_consumption.parent_mutation_id)
       is distinct from
       (p_user, p_item_id, p_quantity, p_source_type, p_source_ref, p_parent_mutation_id) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return private.world_inventory_consume_result_v1(v_consumption, 'ALREADY_PROCESSED');
  end;

  if v_after = 0 then
    delete from private.world_player_items i where i.id = v_owned.id;
  else
    update private.world_player_items i
       set quantity = v_after,
           updated_at = now()
     where i.id = v_owned.id;
  end if;

  return private.world_inventory_consume_result_v1(v_consumption, 'SUCCESS');
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_inventory_grant_result_v1(p_grant private.world_item_grants, p_status text, p_acquired_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'status', p_status,
    'originalStatus', p_grant.result,
    'grantId', p_grant.grant_id,
    'userId', p_grant.user_id,
    'itemId', p_grant.item_id,
    'quantityBefore', p_grant.quantity_before,
    'quantityGranted', p_grant.quantity_granted,
    'quantityAfter', p_grant.quantity_after,
    'sourceType', p_grant.source_type,
    'sourceRef', p_grant.source_ref,
    'eventId', p_grant.event_id,
    'grantedAt', p_grant.created_at,
    'acquiredAt', p_acquired_at
  );
$function$
;

CREATE OR REPLACE FUNCTION private.world_inventory_grant_v1(p_user uuid, p_item_id text, p_quantity integer, p_source_type text, p_source_ref text, p_idempotency_key text, p_event_id text, p_metadata jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_catalog private.world_item_catalog%rowtype;
  v_grant private.world_item_grants%rowtype;
  v_owned private.world_player_items%rowtype;
  v_before integer;
  v_result text;
begin
  if p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$' then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = '22023';
  end if;
  if p_item_id is null or p_item_id !~ '^[a-z][a-z0-9_]*\.[a-z0-9_]+$' or char_length(p_item_id) > 80 then
    raise exception 'INVALID_ITEM_ID' using errcode = '22023';
  end if;
  if p_quantity is null or p_quantity < 1 then
    raise exception 'INVALID_QUANTITY' using errcode = '22023';
  end if;
  if p_source_type is null or p_source_type not in (
       'DEFAULT', 'QUEST', 'EXPLORATION', 'ACHIEVEMENT', 'EVENT', 'MINIGAME', 'SHOP',
       'INHAGAME_REWARD', 'ACTIVITY', 'CRAFTING', 'EQUIPMENT', 'RESEARCH', 'SYSTEM', 'ADMIN')
     or p_source_ref is null or char_length(p_source_ref) not between 1 and 200 then
    raise exception 'INVALID_SOURCE' using errcode = '22023';
  end if;
  if p_event_id is not null and p_event_id !~ '^[a-z][a-z0-9_]*\.[a-z0-9_]+$' then
    raise exception 'INVALID_EVENT_ID' using errcode = '22023';
  end if;
  if p_metadata is not null and (jsonb_typeof(p_metadata) <> 'object'
       or octet_length(p_metadata::text) > 2048) then
    raise exception 'INVALID_METADATA' using errcode = '22023';
  end if;
  if not private.world_inventory_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('world_inventory:' || p_user::text, 0));

  select * into v_grant from private.world_item_grants g where g.grant_id = p_idempotency_key;
  if found then
    if (v_grant.user_id, v_grant.item_id, v_grant.quantity_requested, v_grant.source_type,
        v_grant.source_ref, v_grant.event_id)
       is distinct from (p_user, p_item_id, p_quantity, p_source_type, p_source_ref, p_event_id) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    select * into v_owned from private.world_player_items i
     where i.user_id = p_user and i.item_id = p_item_id;
    return private.world_inventory_grant_result_v1(v_grant, 'ALREADY_PROCESSED', v_owned.acquired_at);
  end if;

  select * into v_catalog from private.world_item_catalog c where c.item_id = p_item_id;
  if not found then
    raise exception 'UNKNOWN_ITEM' using errcode = '22023';
  end if;
  if v_catalog.status in ('DISABLED', 'HIDDEN') then
    raise exception 'ITEM_UNAVAILABLE' using errcode = 'P0001';
  end if;
  if v_catalog.ownership_policy = 'UNIQUE' and p_quantity <> 1 then
    raise exception 'INVALID_QUANTITY' using errcode = '22023';
  end if;

  select * into v_owned from private.world_player_items i
   where i.user_id = p_user and i.item_id = p_item_id
     for update;
  v_before := coalesce(v_owned.quantity, 0);

  if v_catalog.ownership_policy = 'UNIQUE' and v_before > 0 then
    v_result := 'ALREADY_OWNED';
  else
    if v_catalog.ownership_policy = 'STACKABLE' and v_before + p_quantity > v_catalog.max_stack then
      raise exception 'MAX_STACK_EXCEEDED' using errcode = 'P0001';
    end if;
    v_result := 'GRANTED';
  end if;

  begin
    insert into private.world_item_grants (
      grant_id, user_id, item_id, result, quantity_requested,
      quantity_before, quantity_granted, quantity_after,
      source_type, source_ref, event_id, acquisition_metadata)
    values (
      p_idempotency_key, p_user, p_item_id, v_result, p_quantity,
      v_before, case when v_result = 'GRANTED' then p_quantity else 0 end,
      v_before + case when v_result = 'GRANTED' then p_quantity else 0 end,
      p_source_type, p_source_ref, p_event_id, p_metadata)
    returning * into v_grant;
  exception when unique_violation then
    raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
  end;

  if v_result = 'GRANTED' then
    if v_before = 0 then
      insert into private.world_player_items (
        user_id, item_id, quantity, source_type, source_ref, event_id, grant_id, acquisition_metadata)
      values (
        p_user, p_item_id, p_quantity, p_source_type, p_source_ref, p_event_id, p_idempotency_key, p_metadata)
      returning * into v_owned;
    else
      update private.world_player_items i
         set quantity = v_grant.quantity_after,
             updated_at = now()
       where i.id = v_owned.id
      returning * into v_owned;
    end if;
  end if;

  return private.world_inventory_grant_result_v1(v_grant, v_result, v_owned.acquired_at);
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_inventory_item_json_v1(p_item private.world_player_items, p_catalog_status text, p_server_view boolean)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'itemId', p_item.item_id,
    'quantity', p_item.quantity,
    'acquiredAt', p_item.acquired_at,
    'updatedAt', p_item.updated_at,
    'sourceType', p_item.source_type,
    'sourceRef', p_item.source_ref,
    'eventId', p_item.event_id,
    -- A catalog miss is reported, never dropped: the owned row stays readable.
    'catalogStatus', coalesce(p_catalog_status, 'UNKNOWN_ITEM')
  ) || case when p_server_view then jsonb_build_object(
    'grantId', p_item.grant_id,
    'acquisitionMetadata', p_item.acquisition_metadata) else '{}'::jsonb end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_inventory_mutate_v1(p_user uuid, p_mutation_type text, p_source_type text, p_source_ref text, p_idempotency_key text, p_plan jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_plan jsonb;
  v_mutation private.world_inventory_mutations%rowtype;
  v_catalog private.world_item_catalog%rowtype;
  v_owned private.world_player_items%rowtype;
  v_op jsonb;
  v_child jsonb;
  v_item_id text;
  v_child_key text;
  v_qty integer;
  v_before integer;
  v_pos integer := 0;
  v_child_pos integer := 0;
begin
  if p_mutation_type is null or p_mutation_type not in (
    'CONSUME','CRAFT','PROCESS','COOK','DISASSEMBLE','ENHANCE','RESEARCH','SYSTEM_EXCHANGE'
  ) then
    raise exception 'INVALID_MUTATION' using errcode = '22023';
  end if;
  if p_source_type is null or p_source_type not in (
       'DEFAULT','QUEST','EXPLORATION','ACHIEVEMENT','EVENT','MINIGAME','SHOP','INHAGAME_REWARD',
       'ACTIVITY','CRAFTING','EQUIPMENT','RESEARCH','SYSTEM','ADMIN')
     or p_source_ref is null or char_length(p_source_ref) not between 1 and 200 then
    raise exception 'MUTATION_SOURCE_INVALID' using errcode = '22023';
  end if;
  if p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,159}$' then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = '22023';
  end if;
  if not private.world_inventory_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  v_plan := private.world_inventory_normalize_plan_v1(p_plan);
  if p_mutation_type = 'CONSUME' and jsonb_array_length(v_plan -> 'grants') <> 0 then
    raise exception 'INVALID_MUTATION' using errcode = '22023';
  end if;
  if p_mutation_type <> 'CONSUME' and jsonb_array_length(v_plan -> 'grants') = 0 then
    raise exception 'INVALID_MUTATION' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('world_inventory:' || p_user::text, 0));

  select * into v_mutation
    from private.world_inventory_mutations m
   where m.idempotency_key = p_idempotency_key;
  if found then
    if (v_mutation.user_id, v_mutation.mutation_type, v_mutation.source_type,
        v_mutation.source_ref, v_mutation.plan)
       is distinct from
       (p_user, p_mutation_type, p_source_type, p_source_ref, v_plan) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return private.world_inventory_mutation_receipt_v1(v_mutation, 'ALREADY_PROCESSED');
  end if;

  -- Preflight every input under deterministic item ordering.
  for v_op in
    select value from jsonb_array_elements(v_plan -> 'consumes')
     order by value ->> 'itemId'
  loop
    v_item_id := v_op ->> 'itemId';
    v_qty := (v_op ->> 'quantity')::integer;

    select * into v_catalog from private.world_item_catalog c where c.item_id = v_item_id;
    if not found then raise exception 'INPUT_UNAVAILABLE' using errcode = 'P0001'; end if;
    if v_catalog.status in ('DISABLED','HIDDEN') then
      raise exception 'INPUT_UNAVAILABLE' using errcode = 'P0001';
    end if;
    if v_catalog.ownership_policy <> 'STACKABLE' then
      raise exception 'CONSUME_POLICY_UNSUPPORTED' using errcode = 'P0001';
    end if;

    select * into v_owned
      from private.world_player_items i
     where i.user_id = p_user and i.item_id = v_item_id
     for update;
    if not found or v_owned.quantity < v_qty then
      raise exception 'INSUFFICIENT_QUANTITY' using errcode = 'P0001';
    end if;
  end loop;

  -- Preflight every output before moving any input value.
  for v_op in
    select value from jsonb_array_elements(v_plan -> 'grants')
     order by value ->> 'itemId'
  loop
    v_item_id := v_op ->> 'itemId';
    v_qty := (v_op ->> 'quantity')::integer;

    select * into v_catalog from private.world_item_catalog c where c.item_id = v_item_id;
    if not found or v_catalog.status in ('DISABLED','HIDDEN') then
      raise exception 'OUTPUT_UNAVAILABLE' using errcode = 'P0001';
    end if;
    if v_catalog.ownership_policy = 'UNIQUE' and v_qty <> 1 then
      raise exception 'INVALID_QUANTITY' using errcode = '22023';
    end if;

    select * into v_owned
      from private.world_player_items i
     where i.user_id = p_user and i.item_id = v_item_id
     for update;
    v_before := coalesce(v_owned.quantity, 0);

    if v_catalog.ownership_policy = 'UNIQUE' and v_before > 0 then
      raise exception 'OUTPUT_ALREADY_OWNED' using errcode = 'P0001';
    end if;
    if v_catalog.ownership_policy = 'STACKABLE' and v_before + v_qty > v_catalog.max_stack then
      raise exception 'MAX_STACK_EXCEEDED' using errcode = 'P0001';
    end if;
  end loop;

  insert into private.world_inventory_mutations(
    user_id, mutation_type, source_type, source_ref, idempotency_key, plan)
  values (p_user, p_mutation_type, p_source_type, p_source_ref, p_idempotency_key, v_plan)
  returning * into v_mutation;

  -- Consume inputs first. Any later grant failure rolls the whole transaction back.
  v_child_pos := 0;
  for v_op in
    select value from jsonb_array_elements(v_plan -> 'consumes')
     order by value ->> 'itemId'
  loop
    v_item_id := v_op ->> 'itemId';
    v_qty := (v_op ->> 'quantity')::integer;
    v_child_key := p_idempotency_key || '/consume/' || v_child_pos::text;

    v_child := private.world_inventory_consume_v1(
      p_user, v_item_id, v_qty, p_source_type, p_source_ref, v_child_key,
      v_mutation.mutation_id, jsonb_build_object('mutationType', p_mutation_type));

    insert into private.world_inventory_mutation_entries(
      mutation_id, position, direction, item_id, quantity,
      quantity_before, quantity_after, child_idempotency_key, child_ref)
    values (
      v_mutation.mutation_id, v_pos, 'CONSUME', v_item_id, v_qty,
      (v_child ->> 'quantityBefore')::integer,
      (v_child ->> 'quantityAfter')::integer,
      v_child_key, v_child ->> 'consumeId');

    v_pos := v_pos + 1;
    v_child_pos := v_child_pos + 1;
  end loop;

  -- Reuse the existing Grant Core for outputs.
  v_child_pos := 0;
  for v_op in
    select value from jsonb_array_elements(v_plan -> 'grants')
     order by value ->> 'itemId'
  loop
    v_item_id := v_op ->> 'itemId';
    v_qty := (v_op ->> 'quantity')::integer;
    v_child_key := p_idempotency_key || '/grant/' || v_child_pos::text;

    v_child := private.world_inventory_grant_v1(
      p_user, v_item_id, v_qty, p_source_type, p_source_ref, v_child_key, null,
      jsonb_build_object('parentMutationId', v_mutation.mutation_id, 'mutationType', p_mutation_type));

    if v_child ->> 'originalStatus' <> 'GRANTED' then
      raise exception 'OUTPUT_UNAVAILABLE' using errcode = 'P0001';
    end if;

    insert into private.world_inventory_mutation_entries(
      mutation_id, position, direction, item_id, quantity,
      quantity_before, quantity_after, child_idempotency_key, child_ref)
    values (
      v_mutation.mutation_id, v_pos, 'GRANT', v_item_id, v_qty,
      (v_child ->> 'quantityBefore')::integer,
      (v_child ->> 'quantityAfter')::integer,
      v_child_key, v_child ->> 'grantId');

    v_pos := v_pos + 1;
    v_child_pos := v_child_pos + 1;
  end loop;

  return private.world_inventory_mutation_receipt_v1(v_mutation, 'SUCCESS');
exception when unique_violation then
  select * into v_mutation
    from private.world_inventory_mutations m
   where m.idempotency_key = p_idempotency_key;
  if found
     and (v_mutation.user_id, v_mutation.mutation_type, v_mutation.source_type,
          v_mutation.source_ref, v_mutation.plan)
         is not distinct from
         (p_user, p_mutation_type, p_source_type, p_source_ref, v_plan) then
    return private.world_inventory_mutation_receipt_v1(v_mutation, 'ALREADY_PROCESSED');
  end if;
  raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_inventory_mutation_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  raise exception 'INVENTORY_MUTATION_APPEND_ONLY' using errcode = '42501';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_inventory_mutation_receipt_v1(p_mutation private.world_inventory_mutations, p_status text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'status', p_status,
    'replayed', p_status = 'ALREADY_PROCESSED',
    'mutationId', p_mutation.mutation_id,
    'userId', p_mutation.user_id,
    'mutationType', p_mutation.mutation_type,
    'sourceType', p_mutation.source_type,
    'sourceRef', p_mutation.source_ref,
    'idempotencyKey', p_mutation.idempotency_key,
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'position', e.position,
        'direction', e.direction,
        'itemId', e.item_id,
        'quantity', e.quantity,
        'quantityBefore', e.quantity_before,
        'quantityAfter', e.quantity_after,
        'ownedAfter', e.quantity_after > 0,
        'childIdempotencyKey', e.child_idempotency_key,
        'childRef', e.child_ref
      ) order by e.position)
      from private.world_inventory_mutation_entries e
      where e.mutation_id = p_mutation.mutation_id
    ), '[]'::jsonb),
    'createdAt', p_mutation.created_at
  );
$function$
;

CREATE OR REPLACE FUNCTION private.world_inventory_normalize_plan_v1(p_plan jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare
  v_consumes jsonb;
  v_grants jsonb;
  v_normal_consumes jsonb;
  v_normal_grants jsonb;
begin
  if p_plan is null or jsonb_typeof(p_plan) <> 'object' then
    raise exception 'INVALID_MUTATION_PLAN' using errcode = '22023';
  end if;

  if exists (
    select 1
      from jsonb_object_keys(p_plan) as keys(key)
     where keys.key not in ('consumes','grants')
  ) then
    raise exception 'INVALID_MUTATION_PLAN' using errcode = '22023';
  end if;

  v_consumes := coalesce(p_plan -> 'consumes', '[]'::jsonb);
  v_grants := coalesce(p_plan -> 'grants', '[]'::jsonb);

  if jsonb_typeof(v_consumes) <> 'array'
     or jsonb_typeof(v_grants) <> 'array'
     or jsonb_array_length(v_consumes) < 1
     or jsonb_array_length(v_consumes) > 16
     or jsonb_array_length(v_grants) > 16 then
    raise exception 'INVALID_MUTATION_PLAN' using errcode = '22023';
  end if;

  if exists (
    select 1
      from jsonb_array_elements(v_consumes) as e(value)
     where jsonb_typeof(e.value) <> 'object'
  ) or exists (
    select 1
      from jsonb_array_elements(v_grants) as e(value)
     where jsonb_typeof(e.value) <> 'object'
  ) then
    raise exception 'INVALID_MUTATION_PLAN' using errcode = '22023';
  end if;

  if exists (
    select 1
      from jsonb_array_elements(v_consumes) as e(value)
     where exists (
       select 1
         from jsonb_object_keys(e.value) as keys(key)
        where keys.key not in ('itemId','quantity')
     )
        or coalesce(e.value ->> 'itemId','') !~ '^[a-z][a-z0-9_]*\.[a-z0-9_]+$'
        or char_length(coalesce(e.value ->> 'itemId','')) > 80
        or coalesce(e.value ->> 'quantity','') !~ '^[1-9][0-9]{0,8}$'
  ) or exists (
    select 1
      from jsonb_array_elements(v_grants) as e(value)
     where exists (
       select 1
         from jsonb_object_keys(e.value) as keys(key)
        where keys.key not in ('itemId','quantity')
     )
        or coalesce(e.value ->> 'itemId','') !~ '^[a-z][a-z0-9_]*\.[a-z0-9_]+$'
        or char_length(coalesce(e.value ->> 'itemId','')) > 80
        or coalesce(e.value ->> 'quantity','') !~ '^[1-9][0-9]{0,8}$'
  ) then
    raise exception 'INVALID_MUTATION_PLAN' using errcode = '22023';
  end if;

  if exists (
    select 1
      from jsonb_array_elements(v_consumes) as e(value)
     group by e.value ->> 'itemId'
    having count(*) > 1
  ) or exists (
    select 1
      from jsonb_array_elements(v_grants) as e(value)
     group by e.value ->> 'itemId'
    having count(*) > 1
  ) then
    raise exception 'DUPLICATE_MUTATION_ITEM' using errcode = '22023';
  end if;

  if exists (
    select 1
      from jsonb_array_elements(v_consumes) as c(value)
      join jsonb_array_elements(v_grants) as g(value)
        on c.value ->> 'itemId' = g.value ->> 'itemId'
  ) then
    raise exception 'MUTATION_ITEM_OVERLAP' using errcode = '22023';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'itemId', e.value ->> 'itemId',
        'quantity', (e.value ->> 'quantity')::integer
      )
      order by e.value ->> 'itemId'
    ),
    '[]'::jsonb
  )
    into v_normal_consumes
    from jsonb_array_elements(v_consumes) as e(value);

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'itemId', e.value ->> 'itemId',
        'quantity', (e.value ->> 'quantity')::integer
      )
      order by e.value ->> 'itemId'
    ),
    '[]'::jsonb
  )
    into v_normal_grants
    from jsonb_array_elements(v_grants) as e(value);

  return jsonb_build_object(
    'consumes', v_normal_consumes,
    'grants', v_normal_grants
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_item_grants_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  raise exception 'GRANT_LOG_APPEND_ONLY' using errcode = '42501';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_jeongseok_access_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
  v_now timestamptz := now();
  v_gate text;
  v_verified boolean;
  v_pass private.world_jeongseok_pass_entitlements%rowtype;
  v_product private.world_jeongseok_pass_catalog%rowtype;
  v_balance bigint;
  v_pass_json jsonb := null;
  v_offer jsonb := null;
  v_decision text;
  v_via text := null;
begin
  select g.status into v_gate from private.world_jeongseok_gate_policy g where g.singleton;
  if v_gate is distinct from 'ACTIVE' then
    -- Closed gate: no identity, price or pass detail leaves the server.
    return jsonb_build_object('version',1,'decision',coalesce(v_gate,'DISABLED'),'granted',false,'via',null,
      'gateStatus',coalesce(v_gate,'DISABLED'),'serverNow',v_now,'userId',null,'inhaMailVerified',null,'pass',null,'offer',null);
  end if;
  if v_uid is null then
    return jsonb_build_object('version',1,'decision','AUTH_REQUIRED','granted',false,'via',null,
      'gateStatus',v_gate,'serverNow',v_now,'userId',null,'inhaMailVerified',null,'pass',null,'offer',null);
  end if;
  if not private.world_wallet_account_ok_v1(v_uid) then
    return jsonb_build_object('version',1,'decision','ACCOUNT_BLOCKED','granted',false,'via',null,
      'gateStatus',v_gate,'serverNow',v_now,'userId',v_uid,'inhaMailVerified',null,'pass',null,'offer',null);
  end if;

  -- The existing Hub authority; mailbox ownership only.
  v_verified := public.my_inha_mail_badge(v_uid);
  select * into v_pass from private.world_jeongseok_pass_entitlements e where e.user_id = v_uid;
  if found then
    v_pass_json := jsonb_build_object('passType',v_pass.pass_type,'issuedAt',v_pass.issued_at,
      'expiresAt',v_pass.expires_at,'active',v_now < v_pass.expires_at,'purchaseId',v_pass.last_purchase_id);
  end if;

  if v_verified then
    v_decision := 'GRANTED'; v_via := 'INHA_MAIL';
  elsif v_pass.user_id is not null and v_now < v_pass.expires_at then
    v_decision := 'GRANTED'; v_via := 'VISITOR_PASS';
  else
    v_decision := case when v_pass.user_id is null then 'NEEDS_PASS' else 'EXPIRED' end;
    select * into v_product from private.world_jeongseok_pass_catalog c where c.pass_type = 'jeongseok.visitor.day';
    if found and v_product.status = 'ACTIVE' then
      select w.balance into v_balance from private.world_wallets w
       where w.user_id = v_uid and w.currency_id = v_product.currency_id;
      v_balance := coalesce(v_balance, 0);
      v_offer := jsonb_build_object('status','ACTIVE','passType',v_product.pass_type,'price',v_product.price,
        'currencyId',v_product.currency_id,'durationSeconds',v_product.duration_seconds,'balance',v_balance,
        'canPurchase',v_balance >= v_product.price,'shortfall',greatest(v_product.price - v_balance, 0));
    else
      -- An unreleased or paused product never exposes its candidate price.
      v_offer := jsonb_build_object('status',coalesce(v_product.status,'DISABLED'),'passType',null,'price',null,
        'currencyId',null,'durationSeconds',null,'balance',null,'canPurchase',false,'shortfall',null);
    end if;
  end if;

  return jsonb_build_object('version',1,'decision',v_decision,'granted',v_decision = 'GRANTED','via',v_via,
    'gateStatus',v_gate,'serverNow',v_now,'userId',v_uid,'inhaMailVerified',v_verified,'pass',v_pass_json,'offer',v_offer);
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_jeongseok_pass_purchase_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'DELETE' and not exists (select 1 from public.sessions s where s.id = old.user_id::text) then return old; end if;
  raise exception 'JEONGSEOK_PASS_RECEIPT_APPEND_ONLY' using errcode = '42501';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_jeongseok_purchase_result_v1(p_purchase_id uuid, p_replayed boolean)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object('status', case when p_replayed then 'ALREADY_PROCESSED' else 'SUCCESS' end,
    'purchaseId',p.purchase_id,'userId',p.user_id,'passType',p.pass_type,'currencyId',p.currency_id,
    'price',p.price,'balanceBefore',p.balance_before,'balanceAfter',p.balance_after,
    'issuedAt',p.issued_at,'expiresAt',p.expires_at,'walletTransactionId',p.wallet_transaction_id,
    'idempotencyKey',p.idempotency_key,'access',private.world_jeongseok_access_v1(p.user_id))
  from private.world_jeongseok_pass_purchases p where p.purchase_id = p_purchase_id;
$function$
;

CREATE OR REPLACE FUNCTION private.world_landlord_pick_survivor_v1()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_byte integer;
begin
  loop
    v_byte := get_byte(extensions.gen_random_bytes(1), 0);
    exit when v_byte < 255;
  end loop;
  return (array['ZUE-MG-001', 'ZUE-MG-002', 'ZUE-MG-003', 'ZUE-MG-004', 'ZUE-MG-005'])[v_byte % 5 + 1];
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_level_for_exp_v1(p_total_exp bigint)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_level integer;
begin
  if p_total_exp is null or p_total_exp < 0 then
    raise exception 'INVALID_TOTAL_EXP' using errcode = '22023';
  end if;

  select t.level into v_level
    from private.world_level_thresholds t
   where t.min_total_exp <= p_total_exp
   order by t.level desc
   limit 1;

  if v_level is null then
    raise exception 'PROGRESSION_CONFIG_INVALID' using errcode = 'P0001';
  end if;
  return v_level;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_level_thresholds_immutable_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  raise exception 'PROGRESSION_CONFIG_IMMUTABLE' using errcode = '42501';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_level_thresholds_validate_insert_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_max_level integer;
  v_max_exp bigint;
begin
  select max(t.level), max(t.min_total_exp)
    into v_max_level, v_max_exp
    from private.world_level_thresholds t;

  if v_max_level is null then
    if new.level <> 1 or new.min_total_exp <> 0 then
      raise exception 'PROGRESSION_CONFIG_INVALID' using errcode = '23514';
    end if;
  elsif new.level <> v_max_level + 1 or new.min_total_exp <= v_max_exp then
    raise exception 'PROGRESSION_CONFIG_INVALID' using errcode = '23514';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_book_skill_view_v1(p_user uuid, p_skill_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_skill jsonb := private.world_life_skill_snapshot_v1(p_user,p_skill_id);
  v_sp jsonb := private.world_life_skill_sp_snapshot_v1(p_user,p_skill_id);
begin
  return jsonb_build_object(
    'skillId',p_skill_id,
    'level',v_skill->'level',
    'totalXp',v_skill->'totalXp',
    'currentLevelStartXp',v_skill->'currentLevelStartXp',
    'nextLevelXp',v_skill->'nextLevelXp',
    'maxDefinedLevel',v_skill->'maxDefinedLevel',
    'isMaxLevel',v_skill->'isMaxLevel',
    'sp',jsonb_build_object(
      'earned',v_sp->'earnedSp',
      'spent',v_sp->'spentSp',
      'available',v_sp->'availableSp',
      'nextLevelEarned',v_sp->'nextLevelEarnedSp'
    )
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_book_tree_view_v1(p_user uuid, p_skill_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_skill jsonb := private.world_life_book_skill_view_v1(p_user,p_skill_id);
  v_reset jsonb := private.world_life_tree_reset_state_v1(p_user,p_skill_id);
  v_life_level integer := (private.world_life_progression_snapshot_v1(p_user)->>'level')::integer;
  v_skill_level integer := (v_skill->>'level')::integer;
  v_available integer := (v_skill->'sp'->>'available')::integer;
  v_spent integer := (v_skill->'sp'->>'spent')::integer;
  v_nodes jsonb;
begin
  -- Same order of checks as world_life_node_unlock_v1, so the hint matches the authority.
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'nodeId',x.node_id,
             'rank',x.rank,
             'maxRank',x.max_rank,
             'nextRankCost',case when x.rank >= x.max_rank then null else x.sp_cost end,
             'requiredSkillLevel',x.required_skill_level,
             'prerequisites',x.prerequisites,
             'canUnlock',x.lock_reason is null,
             'lockReason',x.lock_reason)
           order by x.node_id),'[]'::jsonb)
    into v_nodes
    from (
      select n.node_id,n.max_rank,n.sp_cost,n.required_skill_level,r.rank,p.prerequisites,
             case
               when r.rank >= n.max_rank then 'MAX_RANK'
               when not p.all_met then 'PREREQUISITE'
               when v_life_level < n.required_life_level then 'LIFE_LEVEL'
               when v_skill_level < n.required_skill_level then 'SKILL_LEVEL'
               when v_available < n.sp_cost then 'SP'
               else null
             end as lock_reason
        from private.world_life_skill_tree_catalog n
        cross join lateral (
          select private.world_life_node_rank_v1(p_user,n.node_id) as rank
        ) r
        cross join lateral (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'nodeId',e.prerequisite_node_id,
                   'requiredRank',e.required_rank,
                   'visible',pn.status = 'ACTIVE',
                   'met',private.world_life_node_rank_v1(p_user,e.prerequisite_node_id) >= e.required_rank)
                   order by e.prerequisite_node_id),'[]'::jsonb) as prerequisites,
                 coalesce(bool_and(private.world_life_node_rank_v1(p_user,e.prerequisite_node_id) >= e.required_rank),true)
                   as all_met
            from private.world_life_skill_tree_edges e
            join private.world_life_skill_tree_catalog pn on pn.node_id = e.prerequisite_node_id
           where e.node_id = n.node_id
        ) p
       where n.skill_id = p_skill_id
         and n.status = 'ACTIVE'
    ) x;

  return jsonb_build_object(
    'skill',v_skill,
    'reset',jsonb_build_object(
      'cost',0,
      'cooldownSeconds',v_reset->'cooldownSeconds',
      'lastResetAt',v_reset->'lastResetAt',
      'nextResetAt',v_reset->'nextResetAt',
      'canReset',v_spent > 0 and v_reset->>'nextResetAt' is null,
      'resetBlockedBy',case
        when v_spent = 0 then 'EMPTY'
        when v_reset->>'nextResetAt' is not null then 'COOLDOWN'
        else null end
    ),
    'nodes',v_nodes
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_book_visible_skill_v1(p_skill_id text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_skill_id is null or not exists (
    select 1 from private.world_life_skill_catalog s
     where s.skill_id = p_skill_id and s.status = 'ACTIVE'
  ) then
    raise exception 'LIFE_SKILL_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_caller_v1(p_user uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
begin
  if v_uid is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;
  if not private.world_life_skill_account_ok_v1(v_uid) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '42501';
  end if;
  return v_uid;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_node_rank_v1(p_user uuid, p_node_id text)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(max(p.rank),0)::integer
    from private.world_player_life_nodes p
    join private.world_life_skill_tree_catalog n on n.node_id = p.node_id
   where p.user_id = p_user
     and p.node_id = p_node_id
     and p.epoch = private.world_life_tree_epoch_v1(p_user,n.skill_id);
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_node_unlock_v1(p_user uuid, p_node_id text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_node private.world_life_skill_tree_catalog%rowtype;
  v_skill private.world_life_skill_catalog%rowtype;
  v_existing private.world_life_sp_transactions%rowtype;
  v_tx private.world_life_sp_transactions%rowtype;
  v_progress jsonb;
  v_sp jsonb;
  v_life_level integer;
  v_skill_level integer;
  v_available integer;
  v_rank_before integer;
  v_epoch integer;
begin
  if p_node_id is null
     or p_node_id !~ '^life\.node\.[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'
     or char_length(p_node_id) > 120 then
    raise exception 'INVALID_LIFE_NODE_ID' using errcode = '22023';
  end if;
  if p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$' then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = '22023';
  end if;
  if not private.world_life_skill_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('world_life:' || p_user::text,0));

  -- Exact replay returns the committed rank, even if the node was disabled or the tree reset since.
  select * into v_existing
    from private.world_life_sp_transactions t
   where t.idempotency_key = p_idempotency_key;
  if found then
    if (v_existing.user_id,v_existing.node_id) is distinct from (p_user,p_node_id) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return jsonb_build_object(
      'status','ALREADY_PROCESSED',
      'transactionId',v_existing.transaction_id,
      'nodeId',v_existing.node_id,
      'skillId',v_existing.skill_id,
      'rankAfter',v_existing.rank,
      'epoch',v_existing.epoch,
      'sp',private.world_life_skill_sp_snapshot_v1(p_user,v_existing.skill_id)
    );
  end if;

  select * into v_node
    from private.world_life_skill_tree_catalog n
   where n.node_id = p_node_id;
  if not found then
    raise exception 'LIFE_NODE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_node.status <> 'ACTIVE' then
    raise exception 'LIFE_NODE_INACTIVE' using errcode = 'P0001';
  end if;

  select * into strict v_skill
    from private.world_life_skill_catalog s
   where s.skill_id = v_node.skill_id;
  if v_skill.status <> 'ACTIVE' then
    raise exception 'LIFE_SKILL_INACTIVE' using errcode = 'P0001';
  end if;

  v_epoch := private.world_life_tree_epoch_v1(p_user,v_node.skill_id);
  v_rank_before := private.world_life_node_rank_v1(p_user,p_node_id);
  if v_rank_before >= v_node.max_rank then
    raise exception 'LIFE_NODE_MAX_RANK' using errcode = '23505';
  end if;

  if exists (
    select 1
      from private.world_life_skill_tree_edges e
     where e.node_id = p_node_id
       and private.world_life_node_rank_v1(p_user,e.prerequisite_node_id) < e.required_rank
  ) then
    raise exception 'LIFE_NODE_PREREQUISITE_LOCKED' using errcode = 'P0001';
  end if;

  v_progress := private.world_life_progression_snapshot_v1(p_user);
  v_sp := private.world_life_skill_sp_snapshot_v1(p_user,v_node.skill_id);
  v_life_level := (v_progress->>'level')::integer;
  v_skill_level := (v_sp->>'skillLevel')::integer;
  v_available := (v_sp->>'availableSp')::integer;

  if v_life_level < v_node.required_life_level then
    raise exception 'LIFE_LEVEL_REQUIRED' using errcode = 'P0001';
  end if;
  if v_skill_level < v_node.required_skill_level then
    raise exception 'LIFE_SKILL_LEVEL_REQUIRED' using errcode = 'P0001';
  end if;
  if v_available < v_node.sp_cost then
    raise exception 'LIFE_SP_INSUFFICIENT' using errcode = 'P0001';
  end if;

  insert into private.world_life_sp_transactions(
    user_id,skill_id,node_id,rank,epoch,sp_cost,sp_before,sp_after,idempotency_key)
  values (
    p_user,v_node.skill_id,p_node_id,v_rank_before + 1,v_epoch,v_node.sp_cost,v_available,
    v_available-v_node.sp_cost,p_idempotency_key)
  returning * into v_tx;

  insert into private.world_player_life_nodes(user_id,node_id,epoch,rank,transaction_id)
  values (p_user,p_node_id,v_epoch,v_tx.rank,v_tx.transaction_id);

  return jsonb_build_object(
    'status','SUCCESS',
    'transactionId',v_tx.transaction_id,
    'nodeId',v_tx.node_id,
    'skillId',v_tx.skill_id,
    'epoch',v_epoch,
    'rankBefore',v_rank_before,
    'rankAfter',v_tx.rank,
    'maxRank',v_node.max_rank,
    'spCost',v_tx.sp_cost,
    'spBefore',v_tx.sp_before,
    'spAfter',v_tx.sp_after,
    'sp',private.world_life_skill_sp_snapshot_v1(p_user,v_node.skill_id),
    'tree',private.world_life_skill_tree_snapshot_v1(p_user,v_node.skill_id)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_nodes_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'DELETE' and not exists (select 1 from public.sessions s where s.id = old.user_id::text) then return old; end if;
  raise exception 'LIFE_NODE_APPEND_ONLY' using errcode = '42501';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_progression_snapshot_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_curve constant text := 'life.progression.v1';
  v_total bigint;
  v_level integer;
  v_start bigint;
  v_next bigint;
  v_max integer;
begin
  if not private.world_life_skill_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  v_total := private.world_life_progression_total_skill_xp_v1(p_user);

  select t.level,t.min_total_skill_xp
    into v_level,v_start
    from private.world_life_progression_thresholds t
   where t.curve_id = v_curve
     and t.min_total_skill_xp <= v_total
   order by t.level desc
   limit 1;
  if v_level is null then
    raise exception 'LIFE_PROGRESSION_CURVE_INVALID' using errcode = 'P0001';
  end if;

  select t.min_total_skill_xp into v_next
    from private.world_life_progression_thresholds t
   where t.curve_id = v_curve and t.level = v_level + 1;

  select max(t.level) into v_max
    from private.world_life_progression_thresholds t
   where t.curve_id = v_curve;

  return jsonb_build_object(
    'curveId',v_curve,
    'totalSkillXp',v_total,
    'level',v_level,
    'currentLevelStartXp',v_start,
    'nextLevelXp',v_next,
    'progressXp',v_total-v_start,
    'progressRequired',case when v_next is null then null else v_next-v_start end,
    'maxDefinedLevel',v_max,
    'isMaxLevel',v_next is null
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_progression_threshold_immutable_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  raise exception 'LIFE_PROGRESSION_CURVE_IMMUTABLE' using errcode = '42501';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_progression_threshold_validate_insert_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_max_level integer;
  v_max_xp bigint;
begin
  -- Per-skill pools (Authority Map 7.1): SP is earned only from per-skill curves.
  if new.cumulative_sp <> 0 then
    raise exception 'LIFE_PROGRESSION_CURVE_INVALID' using errcode = '23514';
  end if;

  select max(t.level), max(t.min_total_skill_xp)
    into v_max_level, v_max_xp
    from private.world_life_progression_thresholds t
   where t.curve_id = new.curve_id;

  if v_max_level is null then
    if new.level <> 1 or new.min_total_skill_xp <> 0 then
      raise exception 'LIFE_PROGRESSION_CURVE_INVALID' using errcode = '23514';
    end if;
  elsif new.level <> v_max_level + 1
     or new.min_total_skill_xp <= v_max_xp then
    raise exception 'LIFE_PROGRESSION_CURVE_INVALID' using errcode = '23514';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_progression_total_skill_xp_v1(p_user uuid)
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(sum(p.total_xp),0)::bigint
    from private.world_player_life_skills p
   where p.user_id = p_user;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_skill_account_ok_v1(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select p_user is not null and exists (select 1 from public.sessions s where s.id = p_user::text);
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_skill_level_for_xp_v1(p_curve_id text, p_total_xp bigint)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_level integer;
begin
  if p_curve_id is null
     or p_curve_id !~ '^life\.[a-z][a-z0-9_]*\.v[0-9]+$'
     or char_length(p_curve_id) > 80 then
    raise exception 'INVALID_LIFE_SKILL_CURVE' using errcode = '22023';
  end if;
  if p_total_xp is null or p_total_xp < 0 then
    raise exception 'INVALID_TOTAL_XP' using errcode = '22023';
  end if;

  select t.level into v_level
    from private.world_life_skill_thresholds t
   where t.curve_id = p_curve_id
     and t.min_total_xp <= p_total_xp
   order by t.level desc
   limit 1;

  if v_level is null then
    raise exception 'LIFE_SKILL_CURVE_INVALID' using errcode = 'P0001';
  end if;
  return v_level;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_skill_snapshot_v1(p_user uuid, p_skill_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_skill private.world_life_skill_catalog%rowtype;
  v_total bigint := 0;
  v_version bigint := 0;
  v_level integer;
  v_start bigint;
  v_next bigint;
  v_max integer;
begin
  select * into v_skill
    from private.world_life_skill_catalog s
   where s.skill_id = p_skill_id;
  if not found then
    raise exception 'LIFE_SKILL_NOT_FOUND' using errcode = 'P0002';
  end if;

  select p.total_xp,p.version
    into v_total,v_version
    from private.world_player_life_skills p
   where p.user_id = p_user
     and p.skill_id = p_skill_id;
  v_total := coalesce(v_total,0);
  v_version := coalesce(v_version,0);

  v_level := private.world_life_skill_level_for_xp_v1(v_skill.curve_id,v_total);
  select t.min_total_xp into strict v_start
    from private.world_life_skill_thresholds t
   where t.curve_id = v_skill.curve_id and t.level = v_level;
  select t.min_total_xp into v_next
    from private.world_life_skill_thresholds t
   where t.curve_id = v_skill.curve_id and t.level = v_level + 1;
  select max(t.level) into v_max
    from private.world_life_skill_thresholds t
   where t.curve_id = v_skill.curve_id;

  return jsonb_build_object(
    'skillId', v_skill.skill_id,
    'curveId', v_skill.curve_id,
    'status', v_skill.status,
    'totalXp', v_total,
    'level', v_level,
    'version', v_version,
    'currentLevelStartXp', v_start,
    'nextLevelXp', v_next,
    'progressXp', v_total - v_start,
    'progressRequired', case when v_next is null then null else v_next - v_start end,
    'maxDefinedLevel', v_max,
    'isMaxLevel', v_next is null
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_skill_sp_snapshot_v1(p_user uuid, p_skill_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_skill jsonb;
  v_level integer;
  v_earned integer;
  v_next integer;
  v_spent integer;
  v_epoch integer;
begin
  if not private.world_life_skill_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  v_skill := private.world_life_skill_snapshot_v1(p_user,p_skill_id);
  v_level := (v_skill->>'level')::integer;
  v_epoch := private.world_life_tree_epoch_v1(p_user,p_skill_id);

  select t.cumulative_sp into strict v_earned
    from private.world_life_skill_thresholds t
   where t.curve_id = v_skill->>'curveId'
     and t.level = v_level;
  select t.cumulative_sp into v_next
    from private.world_life_skill_thresholds t
   where t.curve_id = v_skill->>'curveId'
     and t.level = v_level + 1;

  select coalesce(sum(s.sp_cost),0)::integer into v_spent
    from private.world_life_sp_transactions s
   where s.user_id = p_user
     and s.skill_id = p_skill_id
     and s.epoch = v_epoch;

  if v_spent > v_earned then
    raise exception 'LIFE_SP_LEDGER_INVALID' using errcode = 'P0001';
  end if;

  return jsonb_build_object(
    'skillId',p_skill_id,
    'curveId',v_skill->>'curveId',
    'skillLevel',v_level,
    'earnedSp',v_earned,
    'spentSp',v_spent,
    'availableSp',v_earned - v_spent,
    'nextLevelEarnedSp',v_next
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_skill_threshold_immutable_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  raise exception 'LIFE_SKILL_CURVE_IMMUTABLE' using errcode = '42501';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_skill_threshold_validate_insert_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_max_level integer;
  v_max_xp bigint;
  v_max_sp integer;
begin
  select max(t.level), max(t.min_total_xp), max(t.cumulative_sp)
    into v_max_level, v_max_xp, v_max_sp
    from private.world_life_skill_thresholds t
   where t.curve_id = new.curve_id;

  if v_max_level is null then
    if new.level <> 1 or new.min_total_xp <> 0 or new.cumulative_sp <> 0 then
      raise exception 'LIFE_SKILL_CURVE_INVALID' using errcode = '23514';
    end if;
  elsif new.level <> v_max_level + 1
     or new.min_total_xp <= v_max_xp
     or new.cumulative_sp < v_max_sp then
    raise exception 'LIFE_SKILL_CURVE_INVALID' using errcode = '23514';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_skill_tree_snapshot_v1(p_user uuid, p_skill_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_skill private.world_life_skill_catalog%rowtype;
begin
  if not private.world_life_skill_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  select * into v_skill
    from private.world_life_skill_catalog s
   where s.skill_id = p_skill_id;
  if not found then
    raise exception 'LIFE_SKILL_NOT_FOUND' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'skillId',p_skill_id,
    'sp',private.world_life_skill_sp_snapshot_v1(p_user,p_skill_id),
    'reset',private.world_life_tree_reset_state_v1(p_user,p_skill_id),
    'nodes',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'nodeId',n.node_id,
          'status',n.status,
          'spCost',n.sp_cost,
          'maxRank',n.max_rank,
          'rank',private.world_life_node_rank_v1(p_user,n.node_id),
          'requiredLifeLevel',n.required_life_level,
          'requiredSkillLevel',n.required_skill_level,
          'prerequisites',coalesce((
            select jsonb_agg(
              jsonb_build_object('nodeId',e.prerequisite_node_id,'requiredRank',e.required_rank)
              order by e.prerequisite_node_id)
              from private.world_life_skill_tree_edges e
             where e.node_id = n.node_id
          ),'[]'::jsonb)
        )
        order by n.node_id
      )
      from private.world_life_skill_tree_catalog n
      where n.skill_id = p_skill_id
    ),'[]'::jsonb)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_sp_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'DELETE' and not exists (select 1 from public.sessions s where s.id = old.user_id::text) then return old; end if;
  raise exception 'LIFE_SP_APPEND_ONLY' using errcode = '42501';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_tree_edge_validate_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_node private.world_life_skill_tree_catalog%rowtype;
  v_prerequisite private.world_life_skill_tree_catalog%rowtype;
begin
  if tg_op <> 'INSERT' then
    raise exception 'LIFE_TREE_DEFINITION_IMMUTABLE' using errcode = '42501';
  end if;
  select * into strict v_node
    from private.world_life_skill_tree_catalog n where n.node_id = new.node_id;
  select * into strict v_prerequisite
    from private.world_life_skill_tree_catalog n where n.node_id = new.prerequisite_node_id;
  if v_node.skill_id <> v_prerequisite.skill_id
     or new.required_rank > v_prerequisite.max_rank then
    raise exception 'LIFE_TREE_EDGE_INVALID' using errcode = '23514';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_tree_epoch_v1(p_user uuid, p_skill_id text)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(max(r.epoch),0)::integer
    from private.world_life_tree_resets r
   where r.user_id = p_user and r.skill_id = p_skill_id;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_tree_node_guard_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'DELETE'
     or (new.node_id,new.skill_id,new.sp_cost,new.required_life_level,new.required_skill_level,new.max_rank)
        is distinct from
        (old.node_id,old.skill_id,old.sp_cost,old.required_life_level,old.required_skill_level,old.max_rank) then
    raise exception 'LIFE_TREE_DEFINITION_IMMUTABLE' using errcode = '42501';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_tree_reset_state_v1(p_user uuid, p_skill_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_cooldown integer;
  v_last timestamptz;
  v_next timestamptz;
begin
  select p.cooldown_seconds into strict v_cooldown
    from private.world_life_tree_reset_policy p
   where p.policy_id = 'life.tree_reset.v1';
  select max(r.created_at) into v_last
    from private.world_life_tree_resets r
   where r.user_id = p_user and r.skill_id = p_skill_id;
  v_next := v_last + make_interval(secs => v_cooldown);
  return jsonb_build_object(
    'epoch',private.world_life_tree_epoch_v1(p_user,p_skill_id),
    'cooldownSeconds',v_cooldown,
    'lastResetAt',v_last,
    'nextResetAt',case when v_next is null or v_next <= now() then null else v_next end,
    'cost',0
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_tree_reset_v1(p_user uuid, p_skill_id text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_existing private.world_life_tree_resets%rowtype;
  v_reset private.world_life_tree_resets%rowtype;
  v_epoch integer;
  v_cooldown integer;
  v_last timestamptz;
  v_refund integer;
  v_cleared jsonb;
begin
  if p_skill_id is null
     or p_skill_id !~ '^life\.[a-z][a-z0-9_]*$'
     or char_length(p_skill_id) > 80 then
    raise exception 'INVALID_LIFE_SKILL_ID' using errcode = '22023';
  end if;
  if p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$' then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = '22023';
  end if;
  if not private.world_life_skill_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('world_life:' || p_user::text,0));

  select * into v_existing
    from private.world_life_tree_resets r
   where r.idempotency_key = p_idempotency_key;
  if found then
    if (v_existing.user_id,v_existing.skill_id) is distinct from (p_user,p_skill_id) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return jsonb_build_object(
      'status','ALREADY_PROCESSED',
      'resetId',v_existing.reset_id,
      'skillId',v_existing.skill_id,
      'epoch',v_existing.epoch,
      'refundedSp',v_existing.refunded_sp,
      'clearedRanks',v_existing.cleared_ranks,
      'sp',private.world_life_skill_sp_snapshot_v1(p_user,p_skill_id),
      'reset',private.world_life_tree_reset_state_v1(p_user,p_skill_id)
    );
  end if;

  -- A reset works whatever the skill's or nodes' status: a disabled tree must still refund.
  if not exists (select 1 from private.world_life_skill_catalog s where s.skill_id = p_skill_id) then
    raise exception 'LIFE_SKILL_NOT_FOUND' using errcode = 'P0002';
  end if;

  v_epoch := private.world_life_tree_epoch_v1(p_user,p_skill_id);

  select coalesce(sum(s.sp_cost),0)::integer into v_refund
    from private.world_life_sp_transactions s
   where s.user_id = p_user and s.skill_id = p_skill_id and s.epoch = v_epoch;
  if v_refund = 0 then
    raise exception 'LIFE_TREE_RESET_EMPTY' using errcode = 'P0001';
  end if;

  select p.cooldown_seconds into strict v_cooldown
    from private.world_life_tree_reset_policy p
   where p.policy_id = 'life.tree_reset.v1';
  select max(r.created_at) into v_last
    from private.world_life_tree_resets r
   where r.user_id = p_user and r.skill_id = p_skill_id;
  if v_last is not null and now() < v_last + make_interval(secs => v_cooldown) then
    raise exception 'LIFE_TREE_RESET_COOLDOWN' using errcode = 'P0001';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('nodeId',x.node_id,'rank',x.rank) order by x.node_id),'[]'::jsonb)
    into v_cleared
    from (
      select p.node_id,max(p.rank) as rank
        from private.world_player_life_nodes p
        join private.world_life_skill_tree_catalog n on n.node_id = p.node_id
       where p.user_id = p_user and n.skill_id = p_skill_id and p.epoch = v_epoch
       group by p.node_id
    ) x;

  insert into private.world_life_tree_resets(
    user_id,skill_id,epoch,refunded_sp,cleared_ranks,cooldown_seconds,idempotency_key)
  values (
    p_user,p_skill_id,v_epoch + 1,v_refund,v_cleared,v_cooldown,p_idempotency_key)
  returning * into v_reset;

  return jsonb_build_object(
    'status','SUCCESS',
    'resetId',v_reset.reset_id,
    'skillId',p_skill_id,
    'epochBefore',v_epoch,
    'epoch',v_reset.epoch,
    'refundedSp',v_reset.refunded_sp,
    'clearedRanks',v_reset.cleared_ranks,
    'cost',0,
    'sp',private.world_life_skill_sp_snapshot_v1(p_user,p_skill_id),
    'reset',private.world_life_tree_reset_state_v1(p_user,p_skill_id)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_life_tree_resets_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  -- Account deletion cascades remove the account's whole history; nothing else may.
  if tg_op = 'DELETE' and not exists (select 1 from public.sessions s where s.id = old.user_id::text) then return old; end if;
  raise exception 'LIFE_TREE_RESET_APPEND_ONLY' using errcode = '42501';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_lock_pair(p_a uuid, p_b uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select pg_advisory_xact_lock(hashtextextended('world_pair:' || least(p_a, p_b)::text || ':' || greatest(p_a, p_b)::text, 0));
$function$
;

CREATE OR REPLACE FUNCTION private.world_mcm_account_ok_v1(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select p_user is not null and exists (select 1 from public.sessions s where s.id = p_user::text);
$function$
;

CREATE OR REPLACE FUNCTION private.world_mcm_claim_result_v1(p_claim_type text, p_status text, p_replayed boolean, p_reward_transaction_id uuid, p_claimed_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'claimType', p_claim_type,
    'status', p_status,
    'replayed', p_replayed,
    'rewardId', t.reward_id,
    'rewardStatus', t.status,
    'rewardTransactionId', t.reward_transaction_id,
    'claimedAt', p_claimed_at,
    'rewardResult', jsonb_build_object(
      'status', t.status,
      'completedAt', t.completed_at,
      'entries', coalesce((
        select jsonb_agg(jsonb_build_object(
          'grantType', e.grant_type,
          'targetId', e.target_id,
          'requested', e.requested,
          'granted', e.granted,
          'status', e.status,
          'reason', e.reason) order by e.position)
        from private.world_reward_transaction_entries e
        where e.reward_transaction_id = t.reward_transaction_id), '[]'::jsonb)))
  from private.world_reward_transactions t
  where t.reward_transaction_id = p_reward_transaction_id;
$function$
;

CREATE OR REPLACE FUNCTION private.world_mcm_claim_reward_v1(p_user uuid, p_claim_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_reward_id text;
  v_source_type text;
  v_source_id text;
  v_key text;
  v_source_at timestamptz;
  v_claim private.world_mcm_reward_claims%rowtype;
  v_reward jsonb;
begin
  if p_claim_type = 'MAIN_CLEAR' then
    v_reward_id := 'reward.event.mcm_2026_main_clear';
    v_source_type := 'EVENT';
    v_source_id := 'event.mcm_2026:main_clear';
    v_key := 'event:mcm_2026:' || p_user::text || ':main_clear';
  elsif p_claim_type = 'LANDLORD_FIRST_CLEAR' then
    v_reward_id := 'reward.minigame.landlord_first_clear';
    v_source_type := 'MINIGAME';
    v_source_id := 'event.mcm_2026:landlord_first_clear';
    v_key := 'minigame:landlord:' || p_user::text || ':first_clear';
  else
    raise exception 'INVALID_CLAIM_TYPE' using errcode = '22023';
  end if;

  -- One claim decision per account at a time; concurrent calls wait, then see the final claim.
  perform pg_advisory_xact_lock(hashtextextended('world_mcm_claim:' || p_user::text, 0));

  select * into v_claim from private.world_mcm_reward_claims c
   where c.user_id = p_user and c.claim_type = p_claim_type;
  if found then
    return private.world_mcm_claim_result_v1(
      p_claim_type, 'ALREADY_CLAIMED', true, v_claim.reward_transaction_id, v_claim.claimed_at);
  end if;

  -- Eligibility comes only from the server-verified completion records (never from client state).
  if p_claim_type = 'MAIN_CLEAR' then
    select p.completed_at into v_source_at from private.world_event_progress p
     where p.user_id = p_user and p.event_id = 'event.mcm_2026' and p.stage = 3;
  else
    select c.first_cleared_at into v_source_at from private.world_landlord_first_clears c
     where c.user_id = p_user and c.event_id = 'event.mcm_2026';
  end if;
  if v_source_at is null then
    raise exception 'CLAIM_NOT_ELIGIBLE' using errcode = 'P0001';
  end if;

  -- P0-C executes (or replays / resumes) the reward; its grants come from the RewardDefinition.
  v_reward := private.world_reward_grant_v1(p_user, v_reward_id, v_source_type, v_source_id, v_key);

  if coalesce(v_reward ->> 'status', 'FAILED') not in ('SUCCESS', 'PARTIAL_SUCCESS') then
    -- Not final: commit P0-C's resumable FAILED state, keep completion, no claim row.
    return private.world_mcm_claim_result_v1(
      p_claim_type, 'REWARD_FAILED', false, (v_reward ->> 'rewardTransactionId')::uuid, null);
  end if;

  insert into private.world_mcm_reward_claims (
    user_id, claim_type, event_id, reward_id, idempotency_key, reward_transaction_id, reward_status,
    source_completed_at)
  values (
    p_user, p_claim_type, 'event.mcm_2026', v_reward_id, v_key, (v_reward ->> 'rewardTransactionId')::uuid,
    v_reward ->> 'status', v_source_at)
  returning * into v_claim;

  -- replayed = true when P0-C returned a stored result (the reward ran before the claim was
  -- finalized): the claim is recovered and no value moved in this call.
  return private.world_mcm_claim_result_v1(
    p_claim_type, 'CLAIMED', coalesce((v_reward ->> 'replayed')::boolean, false),
    v_claim.reward_transaction_id, v_claim.claimed_at);
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_mcm_reward_claims_final_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  raise exception 'CLAIM_FINAL' using errcode = '42501';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_mcm_state_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'eventId', ev.event_id,
    'eventState', private.world_event_state_v1(ev, now()),
    'startsAt', ev.starts_at,
    'endsAt', ev.ends_at,
    'serverNow', now(),
    'progress', jsonb_build_object(
      'stage', case coalesce(p.stage, 0) when 0 then 'NOT_STARTED' when 1 then 'STARTED'
                 when 2 then 'VENUE_UNLOCKED' else 'COMPLETED' end,
      'investigated', coalesce(to_jsonb(p.investigated), '[]'::jsonb),
      'startedAt', p.started_at,
      'venueUnlockedAt', p.venue_unlocked_at,
      'completedAt', p.completed_at),
    'landlord', jsonb_build_object(
      'firstClearedAt', c.first_cleared_at,
      'activeRun', (select jsonb_build_object('runId', r.run_id, 'startedAt', r.started_at,
                      'deadlineAt', r.deadline_at, 'wrongCount', r.wrong_count)
                      from private.world_landlord_runs r
                     where r.user_id = p_user and r.status = 'ACTIVE' and r.deadline_at > now())))
  from private.world_events ev
  left join private.world_event_progress p on p.user_id = p_user and p.event_id = ev.event_id
  left join private.world_landlord_first_clears c on c.user_id = p_user and c.event_id = ev.event_id
  where ev.event_id = 'event.mcm_2026';
$function$
;

CREATE OR REPLACE FUNCTION private.world_mcm_try_complete_v1(p_user uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update private.world_event_progress e
     set stage = 3, completed_at = now(), updated_at = now()
   where e.user_id = p_user and e.event_id = 'event.mcm_2026' and e.stage = 2
     and exists (select 1 from private.world_landlord_first_clears c
                  where c.user_id = p_user and c.event_id = 'event.mcm_2026');
$function$
;

CREATE OR REPLACE FUNCTION private.world_personal_room_json_v1(p_room world_player_rooms)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'roomId', p_room.id,
    'ownerUserId', p_room.owner_user_id,
    'roomType', p_room.room_type,
    'visibility', p_room.visibility,
    'createdAt', p_room.created_at,
    'updatedAt', p_room.updated_at
  );
$function$
;

CREATE OR REPLACE FUNCTION private.world_player_level_v1(p_user uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select private.world_level_for_exp_v1(coalesce(
    (select p.total_exp from private.world_player_progression p where p.user_id = p_user), 0));
$function$
;

CREATE OR REPLACE FUNCTION private.world_progression_account_ok_v1(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select p_user is not null and exists (select 1 from public.sessions s where s.id = p_user::text);
$function$
;

CREATE OR REPLACE FUNCTION private.world_progression_snapshot_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_total bigint := 0;
  v_level integer;
  v_start bigint;
  v_next bigint;
  v_max integer;
begin
  select p.total_exp into v_total
    from private.world_player_progression p
   where p.user_id = p_user;
  v_total := coalesce(v_total, 0);

  v_level := private.world_level_for_exp_v1(v_total);
  select t.min_total_exp into strict v_start
    from private.world_level_thresholds t where t.level = v_level;
  select t.min_total_exp into v_next
    from private.world_level_thresholds t where t.level = v_level + 1;
  select max(t.level) into v_max from private.world_level_thresholds t;

  if v_max is null then
    raise exception 'PROGRESSION_CONFIG_INVALID' using errcode = 'P0001';
  end if;

  return jsonb_build_object(
    'userId', p_user,
    'totalExp', v_total,
    'level', v_level,
    'currentLevelStartExp', v_start,
    'nextLevelExp', v_next,
    'progressExp', v_total - v_start,
    'progressRequired', case when v_next is null then null else v_next - v_start end,
    'maxDefinedLevel', v_max,
    'isMaxLevel', v_next is null
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_purchase_result_v1(p_purchase_id uuid, p_replayed boolean)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'status', 'SUCCESS',
    'replayed', p_replayed,
    'purchaseId', p.purchase_id,
    'shopId', p.shop_id,
    'listingId', p.listing_id,
    'idempotencyKey', p.idempotency_key,
    'item', jsonb_build_object(
      'itemId', p.item_id,
      'quantity', p.quantity,
      'grantId', p.inventory_grant_id,
      'acquiredAt', (select i.acquired_at from private.world_player_items i
                      where i.user_id = p.user_id and i.item_id = p.item_id)),
    'wallet', jsonb_build_object(
      'currencyId', p.currency_id,
      'price', p.price,
      'balanceBefore', p.balance_before,
      'balanceAfter', p.balance_after,
      'transactionId', p.wallet_transaction_id),
    'createdAt', p.created_at)
  from private.world_purchase_transactions p
  where p.purchase_id = p_purchase_id;
$function$
;

CREATE OR REPLACE FUNCTION private.world_purchase_transactions_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  raise exception 'PURCHASE_APPEND_ONLY' using errcode = '42501';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_recipe_receipt_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'DELETE' and not exists (select 1 from public.sessions s where s.id = old.user_id::text) then return old; end if;
  raise exception 'RECIPE_RECEIPT_APPEND_ONLY' using errcode = '42501';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_relationship(p_caller uuid, p_target uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case
    when exists (select 1 from public.world_user_blocks b where b.blocker_id = p_caller and b.blocked_id = p_target) then 'blocked_by_me'
    when exists (select 1 from public.world_user_blocks b where b.blocker_id = p_target and b.blocked_id = p_caller) then 'unavailable'
    else coalesce((
      select case when f.status = 'accepted' then 'friends'
                  when f.requested_by = p_caller then 'outgoing'
                  else 'incoming' end
      from public.world_friendships f
      where f.user_low = least(p_caller, p_target) and f.user_high = greatest(p_caller, p_target)
    ), 'none')
  end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_reward_final_rows_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if old.status <> 'FAILED' then
    raise exception 'REWARD_RESULT_FINAL' using errcode = '42501';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_reward_grant_v1(p_user uuid, p_reward_id text, p_source_type text, p_source_id text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_def private.world_reward_definitions%rowtype;
  v_tx private.world_reward_transactions%rowtype;
  v_entry private.world_reward_transaction_entries%rowtype;
  v_child jsonb;
  v_child_status text;
  v_status text;
  v_granted bigint;
  v_reason text;
  v_child_tx text;
  v_final text;
begin
  -- Structural preflight: nothing is written if any of these fail.
  if p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,119}$' then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = '22023';
  end if;
  if p_source_type is null or p_source_type not in (
       'QUEST', 'EXPLORATION', 'ACHIEVEMENT', 'EVENT', 'MINIGAME', 'INHAGAME_REWARD', 'SYSTEM', 'ADMIN')
     or p_source_id is null or char_length(p_source_id) not between 1 and 200 then
    raise exception 'INVALID_SOURCE' using errcode = '22023';
  end if;
  if p_reward_id is null then
    raise exception 'UNKNOWN_REWARD' using errcode = '22023';
  end if;
  if not private.world_inventory_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  -- One reward execution per account at a time; a concurrent retry waits, then replays.
  perform pg_advisory_xact_lock(hashtextextended('world_reward:' || p_user::text, 0));

  select * into v_tx from private.world_reward_transactions t where t.idempotency_key = p_idempotency_key;
  if found then
    if (v_tx.user_id, v_tx.reward_id, v_tx.source_type, v_tx.source_id)
       is distinct from (p_user, p_reward_id, p_source_type, p_source_id) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    if v_tx.status <> 'FAILED' then
      return private.world_reward_result_v1(v_tx.reward_transaction_id, true);
    end if;
    -- Resume a FAILED execution from its own snapshot, not from today's definition.
    update private.world_reward_transactions t
       set attempts = t.attempts + 1, updated_at = now()
     where t.reward_transaction_id = v_tx.reward_transaction_id
    returning * into v_tx;
  else
    select * into v_def from private.world_reward_definitions d where d.reward_id = p_reward_id;
    if not found then
      raise exception 'UNKNOWN_REWARD' using errcode = '22023';
    end if;
    if v_def.status <> 'ACTIVE' then
      raise exception 'REWARD_INACTIVE' using errcode = 'P0001';
    end if;
    if not exists (select 1 from private.world_reward_grants g where g.reward_id = p_reward_id) then
      raise exception 'REWARD_EMPTY' using errcode = 'P0001';
    end if;
    if exists (select 1 from private.world_reward_grants g
                where g.reward_id = p_reward_id and g.grant_type not in ('CURRENCY', 'ITEM', 'EXP')) then
      raise exception 'REWARD_UNSUPPORTED_GRANT' using errcode = 'P0001';
    end if;

    begin
      -- Inserted as FAILED (not final) and settled below in this same transaction.
      insert into private.world_reward_transactions (
        user_id, reward_id, reward_version, event_id, source_type, source_id, idempotency_key, status)
      values (
        p_user, p_reward_id, v_def.version, v_def.event_id, p_source_type, p_source_id, p_idempotency_key, 'FAILED')
      returning * into v_tx;
    exception when unique_violation then
      -- Same-account retries are resolved above under the lock; this key belongs to another account.
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end;

    insert into private.world_reward_transaction_entries (
      reward_transaction_id, grant_entry_id, position, grant_type, target_id, requested,
      status, reason, child_idempotency_key)
    select v_tx.reward_transaction_id, g.grant_entry_id, g.position, g.grant_type, g.target_id, g.amount,
           'FAILED', 'NOT_ATTEMPTED', 'reward/' || p_idempotency_key || '/' || g.grant_entry_id
      from private.world_reward_grants g
     where g.reward_id = p_reward_id;
  end if;

  for v_entry in
    select * from private.world_reward_transaction_entries e
     where e.reward_transaction_id = v_tx.reward_transaction_id and e.status = 'FAILED'
     order by e.position
  loop
    begin
      if v_entry.grant_type = 'CURRENCY' then
        v_child := private.world_wallet_apply_v1(
          p_user, v_entry.target_id, v_entry.requested, 'REWARD', 'reward',
          v_tx.reward_id || ':' || v_tx.reward_transaction_id::text, v_entry.child_idempotency_key, null);
        v_status := 'GRANTED';
        v_granted := v_entry.requested;
        v_reason := null;
        v_child_tx := v_child ->> 'transactionId';
      elsif v_entry.grant_type = 'ITEM' then
        v_child := private.world_inventory_grant_v1(
          p_user, v_entry.target_id, v_entry.requested::integer, v_tx.source_type, v_tx.reward_id,
          v_entry.child_idempotency_key, v_tx.event_id,
          jsonb_build_object('rewardTransactionId', v_tx.reward_transaction_id, 'sourceId', v_tx.source_id));
        v_child_status := case when v_child ->> 'status' = 'ALREADY_PROCESSED'
                               then v_child ->> 'originalStatus' else v_child ->> 'status' end;
        -- Readback: the item must be owned now, whether granted here or already owned.
        if not exists (select 1 from private.world_player_items i
                        where i.user_id = p_user and i.item_id = v_entry.target_id) then
          raise exception 'ITEM_READBACK_FAILED';
        end if;
        if v_child_status = 'GRANTED' then
          v_status := 'GRANTED';
          v_granted := v_entry.requested;
          v_reason := null;
        else
          v_status := 'SKIPPED';
          v_granted := 0;
          v_reason := 'ALREADY_OWNED';
        end if;
        v_child_tx := v_child ->> 'grantId';

      elsif v_entry.grant_type = 'EXP' then
        v_child := private.world_exp_apply_v1(
          p_user,
          v_entry.requested,
          'reward',
          v_tx.reward_id || ':' || v_tx.reward_transaction_id::text || ':' || v_entry.grant_entry_id,
          v_entry.child_idempotency_key);
        v_child_status := v_child ->> 'status';
        if v_child_status is null
           or v_child_status not in ('SUCCESS', 'ALREADY_PROCESSED')
           or (v_child ->> 'amount')::bigint is distinct from v_entry.requested
           or v_child ->> 'transactionId' is null then
          raise exception 'EXP_READBACK_FAILED';
        end if;
        v_status := 'GRANTED';
        v_granted := v_entry.requested;
        v_reason := null;
        v_child_tx := v_child ->> 'transactionId';

      else
        -- Defensive only: COLLECTION is rejected by preflight before a transaction exists.
        raise exception 'REWARD_UNSUPPORTED_GRANT';
      end if;
    exception when others then
      -- The child call's own writes were rolled back with this subtransaction; siblings stand.
      v_status := 'FAILED';
      v_granted := 0;
      v_reason := left(sqlerrm, 200);
      v_child_tx := null;
    end;

    update private.world_reward_transaction_entries e
       set status = v_status, granted = v_granted, reason = v_reason,
           child_transaction_id = v_child_tx, attempts = e.attempts + 1, updated_at = now()
     where e.reward_transaction_id = v_entry.reward_transaction_id
       and e.grant_entry_id = v_entry.grant_entry_id;
  end loop;

  select case
           when bool_or(e.status = 'FAILED') then 'FAILED'
           when bool_or(e.status = 'SKIPPED') then 'PARTIAL_SUCCESS'
           else 'SUCCESS' end
    into v_final
    from private.world_reward_transaction_entries e
   where e.reward_transaction_id = v_tx.reward_transaction_id;

  update private.world_reward_transactions t
     set status = v_final, updated_at = now(),
         completed_at = case when v_final = 'FAILED' then null else now() end
   where t.reward_transaction_id = v_tx.reward_transaction_id;

  return private.world_reward_result_v1(v_tx.reward_transaction_id, false);
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_reward_grants_validate_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_policy text;
  v_max integer;
begin
  if new.grant_type = 'CURRENCY' then
    if not exists (select 1 from private.world_currencies c where c.currency_id = new.target_id) then
      raise exception 'REWARD_UNKNOWN_CURRENCY' using errcode = '23503';
    end if;
  elsif new.grant_type = 'ITEM' then
    select c.ownership_policy, c.max_stack into v_policy, v_max
      from private.world_item_catalog c where c.item_id = new.target_id;
    if not found then
      raise exception 'REWARD_UNKNOWN_ITEM' using errcode = '23503';
    end if;
    if (v_policy = 'UNIQUE' and new.amount <> 1) or (v_policy = 'STACKABLE' and new.amount > v_max) then
      raise exception 'REWARD_INVALID_QUANTITY' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_reward_result_v1(p_reward_transaction_id uuid, p_replayed boolean)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'rewardTransactionId', t.reward_transaction_id,
    'rewardId', t.reward_id,
    'rewardVersion', t.reward_version,
    'userId', t.user_id,
    'eventId', t.event_id,
    'sourceType', t.source_type,
    'sourceId', t.source_id,
    'idempotencyKey', t.idempotency_key,
    'status', t.status,
    'replayed', p_replayed,
    'attempts', t.attempts,
    'createdAt', t.created_at,
    'completedAt', t.completed_at,
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'grantEntryId', e.grant_entry_id,
        'grantType', e.grant_type,
        'targetId', e.target_id,
        'requested', e.requested,
        'granted', e.granted,
        'status', e.status,
        'reason', e.reason,
        'childIdempotencyKey', e.child_idempotency_key,
        'childTransactionId', e.child_transaction_id,
        'attempts', e.attempts) order by e.position)
      from private.world_reward_transaction_entries e
      where e.reward_transaction_id = t.reward_transaction_id), '[]'::jsonb))
  from private.world_reward_transactions t
  where t.reward_transaction_id = p_reward_transaction_id;
$function$
;

CREATE OR REPLACE FUNCTION private.world_room_access_v1(p_viewer uuid, p_room_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_room public.world_player_rooms%rowtype;
begin
  if p_viewer is null or p_room_id is null then
    return 'DENIED';
  end if;
  -- The viewer must be a permanent, non-banned account (guests never enter a personal room).
  if not exists (
    select 1
      from public.profiles p
     where p.user_id = p_viewer
       and p.is_banned = false
  ) then
    return 'DENIED';
  end if;

  select r.* into v_room from public.world_player_rooms r where r.id = p_room_id;
  if not found then
    return 'DENIED';
  end if;
  if v_room.owner_user_id = p_viewer then
    return 'OWNER';
  end if;
  if not exists (
    select 1 from public.profiles p where p.user_id = v_room.owner_user_id and p.is_banned = false
  ) then
    return 'DENIED';
  end if;
  -- world_relationship checks blocks in both directions before friendship.
  if private.world_relationship(p_viewer, v_room.owner_user_id) <> 'friends' then
    return 'DENIED';
  end if;
  if v_room.visibility <> 'friends' then
    return 'PRIVATE';
  end if;
  -- H3: an owner's "not now" holds for 10 minutes, for this room and this visitor only.
  if exists (
    select 1 from private.world_room_knocks k
     where k.room_id = p_room_id and k.visitor_user_id = p_viewer
       and k.status = 'DECLINED' and k.responded_at > now() - interval '10 minutes'
  ) then
    return 'DECLINED';
  end if;
  -- H3: while the owner is home, only a visitor the owner let in (or who arrived while the owner
  -- was away) may be in the room.
  if private.world_room_owner_present_v1(p_room_id) and not exists (
    select 1 from private.world_room_knocks k
     where k.room_id = p_room_id and k.visitor_user_id = p_viewer
       and k.status in ('ACCEPTED', 'OPEN') and k.created_at > now() - interval '2 hours'
  ) then
    return 'KNOCK_REQUIRED';
  end if;
  return 'VISITOR';
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_room_caller_v1(p_user uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
begin
  if not private.world_inventory_account_ok_v1(v_uid) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '42501';
  end if;
  return v_uid;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_room_furniture_v1()
 RETURNS TABLE(item_id text, width double precision, height double precision, depth double precision, surfaces text[], solid boolean, flat boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select * from (values
    ('furniture.campus_map_poster', .9::float8, .65::float8, .04::float8, array['north','east','south','west'], false, false),
    ('furniture.induck_cushion', .45, .14, .4, array['floor','bed'], true, false),
    ('furniture.dorm_desk_lamp', .22, .45, .22, array['desk','floor'], true, false),
    ('furniture.induck_chair', .6, .65, .65, array['floor'], true, false),
    ('furniture.mini_induck', .22, .28, .22, array['desk','floor'], true, false),
    ('furniture.campus_rug_blue', 2, .02, 1.5, array['floor'], false, true),
    ('furniture.dorm_resident_plate', .6, .22, .04, array['north','east','south','west'], false, false),
    ('furniture.mcm_2026_landlord_figure', .32, .35, .32, array['desk','floor'], true, false),
    ('furniture.mcm_2026_poster', 1, .75, .04, array['north','east','south','west'], false, false),
    ('furniture.dorm_single_sofa', 1.10, .72, .78, array['floor'], true, false),
    ('furniture.dorm_side_table_low', .65, .38, .65, array['floor'], true, false),
    ('furniture.dorm_bookshelf_slim', .75, 1.25, .35, array['floor'], true, false),
    ('furniture.dorm_plant_medium', .55, .80, .55, array['floor'], true, false),
    ('furniture.dorm_monitor', .52, .36, .18, array['desk'], true, false),
    ('furniture.dorm_trophy_shelf', .90, 1.10, .32, array['floor'], true, false),
    ('furniture.study_books_set', .38, .18, .22, array['desk'], true, false),
    ('furniture.cooking_station', 1.00, .90, .65, array['floor'], true, false)
  ) as furniture(item_id, width, height, depth, surfaces, solid, flat);
$function$
;

CREATE OR REPLACE FUNCTION private.world_room_knock_json_v1(p_knock private.world_room_knocks)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'knockId', p_knock.id,
    'roomId', p_knock.room_id,
    'visitorUserId', p_knock.visitor_user_id,
    'status', case when p_knock.status = 'PENDING' and p_knock.expires_at <= now()
                   then 'EXPIRED' else p_knock.status end,
    'createdAt', p_knock.created_at,
    'expiresAt', p_knock.expires_at,
    'respondedAt', p_knock.responded_at
  );
$function$
;

CREATE OR REPLACE FUNCTION private.world_room_owner_present_v1(p_room_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1 from private.world_room_owner_presence p
     where p.room_id = p_room_id and p.seen_at > now() - interval '12 seconds'
  );
$function$
;

CREATE OR REPLACE FUNCTION private.world_shop_listing_block_v2(p_listing private.world_shop_listings, p_now timestamp with time zone, p_player_level integer)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case
    when p_listing.status = 'LOCKED' then 'LISTING_LOCKED'
    when p_listing.status <> 'ACTIVE' then 'LISTING_INACTIVE'
    when p_listing.start_at is not null and p_now < p_listing.start_at then 'LISTING_NOT_STARTED'
    when p_listing.end_at is not null and p_now >= p_listing.end_at then 'LISTING_EXPIRED'
    when p_listing.required_level is not null
         and (p_player_level is null or p_player_level < p_listing.required_level) then 'LEVEL_REQUIRED'
    when not exists (select 1 from private.world_item_catalog c
                      where c.item_id = p_listing.item_id and c.status not in ('DISABLED', 'HIDDEN'))
      then 'ITEM_UNAVAILABLE'
    else null end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_shop_listings_validate_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_policy text;
  v_max integer;
begin
  select c.ownership_policy, c.max_stack into v_policy, v_max
    from private.world_item_catalog c where c.item_id = new.item_id;
  if not found then
    raise exception 'LISTING_UNKNOWN_ITEM' using errcode = '23503';
  end if;
  if (v_policy = 'UNIQUE' and new.quantity <> 1) or (v_policy = 'STACKABLE' and new.quantity > v_max) then
    raise exception 'LISTING_INVALID_QUANTITY' using errcode = '23514';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_social_caller(p_user uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
begin
  if v_uid is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.profiles p
    where p.user_id = v_uid and p.is_banned = false
  ) then
    raise exception 'PROFILE_NOT_FOUND' using errcode = '42501';
  end if;
  if exists (
    select 1
    from private.world_user_moderation_actions a
    where a.target_id = v_uid
      and a.action = 'interaction_restriction_24h'
      and a.ends_at > now()
  ) then
    raise exception 'SOCIAL_RESTRICTED' using errcode = '42501';
  end if;
  return v_uid;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_social_target(p_caller uuid, p_target uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_target is null or p_target = p_caller
     or not exists (select 1 from public.profiles p where p.user_id = p_target and p.is_banned = false) then
    raise exception 'TARGET_UNAVAILABLE' using errcode = '22023';
  end if;
  return p_target;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_wallet_account_ok_v1(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select p_user is not null and exists (select 1 from public.sessions s where s.id = p_user::text);
$function$
;

CREATE OR REPLACE FUNCTION private.world_wallet_apply_v1(p_user uuid, p_currency_id text, p_delta bigint, p_type text, p_source_type text, p_source_id text, p_idempotency_key text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_balance bigint;
  v_tx private.world_currency_transactions%rowtype;
begin
  if p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$' then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = '22023';
  end if;
  if p_source_type is null or p_source_type !~ '^[a-z][a-z0-9_]{0,31}$'
     or p_source_id is null or char_length(p_source_id) not between 1 and 200 then
    raise exception 'INVALID_SOURCE' using errcode = '22023';
  end if;
  if p_reason is not null and char_length(p_reason) not between 1 and 500 then
    raise exception 'INVALID_REASON' using errcode = '22023';
  end if;
  if p_type in ('ADMIN', 'ADJUSTMENT') and p_reason is null then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;
  if p_currency_id is null or not exists (
    select 1 from private.world_currencies c where c.currency_id = p_currency_id
  ) then
    raise exception 'INVALID_CURRENCY' using errcode = '22023';
  end if;
  if not private.world_wallet_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  -- Lazy provisioning, then a row lock that serializes every change to this wallet.
  insert into private.world_wallets (user_id, currency_id)
  values (p_user, p_currency_id)
  on conflict (user_id, currency_id) do nothing;

  select w.balance
    into strict v_balance
    from private.world_wallets w
   where w.user_id = p_user and w.currency_id = p_currency_id
     for update;

  -- Checked under the lock: a concurrent retry waits here and then sees the committed first attempt.
  select * into v_tx
    from private.world_currency_transactions t
   where t.idempotency_key = p_idempotency_key;
  if found then
    if (v_tx.user_id, v_tx.currency_id, v_tx.amount, v_tx.type, v_tx.source_type, v_tx.source_id)
       is distinct from (p_user, p_currency_id, p_delta, p_type, p_source_type, p_source_id) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return private.world_wallet_result_v1(v_tx, 'ALREADY_PROCESSED');
  end if;

  if v_balance + p_delta < 0 then
    raise exception 'INSUFFICIENT_FUNDS' using errcode = 'P0001';
  end if;

  begin
    insert into private.world_currency_transactions (
      user_id, currency_id, type, amount, balance_before, balance_after,
      source_type, source_id, reason, idempotency_key)
    values (
      p_user, p_currency_id, p_type, p_delta, v_balance, v_balance + p_delta,
      p_source_type, p_source_id, p_reason, p_idempotency_key)
    returning * into v_tx;
  exception when unique_violation then
    -- The same key was committed concurrently for another wallet: never apply it twice.
    select * into strict v_tx
      from private.world_currency_transactions t
     where t.idempotency_key = p_idempotency_key;
    if (v_tx.user_id, v_tx.currency_id, v_tx.amount, v_tx.type, v_tx.source_type, v_tx.source_id)
       is distinct from (p_user, p_currency_id, p_delta, p_type, p_source_type, p_source_id) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return private.world_wallet_result_v1(v_tx, 'ALREADY_PROCESSED');
  end;

  update private.world_wallets w
     set balance = v_tx.balance_after,
         version = w.version + 1,
         updated_at = now()
   where w.user_id = p_user and w.currency_id = p_currency_id;

  return private.world_wallet_result_v1(v_tx, 'SUCCESS');
end;
$function$
;

CREATE OR REPLACE FUNCTION private.world_wallet_result_v1(p_tx private.world_currency_transactions, p_status text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'status', p_status,
    'transactionId', p_tx.transaction_id,
    'userId', p_tx.user_id,
    'currencyId', p_tx.currency_id,
    'type', p_tx.type,
    'amount', p_tx.amount,
    'balanceBefore', p_tx.balance_before,
    'balanceAfter', p_tx.balance_after,
    'sourceType', p_tx.source_type,
    'sourceId', p_tx.source_id,
    'idempotencyKey', p_tx.idempotency_key,
    'createdAt', p_tx.created_at
  );
$function$
;

CREATE OR REPLACE FUNCTION public.advance_mcm_2026_event_v1(p_user uuid, p_event text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_event private.world_events%rowtype;
  v_npc text;
begin
  -- Tier 4: no service_role JWT exists; the Worker is the server caller.
  if p_event is null or p_event not in (
       'status', 'start', 'investigate_staggering', 'investigate_dancing', 'investigate_hungry') then
    raise exception 'INVALID_EVENT_ACTION' using errcode = '22023';
  end if;
  if not private.world_mcm_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;
  if p_event = 'status' then
    return private.world_mcm_state_v1(p_user);
  end if;

  select * into v_event from private.world_events where event_id = 'event.mcm_2026';
  if private.world_event_state_v1(v_event, now()) is distinct from 'ACTIVE' then
    raise exception 'EVENT_NOT_ACTIVE' using errcode = 'P0001';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('world_mcm_2026:' || p_user::text, 0));

  if p_event = 'start' then
    insert into private.world_event_progress (user_id, event_id, stage)
    values (p_user, 'event.mcm_2026', 1)
    on conflict (user_id, event_id) do nothing;
  else
    v_npc := substr(p_event, char_length('investigate_') + 1);
    -- Before 'start' there is no row, so an investigation cannot skip ahead.
    update private.world_event_progress e
       set investigated = array(select distinct unnest(e.investigated || array[v_npc]) order by 1),
           updated_at = now()
     where e.user_id = p_user and e.event_id = 'event.mcm_2026' and e.stage = 1
       and not (v_npc = any(e.investigated));
    update private.world_event_progress e
       set stage = 2, venue_unlocked_at = now(), updated_at = now()
     where e.user_id = p_user and e.event_id = 'event.mcm_2026' and e.stage = 1
       and e.investigated @> array['staggering', 'dancing', 'hungry']::text[];
    perform private.world_mcm_try_complete_v1(p_user);
  end if;

  return private.world_mcm_state_v1(p_user);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.answer_my_world_daily_quiz_v1(p_user uuid, p_run_id uuid, p_question_id text, p_answer_index smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.world_daily_quiz_caller_v1(p_user);
  v_today date := private.world_daily_quiz_today_v1();
  v_run private.world_daily_quiz_runs%rowtype;
  v_index smallint;
  v_correct boolean;
  v_status text;
  v_reward jsonb;
  v_result jsonb;
begin
  if p_answer_index is null or p_answer_index not between 0 and 3 then
    raise exception 'INVALID_ANSWER' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('world_daily_quiz:' || v_uid::text, 0));

  -- Another account's run is indistinguishable from a missing one.
  select * into v_run from private.world_daily_quiz_runs r
   where r.run_id = p_run_id and r.user_id = v_uid for update;
  if not found then
    raise exception 'QUIZ_RUN_NOT_FOUND' using errcode = 'P0001';
  end if;
  if v_run.reward_date <> v_today then
    raise exception 'QUIZ_RUN_EXPIRED' using errcode = 'P0001';
  end if;
  if v_run.status <> 'ACTIVE' then
    raise exception 'QUIZ_ALREADY_ANSWERED' using errcode = 'P0001';
  end if;
  v_index := v_run.answered_count;
  if p_question_id is distinct from v_run.question_ids[v_index + 1] then
    if p_question_id = any (v_run.question_ids[1:v_index]) then
      raise exception 'QUIZ_ALREADY_ANSWERED' using errcode = 'P0001';
    end if;
    raise exception 'QUIZ_QUESTION_MISMATCH' using errcode = 'P0001';
  end if;

  select q.correct_index = p_answer_index into v_correct
    from private.world_daily_quiz_questions q where q.question_id = p_question_id;
  insert into private.world_daily_quiz_answers (run_id, question_index, question_id, selected_index, correct)
  values (v_run.run_id, v_index, p_question_id, p_answer_index, v_correct);

  v_run.answered_count := v_index + 1;
  v_run.correct_count := v_run.correct_count + case when v_correct then 1 else 0 end;
  v_status := case when v_run.answered_count < 3 then 'ACTIVE'
                   when v_run.correct_count >= 2 then 'PASSED' else 'FAILED' end;

  if v_status = 'PASSED' then
    -- Same transaction as the last answer and the PASSED status: a failed reward rolls all back.
    v_reward := private.world_reward_grant_v1(
      v_uid, 'reward.daily.campus_quiz', 'MINIGAME', 'daily.campus_quiz',
      'daily:campus_quiz:' || v_uid::text || ':' || to_char(v_run.reward_date, 'YYYY-MM-DD'));
    if coalesce(v_reward ->> 'status', 'FAILED') not in ('SUCCESS', 'PARTIAL_SUCCESS') then
      raise exception 'QUIZ_REWARD_FAILED' using errcode = 'P0001';
    end if;
  end if;

  update private.world_daily_quiz_runs r
     set answered_count = v_run.answered_count,
         correct_count = v_run.correct_count,
         status = v_status,
         completed_at = case when v_status = 'ACTIVE' then null else now() end,
         reward_transaction_id = case when v_status = 'PASSED' then (v_reward ->> 'rewardTransactionId')::uuid end
   where r.run_id = v_run.run_id;

  v_result := private.world_daily_quiz_state_v1(v_uid, v_today)
    || jsonb_build_object('lastAnswer', jsonb_build_object(
         'questionId', p_question_id, 'index', v_index, 'selectedIndex', p_answer_index, 'correct', v_correct));
  if v_reward is not null then
    v_result := v_result || jsonb_build_object('reward', private.world_daily_quiz_reward_view_v1(v_reward));
  end if;
  return v_result;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.block_world_user(p_user uuid, p_target uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_caller uuid := private.world_social_caller(p_user);
begin
  -- Blocking a banned or missing account is refused like any unavailable target.
  perform private.world_social_target(v_caller, p_target);
  perform private.world_lock_pair(v_caller, p_target);
  insert into public.world_user_blocks (blocker_id, blocked_id) values (v_caller, p_target)
  on conflict (blocker_id, blocked_id) do nothing;
  delete from public.world_friendships f
   where f.user_low = least(v_caller, p_target) and f.user_high = greatest(v_caller, p_target);
  return jsonb_build_object('userId', p_target, 'relationship', 'blocked_by_me');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.cancel_world_friend_request(p_user uuid, p_target uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_caller uuid := private.world_social_caller(p_user);
begin
  perform private.world_social_target(v_caller, p_target);
  perform private.world_lock_pair(v_caller, p_target);
  delete from public.world_friendships f
   where f.user_low = least(v_caller, p_target) and f.user_high = greatest(v_caller, p_target)
     and f.status = 'pending' and f.requested_by = v_caller;
  return jsonb_build_object('userId', p_target, 'relationship', private.world_relationship(v_caller, p_target));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.claim_my_mcm_2026_main_reward_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
begin
  if v_uid is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;
  if not private.world_mcm_account_ok_v1(v_uid) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '42501';
  end if;
  return private.world_mcm_claim_reward_v1(v_uid, 'MAIN_CLEAR');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.claim_my_mcm_landlord_first_clear_reward_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
begin
  if v_uid is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;
  if not private.world_mcm_account_ok_v1(v_uid) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '42501';
  end if;
  return private.world_mcm_claim_reward_v1(v_uid, 'LANDLORD_FIRST_CLEAR');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.claim_my_world_attendance_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.world_attendance_caller_v1(p_user);
begin
  return private.world_attendance_claim_v1(v_uid, private.world_attendance_today_v1());
end;
$function$
;

CREATE OR REPLACE FUNCTION public.cook_my_world_recipe_v1(p_user uuid, p_recipe_id text, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := private.world_room_caller_v1(p_user);
  v_recipe private.world_recipe_catalog%rowtype;
  v_previous private.world_recipe_receipts%rowtype;
  v_room public.world_player_rooms%rowtype;
  v_layout private.world_room_layouts%rowtype;
  v_mutation jsonb; v_receipt jsonb;
begin
  -- Also check the stored account, not only claims. This guard applies to historical replay too.
  if not private.world_inventory_account_ok_v1(v_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '42501';
  end if;
  if p_request_id is null or p_recipe_id is null or p_recipe_id !~ '^recipe\.[a-z0-9_]+$'
     or length(p_recipe_id) > 80 then raise exception 'INVALID_RECIPE_REQUEST' using errcode = '22023'; end if;
  -- Lock order: Inventory account -> room -> layout -> station ownership -> Inventory item rows.
  -- Housing save locks room -> layout, and only reads Inventory without a row/advisory lock.
  -- It never waits on the Inventory account/item lock, so the two paths have no lock cycle.
  perform pg_advisory_xact_lock(hashtextextended('world_inventory:' || v_user::text,0));
  select * into v_previous from private.world_recipe_receipts where user_id=v_user and request_id=p_request_id;
  if found then
    if v_previous.recipe_id <> p_recipe_id then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return v_previous.receipt;
  end if;
  select * into v_recipe from private.world_recipe_catalog where recipe_id=p_recipe_id for share;
  if not found or v_recipe.status <> 'ACTIVE' or v_recipe.mutation_type <> 'COOK'
    or v_recipe.required_capability <> 'COOKING_STATION' or v_recipe.required_item_id <> 'furniture.cooking_station' then
    raise exception 'RECIPE_UNAVAILABLE' using errcode = 'P0001';
  end if;
  select * into v_room from public.world_player_rooms where owner_user_id=v_user and room_type='DORM_1_BASIC' for update;
  if not found then raise exception 'COOKING_STATION_REQUIRED' using errcode = '42501'; end if;
  select * into v_layout from private.world_room_layouts where room_id=v_room.id for update;
  if not found or not exists (select 1 from jsonb_array_elements(v_layout.objects) o
    where o->>'itemId'=v_recipe.required_item_id and o->>'surface'='floor') then
    raise exception 'COOKING_STATION_REQUIRED' using errcode = '42501';
  end if;
  perform 1 from private.world_player_items i join private.world_item_catalog c on c.item_id=i.item_id
    where i.user_id=v_user and i.item_id=v_recipe.required_item_id and i.quantity>0
      and c.category='FURNITURE' and c.status not in ('DISABLED','HIDDEN') for share of i,c;
  if not found then raise exception 'COOKING_STATION_REQUIRED' using errcode = '42501'; end if;
  v_mutation := private.world_inventory_mutate_v1(v_user,'COOK','CRAFTING',v_recipe.recipe_id,
    'recipe:' || v_user::text || ':' || p_request_id::text,v_recipe.plan);
  v_receipt := jsonb_build_object('status','SUCCESS','recipeId',v_recipe.recipe_id,'requestId',p_request_id,
    'userId',v_user,'roomId',v_room.id,'layoutRevision',v_layout.revision,'definitionVersion',v_recipe.definition_version,
    'inventory',v_mutation);
  insert into private.world_recipe_receipts(user_id,request_id,recipe_id,receipt)
    values(v_user,p_request_id,v_recipe.recipe_id,v_receipt);
  return v_receipt;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_world_guestbook_entry_v2(p_user uuid, p_content text, p_location_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.world_social_caller(p_user);
  v_content text := btrim(coalesce(p_content, ''));
  v_daily_used integer := 0;
  v_latest timestamptz;
  v_row public.world_guestbook_entries%rowtype;
begin
  if p_location_key <> 'main_gate' then
    raise exception 'INVALID_LOCATION' using errcode = '22023';
  end if;
  if char_length(v_content) < 1 or char_length(v_content) > 150 then
    raise exception 'INVALID_CONTENT' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_uid::text || ':' || p_location_key, 0)
  );

  select count(*)::integer
  into v_daily_used
  from private.world_guestbook_post_log l
  where l.user_id = v_uid
    and l.location_key = p_location_key
    and (l.created_at at time zone 'Asia/Seoul')::date =
        (now() at time zone 'Asia/Seoul')::date;

  select max(l.created_at)
  into v_latest
  from private.world_guestbook_post_log l
  where l.user_id = v_uid
    and l.location_key = p_location_key;

  if v_daily_used >= 3 then
    raise exception 'DAILY_LIMIT_REACHED' using errcode = 'P0001';
  end if;
  if v_latest is not null and v_latest > now() - interval '60 seconds' then
    raise exception 'GUESTBOOK_COOLDOWN' using errcode = 'P0001';
  end if;

  insert into public.world_guestbook_entries (user_id, location_key, content)
  values (v_uid, p_location_key, v_content)
  returning * into v_row;

  insert into private.world_guestbook_post_log (entry_id, user_id, location_key, created_at)
  values (v_row.id, v_uid, p_location_key, v_row.created_at);

  return private.world_guestbook_entry_json(v_row.id, v_uid);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.delete_world_guestbook_entry_v2(p_user uuid, p_entry_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.world_social_caller(p_user);
begin
  delete from public.world_guestbook_entries g
  where g.id = p_entry_id
    and g.user_id = v_uid;

  if not found then
    raise exception 'ENTRY_UNAVAILABLE' using errcode = '22023';
  end if;

  return true;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.end_world_accompany(p_user uuid, p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_caller uuid := private.world_social_caller(p_user);
begin
  update public.world_accompany_sessions s set state = 'ended', ended_at = now(), ended_reason = 'participant'
   where s.id = p_session_id and (s.inviter_id = v_caller or s.invitee_id = v_caller)
     and s.state in ('offered', 'active');
  if not found and not exists (select 1 from public.world_accompany_sessions s
    where s.id = p_session_id and (s.inviter_id = v_caller or s.invitee_id = v_caller)) then
    raise exception 'TARGET_UNAVAILABLE' using errcode = '22023';
  end if;
  return jsonb_build_object('id', p_session_id, 'state', 'ended');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.equip_my_world_item_v1(p_user uuid, p_slot text, p_item_id text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.world_appearance_caller_v1(p_user);
  v_tx private.world_appearance_transactions;
  v_category text;
  v_status text;
  v_previous text;
begin
  if p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$' then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = '22023';
  end if;
  if not private.world_appearance_slot_ok_v1(p_slot) then
    raise exception 'INVALID_APPEARANCE_SLOT' using errcode = '22023';
  end if;
  if p_item_id is null or char_length(p_item_id) > 80 or p_item_id !~ '^[a-z][a-z0-9_]*\.[a-z0-9_]+$' then
    raise exception 'INVALID_ITEM_ID' using errcode = '22023';
  end if;

  -- One change per account at a time: the idempotency lookup, the checks and the write are atomic.
  perform pg_advisory_xact_lock(hashtextextended('world_appearance:' || v_uid::text, 0));

  select * into v_tx from private.world_appearance_transactions where idempotency_key = p_idempotency_key;
  if found then
    if v_tx.user_id = v_uid and v_tx.action = 'EQUIP' and v_tx.slot = p_slot
       and v_tx.requested_item_id = p_item_id then
      return private.world_appearance_result_v1(v_tx, true);
    end if;
    raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
  end if;

  -- Category, slot and status from the server catalog mirror; nothing from the client is trusted.
  select c.category, c.status into v_category, v_status
    from private.world_item_catalog c where c.item_id = p_item_id;
  if not found then
    raise exception 'UNKNOWN_ITEM' using errcode = '22023';
  end if;
  if v_category <> 'WEARABLE' then
    raise exception 'ITEM_NOT_EQUIPPABLE' using errcode = 'P0001';
  end if;
  if upper(split_part(p_item_id, '.', 1)) <> p_slot then
    raise exception 'SLOT_MISMATCH' using errcode = 'P0001';
  end if;
  -- Same rule as new grants (C0 GRANT_BLOCKED_STATUSES): DISABLED / HIDDEN items cannot be put on.
  if v_status in ('DISABLED', 'HIDDEN') then
    raise exception 'ITEM_UNAVAILABLE' using errcode = 'P0001';
  end if;
  if not exists (select 1 from private.world_player_items i where i.user_id = v_uid and i.item_id = p_item_id) then
    raise exception 'ITEM_NOT_OWNED' using errcode = 'P0001';
  end if;

  select l.item_id into v_previous from private.world_player_appearance_loadout l
   where l.user_id = v_uid and l.slot = p_slot for update;

  v_tx := private.world_appearance_record_v1(v_uid, p_idempotency_key, 'EQUIP', p_slot, p_item_id, v_previous, p_item_id);
  if v_previous is distinct from p_item_id then
    insert into private.world_player_appearance_loadout (user_id, slot, item_id, updated_at)
    values (v_uid, p_slot, p_item_id, clock_timestamp())
    on conflict (user_id, slot) do update set item_id = excluded.item_id, updated_at = excluded.updated_at;
  end if;
  return private.world_appearance_result_v1(v_tx, false);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_jeongseok_access_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select private.world_jeongseok_access_v1(p_user);
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_achievements(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
  v_classic_at timestamptz;
  v_ranked_at timestamptz;
  v_inha_at timestamptz;
  v_event_place smallint;
  v_event_at timestamptz;
  v_event_key text;
  v_event_title text;
  v_event_description text;
  v_achievements jsonb;
begin
  if v_uid is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;
  if not exists (
       select 1 from public.profiles p
       where p.user_id = v_uid and p.is_banned = false
     )
  then
    raise exception 'PROFILE_NOT_FOUND' using errcode = '42501';
  end if;

  insert into public.user_achievements
    (user_id, achievement_key, earned_at, evidence_source)
  select v_uid, 'classic_recorded_v1', min(recorded_at), 'classic_record'
  from (
    select achieved_at as recorded_at
    from public.general_stage_bests
    where user_id = v_uid
    union all
    select achieved_at as recorded_at
    from public.player_bests
    where user_id = v_uid
  ) records
  having count(*) > 0
  on conflict (user_id, achievement_key) do nothing;

  insert into public.user_achievements
    (user_id, achievement_key, earned_at, evidence_source)
  select v_uid, 'classic_ranked_accepted_v1', min(r.created_at), 'classic_ranked_accepted'
  from public.ranked_runs r
  where r.user_id = v_uid
    and r.run_type = 'ranked'
    and r.validation_status = 'accepted'
  having count(*) > 0
  on conflict (user_id, achievement_key) do nothing;

  insert into public.user_achievements
    (user_id, achievement_key, earned_at, evidence_source)
  select v_uid, 'inha_verified_v1', min(e.earned_at), 'inha_mail_verified'
  from (
    select b.verified_at as earned_at
    from public.inha_mail_badges b
    where b.user_id = v_uid
  ) e
  having count(*) > 0
  on conflict (user_id, achievement_key) do nothing;

  select a.earned_at into v_classic_at
  from public.user_achievements a
  where a.user_id = v_uid and a.achievement_key = 'classic_recorded_v1';

  select a.earned_at into v_ranked_at
  from public.user_achievements a
  where a.user_id = v_uid and a.achievement_key = 'classic_ranked_accepted_v1';

  select a.earned_at into v_inha_at
  from public.user_achievements a
  where a.user_id = v_uid and a.achievement_key = 'inha_verified_v1';

  select b.placement, a.earned_at,
         format('classic_inha_duck_s1_rank_%s_v1', b.placement)
    into v_event_place, v_event_at, v_event_key
  from public.classic_event_badges b
  join public.user_achievements a
    on a.user_id = b.user_id
   and a.achievement_key = format('classic_inha_duck_s1_rank_%s_v1', b.placement)
  where b.event_key = 'inha_duck_s1'
    and b.user_id = v_uid
    and b.placement between 1 and 10;

  v_achievements := jsonb_build_array(
    jsonb_build_object(
      'key', 'classic_recorded_v1',
      'scope', 'game',
      'gameSlug', 'inha-duck',
      'title', '클래식 입문',
      'description', 'Classic에서 계정 기록을 남겼어요.',
      'requirement', '계정에 Classic 기록을 남기면 획득해요.',
      'evidence', '계정에 연결된 Classic 최고 기록',
      'earned', v_classic_at is not null,
      'earnedAt', v_classic_at
    ),
    jsonb_build_object(
      'key', 'classic_ranked_accepted_v1',
      'scope', 'game',
      'gameSlug', 'inha-duck',
      'title', '랭킹 첫 기록',
      'description', 'Classic 랭킹전 기록이 서버 검사를 통과했어요.',
      'requirement', 'Classic 랭킹전 기록이 서버 검사에서 승인되면 획득해요.',
      'evidence', '서버가 승인한 본인 Classic 랭킹전 기록',
      'earned', v_ranked_at is not null,
      'earnedAt', v_ranked_at
    ),
    jsonb_build_object(
      'key', 'inha_verified_v1',
      'scope', 'platform',
      'gameSlug', null,
      'title', '인하대 인증',
      'description', '인하대 이메일 소유 확인을 완료했어요.',
      'requirement', '인하대 이메일(@inha.edu 또는 @inha.ac.kr) 인증을 완료하면 획득해요.',
      'evidence', '인하대 학교 이메일 소유 확인',
      'earned', v_inha_at is not null,
      'earnedAt', v_inha_at
    )
  );

  if v_event_place is not null then
    v_event_title := case v_event_place
      when 1 then '인하오리 S1 우승'
      when 2 then '인하오리 S1 준우승'
      when 3 then '인하오리 S1 3위'
      else '인하오리 S1 ' || v_event_place::text || '위'
    end;
    v_event_description := '인하오리 S1 이벤트 최종 랭킹 '
      || v_event_place::text || '위를 기록했어요.';

    v_achievements := v_achievements || jsonb_build_array(
      jsonb_build_object(
        'key', v_event_key,
        'scope', 'game',
        'gameSlug', 'inha-duck',
        'title', v_event_title,
        'description', v_event_description,
        'requirement', '종료된 인하오리 S1 이벤트의 최종 TOP 10 기록입니다.',
        'evidence', '인하오리 S1 이벤트 종료 시점 최종 랭킹',
        'earned', true,
        'earnedAt', v_event_at
      )
    );
  end if;

  return jsonb_build_object(
    'earnedCount',
      (v_classic_at is not null)::int
      + (v_ranked_at is not null)::int
      + (v_inha_at is not null)::int
      + (v_event_place is not null)::int,
    'achievements',
    v_achievements
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_biryong_npc_relationship_v1(p_user uuid, p_npc_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := p_user;
begin
  if v_user is null then
    raise exception 'SIGN_IN_REQUIRED' using errcode = '42501';
  end if;
  return private.world_biryong_relationship_snapshot_v1(v_user,p_npc_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_biryong_npc_relationships_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := p_user;
begin
  if v_user is null then
    raise exception 'SIGN_IN_REQUIRED' using errcode = '42501';
  end if;
  return private.world_biryong_relationship_list_v1(v_user);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_biryong_progress_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_row private.world_biryong_progress_v1%rowtype;
begin
  if p_user is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;

  select * into v_row
  from private.world_biryong_progress_v1
  where user_id = p_user;

  if not found then return null; end if;

  return jsonb_build_object(
    'discoveredAt', case when v_row.discovered_at is null then null
      else floor(extract(epoch from v_row.discovered_at) * 1000)::bigint end,
    'step', v_row.step,
    'lore', to_jsonb(v_row.lore),
    'shouts', v_row.shouts,
    'completedAt', case when v_row.completed_at is null then null
      else floor(extract(epoch from v_row.completed_at) * 1000)::bigint end
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_mcm_2026_event_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
begin
  if v_uid is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;
  if not private.world_mcm_account_ok_v1(v_uid) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '42501';
  end if;
  return private.world_mcm_state_v1(v_uid);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_profile(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid := p_user;
declare v_result jsonb;
begin
  if v_uid is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode='42501';
  end if;
  with identity as (
    select p.nickname,p.title,p.avatar_key,p.department_id,p.created_at,
           d.name as department
    from public.profiles p left join public.departments d on d.id=p.department_id
    where p.user_id=v_uid and p.is_banned=false
  ), activity as (
    select g.slug, min(e.created_at) first_at, max(e.created_at) last_at
    from public.game_events e
    join public.games g on g.id=e.game_id
    left join public.players pl on pl.id=e.player_id
    where e.user_id=v_uid or pl.auth_user_id=v_uid
    group by g.slug
  ), classic_records as (
    select max(best_score) score,max(best_combo) combo,min(achieved_at) first_at,
           max(achieved_at) last_at
    from (
      select best_score,best_combo,achieved_at from public.player_bests where user_id=v_uid
      union all
      select best_score,best_combo,achieved_at from public.general_stage_bests where user_id=v_uid
    ) b
  ), up_record as (
    select best_wave,best_score,achieved_at from public.induckup_ranked_bests where user_id=v_uid
  ), progress as (
    select g.slug,ugp.first_synced_at,ugp.updated_at,ugp.progress
    from public.user_game_progress ugp join public.games g on g.id=ugp.game_id
    where ugp.user_id=v_uid
  ), survival as (
    select p.slug,max(s.key::int) filter (where s.value->>'clear'='true') as cleared,
           max((s.value->>'bestKills')::int) filter
             (where s.value->>'bestKills' ~ '^[0-9]{1,8}$') as kills
    from progress p cross join lateral jsonb_each(
      case when jsonb_typeof(p.progress->'stages')='object'
           then p.progress->'stages' else '{}'::jsonb end
    ) s
    where p.slug='inha-duck-survival' and s.key ~ '^[0-9]{1,3}$'
    group by p.slug
  ), records as (
    select g.slug,g.name,g.status,
      coalesce(a.first_at, case when g.slug='inha-duck' then c.first_at
        when g.slug='induckup' then u.achieved_at end,p.first_synced_at) first_at,
      greatest(a.last_at,
        case when g.slug='inha-duck' then c.last_at
             when g.slug='induckup' then u.achieved_at end,p.updated_at) last_at,
      case when g.slug='inha-duck' and c.score is not null then '최고 점수'
           when g.slug='induckup' and u.best_wave is not null then '최고 Wave'
           when g.slug='inha-duck-survival' and s.cleared is not null then '최고 클리어 스테이지'
           when g.slug='inha-duck-survival' and p.slug is not null then '진행 상태'
           when g.slug='induck-grow' and p.slug is not null then '학기 진행' end headline_key,
      case when g.slug='inha-duck' then c.score::text
           when g.slug='induckup' then u.best_wave::text
           when g.slug='inha-duck-survival' then coalesce(s.cleared::text,'진행 중')
           when g.slug='induck-grow' then case
             when p.progress->>'phase'='final' then '한 학기 완료'
             when p.progress->>'week' ~ '^([1-9]|1[0-5])$' then (p.progress->>'week')||'주차'
             else '진행 중' end end headline_value,
      case when g.slug='inha-duck' and c.combo is not null then '최고 콤보'
           when g.slug='induckup' and u.best_score is not null then '최고 점수'
           when g.slug='inha-duck-survival' and s.kills is not null then '최고 처치'
           when g.slug='induck-grow' and p.progress->>'phase'='final'
             and p.progress->>'gpa' ~ '^[0-4](\.[0-9]{1,3})?$' then '학기 GPA' end subline_key,
      case when g.slug='inha-duck' then c.combo::text
           when g.slug='induckup' then u.best_score::text
           when g.slug='inha-duck-survival' then s.kills::text
           when g.slug='induck-grow' and p.progress->>'phase'='final'
             and p.progress->>'gpa' ~ '^[0-4](\.[0-9]{1,3})?$' then p.progress->>'gpa' end subline_value
    from public.games g left join activity a on a.slug=g.slug
    left join progress p on p.slug=g.slug
    left join survival s on s.slug=g.slug
    left join classic_records c on g.slug='inha-duck'
    left join up_record u on g.slug='induckup'
    where g.status in ('production','testing')
  )
  select jsonb_build_object(
    'profile',(select jsonb_build_object('nickname',i.nickname,'departmentId',i.department_id,
      'department',i.department,'title',i.title,'avatar',i.avatar_key,
      'joinedAt',i.created_at,'inhaVerified',public.my_inha_mail_badge(p_user)) from identity i),
    'stats',jsonb_build_object('playedGames',(select count(*) from records where first_at is not null)),
    'games',coalesce((select jsonb_agg(jsonb_build_object(
      'slug',slug,'name',name,'status',status,'played',first_at is not null,
      'firstPlayedAt',first_at,'lastPlayedAt',last_at,
      'headline',case when headline_key is not null then
        jsonb_build_object('label',headline_key,'value',headline_value) end,
      'subline',case when subline_key is not null then
        jsonb_build_object('label',subline_key,'value',subline_value) end
    ) order by name) from records),'[]'::jsonb)
  ) into v_result;
  if v_result->'profile'='null'::jsonb then
    raise exception 'PROFILE_NOT_FOUND' using errcode='42501';
  end if;
  return v_result;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_room_knock_v1(p_user uuid, p_knock uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_caller uuid := private.world_room_caller_v1(p_user);
  v_knock private.world_room_knocks%rowtype;
begin
  select k.* into v_knock from private.world_room_knocks k
   where k.id = p_knock and k.visitor_user_id = v_caller;
  if not found then
    raise exception 'KNOCK_NOT_FOUND' using errcode = 'P0002';
  end if;
  return private.world_room_knock_json_v1(v_knock);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_world_accompany(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_caller uuid := private.world_social_caller(p_user);
begin
  perform private.world_accompany_expire(v_caller);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id, 'inviterId', s.inviter_id, 'inviteeId', s.invitee_id,
      'peer', private.world_card(case when s.inviter_id = v_caller then s.invitee_id else s.inviter_id end),
      'placeZoneId', s.place_zone_id, 'poiId', s.poi_id, 'state', s.state,
      'createdAt', s.created_at, 'expiresAt', s.expires_at, 'acceptedAt', s.accepted_at
    ) order by s.created_at desc)
    from public.world_accompany_sessions s
    where (s.inviter_id = v_caller or s.invitee_id = v_caller)
      and s.state in ('offered', 'active') and s.expires_at > now()
  ), '[]'::jsonb);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_world_appearance_loadout_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.world_appearance_caller_v1(p_user);
begin
  -- Read-only: never creates a loadout row. No rows = every slot empty.
  return private.world_appearance_loadout_json_v1(v_uid);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_world_attendance_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.world_attendance_caller_v1(p_user);
begin
  return private.world_attendance_state_v1(v_uid, private.world_attendance_today_v1());
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_world_campus_npc_relationship_v1(p_user uuid, p_npc_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_user uuid := p_user;
begin
  if v_user is null then raise exception 'SIGN_IN_REQUIRED' using errcode = '42501'; end if;
  return private.world_campus_npc_relationship_snapshot_v1(v_user,p_npc_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_world_campus_npc_relationships_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_user uuid := p_user;
begin
  if v_user is null then raise exception 'SIGN_IN_REQUIRED' using errcode = '42501'; end if;
  return private.world_campus_npc_relationship_list_v1(v_user);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_world_daily_quiz_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.world_daily_quiz_caller_v1(p_user);
begin
  return private.world_daily_quiz_state_v1(v_uid, private.world_daily_quiz_today_v1());
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_world_inventory_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
begin
  if v_uid is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;
  if not private.world_inventory_account_ok_v1(v_uid) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '42501';
  end if;
  return jsonb_build_object('items', coalesce((
    select jsonb_agg(private.world_inventory_item_json_v1(i, c.status, false)
                     order by i.acquired_at desc, i.item_id)
      from private.world_player_items i
      left join private.world_item_catalog c on c.item_id = i.item_id
     where i.user_id = v_uid
  ), '[]'::jsonb));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_world_life_skill_tree_v1(p_user uuid, p_skill_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := private.world_life_caller_v1(p_user);
begin
  perform private.world_life_book_visible_skill_v1(p_skill_id);
  return private.world_life_book_tree_view_v1(v_user,p_skill_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_world_life_skills_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := private.world_life_caller_v1(p_user);
  v_life jsonb := private.world_life_progression_snapshot_v1(v_user);
begin
  return jsonb_build_object(
    'lifeLevel',jsonb_build_object('level',v_life->'level','totalSkillXp',v_life->'totalSkillXp'),
    'skills',coalesce((
      select jsonb_agg(private.world_life_book_skill_view_v1(v_user,s.skill_id) order by s.skill_id)
        from private.world_life_skill_catalog s
       where s.status = 'ACTIVE'
    ),'[]'::jsonb)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_world_progression_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
begin
  if v_uid is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;
  if not private.world_progression_account_ok_v1(v_uid) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '42501';
  end if;
  return private.world_progression_snapshot_v1(v_uid) - 'userId';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_world_social(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_caller uuid := private.world_social_caller(p_user);
begin
  return jsonb_build_object(
    'friends', coalesce((
      select jsonb_agg(private.world_card(o.other) order by p.nickname)
      from (select case when f.user_low = v_caller then f.user_high else f.user_low end other
            from public.world_friendships f
            where (f.user_low = v_caller or f.user_high = v_caller) and f.status = 'accepted') o
      join public.profiles p on p.user_id = o.other and p.is_banned = false), '[]'::jsonb),
    'incoming', coalesce((
      select jsonb_agg(private.world_card(f.requested_by) order by f.created_at desc)
      from public.world_friendships f join public.profiles p on p.user_id = f.requested_by and p.is_banned = false
      where (f.user_low = v_caller or f.user_high = v_caller) and f.status = 'pending' and f.requested_by <> v_caller), '[]'::jsonb),
    'outgoing', coalesce((
      select jsonb_agg(private.world_card(case when f.user_low = v_caller then f.user_high else f.user_low end) order by f.created_at desc)
      from public.world_friendships f
      join public.profiles p on p.user_id = (case when f.user_low = v_caller then f.user_high else f.user_low end) and p.is_banned = false
      where (f.user_low = v_caller or f.user_high = v_caller) and f.status = 'pending' and f.requested_by = v_caller), '[]'::jsonb),
    -- Only people the caller blocked; who blocked the caller is never listed.
    'blocked', coalesce((
      select jsonb_agg(jsonb_build_object('userId', p.user_id, 'nickname', p.nickname, 'title', p.title, 'avatar', p.avatar_key) order by b.created_at desc)
      from public.world_user_blocks b join public.profiles p on p.user_id = b.blocked_id
      where b.blocker_id = v_caller), '[]'::jsonb)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_world_wallet_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
begin
  if v_uid is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;
  if not private.world_wallet_account_ok_v1(v_uid) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '42501';
  end if;
  return jsonb_build_object('currencies', coalesce((
    select jsonb_agg(jsonb_build_object('id', c.currency_id, 'balance', coalesce(w.balance, 0))
                     order by c.currency_id)
      from private.world_currencies c
      left join private.world_wallets w
        on w.currency_id = c.currency_id and w.user_id = v_uid
  ), '[]'::jsonb));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_or_create_my_personal_room_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.world_room_caller_v1(p_user);
  v_room public.world_player_rooms%rowtype;
begin
  -- Serialize first-entry provisioning across tabs/retries before the unique constraint fallback.
  perform pg_advisory_xact_lock(hashtextextended('world_personal_room:' || v_uid::text, 0));

  insert into public.world_player_rooms (owner_user_id, room_type, visibility)
  values (v_uid, 'DORM_1_BASIC', 'friends')
  on conflict (owner_user_id) do nothing;

  select *
    into strict v_room
    from public.world_player_rooms r
   where r.owner_user_id = v_uid;

  return jsonb_build_object(
    'roomId', v_room.id,
    'ownerUserId', v_room.owner_user_id,
    'roomType', v_room.room_type,
    'visibility', v_room.visibility,
    'createdAt', v_room.created_at,
    'updatedAt', v_room.updated_at
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_world_guestbook_v2(p_user uuid, p_location_key text, p_limit integer, p_before timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.world_social_caller(p_user);
  v_limit integer := greatest(1, least(coalesce(p_limit, 20), 50));
  v_has_more boolean;
  v_next_before timestamptz;
  v_entries jsonb;
  v_daily_used integer := 0;
  v_cooldown integer := 0;
begin
  if p_location_key <> 'main_gate' then
    raise exception 'INVALID_LOCATION' using errcode = '22023';
  end if;

  with selected as (
    select g.id, g.created_at
    from public.world_guestbook_entries g
    join public.profiles p on p.user_id = g.user_id and p.is_banned = false
    where g.location_key = p_location_key
      and g.is_hidden = false
      and (p_before is null or g.created_at < p_before)
    order by g.created_at desc, g.id desc
    limit v_limit + 1
  ),
  page as (
    select * from selected
    order by created_at desc, id desc
    limit v_limit
  )
  select
    coalesce(
      jsonb_agg(
        private.world_guestbook_entry_json(id, v_uid)
        order by created_at desc, id desc
      ),
      '[]'::jsonb
    ),
    (select count(*) > v_limit from selected),
    min(created_at)
  into v_entries, v_has_more, v_next_before
  from page;

  select count(*)::integer
  into v_daily_used
  from private.world_guestbook_post_log l
  where l.user_id = v_uid
    and l.location_key = p_location_key
    and (l.created_at at time zone 'Asia/Seoul')::date =
        (now() at time zone 'Asia/Seoul')::date;

  select coalesce(
    greatest(
      0,
      ceil(extract(epoch from (max(l.created_at) + interval '60 seconds' - now())))::integer
    ),
    0
  )
  into v_cooldown
  from private.world_guestbook_post_log l
  where l.user_id = v_uid
    and l.location_key = p_location_key;

  return jsonb_build_object(
    'locationKey', p_location_key,
    'entries', v_entries,
    'hasMore', coalesce(v_has_more, false),
    'nextBefore', case when coalesce(v_has_more, false) then v_next_before else null end,
    'dailyLimit', 3,
    'dailyUsed', v_daily_used,
    'dailyRemaining', greatest(0, 3 - v_daily_used),
    'cooldownRemainingSeconds', v_cooldown
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_world_public_profile(p_user uuid, p_target uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_caller uuid := private.world_social_caller(p_user);
declare v_state text;
begin
  perform private.world_social_target(v_caller, p_target);
  v_state := private.world_relationship(v_caller, p_target);
  if v_state = 'unavailable' then
    return jsonb_build_object('userId', p_target, 'available', false, 'relationship', 'unavailable');
  end if;
  return private.world_card(p_target) || jsonb_build_object('available', true, 'relationship', v_state);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_world_relationship(p_user uuid, p_target uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_caller uuid := private.world_social_caller(p_user);
begin
  perform private.world_social_target(v_caller, p_target);
  return jsonb_build_object('userId', p_target, 'relationship', private.world_relationship(v_caller, p_target));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_world_room_furniture_v1(p_user uuid, p_room uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := private.world_room_caller_v1(p_user);
  v_role text; v_layout private.world_room_layouts%rowtype;
begin
  v_role := private.world_room_access_v1(v_user,p_room);
  if v_role not in ('OWNER','VISITOR') then raise exception 'LAYOUT_DENIED' using errcode = '42501'; end if;
  select * into v_layout from private.world_room_layouts where room_id = p_room;
  return jsonb_build_object('roomId',p_room,'role',lower(v_role),'revision',coalesce(v_layout.revision,0),'objects',coalesce(v_layout.objects,'[]'::jsonb));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_world_shop_capabilities_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
  v_scoped oid := to_regprocedure('public.purchase_world_shop_listing_v2(uuid,text,text,text)');
  v_legacy oid := to_regprocedure('public.purchase_world_shop_listing_v1(uuid,text,text)');
  v_rpc text;
  v_layout text;
begin
  if v_uid is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;
  if not private.world_inventory_account_ok_v1(v_uid) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '42501';
  end if;

  -- Check the caller role's grant, not the SECURITY DEFINER owner's privileges.
  if v_scoped is not null and has_function_privilege('inha_world_tier4_writes_app', v_scoped, 'EXECUTE') then
    v_rpc := 'purchase_world_shop_listing_v2';
  elsif v_legacy is not null and has_function_privilege('inha_world_tier4_writes_app', v_legacy, 'EXECUTE') then
    v_rpc := 'purchase_world_shop_listing_v1';
  else
    raise exception 'SHOP_API_UNAVAILABLE' using errcode = 'P0001';
  end if;

  -- This is the physical catalog binding, not a claim about UI deployment, proximity,
  -- product availability or vendor identity. All six durable listings must be present.
  -- Inactive/hidden products keep their status; get_world_shop_v1 still decides visibility.
  with expected(listing_id, split_shop_id) as (values
    ('offer.student_center.campus_mug', 'shop.student_center'),
    ('offer.student_center.induck_cap', 'shop.student_center_fashion'),
    ('offer.student_center.campus_sneakers', 'shop.student_center_fashion'),
    ('offer.student_center.induck_hoodie', 'shop.student_center_fashion'),
    ('offer.student_center.induck_backpack', 'shop.student_center_fashion'),
    ('offer.student_center.campus_map_poster', 'shop.dorm_furniture')
  )
  select case
    when count(l.listing_id) <> 6 then 'mixed'
    when bool_and(l.shop_id = 'shop.student_center') then 'legacy'
    when bool_and(l.shop_id = e.split_shop_id) then 'split'
    else 'mixed'
  end into v_layout
  from expected e left join private.world_shop_listings l on l.listing_id = e.listing_id;

  return jsonb_build_object('version', 1, 'purchaseRpc', v_rpc, 'catalogLayout', v_layout);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_world_shop_v1(p_user uuid, p_shop_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
  v_shop private.world_shops%rowtype;
  v_level integer;
begin
  if v_uid is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;
  select * into v_shop from private.world_shops s where s.shop_id = p_shop_id;
  if not found or v_shop.status = 'HIDDEN' then
    raise exception 'SHOP_NOT_FOUND' using errcode = 'P0001';
  end if;
  v_level := private.world_player_level_v1(v_uid);
  return jsonb_build_object(
    'shopId', v_shop.shop_id,
    'displayName', v_shop.display_name,
    'status', v_shop.status,
    'playerLevel', v_level,
    'offers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'listingId', l.listing_id,
        'itemId', l.item_id,
        'currencyId', l.currency_id,
        'price', l.price,
        'quantity', l.quantity,
        'requiredLevel', l.required_level,
        'purchaseLimit', l.purchase_limit,
        'startAt', l.start_at,
        'endAt', l.end_at,
        'status', l.status,
        'purchasable', v_shop.status = 'ACTIVE' and b.reason is null,
        'unavailableReason', case when v_shop.status <> 'ACTIVE' then 'SHOP_INACTIVE' else b.reason end)
        order by l.position)
        from private.world_shop_listings l
        cross join lateral (select private.world_shop_listing_block_v2(l, now(), v_level) as reason) b
       where l.shop_id = v_shop.shop_id and l.status in ('ACTIVE', 'LOCKED')), '[]'::jsonb));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_world_staff_badges_v1(p_user uuid, p_user_ids uuid[])
 RETURNS TABLE(user_id uuid, badge_code text)
 LANGUAGE sql
 STABLE SECURITY DEFINER ROWS 64
 SET search_path TO ''
AS $function$
  select a.user_id, 'gm'::text
  from private.world_staff_assignments a
  where p_user is not null
    and coalesce(cardinality(p_user_ids), 0) between 1 and 64
    and a.user_id = any(p_user_ids)
    and a.active
    and a.role in ('world_admin', 'sound_gm')
  order by a.user_id
$function$
;

CREATE OR REPLACE FUNCTION public.is_inha_mail(p_email text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$select lower(coalesce(p_email,'')) ~ '^[^@[:space:]]+@(inha[.]edu|inha[.]ac[.]kr)$'$function$
;

CREATE OR REPLACE FUNCTION public.knock_friend_personal_room_v1(p_user uuid, p_owner uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_caller uuid := private.world_social_caller(p_user);
  v_room public.world_player_rooms%rowtype;
  v_access text;
  v_knock private.world_room_knocks%rowtype;
begin
  perform private.world_social_target(v_caller, p_owner);
  if private.world_relationship(v_caller, p_owner) <> 'friends' then
    raise exception 'NOT_FRIENDS' using errcode = '42501';
  end if;
  select r.* into v_room from public.world_player_rooms r where r.owner_user_id = p_owner;
  if not found then
    raise exception 'ROOM_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- Serialize knocks per room so presence, rate limit and the pending slot agree.
  perform 1 from public.world_player_rooms r where r.id = v_room.id for update;

  update private.world_room_knocks k
     set status = 'EXPIRED'
   where k.room_id = v_room.id and k.status = 'PENDING' and k.expires_at <= now();

  v_access := private.world_room_access_v1(v_caller, v_room.id);
  if v_access = 'PRIVATE' then
    raise exception 'ROOM_PRIVATE' using errcode = '42501';
  end if;
  if v_access = 'DECLINED' then
    raise exception 'VISIT_DECLINED' using errcode = '42501';
  end if;
  if v_access not in ('VISITOR', 'KNOCK_REQUIRED') then
    raise exception 'NOT_FRIENDS' using errcode = '42501';
  end if;

  -- A repeated knock while one is still waiting returns that knock.
  select k.* into v_knock from private.world_room_knocks k
   where k.room_id = v_room.id and k.visitor_user_id = v_caller and k.status = 'PENDING';
  if found then
    return private.world_room_knock_json_v1(v_knock) || jsonb_build_object('ownerPresent', true);
  end if;

  -- A still-valid admission is reused rather than stacking a new row per knock.
  if v_access = 'VISITOR' then
    select k.* into v_knock from private.world_room_knocks k
     where k.room_id = v_room.id and k.visitor_user_id = v_caller
       and k.status in ('ACCEPTED', 'OPEN') and k.created_at > now() - interval '2 hours'
     order by k.created_at desc limit 1;
    if found then
      return private.world_room_knock_json_v1(v_knock)
        || jsonb_build_object('ownerPresent', private.world_room_owner_present_v1(v_room.id));
    end if;
  end if;

  if not private.world_room_owner_present_v1(v_room.id) then
    insert into private.world_room_knocks (room_id, visitor_user_id, status, expires_at, responded_at)
    values (v_room.id, v_caller, 'OPEN', now() + interval '2 hours', now())
    returning * into v_knock;
    return private.world_room_knock_json_v1(v_knock) || jsonb_build_object('ownerPresent', false);
  end if;

  if (select count(*) from private.world_room_knocks k
       where k.room_id = v_room.id and k.visitor_user_id = v_caller
         and k.created_at > now() - interval '2 minutes') >= 5 then
    raise exception 'RATE_LIMITED' using errcode = '54000';
  end if;
  insert into private.world_room_knocks (room_id, visitor_user_id, status, expires_at)
  values (v_room.id, v_caller, 'PENDING', now() + interval '30 seconds')
  returning * into v_knock;
  return private.world_room_knock_json_v1(v_knock) || jsonb_build_object('ownerPresent', true);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_my_room_knocks_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.world_room_caller_v1(p_user);
  v_room public.world_player_rooms%rowtype;
begin
  select r.* into v_room from public.world_player_rooms r where r.owner_user_id = v_uid;
  if not found then
    raise exception 'ROOM_NOT_FOUND' using errcode = 'P0002';
  end if;
  insert into private.world_room_owner_presence (room_id, seen_at) values (v_room.id, now())
  on conflict (room_id) do update set seen_at = excluded.seen_at;
  update private.world_room_knocks k
     set status = 'EXPIRED'
   where k.room_id = v_room.id and k.status = 'PENDING' and k.expires_at <= now();
  return jsonb_build_object(
    'roomId', v_room.id,
    'knocks', coalesce((
      select jsonb_agg(private.world_room_knock_json_v1(k)
               || jsonb_build_object('visitorDisplayName', p.nickname)
             order by k.created_at)
        from private.world_room_knocks k
        left join public.profiles p on p.user_id = k.visitor_user_id
       where k.room_id = v_room.id and k.status = 'PENDING'
         -- A visitor who has since been blocked or unfriended no longer appears.
         and private.world_relationship(v_uid, k.visitor_user_id) = 'friends'
    ), '[]'::jsonb)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.merge_my_biryong_progress_v1(p_user uuid, p_progress jsonb, p_migrated_from_local boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := p_user;
  v_existing private.world_biryong_progress_v1%rowtype;
  v_step text;
  v_step_rank integer;
  v_existing_rank integer;
  v_discovered timestamptz;
  v_completed timestamptz;
  v_lore text[];
  v_shouts integer;
begin
  if v_user is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;
  if p_progress is null or jsonb_typeof(p_progress) <> 'object' then
    raise exception 'INVALID_BIRYONG_PROGRESS' using errcode = '22023';
  end if;

  v_step := coalesce(p_progress->>'step', 'INTRO');
  v_step_rank := case v_step
    when 'INTRO' then 0 when 'FIND_CENTER' then 1 when 'SHOUT' then 2
    when 'REACTION' then 3 when 'COMPLETE' then 4 else -1 end;
  if v_step_rank < 0 then
    raise exception 'INVALID_BIRYONG_STEP' using errcode = '22023';
  end if;

  if jsonb_typeof(p_progress->'discoveredAt') = 'number' then
    v_discovered := to_timestamp((p_progress->>'discoveredAt')::numeric / 1000);
  end if;
  if jsonb_typeof(p_progress->'completedAt') = 'number' then
    v_completed := to_timestamp((p_progress->>'completedAt')::numeric / 1000);
  end if;
  if v_step <> 'INTRO' and v_discovered is null then v_discovered := now(); end if;
  if v_step = 'COMPLETE' and v_completed is null then v_completed := now(); end if;
  if v_step <> 'COMPLETE' then v_completed := null; end if;

  begin
    v_shouts := greatest(0, coalesce((p_progress->>'shouts')::integer, 0));
  exception when others then
    raise exception 'INVALID_BIRYONG_SHOUTS' using errcode = '22023';
  end;

  if p_progress ? 'lore' and jsonb_typeof(p_progress->'lore') <> 'array' then
    raise exception 'INVALID_BIRYONG_LORE' using errcode = '22023';
  end if;
  select coalesce(array_agg(distinct value order by value), '{}'::text[]) into v_lore
  from jsonb_array_elements_text(coalesce(p_progress->'lore', '[]'::jsonb)) as lore(value)
  where char_length(value) between 1 and 96;

  select * into v_existing
  from private.world_biryong_progress_v1
  where user_id = v_user
  for update;

  if not found then
    insert into private.world_biryong_progress_v1(
      user_id, discovered_at, step, lore, shouts, completed_at, migrated_from_local
    ) values (
      v_user, v_discovered, v_step, v_lore, v_shouts, v_completed, coalesce(p_migrated_from_local, false)
    );
  else
    v_existing_rank := case v_existing.step
      when 'INTRO' then 0 when 'FIND_CENTER' then 1 when 'SHOUT' then 2
      when 'REACTION' then 3 when 'COMPLETE' then 4 else -1 end;

    update private.world_biryong_progress_v1
    set discovered_at = case
          when v_existing.discovered_at is null then v_discovered
          when v_discovered is null then v_existing.discovered_at
          else least(v_existing.discovered_at, v_discovered) end,
        step = case when v_step_rank > v_existing_rank then v_step else v_existing.step end,
        lore = array(
          select distinct x from unnest(v_existing.lore || v_lore) x order by x
        ),
        shouts = greatest(v_existing.shouts, v_shouts),
        completed_at = case
          when greatest(v_existing_rank, v_step_rank) < 4 then null
          when v_existing.completed_at is null then v_completed
          when v_completed is null then v_existing.completed_at
          else least(v_existing.completed_at, v_completed) end,
        migrated_from_local = v_existing.migrated_from_local or coalesce(p_migrated_from_local, false),
        updated_at = now()
    where user_id = v_user;
  end if;

  return public.get_my_biryong_progress_v1(p_user);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.my_inha_mail_badge(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1 from public.inha_mail_badges b
    where b.user_id = p_user
  )
$function$
;

CREATE OR REPLACE FUNCTION public.propose_world_accompany(p_user uuid, p_target uuid, p_poi_id text, p_place_zone_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_caller uuid := private.world_social_caller(p_user);
declare v_id uuid;
begin
  perform private.world_social_target(v_caller, p_target);
  if p_poi_id not in ('poi.main-gate', 'poi.main-hall', 'poi.inkyung-pond', 'poi.jungseok') or p_poi_id is null then
    raise exception 'INVALID_DESTINATION' using errcode = '22023';
  end if;
  if p_place_zone_id is null or p_place_zone_id !~ '^AREA_[A-Z0-9_]{1,60}$' then
    raise exception 'INVALID_PLACE_ZONE' using errcode = '22023';
  end if;
  perform private.world_accompany_lock_users(v_caller, p_target);
  perform private.world_accompany_expire(v_caller);
  perform private.world_accompany_expire(p_target);
  if private.world_relationship(v_caller, p_target) <> 'friends' then
    raise exception 'NOT_ALLOWED' using errcode = '42501';
  end if;
  -- Repeat the same proposal safely after a lost response.
  select s.id into v_id from public.world_accompany_sessions s
   where s.inviter_id = v_caller and s.invitee_id = p_target and s.state = 'offered'
     and s.poi_id = p_poi_id and s.place_zone_id = p_place_zone_id and s.expires_at > now()
   order by s.created_at desc limit 1;
  if v_id is not null then return (select jsonb_build_object('id', s.id, 'state', s.state, 'expiresAt', s.expires_at)
                                from public.world_accompany_sessions s where s.id = v_id); end if;
  if exists (select 1 from public.world_accompany_sessions s
              where (s.inviter_id in (v_caller, p_target) or s.invitee_id in (v_caller, p_target))
                and s.state in ('offered', 'active') and s.expires_at > now()) then
    raise exception 'ALREADY_BUSY' using errcode = '42501';
  end if;
  if (select count(*) from public.world_accompany_sessions s
       where s.inviter_id = v_caller and s.created_at > now() - interval '1 minute') >= 3 then
    raise exception 'RATE_LIMITED' using errcode = '54000';
  end if;
  insert into public.world_accompany_sessions(inviter_id, invitee_id, place_zone_id, poi_id)
    values(v_caller, p_target, p_place_zone_id, p_poi_id) returning id into v_id;
  return (select jsonb_build_object('id', s.id, 'state', s.state, 'expiresAt', s.expires_at)
          from public.world_accompany_sessions s where s.id = v_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.purchase_jeongseok_pass_v1(p_user uuid, p_pass_type text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
  v_now timestamptz := now();
  v_existing private.world_jeongseok_pass_purchases%rowtype;
  v_product private.world_jeongseok_pass_catalog%rowtype;
  v_gate text;
  v_wallet jsonb;
  v_purchase_id uuid;
  v_expires timestamptz;
begin
  if v_uid is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,119}$' then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = '22023';
  end if;
  -- Stored account state, not only claims: anonymous or banned accounts never pay or replay.
  if not private.world_wallet_account_ok_v1(v_uid) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '42501';
  end if;

  -- One pass decision per account at a time; different keys queue here and re-check the right.
  perform pg_advisory_xact_lock(hashtextextended('world_jeongseok_pass:' || v_uid::text, 0));

  -- Lost-response recovery: the same key returns the original receipt, never a second debit.
  select * into v_existing from private.world_jeongseok_pass_purchases p where p.idempotency_key = p_idempotency_key;
  if found then
    if (v_existing.user_id, v_existing.pass_type) is distinct from (v_uid, p_pass_type) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return private.world_jeongseok_purchase_result_v1(v_existing.purchase_id, true);
  end if;

  -- Preflight: every refusal happens before any value moves.
  select g.status into v_gate from private.world_jeongseok_gate_policy g where g.singleton;
  if v_gate is distinct from 'ACTIVE' then
    raise exception 'JEONGSEOK_GATE_UNAVAILABLE' using errcode = 'P0001';
  end if;
  if p_pass_type is null then raise exception 'INVALID_PASS_TYPE' using errcode = '22023'; end if;
  select * into v_product from private.world_jeongseok_pass_catalog c where c.pass_type = p_pass_type for share;
  if not found then raise exception 'INVALID_PASS_TYPE' using errcode = '22023'; end if;
  -- Defense in depth: a candidate price must never be charged, even if catalog policy changes.
  if v_product.status <> 'ACTIVE' or v_product.price_basis <> 'CONFIRMED' then
    raise exception 'PASS_UNAVAILABLE' using errcode = 'P0001';
  end if;
  if public.my_inha_mail_badge(v_uid) then
    raise exception 'FREE_ACCESS_ELIGIBLE' using errcode = 'P0001';
  end if;
  if exists (select 1 from private.world_jeongseok_pass_entitlements e
              where e.user_id = v_uid and e.expires_at > v_now) then
    raise exception 'PASS_ALREADY_ACTIVE' using errcode = 'P0001';
  end if;

  -- Debit through the Wallet authority. INSUFFICIENT_FUNDS aborts with nothing moved.
  v_wallet := private.world_wallet_apply_v1(
    v_uid, v_product.currency_id, -v_product.price, 'PURCHASE', 'jeongseok_pass', v_product.pass_type,
    'jeongseok/' || p_idempotency_key || '/wallet', null);
  if v_wallet ->> 'status' <> 'SUCCESS' then
    -- A ledger row without its receipt would mean a split purchase; never treat it as paid.
    raise exception 'PURCHASE_STATE_CONFLICT' using errcode = 'P0001';
  end if;

  v_expires := v_now + make_interval(secs => v_product.duration_seconds);
  begin
    insert into private.world_jeongseok_pass_purchases (
      user_id, pass_type, currency_id, price, balance_before, balance_after,
      issued_at, expires_at, wallet_transaction_id, idempotency_key)
    values (
      v_uid, v_product.pass_type, v_product.currency_id, v_product.price,
      (v_wallet ->> 'balanceBefore')::bigint, (v_wallet ->> 'balanceAfter')::bigint,
      v_now, v_expires, (v_wallet ->> 'transactionId')::uuid, p_idempotency_key)
    returning purchase_id into v_purchase_id;
  exception when unique_violation then
    -- Same-account retries resolve above under the lock; this key belongs to another account.
    raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
  end;

  insert into private.world_jeongseok_pass_entitlements (user_id, pass_type, issued_at, expires_at, last_purchase_id, updated_at)
  values (v_uid, v_product.pass_type, v_now, v_expires, v_purchase_id, v_now)
  on conflict (user_id) do update
    set pass_type = excluded.pass_type, issued_at = excluded.issued_at, expires_at = excluded.expires_at,
        last_purchase_id = excluded.last_purchase_id, updated_at = excluded.updated_at;

  -- Readback inside the same transaction: right, receipt and ledger balance agree.
  if not exists (select 1 from private.world_jeongseok_pass_entitlements e
                  where e.user_id = v_uid and e.last_purchase_id = v_purchase_id and e.expires_at = v_expires)
     or (select w.balance from private.world_wallets w
          where w.user_id = v_uid and w.currency_id = v_product.currency_id)
        is distinct from (v_wallet ->> 'balanceAfter')::bigint then
    raise exception 'PURCHASE_READBACK_FAILED' using errcode = 'P0001';
  end if;

  return private.world_jeongseok_purchase_result_v1(v_purchase_id, false);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.purchase_world_shop_listing_v1(p_user uuid, p_listing_id text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
  v_listing private.world_shop_listings%rowtype;
  v_shop private.world_shops%rowtype;
  v_existing private.world_purchase_transactions%rowtype;
  v_block text;
  v_policy text;
  v_wallet jsonb;
  v_grant jsonb;
  v_purchase_id uuid;
begin
  if v_uid is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;
  if p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,119}$' then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = '22023';
  end if;
  if not private.world_inventory_account_ok_v1(v_uid) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '42501';
  end if;

  -- One purchase per account at a time: retries, ownership preflight and limits are decided here.
  perform pg_advisory_xact_lock(hashtextextended('world_shop:' || v_uid::text, 0));

  select * into v_existing from private.world_purchase_transactions p where p.idempotency_key = p_idempotency_key;
  if found then
    if (v_existing.user_id, v_existing.listing_id) is distinct from (v_uid, p_listing_id) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return private.world_purchase_result_v1(v_existing.purchase_id, true);
  end if;

  -- Preflight: every structural refusal happens before any value moves.
  select * into v_listing from private.world_shop_listings l where l.listing_id = p_listing_id;
  if not found or v_listing.status = 'HIDDEN' then
    raise exception 'INVALID_LISTING' using errcode = 'P0001';
  end if;
  select * into v_shop from private.world_shops s where s.shop_id = v_listing.shop_id;
  if v_shop.status = 'HIDDEN' then
    raise exception 'INVALID_LISTING' using errcode = 'P0001';
  end if;
  if v_shop.status <> 'ACTIVE' then
    raise exception 'SHOP_INACTIVE' using errcode = 'P0001';
  end if;
  -- The Level gate: derived now from the P0-F0 authority, never from the client or a cached read.
  v_block := private.world_shop_listing_block_v2(v_listing, now(), private.world_player_level_v1(v_uid));
  if v_block is not null then
    raise exception '%', v_block using errcode = 'P0001';
  end if;
  if v_listing.purchase_limit is not null and (
       select count(*) from private.world_purchase_transactions p
        where p.user_id = v_uid and p.listing_id = v_listing.listing_id) >= v_listing.purchase_limit then
    raise exception 'PURCHASE_LIMIT_REACHED' using errcode = 'P0001';
  end if;
  select c.ownership_policy into v_policy from private.world_item_catalog c where c.item_id = v_listing.item_id;
  if v_policy = 'UNIQUE' and exists (select 1 from private.world_player_items i
                                      where i.user_id = v_uid and i.item_id = v_listing.item_id) then
    raise exception 'ITEM_ALREADY_OWNED' using errcode = 'P0001';
  end if;

  -- Debit (P0-A path). INSUFFICIENT_FUNDS aborts the purchase with nothing moved.
  v_wallet := private.world_wallet_apply_v1(
    v_uid, v_listing.currency_id, -v_listing.price, 'PURCHASE', 'shop', v_listing.listing_id,
    'purchase/' || p_idempotency_key || '/wallet', null);

  -- Grant (P0-B path). Anything but a fresh grant aborts the whole purchase, debit included.
  v_grant := private.world_inventory_grant_v1(
    v_uid, v_listing.item_id, v_listing.quantity, 'SHOP', v_listing.listing_id,
    'purchase/' || p_idempotency_key || '/item', null,
    jsonb_build_object('shopId', v_listing.shop_id, 'price', v_listing.price, 'currencyId', v_listing.currency_id));
  if v_grant ->> 'status' = 'ALREADY_OWNED' then
    raise exception 'ITEM_ALREADY_OWNED' using errcode = 'P0001';
  end if;
  if v_grant ->> 'status' <> 'GRANTED' then
    raise exception 'PURCHASE_GRANT_FAILED' using errcode = 'P0001';
  end if;

  -- Readback of the final state inside the same transaction.
  if not exists (select 1 from private.world_player_items i
                  where i.user_id = v_uid and i.item_id = v_listing.item_id)
     or (select w.balance from private.world_wallets w
          where w.user_id = v_uid and w.currency_id = v_listing.currency_id)
        is distinct from (v_wallet ->> 'balanceAfter')::bigint then
    raise exception 'PURCHASE_READBACK_FAILED' using errcode = 'P0001';
  end if;

  begin
    insert into private.world_purchase_transactions (
      user_id, shop_id, listing_id, item_id, quantity, currency_id, price,
      balance_before, balance_after, wallet_transaction_id, inventory_grant_id, idempotency_key)
    values (
      v_uid, v_listing.shop_id, v_listing.listing_id, v_listing.item_id, v_listing.quantity,
      v_listing.currency_id, v_listing.price,
      (v_wallet ->> 'balanceBefore')::bigint, (v_wallet ->> 'balanceAfter')::bigint,
      (v_wallet ->> 'transactionId')::uuid, v_grant ->> 'grantId', p_idempotency_key)
    returning purchase_id into v_purchase_id;
  exception when unique_violation then
    -- Same-account retries are resolved above under the lock; this key belongs to another account.
    raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
  end;

  return private.world_purchase_result_v1(v_purchase_id, false);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.purchase_world_shop_listing_v2(p_user uuid, p_shop_id text, p_listing_id text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
  v_existing private.world_purchase_transactions%rowtype;
  v_shop_id text;
begin
  -- Match v1's authentication order before exposing any listing or replay information.
  if v_uid is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;
  if p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,119}$' then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = '22023';
  end if;
  if not private.world_inventory_account_ok_v1(v_uid) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '42501';
  end if;

  -- Share v1's lock, including mixed v1/v2 requests; nested acquisition is reentrant.
  perform pg_advisory_xact_lock(hashtextextended('world_shop:' || v_uid::text, 0));
  select * into v_existing from private.world_purchase_transactions p
    where p.idempotency_key = p_idempotency_key;
  if found then
    -- The completed purchase's original shop is authoritative for retries, even after
    -- a listing moves or is disabled. Never reinterpret a key using its new shop.
    if (v_existing.user_id, v_existing.listing_id, v_existing.shop_id)
       is distinct from (v_uid, p_listing_id, p_shop_id) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return public.purchase_world_shop_listing_v1(p_user, p_listing_id, p_idempotency_key);
  end if;

  -- Hold binding stable through v1's authoritative debit/grant transaction. FOR SHARE
  -- blocks a concurrent listing move/update; ordinary simultaneous readers can coexist.
  select l.shop_id into v_shop_id from private.world_shop_listings l
    where l.listing_id = p_listing_id for share;
  if not found then
    raise exception 'INVALID_LISTING' using errcode = 'P0001';
  end if;
  if v_shop_id is distinct from p_shop_id then
    raise exception 'SHOP_LISTING_MISMATCH' using errcode = 'P0001';
  end if;
  -- v1 remains the sole owner of price, availability, level, limits, balance and grant.
  return public.purchase_world_shop_listing_v1(p_user, p_listing_id, p_idempotency_key);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.remove_world_friend(p_user uuid, p_target uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_caller uuid := private.world_social_caller(p_user);
begin
  perform private.world_social_target(v_caller, p_target);
  perform private.world_lock_pair(v_caller, p_target);
  delete from public.world_friendships f
   where f.user_low = least(v_caller, p_target) and f.user_high = greatest(v_caller, p_target)
     and f.status = 'accepted';
  return jsonb_build_object('userId', p_target, 'relationship', private.world_relationship(v_caller, p_target));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.report_world_user(p_user uuid, p_target uuid, p_category text, p_place_zone_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_caller uuid := private.world_social_caller(p_user);
begin
  if p_target is null or p_target = v_caller then raise exception 'CANNOT_REPORT_SELF' using errcode = '22023'; end if;
  if not exists (select 1 from public.profiles p where p.user_id = p_target) then
    raise exception 'TARGET_UNAVAILABLE' using errcode = '22023';
  end if;
  if p_category is null or p_category not in ('spam', 'harassment', 'inappropriate_name', 'other') then
    raise exception 'INVALID_CATEGORY' using errcode = '22023';
  end if;
  if p_place_zone_id is not null and p_place_zone_id !~ '^AREA_[A-Z0-9_]{1,60}$' then
    raise exception 'INVALID_PLACE_ZONE' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('world_report:' || v_caller::text, 0));
  if exists (select 1 from public.world_user_reports r where r.reporter_id = v_caller and r.target_id = p_target
             and r.category = p_category and r.created_at > now() - interval '24 hours') then
    return jsonb_build_object('status', 'duplicate');
  end if;
  if (select count(*) from public.world_user_reports r where r.reporter_id = v_caller and r.created_at > now() - interval '1 hour') >= 10 then
    raise exception 'RATE_LIMITED' using errcode = '54000';
  end if;
  insert into public.world_user_reports (reporter_id, target_id, category, place_zone_id)
  values (v_caller, p_target, p_category, p_place_zone_id);
  return jsonb_build_object('status', 'received');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.reset_my_world_life_tree_v1(p_user uuid, p_skill_id text, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := private.world_life_caller_v1(p_user);
  v_key text;
  v_result jsonb;
begin
  if p_request_id is null then
    raise exception 'INVALID_REQUEST_ID' using errcode = '22023';
  end if;
  v_key := 'life.reset:' || v_user::text || ':' || p_request_id::text;

  if not exists (select 1 from private.world_life_tree_resets r where r.idempotency_key = v_key) then
    perform private.world_life_book_visible_skill_v1(p_skill_id);
  end if;

  v_result := private.world_life_tree_reset_v1(v_user,p_skill_id,v_key);
  return jsonb_build_object(
    'status',v_result->'status',
    'skillId',p_skill_id,
    'refundedSp',v_result->'refundedSp',
    'tree',private.world_life_book_tree_view_v1(v_user,p_skill_id)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.respond_room_knock_v1(p_user uuid, p_knock uuid, p_accept boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.world_room_caller_v1(p_user);
  v_knock private.world_room_knocks%rowtype;
begin
  if p_accept is null then
    raise exception 'INVALID_RESPONSE' using errcode = '22023';
  end if;
  select k.* into v_knock
    from private.world_room_knocks k
    join public.world_player_rooms r on r.id = k.room_id
   where k.id = p_knock and r.owner_user_id = v_uid
   for update of k;
  if not found then
    raise exception 'KNOCK_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_knock.status = 'PENDING' and v_knock.expires_at <= now() then
    update private.world_room_knocks set status = 'EXPIRED' where id = v_knock.id returning * into v_knock;
  end if;
  -- Answered or expired knocks are returned unchanged (a lost response may retry).
  if v_knock.status = 'PENDING' then
    update private.world_room_knocks
       set status = case when p_accept then 'ACCEPTED' else 'DECLINED' end, responded_at = now()
     where id = v_knock.id
    returning * into v_knock;
  end if;
  return private.world_room_knock_json_v1(v_knock);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.respond_world_accompany(p_user uuid, p_session_id uuid, p_accept boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_caller uuid := private.world_social_caller(p_user);
declare v_session public.world_accompany_sessions%rowtype;
begin
  if p_accept is null then raise exception 'INVALID_ARGUMENT' using errcode = '22023'; end if;
  select * into v_session from public.world_accompany_sessions where id = p_session_id and invitee_id = v_caller;
  if not found then raise exception 'TARGET_UNAVAILABLE' using errcode = '22023'; end if;
  perform private.world_accompany_lock_users(v_caller, v_session.inviter_id);
  perform private.world_accompany_expire(v_caller);
  select * into v_session from public.world_accompany_sessions where id = p_session_id and invitee_id = v_caller for update;
  if v_session.state = 'active' and p_accept then return jsonb_build_object('id', v_session.id, 'state', 'active'); end if;
  if v_session.state = 'declined' and not p_accept then return jsonb_build_object('id', v_session.id, 'state', 'declined'); end if;
  if v_session.state <> 'offered' then raise exception 'TARGET_UNAVAILABLE' using errcode = '22023'; end if;
  if private.world_relationship(v_caller, v_session.inviter_id) <> 'friends' then
    raise exception 'NOT_ALLOWED' using errcode = '42501';
  end if;
  if p_accept then
    update public.world_accompany_sessions set state = 'active', accepted_at = now(), expires_at = now() + interval '10 minutes'
      where id = p_session_id;
  else
    update public.world_accompany_sessions set state = 'declined', ended_at = now(), ended_reason = 'declined'
      where id = p_session_id;
  end if;
  return jsonb_build_object('id', p_session_id, 'state', case when p_accept then 'active' else 'declined' end);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.respond_world_friend_request(p_user uuid, p_target uuid, p_accept boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_caller uuid := private.world_social_caller(p_user);
begin
  perform private.world_social_target(v_caller, p_target);
  if p_accept is null then raise exception 'INVALID_ARGUMENT' using errcode = '22023'; end if;
  perform private.world_lock_pair(v_caller, p_target);
  -- Only the recipient of a pending request (requested_by = the other user) may answer it.
  if p_accept then
    update public.world_friendships f
       set status = 'accepted', accepted_at = now(), updated_at = now()
     where f.user_low = least(v_caller, p_target) and f.user_high = greatest(v_caller, p_target)
       and f.status = 'pending' and f.requested_by = p_target;
  else
    delete from public.world_friendships f
     where f.user_low = least(v_caller, p_target) and f.user_high = greatest(v_caller, p_target)
       and f.status = 'pending' and f.requested_by = p_target;
  end if;
  return jsonb_build_object('userId', p_target, 'relationship', private.world_relationship(v_caller, p_target));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.save_my_room_furniture_v1(p_user uuid, p_room uuid, p_revision integer, p_objects jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := private.world_room_caller_v1(p_user);
  v_layout private.world_room_layouts%rowtype; v_objects jsonb;
begin
  if private.world_room_access_v1(v_user,p_room) <> 'OWNER' then raise exception 'LAYOUT_DENIED' using errcode = '42501'; end if;
  -- Serialize saves on the existing authority row, including a first empty layout, across tabs.
  perform 1 from public.world_player_rooms where id = p_room and owner_user_id = v_user for update;
  if not found then raise exception 'LAYOUT_DENIED' using errcode = '42501'; end if;
  if p_revision is null or p_revision < 0 then raise exception 'INVALID_LAYOUT' using errcode = '22023'; end if;
  perform private.validate_world_room_furniture_v1(v_user,p_objects);
  select coalesce(jsonb_agg(value order by value->>'id'),'[]'::jsonb) into v_objects from jsonb_array_elements(p_objects);
  insert into private.world_room_layouts(room_id) values(p_room) on conflict (room_id) do nothing;
  select * into strict v_layout from private.world_room_layouts where room_id = p_room for update;
  -- A lost response can retry the identical snapshot without another revision. No last-write-wins.
  if v_layout.objects <> v_objects then
    if v_layout.revision <> p_revision then raise exception 'LAYOUT_CONFLICT' using errcode = '40001'; end if;
    if v_layout.revision = 2147483647 then raise exception 'LAYOUT_CONFLICT' using errcode = '40001'; end if;
    update private.world_room_layouts set objects = v_objects, revision = revision+1, updated_at = now() where room_id = p_room returning * into v_layout;
  end if;
  return jsonb_build_object('roomId',p_room,'role','owner','revision',v_layout.revision,'objects',v_layout.objects);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.send_world_friend_request(p_user uuid, p_target uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_caller uuid := private.world_social_caller(p_user);
declare v_state text;
begin
  perform private.world_social_target(v_caller, p_target);
  perform private.world_lock_pair(v_caller, p_target);
  v_state := private.world_relationship(v_caller, p_target);
  if v_state in ('blocked_by_me', 'unavailable') then
    raise exception 'NOT_ALLOWED' using errcode = '42501';
  end if;
  if v_state = 'none' then
    insert into public.world_friendships (user_low, user_high, status, requested_by)
    values (least(v_caller, p_target), greatest(v_caller, p_target), 'pending', v_caller)
    on conflict (user_low, user_high) do nothing;
  end if;
  -- outgoing/incoming/friends are returned as-is: a crossed request never auto-accepts.
  return jsonb_build_object('userId', p_target, 'relationship', private.world_relationship(v_caller, p_target));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_my_personal_room_visibility_v1(p_user uuid, p_visibility text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.world_room_caller_v1(p_user);
  v_room public.world_player_rooms%rowtype;
begin
  if p_visibility is null or p_visibility not in ('private', 'friends') then
    raise exception 'INVALID_VISIBILITY' using errcode = '22023';
  end if;

  update public.world_player_rooms r
     set visibility = p_visibility,
         -- An identical request is idempotent and leaves updated_at alone.
         updated_at = case when r.visibility = p_visibility then r.updated_at else now() end
   where r.owner_user_id = v_uid
  returning r.* into v_room;

  if not found then
    raise exception 'ROOM_NOT_FOUND' using errcode = 'P0002';
  end if;
  return private.world_personal_room_json_v1(v_room);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.start_mcm_landlord_run_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
  v_event private.world_events%rowtype;
  v_run private.world_landlord_runs%rowtype;
  v_resumed boolean := true;
begin
  if v_uid is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;
  if not private.world_mcm_account_ok_v1(v_uid) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '42501';
  end if;
  select * into v_event from private.world_events where event_id = 'event.mcm_2026';
  if private.world_event_state_v1(v_event, now()) is distinct from 'ACTIVE' then
    raise exception 'EVENT_NOT_ACTIVE' using errcode = 'P0001';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('world_landlord:' || v_uid::text, 0));

  -- A run past its deadline is over, whether or not the player came back to it.
  update private.world_landlord_runs r
     set status = 'FAILED', ended_at = now()
   where r.user_id = v_uid and r.status = 'ACTIVE' and r.deadline_at <= now();

  select * into v_run from private.world_landlord_runs r where r.user_id = v_uid and r.status = 'ACTIVE';
  if not found then
    insert into private.world_landlord_runs (user_id, event_id, status, survivor_actor_id, deadline_at)
    values (v_uid, 'event.mcm_2026', 'ACTIVE', private.world_landlord_pick_survivor_v1(),
            now() + interval '45 seconds')
    returning * into v_run;
    v_resumed := false;
  end if;

  return jsonb_build_object(
    'runId', v_run.run_id,
    'status', v_run.status,
    'resumed', v_resumed,
    'startedAt', v_run.started_at,
    'deadlineAt', v_run.deadline_at,
    'serverNow', now(),
    'durationMs', 45000,
    'wrongPenaltyMs', 5000,
    'wrongCount', v_run.wrong_count,
    'actorIds', jsonb_build_array('ZUE-MG-001', 'ZUE-MG-002', 'ZUE-MG-003', 'ZUE-MG-004', 'ZUE-MG-005'));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.start_my_world_daily_quiz_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.world_daily_quiz_caller_v1(p_user);
  v_today date := private.world_daily_quiz_today_v1();
  v_major_count smallint;
  v_other_count smallint;
  v_questions text[];
begin
  -- One quiz decision per account at a time: concurrent starts wait, then see the same run.
  perform pg_advisory_xact_lock(hashtextextended('world_daily_quiz:' || v_uid::text, 0));

  if not exists (
    select 1
    from private.world_daily_quiz_runs r
    where r.user_id = v_uid
      and r.reward_date = v_today
  ) then
    v_major_count := private.world_daily_quiz_major_count_v1(v_uid, v_today);
    v_other_count := 3 - v_major_count;

    select array_agg(s.question_id order by gen_random_uuid())
      into v_questions
      from (
        (
          select q.question_id
          from private.world_daily_quiz_questions q
          where q.status = 'ACTIVE'
            and q.category = 'major'
          order by gen_random_uuid()
          limit v_major_count
        )
        union all
        (
          select q.question_id
          from private.world_daily_quiz_questions q
          where q.status = 'ACTIVE'
            and q.category <> 'major'
          order by gen_random_uuid()
          limit v_other_count
        )
      ) s;

    if coalesce(cardinality(v_questions), 0) < 3 then
      raise exception 'QUIZ_UNAVAILABLE' using errcode = 'P0001';
    end if;

    insert into private.world_daily_quiz_runs (user_id, reward_date, question_ids)
    values (v_uid, v_today, v_questions)
    on conflict (user_id, reward_date) do nothing;
  end if;

  return private.world_daily_quiz_state_v1(v_uid, v_today);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.submit_mcm_landlord_choice_v1(p_user uuid, p_run_id uuid, p_actor_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := p_user;
  v_event private.world_events%rowtype;
  v_run private.world_landlord_runs%rowtype;
  v_correct boolean := null;
  v_first boolean := false;
begin
  if v_uid is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;
  if not private.world_mcm_account_ok_v1(v_uid) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '42501';
  end if;
  if p_actor_id is null
     or p_actor_id not in ('ZUE-MG-001', 'ZUE-MG-002', 'ZUE-MG-003', 'ZUE-MG-004', 'ZUE-MG-005') then
    raise exception 'INVALID_ACTOR' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('world_landlord:' || v_uid::text, 0));

  select * into v_run from private.world_landlord_runs r where r.run_id = p_run_id for update;
  if not found or v_run.user_id <> v_uid then
    raise exception 'RUN_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_run.status = 'ACTIVE' then
    select * into v_event from private.world_events where event_id = v_run.event_id;
    if private.world_event_state_v1(v_event, now()) is distinct from 'ACTIVE' then
      raise exception 'EVENT_NOT_ACTIVE' using errcode = 'P0001';
    end if;
    if now() > v_run.deadline_at then
      update private.world_landlord_runs r set status = 'FAILED', ended_at = now()
       where r.run_id = v_run.run_id returning * into v_run;
    elsif p_actor_id = v_run.survivor_actor_id then
      v_correct := true;
      update private.world_landlord_runs r set status = 'CLEARED', ended_at = now()
       where r.run_id = v_run.run_id returning * into v_run;
      insert into private.world_landlord_first_clears (user_id, event_id, run_id)
      values (v_uid, v_run.event_id, v_run.run_id)
      on conflict (user_id, event_id) do nothing;
      v_first := found;
      perform private.world_mcm_try_complete_v1(v_uid);
    else
      v_correct := false;
      update private.world_landlord_runs r
         set wrong_count = r.wrong_count + 1,
             deadline_at = r.deadline_at - interval '5 seconds',
             status = case when r.deadline_at - interval '5 seconds' < now() then 'FAILED' else 'ACTIVE' end,
             ended_at = case when r.deadline_at - interval '5 seconds' < now() then now() end
       where r.run_id = v_run.run_id returning * into v_run;
    end if;
  end if;

  -- A terminal run is reported as it stands: resubmitting never clears it twice.
  return jsonb_build_object(
    'runId', v_run.run_id,
    'status', v_run.status,
    'correct', v_correct,
    'firstClear', v_first,
    'wrongCount', v_run.wrong_count,
    'deadlineAt', v_run.deadline_at,
    'serverNow', now(),
    'firstClearedAt', (select c.first_cleared_at from private.world_landlord_first_clears c
                        where c.user_id = v_uid and c.event_id = v_run.event_id));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.unblock_world_user(p_user uuid, p_target uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_caller uuid := private.world_social_caller(p_user);
begin
  if p_target is null or p_target = v_caller then raise exception 'TARGET_UNAVAILABLE' using errcode = '22023'; end if;
  perform private.world_lock_pair(v_caller, p_target);
  -- Only the caller's own block can be removed; the friendship is not restored.
  delete from public.world_user_blocks b where b.blocker_id = v_caller and b.blocked_id = p_target;
  return jsonb_build_object('userId', p_target, 'relationship', private.world_relationship(v_caller, p_target));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.unequip_my_world_item_v1(p_user uuid, p_slot text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.world_appearance_caller_v1(p_user);
  v_tx private.world_appearance_transactions;
  v_previous text;
begin
  if p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$' then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = '22023';
  end if;
  if not private.world_appearance_slot_ok_v1(p_slot) then
    raise exception 'INVALID_APPEARANCE_SLOT' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('world_appearance:' || v_uid::text, 0));

  select * into v_tx from private.world_appearance_transactions where idempotency_key = p_idempotency_key;
  if found then
    if v_tx.user_id = v_uid and v_tx.action = 'UNEQUIP' and v_tx.slot = p_slot then
      return private.world_appearance_result_v1(v_tx, true);
    end if;
    raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
  end if;

  select l.item_id into v_previous from private.world_player_appearance_loadout l
   where l.user_id = v_uid and l.slot = p_slot for update;

  v_tx := private.world_appearance_record_v1(v_uid, p_idempotency_key, 'UNEQUIP', p_slot, null, v_previous, null);
  if v_previous is not null then
    delete from private.world_player_appearance_loadout l where l.user_id = v_uid and l.slot = p_slot;
  end if;
  return private.world_appearance_result_v1(v_tx, false);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.unlock_my_world_life_node_v1(p_user uuid, p_node_id text, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := private.world_life_caller_v1(p_user);
  v_key text;
  v_skill_id text;
  v_result jsonb;
begin
  if p_request_id is null then
    raise exception 'INVALID_REQUEST_ID' using errcode = '22023';
  end if;
  v_key := 'life.unlock:' || v_user::text || ':' || p_request_id::text;

  -- A committed request replays even if the node was hidden afterwards.
  select t.skill_id into v_skill_id
    from private.world_life_sp_transactions t
   where t.idempotency_key = v_key;
  if not found then
    select n.skill_id into v_skill_id
      from private.world_life_skill_tree_catalog n
      join private.world_life_skill_catalog s on s.skill_id = n.skill_id
     where n.node_id = p_node_id and n.status = 'ACTIVE' and s.status = 'ACTIVE';
    if not found then
      raise exception 'LIFE_NODE_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;

  v_result := private.world_life_node_unlock_v1(v_user,p_node_id,v_key);
  return jsonb_build_object(
    'status',v_result->'status',
    'nodeId',v_result->'nodeId',
    'skillId',v_skill_id,
    'rankAfter',v_result->'rankAfter',
    'tree',private.world_life_book_tree_view_v1(v_user,v_skill_id)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_world_guestbook_entry_v2(p_user uuid, p_entry_id uuid, p_content text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.world_social_caller(p_user);
  v_content text := btrim(coalesce(p_content, ''));
  v_id uuid;
begin
  if char_length(v_content) < 1 or char_length(v_content) > 150 then
    raise exception 'INVALID_CONTENT' using errcode = '22023';
  end if;

  update public.world_guestbook_entries g
  set content = v_content
  where g.id = p_entry_id
    and g.user_id = v_uid
    and g.is_hidden = false
  returning g.id into v_id;

  if v_id is null then
    raise exception 'ENTRY_UNAVAILABLE' using errcode = '22023';
  end if;

  return private.world_guestbook_entry_json(v_id, v_uid);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.world_biryong_npc_relationship_advance_v1(p_user uuid, p_npc_id text, p_target_stage smallint, p_source_type text, p_source_ref text, p_result_ref text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select private.world_biryong_relationship_advance_v1(
    p_user,p_npc_id,p_target_stage,p_source_type,p_source_ref,p_result_ref,p_idempotency_key);
$function$
;

CREATE OR REPLACE FUNCTION public.world_campus_npc_relationship_apply_v1(p_user uuid, p_npc_id text, p_definition_version integer, p_event_type text, p_signal text, p_occurrence integer, p_requested_delta smallint, p_source_type text, p_source_ref text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select private.world_campus_npc_relationship_apply_v1(
    p_user,p_npc_id,p_definition_version,p_event_type,p_signal,p_occurrence,p_requested_delta,
    p_source_type,p_source_ref,p_idempotency_key);
$function$
;

CREATE OR REPLACE FUNCTION public.world_reward_grant_v1(p_user uuid, p_reward_id text, p_source_type text, p_source_id text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  -- Tier 4: no service_role JWT exists; the Worker is the server caller.
  return private.world_reward_grant_v1(p_user, p_reward_id, p_source_type, p_source_id, p_idempotency_key);
end;
$function$
;

-- ================= Session-ref triggers (was: FK to auth.users) =================

drop trigger if exists tier4_session_ref on private.world_appearance_transactions;
create trigger tier4_session_ref before insert or update of user_id on private.world_appearance_transactions for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_attendance_days;
create trigger tier4_session_ref before insert or update of user_id on private.world_attendance_days for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_biryong_npc_relationship_events;
create trigger tier4_session_ref before insert or update of user_id on private.world_biryong_npc_relationship_events for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_biryong_progress_v1;
create trigger tier4_session_ref before insert or update of user_id on private.world_biryong_progress_v1 for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_campus_npc_relationship_events;
create trigger tier4_session_ref before insert or update of user_id on private.world_campus_npc_relationship_events for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_daily_quiz_runs;
create trigger tier4_session_ref before insert or update of user_id on private.world_daily_quiz_runs for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_event_progress;
create trigger tier4_session_ref before insert or update of user_id on private.world_event_progress for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_guestbook_post_log;
create trigger tier4_session_ref before insert or update of user_id on private.world_guestbook_post_log for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_inventory_mutations;
create trigger tier4_session_ref before insert or update of user_id on private.world_inventory_mutations for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_item_consumptions;
create trigger tier4_session_ref before insert or update of user_id on private.world_item_consumptions for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_item_grants;
create trigger tier4_session_ref before insert or update of user_id on private.world_item_grants for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_jeongseok_pass_entitlements;
create trigger tier4_session_ref before insert or update of user_id on private.world_jeongseok_pass_entitlements for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_jeongseok_pass_purchases;
create trigger tier4_session_ref before insert or update of user_id on private.world_jeongseok_pass_purchases for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_landlord_first_clears;
create trigger tier4_session_ref before insert or update of user_id on private.world_landlord_first_clears for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_landlord_runs;
create trigger tier4_session_ref before insert or update of user_id on private.world_landlord_runs for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_life_sp_transactions;
create trigger tier4_session_ref before insert or update of user_id on private.world_life_sp_transactions for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_life_tree_resets;
create trigger tier4_session_ref before insert or update of user_id on private.world_life_tree_resets for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_mcm_reward_claims;
create trigger tier4_session_ref before insert or update of user_id on private.world_mcm_reward_claims for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_player_appearance_loadout;
create trigger tier4_session_ref before insert or update of user_id on private.world_player_appearance_loadout for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_player_biryong_npc_relationships;
create trigger tier4_session_ref before insert or update of user_id on private.world_player_biryong_npc_relationships for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_player_campus_npc_relationships;
create trigger tier4_session_ref before insert or update of user_id on private.world_player_campus_npc_relationships for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_player_items;
create trigger tier4_session_ref before insert or update of user_id on private.world_player_items for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_player_life_nodes;
create trigger tier4_session_ref before insert or update of user_id on private.world_player_life_nodes for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_player_life_skills;
create trigger tier4_session_ref before insert or update of user_id on private.world_player_life_skills for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_player_progression;
create trigger tier4_session_ref before insert or update of user_id on private.world_player_progression for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_purchase_transactions;
create trigger tier4_session_ref before insert or update of user_id on private.world_purchase_transactions for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_recipe_receipts;
create trigger tier4_session_ref before insert or update of user_id on private.world_recipe_receipts for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_reward_transactions;
create trigger tier4_session_ref before insert or update of user_id on private.world_reward_transactions for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_room_knocks;
create trigger tier4_session_ref before insert or update of visitor_user_id on private.world_room_knocks for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (visitor_user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_staff_assignments;
create trigger tier4_session_ref before insert or update of user_id on private.world_staff_assignments for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_user_moderation_actions;
create trigger tier4_session_ref before insert or update of actor_id on private.world_user_moderation_actions for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (actor_id) REFERENCES auth.users(id) ON DELETE SET NULL

drop trigger if exists tier4_session_ref on private.world_user_moderation_actions;
create trigger tier4_session_ref before insert or update of target_id on private.world_user_moderation_actions for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (target_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on private.world_wallets;
create trigger tier4_session_ref before insert or update of user_id on private.world_wallets for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.classic_event_badges;
create trigger tier4_session_ref before insert or update of user_id on public.classic_event_badges for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.game_events;
create trigger tier4_session_ref before insert or update of user_id on public.game_events for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL

drop trigger if exists tier4_session_ref on public.general_stage_bests;
create trigger tier4_session_ref before insert or update of user_id on public.general_stage_bests for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.induckup_ranked_bests;
create trigger tier4_session_ref before insert or update of user_id on public.induckup_ranked_bests for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.inha_mail_badges;
create trigger tier4_session_ref before insert or update of user_id on public.inha_mail_badges for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.player_bests;
create trigger tier4_session_ref before insert or update of user_id on public.player_bests for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.players;
create trigger tier4_session_ref before insert or update of auth_user_id on public.players for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (auth_user_id) REFERENCES auth.users(id) ON DELETE SET NULL

drop trigger if exists tier4_session_ref on public.profiles;
create trigger tier4_session_ref before insert or update of user_id on public.profiles for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.ranked_runs;
create trigger tier4_session_ref before insert or update of user_id on public.ranked_runs for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.ranked_sessions;
create trigger tier4_session_ref before insert or update of user_id on public.ranked_sessions for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.user_achievements;
create trigger tier4_session_ref before insert or update of user_id on public.user_achievements for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.user_game_progress;
create trigger tier4_session_ref before insert or update of user_id on public.user_game_progress for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.world_accompany_sessions;
create trigger tier4_session_ref before insert or update of invitee_id on public.world_accompany_sessions for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (invitee_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.world_accompany_sessions;
create trigger tier4_session_ref before insert or update of inviter_id on public.world_accompany_sessions for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (inviter_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.world_friendships;
create trigger tier4_session_ref before insert or update of requested_by on public.world_friendships for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (requested_by) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.world_friendships;
create trigger tier4_session_ref before insert or update of user_high on public.world_friendships for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_high) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.world_friendships;
create trigger tier4_session_ref before insert or update of user_low on public.world_friendships for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_low) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.world_guestbook_entries;
create trigger tier4_session_ref before insert or update of user_id on public.world_guestbook_entries for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.world_player_rooms;
create trigger tier4_session_ref before insert or update of owner_user_id on public.world_player_rooms for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (owner_user_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.world_user_blocks;
create trigger tier4_session_ref before insert or update of blocked_id on public.world_user_blocks for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (blocked_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.world_user_blocks;
create trigger tier4_session_ref before insert or update of blocker_id on public.world_user_blocks for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (blocker_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.world_user_reports;
create trigger tier4_session_ref before insert or update of reporter_id on public.world_user_reports for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (reporter_id) REFERENCES auth.users(id) ON DELETE CASCADE

drop trigger if exists tier4_session_ref on public.world_user_reports;
create trigger tier4_session_ref before insert or update of target_id on public.world_user_reports for each row execute function private.tier4_require_session_v1();  -- was: FOREIGN KEY (target_id) REFERENCES auth.users(id) ON DELETE CASCADE

-- ================= Kept triggers =================

drop trigger if exists world_appearance_transactions_append_only on private.world_appearance_transactions;
CREATE TRIGGER world_appearance_transactions_append_only BEFORE UPDATE ON private.world_appearance_transactions FOR EACH ROW EXECUTE FUNCTION private.world_appearance_transactions_append_only_v1();

drop trigger if exists world_biryong_relationship_event_append_only on private.world_biryong_npc_relationship_events;
CREATE TRIGGER world_biryong_relationship_event_append_only BEFORE DELETE OR UPDATE ON private.world_biryong_npc_relationship_events FOR EACH ROW EXECUTE FUNCTION private.world_biryong_relationship_event_append_only_v1();

drop trigger if exists world_campus_npc_relationship_event_append_only on private.world_campus_npc_relationship_events;
CREATE TRIGGER world_campus_npc_relationship_event_append_only BEFORE DELETE OR UPDATE ON private.world_campus_npc_relationship_events FOR EACH ROW EXECUTE FUNCTION private.world_campus_npc_relationship_event_append_only_v1();

drop trigger if exists world_currency_transactions_append_only on private.world_currency_transactions;
CREATE TRIGGER world_currency_transactions_append_only BEFORE UPDATE ON private.world_currency_transactions FOR EACH ROW EXECUTE FUNCTION private.world_currency_transactions_append_only_v1();

drop trigger if exists world_exp_transactions_append_only on private.world_exp_transactions;
CREATE TRIGGER world_exp_transactions_append_only BEFORE UPDATE ON private.world_exp_transactions FOR EACH ROW EXECUTE FUNCTION private.world_exp_transactions_append_only_v1();

drop trigger if exists world_inventory_mutation_entries_append_only on private.world_inventory_mutation_entries;
CREATE TRIGGER world_inventory_mutation_entries_append_only BEFORE UPDATE ON private.world_inventory_mutation_entries FOR EACH ROW EXECUTE FUNCTION private.world_inventory_mutation_append_only_v1();

drop trigger if exists world_inventory_mutations_append_only on private.world_inventory_mutations;
CREATE TRIGGER world_inventory_mutations_append_only BEFORE UPDATE ON private.world_inventory_mutations FOR EACH ROW EXECUTE FUNCTION private.world_inventory_mutation_append_only_v1();

drop trigger if exists world_item_consumptions_append_only on private.world_item_consumptions;
CREATE TRIGGER world_item_consumptions_append_only BEFORE UPDATE ON private.world_item_consumptions FOR EACH ROW EXECUTE FUNCTION private.world_inventory_mutation_append_only_v1();

drop trigger if exists world_item_grants_append_only on private.world_item_grants;
CREATE TRIGGER world_item_grants_append_only BEFORE UPDATE ON private.world_item_grants FOR EACH ROW EXECUTE FUNCTION private.world_item_grants_append_only_v1();

drop trigger if exists world_jeongseok_pass_purchases_append_only on private.world_jeongseok_pass_purchases;
CREATE TRIGGER world_jeongseok_pass_purchases_append_only BEFORE DELETE OR UPDATE ON private.world_jeongseok_pass_purchases FOR EACH ROW EXECUTE FUNCTION private.world_jeongseok_pass_purchase_append_only_v1();

drop trigger if exists world_level_thresholds_immutable on private.world_level_thresholds;
CREATE TRIGGER world_level_thresholds_immutable BEFORE DELETE OR UPDATE ON private.world_level_thresholds FOR EACH ROW EXECUTE FUNCTION private.world_level_thresholds_immutable_v1();

drop trigger if exists world_level_thresholds_validate_insert on private.world_level_thresholds;
CREATE TRIGGER world_level_thresholds_validate_insert BEFORE INSERT ON private.world_level_thresholds FOR EACH ROW EXECUTE FUNCTION private.world_level_thresholds_validate_insert_v1();

drop trigger if exists world_life_progression_threshold_immutable on private.world_life_progression_thresholds;
CREATE TRIGGER world_life_progression_threshold_immutable BEFORE DELETE OR UPDATE ON private.world_life_progression_thresholds FOR EACH ROW EXECUTE FUNCTION private.world_life_progression_threshold_immutable_v1();

drop trigger if exists world_life_progression_threshold_validate_insert on private.world_life_progression_thresholds;
CREATE TRIGGER world_life_progression_threshold_validate_insert BEFORE INSERT ON private.world_life_progression_thresholds FOR EACH ROW EXECUTE FUNCTION private.world_life_progression_threshold_validate_insert_v1();

drop trigger if exists world_life_skill_threshold_immutable on private.world_life_skill_thresholds;
CREATE TRIGGER world_life_skill_threshold_immutable BEFORE DELETE OR UPDATE ON private.world_life_skill_thresholds FOR EACH ROW EXECUTE FUNCTION private.world_life_skill_threshold_immutable_v1();

drop trigger if exists world_life_skill_threshold_validate_insert on private.world_life_skill_thresholds;
CREATE TRIGGER world_life_skill_threshold_validate_insert BEFORE INSERT ON private.world_life_skill_thresholds FOR EACH ROW EXECUTE FUNCTION private.world_life_skill_threshold_validate_insert_v1();

drop trigger if exists world_life_tree_node_guard on private.world_life_skill_tree_catalog;
CREATE TRIGGER world_life_tree_node_guard BEFORE DELETE OR UPDATE ON private.world_life_skill_tree_catalog FOR EACH ROW EXECUTE FUNCTION private.world_life_tree_node_guard_v1();

drop trigger if exists world_life_tree_edge_validate on private.world_life_skill_tree_edges;
CREATE TRIGGER world_life_tree_edge_validate BEFORE INSERT OR DELETE OR UPDATE ON private.world_life_skill_tree_edges FOR EACH ROW EXECUTE FUNCTION private.world_life_tree_edge_validate_v1();

drop trigger if exists world_life_sp_append_only on private.world_life_sp_transactions;
CREATE TRIGGER world_life_sp_append_only BEFORE DELETE OR UPDATE ON private.world_life_sp_transactions FOR EACH ROW EXECUTE FUNCTION private.world_life_sp_append_only_v1();

drop trigger if exists world_life_tree_resets_append_only on private.world_life_tree_resets;
CREATE TRIGGER world_life_tree_resets_append_only BEFORE DELETE OR UPDATE ON private.world_life_tree_resets FOR EACH ROW EXECUTE FUNCTION private.world_life_tree_resets_append_only_v1();

drop trigger if exists world_mcm_reward_claims_final on private.world_mcm_reward_claims;
CREATE TRIGGER world_mcm_reward_claims_final BEFORE UPDATE ON private.world_mcm_reward_claims FOR EACH ROW EXECUTE FUNCTION private.world_mcm_reward_claims_final_v1();

drop trigger if exists world_biryong_relationship_projection_guard on private.world_player_biryong_npc_relationships;
CREATE TRIGGER world_biryong_relationship_projection_guard BEFORE UPDATE ON private.world_player_biryong_npc_relationships FOR EACH ROW EXECUTE FUNCTION private.world_biryong_relationship_projection_guard_v1();

drop trigger if exists world_campus_npc_relationship_projection_guard on private.world_player_campus_npc_relationships;
CREATE TRIGGER world_campus_npc_relationship_projection_guard BEFORE UPDATE ON private.world_player_campus_npc_relationships FOR EACH ROW EXECUTE FUNCTION private.world_campus_npc_relationship_projection_guard_v1();

drop trigger if exists world_life_nodes_append_only on private.world_player_life_nodes;
CREATE TRIGGER world_life_nodes_append_only BEFORE DELETE OR UPDATE ON private.world_player_life_nodes FOR EACH ROW EXECUTE FUNCTION private.world_life_nodes_append_only_v1();

drop trigger if exists world_purchase_transactions_append_only on private.world_purchase_transactions;
CREATE TRIGGER world_purchase_transactions_append_only BEFORE UPDATE ON private.world_purchase_transactions FOR EACH ROW EXECUTE FUNCTION private.world_purchase_transactions_append_only_v1();

drop trigger if exists world_recipe_receipts_append_only on private.world_recipe_receipts;
CREATE TRIGGER world_recipe_receipts_append_only BEFORE DELETE OR UPDATE ON private.world_recipe_receipts FOR EACH ROW EXECUTE FUNCTION private.world_recipe_receipt_append_only_v1();

drop trigger if exists world_reward_grants_validate on private.world_reward_grants;
CREATE TRIGGER world_reward_grants_validate BEFORE INSERT OR UPDATE ON private.world_reward_grants FOR EACH ROW EXECUTE FUNCTION private.world_reward_grants_validate_v1();

drop trigger if exists world_reward_entries_final on private.world_reward_transaction_entries;
CREATE TRIGGER world_reward_entries_final BEFORE UPDATE ON private.world_reward_transaction_entries FOR EACH ROW EXECUTE FUNCTION private.world_reward_final_rows_v1();

drop trigger if exists world_reward_transactions_final on private.world_reward_transactions;
CREATE TRIGGER world_reward_transactions_final BEFORE UPDATE ON private.world_reward_transactions FOR EACH ROW EXECUTE FUNCTION private.world_reward_final_rows_v1();

drop trigger if exists world_shop_listings_validate on private.world_shop_listings;
CREATE TRIGGER world_shop_listings_validate BEFORE INSERT OR UPDATE ON private.world_shop_listings FOR EACH ROW EXECUTE FUNCTION private.world_shop_listings_validate_v1();

drop trigger if exists world_guestbook_normalize_before_write on public.world_guestbook_entries;
CREATE TRIGGER world_guestbook_normalize_before_write BEFORE INSERT OR UPDATE OF content ON public.world_guestbook_entries FOR EACH ROW EXECUTE FUNCTION private.world_guestbook_normalize();

-- ================= Seeds (idempotent per row via ON CONFLICT DO NOTHING) =================

-- Deterministic reference seeds only.
INSERT INTO "public"."games" ("created_at","id","metadata","name","released_at","slug","status","updated_at") VALUES ('2026-10-01T21:31:32Z','2619e309-a236-57cb-b232-38144cb46ca4','{"account_platform":"inhagame"}','인덕 서바이벌',NULL,'inha-duck-survival','testing','2026-10-01T21:31:32Z') on conflict do nothing;

INSERT INTO "public"."games" ("created_at","id","metadata","name","released_at","slug","status","updated_at") VALUES ('2026-10-01T21:31:32Z','3a10becf-686c-5ba7-8daa-3867946c83ee','{"account_platform":"inhagame"}','인덕업',NULL,'induckup','testing','2026-10-01T21:31:32Z') on conflict do nothing;

INSERT INTO "public"."games" ("created_at","id","metadata","name","released_at","slug","status","updated_at") VALUES ('2026-10-01T21:31:32Z','88db5186-c719-5b75-90df-27a54e6a2535','{"legacy_project":"inha-duck","migration_source":"multi_game_core_v1"}','인하오리 Classic',NULL,'inha-duck','production','2026-10-01T21:31:32Z') on conflict do nothing;

INSERT INTO "public"."games" ("created_at","id","metadata","name","released_at","slug","status","updated_at") VALUES ('2026-10-01T21:31:32Z','f06be21f-756b-50ca-8b29-5930502db86c','{"account_platform":"inhagame"}','인덕이 키우기','2026-10-01T21:31:32Z','induck-grow','production','2026-10-01T21:31:32Z') on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',1,'학과 미선택',9999) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',10,'환경공학과',9) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',11,'공간정보공학과',10) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',12,'건축학부',11) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',13,'에너지자원공학과',12) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',14,'전기전자공학부',13) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',15,'반도체시스템공학과',14) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',16,'이차전지융합학과',15) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',17,'수학과',16) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',18,'통계학과',17) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',19,'물리학과',18) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',2,'기계공학과',1) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',20,'화학과',19) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',21,'해양과학과',20) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',22,'식품영양학과',21) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',23,'경영학과',22) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',24,'파이낸스경영학과',23) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',25,'아태물류학부',24) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',26,'국제통상학과',25) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',27,'국어교육과',26) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',28,'영어교육과',27) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',29,'사회교육과',28) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',3,'항공우주공학과',2) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',30,'체육교육과',29) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',31,'교육학과',30) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',32,'수학교육과',31) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',33,'행정학과',32) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',34,'정치외교학과',33) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',35,'미디어커뮤니케이션학과',34) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',36,'경제학과',35) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',37,'소비자학과',36) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',38,'아동심리학과',37) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',39,'사회복지학과',38) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',4,'조선해양공학과',3) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',40,'한국어문학과',39) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',41,'사학과',40) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',42,'철학과',41) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',43,'중국학과',42) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',44,'일본언어문화학과',43) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',45,'영미유럽인문융합학부',44) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',46,'문화콘텐츠문화경영학과',45) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',47,'의예과',46) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',48,'간호학과',47) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',49,'조형예술학과',48) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',5,'산업경영공학과',4) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',50,'디자인융합학과',49) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',51,'스포츠과학과',50) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',52,'연극영화학과',51) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',53,'의류디자인학과',52) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',54,'인공지능공학과',53) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',55,'데이터사이언스학과',54) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',56,'스마트모빌리티공학과',55) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',57,'디자인테크놀로지학과',56) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',58,'컴퓨터공학과',57) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',59,'IBT학과',58) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',6,'화학공학과',5) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',60,'ISE학과',59) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',61,'KLC학과',60) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',62,'자유전공학부',61) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',63,'메카트로닉스공학과',62) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',64,'소프트웨어융합공학과',63) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',65,'산업경영학과',64) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',66,'금융투자학과',65) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',67,'반도체산업융합학과',66) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',7,'고분자공학과',6) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',8,'신소재공학과',7) on conflict do nothing;

INSERT INTO "public"."departments" ("active","created_at","id","name","sort_order") VALUES (true,'2026-10-01T21:31:32Z',9,'사회인프라공학과',8) on conflict do nothing;

INSERT INTO "private"."world_currencies" ("created_at","currency_id","display_name") VALUES ('2026-10-01T21:31:32Z','currency.induck_coin','인덕코인') on conflict do nothing;

INSERT INTO "private"."world_daily_quiz_questions" ("category","correct_index","created_at","options","position","prompt","question_id","status","version") VALUES ('controls',0,'2026-10-01T21:31:32Z','["E","F","C","Enter"]',3,'PC에서 감정표현 메뉴를 여는 키는?','quiz.campus.emote_key','ACTIVE',1) on conflict do nothing;

INSERT INTO "private"."world_daily_quiz_questions" ("category","correct_index","created_at","options","position","prompt","question_id","status","version") VALUES ('controls',1,'2026-10-01T21:31:32Z','["E","F","M","V"]',2,'PC에서 NPC와 대화하거나 앉기·방명록·문 같은 상호작용을 하는 키는?','quiz.campus.interact_key','ACTIVE',1) on conflict do nothing;

INSERT INTO "private"."world_daily_quiz_questions" ("category","correct_index","created_at","options","position","prompt","question_id","status","version") VALUES ('controls',1,'2026-10-01T21:31:32Z','["Tab","V","C","E"]',5,'PC에서 1인칭·3인칭 시점을 전환하는 키는?','quiz.campus.view_key','ACTIVE',1) on conflict do nothing;

INSERT INTO "private"."world_daily_quiz_questions" ("category","correct_index","created_at","options","position","prompt","question_id","status","version") VALUES ('controls',3,'2026-10-01T21:31:32Z','["F","V","Space","M"]',4,'PC에서 탈것에 타거나 내리는 키는?','quiz.campus.mount_key','ACTIVE',1) on conflict do nothing;

INSERT INTO "private"."world_daily_quiz_questions" ("category","correct_index","created_at","options","position","prompt","question_id","status","version") VALUES ('economy',0,'2026-10-01T21:31:32Z','["인덕코인","인하포인트","캠퍼스머니","오리코인"]',1,'INHA WORLD에서 상점 결제에 쓰는 재화의 이름은?','quiz.campus.currency_name','ACTIVE',1) on conflict do nothing;

INSERT INTO "private"."world_daily_quiz_questions" ("category","correct_index","created_at","options","position","prompt","question_id","status","version") VALUES ('equipment',1,'2026-10-01T21:31:32Z','["상의","머리","등","신발"]',14,'인덕 캠퍼스 캡은 옷장에서 어느 슬롯에 착용될까?','quiz.campus.cap_slot','ACTIVE',1) on conflict do nothing;

INSERT INTO "private"."world_daily_quiz_questions" ("category","correct_index","created_at","options","position","prompt","question_id","status","version") VALUES ('navigation',1,'2026-10-01T21:31:32Z','["본관","5호관","학생회관","정문"]',9,'길찾기 익히기에서 처음 목적지로 설정하는 건물은?','quiz.campus.navigation_target','ACTIVE',1) on conflict do nothing;

INSERT INTO "private"."world_daily_quiz_questions" ("category","correct_index","created_at","options","position","prompt","question_id","status","version") VALUES ('navigation',1,'2026-10-01T21:31:32Z','["점프","일시정지 후 재개","탈것 타기","감정표현"]',10,'길찾기 익히기에서 자동이동 도중 한 번 해 보는 조작은?','quiz.campus.navigation_pause','ACTIVE',1) on conflict do nothing;

INSERT INTO "private"."world_daily_quiz_questions" ("category","correct_index","created_at","options","position","prompt","question_id","status","version") VALUES ('navigation',3,'2026-10-01T21:31:32Z','["정문","인경호","본관 앞","후문"]',11,'길찾기 익히기를 마치려면 자동이동으로 어디까지 돌아가야 할까?','quiz.campus.navigation_return','ACTIVE',1) on conflict do nothing;

INSERT INTO "private"."world_daily_quiz_questions" ("category","correct_index","created_at","options","position","prompt","question_id","status","version") VALUES ('progression',1,'2026-10-01T21:31:32Z','["50","100","200","300"]',15,'Lv.2가 되려면 누적 EXP가 얼마 필요할까?','quiz.campus.level_two','ACTIVE',1) on conflict do nothing;

INSERT INTO "private"."world_daily_quiz_questions" ("category","correct_index","created_at","options","position","prompt","question_id","status","version") VALUES ('quest',1,'2026-10-01T21:31:32Z','["가유담","나나율","후문 안내 학생","인덕이"]',6,'정문에서 첫 캠퍼스 탐방을 시작하게 해 주는 학생은?','quiz.campus.first_walk_npc','ACTIVE',1) on conflict do nothing;

INSERT INTO "private"."world_daily_quiz_questions" ("category","correct_index","created_at","options","position","prompt","question_id","status","version") VALUES ('quest',1,'2026-10-01T21:31:32Z','["본관 앞","인경호","학생회관","5호관"]',7,'첫 캠퍼스 탐방에서 가유담을 만나는 곳은?','quiz.campus.first_walk_guide','ACTIVE',1) on conflict do nothing;

INSERT INTO "private"."world_daily_quiz_questions" ("category","correct_index","created_at","options","position","prompt","question_id","status","version") VALUES ('quest',2,'2026-10-01T21:31:32Z','["5호관","후문","본관 앞","학생회관"]',8,'첫 캠퍼스 탐방에서 인경호보다 먼저 방문하는 곳은?','quiz.campus.first_walk_order','ACTIVE',1) on conflict do nothing;

INSERT INTO "private"."world_daily_quiz_questions" ("category","correct_index","created_at","options","position","prompt","question_id","status","version") VALUES ('reward',0,'2026-10-01T21:31:32Z','["정문 첫걸음 배지","건물주 챌린지 배지","인경호 산책 배지","5호관 탐험 배지"]',13,'첫 캠퍼스 탐방을 완료하면 받는 배지는?','quiz.campus.first_walk_badge','ACTIVE',1) on conflict do nothing;

INSERT INTO "private"."world_daily_quiz_questions" ("category","correct_index","created_at","options","position","prompt","question_id","status","version") VALUES ('shop',0,'2026-10-01T21:31:32Z','["학생회관 상점","정문 매점","본관 기념품점","인경호 매점"]',12,'캠퍼스에서 인덕코인으로 아이템을 사는 상점의 이름은?','quiz.campus.shop_name','ACTIVE',1) on conflict do nothing;

INSERT INTO "private"."world_daily_quiz_questions" ("category","correct_index","created_at","options","position","prompt","question_id","status","version") VALUES ('world',0,'2026-10-01T21:31:32Z','["☰ 메뉴","지도","채팅창","프로필 카드"]',16,'인벤토리·옷장·상점은 어디에서 열 수 있을까?','quiz.campus.menu_panels','ACTIVE',1) on conflict do nothing;

INSERT INTO "private"."world_events" ("created_at","ends_at","event_id","is_disabled","starts_at","title") VALUES ('2026-10-01T21:31:32Z','2026-09-30T16:00:00+00:00','event.mcm_2026',false,'2026-09-29T15:00:00+00:00','좀비대학교 · 2026 문콘경 일일호프') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('BADGE','badge.campus_explorer',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('BADGE','badge.campus_first_step',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('BADGE','badge.main_gate',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('BADGE','badge.mcm_2026_landlord',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('EMOTE','emote.wave_plus',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('FURNITURE','furniture.campus_map_poster',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('FURNITURE','furniture.campus_rug_blue',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('FURNITURE','furniture.dorm_desk_lamp',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('FURNITURE','furniture.dorm_resident_plate',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('FURNITURE','furniture.induck_chair',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('FURNITURE','furniture.induck_cushion',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('FURNITURE','furniture.mcm_2026_landlord_figure',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('FURNITURE','furniture.mcm_2026_poster',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('FURNITURE','furniture.mini_induck',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('MEMORABILIA','memorabilia.campus_mug',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('MEMORABILIA','memorabilia.mcm_2026_wristband',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('WEARABLE','back.freshman_bag',NULL,'UNIQUE','ACTIVE') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('WEARABLE','back.induck_backpack',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('WEARABLE','head.induck_cap',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('WEARABLE','head.inha_cap',NULL,'UNIQUE','ACTIVE') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('WEARABLE','head.inkyung_duck',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('WEARABLE','shoes.campus_sneakers',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('WEARABLE','top.induck_hoodie',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('WEARABLE','top.inha_basic',NULL,'UNIQUE','ACTIVE') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('WEARABLE','top.mcm_2026_survivor',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

INSERT INTO "private"."world_item_catalog" ("category","item_id","max_stack","ownership_policy","status") VALUES ('WEARABLE','top.mcm_jacket',NULL,'UNIQUE','COMING_SOON') on conflict do nothing;

do $$ begin if not exists (select 1 from private.world_level_thresholds where level = 1) then INSERT INTO "private"."world_level_thresholds" ("created_at","level","min_total_exp") VALUES ('2026-10-01T21:31:32Z',1,0); end if; end $$;

do $$ begin if not exists (select 1 from private.world_level_thresholds where level = 2) then INSERT INTO "private"."world_level_thresholds" ("created_at","level","min_total_exp") VALUES ('2026-10-01T21:31:32Z',2,100); end if; end $$;

do $$ begin if not exists (select 1 from private.world_level_thresholds where level = 3) then INSERT INTO "private"."world_level_thresholds" ("created_at","level","min_total_exp") VALUES ('2026-10-01T21:31:32Z',3,300); end if; end $$;

do $$ begin if not exists (select 1 from private.world_level_thresholds where level = 4) then INSERT INTO "private"."world_level_thresholds" ("created_at","level","min_total_exp") VALUES ('2026-10-01T21:31:32Z',4,600); end if; end $$;

do $$ begin if not exists (select 1 from private.world_level_thresholds where level = 5) then INSERT INTO "private"."world_level_thresholds" ("created_at","level","min_total_exp") VALUES ('2026-10-01T21:31:32Z',5,1000); end if; end $$;

do $$ begin if not exists (select 1 from private.world_level_thresholds where level = 6) then INSERT INTO "private"."world_level_thresholds" ("created_at","level","min_total_exp") VALUES ('2026-10-01T21:31:32Z',6,1500); end if; end $$;

do $$ begin if not exists (select 1 from private.world_level_thresholds where level = 7) then INSERT INTO "private"."world_level_thresholds" ("created_at","level","min_total_exp") VALUES ('2026-10-01T21:31:32Z',7,2100); end if; end $$;

do $$ begin if not exists (select 1 from private.world_level_thresholds where level = 8) then INSERT INTO "private"."world_level_thresholds" ("created_at","level","min_total_exp") VALUES ('2026-10-01T21:31:32Z',8,2800); end if; end $$;

do $$ begin if not exists (select 1 from private.world_level_thresholds where level = 9) then INSERT INTO "private"."world_level_thresholds" ("created_at","level","min_total_exp") VALUES ('2026-10-01T21:31:32Z',9,3600); end if; end $$;

do $$ begin if not exists (select 1 from private.world_level_thresholds where level = 10) then INSERT INTO "private"."world_level_thresholds" ("created_at","level","min_total_exp") VALUES ('2026-10-01T21:31:32Z',10,4500); end if; end $$;

INSERT INTO "private"."world_reward_definitions" ("created_at","description","event_id","reward_id","status","tags","version") VALUES ('2026-10-01T21:31:32Z','2026 문콘경 일일호프 핵심 이벤트 완주 보상','event.mcm_2026','reward.event.mcm_2026_main_clear','ACTIVE',ARRAY['event','mcm_2026']::text[],2) on conflict do nothing;

INSERT INTO "private"."world_reward_definitions" ("created_at","description","event_id","reward_id","status","tags","version") VALUES ('2026-10-01T21:31:32Z','건물주 미니게임 첫 클리어 보상','event.mcm_2026','reward.minigame.landlord_first_clear','ACTIVE',ARRAY['minigame','mcm_2026']::text[],2) on conflict do nothing;

INSERT INTO "private"."world_reward_definitions" ("created_at","description","event_id","reward_id","status","tags","version") VALUES ('2026-10-01T21:31:32Z','길찾기 익히기 완료 보상',NULL,'reward.quest.navigation_intro','ACTIVE',ARRAY['quest','tutorial','navigation']::text[],1) on conflict do nothing;

INSERT INTO "private"."world_reward_definitions" ("created_at","description","event_id","reward_id","status","tags","version") VALUES ('2026-10-01T21:31:32Z','첫 캠퍼스 탐방 완료 보상',NULL,'reward.quest.first_campus','ACTIVE',ARRAY['quest']::text[],2) on conflict do nothing;

INSERT INTO "private"."world_reward_definitions" ("created_at","description","event_id","reward_id","status","tags","version") VALUES ('2026-10-01T21:31:32Z','캠퍼스 데일리 퀴즈 완료 보상',NULL,'reward.daily.campus_quiz','ACTIVE',ARRAY['daily','minigame','quiz']::text[],1) on conflict do nothing;

INSERT INTO "private"."world_reward_definitions" ("created_at","description","event_id","reward_id","status","tags","version") VALUES ('2026-10-01T21:31:32Z','캠퍼스 출석부 이번 달 14일 출석 보상',NULL,'reward.attendance.monthly_14','ACTIVE',ARRAY['attendance','monthly']::text[],1) on conflict do nothing;

INSERT INTO "private"."world_reward_definitions" ("created_at","description","event_id","reward_id","status","tags","version") VALUES ('2026-10-01T21:31:32Z','캠퍼스 출석부 이번 달 21일 출석 보상',NULL,'reward.attendance.monthly_21','ACTIVE',ARRAY['attendance','monthly']::text[],1) on conflict do nothing;

INSERT INTO "private"."world_reward_definitions" ("created_at","description","event_id","reward_id","status","tags","version") VALUES ('2026-10-01T21:31:32Z','캠퍼스 출석부 이번 달 3일 출석 보상',NULL,'reward.attendance.monthly_3','ACTIVE',ARRAY['attendance','monthly']::text[],1) on conflict do nothing;

INSERT INTO "private"."world_reward_definitions" ("created_at","description","event_id","reward_id","status","tags","version") VALUES ('2026-10-01T21:31:32Z','캠퍼스 출석부 이번 달 7일 출석 보상',NULL,'reward.attendance.monthly_7','ACTIVE',ARRAY['attendance','monthly']::text[],1) on conflict do nothing;

INSERT INTO "private"."world_reward_definitions" ("created_at","description","event_id","reward_id","status","tags","version") VALUES ('2026-10-01T21:31:32Z','캠퍼스 출석부 일일 출석 보상',NULL,'reward.attendance.daily','ACTIVE',ARRAY['attendance','daily']::text[],1) on conflict do nothing;

INSERT INTO "private"."world_reward_grants" ("amount","grant_entry_id","grant_type","position","reward_id","target_id") VALUES (1,'item.badge.main_gate','ITEM',0,'reward.quest.first_campus','badge.main_gate') on conflict do nothing;

INSERT INTO "private"."world_reward_grants" ("amount","grant_entry_id","grant_type","position","reward_id","target_id") VALUES (1,'item.badge.mcm_2026_landlord','ITEM',0,'reward.minigame.landlord_first_clear','badge.mcm_2026_landlord') on conflict do nothing;

INSERT INTO "private"."world_reward_grants" ("amount","grant_entry_id","grant_type","position","reward_id","target_id") VALUES (1,'item.furniture.mcm_2026_poster','ITEM',2,'reward.event.mcm_2026_main_clear','furniture.mcm_2026_poster') on conflict do nothing;

INSERT INTO "private"."world_reward_grants" ("amount","grant_entry_id","grant_type","position","reward_id","target_id") VALUES (1,'item.top.mcm_2026_survivor','ITEM',1,'reward.event.mcm_2026_main_clear','top.mcm_2026_survivor') on conflict do nothing;

INSERT INTO "private"."world_reward_grants" ("amount","grant_entry_id","grant_type","position","reward_id","target_id") VALUES (10,'currency.induck_coin','CURRENCY',0,'reward.attendance.daily','currency.induck_coin') on conflict do nothing;

INSERT INTO "private"."world_reward_grants" ("amount","grant_entry_id","grant_type","position","reward_id","target_id") VALUES (100,'currency.induck_coin','CURRENCY',0,'reward.attendance.monthly_14','currency.induck_coin') on conflict do nothing;

INSERT INTO "private"."world_reward_grants" ("amount","grant_entry_id","grant_type","position","reward_id","target_id") VALUES (100,'exp.campus','EXP',1,'reward.quest.first_campus','exp.campus') on conflict do nothing;

INSERT INTO "private"."world_reward_grants" ("amount","grant_entry_id","grant_type","position","reward_id","target_id") VALUES (100,'exp.campus','EXP',1,'reward.quest.navigation_intro','exp.campus') on conflict do nothing;

INSERT INTO "private"."world_reward_grants" ("amount","grant_entry_id","grant_type","position","reward_id","target_id") VALUES (150,'currency.induck_coin','CURRENCY',0,'reward.attendance.monthly_21','currency.induck_coin') on conflict do nothing;

INSERT INTO "private"."world_reward_grants" ("amount","grant_entry_id","grant_type","position","reward_id","target_id") VALUES (150,'exp.campus','EXP',3,'reward.event.mcm_2026_main_clear','exp.campus') on conflict do nothing;

INSERT INTO "private"."world_reward_grants" ("amount","grant_entry_id","grant_type","position","reward_id","target_id") VALUES (180,'currency.induck_coin','CURRENCY',0,'reward.quest.navigation_intro','currency.induck_coin') on conflict do nothing;

INSERT INTO "private"."world_reward_grants" ("amount","grant_entry_id","grant_type","position","reward_id","target_id") VALUES (25,'exp.campus','EXP',1,'reward.daily.campus_quiz','exp.campus') on conflict do nothing;

INSERT INTO "private"."world_reward_grants" ("amount","grant_entry_id","grant_type","position","reward_id","target_id") VALUES (30,'currency.induck_coin','CURRENCY',0,'reward.attendance.monthly_3','currency.induck_coin') on conflict do nothing;

INSERT INTO "private"."world_reward_grants" ("amount","grant_entry_id","grant_type","position","reward_id","target_id") VALUES (50,'currency.induck_coin','CURRENCY',0,'reward.attendance.monthly_7','currency.induck_coin') on conflict do nothing;

INSERT INTO "private"."world_reward_grants" ("amount","grant_entry_id","grant_type","position","reward_id","target_id") VALUES (50,'currency.induck_coin','CURRENCY',0,'reward.daily.campus_quiz','currency.induck_coin') on conflict do nothing;

INSERT INTO "private"."world_reward_grants" ("amount","grant_entry_id","grant_type","position","reward_id","target_id") VALUES (50,'exp.campus','EXP',1,'reward.minigame.landlord_first_clear','exp.campus') on conflict do nothing;

INSERT INTO "private"."world_reward_grants" ("amount","grant_entry_id","grant_type","position","reward_id","target_id") VALUES (80,'currency.induck_coin','CURRENCY',0,'reward.event.mcm_2026_main_clear','currency.induck_coin') on conflict do nothing;

INSERT INTO "private"."world_shops" ("created_at","display_name","shop_id","status","tags","vendor_id") VALUES ('2026-10-01T21:31:32Z','문콘경 학과 상점','shop.department_mcm','ACTIVE',ARRAY['department','mcm']::text[],NULL) on conflict do nothing;

INSERT INTO "private"."world_shops" ("created_at","display_name","shop_id","status","tags","vendor_id") VALUES ('2026-10-01T21:31:32Z','생활관 가구점','shop.dorm_furniture','ACTIVE',ARRAY['dorm','furniture']::text[],NULL) on conflict do nothing;

INSERT INTO "private"."world_shops" ("created_at","display_name","shop_id","status","tags","vendor_id") VALUES ('2026-10-01T21:31:32Z','학생회관 굿즈샵','shop.student_center','ACTIVE',ARRAY['campus']::text[],NULL) on conflict do nothing;

INSERT INTO "private"."world_shop_listings" ("created_at","currency_id","end_at","item_id","listing_id","position","price","purchase_limit","quantity","required_level","shop_id","start_at","status") VALUES ('2026-10-01T21:31:32Z','currency.induck_coin',NULL,'back.induck_backpack','offer.student_center.induck_backpack',5,420,NULL,1,3,'shop.student_center',NULL,'ACTIVE') on conflict do nothing;

INSERT INTO "private"."world_shop_listings" ("created_at","currency_id","end_at","item_id","listing_id","position","price","purchase_limit","quantity","required_level","shop_id","start_at","status") VALUES ('2026-10-01T21:31:32Z','currency.induck_coin',NULL,'furniture.campus_map_poster','offer.student_center.campus_map_poster',3,250,NULL,1,2,'shop.student_center',NULL,'ACTIVE') on conflict do nothing;

INSERT INTO "private"."world_shop_listings" ("created_at","currency_id","end_at","item_id","listing_id","position","price","purchase_limit","quantity","required_level","shop_id","start_at","status") VALUES ('2026-10-01T21:31:32Z','currency.induck_coin',NULL,'furniture.campus_rug_blue','offer.dorm_furniture.campus_rug_blue',2,360,NULL,1,3,'shop.dorm_furniture',NULL,'ACTIVE') on conflict do nothing;

INSERT INTO "private"."world_shop_listings" ("created_at","currency_id","end_at","item_id","listing_id","position","price","purchase_limit","quantity","required_level","shop_id","start_at","status") VALUES ('2026-10-01T21:31:32Z','currency.induck_coin',NULL,'furniture.dorm_desk_lamp','offer.dorm_furniture.dorm_desk_lamp',1,280,NULL,1,2,'shop.dorm_furniture',NULL,'ACTIVE') on conflict do nothing;

INSERT INTO "private"."world_shop_listings" ("created_at","currency_id","end_at","item_id","listing_id","position","price","purchase_limit","quantity","required_level","shop_id","start_at","status") VALUES ('2026-10-01T21:31:32Z','currency.induck_coin',NULL,'furniture.induck_chair','offer.dorm_furniture.induck_chair',3,420,NULL,1,3,'shop.dorm_furniture',NULL,'ACTIVE') on conflict do nothing;

INSERT INTO "private"."world_shop_listings" ("created_at","currency_id","end_at","item_id","listing_id","position","price","purchase_limit","quantity","required_level","shop_id","start_at","status") VALUES ('2026-10-01T21:31:32Z','currency.induck_coin',NULL,'furniture.induck_cushion','offer.dorm_furniture.induck_cushion',0,220,NULL,1,1,'shop.dorm_furniture',NULL,'ACTIVE') on conflict do nothing;

INSERT INTO "private"."world_shop_listings" ("created_at","currency_id","end_at","item_id","listing_id","position","price","purchase_limit","quantity","required_level","shop_id","start_at","status") VALUES ('2026-10-01T21:31:32Z','currency.induck_coin',NULL,'furniture.mini_induck','offer.dorm_furniture.mini_induck',4,650,NULL,1,5,'shop.dorm_furniture',NULL,'ACTIVE') on conflict do nothing;

INSERT INTO "private"."world_shop_listings" ("created_at","currency_id","end_at","item_id","listing_id","position","price","purchase_limit","quantity","required_level","shop_id","start_at","status") VALUES ('2026-10-01T21:31:32Z','currency.induck_coin',NULL,'head.induck_cap','offer.student_center.induck_cap',1,180,NULL,1,1,'shop.student_center',NULL,'ACTIVE') on conflict do nothing;

INSERT INTO "private"."world_shop_listings" ("created_at","currency_id","end_at","item_id","listing_id","position","price","purchase_limit","quantity","required_level","shop_id","start_at","status") VALUES ('2026-10-01T21:31:32Z','currency.induck_coin',NULL,'memorabilia.campus_mug','offer.student_center.campus_mug',0,120,NULL,1,NULL,'shop.student_center',NULL,'ACTIVE') on conflict do nothing;

INSERT INTO "private"."world_shop_listings" ("created_at","currency_id","end_at","item_id","listing_id","position","price","purchase_limit","quantity","required_level","shop_id","start_at","status") VALUES ('2026-10-01T21:31:32Z','currency.induck_coin',NULL,'shoes.campus_sneakers','offer.student_center.campus_sneakers',2,240,NULL,1,2,'shop.student_center',NULL,'ACTIVE') on conflict do nothing;

INSERT INTO "private"."world_shop_listings" ("created_at","currency_id","end_at","item_id","listing_id","position","price","purchase_limit","quantity","required_level","shop_id","start_at","status") VALUES ('2026-10-01T21:31:32Z','currency.induck_coin',NULL,'top.induck_hoodie','offer.student_center.induck_hoodie',4,320,NULL,1,2,'shop.student_center',NULL,'ACTIVE') on conflict do nothing;

INSERT INTO "private"."world_shop_listings" ("created_at","currency_id","end_at","item_id","listing_id","position","price","purchase_limit","quantity","required_level","shop_id","start_at","status") VALUES ('2026-10-01T21:31:32Z','currency.induck_coin',NULL,'top.mcm_jacket','offer.department_mcm.mcm_jacket',0,480,NULL,1,4,'shop.department_mcm',NULL,'ACTIVE') on conflict do nothing;

-- ---- First real stackable materials ----
insert into private.world_item_catalog(item_id, category, ownership_policy, max_stack, status) values
  ('material.campus_leaf', 'MATERIAL', 'STACKABLE', 99, 'ACTIVE'),
  ('material.fish_carp', 'MATERIAL', 'STACKABLE', 99, 'ACTIVE'),
  ('material.artifact_fragment_01', 'MATERIAL', 'STACKABLE', 99, 'ACTIVE')
on conflict (item_id) do nothing;

insert into private.world_life_skill_catalog(skill_id,curve_id,status) values
  ('life.fishing','life.common.v1','COMING_SOON'),
  ('life.gathering','life.common.v1','COMING_SOON'),
  ('life.archaeology','life.common.v1','COMING_SOON'),
  ('life.woodcutting','life.common.v1','COMING_SOON'),
  ('life.mining','life.common.v1','COMING_SOON'),
  ('life.woodworking','life.common.v1','COMING_SOON'),
  ('life.cooking','life.common.v1','COMING_SOON'),
  ('life.crafting','life.common.v1','COMING_SOON'),
  ('life.farming','life.common.v1','COMING_SOON'),
  ('life.photography','life.common.v1','COMING_SOON'),
  ('life.research','life.common.v1','COMING_SOON')
on conflict (skill_id) do nothing;

insert into private.world_life_skill_thresholds(curve_id,level,min_total_xp)
values ('life.common.v1',1,0)
on conflict (curve_id,level) do nothing;

insert into private.world_life_progression_thresholds(
  curve_id,level,min_total_skill_xp,cumulative_sp)
values ('life.progression.v1',1,0,0)
on conflict (curve_id,level) do nothing;

insert into private.world_biryong_npc_relationship_npc_catalog(
  npc_id,display_name,status,definition_version)
values
  ('BR_NPC_001','강소라','ACTIVE',1),
  ('BR_NPC_002','한여울','ACTIVE',1),
  ('BR_NPC_003','남이솔','ACTIVE',1),
  ('BR_NPC_004','윤하린','ACTIVE',1),
  ('BR_NPC_005','오미래','ACTIVE',1),
  ('BR_NPC_006','한세온','ACTIVE',1),
  ('BR_NPC_007','류가람','ACTIVE',1),
  ('BR_NPC_008','이담','ACTIVE',1)
on conflict (npc_id) do nothing;

insert into private.world_life_skill_thresholds(curve_id,level,min_total_xp,cumulative_sp) values
  ('life.common.v1', 2,   100,  1),
  ('life.common.v1', 3,   300,  2),
  ('life.common.v1', 4,   600,  3),
  ('life.common.v1', 5,  1000,  5),
  ('life.common.v1', 6,  1500,  6),
  ('life.common.v1', 7,  2100,  7),
  ('life.common.v1', 8,  2800,  8),
  ('life.common.v1', 9,  3600,  9),
  ('life.common.v1',10,  4500, 11),
  ('life.common.v1',11,  5500, 12),
  ('life.common.v1',12,  6600, 13),
  ('life.common.v1',13,  7800, 14),
  ('life.common.v1',14,  9100, 15),
  ('life.common.v1',15, 10500, 17),
  ('life.common.v1',16, 12000, 18),
  ('life.common.v1',17, 13600, 19),
  ('life.common.v1',18, 15300, 20),
  ('life.common.v1',19, 17100, 21),
  ('life.common.v1',20, 19000, 23)
on conflict (curve_id,level) do nothing;

-- ---- 3. SP ledger gains the pool dimension ----
-- The ledger and tree catalog hold no rows yet (no ACTIVE node exists), so the pool column is added
-- as NOT NULL directly. Fail loudly instead of guessing a pool for an existing spend.
do $$
begin
  if exists (select 1 from private.world_life_sp_transactions) then
    raise exception 'LIFE_SP_POOL_MIGRATION_REQUIRES_EMPTY_LEDGER';
  end if;
end;
$$;

-- INHA WORLD Life Skill Tree ranks (multi-rank nodes) + published-definition guards.
--
-- Rank model (decided before the #91 node import, docs/architecture/PR91_LIFE_PROGRESSION_SALVAGE.md):
-- - A node has max_rank >= 1. sp_cost is the cost of EACH rank. required_skill_level gates every rank.
-- - A prerequisite edge requires a minimum rank of the prerequisite node (required_rank).
-- - Each acquired rank is one append-only row in world_player_life_nodes and one SP spend row
--   (rank recorded). The current rank is the highest acquired rank; nothing is ever updated.
-- - world_life_node_unlock_v1 acquires exactly the next rank; the client never names a rank.
-- Published definitions are immutable: a node's cost, gates, skill and max rank and every edge are
-- frozen once inserted. Only a node's status may change. Cross-skill edges and edges requiring a rank
-- above the prerequisite's max rank are refused in the database, not only in the code Registry.
-- No node is added and nothing is activated here.

-- ---- 0. player state must still be empty ----
do $$
begin
  if exists (select 1 from private.world_life_sp_transactions)
     or exists (select 1 from private.world_player_life_nodes) then
    raise exception 'LIFE_TREE_RANK_MIGRATION_REQUIRES_EMPTY_STATE';
  end if;
end;
$$;

-- INHA WORLD Life Skill Tree v1 nodes: 18 nodes for Fishing / Woodcutting / Farming from #91
-- (docs/architecture/PR91_LIFE_PROGRESSION_SALVAGE.md sections 4-5), on the rank model of
-- 20261004135000. Mirrors apps/world/src/life-skills/life-skill-tree-nodes-v1.js exactly.
--
-- - Every node is COMING_SOON. No skill is activated; no node effect exists yet.
-- - Gates moved from the aggregate Life Level (#91) to the owning skill's level;
--   required_life_level is 1 for every node.
-- - Each tree costs 17 SP to max, which a skill has earned exactly at skill Lv15.
-- - Sailing (6 nodes) is not imported: life.sailing does not exist in the skill catalog.
-- Published rows are immutable (except status) from here on.

insert into private.world_life_skill_tree_catalog(
  node_id,skill_id,status,sp_cost,max_rank,required_life_level,required_skill_level) values
  ('life.node.fishing.steady_hands','life.fishing','COMING_SOON',1,3,1,2),
  ('life.node.fishing.fish_sense','life.fishing','COMING_SOON',1,3,1,3),
  ('life.node.fishing.baitcraft','life.fishing','COMING_SOON',1,2,1,5),
  ('life.node.fishing.rare_fish_sense','life.fishing','COMING_SOON',2,2,1,8),
  ('life.node.fishing.boat_fishing','life.fishing','COMING_SOON',2,1,1,10),
  ('life.node.fishing.deep_sea_fishing','life.fishing','COMING_SOON',3,1,1,15),
  ('life.node.woodcutting.clean_cut','life.woodcutting','COMING_SOON',1,3,1,2),
  ('life.node.woodcutting.timber_eye','life.woodcutting','COMING_SOON',1,3,1,4),
  ('life.node.woodcutting.tool_care','life.woodcutting','COMING_SOON',1,2,1,5),
  ('life.node.woodcutting.hardwood_handling','life.woodcutting','COMING_SOON',2,2,1,8),
  ('life.node.woodcutting.field_sawmill','life.woodcutting','COMING_SOON',2,1,1,10),
  ('life.node.woodcutting.master_forester','life.woodcutting','COMING_SOON',3,1,1,15),
  ('life.node.farming.soil_reading','life.farming','COMING_SOON',1,3,1,2),
  ('life.node.farming.seed_selection','life.farming','COMING_SOON',1,3,1,4),
  ('life.node.farming.water_sense','life.farming','COMING_SOON',1,2,1,5),
  ('life.node.farming.greenhouse','life.farming','COMING_SOON',2,2,1,8),
  ('life.node.farming.crop_rotation','life.farming','COMING_SOON',2,1,1,10),
  ('life.node.farming.smart_farm','life.farming','COMING_SOON',3,1,1,15)
on conflict (node_id) do nothing;

insert into private.world_life_skill_tree_edges(node_id,prerequisite_node_id,required_rank) values
  ('life.node.fishing.fish_sense','life.node.fishing.steady_hands',1),
  ('life.node.fishing.baitcraft','life.node.fishing.steady_hands',1),
  ('life.node.fishing.rare_fish_sense','life.node.fishing.fish_sense',2),
  ('life.node.fishing.boat_fishing','life.node.fishing.fish_sense',2),
  ('life.node.fishing.deep_sea_fishing','life.node.fishing.rare_fish_sense',1),
  ('life.node.fishing.deep_sea_fishing','life.node.fishing.boat_fishing',1),
  ('life.node.woodcutting.timber_eye','life.node.woodcutting.clean_cut',1),
  ('life.node.woodcutting.tool_care','life.node.woodcutting.clean_cut',1),
  ('life.node.woodcutting.hardwood_handling','life.node.woodcutting.timber_eye',2),
  ('life.node.woodcutting.field_sawmill','life.node.woodcutting.tool_care',2),
  ('life.node.woodcutting.master_forester','life.node.woodcutting.hardwood_handling',1),
  ('life.node.woodcutting.master_forester','life.node.woodcutting.field_sawmill',1),
  ('life.node.farming.seed_selection','life.node.farming.soil_reading',1),
  ('life.node.farming.water_sense','life.node.farming.soil_reading',1),
  ('life.node.farming.greenhouse','life.node.farming.seed_selection',2),
  ('life.node.farming.crop_rotation','life.node.farming.water_sense',2),
  ('life.node.farming.smart_farm','life.node.farming.greenhouse',1),
  ('life.node.farming.smart_farm','life.node.farming.crop_rotation',1)
on conflict (node_id,prerequisite_node_id) do nothing;

insert into private.world_life_tree_reset_policy(policy_id,cooldown_seconds)
values ('life.tree_reset.v1',86400)
on conflict (policy_id) do nothing;

-- INHA WORLD · activate already-live collection items shown in Inventory / Wardrobe.
-- The code catalog is the presentation canon and private.world_item_catalog is its server mirror.
-- Both items are already obtainable in live flows, so COMING_SOON is stale state rather than a gate.
update private.world_item_catalog
set status = 'ACTIVE'
where item_id in ('badge.main_gate', 'head.induck_cap')
  and status <> 'ACTIVE';

-- Fishing becomes the first ACTIVE Life Skill (Life Skill Tree PR-6).
--
-- Activated here:
-- - life.fishing (Life Skill catalog): its XP, level and SP pool now show in the Life Skill Book.
-- - collection.fish.carp (Collection discovery): the settlement path refuses inactive entries.
-- - the Fishing F2 runtime, with a CANDIDATE policy. The values are not tuned balance; change them
--   with a later migration (or an UPDATE of this one row) without touching code. A policy change
--   applies to new attempts only, because every attempt snapshots its policy at start.
--
-- Deliberately not activated:
-- - the Fishing skill tree nodes. They have no effects yet, so spending SP on them would buy nothing.
--   SP still accumulates in the Fishing pool and stays spendable once the nodes are activated.
-- - creature.bridge.activity.fishing (finalize keeps recording NOOP decisions).
-- - every other Life Skill.
--
-- The HTTP entry point stays behind WORLD_FISHING_API_ENABLED=1 (server env), so production play
-- starts only when that switch is set; this migration alone does not expose a player action.

update private.world_life_skill_catalog
   set status = 'ACTIVE'
 where skill_id = 'life.fishing' and status = 'COMING_SOON';

-- INHA WORLD Daily Quiz: expand the ACTIVE pool from 16 to 50.
-- Adds 24 introductory department questions, 8 general-knowledge questions,
-- and 2 INHA history questions. Existing 16 gameplay/campus questions stay unchanged.

insert into private.world_daily_quiz_questions
  (position, category, question_id, prompt, options, correct_index, status, version)
values
  (17, 'major', 'quiz.campus.major_mechanical_newton', '[기계공학과] 뉴턴의 제2법칙에서 질량 m인 물체에 가속도 a가 생길 때 힘 F는?', '["F = ma","F = m/a","F = a/m","F = mv"]'::jsonb, 0, 'ACTIVE', 1),
  (18, 'major', 'quiz.campus.major_aerospace_lift', '[항공우주공학과] 비행기 날개가 비행 중 위쪽으로 받는 대표적인 공기역학적 힘은?', '["항력","양력","추력","중력"]'::jsonb, 1, 'ACTIVE', 1),
  (19, 'major', 'quiz.campus.major_ship_buoyancy', '[조선해양공학과] 배가 물에 뜨는 현상을 가장 직접적으로 설명하는 힘은?', '["마찰력","탄성력","부력","구심력"]'::jsonb, 2, 'ACTIVE', 1),
  (20, 'major', 'quiz.campus.major_industrial_bottleneck', '[산업경영공학과] 생산 공정에서 전체 처리속도를 가장 크게 제한하는 단계를 무엇이라 할까?', '["표준공정","병목공정","유휴공정","병렬공정"]'::jsonb, 1, 'ACTIVE', 1),
  (21, 'major', 'quiz.campus.major_chemical_distillation', '[화학공학과] 액체 혼합물을 끓는점 차이를 이용해 분리하는 대표 공정은?', '["여과","증류","흡착","침전"]'::jsonb, 1, 'ACTIVE', 1),
  (22, 'major', 'quiz.campus.major_polymer_monomer', '[고분자공학과] 고분자를 이루는 반복 구조의 출발 단위가 되는 작은 분자를 무엇이라 할까?', '["단량체","전해질","촉매","결정립"]'::jsonb, 0, 'ACTIVE', 1),
  (23, 'major', 'quiz.campus.major_materials_properties', '[신소재공학과] 재료의 구조·조성과 기계적·전기적 성질의 관계를 다루는 분야에 가장 가까운 것은?', '["재료과학","천문학","언어학","생태학"]'::jsonb, 0, 'ACTIVE', 1),
  (24, 'major', 'quiz.campus.major_civil_structure', '[사회인프라공학과] 교량이나 건물이 하중을 받아도 안전한지 계산하는 기초 분야는?', '["구조역학","광학","열역학","유전학"]'::jsonb, 0, 'ACTIVE', 1),
  (25, 'major', 'quiz.campus.major_environment_bod', '[환경공학과] 물의 유기물 오염 정도를 간접적으로 나타내는 대표 수질 지표 BOD는 무엇의 약자일까?', '["생물화학적 산소요구량","기압 변화량","염분 농도","부유물 총질량"]'::jsonb, 0, 'ACTIVE', 1),
  (26, 'major', 'quiz.campus.major_geoinfo_gnss', '[공간정보공학과] 인공위성 신호를 이용해 지구상의 위치를 계산하는 위성항법 체계의 일반 명칭은?', '["GNSS","HTTP","OLED","CAD"]'::jsonb, 0, 'ACTIVE', 1),
  (27, 'major', 'quiz.campus.major_archeng_concrete', '[건축학부·건축공학 영역] 철근콘크리트에서 철근이 주로 보완하는 콘크리트의 약점은?', '["낮은 압축강도","낮은 인장강도","높은 밀도","높은 내화성"]'::jsonb, 1, 'ACTIVE', 1),
  (28, 'major', 'quiz.campus.major_arch_plan', '[건축학부·건축학 영역] 건물을 수평으로 잘라 위에서 내려다본 공간 배치 도면은?', '["입면도","단면도","배치도","평면도"]'::jsonb, 3, 'ACTIVE', 1),
  (29, 'major', 'quiz.campus.major_electrical_ohm', '[전기전자공학부] 전압 V, 전류 I, 저항 R의 관계를 나타내는 옴의 법칙은?', '["V = IR","V = I/R","V = R/I","V = I + R"]'::jsonb, 0, 'ACTIVE', 1),
  (30, 'major', 'quiz.campus.major_semiconductor_doping', '[반도체시스템공학과] 순수 반도체에 소량의 불순물을 넣어 전기적 특성을 조절하는 과정은?', '["도핑","증류","소결","도금"]'::jsonb, 0, 'ACTIVE', 1),
  (31, 'major', 'quiz.campus.major_battery_secondary', '[이차전지융합학과] 충전하여 여러 번 반복 사용하도록 설계된 전지를 무엇이라 할까?', '["일차전지","이차전지","연료전지","태양전지"]'::jsonb, 1, 'ACTIVE', 1),
  (32, 'major', 'quiz.campus.major_math_derivative', '[수학과] 함수의 한 점에서 순간적인 변화율을 나타내는 개념은?', '["적분","미분계수","행렬식","공약수"]'::jsonb, 1, 'ACTIVE', 1),
  (33, 'major', 'quiz.campus.major_statistics_median', '[통계학과] 극단적으로 큰 값 하나가 추가될 때 평균보다 일반적으로 덜 민감한 대표값은?', '["분산","표준편차","중앙값","최댓값"]'::jsonb, 2, 'ACTIVE', 1),
  (34, 'major', 'quiz.campus.major_physics_force_unit', '[물리학과] 국제단위계(SI)에서 힘의 단위는?', '["줄","와트","파스칼","뉴턴"]'::jsonb, 3, 'ACTIVE', 1),
  (35, 'major', 'quiz.campus.major_chemistry_ph', '[화학과] 25℃ 부근의 수용액에서 pH가 7보다 작은 용액은 일반적으로 어떤 성질을 띨까?', '["산성","중성","염기성","항상 포화 상태"]'::jsonb, 0, 'ACTIVE', 1),
  (36, 'major', 'quiz.campus.major_ocean_tide', '[해양과학과] 지구의 조석 현상에 가장 큰 영향을 주는 천체는?', '["달","화성","금성","목성"]'::jsonb, 0, 'ACTIVE', 1),
  (37, 'major', 'quiz.campus.major_cs_algorithm', '[컴퓨터공학과] 어떤 문제를 해결하기 위한 명확하고 유한한 절차를 무엇이라 할까?', '["알고리즘","컴파일러","데이터베이스","프로토콜"]'::jsonb, 0, 'ACTIVE', 1),
  (38, 'major', 'quiz.campus.major_ai_supervised', '[인공지능공학과] 입력과 정답 라벨이 함께 주어진 데이터로 학습하는 방식은?', '["지도학습","비지도학습","무작위 탐색","압축"]'::jsonb, 0, 'ACTIVE', 1),
  (39, 'major', 'quiz.campus.major_data_overfit', '[데이터사이언스학과] 학습 데이터에서는 성능이 높지만 새로운 데이터에서는 성능이 크게 떨어지는 현상은?', '["정규화","과적합","샘플링","시각화"]'::jsonb, 1, 'ACTIVE', 1),
  (40, 'major', 'quiz.campus.major_ccm_osmu', '[문화콘텐츠문화경영학과] 하나의 원천 콘텐츠를 영화·게임·굿즈 등 여러 형태로 확장 활용하는 전략은?', '["OSMU","FIFO","HTTP","RGB"]'::jsonb, 0, 'ACTIVE', 1),
  (41, 'general', 'quiz.campus.general_binary_digits', '컴퓨터에서 사용하는 2진법의 기본 숫자 두 개는?', '["0과 1","1과 2","2와 3","8과 9"]'::jsonb, 0, 'ACTIVE', 1),
  (42, 'general', 'quiz.campus.general_dna_bases', 'DNA를 구성하는 네 종류의 염기로 옳은 조합은?', '["A·T·G·C","A·U·G·C","A·T·X·Y","G·C·Na·Cl"]'::jsonb, 0, 'ACTIVE', 1),
  (43, 'general', 'quiz.campus.general_hangul_king', '훈민정음 창제를 주도한 조선의 왕은?', '["태조","세종","정조","고종"]'::jsonb, 1, 'ACTIVE', 1),
  (44, 'general', 'quiz.campus.general_equator_latitude', '적도의 위도는 몇 도일까?', '["0도","23.5도","45도","90도"]'::jsonb, 0, 'ACTIVE', 1),
  (45, 'general', 'quiz.campus.general_water_formula', '물의 화학식은?', '["CO₂","O₂","H₂O","NaCl"]'::jsonb, 2, 'ACTIVE', 1),
  (46, 'general', 'quiz.campus.general_red_planet', '태양계에서 흔히 ‘붉은 행성’이라 불리는 행성은?', '["수성","금성","화성","토성"]'::jsonb, 2, 'ACTIVE', 1),
  (47, 'general', 'quiz.campus.general_light_speed', '진공에서 빛의 속도에 가장 가까운 값은?', '["초속 약 300 km","초속 약 3,000 km","초속 약 30,000 km","초속 약 300,000 km"]'::jsonb, 3, 'ACTIVE', 1),
  (48, 'general', 'quiz.campus.general_photosynthesis', '식물이 광합성을 통해 빛에너지를 화학에너지로 저장할 때 주로 만들어 내는 유기물은?', '["포도당","질소","철","염화나트륨"]'::jsonb, 0, 'ACTIVE', 1),
  (49, 'inha', 'quiz.campus.inha_name_origin', '‘인하’라는 교명은 어떤 두 지명의 이름에서 유래했을까?', '["인천과 하와이","인천과 하노이","인제와 하와이","인천과 하얼빈"]'::jsonb, 0, 'ACTIVE', 1),
  (50, 'inha', 'quiz.campus.inha_opened_year', '인하대학교의 전신인 인하공과대학이 개교한 해는?', '["1945년","1950년","1954년","1960년"]'::jsonb, 2, 'ACTIVE', 1) on conflict do nothing;

do $$
declare
  v_total bigint;
  v_active bigint;
  v_major bigint;
  v_general bigint;
  v_inha bigint;
begin
  select count(*),
         count(*) filter (where status = 'ACTIVE'),
         count(*) filter (where category = 'major'),
         count(*) filter (where category = 'general'),
         count(*) filter (where category = 'inha')
    into v_total, v_active, v_major, v_general, v_inha
    from private.world_daily_quiz_questions;

  if v_total <> 50 or v_active <> 50 or v_major <> 24 or v_general <> 8 or v_inha <> 2 then
    raise exception 'DAILY_QUIZ_50_POOL_POSTCONDITION_FAILED total=% active=% major=% general=% inha=%',
      v_total, v_active, v_major, v_general, v_inha;
  end if;

  if (select count(distinct position) from private.world_daily_quiz_questions) <> 50
     or (select min(position) from private.world_daily_quiz_questions) <> 1
     or (select max(position) from private.world_daily_quiz_questions) <> 50 then
    raise exception 'DAILY_QUIZ_50_POOL_POSITION_POSTCONDITION_FAILED';
  end if;
end
$$;

-- INHA WORLD Daily Quiz: expand the 50-question pool to 100.
-- Adds coverage for every current playable department in public.departments
-- (excluding the sentinel "학과 미선택") and seven extra second questions.

insert into private.world_daily_quiz_questions
  (position, category, question_id, prompt, options, correct_index, status, version)
values
  (51, 'major', 'quiz.campus.major_energy_geothermal', '[에너지자원공학과] 지하의 열을 이용해 얻는 재생에너지는?', '["풍력에너지","태양에너지","지열에너지","조력에너지"]'::jsonb, 2, 'ACTIVE', 1),
  (52, 'major', 'quiz.campus.major_nutrition_macros', '[식품영양학과] 탄수화물·단백질·지방과 달리 에너지를 직접 내는 영양소가 아닌 것은?', '["탄수화물","단백질","지방","비타민"]'::jsonb, 3, 'ACTIVE', 1),
  (53, 'major', 'quiz.campus.major_business_breakeven', '[경영학과] 총수익과 총비용이 같아 이익이 0이 되는 지점을 무엇이라 할까?', '["시장점유점","손익분기점","할인율","회전율"]'::jsonb, 1, 'ACTIVE', 1),
  (54, 'major', 'quiz.campus.major_finance_diversification', '[파이낸스경영학과] 여러 종류의 자산에 나누어 투자하는 대표적인 목적은?', '["거래 횟수 극대화","세금 자동 면제","위험 분산","가격 고정"]'::jsonb, 2, 'ACTIVE', 1),
  (55, 'major', 'quiz.campus.major_logistics_scm', '[아태물류학부] 원재료 조달부터 생산·유통·고객 전달까지 흐름을 통합 관리하는 개념은?', '["SCM","CRM","GDP","BEP"]'::jsonb, 0, 'ACTIVE', 1),
  (56, 'major', 'quiz.campus.major_trade_comparative', '[국제통상학과] 국가 간 무역의 이익을 설명할 때 대표적으로 쓰이는 개념은?', '["비교우위","절대온도","한계효용 체감","규모의 불경제"]'::jsonb, 0, 'ACTIVE', 1),
  (57, 'major', 'quiz.campus.major_koreanedu_morpheme', '[국어교육과] 뜻을 가진 가장 작은 말의 단위를 무엇이라 할까?', '["음절","형태소","문장","담화"]'::jsonb, 1, 'ACTIVE', 1),
  (58, 'major', 'quiz.campus.major_englishedu_clt', '[영어교육과] 실제 의미 전달과 상호작용 능력을 중시하는 언어 교수 접근은?', '["문법번역식 교수법","의사소통 중심 교수법","암기 전용 교수법","무반응 교수법"]'::jsonb, 1, 'ACTIVE', 1),
  (59, 'major', 'quiz.campus.major_socialedu_separation', '[사회교육과] 국가 권력을 입법·행정·사법으로 나누어 상호 견제하게 하는 원리는?', '["권력분립","중상주의","직접민주주의","보호무역"]'::jsonb, 0, 'ACTIVE', 1),
  (60, 'major', 'quiz.campus.major_phe_overload', '[체육교육과] 체력 향상을 위해 평소보다 큰 운동 자극을 주는 훈련 원리는?', '["가역성의 원리","과부하의 원리","특이성의 원리","개별성의 원리"]'::jsonb, 1, 'ACTIVE', 1),
  (61, 'major', 'quiz.campus.major_education_formative', '[교육학과] 학습 도중 이해 정도를 확인하고 피드백을 주기 위해 실시하는 평가는?', '["진단평가","총괄평가","형성평가","선발평가"]'::jsonb, 2, 'ACTIVE', 1),
  (62, 'major', 'quiz.campus.major_mathedu_pythagorean', '[수학교육과] 직각삼각형에서 두 직각변 제곱의 합이 빗변 제곱과 같다는 정리는?', '["피타고라스 정리","중간값 정리","페르마 소정리","드모르간 법칙"]'::jsonb, 0, 'ACTIVE', 1),
  (63, 'major', 'quiz.campus.major_publicadmin_policy', '[행정학과] 공공문제를 해결하기 위해 정부가 선택하는 목표와 행동방침을 무엇이라 할까?', '["정책","회계","상표","물류"]'::jsonb, 0, 'ACTIVE', 1),
  (64, 'major', 'quiz.campus.major_politics_proportional', '[정치외교학과] 정당의 득표 비율에 따라 의석을 배분하는 대표 선거제도는?', '["다수대표제","비례대표제","추첨제","세습제"]'::jsonb, 1, 'ACTIVE', 1),
  (65, 'major', 'quiz.campus.major_media_agenda', '[미디어커뮤니케이션학과] 미디어가 어떤 이슈를 중요하게 다루면서 사람들이 중요하다고 생각할 의제에 영향을 준다는 이론은?', '["의제설정 이론","진화론","게임이론","색채이론"]'::jsonb, 0, 'ACTIVE', 1),
  (66, 'major', 'quiz.campus.major_economics_opportunity', '[경제학과] 어떤 선택을 하기 위해 포기한 차선의 대안 가치가 뜻하는 것은?', '["매몰비용","기회비용","고정비용","거래비용"]'::jsonb, 1, 'ACTIVE', 1),
  (67, 'major', 'quiz.campus.major_consumer_purchasingpower', '[소비자학과] 소득이 그대로인데 전반적인 물가가 오르면 일반적으로 실질 구매력은 어떻게 될까?', '["증가한다","변하지 않는다","감소한다","항상 두 배가 된다"]'::jsonb, 2, 'ACTIVE', 1),
  (68, 'major', 'quiz.campus.major_child_objectperm', '[아동심리학과] 눈앞에서 사라진 물체도 계속 존재한다고 이해하는 인지 개념은?', '["대상영속성","고전적 조건형성","확증편향","인지부조화"]'::jsonb, 0, 'ACTIVE', 1),
  (69, 'major', 'quiz.campus.major_socialwork_selfdetermination', '[사회복지학과] 사회복지 실천에서 당사자가 자신의 삶에 관한 선택에 참여할 권리를 존중하는 원칙은?', '["비밀보장","자기결정","표준화","시장균형"]'::jsonb, 1, 'ACTIVE', 1),
  (70, 'major', 'quiz.campus.major_korlit_omniscient', '[한국어문학과] 소설에서 서술자가 여러 인물의 생각과 사건을 폭넓게 알고 서술하는 시점은?', '["1인칭 주인공 시점","1인칭 관찰자 시점","전지적 작가 시점","카메라 시점"]'::jsonb, 2, 'ACTIVE', 1),
  (71, 'major', 'quiz.campus.major_history_primary', '[사학과] 연구하려는 시대에 직접 만들어진 문서·유물·기록을 일반적으로 무엇이라 할까?', '["1차 사료","2차 사료","가설","각주"]'::jsonb, 0, 'ACTIVE', 1),
  (72, 'major', 'quiz.campus.major_philosophy_deduction', '[철학과] 일반적인 원리나 전제로부터 개별적인 결론을 이끌어 내는 추론 방식은?', '["귀납","연역","유추","회상"]'::jsonb, 1, 'ACTIVE', 1),
  (73, 'major', 'quiz.campus.major_china_pinyin', '[중국학과] 중국 표준어 발음을 로마자로 표기하는 대표 체계는?', '["한어병음(Pinyin)","한글 맞춤법","가나","키릴 문자"]'::jsonb, 0, 'ACTIVE', 1),
  (74, 'major', 'quiz.campus.major_japan_katakana', '[일본언어문화학과] 현대 일본어에서 외래어 표기에 흔히 쓰이는 문자는?', '["히라가나","가타카나","한글","키릴 문자"]'::jsonb, 1, 'ACTIVE', 1),
  (75, 'major', 'quiz.campus.major_europe_renaissance', '[영미유럽인문융합학부] 유럽사에서 고대 그리스·로마 문화의 재발견과 인문주의 확산으로 잘 알려진 시대는?', '["르네상스","구석기시대","청동기시대","냉전"]'::jsonb, 0, 'ACTIVE', 1),
  (76, 'major', 'quiz.campus.major_premed_homeostasis', '[의예과] 체온·혈당처럼 몸의 내부 환경을 일정 범위로 유지하려는 성질은?', '["항상성","삼투압","변이","광합성"]'::jsonb, 0, 'ACTIVE', 1),
  (77, 'major', 'quiz.campus.major_nursing_vitals', '[간호학과] 체온·맥박·호흡·혈압을 묶어 부르는 기본 관찰 항목은?', '["활력징후","혈액형","반사검사","체질량지수"]'::jsonb, 0, 'ACTIVE', 1),
  (78, 'major', 'quiz.campus.major_art_perspective', '[조형예술학과] 멀리 있는 대상을 더 작게 표현해 화면에 깊이감을 주는 대표 기법은?', '["원근법","점묘법","콜라주","데칼코마니"]'::jsonb, 0, 'ACTIVE', 1),
  (79, 'major', 'quiz.campus.major_design_usercentered', '[디자인융합학과] 제품·서비스를 설계할 때 사용자의 요구와 경험을 중심에 두는 접근은?', '["사용자 중심 디자인","무작위 디자인","생산자 독점 디자인","비가시적 디자인"]'::jsonb, 0, 'ACTIVE', 1),
  (80, 'major', 'quiz.campus.major_sports_vo2max', '[스포츠과학과] 심폐 지구력과 유산소 운동능력을 평가할 때 널리 쓰이는 지표는?', '["체질량지수","최대산소섭취량","악력만","키"]'::jsonb, 1, 'ACTIVE', 1),
  (81, 'major', 'quiz.campus.major_film_miseenscene', '[연극영화학과] 화면 속 세트·조명·의상·배우 배치 등을 종합해 장면을 구성하는 개념은?', '["미장센","몽타주율","프레임레이트","샘플링"]'::jsonb, 0, 'ACTIVE', 1),
  (82, 'major', 'quiz.campus.major_fashion_warp', '[의류디자인학과] 직물에서 세로 방향으로 놓이는 실을 무엇이라 할까?', '["씨실","날실","봉제선","시접"]'::jsonb, 1, 'ACTIVE', 1),
  (83, 'major', 'quiz.campus.major_mobility_lidar', '[스마트모빌리티공학과] 레이저 빛을 쏘고 돌아오는 시간을 이용해 주변 거리를 측정하는 센서는?', '["LiDAR","마이크","GPS 안테나만","스피커"]'::jsonb, 0, 'ACTIVE', 1),
  (84, 'major', 'quiz.campus.major_designtech_additive', '[디자인테크놀로지학과] 3D 프린팅처럼 재료를 층층이 쌓아 형상을 만드는 제조 방식은?', '["절삭가공","적층제조","주조만","단조만"]'::jsonb, 1, 'ACTIVE', 1),
  (85, 'major', 'quiz.campus.major_ibt_exchange', '[IBT학과] 한 나라의 통화와 다른 나라 통화를 서로 교환하는 비율을 무엇이라 할까?', '["환율","이자율","실업률","출산율"]'::jsonb, 0, 'ACTIVE', 1),
  (86, 'major', 'quiz.campus.major_ise_systems', '[ISE학과] 복잡한 시스템을 요구사항부터 설계·통합·검증까지 전체 관점에서 다루는 공학 접근은?', '["시스템 엔지니어링","문헌비평","순수회계","색채심리"]'::jsonb, 0, 'ACTIVE', 1),
  (87, 'major', 'quiz.campus.major_klc_particle', '[KLC학과] 한국어에서 ‘은/는’, ‘이/가’, ‘을/를’처럼 문법적 관계를 나타내는 품사는?', '["조사","감탄사","관형사","수사"]'::jsonb, 0, 'ACTIVE', 1),
  (88, 'major', 'quiz.campus.major_liberal_convergence', '[자유전공학부] 둘 이상의 학문 분야 지식과 방법을 연결해 문제를 바라보는 접근은?', '["융합적 접근","단일 암기","무작위 추측","자료 배제"]'::jsonb, 0, 'ACTIVE', 1),
  (89, 'major', 'quiz.campus.major_mechatronics_actuator', '[메카트로닉스공학과] 제어기의 명령을 받아 실제 움직임이나 힘을 만들어 내는 장치는?', '["센서","액추에이터","저항기","라우터"]'::jsonb, 1, 'ACTIVE', 1),
  (90, 'major', 'quiz.campus.major_sw_api', '[소프트웨어융합공학과] 서로 다른 소프트웨어가 기능이나 데이터를 주고받도록 정한 인터페이스를 흔히 무엇이라 할까?', '["API","DPI","RPM","pH"]'::jsonb, 0, 'ACTIVE', 1),
  (91, 'major', 'quiz.campus.major_indmgmt_productivity', '[산업경영학과] 일반적으로 생산성은 산출량을 무엇으로 나눈 값으로 생각할 수 있을까?', '["투입량","가격","세율","재고일수"]'::jsonb, 0, 'ACTIVE', 1),
  (92, 'major', 'quiz.campus.major_invest_bondrate', '[금융투자학과] 다른 조건이 같을 때 시장금리가 오르면 기존 고정금리 채권의 가격은 일반적으로 어떻게 될까?', '["오른다","내린다","항상 그대로다","반드시 0원이 된다"]'::jsonb, 1, 'ACTIVE', 1),
  (93, 'major', 'quiz.campus.major_semindustry_wafer', '[반도체산업융합학과] 집적회로를 만들 때 여러 칩을 한꺼번에 형성하는 얇은 반도체 원판은?', '["웨이퍼","플라이휠","터빈","필라멘트"]'::jsonb, 0, 'ACTIVE', 1),
  (94, 'major', 'quiz.campus.major_mechanical_torque', '[기계공학과] 물체를 회전시키려는 힘의 효과를 나타내는 물리량은?', '["토크","밀도","전압","조도"]'::jsonb, 0, 'ACTIVE', 1),
  (95, 'major', 'quiz.campus.major_chemical_hexchanger', '[화학공학과] 서로 다른 온도의 유체 사이에서 열을 전달하도록 설계한 대표 장치는?', '["열교환기","증폭기","정류기","안테나"]'::jsonb, 0, 'ACTIVE', 1),
  (96, 'major', 'quiz.campus.major_electrical_power', '[전기전자공학부] 직류 회로에서 전압 V와 전류 I를 알 때 전력 P를 구하는 기본 관계는?', '["P = V + I","P = V/I","P = VI","P = I − V"]'::jsonb, 2, 'ACTIVE', 1),
  (97, 'major', 'quiz.campus.major_math_integral', '[수학과] 미분과 밀접한 역관계에 있으며 넓이·누적량 계산에 쓰이는 연산은?', '["적분","나눗셈","인수분해만","순열"]'::jsonb, 0, 'ACTIVE', 1),
  (98, 'major', 'quiz.campus.major_cs_stack', '[컴퓨터공학과] 가장 나중에 넣은 데이터가 가장 먼저 나오는 LIFO 구조는?', '["큐","스택","그래프","해시함수"]'::jsonb, 1, 'ACTIVE', 1),
  (99, 'major', 'quiz.campus.major_ai_reinforcement', '[인공지능공학과] 에이전트가 환경에서 행동하고 보상을 받으며 전략을 학습하는 방식은?', '["강화학습","정렬 알고리즘","압축","암호화"]'::jsonb, 0, 'ACTIVE', 1),
  (100, 'major', 'quiz.campus.major_ccm_ip', '[문화콘텐츠문화경영학과] 콘텐츠 산업에서 IP는 일반적으로 무엇을 뜻할까?', '["지식재산(Intellectual Property)","인터넷 프로토콜만","재고회전율","금리정책"]'::jsonb, 0, 'ACTIVE', 1) on conflict do nothing;

do $$
declare
  v_total bigint;
  v_active bigint;
  v_major bigint;
begin
  select count(*),
         count(*) filter (where status = 'ACTIVE'),
         count(*) filter (where category = 'major')
    into v_total, v_active, v_major
    from private.world_daily_quiz_questions;

  if v_total <> 100 or v_active <> 100 or v_major <> 74 then
    raise exception 'DAILY_QUIZ_100_POOL_POSTCONDITION_FAILED total=% active=% major=%',
      v_total, v_active, v_major;
  end if;

  if (select count(distinct position) from private.world_daily_quiz_questions) <> 100
     or (select min(position) from private.world_daily_quiz_questions) <> 1
     or (select max(position) from private.world_daily_quiz_questions) <> 100 then
    raise exception 'DAILY_QUIZ_100_POOL_POSITION_POSTCONDITION_FAILED';
  end if;
end
$$;

-- Activate only effects that are real in this slice.
update private.world_life_skill_tree_catalog
   set status='ACTIVE'
 where node_id in (
   'life.node.fishing.steady_hands',
   'life.node.fishing.fish_sense'
 )
   and status='COMING_SOON';

do $$
begin
  if (select count(*) from private.world_life_skill_tree_catalog
       where node_id in ('life.node.fishing.steady_hands','life.node.fishing.fish_sense')
         and status='ACTIVE') <> 2
     or exists (
       select 1 from private.world_life_skill_tree_catalog
        where skill_id='life.fishing'
          and node_id not in ('life.node.fishing.steady_hands','life.node.fishing.fish_sense')
          and status <> 'COMING_SOON'
     ) then
    raise exception 'FISHING_SKILL_EFFECT_ACTIVATION_INCOMPLETE';
  end if;
end;
$$;

insert into private.world_campus_npc_relationship_npc_catalog(
  npc_id,relationship_class,status,definition_version)
values
  ('INKYUNG-NPC-001','HERO','ACTIVE',1),
  ('INKYUNG-NPC-002','HERO','ACTIVE',1),
  ('INKYUNG-NPC-005','HERO','ACTIVE',1),
  ('INKYUNG-NPC-008','HERO','ACTIVE',1),
  ('INKYUNG-NPC-012','HERO','ACTIVE',1),
  ('INKYUNG-NPC-016','HERO','ACTIVE',1),
  ('INKYUNG-NPC-029','HERO','ACTIVE',1),
  ('INKYUNG-NPC-034','HERO','ACTIVE',1),
  ('INKYUNG-NPC-042','HERO','ACTIVE',1),
  ('INKYUNG-NPC-046','HERO','ACTIVE',1)
on conflict (npc_id) do nothing;

-- Housing F0: register the seven Personal Room starter furniture items and open the C70
-- floor placement envelope. Existing saved coordinates remain valid; east/west wall anchors
-- intentionally remain on the legacy H2 plane until a dedicated wall-placement migration.
--
-- This migration changes definitions/validation only. It does not grant items or add Shop prices.

insert into private.world_item_catalog(item_id, category, ownership_policy, max_stack, status) values
  ('furniture.dorm_single_sofa', 'FURNITURE', 'UNIQUE', null, 'COMING_SOON'),
  ('furniture.dorm_side_table_low', 'FURNITURE', 'UNIQUE', null, 'COMING_SOON'),
  ('furniture.dorm_bookshelf_slim', 'FURNITURE', 'UNIQUE', null, 'COMING_SOON'),
  ('furniture.dorm_plant_medium', 'FURNITURE', 'UNIQUE', null, 'COMING_SOON'),
  ('furniture.dorm_monitor', 'FURNITURE', 'UNIQUE', null, 'COMING_SOON'),
  ('furniture.dorm_trophy_shelf', 'FURNITURE', 'UNIQUE', null, 'COMING_SOON'),
  ('furniture.study_books_set', 'FURNITURE', 'UNIQUE', null, 'COMING_SOON') on conflict do nothing;

insert into private.world_item_catalog(item_id,category,ownership_policy,max_stack,status) values
  ('furniture.cooking_station','FURNITURE','UNIQUE',null,'COMING_SOON'),
  ('consumable.grilled_carp','CONSUMABLE','STACKABLE',20,'COMING_SOON') on conflict do nothing;

insert into private.world_recipe_catalog values (
  'recipe.carp_grill',1,'COOK','COOKING_STATION','furniture.cooking_station','COMING_SOON',
  '{"consumes":[{"itemId":"material.fish_carp","quantity":1}],"grants":[{"itemId":"consumable.grilled_carp","quantity":1}]}'::jsonb
) on conflict do nothing;

insert into private.world_item_catalog(item_id, category, ownership_policy, max_stack, status) values
  ('finish.wall_basic',            'ROOM_FINISH', 'UNIQUE', null, 'COMING_SOON'),
  ('finish.wall_white_plaster_02', 'ROOM_FINISH', 'UNIQUE', null, 'COMING_SOON'),
  ('finish.floor_basic',           'ROOM_FINISH', 'UNIQUE', null, 'COMING_SOON'),
  ('finish.floor_wood_051',        'ROOM_FINISH', 'UNIQUE', null, 'COMING_SOON')
on conflict (item_id) do nothing;

insert into private.world_shops(shop_id, display_name, status, tags) values
  ('shop.room_finishes', '생활관 인테리어 상점', 'ACTIVE', array['housing', 'room_finish'])
on conflict (shop_id) do nothing;

-- LOCKED is server-enforced inside purchase_world_shop_listing_v1.
-- Do not activate these listings before inventory grandfathering + room finish save/read authority.
insert into private.world_shop_listings
  (listing_id, shop_id, "position", item_id, currency_id, price, quantity, required_level, purchase_limit, status)
values
  ('offer.room_finishes.wall_white_plaster_02', 'shop.room_finishes', 0, 'finish.wall_white_plaster_02',
   'currency.induck_coin', 1500, 1, null, 1, 'LOCKED'),
  ('offer.room_finishes.floor_wood_051', 'shop.room_finishes', 1, 'finish.floor_wood_051',
   'currency.induck_coin', 1500, 1, null, 1, 'LOCKED')
on conflict (listing_id) do nothing;

-- Refuse silent pre-existing ID/listing conflicts rather than changing any owned inventory.
do $$
begin
  if (select count(*) from private.world_item_catalog
      where item_id in ('finish.wall_basic','finish.wall_white_plaster_02','finish.floor_basic','finish.floor_wood_051')
        and category='ROOM_FINISH' and ownership_policy='UNIQUE'
        and max_stack is null and status='COMING_SOON') <> 4 then
    raise exception 'ROOM_FINISH_CATALOG_CONFLICT';
  end if;
  if (select count(*) from private.world_shop_listings
      where shop_id='shop.room_finishes' and status='LOCKED'
        and currency_id='currency.induck_coin' and price=1500
        and quantity=1 and purchase_limit=1
        and required_level is null
        and (listing_id, item_id, "position") in (
          ('offer.room_finishes.wall_white_plaster_02','finish.wall_white_plaster_02',0::smallint),
          ('offer.room_finishes.floor_wood_051','finish.floor_wood_051',1::smallint)
        )) <> 2 then
    raise exception 'ROOM_FINISH_LISTING_CONFLICT';
  end if;
end;
$$;

-- Prerequisite for any rollout: the dorm furniture shop must have a reachable NPC route.
-- Local candidate: preserve listing identity/history while moving existing furniture.
-- Do not rename listing IDs or rewrite completed purchase / inventory / wallet records.
-- position is the only other changed field: destination positions are unique per shop.
with moving as (
  select l.listing_id,
    (select coalesce(max(d.position), -1) from private.world_shop_listings d
      where d.shop_id = 'shop.dorm_furniture')
      + row_number() over (order by l.position, l.listing_id) as destination_position
  from private.world_shop_listings l
  join private.world_item_catalog c on c.item_id = l.item_id
  where l.shop_id = 'shop.student_center' and c.category = 'FURNITURE'
)
update private.world_shop_listings l
set shop_id = 'shop.dorm_furniture', position = m.destination_position
from moving m where l.listing_id = m.listing_id;

-- Local candidate only. Rollout requires the fashion route and reachable NPC binding
-- alongside the shop split. The approved existing shop workers map in client routing:
-- INKYUNG-NPC-003 (나수현) -> vendor.student_center_souvenir -> shop.student_center
-- INKYUNG-NPC-012 (가지안) -> vendor.student_center_fashion -> shop.student_center_fashion
-- This is routing metadata, not server-enforced NPC proximity authorization.
-- Copy availability from the existing shop rather than promoting inactive stock.
insert into private.world_shops(shop_id, display_name, status, vendor_id)
select 'shop.student_center_fashion', '패션 상점', status, 'vendor.student_center_fashion'
from private.world_shops where shop_id = 'shop.student_center' on conflict do nothing;

-- Listing IDs are durable identities even though their historical prefix names the old
-- shop. Preserve prices, requirements, availability, limits, positions and all history.
update private.world_shop_listings
set shop_id = 'shop.student_center_fashion'
where shop_id = 'shop.student_center'
  and listing_id in (
    'offer.student_center.induck_cap',
    'offer.student_center.campus_sneakers',
    'offer.student_center.induck_hoodie',
    'offer.student_center.induck_backpack'
  );

update private.world_shops
set display_name = '학생회관 기념품점', vendor_id = 'vendor.student_center_souvenir'
where shop_id = 'shop.student_center';

-- First living furniture: LOCAL CANDIDATE, not an approval to apply to any database.
-- Both listings remain LOCKED. Prices and level gates are review proposals only.
-- A later, separately approved rollout must verify the reachable dorm vendor and
-- decide activation; neither catalog status nor any player's possessions change here.
-- Existing purchase v2/v1, UNIQUE ownership, wallet, grant and retry contracts are reused.

do $$
begin
  if (select count(*) from private.world_item_catalog
      where item_id in ('furniture.study_books_set', 'furniture.dorm_single_sofa')
        and category = 'FURNITURE' and ownership_policy = 'UNIQUE' and max_stack is null
        and status = 'COMING_SOON') <> 2 then
    raise exception 'STARTER_FURNITURE_CATALOG_PREREQUISITE';
  end if;
end;
$$;

-- Allocate after current stock; never move/reprice existing listings or overwrite IDs.
with last_position as (
  select coalesce(max(position), -1) as value from private.world_shop_listings
  where shop_id = 'shop.dorm_furniture'
), candidates(listing_id, item_id, price, required_level, offset_position) as (values
  ('offer.dorm_furniture.study_books_set', 'furniture.study_books_set', 120, 1, 1),
  ('offer.dorm_furniture.dorm_single_sofa', 'furniture.dorm_single_sofa', 480, 1, 2)
)
insert into private.world_shop_listings
  (listing_id, shop_id, position, item_id, currency_id, price, quantity,
   required_level, purchase_limit, start_at, end_at, status)
select c.listing_id, 'shop.dorm_furniture', p.value + c.offset_position, c.item_id,
  'currency.induck_coin', c.price, 1, c.required_level, null, null, null, 'LOCKED'
from candidates c cross join last_position p on conflict do nothing;

insert into private.world_jeongseok_gate_policy(singleton,status) values (true,'COMING_SOON') on conflict do nothing;

insert into private.world_jeongseok_pass_catalog values
  ('jeongseok.visitor.day', 86400, 'currency.induck_coin', 100, 'CANDIDATE', 'COMING_SOON') on conflict do nothing;

-- JSL policy confirmation: the public lobby needs no pass. Beyond its entrance gate,
-- Inha mail verified permanent accounts enter free; other eligible permanent accounts
-- can buy a game-only, account-bound visitor pass from the lobby information NPC.
-- Mail verification proves mailbox ownership, not enrollment or real facility access.
--
-- Confirmed terms: 100 Induck Coin for 86,400 seconds from purchase.
-- This is a forward-only data change. Preserve both existing rollout statuses:
-- the gate and product still ship COMING_SOON. Confirmation does not activate sales
-- or access; activation requires a separate authorized rollout.
-- The original JSL-A migration, RPCs, grants, Wallet authority, advisory lock and
-- idempotency contract remain unchanged. Disposable local databases only, never Production.

update private.world_jeongseok_pass_catalog
   set duration_seconds = 86400,
       currency_id = 'currency.induck_coin',
       price = 100,
       price_basis = 'CONFIRMED'
 where pass_type = 'jeongseok.visitor.day';

-- ================= Grants =================

grant usage on schema public to inha_world_tier4_writes_app;

grant usage on schema private to inha_world_tier4_writes_app;

grant select (id) on table public.sessions to inha_world_tier4_writes_app;

grant select (user_id, is_banned) on table public.profiles to inha_world_tier4_writes_app;

grant execute on function public.advance_mcm_2026_event_v1(p_user uuid, p_event text) to inha_world_tier4_writes_app;

revoke all on function public.advance_mcm_2026_event_v1(p_user uuid, p_event text) from public;

grant execute on function public.answer_my_world_daily_quiz_v1(p_user uuid, p_run_id uuid, p_question_id text, p_answer_index smallint) to inha_world_tier4_writes_app;

revoke all on function public.answer_my_world_daily_quiz_v1(p_user uuid, p_run_id uuid, p_question_id text, p_answer_index smallint) from public;

grant execute on function public.block_world_user(p_user uuid, p_target uuid) to inha_world_tier4_writes_app;

revoke all on function public.block_world_user(p_user uuid, p_target uuid) from public;

grant execute on function public.cancel_world_friend_request(p_user uuid, p_target uuid) to inha_world_tier4_writes_app;

revoke all on function public.cancel_world_friend_request(p_user uuid, p_target uuid) from public;

grant execute on function public.claim_my_mcm_2026_main_reward_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.claim_my_mcm_2026_main_reward_v1(p_user uuid) from public;

grant execute on function public.claim_my_mcm_landlord_first_clear_reward_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.claim_my_mcm_landlord_first_clear_reward_v1(p_user uuid) from public;

grant execute on function public.claim_my_world_attendance_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.claim_my_world_attendance_v1(p_user uuid) from public;

grant execute on function public.cook_my_world_recipe_v1(p_user uuid, p_recipe_id text, p_request_id uuid) to inha_world_tier4_writes_app;

revoke all on function public.cook_my_world_recipe_v1(p_user uuid, p_recipe_id text, p_request_id uuid) from public;

grant execute on function public.create_world_guestbook_entry_v2(p_user uuid, p_content text, p_location_key text) to inha_world_tier4_writes_app;

revoke all on function public.create_world_guestbook_entry_v2(p_user uuid, p_content text, p_location_key text) from public;

grant execute on function public.delete_world_guestbook_entry_v2(p_user uuid, p_entry_id uuid) to inha_world_tier4_writes_app;

revoke all on function public.delete_world_guestbook_entry_v2(p_user uuid, p_entry_id uuid) from public;

grant execute on function public.end_world_accompany(p_user uuid, p_session_id uuid) to inha_world_tier4_writes_app;

revoke all on function public.end_world_accompany(p_user uuid, p_session_id uuid) from public;

grant execute on function public.equip_my_world_item_v1(p_user uuid, p_slot text, p_item_id text, p_idempotency_key text) to inha_world_tier4_writes_app;

revoke all on function public.equip_my_world_item_v1(p_user uuid, p_slot text, p_item_id text, p_idempotency_key text) from public;

grant execute on function public.get_jeongseok_access_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_jeongseok_access_v1(p_user uuid) from public;

grant execute on function public.get_my_achievements(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_my_achievements(p_user uuid) from public;

grant execute on function public.get_my_biryong_npc_relationship_v1(p_user uuid, p_npc_id text) to inha_world_tier4_writes_app;

revoke all on function public.get_my_biryong_npc_relationship_v1(p_user uuid, p_npc_id text) from public;

grant execute on function public.get_my_biryong_npc_relationships_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_my_biryong_npc_relationships_v1(p_user uuid) from public;

grant execute on function public.get_my_biryong_progress_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_my_biryong_progress_v1(p_user uuid) from public;

grant execute on function public.get_my_mcm_2026_event_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_my_mcm_2026_event_v1(p_user uuid) from public;

grant execute on function public.get_my_profile(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_my_profile(p_user uuid) from public;

grant execute on function public.get_my_room_knock_v1(p_user uuid, p_knock uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_my_room_knock_v1(p_user uuid, p_knock uuid) from public;

grant execute on function public.get_my_world_accompany(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_my_world_accompany(p_user uuid) from public;

grant execute on function public.get_my_world_appearance_loadout_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_my_world_appearance_loadout_v1(p_user uuid) from public;

grant execute on function public.get_my_world_attendance_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_my_world_attendance_v1(p_user uuid) from public;

grant execute on function public.get_my_world_campus_npc_relationship_v1(p_user uuid, p_npc_id text) to inha_world_tier4_writes_app;

revoke all on function public.get_my_world_campus_npc_relationship_v1(p_user uuid, p_npc_id text) from public;

grant execute on function public.get_my_world_campus_npc_relationships_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_my_world_campus_npc_relationships_v1(p_user uuid) from public;

grant execute on function public.get_my_world_daily_quiz_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_my_world_daily_quiz_v1(p_user uuid) from public;

grant execute on function public.get_my_world_inventory_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_my_world_inventory_v1(p_user uuid) from public;

grant execute on function public.get_my_world_life_skill_tree_v1(p_user uuid, p_skill_id text) to inha_world_tier4_writes_app;

revoke all on function public.get_my_world_life_skill_tree_v1(p_user uuid, p_skill_id text) from public;

grant execute on function public.get_my_world_life_skills_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_my_world_life_skills_v1(p_user uuid) from public;

grant execute on function public.get_my_world_progression_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_my_world_progression_v1(p_user uuid) from public;

grant execute on function public.get_my_world_social(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_my_world_social(p_user uuid) from public;

grant execute on function public.get_my_world_wallet_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_my_world_wallet_v1(p_user uuid) from public;

grant execute on function public.get_or_create_my_personal_room_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_or_create_my_personal_room_v1(p_user uuid) from public;

grant execute on function public.get_world_guestbook_v2(p_user uuid, p_location_key text, p_limit integer, p_before timestamp with time zone) to inha_world_tier4_writes_app;

revoke all on function public.get_world_guestbook_v2(p_user uuid, p_location_key text, p_limit integer, p_before timestamp with time zone) from public;

grant execute on function public.get_world_public_profile(p_user uuid, p_target uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_world_public_profile(p_user uuid, p_target uuid) from public;

grant execute on function public.get_world_relationship(p_user uuid, p_target uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_world_relationship(p_user uuid, p_target uuid) from public;

grant execute on function public.get_world_room_furniture_v1(p_user uuid, p_room uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_world_room_furniture_v1(p_user uuid, p_room uuid) from public;

grant execute on function public.get_world_shop_capabilities_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.get_world_shop_capabilities_v1(p_user uuid) from public;

grant execute on function public.get_world_shop_v1(p_user uuid, p_shop_id text) to inha_world_tier4_writes_app;

revoke all on function public.get_world_shop_v1(p_user uuid, p_shop_id text) from public;

grant execute on function public.get_world_staff_badges_v1(p_user uuid, p_user_ids uuid[]) to inha_world_tier4_writes_app;

revoke all on function public.get_world_staff_badges_v1(p_user uuid, p_user_ids uuid[]) from public;

grant execute on function public.knock_friend_personal_room_v1(p_user uuid, p_owner uuid) to inha_world_tier4_writes_app;

revoke all on function public.knock_friend_personal_room_v1(p_user uuid, p_owner uuid) from public;

grant execute on function public.list_my_room_knocks_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.list_my_room_knocks_v1(p_user uuid) from public;

grant execute on function public.merge_my_biryong_progress_v1(p_user uuid, p_progress jsonb, p_migrated_from_local boolean) to inha_world_tier4_writes_app;

revoke all on function public.merge_my_biryong_progress_v1(p_user uuid, p_progress jsonb, p_migrated_from_local boolean) from public;

grant execute on function public.propose_world_accompany(p_user uuid, p_target uuid, p_poi_id text, p_place_zone_id text) to inha_world_tier4_writes_app;

revoke all on function public.propose_world_accompany(p_user uuid, p_target uuid, p_poi_id text, p_place_zone_id text) from public;

grant execute on function public.purchase_jeongseok_pass_v1(p_user uuid, p_pass_type text, p_idempotency_key text) to inha_world_tier4_writes_app;

revoke all on function public.purchase_jeongseok_pass_v1(p_user uuid, p_pass_type text, p_idempotency_key text) from public;

grant execute on function public.purchase_world_shop_listing_v1(p_user uuid, p_listing_id text, p_idempotency_key text) to inha_world_tier4_writes_app;

revoke all on function public.purchase_world_shop_listing_v1(p_user uuid, p_listing_id text, p_idempotency_key text) from public;

grant execute on function public.purchase_world_shop_listing_v2(p_user uuid, p_shop_id text, p_listing_id text, p_idempotency_key text) to inha_world_tier4_writes_app;

revoke all on function public.purchase_world_shop_listing_v2(p_user uuid, p_shop_id text, p_listing_id text, p_idempotency_key text) from public;

grant execute on function public.remove_world_friend(p_user uuid, p_target uuid) to inha_world_tier4_writes_app;

revoke all on function public.remove_world_friend(p_user uuid, p_target uuid) from public;

grant execute on function public.report_world_user(p_user uuid, p_target uuid, p_category text, p_place_zone_id text) to inha_world_tier4_writes_app;

revoke all on function public.report_world_user(p_user uuid, p_target uuid, p_category text, p_place_zone_id text) from public;

grant execute on function public.reset_my_world_life_tree_v1(p_user uuid, p_skill_id text, p_request_id uuid) to inha_world_tier4_writes_app;

revoke all on function public.reset_my_world_life_tree_v1(p_user uuid, p_skill_id text, p_request_id uuid) from public;

grant execute on function public.respond_room_knock_v1(p_user uuid, p_knock uuid, p_accept boolean) to inha_world_tier4_writes_app;

revoke all on function public.respond_room_knock_v1(p_user uuid, p_knock uuid, p_accept boolean) from public;

grant execute on function public.respond_world_accompany(p_user uuid, p_session_id uuid, p_accept boolean) to inha_world_tier4_writes_app;

revoke all on function public.respond_world_accompany(p_user uuid, p_session_id uuid, p_accept boolean) from public;

grant execute on function public.respond_world_friend_request(p_user uuid, p_target uuid, p_accept boolean) to inha_world_tier4_writes_app;

revoke all on function public.respond_world_friend_request(p_user uuid, p_target uuid, p_accept boolean) from public;

grant execute on function public.save_my_room_furniture_v1(p_user uuid, p_room uuid, p_revision integer, p_objects jsonb) to inha_world_tier4_writes_app;

revoke all on function public.save_my_room_furniture_v1(p_user uuid, p_room uuid, p_revision integer, p_objects jsonb) from public;

grant execute on function public.send_world_friend_request(p_user uuid, p_target uuid) to inha_world_tier4_writes_app;

revoke all on function public.send_world_friend_request(p_user uuid, p_target uuid) from public;

grant execute on function public.set_my_personal_room_visibility_v1(p_user uuid, p_visibility text) to inha_world_tier4_writes_app;

revoke all on function public.set_my_personal_room_visibility_v1(p_user uuid, p_visibility text) from public;

grant execute on function public.start_mcm_landlord_run_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.start_mcm_landlord_run_v1(p_user uuid) from public;

grant execute on function public.start_my_world_daily_quiz_v1(p_user uuid) to inha_world_tier4_writes_app;

revoke all on function public.start_my_world_daily_quiz_v1(p_user uuid) from public;

grant execute on function public.submit_mcm_landlord_choice_v1(p_user uuid, p_run_id uuid, p_actor_id text) to inha_world_tier4_writes_app;

revoke all on function public.submit_mcm_landlord_choice_v1(p_user uuid, p_run_id uuid, p_actor_id text) from public;

grant execute on function public.unblock_world_user(p_user uuid, p_target uuid) to inha_world_tier4_writes_app;

revoke all on function public.unblock_world_user(p_user uuid, p_target uuid) from public;

grant execute on function public.unequip_my_world_item_v1(p_user uuid, p_slot text, p_idempotency_key text) to inha_world_tier4_writes_app;

revoke all on function public.unequip_my_world_item_v1(p_user uuid, p_slot text, p_idempotency_key text) from public;

grant execute on function public.unlock_my_world_life_node_v1(p_user uuid, p_node_id text, p_request_id uuid) to inha_world_tier4_writes_app;

revoke all on function public.unlock_my_world_life_node_v1(p_user uuid, p_node_id text, p_request_id uuid) from public;

grant execute on function public.update_world_guestbook_entry_v2(p_user uuid, p_entry_id uuid, p_content text) to inha_world_tier4_writes_app;

revoke all on function public.update_world_guestbook_entry_v2(p_user uuid, p_entry_id uuid, p_content text) from public;

grant execute on function public.world_biryong_npc_relationship_advance_v1(p_user uuid, p_npc_id text, p_target_stage smallint, p_source_type text, p_source_ref text, p_result_ref text, p_idempotency_key text) to inha_world_tier4_writes_app;

revoke all on function public.world_biryong_npc_relationship_advance_v1(p_user uuid, p_npc_id text, p_target_stage smallint, p_source_type text, p_source_ref text, p_result_ref text, p_idempotency_key text) from public;

grant execute on function public.world_campus_npc_relationship_apply_v1(p_user uuid, p_npc_id text, p_definition_version integer, p_event_type text, p_signal text, p_occurrence integer, p_requested_delta smallint, p_source_type text, p_source_ref text, p_idempotency_key text) to inha_world_tier4_writes_app;

revoke all on function public.world_campus_npc_relationship_apply_v1(p_user uuid, p_npc_id text, p_definition_version integer, p_event_type text, p_signal text, p_occurrence integer, p_requested_delta smallint, p_source_type text, p_source_ref text, p_idempotency_key text) from public;
-- ================= Tier 4 BCD addendum (2026-11-20) =================
-- B/C/D decisions (~/workspace/inhaworld-tier04-remaining/DECISIONS.md).
-- Hand-written Tier 4 SQL, NOT generated from the scratch closure:
--   * create_my_world_profile_v1 has no origin RPC (the origin creates a
--     profile by direct INSERT after Supabase signup); it is new by design.
--   * request/admin_claim_world_mail_verification_v1 implement the (c)
--     manual-admin fallback for mail 501: no mail is sent, no external
--     account is created. The claim tail (badge upsert + inha_verified
--     achievement when a non-banned profile exists) mirrors the tail of the
--     origin claim_inha_mail_badge(p_primary_id, p_school_id).
--   * touch_world_online_session_v2 / get_world_online_count_v1 are Tier 4
--     adaptations of the origin RPCs of the same names (baseline
--     20261001213132_public_baseline.sql): p_user is added first,
--     auth.uid() is replaced by NULL user_id (no Supabase Auth in Tier 4),
--     the kick-block branch is dropped (no world_session_kick_blocks in
--     Tier 4), and touch gains a 10-second per-session rate limit
--     (C-DESIGN.md §5.3: normal heartbeat is 20 s, so this never trips
--     a healthy client).
-- This file is appended verbatim to the end of schema.sql; apply order is
-- the A-3 schema first, then this addendum (apply-tier4-schema.mjs runs
-- schema.sql in one pass, so the append keeps a single apply step).
-- No auth.* references, no RLS, no direct table grants: only the Worker
-- role inha_world_tier4_writes_app gets EXECUTE on the new RPCs.

-- ---- profile nickname banned words (word-alchemy patch35, verbatim) ----
-- Source: ~/workspace/deploy/word-alchemy/index.html:8975-8982
-- BATTLE_NICK_BANNED (47 words: 37 Korean + 10 English). The list is data,
-- not code: adding a word is an INSERT, not a function change.
create table if not exists private.world_profile_banned_words (
  word text primary key
);
insert into private.world_profile_banned_words (word) values
  ('씨발'), ('시발'), ('시바'), ('씨바'), ('썅'), ('병신'), ('지랄'), ('개새끼'), ('개새'), ('개년'),
  ('새끼'), ('좆'), ('좃'), ('씹'), ('자지'), ('보지'), ('엿'), ('닥쳐'), ('꺼져'), ('죽어'), ('뒤져'),
  ('미친년'), ('미친놈'), ('ㅅㅂ'), ('ㅆㅂ'), ('ㅂㅅ'), ('ㅈㄹ'),
  ('섹스'), ('야동'), ('포르노'), ('자위'), ('음란'),
  ('쪽바리'), ('짱깨'), ('김치녀'), ('된장녀'), ('한남충'),
  ('fuck'), ('shit'), ('bitch'), ('cunt'), ('dick'), ('pussy'), ('whore'), ('slut'), ('bastard'), ('asshole')
on conflict (word) do nothing;

-- patch35 btNormalizeNickForFilter, SQL port (Worker does the exact JS
-- version incl. NFKC first; this is defence-in-depth inside the RPC):
-- lower -> leet 1->i, 0->o, @->a, $->s -> strip separators -> collapse runs.
-- NOTE: SQL lower() does not do NFKC; a full-width lookalike that survives
-- lower() is caught by the Worker-side JS check before the RPC is called.
create or replace function private.world_profile_normalize_nickname_v1(p_nickname text)
returns text language sql immutable set search_path = '' as $fn$
  select regexp_replace(
    regexp_replace(
      replace(replace(replace(replace(lower(btrim(coalesce(p_nickname, ''))), '1', 'i'), '0', 'o'), '@', 'a'), '$', 's'),
      '[\s\-_.,~^*!?·•…]+', '', 'g'),
    '(.)\1+', '\1', 'g');
$fn$;

create or replace function private.world_profile_nickname_banned_v1(p_nickname text)
returns boolean language sql stable set search_path = '' as $fn$
  select exists (
    select 1 from private.world_profile_banned_words w
    where position(w.word in private.world_profile_normalize_nickname_v1(p_nickname)) > 0
  );
$fn$;

-- ---- nickname uniqueness (D-2): banned profiles' nicknames reusable ----
create unique index if not exists profiles_nickname_unique_active
  on public.profiles (lower(nickname)) where is_banned = false;

-- ---- profile creation (D group; no origin RPC) ----
-- POST /api/world-profile. Session 1:1 via profiles.user_id PK. Idempotent:
-- an existing profile is returned with created=false (request content is
-- ignored; edits are a separate API, D-6). A banned profile answers 409
-- PROFILE_REQUIRED through PROFILE_NOT_FOUND so the ban state is not
-- exposed (D-5). title is accepted by the RPC but the Worker always passes
-- NULL at creation (D-PROFILE-MAIL.md §2.2 recommendation).
create or replace function public.create_my_world_profile_v1(p_user uuid, p_nickname text, p_department_id bigint, p_avatar_key text, p_title text)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_nick text := btrim(coalesce(p_nickname, ''));
  v_avatar text := coalesce(p_avatar_key, 'classic');
  v_dept_name text;
  v_existing public.profiles;
begin
  if p_user is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = 'P0001';
  end if;
  if char_length(v_nick) < 2 or char_length(v_nick) > 12
     or v_nick !~ '^[0-9A-Za-z가-힣_ ]+$' then
    raise exception 'INVALID_NICKNAME' using errcode = '22023';
  end if;
  if private.world_profile_nickname_banned_v1(v_nick) then
    raise exception 'INVALID_NICKNAME' using errcode = '22023';
  end if;
  if p_department_id is not null then
    select d.name into v_dept_name from public.departments d
      where d.id = p_department_id and d.active = true;
    if v_dept_name is null then
      raise exception 'INVALID_DEPARTMENT' using errcode = '22023';
    end if;
  end if;
  if v_avatar not in ('classic', 'scholar', 'explorer', 'star') then
    raise exception 'INVALID_AVATAR' using errcode = '22023';
  end if;
  if p_title is not null and char_length(p_title) > 40 then
    raise exception 'INVALID_TITLE' using errcode = '22023';
  end if;

  select * into v_existing from public.profiles p where p.user_id = p_user;
  if found then
    if v_existing.is_banned then
      -- Conceal the ban: same code as a missing profile (D-5).
      raise exception 'PROFILE_NOT_FOUND' using errcode = 'P0001';
    end if;
    select d.name into v_dept_name from public.departments d where d.id = v_existing.department_id;
    return jsonb_build_object(
      'userId', v_existing.user_id, 'nickname', v_existing.nickname,
      'departmentId', v_existing.department_id, 'departmentName', v_dept_name,
      'title', v_existing.title, 'avatarKey', v_existing.avatar_key,
      'isBanned', false, 'createdAt', v_existing.created_at, 'created', false);
  end if;

  if exists (select 1 from public.profiles p
             where lower(p.nickname) = lower(v_nick) and p.is_banned = false) then
    raise exception 'NICKNAME_TAKEN' using errcode = 'P0001';
  end if;

  begin
    insert into public.profiles (user_id, nickname, department_id, title, avatar_key)
      values (p_user, v_nick, p_department_id, p_title, v_avatar);
  exception when unique_violation then
    -- Lost a nickname race against a concurrent insert.
    raise exception 'NICKNAME_TAKEN' using errcode = 'P0001';
  end;
  select * into v_existing from public.profiles p where p.user_id = p_user;
  return jsonb_build_object(
    'userId', v_existing.user_id, 'nickname', v_existing.nickname,
    'departmentId', v_existing.department_id, 'departmentName', v_dept_name,
    'title', v_existing.title, 'avatarKey', v_existing.avatar_key,
    'isBanned', false, 'createdAt', v_existing.created_at, 'created', true);
end;
$fn$;

-- ---- mail verification requests (D-1 (c) manual-admin fallback) ----
-- No mail is sent by this path. A request row is the admin's work queue;
-- the admin claim is gated by the Worker secret MAIL_ADMIN_KEY (the RPC
-- itself has no key parameter; only the Worker can reach it, and the Worker
-- refuses without the header). No personal documents are collected.
create table if not exists private.world_mail_verify_requests (
  request_id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  email text not null,
  status text not null default 'PENDING' check (status in ('PENDING', 'CLAIMED', 'REJECTED')),
  created_at timestamp with time zone default now() not null,
  claimed_at timestamp with time zone
);
create index if not exists world_mail_verify_requests_user_idx
  on private.world_mail_verify_requests (user_id, created_at desc);
create trigger tier4_session_ref before insert or update of user_id
  on private.world_mail_verify_requests
  for each row execute function private.tier4_require_session_v1();

create or replace function public.request_world_mail_verification_v1(p_user uuid, p_email text)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_existing private.world_mail_verify_requests;
  v_count int;
begin
  if p_user is null then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = 'P0001';
  end if;
  if v_email !~ '^[^@\s]+@(inha\.edu|inha\.ac\.kr)$' then
    raise exception 'INVALID_EMAIL' using errcode = '22023';
  end if;
  -- Same user + email, still pending, within 10 minutes: return it, do not
  -- create a second row (client retry / double-tap safe).
  select * into v_existing from private.world_mail_verify_requests r
    where r.user_id = p_user and r.email = v_email and r.status = 'PENDING'
      and r.created_at >= now() - interval '10 minutes'
    order by r.created_at desc limit 1;
  if found then
    return jsonb_build_object(
      'requestId', v_existing.request_id, 'email', v_existing.email,
      'status', 'PENDING', 'duplicate', true);
  end if;
  -- Abuse guard: at most 3 requests per user per hour (any address).
  select count(*) into v_count from private.world_mail_verify_requests r
    where r.user_id = p_user and r.created_at >= now() - interval '1 hour';
  if v_count >= 3 then
    raise exception 'RATE_LIMITED' using errcode = '54000';
  end if;
  insert into private.world_mail_verify_requests (user_id, email)
    values (p_user, v_email) returning * into v_existing;
  return jsonb_build_object(
    'requestId', v_existing.request_id, 'email', v_existing.email,
    'status', 'PENDING', 'duplicate', false);
end;
$fn$;

-- Admin-only (Worker MAIL_ADMIN_KEY gate). Mirrors the tail of the origin
-- claim_inha_mail_badge: badge upsert + inha_verified achievement only when
-- a non-banned profile exists. A claimed/unknown request answers
-- MAIL_REQUEST_NOT_FOUND so the queue state is not exposed.
create or replace function public.admin_claim_world_mail_verification_v1(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_req private.world_mail_verify_requests;
  v_granted boolean;
begin
  if p_request_id is null then
    raise exception 'MAIL_REQUEST_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into v_req from private.world_mail_verify_requests r
    where r.request_id = p_request_id for update;
  if not found or v_req.status <> 'PENDING' then
    raise exception 'MAIL_REQUEST_NOT_FOUND' using errcode = 'P0002';
  end if;
  insert into public.inha_mail_badges (user_id, email, verified_at)
    values (v_req.user_id, v_req.email, now())
    on conflict (user_id) do update
      set email = excluded.email, verified_at = excluded.verified_at;
  insert into public.user_achievements (user_id, achievement_key, earned_at, evidence_source)
    select v_req.user_id, 'inha_verified_v1', now(), 'inha_mail_verified'
    where exists (select 1 from public.profiles p
                  where p.user_id = v_req.user_id and p.is_banned = false)
    on conflict (user_id, achievement_key) do nothing;
  update private.world_mail_verify_requests
    set status = 'CLAIMED', claimed_at = now()
    where request_id = p_request_id;
  select exists (select 1 from public.user_achievements a
                 where a.user_id = v_req.user_id and a.achievement_key = 'inha_verified_v1')
    into v_granted;
  return jsonb_build_object(
    'verified', true, 'userId', v_req.user_id, 'email', v_req.email,
    'requestId', v_req.request_id, 'achievementGranted', v_granted);
end;
$fn$;

-- ---- online heartbeat / count (C-1 (b) HTTP polling) ----
-- Origin table public.world_online_sessions verbatim (columns + indexes);
-- the user_id FK to auth.users is dropped (Tier 4 has no auth.users) and
-- replaced by the tier4_session_ref trigger pattern (no-op while user_id
-- stays NULL; keeps the shape for the D-group account mapping).
create table if not exists public.world_online_sessions (
  session_id uuid not null,
  user_id uuid,
  place_zone_id text,
  space text default 'campus'::text not null,
  started_at timestamp with time zone default now() not null,
  last_seen_at timestamp with time zone default now() not null,
  visitor_id uuid
);
create unique index if not exists world_online_sessions_pkey
  on public.world_online_sessions using btree (session_id);
create index if not exists world_online_sessions_last_seen_idx
  on public.world_online_sessions using btree (last_seen_at desc);
create index if not exists world_online_sessions_space_last_seen_idx
  on public.world_online_sessions using btree (space, last_seen_at desc);
create index if not exists world_online_sessions_visitor_last_seen_idx
  on public.world_online_sessions using btree (visitor_id, last_seen_at desc)
  where visitor_id is not null;
create index if not exists world_online_sessions_zone_last_seen_idx
  on public.world_online_sessions using btree (place_zone_id, last_seen_at desc)
  where place_zone_id is not null;
create trigger tier4_session_ref before insert or update of user_id
  on public.world_online_sessions
  for each row execute function private.tier4_require_session_v1();

-- Origin touch_world_online_session_v2, Tier 4 adaptation (see header).
-- p_user replaces p_session_id; user_id is always NULL. 10-second
-- per-session rate limit (54000, mapped to HTTP 429 by the Worker).
create or replace function public.touch_world_online_session_v2(p_user uuid, p_visitor_id uuid, p_place_zone_id text, p_space text)
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  v_last timestamptz;
begin
  if p_user is null then
    raise exception 'SESSION_ID_REQUIRED' using errcode = '22023';
  end if;
  if p_place_zone_id is not null and p_place_zone_id !~ '^AREA_[A-Z0-9_]{1,60}$' then
    raise exception 'INVALID_PLACE_ZONE' using errcode = '22023';
  end if;
  if p_space not in ('lobby', 'campus', 'club_room', 'housing_lobby', 'personal_room') then
    raise exception 'INVALID_SPACE' using errcode = '22023';
  end if;
  select last_seen_at into v_last from public.world_online_sessions
    where session_id = p_user;
  if v_last is not null and v_last > now() - interval '10 seconds' then
    raise exception 'RATE_LIMITED' using errcode = '54000';
  end if;
  delete from public.world_online_sessions where last_seen_at < now() - interval '1 day';
  insert into public.world_online_sessions (
    session_id, user_id, visitor_id, place_zone_id, space, started_at, last_seen_at
  ) values (
    p_user, null, p_visitor_id, p_place_zone_id, p_space, now(), now()
  ) on conflict (session_id) do update set
    user_id = excluded.user_id,
    visitor_id = coalesce(excluded.visitor_id, public.world_online_sessions.visitor_id),
    place_zone_id = excluded.place_zone_id,
    space = excluded.space,
    last_seen_at = excluded.last_seen_at;
end;
$fn$;

-- Origin get_world_online_count_v1, verbatim body. signedIn is 0 in Tier 4
-- (user_id is always NULL); the response shape is unchanged so the client
-- parser (signedIn + guests === online) keeps working.
create or replace function public.get_world_online_count_v1()
returns jsonb language sql stable security definer set search_path = '' as $fn$
  with active as (
    select * from public.world_online_sessions
    where last_seen_at >= now() - interval '70 seconds'
  )
  select jsonb_build_object(
    'online', count(*)::int,
    'signedIn', count(user_id)::int,
    'guests', (count(*) - count(user_id))::int,
    'lobby', count(*) filter (where space = 'lobby')::int,
    'campus', count(*) filter (where space = 'campus')::int,
    'clubRoom', count(*) filter (where space = 'club_room')::int,
    'housingLobby', count(*) filter (where space = 'housing_lobby')::int,
    'personalRoom', count(*) filter (where space = 'personal_room')::int,
    'asOf', now()
  )
  from active;
$fn$;

-- ---- grants: Worker role only (A-2/A-3 convention) ----
revoke all on function public.create_my_world_profile_v1(uuid, text, bigint, text, text) from public;
grant execute on function public.create_my_world_profile_v1(uuid, text, bigint, text, text) to inha_world_tier4_writes_app;
revoke all on function public.request_world_mail_verification_v1(uuid, text) from public;
grant execute on function public.request_world_mail_verification_v1(uuid, text) to inha_world_tier4_writes_app;
revoke all on function public.admin_claim_world_mail_verification_v1(uuid) from public;
grant execute on function public.admin_claim_world_mail_verification_v1(uuid) to inha_world_tier4_writes_app;
revoke all on function public.touch_world_online_session_v2(uuid, uuid, text, text) from public;
grant execute on function public.touch_world_online_session_v2(uuid, uuid, text, text) to inha_world_tier4_writes_app;
revoke all on function public.get_world_online_count_v1() from public;
grant execute on function public.get_world_online_count_v1() to inha_world_tier4_writes_app;
revoke all on function private.world_profile_normalize_nickname_v1(text) from public;
grant execute on function private.world_profile_normalize_nickname_v1(text) to inha_world_tier4_writes_app;
revoke all on function private.world_profile_nickname_banned_v1(text) from public;
grant execute on function private.world_profile_nickname_banned_v1(text) to inha_world_tier4_writes_app;
