-- INHA WORLD — Tier 3 data-layer schema for Neon (Postgres 16+).
-- Collection book, fishing, ranked runs, Inkyung duck observation, Inha mail badge.
--
-- Apply ONLY to an isolated Neon branch (or a disposable local database) until the
-- owner approves a cutover. Never apply it to the live `inha-world-sync` main branch
-- as part of this tier's verification. Idempotent: safe to re-run. No secrets, no
-- role passwords.
--
-- HOW THIS FILE WAS PRODUCED
-- The original Supabase migrations (aldol2678/inhagame HEAD 0b72d259, all 52, in
-- order) were applied to a local scratch database. Every table and function that
-- the Tier 3 RPCs reach — directly, through private helpers, foreign keys, triggers
-- or column defaults — was then read back from the catalog, so each definition is
-- the FINAL state after every redefinition (e.g. world_fishing_start_v1 is the
-- f2 -> f3 -> skill-effects result). Function bodies are otherwise untouched.
--
-- WHAT IS DIFFERENT FROM THE ORIGINAL (also listed in README.md)
--  1. Identity. Every `user_id uuid` / `p_user uuid` now names a row of
--     public.sessions (the v0.1 guest session, `X-Session-Id`), not auth.users.
--     sessions.id is TEXT holding a lower-case UUID, so the uuid is compared as
--     `sessions.id = <uuid>::text`. RPC signatures are unchanged.
--  2. FOREIGN KEY (user_id) REFERENCES auth.users is replaced by the row trigger
--     `tier3_session_ref` (private.tier3_require_session_v1): a uuid column cannot
--     reference a text column. It raises foreign_key_violation (23503) like the
--     constraint did. There is NO on-delete cascade from sessions.
--  3. private.world_*_account_ok_v1 (5 functions): the original required an auth.users
--     row that is not anonymous AND a public.profiles row with is_banned = false. Both
--     are gone (guest-open decision, 2026-11-12): the session existing in
--     public.sessions is the whole check. A session without a profile row can fish,
--     read its collection book and observe ducks, and these paths no longer check a
--     ban. public.profiles stays for ranked runs, which keep PROFILE_REQUIRED and
--     their own is_banned check in the Worker.
--  4. The `auth.role() = 'service_role'` guard (SERVER_ONLY) is removed from the
--     functions that had it; EXECUTE is granted to the Worker role only instead.
--  5. *_append_only triggers allowed DELETE once the auth.users row was gone; they
--     now allow it once the sessions row is gone.
--  6. public.get_my_rank_v3 takes the session id as a parameter (was auth.uid()).
--  7. public.claim_inha_mail_badge read email / email_confirmed_at / is_anonymous of
--     both accounts from auth.users. Sessions carry none of that. The primary check
--     is now "the session exists"; the school mailbox is read from
--     private.inha_mail_verified_mailboxes, which NOTHING in Tier 3 writes. Identity
--     verification is not ported, so the function fails closed until that is decided.
--  8. Not carried over: row level security and policies (the Worker role has
--     table-level grants only), the ops/analytics mirror triggers on ranked_sessions
--     and ranked_runs (log_ranked_*_event, trg_sync_inha_duck_*, touch_inha_duck_ops_refresh)
--     and their tables, and every object no Tier 3 RPC reaches.

create schema if not exists private;

-- v0.1 sync schema already owns this table. It is NOT redefined here: the statement
-- only creates it when it is missing (e.g. a disposable test database), with the
-- same columns as reference/schema-v01-sync.sql.
create table if not exists public.sessions (
  id text primary key,
  nickname text not null,
  created_at timestamptz not null default now()
);

-- Replacement for FOREIGN KEY (user_id) REFERENCES auth.users(id).
create or replace function private.tier3_require_session_v1()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if new.user_id is not null
     and not exists (select 1 from public.sessions s where s.id = new.user_id::text) then
    raise exception 'user_id % is not a session', new.user_id
      using errcode = 'foreign_key_violation';
  end if;
  return new;
end;
$fn$;

-- Stand-in for the facts claim_inha_mail_badge read from the school account's
-- auth.users row (email, email_confirmed_at). Nothing in Tier 3 writes this table
-- and no role but the owner can. It exists so the ported function and its oracle
-- keep their shape; it is NOT a verification mechanism.
create table if not exists private.inha_mail_verified_mailboxes (
  school_id uuid primary key,
  email text not null,
  confirmed_at timestamptz
);

-- ===========================================================================
-- Tables (final state after every original migration; primary key, unique and
-- check constraints inline, foreign keys added further down).
-- ===========================================================================

-- P0 T1 Activity attempt authority. Terminal outcome is immutable; settlement belongs to other domains.
create table if not exists private.world_activity_attempts (
  attempt_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  activity_id text not null,
  source_ref text not null,
  client_attempt_key uuid not null,
  status text not null,
  outcome_type text,
  result_ref text,
  definition_version integer not null,
  resolver_version integer not null,
  created_at timestamp with time zone default now() not null,
  activated_at timestamp with time zone,
  finalized_at timestamp with time zone,
  expires_at timestamp with time zone,
  constraint world_activity_attempts_pkey PRIMARY KEY (attempt_id),
  constraint world_activity_attempts_client_key UNIQUE (user_id, client_attempt_key),
  constraint world_activity_attempts_activity_id_check CHECK (((activity_id ~ '^activity\.[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,4}$'::text) AND (char_length(activity_id) <= 120))),
  constraint world_activity_attempts_definition_version_check CHECK ((definition_version >= 1)),
  constraint world_activity_attempts_expiry CHECK (((expires_at IS NULL) OR (expires_at > created_at))),
  constraint world_activity_attempts_outcome_type_check CHECK (((outcome_type IS NULL) OR (outcome_type ~ '^[A-Z][A-Z0-9_]{0,63}$'::text))),
  constraint world_activity_attempts_resolver_version_check CHECK ((resolver_version >= 1)),
  constraint world_activity_attempts_result_ref_check CHECK (((result_ref IS NULL) OR (result_ref ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text))),
  constraint world_activity_attempts_source_ref_check CHECK (((source_ref ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,5}$'::text) AND (char_length(source_ref) <= 160))),
  constraint world_activity_attempts_state_shape CHECK ((((status = 'CREATED'::text) AND (activated_at IS NULL) AND (finalized_at IS NULL) AND (outcome_type IS NULL) AND (result_ref IS NULL)) OR ((status = 'ACTIVE'::text) AND (activated_at IS NOT NULL) AND (finalized_at IS NULL) AND (outcome_type IS NULL) AND (result_ref IS NULL)) OR ((status = 'SUCCEEDED'::text) AND (activated_at IS NOT NULL) AND (finalized_at IS NOT NULL) AND (outcome_type IS NOT NULL) AND (result_ref IS NOT NULL)) OR ((status = ANY (ARRAY['FAILED'::text, 'CANCELLED'::text, 'EXPIRED'::text])) AND (activated_at IS NOT NULL) AND (finalized_at IS NOT NULL) AND (outcome_type IS NOT NULL) AND (result_ref IS NULL)))),
  constraint world_activity_attempts_status_check CHECK ((status = ANY (ARRAY['CREATED'::text, 'ACTIVE'::text, 'SUCCEEDED'::text, 'FAILED'::text, 'CANCELLED'::text, 'EXPIRED'::text])))
);

-- Append-only settlement receipt per verified Activity result (Authority Map 7.4).
create table if not exists private.world_activity_settlements (
  attempt_id uuid not null,
  user_id uuid not null,
  activity_id text not null,
  result_ref text not null,
  plan jsonb not null,
  receipt jsonb not null,
  settled_at timestamp with time zone default now() not null,
  constraint world_activity_settlements_pkey PRIMARY KEY (attempt_id),
  constraint world_activity_settlements_result_ref_key UNIQUE (result_ref),
  constraint world_activity_settlements_plan_check CHECK ((jsonb_typeof(plan) = 'object'::text)),
  constraint world_activity_settlements_receipt_check CHECK ((jsonb_typeof(receipt) = 'object'::text))
);

-- Append-only verified discovery events. One idempotency key represents one verified source result.
create table if not exists private.world_collection_discovery_events (
  discovery_event_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  entry_id text not null,
  source_type text not null,
  source_ref text not null,
  result_ref text,
  idempotency_key text not null,
  definition_version integer not null,
  metadata jsonb,
  discovered_at timestamp with time zone default now() not null,
  constraint world_collection_discovery_events_pkey PRIMARY KEY (discovery_event_id),
  constraint world_collection_discovery_events_idempotency_key_key UNIQUE (idempotency_key),
  constraint world_collection_discovery_events_definition_version_check CHECK ((definition_version >= 1)),
  constraint world_collection_discovery_events_entry_id_check CHECK (((entry_id ~ '^collection\.[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,4}$'::text) AND (char_length(entry_id) <= 120))),
  constraint world_collection_discovery_events_idempotency_key_check CHECK ((idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text)),
  constraint world_collection_discovery_events_metadata_check CHECK (((metadata IS NULL) OR ((jsonb_typeof(metadata) = 'object'::text) AND (octet_length((metadata)::text) <= 2048)))),
  constraint world_collection_discovery_events_result_ref_check CHECK (((result_ref IS NULL) OR ((result_ref ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text) AND (char_length(result_ref) <= 200)))),
  constraint world_collection_discovery_events_source_ref_check CHECK (((char_length(source_ref) >= 1) AND (char_length(source_ref) <= 200))),
  constraint world_collection_discovery_events_source_type_check CHECK ((source_type = ANY (ARRAY['ACTIVITY'::text, 'OWNERSHIP'::text, 'QUEST'::text, 'EVENT'::text, 'COMBAT'::text, 'RESEARCH'::text, 'SYSTEM'::text, 'ADMIN'::text])))
);

-- Write-authority mirror of the Collection Entry code Registry. Not a presentation catalog.
create table if not exists private.world_collection_entry_catalog (
  entry_id text not null,
  category text not null,
  persistence_mode text not null,
  owner_domain text,
  owner_ref text,
  status text not null,
  definition_version integer not null,
  constraint world_collection_entry_catalog_pkey PRIMARY KEY (entry_id),
  constraint world_collection_entry_catalog_category_check CHECK ((category ~ '^[A-Z][A-Z0-9_]{1,31}$'::text)),
  constraint world_collection_entry_catalog_definition_version_check CHECK ((definition_version >= 1)),
  constraint world_collection_entry_catalog_entry_id_check CHECK (((entry_id ~ '^collection\.[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,4}$'::text) AND (char_length(entry_id) <= 120))),
  constraint world_collection_entry_catalog_owner_shape CHECK ((((persistence_mode = 'SERVER_PERSISTED'::text) AND (owner_domain IS NULL) AND (owner_ref IS NULL)) OR ((persistence_mode = 'DERIVED_FROM_OWNER'::text) AND (owner_domain IS NOT NULL) AND ((char_length(owner_domain) >= 1) AND (char_length(owner_domain) <= 200)) AND (owner_ref IS NOT NULL) AND ((char_length(owner_ref) >= 1) AND (char_length(owner_ref) <= 200))) OR ((persistence_mode = ANY (ARRAY['SESSION_ONLY'::text, 'PRESENTATION_ONLY'::text])) AND (owner_domain IS NULL) AND (owner_ref IS NULL)))),
  constraint world_collection_entry_catalog_persistence_mode_check CHECK ((persistence_mode = ANY (ARRAY['SERVER_PERSISTED'::text, 'DERIVED_FROM_OWNER'::text, 'SESSION_ONLY'::text, 'PRESENTATION_ONLY'::text]))),
  constraint world_collection_entry_catalog_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'COMING_SOON'::text, 'DISABLED'::text, 'HIDDEN'::text])))
);

-- Append-only successful Creature acquisition claims. One Inkyung duck companion per account/rule.
create table if not exists private.world_creature_acquisition_claims (
  claim_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  rule_id text not null,
  creature_id uuid not null,
  claim_key text not null,
  observation_count_at_claim integer not null,
  auto_activated boolean not null,
  claimed_at timestamp with time zone default now() not null,
  constraint world_creature_acquisition_claims_pkey PRIMARY KEY (claim_id),
  constraint world_creature_acquisition_claims_claim_key_key UNIQUE (claim_key),
  constraint world_creature_acquisition_claims_creature_id_key UNIQUE (creature_id),
  constraint world_creature_acquisition_claims_user_id_rule_id_key UNIQUE (user_id, rule_id),
  constraint world_creature_acquisition_cla_observation_count_at_claim_check CHECK ((observation_count_at_claim >= 1)),
  constraint world_creature_acquisition_claims_claim_key_check CHECK ((claim_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text))
);

-- Creature acquisition authority. Observation eligibility and target form are server-owned.
create table if not exists private.world_creature_acquisition_rule_catalog (
  rule_id text not null,
  species_id text not null,
  form_id text not null,
  source_ref text not null,
  required_observation_count integer not null,
  auto_activate_if_party_empty boolean default false not null,
  status text not null,
  definition_version integer not null,
  constraint world_creature_acquisition_rule_catalog_pkey PRIMARY KEY (rule_id),
  constraint world_creature_acquisition_rul_required_observation_count_check CHECK ((required_observation_count >= 1)),
  constraint world_creature_acquisition_rule_catalo_definition_version_check CHECK ((definition_version >= 1)),
  constraint world_creature_acquisition_rule_catalog_rule_id_check CHECK (((rule_id ~ '^creature\.acquisition\.[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,3}$'::text) AND (char_length(rule_id) <= 140))),
  constraint world_creature_acquisition_rule_catalog_source_ref_check CHECK (((source_ref ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,6}$'::text) AND (char_length(source_ref) <= 160))),
  constraint world_creature_acquisition_rule_catalog_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'COMING_SOON'::text, 'DISABLED'::text, 'HIDDEN'::text])))
);

-- Creature Core-owned mapping from verified external semantic events to Creature XP and Memory. P0 intentionally empty.
create table if not exists private.world_creature_activity_bridge_catalog (
  bridge_id text not null,
  source_domain text not null,
  semantic_event_type text not null,
  memory_tag text not null,
  xp_amount bigint not null,
  cooldown_seconds integer not null,
  daily_cap integer,
  status text not null,
  definition_version integer not null,
  constraint world_creature_activity_bridge_catalog_pkey PRIMARY KEY (bridge_id),
  constraint world_creature_activity_bridge_catalo_semantic_event_type_check CHECK ((semantic_event_type ~ '^(activity|combat|exploration|social|housing)\.[a-z][a-z0-9_.]{0,95}$'::text)),
  constraint world_creature_activity_bridge_catalog_bridge_id_check CHECK (((bridge_id ~ '^creature\.bridge\.[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,3}$'::text) AND (char_length(bridge_id) <= 120))),
  constraint world_creature_activity_bridge_catalog_cooldown_seconds_check CHECK ((cooldown_seconds >= 0)),
  constraint world_creature_activity_bridge_catalog_daily_cap_check CHECK (((daily_cap IS NULL) OR (daily_cap >= 1))),
  constraint world_creature_activity_bridge_catalog_definition_version_check CHECK ((definition_version >= 1)),
  constraint world_creature_activity_bridge_catalog_memory_tag_check CHECK (((memory_tag ~ '^memory\.[a-z][a-z0-9_]*(\.[a-z0-9_]+){0,3}$'::text) AND (char_length(memory_tag) <= 120))),
  constraint world_creature_activity_bridge_catalog_source_domain_check CHECK ((source_domain = ANY (ARRAY['ACTIVITY'::text, 'COMBAT'::text, 'EXPLORATION'::text, 'SOCIAL'::text, 'HOUSING'::text]))),
  constraint world_creature_activity_bridge_catalog_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'COMING_SOON'::text, 'DISABLED'::text, 'HIDDEN'::text]))),
  constraint world_creature_activity_bridge_catalog_xp_amount_check CHECK ((xp_amount >= 0)),
  constraint world_creature_bridge_domain_event CHECK ((((source_domain = 'ACTIVITY'::text) AND (semantic_event_type ~~ 'activity.%'::text)) OR ((source_domain = 'COMBAT'::text) AND (semantic_event_type ~~ 'combat.%'::text)) OR ((source_domain = 'EXPLORATION'::text) AND (semantic_event_type ~~ 'exploration.%'::text)) OR ((source_domain = 'SOCIAL'::text) AND (semantic_event_type ~~ 'social.%'::text)) OR ((source_domain = 'HOUSING'::text) AND (semantic_event_type ~~ 'housing.%'::text))))
);

-- Append-only replay-safe decision ledger. NOOP rows intentionally prevent later backfill after party/context changes.
create table if not exists private.world_creature_activity_events (
  creature_activity_event_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  bridge_id text not null,
  source_ref text not null,
  source_result_ref text not null,
  source_event_key text not null,
  party_revision bigint not null,
  creature_id uuid,
  decision text not null,
  xp_awarded bigint not null,
  memory_tag text,
  occurred_at timestamp with time zone not null,
  processed_at timestamp with time zone default now() not null,
  constraint world_creature_activity_events_pkey PRIMARY KEY (creature_activity_event_id),
  constraint world_creature_activity_event_user_id_bridge_id_source_resu_key UNIQUE (user_id, bridge_id, source_result_ref),
  constraint world_creature_activity_events_source_event_key_key UNIQUE (source_event_key),
  constraint world_creature_activity_decision_shape CHECK ((((decision = 'ACCEPTED'::text) AND (creature_id IS NOT NULL) AND (memory_tag IS NOT NULL)) OR ((decision <> 'ACCEPTED'::text) AND (xp_awarded = 0) AND (memory_tag IS NULL)))),
  constraint world_creature_activity_events_decision_check CHECK ((decision = ANY (ARRAY['ACCEPTED'::text, 'NOOP_NO_ACTIVE'::text, 'NOOP_COOLDOWN'::text, 'NOOP_CAP'::text]))),
  constraint world_creature_activity_events_memory_tag_check CHECK (((memory_tag IS NULL) OR ((memory_tag ~ '^memory\.[a-z][a-z0-9_]*(\.[a-z0-9_]+){0,3}$'::text) AND (char_length(memory_tag) <= 120)))),
  constraint world_creature_activity_events_party_revision_check CHECK ((party_revision >= 0)),
  constraint world_creature_activity_events_source_event_key_check CHECK ((source_event_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text)),
  constraint world_creature_activity_events_source_ref_check CHECK (((source_ref ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,6}$'::text) AND (char_length(source_ref) <= 160))),
  constraint world_creature_activity_events_source_result_ref_check CHECK ((source_result_ref ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text)),
  constraint world_creature_activity_events_xp_awarded_check CHECK ((xp_awarded >= 0))
);

-- Creature form write-authority mirror. P0 intentionally commits no form identities.
create table if not exists private.world_creature_form_catalog (
  form_id text not null,
  species_id text not null,
  status text not null,
  definition_version integer not null,
  constraint world_creature_form_catalog_pkey PRIMARY KEY (form_id),
  constraint world_creature_form_catalog_definition_version_check CHECK ((definition_version >= 1)),
  constraint world_creature_form_catalog_form_id_check CHECK (((form_id ~ '^creature\.form\.[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'::text) AND (char_length(form_id) <= 120))),
  constraint world_creature_form_catalog_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'COMING_SOON'::text, 'DISABLED'::text, 'HIDDEN'::text])))
);

-- Creature Core-owned semantic Memory projection derived from accepted verified activity events.
create table if not exists private.world_creature_memory_tags (
  creature_id uuid not null,
  memory_tag text not null,
  memory_count bigint not null,
  first_remembered_at timestamp with time zone not null,
  last_remembered_at timestamp with time zone not null,
  version bigint default 1 not null,
  constraint world_creature_memory_tags_pkey PRIMARY KEY (creature_id, memory_tag),
  constraint world_creature_memory_tags_memory_count_check CHECK ((memory_count >= 1)),
  constraint world_creature_memory_tags_memory_tag_check CHECK (((memory_tag ~ '^memory\.[a-z][a-z0-9_]*(\.[a-z0-9_]+){0,3}$'::text) AND (char_length(memory_tag) <= 120))),
  constraint world_creature_memory_tags_version_check CHECK ((version >= 1)),
  constraint world_creature_memory_time CHECK ((last_remembered_at >= first_remembered_at))
);

-- Append-only verified Creature observation provenance. Observation does not imply ownership or bonding.
create table if not exists private.world_creature_observation_events (
  observation_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  species_id text not null,
  source_type text not null,
  source_ref text not null,
  result_ref text not null,
  idempotency_key text not null,
  observed_at timestamp with time zone default now() not null,
  constraint world_creature_observation_events_pkey PRIMARY KEY (observation_id),
  constraint world_creature_observation_ev_user_id_species_id_result_ref_key UNIQUE (user_id, species_id, result_ref),
  constraint world_creature_observation_events_idempotency_key_key UNIQUE (idempotency_key),
  constraint world_creature_observation_events_idempotency_key_check CHECK ((idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text)),
  constraint world_creature_observation_events_result_ref_check CHECK ((result_ref ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text)),
  constraint world_creature_observation_events_source_ref_check CHECK (((source_ref ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,6}$'::text) AND (char_length(source_ref) <= 160))),
  constraint world_creature_observation_events_source_type_check CHECK ((source_type = ANY (ARRAY['WORLD'::text, 'QUEST'::text, 'ACTIVITY'::text, 'COMBAT'::text, 'RESEARCH'::text, 'SYSTEM'::text, 'ADMIN'::text])))
);

-- Append-only party revision history used to bind later verified Activity results to the ACTIVE Creature at occurrence time.
create table if not exists private.world_creature_party_history (
  user_id uuid not null,
  revision bigint not null,
  active_creature_id uuid,
  reserve1_creature_id uuid,
  reserve2_creature_id uuid,
  mutation_key text not null,
  committed_at timestamp with time zone default now() not null,
  constraint world_creature_party_history_pkey PRIMARY KEY (user_id, revision),
  constraint world_creature_party_history_mutation_key_key UNIQUE (mutation_key),
  constraint world_creature_party_history_mutation_key_check CHECK ((mutation_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text)),
  constraint world_creature_party_history_revision_check CHECK ((revision >= 1)),
  constraint world_creature_party_history_shape CHECK (((active_creature_id IS NOT NULL) OR ((reserve1_creature_id IS NULL) AND (reserve2_creature_id IS NULL)))),
  constraint world_creature_party_history_unique_slots CHECK ((((active_creature_id IS NULL) OR (reserve1_creature_id IS NULL) OR (active_creature_id <> reserve1_creature_id)) AND ((active_creature_id IS NULL) OR (reserve2_creature_id IS NULL) OR (active_creature_id <> reserve2_creature_id)) AND ((reserve1_creature_id IS NULL) OR (reserve2_creature_id IS NULL) OR (reserve1_creature_id <> reserve2_creature_id))))
);

-- Current Active 1 + Reserve 2 party projection. Revision changes on every committed party mutation.
create table if not exists private.world_creature_party_state (
  user_id uuid not null,
  revision bigint default 0 not null,
  active_creature_id uuid,
  reserve1_creature_id uuid,
  reserve2_creature_id uuid,
  updated_at timestamp with time zone default now() not null,
  constraint world_creature_party_state_pkey PRIMARY KEY (user_id),
  constraint world_creature_party_state_revision_check CHECK ((revision >= 0)),
  constraint world_creature_party_state_shape CHECK (((active_creature_id IS NOT NULL) OR ((reserve1_creature_id IS NULL) AND (reserve2_creature_id IS NULL)))),
  constraint world_creature_party_state_unique_slots CHECK ((((active_creature_id IS NULL) OR (reserve1_creature_id IS NULL) OR (active_creature_id <> reserve1_creature_id)) AND ((active_creature_id IS NULL) OR (reserve2_creature_id IS NULL) OR (active_creature_id <> reserve2_creature_id)) AND ((reserve1_creature_id IS NULL) OR (reserve2_creature_id IS NULL) OR (reserve1_creature_id <> reserve2_creature_id))))
);

-- Creature species write-authority mirror. Product presentation remains in code.
create table if not exists private.world_creature_species_catalog (
  species_id text not null,
  status text not null,
  definition_version integer not null,
  constraint world_creature_species_catalog_pkey PRIMARY KEY (species_id),
  constraint world_creature_species_catalog_definition_version_check CHECK ((definition_version >= 1)),
  constraint world_creature_species_catalog_species_id_check CHECK (((species_id ~ '^creature\.species\.[a-z][a-z0-9_]*$'::text) AND (char_length(species_id) <= 100))),
  constraint world_creature_species_catalog_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'COMING_SOON'::text, 'DISABLED'::text, 'HIDDEN'::text])))
);

-- Append-only Creature XP ledger. XP amounts are resolved only from Creature Core bridge definitions.
create table if not exists private.world_creature_xp_transactions (
  transaction_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  creature_id uuid not null,
  creature_activity_event_id uuid not null,
  amount bigint not null,
  xp_before bigint not null,
  xp_after bigint not null,
  created_at timestamp with time zone default now() not null,
  constraint world_creature_xp_transactions_pkey PRIMARY KEY (transaction_id),
  constraint world_creature_xp_transactions_creature_activity_event_id_key UNIQUE (creature_activity_event_id),
  constraint world_creature_xp_math CHECK ((xp_after = (xp_before + amount))),
  constraint world_creature_xp_transactions_amount_check CHECK ((amount > 0)),
  constraint world_creature_xp_transactions_xp_after_check CHECK ((xp_after >= 0)),
  constraint world_creature_xp_transactions_xp_before_check CHECK ((xp_before >= 0))
);

create table if not exists private.world_fishing_attempt_snapshots (
  attempt_id uuid not null,
  user_id uuid not null,
  snapshot jsonb not null,
  constraint world_fishing_attempt_snapshots_pkey PRIMARY KEY (attempt_id),
  constraint world_fishing_attempt_snapshots_snapshot_check CHECK ((jsonb_typeof(snapshot) = 'object'::text))
);

create table if not exists private.world_fishing_positions (
  user_id uuid not null,
  session_id uuid not null,
  revision bigint not null,
  x double precision not null,
  y double precision not null,
  z double precision not null,
  space text not null,
  mode text not null,
  observed_at timestamp with time zone not null,
  constraint world_fishing_positions_pkey PRIMARY KEY (user_id),
  constraint world_fishing_positions_mode_check CHECK ((mode = ANY (ARRAY['ON_FOOT'::text, 'INELIGIBLE'::text]))),
  constraint world_fishing_positions_revision_check CHECK ((revision > 0)),
  constraint world_fishing_positions_space_check CHECK ((space = ANY (ARRAY['CAMPUS'::text, 'OTHER'::text]))),
  constraint world_fishing_positions_x_check CHECK (((x >= ('-10000'::integer)::double precision) AND (x <= (10000)::double precision))),
  constraint world_fishing_positions_y_check CHECK (((y >= ('-10000'::integer)::double precision) AND (y <= (10000)::double precision))),
  constraint world_fishing_positions_z_check CHECK (((z >= ('-10000'::integer)::double precision) AND (z <= (10000)::double precision)))
);

create table if not exists private.world_fishing_runtime (
  singleton boolean default true not null,
  enabled boolean default false not null,
  policy jsonb,
  minimum_start_interval_ms bigint,
  presence_required boolean default true not null,
  constraint world_fishing_runtime_pkey PRIMARY KEY (singleton),
  constraint world_fishing_runtime_minimum_start_interval_ms_check CHECK ((minimum_start_interval_ms > 0)),
  constraint world_fishing_runtime_singleton_check CHECK (singleton)
);

create table if not exists private.world_fishing_spot_leases (
  source_ref text not null,
  user_id uuid not null,
  attempt_id uuid not null,
  session_id uuid not null,
  expires_at timestamp with time zone not null,
  constraint world_fishing_spot_leases_pkey PRIMARY KEY (source_ref),
  constraint world_fishing_spot_leases_attempt_id_key UNIQUE (attempt_id),
  constraint world_fishing_spot_leases_user_id_key UNIQUE (user_id)
);

create table if not exists private.world_fishing_spots (
  source_ref text not null,
  x double precision not null,
  z double precision not null,
  radius double precision not null,
  min_y double precision not null,
  max_y double precision not null,
  constraint world_fishing_spots_pkey PRIMARY KEY (source_ref),
  constraint world_fishing_spots_check CHECK ((max_y > min_y)),
  constraint world_fishing_spots_radius_check CHECK (((radius > (0)::double precision) AND (radius <= (3)::double precision)))
);

-- Ordinary Inkyung Pond duck subjects eligible for verified Creature observation. Mechanical duck is intentionally excluded.
create table if not exists private.world_inkyung_duck_observation_subjects (
  duck_id text not null,
  kind text not null,
  status text not null,
  constraint world_inkyung_duck_observation_subjects_pkey PRIMARY KEY (duck_id),
  constraint world_inkyung_duck_observation_subjects_duck_id_check CHECK (((duck_id ~ '^inkyung_duck_[a-z0-9_]+$'::text) AND (char_length(duck_id) <= 80))),
  constraint world_inkyung_duck_observation_subjects_kind_check CHECK ((kind = ANY (ARRAY['white'::text, 'mallard'::text]))),
  constraint world_inkyung_duck_observation_subjects_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'DISABLED'::text])))
);

-- Grant-authority mirror of the C0 code catalog. Life M1 adds STACKABLE MATERIAL fixtures; prices remain outside the catalog.
create table if not exists private.world_item_catalog (
  item_id text not null,
  category text not null,
  ownership_policy text not null,
  max_stack integer,
  status text not null,
  constraint world_item_catalog_pkey PRIMARY KEY (item_id),
  constraint world_item_catalog_category_check CHECK ((category = ANY (ARRAY['WEARABLE'::text, 'BADGE'::text, 'EMOTE'::text, 'FURNITURE'::text, 'MOUNT'::text, 'MOUNT_COSMETIC'::text, 'MEMORABILIA'::text, 'MATERIAL'::text, 'CONSUMABLE'::text, 'ROOM_FINISH'::text]))),
  constraint world_item_catalog_item_id_check CHECK (((item_id ~ '^[a-z][a-z0-9_]*\.[a-z0-9_]+$'::text) AND (char_length(item_id) <= 80))),
  constraint world_item_catalog_ownership_policy_check CHECK ((ownership_policy = ANY (ARRAY['UNIQUE'::text, 'STACKABLE'::text]))),
  constraint world_item_catalog_stack_policy CHECK ((((ownership_policy = 'UNIQUE'::text) AND (max_stack IS NULL)) OR ((ownership_policy = 'STACKABLE'::text) AND (max_stack >= 2)))),
  constraint world_item_catalog_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'LOCKED'::text, 'COMING_SOON'::text, 'DISABLED'::text, 'HIDDEN'::text])))
);

-- INHA WORLD item grant log. grant_id is the idempotency key; rows are never updated.
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
  created_at timestamp with time zone default now() not null,
  constraint world_item_grants_pkey PRIMARY KEY (grant_id),
  constraint world_item_grants_acquisition_metadata_check CHECK (((acquisition_metadata IS NULL) OR ((jsonb_typeof(acquisition_metadata) = 'object'::text) AND (octet_length((acquisition_metadata)::text) <= 2048)))),
  constraint world_item_grants_event_id_check CHECK (((event_id IS NULL) OR (event_id ~ '^[a-z][a-z0-9_]*\.[a-z0-9_]+$'::text))),
  constraint world_item_grants_grant_id_check CHECK ((grant_id ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text)),
  constraint world_item_grants_quantity_after_check CHECK ((quantity_after >= 0)),
  constraint world_item_grants_quantity_before_check CHECK ((quantity_before >= 0)),
  constraint world_item_grants_quantity_granted_check CHECK ((quantity_granted >= 0)),
  constraint world_item_grants_quantity_math CHECK ((quantity_after = (quantity_before + quantity_granted))),
  constraint world_item_grants_quantity_requested_check CHECK ((quantity_requested >= 1)),
  constraint world_item_grants_result CHECK ((((result = 'GRANTED'::text) AND (quantity_granted = quantity_requested)) OR ((result = 'ALREADY_OWNED'::text) AND (quantity_granted = 0)))),
  constraint world_item_grants_result_check CHECK ((result = ANY (ARRAY['GRANTED'::text, 'ALREADY_OWNED'::text]))),
  constraint world_item_grants_source_ref_check CHECK (((char_length(source_ref) >= 1) AND (char_length(source_ref) <= 200))),
  constraint world_item_grants_source_type_check CHECK ((source_type = ANY (ARRAY['DEFAULT'::text, 'QUEST'::text, 'EXPLORATION'::text, 'ACHIEVEMENT'::text, 'EVENT'::text, 'MINIGAME'::text, 'SHOP'::text, 'INHAGAME_REWARD'::text, 'ACTIVITY'::text, 'CRAFTING'::text, 'EQUIPMENT'::text, 'RESEARCH'::text, 'SYSTEM'::text, 'ADMIN'::text])))
);

-- Append-only Creature party revision captured when a mapped Life Activity starts.
create table if not exists private.world_life_creature_activity_contexts (
  attempt_id uuid not null,
  user_id uuid not null,
  activity_id text not null,
  party_revision bigint not null,
  bound_at timestamp with time zone default now() not null,
  constraint world_life_creature_activity_contexts_pkey PRIMARY KEY (attempt_id),
  constraint world_life_creature_activity_contexts_party_revision_check CHECK ((party_revision >= 0))
);

-- Cross-domain routing catalog from canonical Life Activity identity to Creature Core bridge identity.
create table if not exists private.world_life_creature_bridge_catalog (
  bridge_id text not null,
  activity_id text not null,
  life_skill_id text not null,
  required_activity_definition_version integer not null,
  created_at timestamp with time zone default now() not null,
  constraint world_life_creature_bridge_catalog_pkey PRIMARY KEY (bridge_id),
  constraint world_life_creature_bridge_catalog_activity_id_key UNIQUE (activity_id),
  constraint world_life_creature_bridge_c_required_activity_definition_check CHECK ((required_activity_definition_version >= 1)),
  constraint world_life_creature_bridge_catalog_activity_id_check CHECK (((activity_id ~ '^activity\.[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,4}$'::text) AND (char_length(activity_id) <= 120)))
);

-- Append-only first-finalization decision; prevents retroactive Creature growth after later activation.
create table if not exists private.world_life_creature_bridge_decisions (
  attempt_id uuid not null,
  user_id uuid not null,
  bridge_id text not null,
  decision text not null,
  creature_activity_event_id uuid,
  decided_at timestamp with time zone default now() not null,
  constraint world_life_creature_bridge_decisions_pkey PRIMARY KEY (attempt_id),
  constraint world_life_creature_bridge_decision_shape CHECK ((((decision = 'FORWARDED'::text) AND (creature_activity_event_id IS NOT NULL)) OR ((decision <> 'FORWARDED'::text) AND (creature_activity_event_id IS NULL)))),
  constraint world_life_creature_bridge_decisions_decision_check CHECK ((decision = ANY (ARRAY['FORWARDED'::text, 'NOOP_ACTIVITY_NOT_SUCCEEDED'::text, 'NOOP_NO_CONTEXT'::text, 'NOOP_INACTIVE'::text])))
);

-- Write-authority mirror of the Life Skill code Registry. Product descriptions remain in code.
create table if not exists private.world_life_skill_catalog (
  skill_id text not null,
  curve_id text not null,
  status text not null,
  constraint world_life_skill_catalog_pkey PRIMARY KEY (skill_id),
  constraint world_life_skill_catalog_curve_id_check CHECK (((curve_id ~ '^life\.[a-z][a-z0-9_]*\.v[0-9]+$'::text) AND (char_length(curve_id) <= 80))),
  constraint world_life_skill_catalog_skill_id_check CHECK (((skill_id ~ '^life\.[a-z][a-z0-9_]*$'::text) AND (char_length(skill_id) <= 80))),
  constraint world_life_skill_catalog_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'COMING_SOON'::text, 'DISABLED'::text, 'HIDDEN'::text])))
);

-- Immutable per-curve Life Skill thresholds with cumulative per-skill SP. Rows append only.
create table if not exists private.world_life_skill_thresholds (
  curve_id text not null,
  level integer not null,
  min_total_xp bigint not null,
  created_at timestamp with time zone default now() not null,
  cumulative_sp integer default 0 not null,
  constraint world_life_skill_thresholds_pkey PRIMARY KEY (curve_id, level),
  constraint world_life_skill_thresholds_cumulative_sp_check CHECK ((cumulative_sp >= 0)),
  constraint world_life_skill_thresholds_curve_id_check CHECK (((curve_id ~ '^life\.[a-z][a-z0-9_]*\.v[0-9]+$'::text) AND (char_length(curve_id) <= 80))),
  constraint world_life_skill_thresholds_level_check CHECK ((level >= 1)),
  constraint world_life_skill_thresholds_min_total_xp_check CHECK ((min_total_xp >= 0))
);

-- Write-authority mirror for Life Skill Tree nodes. Published rows are immutable except status.
create table if not exists private.world_life_skill_tree_catalog (
  node_id text not null,
  skill_id text not null,
  status text not null,
  sp_cost integer not null,
  required_life_level integer not null,
  required_skill_level integer not null,
  max_rank integer default 1 not null,
  constraint world_life_skill_tree_catalog_pkey PRIMARY KEY (node_id),
  constraint world_life_skill_tree_catalog_node_skill_key UNIQUE (node_id, skill_id),
  constraint world_life_skill_tree_catalog_max_rank_check CHECK (((max_rank >= 1) AND (max_rank <= 10))),
  constraint world_life_skill_tree_catalog_node_id_check CHECK (((node_id ~ '^life\.node\.[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'::text) AND (char_length(node_id) <= 120))),
  constraint world_life_skill_tree_catalog_required_life_level_check CHECK ((required_life_level >= 1)),
  constraint world_life_skill_tree_catalog_required_skill_level_check CHECK ((required_skill_level >= 1)),
  constraint world_life_skill_tree_catalog_sp_cost_check CHECK (((sp_cost >= 1) AND (sp_cost <= 99))),
  constraint world_life_skill_tree_catalog_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'COMING_SOON'::text, 'DISABLED'::text, 'HIDDEN'::text])))
);

-- Append-only positive Life Skill XP ledger. Independent from Campus World EXP.
create table if not exists private.world_life_skill_xp_transactions (
  transaction_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  skill_id text not null,
  amount bigint not null,
  xp_before bigint not null,
  xp_after bigint not null,
  level_before integer not null,
  level_after integer not null,
  source_type text not null,
  source_id text not null,
  idempotency_key text not null,
  created_at timestamp with time zone default now() not null,
  constraint world_life_skill_xp_transactions_pkey PRIMARY KEY (transaction_id),
  constraint world_life_skill_xp_transactions_idempotency_key_key UNIQUE (idempotency_key),
  constraint world_life_skill_xp_transactions_amount_check CHECK ((amount > 0)),
  constraint world_life_skill_xp_transactions_idempotency_key_check CHECK ((idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text)),
  constraint world_life_skill_xp_transactions_level_after_check CHECK ((level_after >= 1)),
  constraint world_life_skill_xp_transactions_level_before_check CHECK ((level_before >= 1)),
  constraint world_life_skill_xp_transactions_level_monotonic CHECK ((level_after >= level_before)),
  constraint world_life_skill_xp_transactions_math CHECK ((xp_after = (xp_before + amount))),
  constraint world_life_skill_xp_transactions_source_id_check CHECK (((char_length(source_id) >= 1) AND (char_length(source_id) <= 200))),
  constraint world_life_skill_xp_transactions_source_type_check CHECK ((source_type = ANY (ARRAY['activity'::text, 'crafting'::text, 'research'::text, 'farming'::text, 'system'::text, 'admin'::text]))),
  constraint world_life_skill_xp_transactions_xp_after_check CHECK ((xp_after >= 0)),
  constraint world_life_skill_xp_transactions_xp_before_check CHECK ((xp_before >= 0))
);

-- Append-only per-skill SP spend ledger. skill_id is the SP pool and always equals the node's skill.
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
  epoch integer default 0 not null,
  constraint world_life_sp_transactions_pkey PRIMARY KEY (transaction_id),
  constraint world_life_sp_transactions_idempotency_key_key UNIQUE (idempotency_key),
  constraint world_life_sp_transactions_epoch_check CHECK ((epoch >= 0)),
  constraint world_life_sp_transactions_idempotency_key_check CHECK ((idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text)),
  constraint world_life_sp_transactions_math CHECK ((sp_after = (sp_before - sp_cost))),
  constraint world_life_sp_transactions_rank_check CHECK ((rank >= 1)),
  constraint world_life_sp_transactions_sp_after_check CHECK ((sp_after >= 0)),
  constraint world_life_sp_transactions_sp_before_check CHECK ((sp_before >= 0)),
  constraint world_life_sp_transactions_sp_cost_check CHECK ((sp_cost > 0))
);

-- Append-only Life Skill Tree resets. Each row opens a new epoch for (account, skill).
create table if not exists private.world_life_tree_resets (
  reset_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  skill_id text not null,
  epoch integer not null,
  refunded_sp integer not null,
  cleared_ranks jsonb not null,
  cooldown_seconds integer not null,
  idempotency_key text not null,
  created_at timestamp with time zone default now() not null,
  constraint world_life_tree_resets_pkey PRIMARY KEY (reset_id),
  constraint world_life_tree_resets_epoch_key UNIQUE (user_id, skill_id, epoch),
  constraint world_life_tree_resets_idempotency_key_key UNIQUE (idempotency_key),
  constraint world_life_tree_resets_cleared_ranks_check CHECK ((jsonb_typeof(cleared_ranks) = 'array'::text)),
  constraint world_life_tree_resets_cooldown_seconds_check CHECK ((cooldown_seconds >= 0)),
  constraint world_life_tree_resets_epoch_check CHECK ((epoch >= 1)),
  constraint world_life_tree_resets_idempotency_key_check CHECK ((idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text)),
  constraint world_life_tree_resets_refunded_sp_check CHECK ((refunded_sp > 0))
);

-- Current server-persisted Discovery projection. First provenance is immutable; count/version advance together.
create table if not exists private.world_player_collection_discoveries (
  user_id uuid not null,
  entry_id text not null,
  first_discovered_at timestamp with time zone not null,
  last_discovered_at timestamp with time zone not null,
  discovery_count bigint not null,
  first_source_type text not null,
  first_source_ref text not null,
  first_result_ref text,
  version bigint default 1 not null,
  updated_at timestamp with time zone default now() not null,
  constraint world_player_collection_discoveries_pkey PRIMARY KEY (user_id, entry_id),
  constraint world_player_collection_discoveries_discovery_count_check CHECK ((discovery_count >= 1)),
  constraint world_player_collection_discoveries_entry_id_check CHECK (((entry_id ~ '^collection\.[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,4}$'::text) AND (char_length(entry_id) <= 120))),
  constraint world_player_collection_discoveries_first_result_ref_check CHECK (((first_result_ref IS NULL) OR ((first_result_ref ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text) AND (char_length(first_result_ref) <= 200)))),
  constraint world_player_collection_discoveries_first_source_ref_check CHECK (((char_length(first_source_ref) >= 1) AND (char_length(first_source_ref) <= 200))),
  constraint world_player_collection_discoveries_first_source_type_check CHECK ((first_source_type = ANY (ARRAY['ACTIVITY'::text, 'OWNERSHIP'::text, 'QUEST'::text, 'EVENT'::text, 'COMBAT'::text, 'RESEARCH'::text, 'SYSTEM'::text, 'ADMIN'::text]))),
  constraint world_player_collection_discoveries_time CHECK ((last_discovered_at >= first_discovered_at)),
  constraint world_player_collection_discoveries_version_check CHECK ((version >= 1))
);

-- Per-account owned Creature projection. Current form, Creature XP and revisions are Creature Core authority.
create table if not exists private.world_player_creatures (
  creature_id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  species_id text not null,
  current_form_id text not null,
  form_revision bigint default 0 not null,
  total_xp bigint default 0 not null,
  bond_entitled boolean default false not null,
  version bigint default 0 not null,
  acquisition_key text not null,
  source_ref text not null,
  acquired_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  constraint world_player_creatures_pkey PRIMARY KEY (creature_id),
  constraint world_player_creatures_acquisition_key_key UNIQUE (acquisition_key),
  constraint world_player_creatures_acquisition_key_check CHECK ((acquisition_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'::text)),
  constraint world_player_creatures_form_revision_check CHECK ((form_revision >= 0)),
  constraint world_player_creatures_source_ref_check CHECK (((source_ref ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,6}$'::text) AND (char_length(source_ref) <= 160))),
  constraint world_player_creatures_total_xp_check CHECK ((total_xp >= 0)),
  constraint world_player_creatures_version_check CHECK ((version >= 0))
);

-- INHA WORLD C1 ownership. Written only by private.world_inventory_grant_v1; provenance is the first acquisition.
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
  updated_at timestamp with time zone default now() not null,
  constraint world_player_items_pkey PRIMARY KEY (id),
  constraint world_player_items_user_item_key UNIQUE (user_id, item_id),
  constraint world_player_items_item_id_check CHECK ((item_id ~ '^[a-z][a-z0-9_]*\.[a-z0-9_]+$'::text)),
  constraint world_player_items_quantity_check CHECK ((quantity >= 1))
);

-- Append-only Life Skill Tree ranks acquired by each account. Current rank = highest acquired rank.
create table if not exists private.world_player_life_nodes (
  user_id uuid not null,
  node_id text not null,
  transaction_id uuid not null,
  unlocked_at timestamp with time zone default now() not null,
  rank integer default 1 not null,
  epoch integer default 0 not null,
  constraint world_player_life_nodes_pkey PRIMARY KEY (user_id, node_id, epoch, rank),
  constraint world_player_life_nodes_transaction_id_key UNIQUE (transaction_id),
  constraint world_player_life_nodes_epoch_check CHECK ((epoch >= 0)),
  constraint world_player_life_nodes_rank_check CHECK ((rank >= 1))
);

-- Per-account Life Skill XP projection. Level is never stored; it is derived from the skill curve.
create table if not exists private.world_player_life_skills (
  user_id uuid not null,
  skill_id text not null,
  total_xp bigint default 0 not null,
  version bigint default 0 not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  constraint world_player_life_skills_pkey PRIMARY KEY (user_id, skill_id),
  constraint world_player_life_skills_skill_id_check CHECK (((skill_id ~ '^life\.[a-z][a-z0-9_]*$'::text) AND (char_length(skill_id) <= 80))),
  constraint world_player_life_skills_total_xp_check CHECK ((total_xp >= 0)),
  constraint world_player_life_skills_version_check CHECK ((version >= 0))
);

create table if not exists public.departments (
  id bigint generated by default as identity not null,
  name text not null,
  active boolean default true not null,
  sort_order integer default 0 not null,
  created_at timestamp with time zone default now() not null,
  constraint departments_pkey PRIMARY KEY (id),
  constraint departments_name_key UNIQUE (name),
  constraint departments_name_len CHECK (((char_length(name) >= 1) AND (char_length(name) <= 80)))
);

create table if not exists public.general_stage_bests (
  user_id uuid not null,
  stage_id smallint not null,
  best_score integer default 0 not null,
  best_combo integer default 0 not null,
  achieved_at timestamp with time zone default now() not null,
  best_stars smallint default 0 not null,
  constraint general_stage_bests_pkey PRIMARY KEY (user_id, stage_id),
  constraint general_stage_bests_best_combo_check CHECK ((best_combo >= 0)),
  constraint general_stage_bests_best_score_check CHECK ((best_score >= 0)),
  constraint general_stage_bests_best_stars_check CHECK (((best_stars >= 0) AND (best_stars <= 3))),
  constraint general_stage_bests_stage_id_check CHECK (((stage_id >= 1) AND (stage_id <= 4)))
);

create table if not exists public.inha_mail_badges (
  user_id uuid not null,
  email text not null,
  verified_at timestamp with time zone default now() not null,
  constraint inha_mail_badges_pkey PRIMARY KEY (user_id),
  constraint inha_mail_badges_email_key UNIQUE (email),
  constraint inha_mail_badges_valid_email CHECK ((lower(email) ~ '^[^@[:space:]]+@(inha[.]edu|inha[.]ac[.]kr)$'::text))
);

create table if not exists public.player_bests (
  user_id uuid not null,
  stage_key text default 'secret'::text not null,
  best_score integer not null,
  best_combo integer default 0 not null,
  best_run_id uuid not null,
  achieved_at timestamp with time zone default now() not null,
  constraint player_bests_pkey PRIMARY KEY (user_id, stage_key),
  constraint player_bests_nonnegative CHECK (((best_score >= 0) AND (best_combo >= 0))),
  constraint player_bests_stage CHECK ((stage_key = 'secret'::text))
);

create table if not exists public.profiles (
  user_id uuid not null,
  nickname text not null,
  department_id bigint,
  title text,
  is_banned boolean default false not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  avatar_key text default 'classic'::text not null,
  constraint profiles_pkey PRIMARY KEY (user_id),
  constraint profiles_avatar_key_check CHECK ((avatar_key = ANY (ARRAY['classic'::text, 'scholar'::text, 'explorer'::text, 'star'::text]))),
  constraint profiles_nickname_chars CHECK ((nickname ~ '^[0-9A-Za-z가-힣_ ]+$'::text)),
  constraint profiles_nickname_len CHECK (((char_length(nickname) >= 2) AND (char_length(nickname) <= 12))),
  constraint profiles_title_len CHECK (((title IS NULL) OR (char_length(title) <= 40)))
);

create table if not exists public.ranked_recovery_eligibility (
  incident_key text not null,
  user_id uuid not null,
  failure_count integer not null,
  first_failed_at timestamp with time zone,
  last_failed_at timestamp with time zone,
  claimed_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  constraint ranked_recovery_eligibility_pkey PRIMARY KEY (incident_key, user_id),
  constraint ranked_recovery_eligibility_failure_count_check CHECK ((failure_count > 0))
);

-- Unverified recovery evidence only. Never used directly as official ranked leaderboard authority.
create table if not exists public.ranked_recovery_records (
  id uuid default gen_random_uuid() not null,
  incident_key text,
  user_id uuid,
  visitor_id uuid,
  session_id uuid,
  record_kind text not null,
  client_snapshot_id uuid,
  score integer,
  best_contract text,
  local_plays integer,
  reason text,
  ruleset_version text,
  client_version text,
  validation_status text default 'recovered_unverified'::text not null,
  source text default 'client_recovery'::text not null,
  payload jsonb default '{}'::jsonb not null,
  created_at timestamp with time zone default now() not null,
  constraint ranked_recovery_records_pkey PRIMARY KEY (id),
  constraint ranked_recovery_records_local_plays_check CHECK (((local_plays IS NULL) OR (local_plays >= 0))),
  constraint ranked_recovery_records_record_kind_check CHECK ((record_kind = ANY (ARRAY['incident_summary'::text, 'full_snapshot'::text]))),
  constraint ranked_recovery_records_score_check CHECK (((score IS NULL) OR ((score >= 0) AND (score <= 4000)))),
  constraint ranked_recovery_records_validation_status_check CHECK ((validation_status = ANY (ARRAY['recovered_unverified'::text, 'reviewed'::text, 'discarded'::text])))
);

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
  ascension_bonus integer default 0 not null,
  constraint ranked_runs_pkey PRIMARY KEY (id),
  constraint ranked_runs_run_id_key UNIQUE (run_id),
  constraint ranked_runs_anticheat_counts_check CHECK (((normal_hits >= 0) AND (speedy_hits >= 0) AND ((dragon_calls >= 0) AND (dragon_calls <= 2)) AND (moon_bonus_hits >= 0) AND (flight_hits >= 0) AND (input_count >= 0) AND (reaction_sample_count >= 0) AND (ultra_fast_reaction_count >= 0) AND (ultra_fast_reaction_count <= reaction_sample_count))),
  constraint ranked_runs_ascension_award_plausible CHECK (((validation_status <> 'accepted'::text) OR (ruleset_version <> 'secret-2.2-r1'::text) OR ((tier1_ground_award + tier2_ground_award) <= ((((normal_hits + (speedy_hits * 2)) + (gold_hits * 3)) + (indeoki_hits * 5)) + combo_bonus)))),
  constraint ranked_runs_ascension_bonus_exact CHECK (((validation_status <> 'accepted'::text) OR (ruleset_version <> 'secret-2.2-r1'::text) OR (ascension_bonus = ((tier1_ground_award / 5) + (tier2_ground_award / 2))))),
  constraint ranked_runs_combo_bonus_plausible CHECK (((validation_status <> 'accepted'::text) OR (ruleset_version <> 'secret-2.2-r1'::text) OR (combo_bonus <= (((((normal_hits + (speedy_hits * 2)) + (gold_hits * 3)) + (indeoki_hits * 5)) + (moon_bonus_hits * 2)) + flight_base_points)))),
  constraint ranked_runs_completed_calls_check CHECK (((completed_calls >= 0) AND (completed_calls <= 2))),
  constraint ranked_runs_flight_ledger_bounds CHECK (((validation_status <> 'accepted'::text) OR (ruleset_version <> 'secret-2.2-r1'::text) OR ((flight_hits = 0) AND (flight_base_points = 0)) OR ((flight_hits > 0) AND ((flight_base_points >= flight_hits) AND (flight_base_points <= (flight_hits * 5)))))),
  constraint ranked_runs_ledger_nonnegative CHECK (((combo_bonus >= 0) AND (flight_base_points >= 0) AND (tier1_hits >= 0) AND (tier2_hits >= 0) AND (tier1_ground_award >= 0) AND (tier2_ground_award >= 0) AND (ascension_bonus >= 0))),
  constraint ranked_runs_nonnegative CHECK (((score >= 0) AND (max_combo >= 0) AND (annyongi_hits >= 0) AND (indeoki_hits >= 0) AND (gold_hits >= 0) AND (total_hits >= 0) AND (dragon_bursts >= 0) AND (duration_ms >= 0))),
  constraint ranked_runs_run_type_check CHECK ((run_type = ANY (ARRAY['ranked'::text, 'qa'::text]))),
  constraint ranked_runs_stage CHECK ((stage_key = 'secret'::text)),
  constraint ranked_runs_tier1_award_bounds CHECK (((validation_status <> 'accepted'::text) OR (ruleset_version <> 'secret-2.2-r1'::text) OR ((tier1_hits = 0) AND (tier1_ground_award = 0)) OR ((tier1_hits > 0) AND ((tier1_ground_award >= tier1_hits) AND (tier1_ground_award <= (tier1_hits * 10)))))),
  constraint ranked_runs_tier2_award_bounds CHECK (((validation_status <> 'accepted'::text) OR (ruleset_version <> 'secret-2.2-r1'::text) OR ((tier2_hits = 0) AND (tier2_ground_award = 0)) OR ((tier2_hits > 0) AND ((tier2_ground_award >= tier2_hits) AND (tier2_ground_award <= (tier2_hits * 10)))))),
  constraint ranked_runs_tier_hits_within_total CHECK (((validation_status <> 'accepted'::text) OR (ruleset_version <> 'secret-2.2-r1'::text) OR ((tier1_hits + tier2_hits) <= total_hits))),
  constraint ranked_runs_validation CHECK ((validation_status = ANY (ARRAY['accepted'::text, 'rejected'::text])))
);

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
  expired_at timestamp with time zone,
  constraint ranked_sessions_pkey PRIMARY KEY (run_id),
  constraint ranked_sessions_run_type_check CHECK ((run_type = ANY (ARRAY['ranked'::text, 'qa'::text]))),
  constraint ranked_sessions_stage CHECK ((stage_key = 'secret'::text)),
  constraint ranked_sessions_status CHECK ((status = ANY (ARRAY['started'::text, 'submitted'::text, 'accepted'::text, 'rejected'::text, 'abandoned'::text, 'expired'::text])))
);

-- Private derived awards: Classic records, accepted ranked runs, verified Inha mail ownership, and frozen Classic seasonal placements.
create table if not exists public.user_achievements (
  user_id uuid not null,
  achievement_key text not null,
  earned_at timestamp with time zone not null,
  awarded_at timestamp with time zone default now() not null,
  condition_version smallint default 1 not null,
  evidence_source text not null,
  constraint user_achievements_pkey PRIMARY KEY (user_id, achievement_key),
  constraint user_achievements_achievement_key_check CHECK (((achievement_key = ANY (ARRAY['classic_recorded_v1'::text, 'classic_ranked_accepted_v1'::text, 'inha_verified_v1'::text])) OR (achievement_key ~ '^classic_inha_duck_s1_rank_([1-9]|10)_v1$'::text))),
  constraint user_achievements_condition_version_check CHECK ((condition_version = 1)),
  constraint user_achievements_evidence_source_check CHECK ((((achievement_key = 'classic_recorded_v1'::text) AND (evidence_source = 'classic_record'::text)) OR ((achievement_key = 'classic_ranked_accepted_v1'::text) AND (evidence_source = 'classic_ranked_accepted'::text)) OR ((achievement_key = 'inha_verified_v1'::text) AND (evidence_source = 'inha_mail_verified'::text)) OR ((achievement_key ~ '^classic_inha_duck_s1_rank_([1-9]|10)_v1$'::text) AND (evidence_source = 'classic_event_final_rank'::text))))
);

-- ---- indexes ----
create unique index if not exists world_activity_attempts_one_active_source ON private.world_activity_attempts USING btree (user_id, activity_id, source_ref) WHERE (status = ANY (ARRAY['CREATED'::text, 'ACTIVE'::text]));
create index if not exists world_activity_attempts_user_created_idx ON private.world_activity_attempts USING btree (user_id, created_at DESC);
create index if not exists world_activity_settlements_user_idx ON private.world_activity_settlements USING btree (user_id, settled_at DESC);
create index if not exists world_collection_discovery_events_user_created_idx ON private.world_collection_discovery_events USING btree (user_id, discovered_at DESC);
create index if not exists world_creature_activity_creature_idx ON private.world_creature_activity_events USING btree (creature_id, occurred_at DESC) WHERE (creature_id IS NOT NULL);
create index if not exists world_creature_observation_user_idx ON private.world_creature_observation_events USING btree (user_id, observed_at DESC);
create index if not exists world_fishing_user_idx ON private.world_fishing_attempt_snapshots USING btree (user_id);
create index if not exists world_item_grants_user_idx ON private.world_item_grants USING btree (user_id, created_at DESC);
create index if not exists world_life_skill_xp_transactions_user_created_idx ON private.world_life_skill_xp_transactions USING btree (user_id, created_at DESC);
create index if not exists world_life_sp_transactions_user_created_idx ON private.world_life_sp_transactions USING btree (user_id, created_at DESC);
create index if not exists world_life_sp_transactions_user_skill_idx ON private.world_life_sp_transactions USING btree (user_id, skill_id);
create index if not exists world_life_tree_resets_user_skill_idx ON private.world_life_tree_resets USING btree (user_id, skill_id, epoch DESC);
create index if not exists world_player_collection_discoveries_user_updated_idx ON private.world_player_collection_discoveries USING btree (user_id, updated_at DESC);
create index if not exists world_player_creatures_user_idx ON private.world_player_creatures USING btree (user_id, acquired_at);
create index if not exists player_bests_best_run_idx ON public.player_bests USING btree (best_run_id);
create index if not exists player_bests_score_idx ON public.player_bests USING btree (stage_key, best_score DESC, achieved_at);
create index if not exists profiles_department_idx ON public.profiles USING btree (department_id);
create index if not exists ranked_recovery_records_user_created_idx ON public.ranked_recovery_records USING btree (user_id, created_at DESC);
create unique index if not exists ranked_recovery_snapshot_once_idx ON public.ranked_recovery_records USING btree (client_snapshot_id) WHERE ((record_kind = 'full_snapshot'::text) AND (client_snapshot_id IS NOT NULL));
create unique index if not exists ranked_recovery_summary_once_idx ON public.ranked_recovery_records USING btree (incident_key, user_id) WHERE (record_kind = 'incident_summary'::text);
create index if not exists ranked_runs_user_created_idx ON public.ranked_runs USING btree (user_id, created_at DESC);
create index if not exists ranked_sessions_user_started_idx ON public.ranked_sessions USING btree (user_id, started_at DESC);

-- ===========================================================================
-- Functions. Bodies are the originals' final definitions; the only edits are the
-- ones listed in the header (identity source, SERVER_ONLY role check, get_my_rank_v3
-- parameter, claim_inha_mail_badge identity source).
-- ===========================================================================
set check_function_bodies = false;

create or replace function private.world_activity_account_ok_v1(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
  -- Guest-open (2026-11-12): the session existing is the whole check. The original's
  -- profiles join and is_banned test are dropped; ranked runs keep their own profile check.
  select p_user is not null and exists (
    select 1
      from public.sessions s
     where s.id = p_user::text
  );
$fn$;

create or replace function private.world_activity_attempt_guard_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $fn$
begin
  if old.status in ('SUCCEEDED','FAILED','CANCELLED','EXPIRED') then
    raise exception 'ACTIVITY_TERMINAL_IMMUTABLE' using errcode = '42501';
  end if;

  if (new.attempt_id, new.user_id, new.activity_id, new.source_ref, new.client_attempt_key,
      new.definition_version, new.resolver_version, new.created_at, new.expires_at)
     is distinct from
     (old.attempt_id, old.user_id, old.activity_id, old.source_ref, old.client_attempt_key,
      old.definition_version, old.resolver_version, old.created_at, old.expires_at) then
    raise exception 'ACTIVITY_IDENTITY_IMMUTABLE' using errcode = '42501';
  end if;

  if old.status = 'CREATED' and new.status = 'ACTIVE' then
    if new.activated_at is null or new.finalized_at is not null
       or new.outcome_type is not null or new.result_ref is not null then
      raise exception 'ACTIVITY_TRANSITION_INVALID' using errcode = '23514';
    end if;
    return new;
  end if;

  if old.status = 'ACTIVE' and new.status in ('SUCCEEDED','FAILED','CANCELLED','EXPIRED') then
    return new;
  end if;

  raise exception 'ACTIVITY_TRANSITION_INVALID' using errcode = '23514';
end;
$fn$;

create or replace function private.world_activity_attempt_json_v1(p_attempt private.world_activity_attempts)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $fn$
  select jsonb_build_object(
    'attemptId', p_attempt.attempt_id,
    'userId', p_attempt.user_id,
    'activityId', p_attempt.activity_id,
    'sourceRef', p_attempt.source_ref,
    'clientAttemptKey', p_attempt.client_attempt_key,
    'status', p_attempt.status,
    'outcomeType', p_attempt.outcome_type,
    'resultRef', p_attempt.result_ref,
    'definitionVersion', p_attempt.definition_version,
    'resolverVersion', p_attempt.resolver_version,
    'createdAt', p_attempt.created_at,
    'activatedAt', p_attempt.activated_at,
    'finalizedAt', p_attempt.finalized_at,
    'expiresAt', p_attempt.expires_at
  );
$fn$;

create or replace function private.world_activity_finalize_v1(p_user uuid, p_attempt_id uuid, p_terminal_status text, p_outcome_type text, p_result_ref text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare
  v_attempt private.world_activity_attempts%rowtype;
begin
  if p_attempt_id is null then
    raise exception 'INVALID_ATTEMPT_ID' using errcode = '22023';
  end if;
  if p_terminal_status not in ('SUCCEEDED','FAILED','CANCELLED','EXPIRED') then
    raise exception 'INVALID_TERMINAL_STATUS' using errcode = '22023';
  end if;
  if p_outcome_type is null or p_outcome_type !~ '^[A-Z][A-Z0-9_]{0,63}$' then
    raise exception 'INVALID_OUTCOME_TYPE' using errcode = '22023';
  end if;
  if p_terminal_status = 'SUCCEEDED' then
    if p_result_ref is null
       or p_result_ref !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$' then
      raise exception 'RESULT_REF_REQUIRED' using errcode = '22023';
    end if;
  elsif p_result_ref is not null then
    raise exception 'RESULT_REF_FORBIDDEN' using errcode = '22023';
  end if;
  if not private.world_activity_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('world_activity:' || p_user::text, 0));

  select * into v_attempt
    from private.world_activity_attempts a
   where a.attempt_id = p_attempt_id
     and a.user_id = p_user
   for update;
  if not found then
    raise exception 'ATTEMPT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_attempt.status in ('SUCCEEDED','FAILED','CANCELLED','EXPIRED') then
    if (v_attempt.status, v_attempt.outcome_type, v_attempt.result_ref)
       is distinct from (p_terminal_status, p_outcome_type, p_result_ref) then
      raise exception 'OUTCOME_CONFLICT' using errcode = '23505';
    end if;
    return jsonb_build_object(
      'status', 'ALREADY_PROCESSED',
      'attempt', private.world_activity_attempt_json_v1(v_attempt)
    );
  end if;

  if v_attempt.status <> 'ACTIVE' then
    raise exception 'INVALID_ATTEMPT_STATE' using errcode = 'P0001';
  end if;

  if v_attempt.expires_at is not null and v_attempt.expires_at <= now() then
    update private.world_activity_attempts a
       set status = 'EXPIRED',
           outcome_type = 'EXPIRED',
           finalized_at = now()
     where a.attempt_id = p_attempt_id
    returning * into v_attempt;
    return jsonb_build_object(
      'status', 'STALE_ATTEMPT',
      'attempt', private.world_activity_attempt_json_v1(v_attempt)
    );
  end if;

  update private.world_activity_attempts a
     set status = p_terminal_status,
         outcome_type = p_outcome_type,
         result_ref = p_result_ref,
         finalized_at = now()
   where a.attempt_id = p_attempt_id
  returning * into v_attempt;

  return jsonb_build_object(
    'status', 'SUCCESS',
    'attempt', private.world_activity_attempt_json_v1(v_attempt)
  );
end;
$fn$;

create or replace function private.world_activity_settle_v1(p_user uuid, p_attempt_id uuid, p_plan jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare
  v_attempt private.world_activity_attempts%rowtype;
  v_existing private.world_activity_settlements%rowtype;
  v_entry jsonb;
  v_key text;
  v_child jsonb;
  v_items jsonb := '[]'::jsonb;
  v_discoveries jsonb := '[]'::jsonb;
  v_xp jsonb := '[]'::jsonb;
  v_receipt jsonb;
begin
  if p_attempt_id is null then
    raise exception 'INVALID_ATTEMPT_ID' using errcode = '22023';
  end if;
  perform private.world_activity_settlement_plan_validate_v1(p_plan);
  if private.world_activity_account_ok_v1(p_user) is not true then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('world_activity:' || p_user::text,0));

  select * into v_attempt
    from private.world_activity_attempts a
   where a.attempt_id = p_attempt_id
     and a.user_id = p_user
     for share;
  if not found then
    raise exception 'ATTEMPT_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into v_existing
    from private.world_activity_settlements s
   where s.attempt_id = p_attempt_id;
  if found then
    if v_existing.plan is distinct from p_plan then
      raise exception 'SETTLEMENT_PLAN_CONFLICT' using errcode = '23505';
    end if;
    return jsonb_build_object('status','ALREADY_PROCESSED','receipt',v_existing.receipt);
  end if;

  if v_attempt.status <> 'SUCCEEDED' then
    raise exception 'ACTIVITY_NOT_SUCCEEDED' using errcode = 'P0001';
  end if;
  if v_attempt.result_ref is null or v_attempt.finalized_at is null then
    raise exception 'ACTIVITY_SUCCESS_PROVENANCE_INVALID' using errcode = 'P0001';
  end if;

  for v_entry in select e from jsonb_array_elements(p_plan->'items') e loop
    v_key := 'activity_settle:' || p_attempt_id::text || '/item/' || (v_entry->>'itemId');
    v_child := private.world_inventory_grant_v1(
      p_user,v_entry->>'itemId',(v_entry->>'quantity')::integer,'ACTIVITY',
      v_attempt.result_ref,v_key,null,
      jsonb_build_object('activityAttemptId',p_attempt_id,'activityId',v_attempt.activity_id));
    if v_child->>'originalStatus' is distinct from 'GRANTED' then
      raise exception 'OUTPUT_UNAVAILABLE' using errcode = 'P0001';
    end if;
    v_items := v_items || jsonb_build_array(v_child);
  end loop;

  for v_entry in select e from jsonb_array_elements(p_plan->'discoveries') e loop
    v_key := 'activity_settle:' || p_attempt_id::text || '/discovery/' || (v_entry->>'entryId');
    v_child := private.world_collection_discover_v1(
      p_user,v_entry->>'entryId','ACTIVITY',v_attempt.activity_id,v_attempt.result_ref,v_key,null);
    v_discoveries := v_discoveries || jsonb_build_array(v_child);
  end loop;

  for v_entry in select e from jsonb_array_elements(p_plan->'lifeXp') e loop
    v_key := 'activity_settle:' || p_attempt_id::text || '/xp/' || (v_entry->>'skillId');
    v_child := private.world_life_skill_xp_apply_v1(
      p_user,v_entry->>'skillId',(v_entry->>'amount')::bigint,'activity',v_attempt.result_ref,v_key);
    v_xp := v_xp || jsonb_build_array(v_child);
  end loop;

  v_receipt := jsonb_build_object(
    'attemptId',p_attempt_id,
    'activityId',v_attempt.activity_id,
    'resultRef',v_attempt.result_ref,
    'items',v_items,
    'discoveries',v_discoveries,
    'lifeXp',v_xp);

  insert into private.world_activity_settlements(
    attempt_id,user_id,activity_id,result_ref,plan,receipt)
  values (
    p_attempt_id,p_user,v_attempt.activity_id,v_attempt.result_ref,p_plan,v_receipt);

  return jsonb_build_object('status','SETTLED','receipt',v_receipt);
end;
$fn$;

create or replace function private.world_activity_settlement_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $fn$
begin
  -- Account deletion cascades remove the account's whole history; nothing else may delete a receipt.
  if tg_op = 'DELETE' and not exists (select 1 from public.sessions s where s.id = old.user_id::text) then
    return old;
  end if;
  raise exception 'ACTIVITY_SETTLEMENT_APPEND_ONLY' using errcode = '42501';
end;
$fn$;

create or replace function private.world_activity_settlement_plan_validate_v1(p_plan jsonb)
 RETURNS void
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $fn$
declare
  v_entry jsonb;
begin
  if p_plan is null or jsonb_typeof(p_plan) <> 'object'
     or (select array_agg(k order by k) from jsonb_object_keys(p_plan) k)
        is distinct from array['discoveries','items','lifeXp']
     or jsonb_typeof(p_plan->'items') <> 'array'
     or jsonb_typeof(p_plan->'discoveries') <> 'array'
     or jsonb_typeof(p_plan->'lifeXp') <> 'array'
     or jsonb_array_length(p_plan->'items') > 8
     or jsonb_array_length(p_plan->'discoveries') > 8
     or jsonb_array_length(p_plan->'lifeXp') > 8 then
    raise exception 'SETTLEMENT_PLAN_INVALID' using errcode = '22023';
  end if;

  for v_entry in select e from jsonb_array_elements(p_plan->'items') e loop
    if jsonb_typeof(v_entry) <> 'object'
       or (select array_agg(k order by k) from jsonb_object_keys(v_entry) k)
          is distinct from array['itemId','quantity']
       or jsonb_typeof(v_entry->'itemId') <> 'string'
       or v_entry->>'itemId' !~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,4}$'
       or jsonb_typeof(v_entry->'quantity') <> 'number'
       or (v_entry->>'quantity')::numeric <> trunc((v_entry->>'quantity')::numeric)
       or (v_entry->>'quantity')::numeric not between 1 and 999 then
      raise exception 'SETTLEMENT_PLAN_INVALID' using errcode = '22023';
    end if;
  end loop;
  for v_entry in select e from jsonb_array_elements(p_plan->'discoveries') e loop
    if jsonb_typeof(v_entry) <> 'object'
       or (select array_agg(k order by k) from jsonb_object_keys(v_entry) k)
          is distinct from array['entryId']
       or jsonb_typeof(v_entry->'entryId') <> 'string'
       or v_entry->>'entryId' !~ '^collection\.[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,4}$' then
      raise exception 'SETTLEMENT_PLAN_INVALID' using errcode = '22023';
    end if;
  end loop;
  for v_entry in select e from jsonb_array_elements(p_plan->'lifeXp') e loop
    if jsonb_typeof(v_entry) <> 'object'
       or (select array_agg(k order by k) from jsonb_object_keys(v_entry) k)
          is distinct from array['amount','skillId']
       or jsonb_typeof(v_entry->'skillId') <> 'string'
       or v_entry->>'skillId' !~ '^life\.[a-z][a-z0-9_]*$'
       or jsonb_typeof(v_entry->'amount') <> 'number'
       or (v_entry->>'amount')::numeric <> trunc((v_entry->>'amount')::numeric)
       or (v_entry->>'amount')::numeric not between 1 and 1000000 then
      raise exception 'SETTLEMENT_PLAN_INVALID' using errcode = '22023';
    end if;
  end loop;

  if (select count(distinct e->>'itemId') from jsonb_array_elements(p_plan->'items') e)
       <> jsonb_array_length(p_plan->'items')
     or (select count(distinct e->>'entryId') from jsonb_array_elements(p_plan->'discoveries') e)
       <> jsonb_array_length(p_plan->'discoveries')
     or (select count(distinct e->>'skillId') from jsonb_array_elements(p_plan->'lifeXp') e)
       <> jsonb_array_length(p_plan->'lifeXp') then
    raise exception 'SETTLEMENT_PLAN_INVALID' using errcode = '22023';
  end if;
end;
$fn$;

create or replace function private.world_activity_start_v1(p_user uuid, p_activity_id text, p_source_ref text, p_client_attempt_key uuid, p_definition_version integer, p_resolver_version integer, p_expires_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare
  v_attempt private.world_activity_attempts%rowtype;
begin
  perform private.world_activity_validate_identity_v1(
    p_activity_id, p_source_ref, p_definition_version, p_resolver_version);

  if p_client_attempt_key is null then
    raise exception 'INVALID_CLIENT_ATTEMPT_KEY' using errcode = '22023';
  end if;
  if p_expires_at is not null and p_expires_at <= now() then
    raise exception 'INVALID_EXPIRY' using errcode = '22023';
  end if;
  if not private.world_activity_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('world_activity:' || p_user::text, 0));

  select * into v_attempt
    from private.world_activity_attempts a
   where a.user_id = p_user
     and a.client_attempt_key = p_client_attempt_key;
  if found then
    if (v_attempt.activity_id, v_attempt.source_ref, v_attempt.definition_version, v_attempt.resolver_version)
       is distinct from (p_activity_id, p_source_ref, p_definition_version, p_resolver_version) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return jsonb_build_object(
      'status', 'ALREADY_PROCESSED',
      'attempt', private.world_activity_attempt_json_v1(v_attempt)
    );
  end if;

  -- Expire stale ACTIVE rows before enforcing one active attempt per semantic source.
  select * into v_attempt
    from private.world_activity_attempts a
   where a.user_id = p_user
     and a.activity_id = p_activity_id
     and a.source_ref = p_source_ref
     and a.status = 'ACTIVE'
   for update;
  if found and v_attempt.expires_at is not null and v_attempt.expires_at <= now() then
    update private.world_activity_attempts a
       set status = 'EXPIRED',
           outcome_type = 'EXPIRED',
           finalized_at = now()
     where a.attempt_id = v_attempt.attempt_id;
    v_attempt := null;
  end if;

  select * into v_attempt
    from private.world_activity_attempts a
   where a.user_id = p_user
     and a.activity_id = p_activity_id
     and a.source_ref = p_source_ref
     and a.status in ('CREATED','ACTIVE')
   limit 1;
  if found then
    return jsonb_build_object(
      'status', 'ATTEMPT_ALREADY_ACTIVE',
      'attempt', private.world_activity_attempt_json_v1(v_attempt)
    );
  end if;

  insert into private.world_activity_attempts(
    user_id, activity_id, source_ref, client_attempt_key, status,
    definition_version, resolver_version, activated_at, expires_at)
  values (
    p_user, p_activity_id, p_source_ref, p_client_attempt_key, 'ACTIVE',
    p_definition_version, p_resolver_version, now(), p_expires_at)
  returning * into v_attempt;

  return jsonb_build_object(
    'status', 'STARTED',
    'attempt', private.world_activity_attempt_json_v1(v_attempt)
  );
end;
$fn$;

create or replace function private.world_activity_validate_identity_v1(p_activity_id text, p_source_ref text, p_definition_version integer, p_resolver_version integer)
 RETURNS void
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $fn$
begin
  if p_activity_id is null
     or p_activity_id !~ '^activity\.[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,4}$'
     or char_length(p_activity_id) > 120 then
    raise exception 'INVALID_ACTIVITY_ID' using errcode = '22023';
  end if;
  if p_source_ref is null
     or p_source_ref !~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,5}$'
     or char_length(p_source_ref) > 160 then
    raise exception 'INVALID_SOURCE_REF' using errcode = '22023';
  end if;
  if p_definition_version is null or p_definition_version < 1
     or p_resolver_version is null or p_resolver_version < 1 then
    raise exception 'INVALID_RULE_VERSION' using errcode = '22023';
  end if;
end;
$fn$;

create or replace function private.world_collection_account_ok_v1(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
  -- Guest-open (2026-11-12): the session existing is the whole check. The original's
  -- profiles join and is_banned test are dropped; ranked runs keep their own profile check.
  select p_user is not null and exists (
    select 1
      from public.sessions s
     where s.id = p_user::text
  );
$fn$;

create or replace function private.world_collection_discover_v1(p_user uuid, p_entry_id text, p_source_type text, p_source_ref text, p_result_ref text, p_idempotency_key text, p_metadata jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare
  v_entry private.world_collection_entry_catalog%rowtype;
  v_event private.world_collection_discovery_events%rowtype;
  v_projection private.world_player_collection_discoveries%rowtype;
  v_now timestamptz := now();
  v_status text;
begin
  if p_entry_id is null
     or p_entry_id !~ '^collection\.[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,4}$'
     or char_length(p_entry_id) > 120 then
    raise exception 'INVALID_COLLECTION_ENTRY_ID' using errcode = '22023';
  end if;
  if p_source_type is null or p_source_type not in (
       'ACTIVITY','OWNERSHIP','QUEST','EVENT','COMBAT','RESEARCH','SYSTEM','ADMIN')
     or p_source_ref is null or char_length(p_source_ref) not between 1 and 200 then
    raise exception 'INVALID_DISCOVERY_SOURCE' using errcode = '22023';
  end if;
  if p_result_ref is not null and (
       p_result_ref !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'
       or char_length(p_result_ref) > 200) then
    raise exception 'INVALID_RESULT_REF' using errcode = '22023';
  end if;
  if p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$' then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = '22023';
  end if;
  if p_metadata is not null and (
       jsonb_typeof(p_metadata) <> 'object'
       or octet_length(p_metadata::text) > 2048) then
    raise exception 'INVALID_METADATA' using errcode = '22023';
  end if;
  if not private.world_collection_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('world_collection:' || p_user::text, 0));

  select * into v_event
    from private.world_collection_discovery_events e
   where e.idempotency_key = p_idempotency_key;
  if found then
    if (v_event.user_id, v_event.entry_id, v_event.source_type, v_event.source_ref,
        v_event.result_ref, v_event.metadata)
       is distinct from
       (p_user, p_entry_id, p_source_type, p_source_ref, p_result_ref, p_metadata) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return private.world_collection_discovery_result_v1(v_event, 'ALREADY_PROCESSED');
  end if;

  select * into v_entry
    from private.world_collection_entry_catalog c
   where c.entry_id = p_entry_id;
  if not found then
    raise exception 'COLLECTION_ENTRY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_entry.status <> 'ACTIVE' then
    raise exception 'COLLECTION_ENTRY_INACTIVE' using errcode = 'P0001';
  end if;
  if v_entry.persistence_mode <> 'SERVER_PERSISTED' then
    raise exception 'COLLECTION_WRITE_NOT_ALLOWED' using errcode = 'P0001';
  end if;

  insert into private.world_collection_discovery_events(
    user_id, entry_id, source_type, source_ref, result_ref,
    idempotency_key, definition_version, metadata, discovered_at)
  values (
    p_user, p_entry_id, p_source_type, p_source_ref, p_result_ref,
    p_idempotency_key, v_entry.definition_version, p_metadata, v_now)
  returning * into v_event;

  select * into v_projection
    from private.world_player_collection_discoveries d
   where d.user_id = p_user
     and d.entry_id = p_entry_id
   for update;

  if not found then
    insert into private.world_player_collection_discoveries(
      user_id, entry_id,
      first_discovered_at, last_discovered_at, discovery_count,
      first_source_type, first_source_ref, first_result_ref,
      version, updated_at)
    values (
      p_user, p_entry_id,
      v_now, v_now, 1,
      p_source_type, p_source_ref, p_result_ref,
      1, v_now)
    returning * into v_projection;
    v_status := 'DISCOVERED';
  else
    update private.world_player_collection_discoveries d
       set last_discovered_at = v_now,
           discovery_count = d.discovery_count + 1,
           version = d.version + 1,
           updated_at = v_now
     where d.user_id = p_user
       and d.entry_id = p_entry_id
    returning * into v_projection;
    v_status := 'REDISCOVERED';
  end if;

  return private.world_collection_discovery_result_v1(v_event, v_status);
exception when unique_violation then
  select * into v_event
    from private.world_collection_discovery_events e
   where e.idempotency_key = p_idempotency_key;
  if found
     and (v_event.user_id, v_event.entry_id, v_event.source_type, v_event.source_ref,
          v_event.result_ref, v_event.metadata)
         is not distinct from
         (p_user, p_entry_id, p_source_type, p_source_ref, p_result_ref, p_metadata) then
    return private.world_collection_discovery_result_v1(v_event, 'ALREADY_PROCESSED');
  end if;
  raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
end;
$fn$;

create or replace function private.world_collection_discovery_event_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $fn$
begin
  raise exception 'COLLECTION_DISCOVERY_EVENT_APPEND_ONLY' using errcode = '42501';
end;
$fn$;

create or replace function private.world_collection_discovery_result_v1(p_event private.world_collection_discovery_events, p_status text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
  select jsonb_build_object(
    'status', p_status,
    'discoveryEventId', p_event.discovery_event_id,
    'userId', p_event.user_id,
    'entryId', p_event.entry_id,
    'sourceType', p_event.source_type,
    'sourceRef', p_event.source_ref,
    'resultRef', p_event.result_ref,
    'idempotencyKey', p_event.idempotency_key,
    'definitionVersion', p_event.definition_version,
    'discoveredAt', p_event.discovered_at,
    'projection', private.world_collection_projection_json_v1(d)
  )
  from private.world_player_collection_discoveries d
  where d.user_id = p_event.user_id
    and d.entry_id = p_event.entry_id;
$fn$;

create or replace function private.world_collection_entry_snapshot_v1(p_user uuid, p_entry private.world_collection_entry_catalog)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare
  v_projection private.world_player_collection_discoveries%rowtype;
begin
  if p_entry.persistence_mode = 'SERVER_PERSISTED' then
    select * into v_projection
      from private.world_player_collection_discoveries d
     where d.user_id = p_user
       and d.entry_id = p_entry.entry_id;

    return jsonb_build_object(
      'entryId', p_entry.entry_id,
      'category', p_entry.category,
      'persistenceMode', p_entry.persistence_mode,
      'ownerDomain', null,
      'ownerRef', null,
      'catalogStatus', p_entry.status,
      'definitionVersion', p_entry.definition_version,
      'discoveryState', case when found then 'DISCOVERED' else 'UNKNOWN' end,
      'discovered', found,
      'firstDiscoveredAt', case when found then v_projection.first_discovered_at else null end,
      'lastDiscoveredAt', case when found then v_projection.last_discovered_at else null end,
      'discoveryCount', case when found then v_projection.discovery_count else 0 end,
      'version', case when found then v_projection.version else 0 end
    );
  end if;

  if p_entry.persistence_mode = 'DERIVED_FROM_OWNER' then
    return jsonb_build_object(
      'entryId', p_entry.entry_id,
      'category', p_entry.category,
      'persistenceMode', p_entry.persistence_mode,
      'ownerDomain', p_entry.owner_domain,
      'ownerRef', p_entry.owner_ref,
      'catalogStatus', p_entry.status,
      'definitionVersion', p_entry.definition_version,
      'discoveryState', 'OWNER_DERIVED',
      'discovered', null,
      'firstDiscoveredAt', null,
      'lastDiscoveredAt', null,
      'discoveryCount', null,
      'version', null
    );
  end if;

  return jsonb_build_object(
    'entryId', p_entry.entry_id,
    'category', p_entry.category,
    'persistenceMode', p_entry.persistence_mode,
    'ownerDomain', null,
    'ownerRef', null,
    'catalogStatus', p_entry.status,
    'definitionVersion', p_entry.definition_version,
    'discoveryState', 'NOT_PERSISTED',
    'discovered', null,
    'firstDiscoveredAt', null,
    'lastDiscoveredAt', null,
    'discoveryCount', null,
    'version', null
  );
end;
$fn$;

create or replace function private.world_collection_list_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
begin
  if not private.world_collection_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  return jsonb_build_object(
    'userId', p_user,
    'entries', coalesce((
      select jsonb_agg(
        private.world_collection_entry_snapshot_v1(p_user, c)
        order by c.entry_id
      )
      from private.world_collection_entry_catalog c
    ), '[]'::jsonb)
  );
end;
$fn$;

create or replace function private.world_collection_projection_guard_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $fn$
begin
  if (new.user_id, new.entry_id, new.first_discovered_at, new.first_source_type,
      new.first_source_ref, new.first_result_ref)
     is distinct from
     (old.user_id, old.entry_id, old.first_discovered_at, old.first_source_type,
      old.first_source_ref, old.first_result_ref) then
    raise exception 'COLLECTION_FIRST_PROVENANCE_IMMUTABLE' using errcode = '42501';
  end if;

  if new.discovery_count <> old.discovery_count + 1
     or new.version <> old.version + 1
     or new.last_discovered_at < old.last_discovered_at
     or new.updated_at < old.updated_at then
    raise exception 'COLLECTION_PROJECTION_INVALID' using errcode = '23514';
  end if;

  return new;
end;
$fn$;

create or replace function private.world_collection_projection_json_v1(p_projection private.world_player_collection_discoveries)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $fn$
  select jsonb_build_object(
    'entryId', p_projection.entry_id,
    'discovered', true,
    'discoveryState', 'DISCOVERED',
    'firstDiscoveredAt', p_projection.first_discovered_at,
    'lastDiscoveredAt', p_projection.last_discovered_at,
    'discoveryCount', p_projection.discovery_count,
    'firstSourceType', p_projection.first_source_type,
    'firstSourceRef', p_projection.first_source_ref,
    'firstResultRef', p_projection.first_result_ref,
    'version', p_projection.version,
    'updatedAt', p_projection.updated_at
  );
$fn$;

create or replace function private.world_creature_account_ok_v1(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
  -- Guest-open (2026-11-12): the session existing is the whole check. The original's
  -- profiles join and is_banned test are dropped; ranked runs keep their own profile check.
  select p_user is not null and exists (
    select 1
      from public.sessions s
     where s.id = p_user::text
  );
$fn$;

create or replace function private.world_creature_activity_accept_v1(p_user uuid, p_bridge_id text, p_source_ref text, p_source_result_ref text, p_source_event_key text, p_party_revision bigint, p_occurred_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare
  v_bridge private.world_creature_activity_bridge_catalog%rowtype;
  v_existing private.world_creature_activity_events%rowtype;
  v_party private.world_creature_party_history%rowtype;
  v_event private.world_creature_activity_events%rowtype;
  v_creature private.world_player_creatures%rowtype;
  v_last timestamptz;
  v_daily_count bigint;
  v_decision text := 'NOOP_NO_ACTIVE';
  v_xp bigint := 0;
  v_memory_tag text := null;
  v_before bigint;
  v_has_party boolean := false;
begin
  if p_bridge_id is null
     or p_bridge_id !~ '^creature\.bridge\.[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,3}$'
     or p_source_ref is null
     or p_source_ref !~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,6}$'
     or p_source_result_ref is null
     or p_source_result_ref !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'
     or p_source_event_key is null
     or p_source_event_key !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'
     or p_party_revision is null or p_party_revision < 0
     or p_occurred_at is null then
    raise exception 'INVALID_CREATURE_ACTIVITY_INGRESS' using errcode = '22023';
  end if;
  if not private.world_creature_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('world_creature_activity:' || p_user::text,0));

  select * into v_existing
    from private.world_creature_activity_events e
   where e.source_event_key = p_source_event_key;
  if found then
    if (v_existing.user_id,v_existing.bridge_id,v_existing.source_ref,
        v_existing.source_result_ref,v_existing.party_revision,v_existing.occurred_at)
       is distinct from
       (p_user,p_bridge_id,p_source_ref,p_source_result_ref,p_party_revision,p_occurred_at) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return jsonb_build_object(
      'status','ALREADY_PROCESSED',
      'event',private.world_creature_activity_event_json_v1(v_existing)
    );
  end if;

  select * into v_existing
    from private.world_creature_activity_events e
   where e.user_id = p_user
     and e.bridge_id = p_bridge_id
     and e.source_result_ref = p_source_result_ref;
  if found then
    return jsonb_build_object(
      'status','ALREADY_PROCESSED',
      'event',private.world_creature_activity_event_json_v1(v_existing)
    );
  end if;

  select * into v_bridge
    from private.world_creature_activity_bridge_catalog b
   where b.bridge_id = p_bridge_id;
  if not found then
    raise exception 'CREATURE_BRIDGE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_bridge.status <> 'ACTIVE' then
    raise exception 'CREATURE_BRIDGE_INACTIVE' using errcode = 'P0001';
  end if;

  select * into v_party
    from private.world_creature_party_history h
   where h.user_id = p_user
     and h.revision = p_party_revision;
  v_has_party := found;

  if v_has_party and v_party.active_creature_id is not null then
    if not private.world_creature_owned_by_v1(p_user,v_party.active_creature_id) then
      raise exception 'CREATURE_PARTY_HISTORY_INVALID' using errcode = 'P0001';
    end if;

    v_decision := 'ACCEPTED';

    if v_bridge.cooldown_seconds > 0 then
      select max(e.occurred_at) into v_last
        from private.world_creature_activity_events e
       where e.creature_id = v_party.active_creature_id
         and e.bridge_id = p_bridge_id
         and e.decision = 'ACCEPTED'
         and e.occurred_at <= p_occurred_at;
      if v_last is not null
         and p_occurred_at < v_last + make_interval(secs => v_bridge.cooldown_seconds) then
        v_decision := 'NOOP_COOLDOWN';
      end if;
    end if;

    if v_decision = 'ACCEPTED' and v_bridge.daily_cap is not null then
      select count(*) into v_daily_count
        from private.world_creature_activity_events e
       where e.creature_id = v_party.active_creature_id
         and e.bridge_id = p_bridge_id
         and e.decision = 'ACCEPTED'
         and e.occurred_at >= date_trunc('day',p_occurred_at)
         and e.occurred_at < date_trunc('day',p_occurred_at) + interval '1 day';
      if v_daily_count >= v_bridge.daily_cap then
        v_decision := 'NOOP_CAP';
      end if;
    end if;

    if v_decision = 'ACCEPTED' then
      v_xp := v_bridge.xp_amount;
      v_memory_tag := v_bridge.memory_tag;
    end if;
  end if;

  insert into private.world_creature_activity_events(
    user_id,bridge_id,source_ref,source_result_ref,source_event_key,
    party_revision,creature_id,decision,xp_awarded,memory_tag,occurred_at)
  values (
    p_user,p_bridge_id,p_source_ref,p_source_result_ref,p_source_event_key,
    p_party_revision,
    case when v_has_party then v_party.active_creature_id else null end,
    v_decision,v_xp,v_memory_tag,p_occurred_at)
  returning * into v_event;

  if v_decision = 'ACCEPTED' then
    select * into strict v_creature
      from private.world_player_creatures c
     where c.creature_id = v_party.active_creature_id
       and c.user_id = p_user
     for update;
    v_before := v_creature.total_xp;

    if v_xp > 0 then
      insert into private.world_creature_xp_transactions(
        user_id,creature_id,creature_activity_event_id,amount,xp_before,xp_after)
      values (
        p_user,v_creature.creature_id,v_event.creature_activity_event_id,
        v_xp,v_before,v_before+v_xp);

      update private.world_player_creatures c
         set total_xp = c.total_xp + v_xp,
             version = c.version + 1,
             updated_at = now()
       where c.creature_id = v_creature.creature_id;
    end if;

    insert into private.world_creature_memory_tags(
      creature_id,memory_tag,memory_count,first_remembered_at,last_remembered_at,version)
    values (
      v_creature.creature_id,v_memory_tag,1,p_occurred_at,p_occurred_at,1)
    on conflict (creature_id,memory_tag) do update
      set memory_count = private.world_creature_memory_tags.memory_count + 1,
          last_remembered_at = greatest(
            private.world_creature_memory_tags.last_remembered_at,
            excluded.last_remembered_at
          ),
          version = private.world_creature_memory_tags.version + 1;
  end if;

  return jsonb_build_object(
    'status','SUCCESS',
    'event',private.world_creature_activity_event_json_v1(v_event)
  );
end;
$fn$;

create or replace function private.world_creature_activity_event_json_v1(p_event private.world_creature_activity_events)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $fn$
  select jsonb_build_object(
    'creatureActivityEventId',p_event.creature_activity_event_id,
    'bridgeId',p_event.bridge_id,
    'sourceRef',p_event.source_ref,
    'sourceResultRef',p_event.source_result_ref,
    'partyRevision',p_event.party_revision,
    'creatureId',p_event.creature_id,
    'decision',p_event.decision,
    'xpAwarded',p_event.xp_awarded,
    'memoryTag',p_event.memory_tag,
    'occurredAt',p_event.occurred_at,
    'processedAt',p_event.processed_at
  );
$fn$;

create or replace function private.world_creature_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $fn$
begin
  if tg_op = 'DELETE' and not exists (select 1 from public.sessions s where s.id = old.user_id::text) then
    return old;
  end if;
  raise exception 'CREATURE_LEDGER_APPEND_ONLY' using errcode = '42501';
end;
$fn$;

create or replace function private.world_creature_instance_json_v1(p_creature private.world_player_creatures)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $fn$
  select jsonb_build_object(
    'creatureId',p_creature.creature_id,
    'speciesId',p_creature.species_id,
    'currentFormId',p_creature.current_form_id,
    'formRevision',p_creature.form_revision,
    'totalXp',p_creature.total_xp,
    'bondEntitled',p_creature.bond_entitled,
    'version',p_creature.version,
    'acquiredAt',p_creature.acquired_at,
    'updatedAt',p_creature.updated_at
  );
$fn$;

create or replace function private.world_creature_observe_v1(p_user uuid, p_species_id text, p_source_type text, p_source_ref text, p_result_ref text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare
  v_species private.world_creature_species_catalog%rowtype;
  v_existing private.world_creature_observation_events%rowtype;
  v_event private.world_creature_observation_events%rowtype;
begin
  if p_species_id is null
     or p_species_id !~ '^creature\.species\.[a-z][a-z0-9_]*$'
     or char_length(p_species_id) > 100 then
    raise exception 'INVALID_CREATURE_SPECIES_ID' using errcode = '22023';
  end if;
  if p_source_type not in ('WORLD','QUEST','ACTIVITY','COMBAT','RESEARCH','SYSTEM','ADMIN') then
    raise exception 'INVALID_OBSERVATION_SOURCE' using errcode = '22023';
  end if;
  if p_source_ref is null
     or p_source_ref !~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,6}$'
     or char_length(p_source_ref) > 160
     or p_result_ref is null
     or p_result_ref !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'
     or p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$' then
    raise exception 'INVALID_OBSERVATION_PROVENANCE' using errcode = '22023';
  end if;
  if not private.world_creature_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  select * into v_existing
    from private.world_creature_observation_events e
   where e.idempotency_key = p_idempotency_key;
  if found then
    if (v_existing.user_id,v_existing.species_id,v_existing.source_type,
        v_existing.source_ref,v_existing.result_ref)
       is distinct from
       (p_user,p_species_id,p_source_type,p_source_ref,p_result_ref) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return jsonb_build_object(
      'status','ALREADY_PROCESSED',
      'observationId',v_existing.observation_id
    );
  end if;

  select * into v_existing
    from private.world_creature_observation_events e
   where e.user_id = p_user
     and e.species_id = p_species_id
     and e.result_ref = p_result_ref;
  if found then
    return jsonb_build_object(
      'status','ALREADY_PROCESSED',
      'observationId',v_existing.observation_id
    );
  end if;

  select * into v_species
    from private.world_creature_species_catalog s
   where s.species_id = p_species_id;
  if not found then
    raise exception 'CREATURE_SPECIES_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_species.status <> 'ACTIVE' then
    raise exception 'CREATURE_SPECIES_INACTIVE' using errcode = 'P0001';
  end if;

  insert into private.world_creature_observation_events(
    user_id,species_id,source_type,source_ref,result_ref,idempotency_key)
  values (
    p_user,p_species_id,p_source_type,p_source_ref,p_result_ref,p_idempotency_key)
  returning * into v_event;

  return jsonb_build_object(
    'status','SUCCESS',
    'observationId',v_event.observation_id,
    'speciesId',v_event.species_id,
    'observedAt',v_event.observed_at
  );
end;
$fn$;

create or replace function private.world_creature_owned_by_v1(p_user uuid, p_creature uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
  select exists (
    select 1
      from private.world_player_creatures c
     where c.creature_id = p_creature
       and c.user_id = p_user
  );
$fn$;

create or replace function private.world_creature_party_snapshot_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare
  v_party private.world_creature_party_state%rowtype;
begin
  if not private.world_creature_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  select * into v_party
    from private.world_creature_party_state p
   where p.user_id = p_user;

  if not found then
    return jsonb_build_object(
      'revision',0,
      'activeCreatureId',null,
      'reserveCreatureIds','[]'::jsonb
    );
  end if;

  return jsonb_build_object(
    'revision',v_party.revision,
    'activeCreatureId',v_party.active_creature_id,
    'reserveCreatureIds',to_jsonb(array_remove(
      ARRAY[v_party.reserve1_creature_id,v_party.reserve2_creature_id],
      NULL::uuid
    ))
  );
end;
$fn$;

create or replace function private.world_duck_companion_status_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare
  v_rule private.world_creature_acquisition_rule_catalog%rowtype;
  v_claim private.world_creature_acquisition_claims%rowtype;
  v_observation_count integer := 0;
  v_state text;
  v_creature private.world_player_creatures%rowtype;
begin
  if not private.world_creature_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  select * into strict v_rule
    from private.world_creature_acquisition_rule_catalog r
   where r.rule_id = 'creature.acquisition.duck.inkyung_bond';

  select count(distinct e.source_ref)::integer
    into v_observation_count
    from private.world_creature_observation_events e
   where e.user_id = p_user
     and e.species_id = v_rule.species_id
     and exists (
       select 1
         from private.world_inkyung_duck_observation_subjects s
        where s.status = 'ACTIVE'
          and e.source_ref = 'world.inkyung.duck.' || s.duck_id
     );

  select * into v_claim
    from private.world_creature_acquisition_claims c
   where c.user_id = p_user
     and c.rule_id = v_rule.rule_id;

  if found then
    select * into strict v_creature
      from private.world_player_creatures c
     where c.creature_id = v_claim.creature_id
       and c.user_id = p_user;
    v_state := 'OWNED';
  elsif v_observation_count <= 0 then
    v_state := 'UNSEEN';
  elsif v_observation_count = 1 then
    v_state := 'SIGHTED';
  elsif v_observation_count < v_rule.required_observation_count then
    v_state := 'OBSERVED';
  else
    v_state := 'BOND_ELIGIBLE';
  end if;

  return jsonb_build_object(
    'ruleId',v_rule.rule_id,
    'speciesId',v_rule.species_id,
    'formId',v_rule.form_id,
    'state',v_state,
    'observationCount',v_observation_count,
    'requiredObservationCount',v_rule.required_observation_count,
    'remainingObservations',greatest(v_rule.required_observation_count-v_observation_count,0),
    'ownedCreature',case
      when v_state = 'OWNED' then private.world_creature_instance_json_v1(v_creature)
      else null end,
    'party',private.world_creature_party_snapshot_v1(p_user)
  );
end;
$fn$;

create or replace function private.world_fishing_apply_skill_effects_v1(p_policy jsonb, p_effects jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $fn$
declare
  v_steady integer;
  v_sense integer;
  v_response_bonus bigint;
  v_wait_reduction bigint;
  v_min bigint;
  v_max bigint;
  v_effective jsonb;
begin
  perform private.world_fishing_policy_validate_v1(p_policy);

  if p_effects is null or jsonb_typeof(p_effects) <> 'object'
     or p_effects->>'version' <> 'fishing.skill_effects.v1'
     or not p_effects ?& array['steadyHandsRank','fishSenseRank','responseWindowBonusMs','waitReductionMs']
     or jsonb_typeof(p_effects->'steadyHandsRank') <> 'number'
     or jsonb_typeof(p_effects->'fishSenseRank') <> 'number'
     or jsonb_typeof(p_effects->'responseWindowBonusMs') <> 'number'
     or jsonb_typeof(p_effects->'waitReductionMs') <> 'number' then
    raise exception 'FISHING_SKILL_EFFECT_INVALID' using errcode='22023';
  end if;

  v_steady := (p_effects->>'steadyHandsRank')::integer;
  v_sense := (p_effects->>'fishSenseRank')::integer;
  v_response_bonus := (p_effects->>'responseWindowBonusMs')::bigint;
  v_wait_reduction := (p_effects->>'waitReductionMs')::bigint;

  if v_steady not between 0 and 3 or v_sense not between 0 and 3
     or v_response_bonus <> v_steady * 250
     or v_wait_reduction <> v_sense * 250 then
    raise exception 'FISHING_SKILL_EFFECT_INVALID' using errcode='22023';
  end if;

  v_min := greatest(1::bigint,(p_policy->>'minWaitMs')::bigint-v_wait_reduction);
  v_max := greatest(v_min,(p_policy->>'maxWaitMs')::bigint-v_wait_reduction);
  v_effective := p_policy || jsonb_build_object(
    'minWaitMs',v_min,
    'maxWaitMs',v_max,
    'responseWindowMs',(p_policy->>'responseWindowMs')::bigint+v_response_bonus
  );

  perform private.world_fishing_policy_validate_v1(v_effective);
  return v_effective;
end;
$fn$;

create or replace function private.world_fishing_commit_v1(p_user uuid, p_attempt_id uuid, p_next jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare v_owner private.world_activity_attempts%rowtype; v_reply jsonb;
begin
  select * into strict v_owner from private.world_activity_attempts
    where attempt_id=p_attempt_id and user_id=p_user for update;
  if v_owner.status='EXPIRED' then
    p_next := private.world_fishing_finish_v1(p_next,'EXPIRED','ATTEMPT_EXPIRED',
      p_next->>'terminalAction',floor(extract(epoch from clock_timestamp())*1000)::bigint);
  elsif v_owner.status <> 'ACTIVE' then
    raise exception 'ACTIVITY_OUTCOME_CONFLICT' using errcode='23505';
  else
    -- Same transaction as the bridge decision: Creature growth only ever follows this outcome.
    v_reply := private.world_life_activity_finalize_with_creature_v1(p_user,p_attempt_id,p_next->>'status',
      p_next->'result'->>'reason',case when p_next->>'status'='SUCCEEDED' then p_next->'result'->>'resultRef' else null end);
    if v_reply->'activity'->'attempt'->>'status'='EXPIRED' then
      p_next := private.world_fishing_finish_v1(p_next,'EXPIRED','ATTEMPT_EXPIRED',
        p_next->>'terminalAction',floor(extract(epoch from clock_timestamp())*1000)::bigint);
    end if;
  end if;
  update private.world_fishing_attempt_snapshots set snapshot=p_next where attempt_id=p_attempt_id and user_id=p_user;
  -- Includes cancellation, failed/early HOOK and expiry reconciled by a read.
  delete from private.world_fishing_spot_leases where attempt_id=p_attempt_id and user_id=p_user;
  return p_next;
end;
$fn$;

create or replace function private.world_fishing_expire_v1(p_user uuid, p_snapshot jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare v_now bigint := floor(extract(epoch from clock_timestamp())*1000)::bigint;
begin
  if p_snapshot->>'status'='ACTIVE' and v_now >= (p_snapshot->>'expiresAtMs')::bigint then
    return private.world_fishing_commit_v1(p_user,(p_snapshot->>'attemptId')::uuid,
      private.world_fishing_finish_v1(p_snapshot,'EXPIRED','ATTEMPT_EXPIRED','EXPIRE',v_now));
  end if;
  return p_snapshot;
end;
$fn$;

create or replace function private.world_fishing_finish_v1(p_snapshot jsonb, p_status text, p_reason text, p_action text, p_now_ms bigint)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $fn$
  select p_snapshot || jsonb_build_object('status',p_status,'terminalAction',p_action,'result',
    jsonb_build_object(
      'resultRef','fishing_result:' || (p_snapshot->>'attemptId'),
      'activityId',p_snapshot->'activityId','attemptId',p_snapshot->'attemptId',
      'actorUserId',p_snapshot->'actorUserId','status',p_status,'reason',p_reason,
      'resolverVersion',p_snapshot->'resolverVersion','definitionVersion',p_snapshot->'definitionVersion',
      'outcomeSchemaVersion',p_snapshot->'outcomeSchemaVersion','policyVersion',p_snapshot->'policy'->'policyVersion',
      'resolvedAtMs',p_now_ms,'conditionSnapshot',jsonb_build_object(
        'sourceRef',p_snapshot->'sourceRef','startedAtMs',p_snapshot->'startedAtMs',
        'biteAtMs',p_snapshot->'biteAtMs','hookDeadlineMs',p_snapshot->'hookDeadlineMs',
        'expiresAtMs',p_snapshot->'expiresAtMs','weather','UNKNOWN'),
      'catch',case when p_status='SUCCEEDED' then jsonb_build_object(
        'speciesId','carp','itemId','material.fish_carp','quantity',1,
        'collectionEntryId','collection.fish.carp','skillId','life.fishing','lifeXp',p_snapshot->'policy'->'lifeXp')
      else 'null'::jsonb end));
$fn$;

create or replace function private.world_fishing_policy_validate_v1(p_policy jsonb)
 RETURNS void
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $fn$
declare v_field text; v_value numeric;
begin
  if p_policy is null or jsonb_typeof(p_policy) <> 'object'
     or not p_policy ?& array['policyVersion','minWaitMs','maxWaitMs','responseWindowMs','attemptTtlMs','lifeXp']
     or (select count(*) from jsonb_object_keys(p_policy)) <> 6
     or jsonb_typeof(p_policy->'policyVersion') <> 'string'
     or p_policy->>'policyVersion' !~ '^[a-z][a-z0-9_.]{0,79}$' then
    raise exception 'FISHING_POLICY_INVALID' using errcode='22023';
  end if;
  foreach v_field in array array['minWaitMs','maxWaitMs','responseWindowMs','attemptTtlMs','lifeXp'] loop
    if jsonb_typeof(p_policy->v_field) <> 'number' then
      raise exception 'FISHING_POLICY_INVALID' using errcode='22023';
    end if;
    v_value := (p_policy->>v_field)::numeric;
    if v_value <> trunc(v_value) or v_value > 9007199254740991
       or v_value < (case when v_field='lifeXp' then 0 else 1 end) then
      raise exception 'FISHING_POLICY_INVALID' using errcode='22023';
    end if;
  end loop;
  -- Settlement plans cap Life XP per output; a larger policy would strand successful catches.
  if (p_policy->>'maxWaitMs')::bigint < (p_policy->>'minWaitMs')::bigint
     or (p_policy->>'lifeXp')::bigint > 1000000
     or (p_policy->>'attemptTtlMs')::bigint <=
        (p_policy->>'maxWaitMs')::bigint + (p_policy->>'responseWindowMs')::bigint then
    raise exception 'FISHING_POLICY_INVALID' using errcode='22023';
  end if;
end;
$fn$;

create or replace function private.world_fishing_project_v1(p_snapshot jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $fn$
  select p_snapshot - array[
    'actorUserId','policy','skillEffects','resolverVersion','definitionVersion',
    'outcomeSchemaVersion','terminalAction'
  ];
$fn$;

create or replace function private.world_fishing_require_position_v1(p_user uuid, p_source_ref text)
 RETURNS private.world_fishing_positions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare v_position private.world_fishing_positions%rowtype; v_spot private.world_fishing_spots%rowtype;
begin
  select * into v_position from private.world_fishing_positions where user_id=p_user for share;
  if not found then raise exception 'FISHING_POSITION_UNAVAILABLE' using errcode='P0001'; end if;
  if v_position.observed_at > clock_timestamp()
     or v_position.observed_at <= clock_timestamp()-interval '5 seconds' then
    raise exception 'FISHING_POSITION_STALE' using errcode='P0001';
  end if;
  if v_position.space <> 'CAMPUS' or v_position.mode <> 'ON_FOOT' then
    raise exception 'FISHING_POSITION_INELIGIBLE' using errcode='P0001';
  end if;
  select * into strict v_spot from private.world_fishing_spots where source_ref=p_source_ref;
  if (v_position.x-v_spot.x)^2+(v_position.z-v_spot.z)^2 > v_spot.radius^2
     or v_position.y < v_spot.min_y or v_position.y > v_spot.max_y then
    raise exception 'FISHING_OUT_OF_RANGE' using errcode='P0001';
  end if;
  return v_position;
end;
$fn$;

create or replace function private.world_fishing_require_server_v1(p_user uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
begin
  -- (original: SERVER_ONLY unless auth.role() = service_role; here EXECUTE is granted to the Worker role only)
  if private.world_activity_account_ok_v1(p_user) is not true then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode='22023';
  end if;
end;
$fn$;

create or replace function private.world_fishing_resolve_v1(p_snapshot jsonb, p_action text, p_now bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $fn$
declare v_status text; v_reason text;
begin
  if p_now < (p_snapshot->>'startedAtMs')::bigint then
    raise exception 'INVALID_SERVER_TIME' using errcode='22023';
  end if;
  if p_now >= (p_snapshot->>'expiresAtMs')::bigint then
    v_status:='EXPIRED'; v_reason:='ATTEMPT_EXPIRED';
  elsif p_action='CANCEL' then v_status:='CANCELLED'; v_reason:='PLAYER_CANCELLED';
  elsif p_now < (p_snapshot->>'biteAtMs')::bigint then v_status:='FAILED'; v_reason:='PREMATURE_HOOK';
  elsif p_now >= (p_snapshot->>'hookDeadlineMs')::bigint then v_status:='FAILED'; v_reason:='MISSED_BITE';
  else v_status:='SUCCEEDED'; v_reason:='CAUGHT';
  end if;
  return private.world_fishing_finish_v1(p_snapshot,v_status,v_reason,p_action,p_now);
end;
$fn$;

create or replace function private.world_fishing_skill_effects_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare
  v_steady integer;
  v_sense integer;
begin
  if p_user is null or not private.world_life_skill_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode='22023';
  end if;

  v_steady := private.world_life_node_rank_v1(p_user,'life.node.fishing.steady_hands');
  v_sense := private.world_life_node_rank_v1(p_user,'life.node.fishing.fish_sense');

  if v_steady not between 0 and 3 or v_sense not between 0 and 3 then
    raise exception 'FISHING_SKILL_EFFECT_INVALID' using errcode='22023';
  end if;

  return jsonb_build_object(
    'version','fishing.skill_effects.v1',
    'steadyHandsRank',v_steady,
    'fishSenseRank',v_sense,
    'responseWindowBonusMs',v_steady * 250,
    'waitReductionMs',v_sense * 250
  );
end;
$fn$;

create or replace function private.world_fishing_snapshot_guard_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $fn$
begin
  if old.snapshot->>'status' <> 'ACTIVE' then
    raise exception 'FISHING_TERMINAL_IMMUTABLE' using errcode='42501';
  end if;
  if (new.attempt_id,new.user_id,new.snapshot - array['status','terminalAction','result'])
     is distinct from
     (old.attempt_id,old.user_id,old.snapshot - array['status','terminalAction','result'])
     or coalesce(new.snapshot->>'status','') not in ('SUCCEEDED','FAILED','CANCELLED','EXPIRED') then
    raise exception 'FISHING_SNAPSHOT_IMMUTABLE' using errcode='42501';
  end if;
  return new;
end;
$fn$;

create or replace function private.world_inkyung_duck_observe_v1(p_user uuid, p_duck_id text, p_result_ref text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare
  v_subject private.world_inkyung_duck_observation_subjects%rowtype;
  v_observation jsonb;
begin
  if p_duck_id is null
     or p_duck_id !~ '^inkyung_duck_[a-z0-9_]+$'
     or char_length(p_duck_id) > 80 then
    raise exception 'INVALID_INKYUNG_DUCK_ID' using errcode = '22023';
  end if;

  select * into v_subject
    from private.world_inkyung_duck_observation_subjects s
   where s.duck_id = p_duck_id;
  if not found or v_subject.status <> 'ACTIVE' then
    raise exception 'INKYUNG_DUCK_NOT_OBSERVABLE' using errcode = 'P0001';
  end if;

  v_observation := private.world_creature_observe_v1(
    p_user,
    'creature.species.duck',
    'WORLD',
    'world.inkyung.duck.' || p_duck_id,
    p_result_ref,
    p_idempotency_key
  );

  return jsonb_build_object(
    'status',v_observation->>'status',
    'duckId',p_duck_id,
    'observation',v_observation,
    'companion',private.world_duck_companion_status_v1(p_user)
  );
end;
$fn$;

create or replace function private.world_inventory_account_ok_v1(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
  -- Guest-open (2026-11-12): the session existing is the whole check. The original's
  -- profiles join and is_banned test are dropped; ranked runs keep their own profile check.
  select p_user is not null and exists (
    select 1
      from public.sessions s
     where s.id = p_user::text
  );
$fn$;

create or replace function private.world_inventory_grant_result_v1(p_grant private.world_item_grants, p_status text, p_acquired_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $fn$
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
$fn$;

create or replace function private.world_inventory_grant_v1(p_user uuid, p_item_id text, p_quantity integer, p_source_type text, p_source_ref text, p_idempotency_key text, p_event_id text, p_metadata jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
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
$fn$;

create or replace function private.world_item_grants_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $fn$
begin
  raise exception 'GRANT_LOG_APPEND_ONLY' using errcode = '42501';
end;
$fn$;

create or replace function private.world_life_activity_finalize_with_creature_v1(p_user uuid, p_attempt_id uuid, p_terminal_status text, p_outcome_type text, p_result_ref text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare
  v_activity jsonb;
  v_attempt private.world_activity_attempts%rowtype;
  v_mapping private.world_life_creature_bridge_catalog%rowtype;
  v_bridge private.world_creature_activity_bridge_catalog%rowtype;
  v_skill private.world_life_skill_catalog%rowtype;
  v_context private.world_life_creature_activity_contexts%rowtype;
  v_decision private.world_life_creature_bridge_decisions%rowtype;
  v_creature_event private.world_creature_activity_events%rowtype;
  v_creature jsonb;
  v_creature_event_id uuid;
  v_event_key text;
begin
  v_activity := private.world_activity_finalize_v1(
    p_user,p_attempt_id,p_terminal_status,p_outcome_type,p_result_ref);

  select * into strict v_attempt
    from private.world_activity_attempts a
   where a.attempt_id = p_attempt_id
     and a.user_id = p_user;

  select * into v_mapping
    from private.world_life_creature_bridge_catalog m
   where m.activity_id = v_attempt.activity_id;
  if not found then
    raise exception 'LIFE_CREATURE_ACTIVITY_NOT_MAPPED' using errcode = 'P0002';
  end if;

  if v_attempt.definition_version <> v_mapping.required_activity_definition_version then
    raise exception 'ACTIVITY_DEFINITION_VERSION_MISMATCH' using errcode = 'P0001';
  end if;

  select * into v_decision
    from private.world_life_creature_bridge_decisions d
   where d.attempt_id = p_attempt_id
     and d.user_id = p_user;
  if found then
    if v_decision.decision = 'FORWARDED' then
      select * into strict v_creature_event
        from private.world_creature_activity_events e
       where e.creature_activity_event_id = v_decision.creature_activity_event_id;
      return jsonb_build_object(
        'status','SUCCESS',
        'activity',v_activity,
        'creatureBridge',jsonb_build_object(
          'status','ALREADY_PROCESSED',
          'decision','FORWARDED',
          'event',private.world_creature_activity_event_json_v1(v_creature_event)
        )
      );
    end if;
    return jsonb_build_object(
      'status','SUCCESS',
      'activity',v_activity,
      'creatureBridge',jsonb_build_object(
        'status','ALREADY_PROCESSED',
        'decision',v_decision.decision
      )
    );
  end if;

  if v_attempt.status <> 'SUCCEEDED' then
    insert into private.world_life_creature_bridge_decisions(
      attempt_id,user_id,bridge_id,decision)
    values (
      p_attempt_id,p_user,v_mapping.bridge_id,'NOOP_ACTIVITY_NOT_SUCCEEDED');

    return jsonb_build_object(
      'status','SUCCESS',
      'activity',v_activity,
      'creatureBridge',jsonb_build_object(
        'status','NOOP_ACTIVITY_NOT_SUCCEEDED'
      )
    );
  end if;

  select * into v_context
    from private.world_life_creature_activity_contexts c
   where c.attempt_id = p_attempt_id
     and c.user_id = p_user;
  if not found then
    insert into private.world_life_creature_bridge_decisions(
      attempt_id,user_id,bridge_id,decision)
    values (
      p_attempt_id,p_user,v_mapping.bridge_id,'NOOP_NO_CONTEXT');

    return jsonb_build_object(
      'status','SUCCESS',
      'activity',v_activity,
      'creatureBridge',jsonb_build_object(
        'status','NOOP_NO_CONTEXT'
      )
    );
  end if;

  select * into strict v_skill
    from private.world_life_skill_catalog s
   where s.skill_id = v_mapping.life_skill_id;

  select * into strict v_bridge
    from private.world_creature_activity_bridge_catalog b
   where b.bridge_id = v_mapping.bridge_id;

  if v_skill.status <> 'ACTIVE' or v_bridge.status <> 'ACTIVE' then
    insert into private.world_life_creature_bridge_decisions(
      attempt_id,user_id,bridge_id,decision)
    values (
      p_attempt_id,p_user,v_mapping.bridge_id,'NOOP_INACTIVE');

    return jsonb_build_object(
      'status','SUCCESS',
      'activity',v_activity,
      'creatureBridge',jsonb_build_object(
        'status','NOOP_INACTIVE'
      )
    );
  end if;

  if v_attempt.result_ref is null or v_attempt.finalized_at is null then
    raise exception 'ACTIVITY_SUCCESS_PROVENANCE_INVALID' using errcode = 'P0001';
  end if;

  v_event_key := 'life-creature:' || v_attempt.attempt_id::text;

  v_creature := private.world_creature_activity_accept_v1(
    p_user,
    v_mapping.bridge_id,
    v_attempt.source_ref,
    v_attempt.result_ref,
    v_event_key,
    v_context.party_revision,
    v_attempt.finalized_at
  );

  v_creature_event_id := nullif(
    v_creature->'event'->>'creatureActivityEventId','')::uuid;
  if v_creature_event_id is null then
    raise exception 'CREATURE_BRIDGE_RESULT_INVALID' using errcode = 'P0001';
  end if;

  insert into private.world_life_creature_bridge_decisions(
    attempt_id,user_id,bridge_id,decision,creature_activity_event_id)
  values (
    p_attempt_id,p_user,v_mapping.bridge_id,'FORWARDED',v_creature_event_id);

  return jsonb_build_object(
    'status','SUCCESS',
    'activity',v_activity,
    'creatureBridge',jsonb_build_object(
      'status','FORWARDED',
      'result',v_creature
    )
  );
end;
$fn$;

create or replace function private.world_life_activity_start_with_creature_v1(p_user uuid, p_activity_id text, p_source_ref text, p_client_attempt_key uuid, p_definition_version integer, p_resolver_version integer, p_expires_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare
  v_mapping private.world_life_creature_bridge_catalog%rowtype;
  v_skill private.world_life_skill_catalog%rowtype;
  v_activity jsonb;
  v_attempt_id uuid;
  v_context jsonb;
begin
  select * into v_mapping
    from private.world_life_creature_bridge_catalog m
   where m.activity_id = p_activity_id;
  if not found then
    raise exception 'LIFE_CREATURE_ACTIVITY_NOT_MAPPED' using errcode = 'P0002';
  end if;

  select * into strict v_skill
    from private.world_life_skill_catalog s
   where s.skill_id = v_mapping.life_skill_id;
  if v_skill.status <> 'ACTIVE' then
    raise exception 'LIFE_SKILL_INACTIVE' using errcode = 'P0001';
  end if;

  if p_definition_version <> v_mapping.required_activity_definition_version then
    raise exception 'ACTIVITY_DEFINITION_VERSION_MISMATCH' using errcode = 'P0001';
  end if;

  v_activity := private.world_activity_start_v1(
    p_user,p_activity_id,p_source_ref,p_client_attempt_key,
    p_definition_version,p_resolver_version,p_expires_at);

  v_attempt_id := nullif(v_activity->'attempt'->>'attemptId','')::uuid;
  if v_attempt_id is null then
    raise exception 'ACTIVITY_START_RESULT_INVALID' using errcode = 'P0001';
  end if;

  v_context := private.world_life_creature_context_bind_v1(
    p_user,v_attempt_id);

  return jsonb_build_object(
    'status','SUCCESS',
    'activity',v_activity,
    'creatureContext',v_context
  );
end;
$fn$;

create or replace function private.world_life_creature_context_bind_v1(p_user uuid, p_attempt_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare
  v_attempt private.world_activity_attempts%rowtype;
  v_mapping private.world_life_creature_bridge_catalog%rowtype;
  v_context private.world_life_creature_activity_contexts%rowtype;
  v_party_revision bigint := 0;
begin
  if p_attempt_id is null then
    raise exception 'INVALID_ATTEMPT_ID' using errcode = '22023';
  end if;
  if not private.world_creature_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('world_life_creature_context:' || p_user::text,0));

  select * into v_context
    from private.world_life_creature_activity_contexts c
   where c.attempt_id = p_attempt_id;
  if found then
    if v_context.user_id <> p_user then
      raise exception 'CREATURE_CONTEXT_OWNER_CONFLICT' using errcode = '42501';
    end if;
    return jsonb_build_object(
      'status','ALREADY_PROCESSED',
      'context',private.world_life_creature_context_json_v1(v_context)
    );
  end if;

  select * into v_attempt
    from private.world_activity_attempts a
   where a.attempt_id = p_attempt_id
     and a.user_id = p_user;
  if not found then
    raise exception 'ATTEMPT_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into v_mapping
    from private.world_life_creature_bridge_catalog m
   where m.activity_id = v_attempt.activity_id;
  if not found then
    raise exception 'LIFE_CREATURE_ACTIVITY_NOT_MAPPED' using errcode = 'P0002';
  end if;

  if v_attempt.definition_version <> v_mapping.required_activity_definition_version then
    raise exception 'ACTIVITY_DEFINITION_VERSION_MISMATCH' using errcode = 'P0001';
  end if;

  if v_attempt.status not in ('CREATED','ACTIVE') then
    raise exception 'LIFE_CREATURE_CONTEXT_TOO_LATE' using errcode = 'P0001';
  end if;

  select p.revision into v_party_revision
    from private.world_creature_party_state p
   where p.user_id = p_user;
  v_party_revision := coalesce(v_party_revision,0);

  if v_party_revision > 0 and not exists (
    select 1
      from private.world_creature_party_history h
     where h.user_id = p_user
       and h.revision = v_party_revision
  ) then
    raise exception 'CREATURE_PARTY_HISTORY_INVALID' using errcode = 'P0001';
  end if;

  insert into private.world_life_creature_activity_contexts(
    attempt_id,user_id,activity_id,party_revision)
  values (
    v_attempt.attempt_id,p_user,v_attempt.activity_id,v_party_revision)
  returning * into v_context;

  return jsonb_build_object(
    'status','SUCCESS',
    'context',private.world_life_creature_context_json_v1(v_context)
  );
end;
$fn$;

create or replace function private.world_life_creature_context_json_v1(p_context private.world_life_creature_activity_contexts)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $fn$
  select jsonb_build_object(
    'attemptId',p_context.attempt_id,
    'userId',p_context.user_id,
    'activityId',p_context.activity_id,
    'partyRevision',p_context.party_revision,
    'boundAt',p_context.bound_at
  );
$fn$;

create or replace function private.world_life_node_rank_v1(p_user uuid, p_node_id text)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
  select coalesce(max(p.rank),0)::integer
    from private.world_player_life_nodes p
    join private.world_life_skill_tree_catalog n on n.node_id = p.node_id
   where p.user_id = p_user
     and p.node_id = p_node_id
     and p.epoch = private.world_life_tree_epoch_v1(p_user,n.skill_id);
$fn$;

create or replace function private.world_life_nodes_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $fn$
begin
  if tg_op = 'DELETE' and not exists (select 1 from public.sessions s where s.id = old.user_id::text) then
    return old;
  end if;
  raise exception 'LIFE_NODE_APPEND_ONLY' using errcode = '42501';
end;
$fn$;

create or replace function private.world_life_skill_account_ok_v1(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
  -- Guest-open (2026-11-12): the session existing is the whole check. The original's
  -- profiles join and is_banned test are dropped; ranked runs keep their own profile check.
  select p_user is not null and exists (
    select 1
      from public.sessions s
     where s.id = p_user::text
  );
$fn$;

create or replace function private.world_life_skill_level_for_xp_v1(p_curve_id text, p_total_xp bigint)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
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
$fn$;

create or replace function private.world_life_skill_snapshot_v1(p_user uuid, p_skill_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
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
$fn$;

create or replace function private.world_life_skill_threshold_immutable_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $fn$
begin
  raise exception 'LIFE_SKILL_CURVE_IMMUTABLE' using errcode = '42501';
end;
$fn$;

create or replace function private.world_life_skill_threshold_validate_insert_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $fn$
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
$fn$;

create or replace function private.world_life_skill_xp_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $fn$
begin
  raise exception 'LIFE_SKILL_XP_APPEND_ONLY' using errcode = '42501';
end;
$fn$;

create or replace function private.world_life_skill_xp_apply_v1(p_user uuid, p_skill_id text, p_amount bigint, p_source_type text, p_source_id text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare
  v_skill private.world_life_skill_catalog%rowtype;
  v_total bigint;
  v_before_level integer;
  v_after_level integer;
  v_tx private.world_life_skill_xp_transactions%rowtype;
begin
  if p_skill_id is null
     or p_skill_id !~ '^life\.[a-z][a-z0-9_]*$'
     or char_length(p_skill_id) > 80 then
    raise exception 'INVALID_LIFE_SKILL_ID' using errcode = '22023';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INVALID_AMOUNT' using errcode = '22023';
  end if;
  if p_source_type is null or p_source_type not in (
       'activity','crafting','research','farming','system','admin')
     or p_source_id is null or char_length(p_source_id) not between 1 and 200 then
    raise exception 'INVALID_SOURCE' using errcode = '22023';
  end if;
  if p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$' then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = '22023';
  end if;
  if not private.world_life_skill_account_ok_v1(p_user) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = '22023';
  end if;

  select * into v_skill
    from private.world_life_skill_catalog s
   where s.skill_id = p_skill_id;
  if not found then
    raise exception 'LIFE_SKILL_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- Exact replay wins over current availability. A response-loss retry must return the
  -- committed transaction even if the skill became disabled after that commit.
  select * into v_tx
    from private.world_life_skill_xp_transactions t
   where t.idempotency_key = p_idempotency_key;
  if found then
    if (v_tx.user_id,v_tx.skill_id,v_tx.amount,v_tx.source_type,v_tx.source_id)
       is distinct from
       (p_user,p_skill_id,p_amount,p_source_type,p_source_id) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return private.world_life_skill_xp_result_v1(v_tx,'ALREADY_PROCESSED');
  end if;

  if v_skill.status <> 'ACTIVE' then
    raise exception 'LIFE_SKILL_INACTIVE' using errcode = 'P0001';
  end if;

  perform private.world_life_skill_level_for_xp_v1(v_skill.curve_id,0);

  insert into private.world_player_life_skills(user_id,skill_id)
  values (p_user,p_skill_id)
  on conflict (user_id,skill_id) do nothing;

  select p.total_xp into strict v_total
    from private.world_player_life_skills p
   where p.user_id = p_user
     and p.skill_id = p_skill_id
   for update;

  if v_total > 9223372036854775807::bigint - p_amount then
    raise exception 'INVALID_AMOUNT' using errcode = '22023';
  end if;

  v_before_level := private.world_life_skill_level_for_xp_v1(v_skill.curve_id,v_total);
  v_after_level := private.world_life_skill_level_for_xp_v1(v_skill.curve_id,v_total+p_amount);

  begin
    insert into private.world_life_skill_xp_transactions(
      user_id,skill_id,amount,xp_before,xp_after,level_before,level_after,
      source_type,source_id,idempotency_key)
    values (
      p_user,p_skill_id,p_amount,v_total,v_total+p_amount,v_before_level,v_after_level,
      p_source_type,p_source_id,p_idempotency_key)
    returning * into v_tx;
  exception when unique_violation then
    select * into strict v_tx
      from private.world_life_skill_xp_transactions t
     where t.idempotency_key = p_idempotency_key;
    if (v_tx.user_id,v_tx.skill_id,v_tx.amount,v_tx.source_type,v_tx.source_id)
       is distinct from
       (p_user,p_skill_id,p_amount,p_source_type,p_source_id) then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505';
    end if;
    return private.world_life_skill_xp_result_v1(v_tx,'ALREADY_PROCESSED');
  end;

  update private.world_player_life_skills p
     set total_xp = v_tx.xp_after,
         version = p.version + 1,
         updated_at = now()
   where p.user_id = p_user
     and p.skill_id = p_skill_id;

  return private.world_life_skill_xp_result_v1(v_tx,'SUCCESS');
end;
$fn$;

create or replace function private.world_life_skill_xp_result_v1(p_tx private.world_life_skill_xp_transactions, p_status text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
  select jsonb_build_object(
    'status',p_status,
    'transactionId',p_tx.transaction_id,
    'userId',p_tx.user_id,
    'skillId',p_tx.skill_id,
    'amount',p_tx.amount,
    'xpBefore',p_tx.xp_before,
    'xpAfter',p_tx.xp_after,
    'levelBefore',p_tx.level_before,
    'levelAfter',p_tx.level_after,
    'leveledUp',p_tx.level_after > p_tx.level_before,
    'sourceType',p_tx.source_type,
    'sourceId',p_tx.source_id,
    'idempotencyKey',p_tx.idempotency_key,
    'createdAt',p_tx.created_at,
    'snapshot',private.world_life_skill_snapshot_v1(p_tx.user_id,p_tx.skill_id)
  );
$fn$;

create or replace function private.world_life_sp_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $fn$
begin
  if tg_op = 'DELETE' and not exists (select 1 from public.sessions s where s.id = old.user_id::text) then
    return old;
  end if;
  raise exception 'LIFE_SP_APPEND_ONLY' using errcode = '42501';
end;
$fn$;

create or replace function private.world_life_tree_epoch_v1(p_user uuid, p_skill_id text)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
  select coalesce(max(r.epoch),0)::integer
    from private.world_life_tree_resets r
   where r.user_id = p_user and r.skill_id = p_skill_id;
$fn$;

create or replace function private.world_life_tree_node_guard_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $fn$
begin
  if tg_op = 'DELETE'
     or (new.node_id,new.skill_id,new.sp_cost,new.required_life_level,new.required_skill_level,new.max_rank)
        is distinct from
        (old.node_id,old.skill_id,old.sp_cost,old.required_life_level,old.required_skill_level,old.max_rank) then
    raise exception 'LIFE_TREE_DEFINITION_IMMUTABLE' using errcode = '42501';
  end if;
  return new;
end;
$fn$;

create or replace function private.world_life_tree_resets_append_only_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $fn$
begin
  -- Account deletion cascades remove the account's whole history; nothing else may.
  if tg_op = 'DELETE' and not exists (select 1 from public.sessions s where s.id = old.user_id::text) then
    return old;
  end if;
  raise exception 'LIFE_TREE_RESET_APPEND_ONLY' using errcode = '42501';
end;
$fn$;

create or replace function public.claim_inha_mail_badge(p_primary_id uuid, p_school_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare
  v_email text;
  v_verified_at timestamptz := now();
begin
  if p_primary_id = p_school_id then
    raise exception 'A second mailbox is required';
  end if;
  -- original: auth.users row, is_anonymous = false, email_confirmed_at is not null.
  -- A guest session has no email, so only its existence can be checked.
  if not exists (
    select 1 from public.sessions s where s.id = p_primary_id::text
  ) then
    raise exception 'Primary account is not confirmed';
  end if;
  -- original: the school account's confirmed auth.users email. See
  -- private.inha_mail_verified_mailboxes: nothing writes it in Tier 3.
  select lower(m.email) into v_email
  from private.inha_mail_verified_mailboxes m
  where m.school_id = p_school_id
    and m.confirmed_at is not null and public.is_inha_mail(m.email);
  if v_email is null then
    raise exception 'School mailbox is not confirmed';
  end if;

  insert into public.inha_mail_badges(user_id,email,verified_at)
    values(p_primary_id,v_email,v_verified_at)
    on conflict (user_id) do update
      set email=excluded.email,verified_at=excluded.verified_at;

  insert into public.user_achievements(user_id,achievement_key,earned_at,evidence_source)
  select p_primary_id,'inha_verified_v1',v_verified_at,'inha_mail_verified'
  where exists (select 1 from public.profiles p where p.user_id=p_primary_id and p.is_banned=false)
  on conflict (user_id,achievement_key) do nothing;

  return true;
end;
$fn$;

create or replace function public.expire_ranked_sessions_v1()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare
  v_count integer;
begin
  update public.ranked_sessions
  set
    status='expired',
    expired_at=coalesce(expired_at,expires_at),
    finished_at=coalesce(finished_at,expires_at)
  where status in ('started','submitted')
    and expires_at <= now();

  get diagnostics v_count = row_count;
  return v_count;
end;
$fn$;

create or replace function public.general_badge_code(p_score integer, p_stars integer)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $fn$
  select case
    when coalesce(p_score,0) >= 1000 and coalesce(p_stars,0) >= 12 then 'inha_king'
    when coalesce(p_score,0) >= 750 and coalesce(p_stars,0) >= 10 then 'campus_master'
    when coalesce(p_score,0) >= 500 and coalesce(p_stars,0) >= 8 then 'campus_explorer'
    when coalesce(p_score,0) >= 350 and coalesce(p_stars,0) >= 6 then 'duck_hunter'
    when coalesce(p_score,0) >= 200 and coalesce(p_stars,0) >= 4 then 'campus_patrol'
    else 'freshman'
  end;
$fn$;

create or replace function public.get_my_rank_v3(p_user uuid)
 RETURNS TABLE(best_score integer, overall_rank bigint, department_rank bigint, department_id bigint, ranked_grade text, general_badge text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
  with all_rows as (
    select pb.user_id,p.department_id,pb.best_score,pb.best_combo,pb.achieved_at
    from public.player_bests pb join public.profiles p on p.user_id=pb.user_id and p.is_banned=false where pb.stage_key='secret'
  ), me as (select * from all_rows where user_id=p_user limit 1),
  overall as (
    select count(*)+1 r from all_rows a,me where a.best_score>me.best_score or (a.best_score=me.best_score and a.best_combo>me.best_combo) or (a.best_score=me.best_score and a.best_combo=me.best_combo and a.achieved_at<me.achieved_at)
  ), dept as (
    select count(*)+1 r from all_rows a,me where a.department_id is not distinct from me.department_id and (a.best_score>me.best_score or (a.best_score=me.best_score and a.best_combo>me.best_combo) or (a.best_score=me.best_score and a.best_combo=me.best_combo and a.achieved_at<me.achieved_at))
  ), gs as (
    select user_id,sum(best_score)::integer total_score,sum(best_stars)::integer total_stars from public.general_stage_bests group by user_id
  ), grade_runs as (
    select rr.user_id,
      case when rr.ruleset_version='secret-2.2-r1'
        then public.ranked_grade_code_v5(rr.score,coalesce(rr.gold_hits,0)+coalesce(rr.indeoki_hits,0),coalesce(rr.moon_bonus_hits,0),coalesce(rr.flight_hits,0),coalesce(rr.completed_calls,0))
        else public.ranked_grade_code(rr.score,coalesce(rr.gold_hits,0)+coalesce(rr.indeoki_hits,0),coalesce(rr.moon_bonus_hits,0),coalesce(rr.flight_hits,0),coalesce(rr.completed_calls,0))
      end grade
    from public.ranked_runs rr where rr.stage_key='secret' and rr.run_type='ranked' and rr.validation_status='accepted'
  ), rg as (
    select distinct on(gr.user_id) gr.user_id,gr.grade ranked_grade from grade_runs gr
    order by gr.user_id,case gr.grade when 'A+' then 8 when 'A0' then 7 when 'B+' then 6 when 'B0' then 5 when 'C+' then 4 when 'C0' then 3 when 'D+' then 2 when 'D0' then 1 else 0 end desc
  )
  select me.best_score,overall.r,dept.r,me.department_id,coalesce(rg.ranked_grade,'F'),
    public.general_badge_code(coalesce(gs.total_score,0),coalesce(gs.total_stars,0))
  from me cross join overall cross join dept left join gs on gs.user_id=me.user_id left join rg on rg.user_id=me.user_id;
$fn$;

create or replace function public.is_inha_mail(p_email text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $fn$select lower(coalesce(p_email,'')) ~ '^[^@[:space:]]+@(inha[.]edu|inha[.]ac[.]kr)$'$fn$;

create or replace function public.ranked_grade_code(p_score integer, p_rare integer, p_eclipse integer, p_flight integer, p_completed_calls integer)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $fn$
  select case
    when coalesce(p_completed_calls,0)>=2 and coalesce(p_score,0)>=330 and coalesce(p_rare,0)>=10 and coalesce(p_eclipse,0)>=12 and coalesce(p_flight,0)>=12 then 'A+'
    when coalesce(p_completed_calls,0)>=2 and coalesce(p_score,0)>=290 and coalesce(p_rare,0)>=8 and coalesce(p_eclipse,0)>=10 and coalesce(p_flight,0)>=10 then 'A0'
    when coalesce(p_completed_calls,0)>=1 and coalesce(p_score,0)>=255 and coalesce(p_rare,0)>=6 and coalesce(p_eclipse,0)>=8 and coalesce(p_flight,0)>=8 then 'B+'
    when coalesce(p_completed_calls,0)>=1 and coalesce(p_score,0)>=220 and coalesce(p_rare,0)>=5 and coalesce(p_eclipse,0)>=6 and coalesce(p_flight,0)>=6 then 'B0'
    when coalesce(p_completed_calls,0)>=1 and coalesce(p_score,0)>=185 and coalesce(p_rare,0)>=4 and coalesce(p_eclipse,0)>=5 and coalesce(p_flight,0)>=5 then 'C+'
    when coalesce(p_completed_calls,0)>=1 and coalesce(p_score,0)>=150 and coalesce(p_rare,0)>=2 and coalesce(p_eclipse,0)>=4 and coalesce(p_flight,0)>=4 then 'C0'
    when coalesce(p_completed_calls,0)>=1 and coalesce(p_score,0)>=115 and coalesce(p_rare,0)>=1 and coalesce(p_eclipse,0)>=3 and coalesce(p_flight,0)>=3 then 'D+'
    when coalesce(p_completed_calls,0)>=1 and coalesce(p_score,0)>=80 then 'D0'
    else 'F'
  end;
$fn$;

create or replace function public.ranked_grade_code_v5(p_score integer, p_rare integer, p_eclipse integer, p_flight integer, p_completed_calls integer)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $fn$
  select case
    when coalesce(p_completed_calls,0)>=2 and coalesce(p_score,0)>=400 and coalesce(p_rare,0)>=10 and coalesce(p_eclipse,0)>=12 and coalesce(p_flight,0)>=12 then 'A+'
    when coalesce(p_completed_calls,0)>=2 and coalesce(p_score,0)>=350 and coalesce(p_rare,0)>=8 and coalesce(p_eclipse,0)>=10 and coalesce(p_flight,0)>=10 then 'A0'
    when coalesce(p_completed_calls,0)>=1 and coalesce(p_score,0)>=290 and coalesce(p_rare,0)>=6 and coalesce(p_eclipse,0)>=8 and coalesce(p_flight,0)>=8 then 'B+'
    when coalesce(p_completed_calls,0)>=1 and coalesce(p_score,0)>=250 and coalesce(p_rare,0)>=5 and coalesce(p_eclipse,0)>=6 and coalesce(p_flight,0)>=6 then 'B0'
    when coalesce(p_completed_calls,0)>=1 and coalesce(p_score,0)>=210 and coalesce(p_rare,0)>=4 and coalesce(p_eclipse,0)>=5 and coalesce(p_flight,0)>=5 then 'C+'
    when coalesce(p_completed_calls,0)>=1 and coalesce(p_score,0)>=170 and coalesce(p_rare,0)>=2 and coalesce(p_eclipse,0)>=4 and coalesce(p_flight,0)>=4 then 'C0'
    when coalesce(p_completed_calls,0)>=1 and coalesce(p_score,0)>=130 and coalesce(p_rare,0)>=1 and coalesce(p_eclipse,0)>=3 and coalesce(p_flight,0)>=3 then 'D+'
    when coalesce(p_completed_calls,0)>=1 and coalesce(p_score,0)>=90 then 'D0'
    else 'F'
  end;
$fn$;

create or replace function public.record_ranked_result_v4(p_run_id uuid, p_user_id uuid, p_score integer, p_max_combo integer, p_annyongi_hits integer, p_indeoki_hits integer, p_gold_hits integer, p_normal_hits integer, p_speedy_hits integer, p_total_hits integer, p_dragon_calls integer, p_completed_calls integer, p_moon_bonus_hits integer, p_flight_hits integer, p_duration_ms integer, p_client_version text, p_input_count integer DEFAULT 0, p_reaction_sample_count integer DEFAULT 0, p_ultra_fast_reaction_count integer DEFAULT 0, p_suspicious_flag boolean DEFAULT false, p_suspicion_reasons text[] DEFAULT '{}'::text[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare
  v_run_row_id uuid;
  v_run_type text;
  v_ruleset_version text;
begin
  select run_type,ruleset_version into v_run_type,v_ruleset_version
  from public.ranked_sessions
  where run_id=p_run_id and user_id=p_user_id and status='submitted'
  for update;
  if not found then raise exception 'ranked session not submitted'; end if;

  insert into public.ranked_runs(
    run_id,user_id,stage_key,score,max_combo,annyongi_hits,indeoki_hits,gold_hits,
    normal_hits,speedy_hits,total_hits,dragon_calls,completed_calls,moon_bonus_hits,flight_hits,
    dragon_bursts,duration_ms,client_version,validation_status,run_type,ruleset_version,
    input_count,reaction_sample_count,ultra_fast_reaction_count,suspicious_flag,suspicion_reasons
  ) values(
    p_run_id,p_user_id,'secret',p_score,p_max_combo,p_annyongi_hits,p_indeoki_hits,p_gold_hits,
    p_normal_hits,p_speedy_hits,p_total_hits,p_dragon_calls,p_completed_calls,p_moon_bonus_hits,p_flight_hits,
    0,p_duration_ms,p_client_version,'accepted',v_run_type,v_ruleset_version,
    p_input_count,p_reaction_sample_count,p_ultra_fast_reaction_count,p_suspicious_flag,coalesce(p_suspicion_reasons,'{}')
  ) returning id into v_run_row_id;

  update public.ranked_sessions
  set status='accepted',finished_at=now()
  where run_id=p_run_id and user_id=p_user_id and status='submitted';
  if not found then raise exception 'ranked session close failed'; end if;

  if v_run_type='ranked' then
    insert into public.player_bests(user_id,stage_key,best_score,best_combo,best_run_id,achieved_at)
    values(p_user_id,'secret',p_score,p_max_combo,v_run_row_id,now())
    on conflict(user_id,stage_key) do update
    set best_score=excluded.best_score,best_combo=excluded.best_combo,
        best_run_id=excluded.best_run_id,achieved_at=excluded.achieved_at
    where excluded.best_score>public.player_bests.best_score
       or (excluded.best_score=public.player_bests.best_score and excluded.best_combo>public.player_bests.best_combo);
  end if;

  return v_run_row_id;
end;
$fn$;

create or replace function public.record_ranked_result_v5(p_run_id uuid, p_user_id uuid, p_score integer, p_max_combo integer, p_annyongi_hits integer, p_indeoki_hits integer, p_gold_hits integer, p_normal_hits integer, p_speedy_hits integer, p_total_hits integer, p_dragon_calls integer, p_completed_calls integer, p_moon_bonus_hits integer, p_flight_hits integer, p_duration_ms integer, p_client_version text, p_combo_bonus integer, p_flight_base_points integer, p_tier1_hits integer, p_tier2_hits integer, p_tier1_ground_award integer, p_tier2_ground_award integer, p_ascension_bonus integer, p_input_count integer DEFAULT 0, p_reaction_sample_count integer DEFAULT 0, p_ultra_fast_reaction_count integer DEFAULT 0, p_suspicious_flag boolean DEFAULT false, p_suspicion_reasons text[] DEFAULT '{}'::text[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare
  v_run_row_id uuid;
  v_run_type text;
  v_ruleset_version text;
begin
  select run_type,ruleset_version into v_run_type,v_ruleset_version
  from public.ranked_sessions
  where run_id=p_run_id and user_id=p_user_id and status='submitted'
  for update;
  if not found then raise exception 'ranked session not submitted'; end if;

  insert into public.ranked_runs(
    run_id,user_id,stage_key,score,max_combo,annyongi_hits,indeoki_hits,gold_hits,
    normal_hits,speedy_hits,total_hits,dragon_calls,completed_calls,moon_bonus_hits,flight_hits,
    dragon_bursts,duration_ms,client_version,validation_status,run_type,ruleset_version,
    input_count,reaction_sample_count,ultra_fast_reaction_count,suspicious_flag,suspicion_reasons,
    combo_bonus,flight_base_points,tier1_hits,tier2_hits,tier1_ground_award,tier2_ground_award,ascension_bonus
  ) values(
    p_run_id,p_user_id,'secret',p_score,p_max_combo,p_annyongi_hits,p_indeoki_hits,p_gold_hits,
    p_normal_hits,p_speedy_hits,p_total_hits,p_dragon_calls,p_completed_calls,p_moon_bonus_hits,p_flight_hits,
    0,p_duration_ms,p_client_version,'accepted',v_run_type,v_ruleset_version,
    p_input_count,p_reaction_sample_count,p_ultra_fast_reaction_count,p_suspicious_flag,coalesce(p_suspicion_reasons,'{}'),
    p_combo_bonus,p_flight_base_points,p_tier1_hits,p_tier2_hits,p_tier1_ground_award,p_tier2_ground_award,p_ascension_bonus
  ) returning id into v_run_row_id;

  update public.ranked_sessions
  set status='accepted',finished_at=now()
  where run_id=p_run_id and user_id=p_user_id and status='submitted';
  if not found then raise exception 'ranked session close failed'; end if;

  if v_run_type='ranked' then
    insert into public.player_bests(user_id,stage_key,best_score,best_combo,best_run_id,achieved_at)
    values(p_user_id,'secret',p_score,p_max_combo,v_run_row_id,now())
    on conflict(user_id,stage_key) do update
    set best_score=excluded.best_score,best_combo=excluded.best_combo,
        best_run_id=excluded.best_run_id,achieved_at=excluded.achieved_at
    where excluded.best_score>public.player_bests.best_score
       or (excluded.best_score=public.player_bests.best_score and excluded.best_combo>public.player_bests.best_combo);
  end if;

  return v_run_row_id;
end;
$fn$;

create or replace function public.world_collection_discover_v1(p_user uuid, p_entry_id text, p_source_type text, p_source_ref text, p_result_ref text, p_idempotency_key text, p_metadata jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
begin
  -- (original: SERVER_ONLY unless auth.role() = service_role; here EXECUTE is granted to the Worker role only)
  return private.world_collection_discover_v1(
    p_user, p_entry_id, p_source_type, p_source_ref,
    p_result_ref, p_idempotency_key, p_metadata);
end;
$fn$;

create or replace function public.world_collection_list_v1(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
begin
  -- (original: SERVER_ONLY unless auth.role() = service_role; here EXECUTE is granted to the Worker role only)
  return private.world_collection_list_v1(p_user);
end;
$fn$;

create or replace function public.world_fishing_input_v1(p_user uuid, p_attempt_id uuid, p_source_ref text, p_nonce uuid, p_action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare v_snapshot jsonb; v_next jsonb; v_now bigint;
  v_position private.world_fishing_positions%rowtype; v_lease private.world_fishing_spot_leases%rowtype;
begin
  perform private.world_fishing_require_server_v1(p_user);
  if p_action is null or p_action not in ('HOOK','CANCEL') then
    raise exception 'INVALID_FISHING_ACTION' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('world_activity:' || p_user::text,0));
  select snapshot into v_snapshot from private.world_fishing_attempt_snapshots
    where attempt_id=p_attempt_id and user_id=p_user for update;
  if not found then raise exception 'ATTEMPT_NOT_FOUND' using errcode='P0002'; end if;
  if p_source_ref is distinct from v_snapshot->>'sourceRef'
     or p_nonce is distinct from (v_snapshot->>'nonce')::uuid then
    raise exception 'FISHING_IDENTITY_MISMATCH' using errcode='22023';
  end if;
  if v_snapshot->>'status' <> 'ACTIVE' then
    if v_snapshot->>'terminalAction' <> 'EXPIRE' and v_snapshot->>'terminalAction' <> p_action then
      raise exception 'TERMINAL_COMMAND_CONFLICT' using errcode='23505';
    end if;
    return jsonb_build_object('status','ALREADY_PROCESSED','attempt',private.world_fishing_project_v1(v_snapshot));
  end if;
  v_now := floor(extract(epoch from clock_timestamp())*1000)::bigint;
  -- CANCEL, expired outcomes and terminal replay remain recoverable without a live position.
  if p_action='HOOK' and v_now<(v_snapshot->>'expiresAtMs')::bigint
     and (select presence_required from private.world_fishing_runtime where singleton) then
    v_position:=private.world_fishing_require_position_v1(p_user,p_source_ref);
    select * into v_lease from private.world_fishing_spot_leases
      where source_ref=p_source_ref and user_id=p_user and attempt_id=p_attempt_id for update;
    if not found or v_lease.expires_at<=clock_timestamp() then
      raise exception 'FISHING_LEASE_LOST' using errcode='P0001';
    end if;
    if v_position.session_id<>v_lease.session_id then
      raise exception 'FISHING_SESSION_CHANGED' using errcode='P0001';
    end if;
  end if;
  v_next := private.world_fishing_commit_v1(p_user,p_attempt_id,
    private.world_fishing_resolve_v1(v_snapshot,p_action,v_now));
  return jsonb_build_object('status','RESOLVED','attempt',private.world_fishing_project_v1(v_next));
end;
$fn$;

create or replace function public.world_fishing_observe_position_v1(p_user uuid, p_session_id uuid, p_revision bigint, p_x double precision, p_y double precision, p_z double precision, p_space text, p_mode text, p_observed_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare v_old private.world_fishing_positions%rowtype; v_now timestamptz;
begin
  perform private.world_fishing_require_server_v1(p_user);
  perform pg_advisory_xact_lock(hashtextextended('world_activity:' || p_user::text,0));
  v_now:=clock_timestamp();
  if p_session_id is null or p_revision is null or p_revision <= 0
     or p_x is null or p_x not between -10000 and 10000
     or p_y is null or p_y not between -10000 and 10000
     or p_z is null or p_z not between -10000 and 10000
     or p_space is null or p_space not in ('CAMPUS','OTHER')
     or p_mode is null or p_mode not in ('ON_FOOT','INELIGIBLE')
     or p_observed_at is null or p_observed_at > v_now then
    raise exception 'FISHING_POSITION_INVALID' using errcode='22023';
  end if;
  select * into v_old from private.world_fishing_positions where user_id=p_user for update;
  if found and p_revision < v_old.revision then
    return jsonb_build_object('status','STALE','revision',v_old.revision);
  end if;
  if found and p_revision = v_old.revision then
    if (p_session_id,p_x,p_y,p_z,p_space,p_mode,p_observed_at) is distinct from
       (v_old.session_id,v_old.x,v_old.y,v_old.z,v_old.space,v_old.mode,v_old.observed_at) then
      raise exception 'FISHING_POSITION_CONFLICT' using errcode='23505';
    end if;
    return jsonb_build_object('status','ALREADY_PROCESSED','revision',v_old.revision);
  end if;
  if p_observed_at <= v_now-interval '5 seconds' then
    raise exception 'FISHING_POSITION_STALE' using errcode='22023';
  end if;
  insert into private.world_fishing_positions(user_id,session_id,revision,x,y,z,space,mode,observed_at)
    values(p_user,p_session_id,p_revision,p_x,p_y,p_z,p_space,p_mode,p_observed_at)
    on conflict(user_id) do update set session_id=excluded.session_id,revision=excluded.revision,
      x=excluded.x,y=excluded.y,z=excluded.z,space=excluded.space,mode=excluded.mode,observed_at=excluded.observed_at;
  return jsonb_build_object('status','OBSERVED','revision',p_revision);
end;
$fn$;

create or replace function public.world_fishing_read_v1(p_user uuid, p_attempt_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare v_snapshot jsonb; v_receipt jsonb; v_id uuid; v_quantity integer;
  v_entry private.world_collection_entry_catalog%rowtype;
begin
  perform private.world_fishing_require_server_v1(p_user);
  perform pg_advisory_xact_lock(hashtextextended('world_activity:' || p_user::text,0));
  if p_attempt_id is null then
    select attempt_id,snapshot into v_id,v_snapshot from private.world_fishing_attempt_snapshots
      where user_id=p_user order by (snapshot->>'startedAtMs')::bigint desc,attempt_id desc limit 1 for update;
  else
    select attempt_id,snapshot into v_id,v_snapshot from private.world_fishing_attempt_snapshots
      where user_id=p_user and attempt_id=p_attempt_id for update;
    if not found then raise exception 'ATTEMPT_NOT_FOUND' using errcode='P0002'; end if;
  end if;
  if v_snapshot is not null then
    v_snapshot := private.world_fishing_expire_v1(p_user,v_snapshot);
    select receipt into v_receipt from private.world_activity_settlements where attempt_id=v_id;
  end if;
  select quantity into v_quantity from private.world_player_items where user_id=p_user and item_id='material.fish_carp';
  select * into strict v_entry from private.world_collection_entry_catalog where entry_id='collection.fish.carp';
  return jsonb_build_object(
    'attempt',case when v_snapshot is null then null else private.world_fishing_project_v1(v_snapshot) end,
    'settlement',case when v_snapshot is null or v_snapshot->>'status' <> 'SUCCEEDED' then 'NOT_REQUIRED'
      when v_receipt is null then 'PENDING' else 'SETTLED' end,'receipt',v_receipt,
    'inventory',jsonb_build_object('itemId','material.fish_carp','quantity',coalesce(v_quantity,0)),
    'discovery',private.world_collection_entry_snapshot_v1(p_user,v_entry),
    'lifeSkill',private.world_life_skill_snapshot_v1(p_user,'life.fishing'));
end;
$fn$;

create or replace function public.world_fishing_settle_v1(p_user uuid, p_attempt_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare v_snapshot jsonb; v_catch jsonb; v_plan jsonb;
begin
  perform private.world_fishing_require_server_v1(p_user);
  perform pg_advisory_xact_lock(hashtextextended('world_activity:' || p_user::text,0));
  select snapshot into v_snapshot from private.world_fishing_attempt_snapshots
    where attempt_id=p_attempt_id and user_id=p_user for update;
  if not found then raise exception 'ATTEMPT_NOT_FOUND' using errcode='P0002'; end if;
  if v_snapshot->>'status' <> 'SUCCEEDED' then
    raise exception 'FISHING_NOT_SUCCEEDED' using errcode='P0001';
  end if;
  -- The plan is derived only from the frozen server outcome, never from the request.
  v_catch := v_snapshot->'result'->'catch';
  v_plan := jsonb_build_object(
    'items',jsonb_build_array(jsonb_build_object('itemId',v_catch->'itemId','quantity',v_catch->'quantity')),
    'discoveries',jsonb_build_array(jsonb_build_object('entryId',v_catch->'collectionEntryId')),
    'lifeXp',case when (v_catch->>'lifeXp')::bigint > 0
      then jsonb_build_array(jsonb_build_object('skillId',v_catch->'skillId','amount',v_catch->'lifeXp'))
      else '[]'::jsonb end);
  return private.world_activity_settle_v1(p_user,p_attempt_id,v_plan);
end;
$fn$;

create or replace function public.world_fishing_start_v1(p_user uuid, p_source_ref text, p_client_attempt_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
declare
  v_config private.world_fishing_runtime%rowtype;
  v_row record;
  v_start jsonb;
  v_snapshot jsonb;
  v_effects jsonb;
  v_policy jsonb;
  v_now bigint;
  v_wait bigint;
  v_id uuid;
  v_last bigint;
  v_position private.world_fishing_positions%rowtype;
begin
  perform private.world_fishing_require_server_v1(p_user);
  if p_source_ref is null or p_source_ref not in ('fishing.inkyung.north_01','fishing.inkyung.south_01')
     or p_client_attempt_key is null then
    raise exception 'INVALID_FISHING_IDENTITY' using errcode='22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('world_activity:' || p_user::text,0));

  select f.snapshot,a.source_ref into v_row
    from private.world_activity_attempts a
    left join private.world_fishing_attempt_snapshots f on f.attempt_id=a.attempt_id
   where a.user_id=p_user and a.client_attempt_key=p_client_attempt_key;
  if found then
    if v_row.snapshot is null or v_row.source_ref <> p_source_ref then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505';
    end if;
    v_snapshot := private.world_fishing_expire_v1(p_user,v_row.snapshot);
    return jsonb_build_object('status','ALREADY_PROCESSED','attempt',private.world_fishing_project_v1(v_snapshot));
  end if;

  for v_row in
    select * from private.world_fishing_attempt_snapshots
     where user_id=p_user and snapshot->>'status'='ACTIVE'
     for update
  loop
    v_snapshot := private.world_fishing_expire_v1(p_user,v_row.snapshot);
    if v_snapshot->>'status'='ACTIVE' then
      raise exception 'ATTEMPT_ALREADY_ACTIVE' using errcode='P0001';
    end if;
  end loop;

  select * into strict v_config from private.world_fishing_runtime where singleton for share;
  if not v_config.enabled then
    raise exception 'FISHING_UNAVAILABLE' using errcode='P0001';
  end if;
  perform private.world_fishing_policy_validate_v1(v_config.policy);
  if v_config.minimum_start_interval_ms is null then
    raise exception 'FISHING_POLICY_INVALID' using errcode='22023';
  end if;

  -- Read the current tree epoch exactly once for this cast, then freeze the resulting policy.
  v_effects := private.world_fishing_skill_effects_v1(p_user);
  v_policy := private.world_fishing_apply_skill_effects_v1(v_config.policy,v_effects);

  v_now := floor(extract(epoch from clock_timestamp())*1000)::bigint;
  if v_now + (v_policy->>'attemptTtlMs')::bigint > 9007199254740991 then
    raise exception 'FISHING_POLICY_INVALID' using errcode='22023';
  end if;

  select max((snapshot->>'startedAtMs')::bigint) into v_last
    from private.world_fishing_attempt_snapshots where user_id=p_user;
  if v_last is not null and v_now-v_last < v_config.minimum_start_interval_ms then
    raise exception 'FISHING_RATE_LIMITED' using errcode='P0001';
  end if;

  if v_config.presence_required then
    v_position:=private.world_fishing_require_position_v1(p_user,p_source_ref);
    perform pg_advisory_xact_lock(hashtextextended('world_fishing_spot:' || p_source_ref,0));
    v_position:=private.world_fishing_require_position_v1(p_user,p_source_ref);
    v_now:=floor(extract(epoch from clock_timestamp())*1000)::bigint;
    delete from private.world_fishing_spot_leases
      where source_ref=p_source_ref and expires_at<=clock_timestamp();
    if exists(select 1 from private.world_fishing_spot_leases where source_ref=p_source_ref) then
      raise exception 'FISHING_SPOT_OCCUPIED' using errcode='P0001';
    end if;
  end if;

  v_wait := (v_policy->>'minWaitMs')::bigint + floor(random() *
    ((v_policy->>'maxWaitMs')::bigint-(v_policy->>'minWaitMs')::bigint+1))::bigint;

  v_start := private.world_life_activity_start_with_creature_v1(
    p_user,'activity.fishing.inkyung',p_source_ref,p_client_attempt_key,1,1,
    to_timestamp((v_now+(v_policy->>'attemptTtlMs')::bigint)::double precision/1000)
  );
  if v_start->'activity'->>'status' is distinct from 'STARTED' then
    raise exception 'ACTIVITY_OUTCOME_CONFLICT' using errcode='23505';
  end if;

  v_id := (v_start->'activity'->'attempt'->>'attemptId')::uuid;
  v_snapshot := jsonb_build_object(
    'activityId','activity.fishing.inkyung',
    'sourceRef',p_source_ref,
    'clientAttemptKey',p_client_attempt_key,
    'attemptId',v_id,
    'actorUserId',p_user,
    'nonce',gen_random_uuid(),
    'resolverVersion','resolver.fishing.inkyung_v1',
    'definitionVersion',1,
    'outcomeSchemaVersion',1,
    'status','ACTIVE',
    'startedAtMs',v_now,
    'biteAtMs',v_now+v_wait,
    'hookDeadlineMs',v_now+v_wait+(v_policy->>'responseWindowMs')::bigint,
    'expiresAtMs',v_now+(v_policy->>'attemptTtlMs')::bigint,
    'policy',v_policy,
    'skillEffects',v_effects,
    'terminalAction',null,
    'result',null
  );

  insert into private.world_fishing_attempt_snapshots values (v_id,p_user,v_snapshot);
  if v_config.presence_required then
    insert into private.world_fishing_spot_leases(source_ref,user_id,attempt_id,session_id,expires_at)
      values(
        p_source_ref,p_user,v_id,v_position.session_id,
        to_timestamp((v_snapshot->>'expiresAtMs')::double precision/1000)
      );
  end if;

  return jsonb_build_object('status','STARTED','attempt',private.world_fishing_project_v1(v_snapshot));
end;
$fn$;

create or replace function public.world_inkyung_duck_observe_v1(p_user uuid, p_duck_id text, p_result_ref text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
begin
  -- (original: SERVER_ONLY unless auth.role() = service_role; here EXECUTE is granted to the Worker role only)
  return private.world_inkyung_duck_observe_v1(
    p_user,p_duck_id,p_result_ref,p_idempotency_key);
end;
$fn$;

reset check_function_bodies;

-- ===========================================================================
-- Reference data (catalogs, policies, seeds), as left by the original migrations.
-- Each table is seeded only while it is still empty, so a re-run never touches
-- rows an operator has since changed (and never trips the catalog guard triggers).
-- ===========================================================================

-- private.world_collection_entry_catalog: 4 rows
do $seed$ begin if not exists (select 1 from private.world_collection_entry_catalog) then
insert into private.world_collection_entry_catalog (entry_id, category, persistence_mode, owner_domain, owner_ref, status, definition_version) values
  ('collection.artifact.campus_fragment_01', 'ARTIFACT', 'SERVER_PERSISTED', NULL, NULL, 'COMING_SOON', '1'),
  ('collection.fish.carp', 'FISH', 'SERVER_PERSISTED', NULL, NULL, 'ACTIVE', '1'),
  ('collection.place.biryong_tower', 'PLACE', 'DERIVED_FROM_OWNER', 'BIRYONG', 'BR01', 'ACTIVE', '1'),
  ('collection.plant.campus_leaf', 'PLANT', 'SERVER_PERSISTED', NULL, NULL, 'COMING_SOON', '1');
end if; end $seed$;

-- private.world_creature_acquisition_rule_catalog: 1 row
do $seed$ begin if not exists (select 1 from private.world_creature_acquisition_rule_catalog) then
insert into private.world_creature_acquisition_rule_catalog (rule_id, species_id, form_id, source_ref, required_observation_count, auto_activate_if_party_empty, status, definition_version) values
  ('creature.acquisition.duck.inkyung_bond', 'creature.species.duck', 'creature.form.duck.base', 'creature.acquisition.duck.inkyung', '3', 'true', 'ACTIVE', '1');
end if; end $seed$;

-- private.world_creature_activity_bridge_catalog: 4 rows
do $seed$ begin if not exists (select 1 from private.world_creature_activity_bridge_catalog) then
insert into private.world_creature_activity_bridge_catalog (bridge_id, source_domain, semantic_event_type, memory_tag, xp_amount, cooldown_seconds, daily_cap, status, definition_version) values
  ('creature.bridge.activity.archaeology', 'ACTIVITY', 'activity.archaeology.excavate', 'memory.life.archaeology', '0', '0', NULL, 'COMING_SOON', '1'),
  ('creature.bridge.activity.fishing', 'ACTIVITY', 'activity.fishing.catch', 'memory.life.fishing', '0', '0', NULL, 'COMING_SOON', '1'),
  ('creature.bridge.activity.gathering', 'ACTIVITY', 'activity.gathering.harvest', 'memory.life.gathering', '0', '0', NULL, 'COMING_SOON', '1'),
  ('creature.bridge.combat.victory', 'COMBAT', 'combat.succeeded', 'memory.combat.victory', '0', '0', NULL, 'COMING_SOON', '1');
end if; end $seed$;

-- private.world_creature_form_catalog: 1 row
do $seed$ begin if not exists (select 1 from private.world_creature_form_catalog) then
insert into private.world_creature_form_catalog (form_id, species_id, status, definition_version) values
  ('creature.form.duck.base', 'creature.species.duck', 'ACTIVE', '1');
end if; end $seed$;

-- private.world_creature_species_catalog: 4 rows
do $seed$ begin if not exists (select 1 from private.world_creature_species_catalog) then
insert into private.world_creature_species_catalog (species_id, status, definition_version) values
  ('creature.species.duck', 'ACTIVE', '1'),
  ('creature.species.pageling', 'COMING_SOON', '1'),
  ('creature.species.porong', 'COMING_SOON', '1'),
  ('creature.species.volti', 'COMING_SOON', '1');
end if; end $seed$;

-- private.world_fishing_runtime: 1 row
do $seed$ begin if not exists (select 1 from private.world_fishing_runtime) then
insert into private.world_fishing_runtime (singleton, enabled, policy, minimum_start_interval_ms, presence_required) values
  ('true', 'true', '{"lifeXp": 20, "maxWaitMs": 9000, "minWaitMs": 3000, "attemptTtlMs": 30000, "policyVersion": "fishing.candidate.v1", "responseWindowMs": 1500}', '2000', 'true');
end if; end $seed$;

-- private.world_fishing_spots: 2 rows
do $seed$ begin if not exists (select 1 from private.world_fishing_spots) then
insert into private.world_fishing_spots (source_ref, x, z, radius, min_y, max_y) values
  ('fishing.inkyung.north_01', '129.77100098688555', '48.14517277694196', '3', '-1', '4'),
  ('fishing.inkyung.south_01', '116.87007679393874', '-6.097417122539438', '3', '-1', '4');
end if; end $seed$;

-- private.world_inkyung_duck_observation_subjects: 4 rows
do $seed$ begin if not exists (select 1 from private.world_inkyung_duck_observation_subjects) then
insert into private.world_inkyung_duck_observation_subjects (duck_id, kind, status) values
  ('inkyung_duck_mallard_01', 'mallard', 'ACTIVE'),
  ('inkyung_duck_white_01', 'white', 'ACTIVE'),
  ('inkyung_duck_white_02', 'white', 'ACTIVE'),
  ('inkyung_duck_white_03', 'white', 'ACTIVE');
end if; end $seed$;

-- private.world_item_catalog: 42 rows
do $seed$ begin if not exists (select 1 from private.world_item_catalog) then
insert into private.world_item_catalog (item_id, category, ownership_policy, max_stack, status) values
  ('back.freshman_bag', 'WEARABLE', 'UNIQUE', NULL, 'ACTIVE'),
  ('back.induck_backpack', 'WEARABLE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('badge.campus_explorer', 'BADGE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('badge.campus_first_step', 'BADGE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('badge.main_gate', 'BADGE', 'UNIQUE', NULL, 'ACTIVE'),
  ('badge.mcm_2026_landlord', 'BADGE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('consumable.grilled_carp', 'CONSUMABLE', 'STACKABLE', '20', 'COMING_SOON'),
  ('emote.wave_plus', 'EMOTE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('finish.floor_basic', 'ROOM_FINISH', 'UNIQUE', NULL, 'COMING_SOON'),
  ('finish.floor_wood_051', 'ROOM_FINISH', 'UNIQUE', NULL, 'COMING_SOON'),
  ('finish.wall_basic', 'ROOM_FINISH', 'UNIQUE', NULL, 'COMING_SOON'),
  ('finish.wall_white_plaster_02', 'ROOM_FINISH', 'UNIQUE', NULL, 'COMING_SOON'),
  ('furniture.campus_map_poster', 'FURNITURE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('furniture.campus_rug_blue', 'FURNITURE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('furniture.cooking_station', 'FURNITURE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('furniture.dorm_bookshelf_slim', 'FURNITURE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('furniture.dorm_desk_lamp', 'FURNITURE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('furniture.dorm_monitor', 'FURNITURE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('furniture.dorm_plant_medium', 'FURNITURE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('furniture.dorm_resident_plate', 'FURNITURE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('furniture.dorm_side_table_low', 'FURNITURE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('furniture.dorm_single_sofa', 'FURNITURE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('furniture.dorm_trophy_shelf', 'FURNITURE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('furniture.induck_chair', 'FURNITURE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('furniture.induck_cushion', 'FURNITURE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('furniture.mcm_2026_landlord_figure', 'FURNITURE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('furniture.mcm_2026_poster', 'FURNITURE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('furniture.mini_induck', 'FURNITURE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('furniture.study_books_set', 'FURNITURE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('head.induck_cap', 'WEARABLE', 'UNIQUE', NULL, 'ACTIVE'),
  ('head.inha_cap', 'WEARABLE', 'UNIQUE', NULL, 'ACTIVE'),
  ('head.inkyung_duck', 'WEARABLE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('material.artifact_fragment_01', 'MATERIAL', 'STACKABLE', '99', 'ACTIVE'),
  ('material.campus_leaf', 'MATERIAL', 'STACKABLE', '99', 'ACTIVE'),
  ('material.fish_carp', 'MATERIAL', 'STACKABLE', '99', 'ACTIVE'),
  ('memorabilia.campus_mug', 'MEMORABILIA', 'UNIQUE', NULL, 'COMING_SOON'),
  ('memorabilia.mcm_2026_wristband', 'MEMORABILIA', 'UNIQUE', NULL, 'COMING_SOON'),
  ('shoes.campus_sneakers', 'WEARABLE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('top.induck_hoodie', 'WEARABLE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('top.inha_basic', 'WEARABLE', 'UNIQUE', NULL, 'ACTIVE'),
  ('top.mcm_2026_survivor', 'WEARABLE', 'UNIQUE', NULL, 'COMING_SOON'),
  ('top.mcm_jacket', 'WEARABLE', 'UNIQUE', NULL, 'COMING_SOON');
end if; end $seed$;

-- private.world_life_creature_bridge_catalog: 3 rows
do $seed$ begin if not exists (select 1 from private.world_life_creature_bridge_catalog) then
insert into private.world_life_creature_bridge_catalog (bridge_id, activity_id, life_skill_id, required_activity_definition_version, created_at) values
  ('creature.bridge.activity.archaeology', 'activity.archaeology.campus_history', 'life.archaeology', '1', '2026-11-11 16:55:25.532082+00'),
  ('creature.bridge.activity.fishing', 'activity.fishing.inkyung', 'life.fishing', '1', '2026-11-11 16:55:25.532082+00'),
  ('creature.bridge.activity.gathering', 'activity.gathering.campus', 'life.gathering', '1', '2026-11-11 16:55:25.532082+00');
end if; end $seed$;

-- private.world_life_skill_catalog: 11 rows
do $seed$ begin if not exists (select 1 from private.world_life_skill_catalog) then
insert into private.world_life_skill_catalog (skill_id, curve_id, status) values
  ('life.archaeology', 'life.common.v1', 'COMING_SOON'),
  ('life.cooking', 'life.common.v1', 'COMING_SOON'),
  ('life.crafting', 'life.common.v1', 'COMING_SOON'),
  ('life.farming', 'life.common.v1', 'COMING_SOON'),
  ('life.fishing', 'life.common.v1', 'ACTIVE'),
  ('life.gathering', 'life.common.v1', 'COMING_SOON'),
  ('life.mining', 'life.common.v1', 'COMING_SOON'),
  ('life.photography', 'life.common.v1', 'COMING_SOON'),
  ('life.research', 'life.common.v1', 'COMING_SOON'),
  ('life.woodcutting', 'life.common.v1', 'COMING_SOON'),
  ('life.woodworking', 'life.common.v1', 'COMING_SOON');
end if; end $seed$;

-- private.world_life_skill_thresholds: 20 rows
do $seed$ begin if not exists (select 1 from private.world_life_skill_thresholds) then
insert into private.world_life_skill_thresholds (curve_id, level, min_total_xp, created_at, cumulative_sp) values
  ('life.common.v1', '1', '0', '2026-11-11 16:55:25.097929+00', '0'),
  ('life.common.v1', '10', '4500', '2026-11-11 16:55:25.771075+00', '11'),
  ('life.common.v1', '11', '5500', '2026-11-11 16:55:25.771075+00', '12'),
  ('life.common.v1', '12', '6600', '2026-11-11 16:55:25.771075+00', '13'),
  ('life.common.v1', '13', '7800', '2026-11-11 16:55:25.771075+00', '14'),
  ('life.common.v1', '14', '9100', '2026-11-11 16:55:25.771075+00', '15'),
  ('life.common.v1', '15', '10500', '2026-11-11 16:55:25.771075+00', '17'),
  ('life.common.v1', '16', '12000', '2026-11-11 16:55:25.771075+00', '18'),
  ('life.common.v1', '17', '13600', '2026-11-11 16:55:25.771075+00', '19'),
  ('life.common.v1', '18', '15300', '2026-11-11 16:55:25.771075+00', '20'),
  ('life.common.v1', '19', '17100', '2026-11-11 16:55:25.771075+00', '21'),
  ('life.common.v1', '2', '100', '2026-11-11 16:55:25.771075+00', '1'),
  ('life.common.v1', '20', '19000', '2026-11-11 16:55:25.771075+00', '23'),
  ('life.common.v1', '3', '300', '2026-11-11 16:55:25.771075+00', '2'),
  ('life.common.v1', '4', '600', '2026-11-11 16:55:25.771075+00', '3'),
  ('life.common.v1', '5', '1000', '2026-11-11 16:55:25.771075+00', '5'),
  ('life.common.v1', '6', '1500', '2026-11-11 16:55:25.771075+00', '6'),
  ('life.common.v1', '7', '2100', '2026-11-11 16:55:25.771075+00', '7'),
  ('life.common.v1', '8', '2800', '2026-11-11 16:55:25.771075+00', '8'),
  ('life.common.v1', '9', '3600', '2026-11-11 16:55:25.771075+00', '9');
end if; end $seed$;

-- private.world_life_skill_tree_catalog: 18 rows
do $seed$ begin if not exists (select 1 from private.world_life_skill_tree_catalog) then
insert into private.world_life_skill_tree_catalog (node_id, skill_id, status, sp_cost, required_life_level, required_skill_level, max_rank) values
  ('life.node.farming.crop_rotation', 'life.farming', 'COMING_SOON', '2', '1', '10', '1'),
  ('life.node.farming.greenhouse', 'life.farming', 'COMING_SOON', '2', '1', '8', '2'),
  ('life.node.farming.seed_selection', 'life.farming', 'COMING_SOON', '1', '1', '4', '3'),
  ('life.node.farming.smart_farm', 'life.farming', 'COMING_SOON', '3', '1', '15', '1'),
  ('life.node.farming.soil_reading', 'life.farming', 'COMING_SOON', '1', '1', '2', '3'),
  ('life.node.farming.water_sense', 'life.farming', 'COMING_SOON', '1', '1', '5', '2'),
  ('life.node.fishing.baitcraft', 'life.fishing', 'COMING_SOON', '1', '1', '5', '2'),
  ('life.node.fishing.boat_fishing', 'life.fishing', 'COMING_SOON', '2', '1', '10', '1'),
  ('life.node.fishing.deep_sea_fishing', 'life.fishing', 'COMING_SOON', '3', '1', '15', '1'),
  ('life.node.fishing.fish_sense', 'life.fishing', 'ACTIVE', '1', '1', '3', '3'),
  ('life.node.fishing.rare_fish_sense', 'life.fishing', 'COMING_SOON', '2', '1', '8', '2'),
  ('life.node.fishing.steady_hands', 'life.fishing', 'ACTIVE', '1', '1', '2', '3'),
  ('life.node.woodcutting.clean_cut', 'life.woodcutting', 'COMING_SOON', '1', '1', '2', '3'),
  ('life.node.woodcutting.field_sawmill', 'life.woodcutting', 'COMING_SOON', '2', '1', '10', '1'),
  ('life.node.woodcutting.hardwood_handling', 'life.woodcutting', 'COMING_SOON', '2', '1', '8', '2'),
  ('life.node.woodcutting.master_forester', 'life.woodcutting', 'COMING_SOON', '3', '1', '15', '1'),
  ('life.node.woodcutting.timber_eye', 'life.woodcutting', 'COMING_SOON', '1', '1', '4', '3'),
  ('life.node.woodcutting.tool_care', 'life.woodcutting', 'COMING_SOON', '1', '1', '5', '2');
end if; end $seed$;

-- public.departments: 67 rows
do $seed$ begin if not exists (select 1 from public.departments) then
insert into public.departments (id, name, active, sort_order, created_at) values
  ('1', '학과 미선택', 'true', '9999', '2026-10-01 21:31:32+00'),
  ('10', '환경공학과', 'true', '9', '2026-10-01 21:31:32+00'),
  ('11', '공간정보공학과', 'true', '10', '2026-10-01 21:31:32+00'),
  ('12', '건축학부', 'true', '11', '2026-10-01 21:31:32+00'),
  ('13', '에너지자원공학과', 'true', '12', '2026-10-01 21:31:32+00'),
  ('14', '전기전자공학부', 'true', '13', '2026-10-01 21:31:32+00'),
  ('15', '반도체시스템공학과', 'true', '14', '2026-10-01 21:31:32+00'),
  ('16', '이차전지융합학과', 'true', '15', '2026-10-01 21:31:32+00'),
  ('17', '수학과', 'true', '16', '2026-10-01 21:31:32+00'),
  ('18', '통계학과', 'true', '17', '2026-10-01 21:31:32+00'),
  ('19', '물리학과', 'true', '18', '2026-10-01 21:31:32+00'),
  ('2', '기계공학과', 'true', '1', '2026-10-01 21:31:32+00'),
  ('20', '화학과', 'true', '19', '2026-10-01 21:31:32+00'),
  ('21', '해양과학과', 'true', '20', '2026-10-01 21:31:32+00'),
  ('22', '식품영양학과', 'true', '21', '2026-10-01 21:31:32+00'),
  ('23', '경영학과', 'true', '22', '2026-10-01 21:31:32+00'),
  ('24', '파이낸스경영학과', 'true', '23', '2026-10-01 21:31:32+00'),
  ('25', '아태물류학부', 'true', '24', '2026-10-01 21:31:32+00'),
  ('26', '국제통상학과', 'true', '25', '2026-10-01 21:31:32+00'),
  ('27', '국어교육과', 'true', '26', '2026-10-01 21:31:32+00'),
  ('28', '영어교육과', 'true', '27', '2026-10-01 21:31:32+00'),
  ('29', '사회교육과', 'true', '28', '2026-10-01 21:31:32+00'),
  ('3', '항공우주공학과', 'true', '2', '2026-10-01 21:31:32+00'),
  ('30', '체육교육과', 'true', '29', '2026-10-01 21:31:32+00'),
  ('31', '교육학과', 'true', '30', '2026-10-01 21:31:32+00'),
  ('32', '수학교육과', 'true', '31', '2026-10-01 21:31:32+00'),
  ('33', '행정학과', 'true', '32', '2026-10-01 21:31:32+00'),
  ('34', '정치외교학과', 'true', '33', '2026-10-01 21:31:32+00'),
  ('35', '미디어커뮤니케이션학과', 'true', '34', '2026-10-01 21:31:32+00'),
  ('36', '경제학과', 'true', '35', '2026-10-01 21:31:32+00'),
  ('37', '소비자학과', 'true', '36', '2026-10-01 21:31:32+00'),
  ('38', '아동심리학과', 'true', '37', '2026-10-01 21:31:32+00'),
  ('39', '사회복지학과', 'true', '38', '2026-10-01 21:31:32+00'),
  ('4', '조선해양공학과', 'true', '3', '2026-10-01 21:31:32+00'),
  ('40', '한국어문학과', 'true', '39', '2026-10-01 21:31:32+00'),
  ('41', '사학과', 'true', '40', '2026-10-01 21:31:32+00'),
  ('42', '철학과', 'true', '41', '2026-10-01 21:31:32+00'),
  ('43', '중국학과', 'true', '42', '2026-10-01 21:31:32+00'),
  ('44', '일본언어문화학과', 'true', '43', '2026-10-01 21:31:32+00'),
  ('45', '영미유럽인문융합학부', 'true', '44', '2026-10-01 21:31:32+00'),
  ('46', '문화콘텐츠문화경영학과', 'true', '45', '2026-10-01 21:31:32+00'),
  ('47', '의예과', 'true', '46', '2026-10-01 21:31:32+00'),
  ('48', '간호학과', 'true', '47', '2026-10-01 21:31:32+00'),
  ('49', '조형예술학과', 'true', '48', '2026-10-01 21:31:32+00'),
  ('5', '산업경영공학과', 'true', '4', '2026-10-01 21:31:32+00'),
  ('50', '디자인융합학과', 'true', '49', '2026-10-01 21:31:32+00'),
  ('51', '스포츠과학과', 'true', '50', '2026-10-01 21:31:32+00'),
  ('52', '연극영화학과', 'true', '51', '2026-10-01 21:31:32+00'),
  ('53', '의류디자인학과', 'true', '52', '2026-10-01 21:31:32+00'),
  ('54', '인공지능공학과', 'true', '53', '2026-10-01 21:31:32+00'),
  ('55', '데이터사이언스학과', 'true', '54', '2026-10-01 21:31:32+00'),
  ('56', '스마트모빌리티공학과', 'true', '55', '2026-10-01 21:31:32+00'),
  ('57', '디자인테크놀로지학과', 'true', '56', '2026-10-01 21:31:32+00'),
  ('58', '컴퓨터공학과', 'true', '57', '2026-10-01 21:31:32+00'),
  ('59', 'IBT학과', 'true', '58', '2026-10-01 21:31:32+00'),
  ('6', '화학공학과', 'true', '5', '2026-10-01 21:31:32+00'),
  ('60', 'ISE학과', 'true', '59', '2026-10-01 21:31:32+00'),
  ('61', 'KLC학과', 'true', '60', '2026-10-01 21:31:32+00'),
  ('62', '자유전공학부', 'true', '61', '2026-10-01 21:31:32+00'),
  ('63', '메카트로닉스공학과', 'true', '62', '2026-10-01 21:31:32+00'),
  ('64', '소프트웨어융합공학과', 'true', '63', '2026-10-01 21:31:32+00'),
  ('65', '산업경영학과', 'true', '64', '2026-10-01 21:31:32+00'),
  ('66', '금융투자학과', 'true', '65', '2026-10-01 21:31:32+00'),
  ('67', '반도체산업융합학과', 'true', '66', '2026-10-01 21:31:32+00'),
  ('7', '고분자공학과', 'true', '6', '2026-10-01 21:31:32+00'),
  ('8', '신소재공학과', 'true', '7', '2026-10-01 21:31:32+00'),
  ('9', '사회인프라공학과', 'true', '8', '2026-10-01 21:31:32+00');
end if; end $seed$;

-- ---- foreign keys between Tier 3 tables ----
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_activity_settlements_attempt_id_fkey' and conrelid = 'private.world_activity_settlements'::regclass) then
  alter table private.world_activity_settlements add constraint world_activity_settlements_attempt_id_fkey FOREIGN KEY (attempt_id) REFERENCES private.world_activity_attempts(attempt_id) ON DELETE CASCADE;
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_creature_acquisition_claims_creature_id_fkey' and conrelid = 'private.world_creature_acquisition_claims'::regclass) then
  alter table private.world_creature_acquisition_claims add constraint world_creature_acquisition_claims_creature_id_fkey FOREIGN KEY (creature_id) REFERENCES private.world_player_creatures(creature_id) ON DELETE CASCADE;
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_creature_acquisition_claims_rule_id_fkey' and conrelid = 'private.world_creature_acquisition_claims'::regclass) then
  alter table private.world_creature_acquisition_claims add constraint world_creature_acquisition_claims_rule_id_fkey FOREIGN KEY (rule_id) REFERENCES private.world_creature_acquisition_rule_catalog(rule_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_creature_acquisition_rule_catalog_form_id_fkey' and conrelid = 'private.world_creature_acquisition_rule_catalog'::regclass) then
  alter table private.world_creature_acquisition_rule_catalog add constraint world_creature_acquisition_rule_catalog_form_id_fkey FOREIGN KEY (form_id) REFERENCES private.world_creature_form_catalog(form_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_creature_acquisition_rule_catalog_species_id_fkey' and conrelid = 'private.world_creature_acquisition_rule_catalog'::regclass) then
  alter table private.world_creature_acquisition_rule_catalog add constraint world_creature_acquisition_rule_catalog_species_id_fkey FOREIGN KEY (species_id) REFERENCES private.world_creature_species_catalog(species_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_creature_activity_events_bridge_id_fkey' and conrelid = 'private.world_creature_activity_events'::regclass) then
  alter table private.world_creature_activity_events add constraint world_creature_activity_events_bridge_id_fkey FOREIGN KEY (bridge_id) REFERENCES private.world_creature_activity_bridge_catalog(bridge_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_creature_activity_events_creature_id_fkey' and conrelid = 'private.world_creature_activity_events'::regclass) then
  alter table private.world_creature_activity_events add constraint world_creature_activity_events_creature_id_fkey FOREIGN KEY (creature_id) REFERENCES private.world_player_creatures(creature_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_creature_form_catalog_species_id_fkey' and conrelid = 'private.world_creature_form_catalog'::regclass) then
  alter table private.world_creature_form_catalog add constraint world_creature_form_catalog_species_id_fkey FOREIGN KEY (species_id) REFERENCES private.world_creature_species_catalog(species_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_creature_memory_tags_creature_id_fkey' and conrelid = 'private.world_creature_memory_tags'::regclass) then
  alter table private.world_creature_memory_tags add constraint world_creature_memory_tags_creature_id_fkey FOREIGN KEY (creature_id) REFERENCES private.world_player_creatures(creature_id) ON DELETE CASCADE;
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_creature_observation_events_species_id_fkey' and conrelid = 'private.world_creature_observation_events'::regclass) then
  alter table private.world_creature_observation_events add constraint world_creature_observation_events_species_id_fkey FOREIGN KEY (species_id) REFERENCES private.world_creature_species_catalog(species_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_creature_party_history_active_creature_id_fkey' and conrelid = 'private.world_creature_party_history'::regclass) then
  alter table private.world_creature_party_history add constraint world_creature_party_history_active_creature_id_fkey FOREIGN KEY (active_creature_id) REFERENCES private.world_player_creatures(creature_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_creature_party_history_reserve1_creature_id_fkey' and conrelid = 'private.world_creature_party_history'::regclass) then
  alter table private.world_creature_party_history add constraint world_creature_party_history_reserve1_creature_id_fkey FOREIGN KEY (reserve1_creature_id) REFERENCES private.world_player_creatures(creature_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_creature_party_history_reserve2_creature_id_fkey' and conrelid = 'private.world_creature_party_history'::regclass) then
  alter table private.world_creature_party_history add constraint world_creature_party_history_reserve2_creature_id_fkey FOREIGN KEY (reserve2_creature_id) REFERENCES private.world_player_creatures(creature_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_creature_party_state_active_creature_id_fkey' and conrelid = 'private.world_creature_party_state'::regclass) then
  alter table private.world_creature_party_state add constraint world_creature_party_state_active_creature_id_fkey FOREIGN KEY (active_creature_id) REFERENCES private.world_player_creatures(creature_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_creature_party_state_reserve1_creature_id_fkey' and conrelid = 'private.world_creature_party_state'::regclass) then
  alter table private.world_creature_party_state add constraint world_creature_party_state_reserve1_creature_id_fkey FOREIGN KEY (reserve1_creature_id) REFERENCES private.world_player_creatures(creature_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_creature_party_state_reserve2_creature_id_fkey' and conrelid = 'private.world_creature_party_state'::regclass) then
  alter table private.world_creature_party_state add constraint world_creature_party_state_reserve2_creature_id_fkey FOREIGN KEY (reserve2_creature_id) REFERENCES private.world_player_creatures(creature_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_creature_xp_transactions_creature_activity_event_id_fkey' and conrelid = 'private.world_creature_xp_transactions'::regclass) then
  alter table private.world_creature_xp_transactions add constraint world_creature_xp_transactions_creature_activity_event_id_fkey FOREIGN KEY (creature_activity_event_id) REFERENCES private.world_creature_activity_events(creature_activity_event_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_creature_xp_transactions_creature_id_fkey' and conrelid = 'private.world_creature_xp_transactions'::regclass) then
  alter table private.world_creature_xp_transactions add constraint world_creature_xp_transactions_creature_id_fkey FOREIGN KEY (creature_id) REFERENCES private.world_player_creatures(creature_id) ON DELETE CASCADE;
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_fishing_attempt_snapshots_attempt_id_fkey' and conrelid = 'private.world_fishing_attempt_snapshots'::regclass) then
  alter table private.world_fishing_attempt_snapshots add constraint world_fishing_attempt_snapshots_attempt_id_fkey FOREIGN KEY (attempt_id) REFERENCES private.world_activity_attempts(attempt_id) ON DELETE CASCADE;
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_fishing_spot_leases_attempt_id_fkey' and conrelid = 'private.world_fishing_spot_leases'::regclass) then
  alter table private.world_fishing_spot_leases add constraint world_fishing_spot_leases_attempt_id_fkey FOREIGN KEY (attempt_id) REFERENCES private.world_activity_attempts(attempt_id) ON DELETE CASCADE;
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_fishing_spot_leases_source_ref_fkey' and conrelid = 'private.world_fishing_spot_leases'::regclass) then
  alter table private.world_fishing_spot_leases add constraint world_fishing_spot_leases_source_ref_fkey FOREIGN KEY (source_ref) REFERENCES private.world_fishing_spots(source_ref);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_creature_activity_contexts_attempt_id_fkey' and conrelid = 'private.world_life_creature_activity_contexts'::regclass) then
  alter table private.world_life_creature_activity_contexts add constraint world_life_creature_activity_contexts_attempt_id_fkey FOREIGN KEY (attempt_id) REFERENCES private.world_activity_attempts(attempt_id) ON DELETE CASCADE;
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_creature_context_activity_fk' and conrelid = 'private.world_life_creature_activity_contexts'::regclass) then
  alter table private.world_life_creature_activity_contexts add constraint world_life_creature_context_activity_fk FOREIGN KEY (activity_id) REFERENCES private.world_life_creature_bridge_catalog(activity_id) ON DELETE RESTRICT;
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_creature_bridge_catalog_bridge_id_fkey' and conrelid = 'private.world_life_creature_bridge_catalog'::regclass) then
  alter table private.world_life_creature_bridge_catalog add constraint world_life_creature_bridge_catalog_bridge_id_fkey FOREIGN KEY (bridge_id) REFERENCES private.world_creature_activity_bridge_catalog(bridge_id) ON DELETE RESTRICT;
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_creature_bridge_catalog_life_skill_id_fkey' and conrelid = 'private.world_life_creature_bridge_catalog'::regclass) then
  alter table private.world_life_creature_bridge_catalog add constraint world_life_creature_bridge_catalog_life_skill_id_fkey FOREIGN KEY (life_skill_id) REFERENCES private.world_life_skill_catalog(skill_id) ON DELETE RESTRICT;
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_creature_bridge_deci_creature_activity_event_id_fkey' and conrelid = 'private.world_life_creature_bridge_decisions'::regclass) then
  alter table private.world_life_creature_bridge_decisions add constraint world_life_creature_bridge_deci_creature_activity_event_id_fkey FOREIGN KEY (creature_activity_event_id) REFERENCES private.world_creature_activity_events(creature_activity_event_id) ON DELETE RESTRICT;
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_creature_bridge_decisions_attempt_id_fkey' and conrelid = 'private.world_life_creature_bridge_decisions'::regclass) then
  alter table private.world_life_creature_bridge_decisions add constraint world_life_creature_bridge_decisions_attempt_id_fkey FOREIGN KEY (attempt_id) REFERENCES private.world_activity_attempts(attempt_id) ON DELETE CASCADE;
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_creature_bridge_decisions_bridge_id_fkey' and conrelid = 'private.world_life_creature_bridge_decisions'::regclass) then
  alter table private.world_life_creature_bridge_decisions add constraint world_life_creature_bridge_decisions_bridge_id_fkey FOREIGN KEY (bridge_id) REFERENCES private.world_life_creature_bridge_catalog(bridge_id) ON DELETE RESTRICT;
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_tree_catalog_skill_id_fkey' and conrelid = 'private.world_life_skill_tree_catalog'::regclass) then
  alter table private.world_life_skill_tree_catalog add constraint world_life_skill_tree_catalog_skill_id_fkey FOREIGN KEY (skill_id) REFERENCES private.world_life_skill_catalog(skill_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_skill_xp_transactions_user_id_skill_id_fkey' and conrelid = 'private.world_life_skill_xp_transactions'::regclass) then
  alter table private.world_life_skill_xp_transactions add constraint world_life_skill_xp_transactions_user_id_skill_id_fkey FOREIGN KEY (user_id, skill_id) REFERENCES private.world_player_life_skills(user_id, skill_id) ON DELETE CASCADE;
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_sp_transactions_node_id_fkey' and conrelid = 'private.world_life_sp_transactions'::regclass) then
  alter table private.world_life_sp_transactions add constraint world_life_sp_transactions_node_id_fkey FOREIGN KEY (node_id) REFERENCES private.world_life_skill_tree_catalog(node_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_sp_transactions_node_skill_fk' and conrelid = 'private.world_life_sp_transactions'::regclass) then
  alter table private.world_life_sp_transactions add constraint world_life_sp_transactions_node_skill_fk FOREIGN KEY (node_id, skill_id) REFERENCES private.world_life_skill_tree_catalog(node_id, skill_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_life_tree_resets_skill_id_fkey' and conrelid = 'private.world_life_tree_resets'::regclass) then
  alter table private.world_life_tree_resets add constraint world_life_tree_resets_skill_id_fkey FOREIGN KEY (skill_id) REFERENCES private.world_life_skill_catalog(skill_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_creatures_current_form_id_fkey' and conrelid = 'private.world_player_creatures'::regclass) then
  alter table private.world_player_creatures add constraint world_player_creatures_current_form_id_fkey FOREIGN KEY (current_form_id) REFERENCES private.world_creature_form_catalog(form_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_creatures_species_id_fkey' and conrelid = 'private.world_player_creatures'::regclass) then
  alter table private.world_player_creatures add constraint world_player_creatures_species_id_fkey FOREIGN KEY (species_id) REFERENCES private.world_creature_species_catalog(species_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_items_grant_id_fkey' and conrelid = 'private.world_player_items'::regclass) then
  alter table private.world_player_items add constraint world_player_items_grant_id_fkey FOREIGN KEY (grant_id) REFERENCES private.world_item_grants(grant_id) ON DELETE CASCADE;
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_life_nodes_node_id_fkey' and conrelid = 'private.world_player_life_nodes'::regclass) then
  alter table private.world_player_life_nodes add constraint world_player_life_nodes_node_id_fkey FOREIGN KEY (node_id) REFERENCES private.world_life_skill_tree_catalog(node_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'world_player_life_nodes_transaction_id_fkey' and conrelid = 'private.world_player_life_nodes'::regclass) then
  alter table private.world_player_life_nodes add constraint world_player_life_nodes_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES private.world_life_sp_transactions(transaction_id);
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'player_bests_best_run_id_fkey' and conrelid = 'public.player_bests'::regclass) then
  alter table public.player_bests add constraint player_bests_best_run_id_fkey FOREIGN KEY (best_run_id) REFERENCES ranked_runs(id) ON DELETE RESTRICT;
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'profiles_department_id_fkey' and conrelid = 'public.profiles'::regclass) then
  alter table public.profiles add constraint profiles_department_id_fkey FOREIGN KEY (department_id) REFERENCES departments(id) ON DELETE SET NULL;
end if; end $$;
do $$ begin if not exists (select 1 from pg_constraint where conname = 'ranked_runs_run_id_fkey' and conrelid = 'public.ranked_runs'::regclass) then
  alter table public.ranked_runs add constraint ranked_runs_run_id_fkey FOREIGN KEY (run_id) REFERENCES ranked_sessions(run_id) ON DELETE CASCADE;
end if; end $$;

-- ---- triggers ----
drop trigger if exists world_activity_attempt_guard on private.world_activity_attempts;
create trigger world_activity_attempt_guard BEFORE UPDATE ON private.world_activity_attempts FOR EACH ROW EXECUTE FUNCTION private.world_activity_attempt_guard_v1();
drop trigger if exists world_activity_settlement_append_only on private.world_activity_settlements;
create trigger world_activity_settlement_append_only BEFORE DELETE OR UPDATE ON private.world_activity_settlements FOR EACH ROW EXECUTE FUNCTION private.world_activity_settlement_append_only_v1();
drop trigger if exists world_collection_discovery_event_append_only on private.world_collection_discovery_events;
create trigger world_collection_discovery_event_append_only BEFORE UPDATE ON private.world_collection_discovery_events FOR EACH ROW EXECUTE FUNCTION private.world_collection_discovery_event_append_only_v1();
drop trigger if exists world_creature_acquisition_claim_append_only on private.world_creature_acquisition_claims;
create trigger world_creature_acquisition_claim_append_only BEFORE DELETE OR UPDATE ON private.world_creature_acquisition_claims FOR EACH ROW EXECUTE FUNCTION private.world_creature_append_only_v1();
drop trigger if exists world_creature_activity_append_only on private.world_creature_activity_events;
create trigger world_creature_activity_append_only BEFORE DELETE OR UPDATE ON private.world_creature_activity_events FOR EACH ROW EXECUTE FUNCTION private.world_creature_append_only_v1();
drop trigger if exists world_creature_observation_append_only on private.world_creature_observation_events;
create trigger world_creature_observation_append_only BEFORE DELETE OR UPDATE ON private.world_creature_observation_events FOR EACH ROW EXECUTE FUNCTION private.world_creature_append_only_v1();
drop trigger if exists world_creature_party_history_append_only on private.world_creature_party_history;
create trigger world_creature_party_history_append_only BEFORE DELETE OR UPDATE ON private.world_creature_party_history FOR EACH ROW EXECUTE FUNCTION private.world_creature_append_only_v1();
drop trigger if exists world_creature_xp_append_only on private.world_creature_xp_transactions;
create trigger world_creature_xp_append_only BEFORE DELETE OR UPDATE ON private.world_creature_xp_transactions FOR EACH ROW EXECUTE FUNCTION private.world_creature_append_only_v1();
drop trigger if exists world_fishing_snapshot_guard on private.world_fishing_attempt_snapshots;
create trigger world_fishing_snapshot_guard BEFORE UPDATE ON private.world_fishing_attempt_snapshots FOR EACH ROW EXECUTE FUNCTION private.world_fishing_snapshot_guard_v1();
drop trigger if exists world_item_grants_append_only on private.world_item_grants;
create trigger world_item_grants_append_only BEFORE UPDATE ON private.world_item_grants FOR EACH ROW EXECUTE FUNCTION private.world_item_grants_append_only_v1();
drop trigger if exists world_life_creature_context_append_only on private.world_life_creature_activity_contexts;
create trigger world_life_creature_context_append_only BEFORE DELETE OR UPDATE ON private.world_life_creature_activity_contexts FOR EACH ROW EXECUTE FUNCTION private.world_creature_append_only_v1();
drop trigger if exists world_life_creature_decision_append_only on private.world_life_creature_bridge_decisions;
create trigger world_life_creature_decision_append_only BEFORE DELETE OR UPDATE ON private.world_life_creature_bridge_decisions FOR EACH ROW EXECUTE FUNCTION private.world_creature_append_only_v1();
drop trigger if exists world_life_skill_threshold_immutable on private.world_life_skill_thresholds;
create trigger world_life_skill_threshold_immutable BEFORE DELETE OR UPDATE ON private.world_life_skill_thresholds FOR EACH ROW EXECUTE FUNCTION private.world_life_skill_threshold_immutable_v1();
drop trigger if exists world_life_skill_threshold_validate_insert on private.world_life_skill_thresholds;
create trigger world_life_skill_threshold_validate_insert BEFORE INSERT ON private.world_life_skill_thresholds FOR EACH ROW EXECUTE FUNCTION private.world_life_skill_threshold_validate_insert_v1();
drop trigger if exists world_life_tree_node_guard on private.world_life_skill_tree_catalog;
create trigger world_life_tree_node_guard BEFORE DELETE OR UPDATE ON private.world_life_skill_tree_catalog FOR EACH ROW EXECUTE FUNCTION private.world_life_tree_node_guard_v1();
drop trigger if exists world_life_skill_xp_append_only on private.world_life_skill_xp_transactions;
create trigger world_life_skill_xp_append_only BEFORE UPDATE ON private.world_life_skill_xp_transactions FOR EACH ROW EXECUTE FUNCTION private.world_life_skill_xp_append_only_v1();
drop trigger if exists world_life_sp_append_only on private.world_life_sp_transactions;
create trigger world_life_sp_append_only BEFORE DELETE OR UPDATE ON private.world_life_sp_transactions FOR EACH ROW EXECUTE FUNCTION private.world_life_sp_append_only_v1();
drop trigger if exists world_life_tree_resets_append_only on private.world_life_tree_resets;
create trigger world_life_tree_resets_append_only BEFORE DELETE OR UPDATE ON private.world_life_tree_resets FOR EACH ROW EXECUTE FUNCTION private.world_life_tree_resets_append_only_v1();
drop trigger if exists world_collection_projection_guard on private.world_player_collection_discoveries;
create trigger world_collection_projection_guard BEFORE UPDATE ON private.world_player_collection_discoveries FOR EACH ROW EXECUTE FUNCTION private.world_collection_projection_guard_v1();
drop trigger if exists world_life_nodes_append_only on private.world_player_life_nodes;
create trigger world_life_nodes_append_only BEFORE DELETE OR UPDATE ON private.world_player_life_nodes FOR EACH ROW EXECUTE FUNCTION private.world_life_nodes_append_only_v1();

-- ---- session reference checks (replace the original FOREIGN KEY ... REFERENCES auth.users) ----
drop trigger if exists tier3_session_ref on private.world_activity_attempts;
create trigger tier3_session_ref before insert or update of user_id on private.world_activity_attempts for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_activity_settlements;
create trigger tier3_session_ref before insert or update of user_id on private.world_activity_settlements for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_collection_discovery_events;
create trigger tier3_session_ref before insert or update of user_id on private.world_collection_discovery_events for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_creature_acquisition_claims;
create trigger tier3_session_ref before insert or update of user_id on private.world_creature_acquisition_claims for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_creature_activity_events;
create trigger tier3_session_ref before insert or update of user_id on private.world_creature_activity_events for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_creature_observation_events;
create trigger tier3_session_ref before insert or update of user_id on private.world_creature_observation_events for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_creature_party_history;
create trigger tier3_session_ref before insert or update of user_id on private.world_creature_party_history for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_creature_party_state;
create trigger tier3_session_ref before insert or update of user_id on private.world_creature_party_state for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_creature_xp_transactions;
create trigger tier3_session_ref before insert or update of user_id on private.world_creature_xp_transactions for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_fishing_attempt_snapshots;
create trigger tier3_session_ref before insert or update of user_id on private.world_fishing_attempt_snapshots for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_fishing_positions;
create trigger tier3_session_ref before insert or update of user_id on private.world_fishing_positions for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_fishing_spot_leases;
create trigger tier3_session_ref before insert or update of user_id on private.world_fishing_spot_leases for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_item_grants;
create trigger tier3_session_ref before insert or update of user_id on private.world_item_grants for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_life_creature_activity_contexts;
create trigger tier3_session_ref before insert or update of user_id on private.world_life_creature_activity_contexts for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_life_creature_bridge_decisions;
create trigger tier3_session_ref before insert or update of user_id on private.world_life_creature_bridge_decisions for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_life_sp_transactions;
create trigger tier3_session_ref before insert or update of user_id on private.world_life_sp_transactions for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_life_tree_resets;
create trigger tier3_session_ref before insert or update of user_id on private.world_life_tree_resets for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_player_collection_discoveries;
create trigger tier3_session_ref before insert or update of user_id on private.world_player_collection_discoveries for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_player_creatures;
create trigger tier3_session_ref before insert or update of user_id on private.world_player_creatures for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_player_items;
create trigger tier3_session_ref before insert or update of user_id on private.world_player_items for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_player_life_nodes;
create trigger tier3_session_ref before insert or update of user_id on private.world_player_life_nodes for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on private.world_player_life_skills;
create trigger tier3_session_ref before insert or update of user_id on private.world_player_life_skills for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on public.general_stage_bests;
create trigger tier3_session_ref before insert or update of user_id on public.general_stage_bests for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on public.inha_mail_badges;
create trigger tier3_session_ref before insert or update of user_id on public.inha_mail_badges for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on public.player_bests;
create trigger tier3_session_ref before insert or update of user_id on public.player_bests for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on public.profiles;
create trigger tier3_session_ref before insert or update of user_id on public.profiles for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on public.ranked_recovery_eligibility;
create trigger tier3_session_ref before insert or update of user_id on public.ranked_recovery_eligibility for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on public.ranked_recovery_records;
create trigger tier3_session_ref before insert or update of user_id on public.ranked_recovery_records for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL
drop trigger if exists tier3_session_ref on public.ranked_runs;
create trigger tier3_session_ref before insert or update of user_id on public.ranked_runs for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on public.ranked_sessions;
create trigger tier3_session_ref before insert or update of user_id on public.ranked_sessions for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
drop trigger if exists tier3_session_ref on public.user_achievements;
create trigger tier3_session_ref before insert or update of user_id on public.user_achievements for each row execute function private.tier3_require_session_v1();  -- was: FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE

-- ===========================================================================
-- Least privilege. `inha_world_tier3_app` is a NOLOGIN group role, created inside
-- a DO block (a role created through the Neon API has no ADMIN OPTION, so the
-- owner could not grant it to itself for the oracle). Create the login role the
-- Worker connects as in the Neon console (its password never goes in a file), then:
--   grant inha_world_tier3_app to <that login role>;
-- The Worker role can: check that a session exists, read a profile's ban flag,
-- create / advance ranked sessions, store a rejected run, and call the RPCs its
-- handlers use. It cannot read or write any other table, and cannot call
-- claim_inha_mail_badge (the handler is 501) or world_collection_discover_v1 (no
-- handler calls it). It CAN call world_fishing_observe_position_v1: POST
-- /api/fishing-position relays a browser-reported position to it. That position
-- is client-reported and can be spoofed; it is not the trusted-producer evidence
-- the original F3 design asked for (see README).
-- ===========================================================================
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'inha_world_tier3_app') then
    create role inha_world_tier3_app nologin;
  end if;
end;
$$;

revoke all on table
  private.inha_mail_verified_mailboxes,
  private.world_activity_attempts,
  private.world_activity_settlements,
  private.world_collection_discovery_events,
  private.world_collection_entry_catalog,
  private.world_creature_acquisition_claims,
  private.world_creature_acquisition_rule_catalog,
  private.world_creature_activity_bridge_catalog,
  private.world_creature_activity_events,
  private.world_creature_form_catalog,
  private.world_creature_memory_tags,
  private.world_creature_observation_events,
  private.world_creature_party_history,
  private.world_creature_party_state,
  private.world_creature_species_catalog,
  private.world_creature_xp_transactions,
  private.world_fishing_attempt_snapshots,
  private.world_fishing_positions,
  private.world_fishing_runtime,
  private.world_fishing_spot_leases,
  private.world_fishing_spots,
  private.world_inkyung_duck_observation_subjects,
  private.world_item_catalog,
  private.world_item_grants,
  private.world_life_creature_activity_contexts,
  private.world_life_creature_bridge_catalog,
  private.world_life_creature_bridge_decisions,
  private.world_life_skill_catalog,
  private.world_life_skill_thresholds,
  private.world_life_skill_tree_catalog,
  private.world_life_skill_xp_transactions,
  private.world_life_sp_transactions,
  private.world_life_tree_resets,
  private.world_player_collection_discoveries,
  private.world_player_creatures,
  private.world_player_items,
  private.world_player_life_nodes,
  private.world_player_life_skills,
  public.departments,
  public.general_stage_bests,
  public.inha_mail_badges,
  public.player_bests,
  public.profiles,
  public.ranked_recovery_eligibility,
  public.ranked_recovery_records,
  public.ranked_runs,
  public.ranked_sessions,
  public.user_achievements
  from public, inha_world_tier3_app;

revoke all on function
  private.tier3_require_session_v1(),
  private.world_activity_account_ok_v1(uuid),
  private.world_activity_attempt_guard_v1(),
  private.world_activity_attempt_json_v1(private.world_activity_attempts),
  private.world_activity_finalize_v1(uuid, uuid, text, text, text),
  private.world_activity_settle_v1(uuid, uuid, jsonb),
  private.world_activity_settlement_append_only_v1(),
  private.world_activity_settlement_plan_validate_v1(jsonb),
  private.world_activity_start_v1(uuid, text, text, uuid, integer, integer, timestamp with time zone),
  private.world_activity_validate_identity_v1(text, text, integer, integer),
  private.world_collection_account_ok_v1(uuid),
  private.world_collection_discover_v1(uuid, text, text, text, text, text, jsonb),
  private.world_collection_discovery_event_append_only_v1(),
  private.world_collection_discovery_result_v1(private.world_collection_discovery_events, text),
  private.world_collection_entry_snapshot_v1(uuid, private.world_collection_entry_catalog),
  private.world_collection_list_v1(uuid),
  private.world_collection_projection_guard_v1(),
  private.world_collection_projection_json_v1(private.world_player_collection_discoveries),
  private.world_creature_account_ok_v1(uuid),
  private.world_creature_activity_accept_v1(uuid, text, text, text, text, bigint, timestamp with time zone),
  private.world_creature_activity_event_json_v1(private.world_creature_activity_events),
  private.world_creature_append_only_v1(),
  private.world_creature_instance_json_v1(private.world_player_creatures),
  private.world_creature_observe_v1(uuid, text, text, text, text, text),
  private.world_creature_owned_by_v1(uuid, uuid),
  private.world_creature_party_snapshot_v1(uuid),
  private.world_duck_companion_status_v1(uuid),
  private.world_fishing_apply_skill_effects_v1(jsonb, jsonb),
  private.world_fishing_commit_v1(uuid, uuid, jsonb),
  private.world_fishing_expire_v1(uuid, jsonb),
  private.world_fishing_finish_v1(jsonb, text, text, text, bigint),
  private.world_fishing_policy_validate_v1(jsonb),
  private.world_fishing_project_v1(jsonb),
  private.world_fishing_require_position_v1(uuid, text),
  private.world_fishing_require_server_v1(uuid),
  private.world_fishing_resolve_v1(jsonb, text, bigint),
  private.world_fishing_skill_effects_v1(uuid),
  private.world_fishing_snapshot_guard_v1(),
  private.world_inkyung_duck_observe_v1(uuid, text, text, text),
  private.world_inventory_account_ok_v1(uuid),
  private.world_inventory_grant_result_v1(private.world_item_grants, text, timestamp with time zone),
  private.world_inventory_grant_v1(uuid, text, integer, text, text, text, text, jsonb),
  private.world_item_grants_append_only_v1(),
  private.world_life_activity_finalize_with_creature_v1(uuid, uuid, text, text, text),
  private.world_life_activity_start_with_creature_v1(uuid, text, text, uuid, integer, integer, timestamp with time zone),
  private.world_life_creature_context_bind_v1(uuid, uuid),
  private.world_life_creature_context_json_v1(private.world_life_creature_activity_contexts),
  private.world_life_node_rank_v1(uuid, text),
  private.world_life_nodes_append_only_v1(),
  private.world_life_skill_account_ok_v1(uuid),
  private.world_life_skill_level_for_xp_v1(text, bigint),
  private.world_life_skill_snapshot_v1(uuid, text),
  private.world_life_skill_threshold_immutable_v1(),
  private.world_life_skill_threshold_validate_insert_v1(),
  private.world_life_skill_xp_append_only_v1(),
  private.world_life_skill_xp_apply_v1(uuid, text, bigint, text, text, text),
  private.world_life_skill_xp_result_v1(private.world_life_skill_xp_transactions, text),
  private.world_life_sp_append_only_v1(),
  private.world_life_tree_epoch_v1(uuid, text),
  private.world_life_tree_node_guard_v1(),
  private.world_life_tree_resets_append_only_v1(),
  public.claim_inha_mail_badge(uuid, uuid),
  public.expire_ranked_sessions_v1(),
  public.general_badge_code(integer, integer),
  public.get_my_rank_v3(uuid),
  public.is_inha_mail(text),
  public.ranked_grade_code(integer, integer, integer, integer, integer),
  public.ranked_grade_code_v5(integer, integer, integer, integer, integer),
  public.record_ranked_result_v4(uuid, uuid, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, text, integer, integer, integer, boolean, text[]),
  public.record_ranked_result_v5(uuid, uuid, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, text, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, boolean, text[]),
  public.world_collection_discover_v1(uuid, text, text, text, text, text, jsonb),
  public.world_collection_list_v1(uuid),
  public.world_fishing_input_v1(uuid, uuid, text, uuid, text),
  public.world_fishing_observe_position_v1(uuid, uuid, bigint, double precision, double precision, double precision, text, text, timestamp with time zone),
  public.world_fishing_read_v1(uuid, uuid),
  public.world_fishing_settle_v1(uuid, uuid),
  public.world_fishing_start_v1(uuid, text, uuid),
  public.world_inkyung_duck_observe_v1(uuid, text, text, text)
  from public, inha_world_tier3_app;

grant usage on schema public to inha_world_tier3_app;
grant select (id) on table public.sessions to inha_world_tier3_app;
grant select (user_id, is_banned) on table public.profiles to inha_world_tier3_app;
grant select, insert, update on table public.ranked_sessions to inha_world_tier3_app;
grant insert on table public.ranked_runs to inha_world_tier3_app;

grant execute on function
  public.world_collection_list_v1(uuid),
  public.world_fishing_start_v1(uuid,text,uuid),
  public.world_fishing_input_v1(uuid,uuid,text,uuid,text),
  public.world_fishing_settle_v1(uuid,uuid),
  public.world_fishing_read_v1(uuid,uuid),
  public.world_inkyung_duck_observe_v1(uuid,text,text,text),
  public.expire_ranked_sessions_v1(),
  public.record_ranked_result_v4(uuid,uuid,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,text,integer,integer,integer,boolean,text[]),
  public.record_ranked_result_v5(uuid,uuid,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,text,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,boolean,text[]),
  public.get_my_rank_v3(uuid),
  public.world_fishing_observe_position_v1(uuid,uuid,bigint,double precision,double precision,double precision,text,text,timestamp with time zone)
  to inha_world_tier3_app;

