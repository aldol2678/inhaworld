-- INHA WORLD — Tier 2 telemetry schema for Neon (Postgres 16+).
-- New schema file on purpose: the v0.1 schema (sessions / guestbook / progress)
-- is untouched, and this file must only ever be applied to an ISOLATED Neon
-- branch until the owner approves a cutover. Never apply it to the live
-- `inha-world-sync` database as part of this tier's verification.
--
-- Port of (aldol2678/inhagame HEAD 0b72d259, read-only):
--   public.inhagame_hub_events            -> hub_events + game_entries
--   public.log_inhagame_hub_event_v2      -> log_hub_event_v2
--   public.log_inhagame_game_entry_v1     -> log_game_entry_v1
--   public.world_runtime_flags            -> runtime_flags
-- Sources: 20261001213132_public_baseline.sql,
--          20261002120000_core15_activation_funnel_contract_v2.sql,
--          20261003072000_world_asset_canary_remote_control.sql.
--
-- The original keeps hub events and game-entry stages in ONE table, told apart
-- by entry_id. Here they are two tables; `hub_events_all` re-joins them in the
-- original row shape for the OPS queries that are not ported yet.
--
-- Idempotent: safe to re-run. No secrets, no role passwords.

-- ---------------------------------------------------------------------------
-- hub_events: rows written by POST /api/hub-event (original: entry_id is null)
-- ---------------------------------------------------------------------------
create table if not exists public.hub_events (
  event_id uuid primary key,
  session_id uuid not null,
  visitor_id uuid not null,
  event_type text not null,
  surface text not null,
  target text,
  acquisition_source text not null default 'unknown',
  campaign text,
  created_at timestamptz not null default now(),
  constraint hub_events_event_type_check check (
    event_type in (
      'hub_visit','hub_panel_view','hub_game_click','campus_entry_click',
      'campus_boot_ready','campus_boot_error','campus_zone_enter','hub_card_impression',
      'profile_view','profile_edit_open','profile_edit_save','profile_game_click',
      'first_session_start','first_goal_seen','first_move','first_zone_arrival','first_npc_interaction',
      'quest_started','first_player_encounter','first_activity_start','first_activity_complete',
      'first_reward','reward_seen','growth_seen','core_loop_complete','next_goal_seen',
      'core15_complete','world_return','next_discovery_click',
      'asset_canary_selected','asset_canary_active','asset_canary_rollback','asset_canary_failure'
    )
  ),
  constraint hub_events_surface_check check (
    surface in ('home','ranking','friends','messages','account','settings','campus','profile')
  ),
  constraint hub_events_target_check check (
    target is null or target in (
      'classic','induckup','survival','campus','induck-grow',
      'C01_GATE','C02_MAIN_HALL','C03_CENTRAL',
      'inkyung_living','first_campus','main2_back_gate_guide',
      'induck_v3'
    )
  ),
  constraint hub_events_acquisition_source_check check (
    acquisition_source in ('direct','everytime','internal','external','unknown')
  ),
  constraint hub_events_campaign_check check (
    campaign is null or campaign ~ '^[a-z0-9][a-z0-9_-]{0,63}$'
  ),
  -- Two-valued on purpose (coalesce ... false): a NULL target on a target-bound
  -- event must be rejected; a bare NULL would satisfy CHECK.
  constraint hub_events_context_check check (
    coalesce(
      (event_type='hub_visit' and surface='home' and target is null)
      or (event_type='hub_panel_view' and surface in ('home','ranking','friends','messages','account','settings') and target is null)
      or (event_type='hub_game_click' and surface in ('home','ranking','account') and target in ('classic','induckup','survival','induck-grow'))
      or (event_type='campus_entry_click' and surface='home' and target='campus')
      or (event_type='hub_card_impression' and surface='home' and target in ('classic','induckup','survival','campus','induck-grow'))
      or (event_type in ('campus_boot_ready','campus_boot_error') and surface='campus' and target is null)
      or (event_type='campus_zone_enter' and surface='campus' and target in ('C01_GATE','C02_MAIN_HALL','C03_CENTRAL'))
      or (event_type in ('profile_view','profile_edit_open','profile_edit_save') and surface='profile' and target is null)
      or (event_type='profile_game_click' and surface='profile' and target in ('classic','induckup','survival','campus','induck-grow'))
      or (event_type in ('first_session_start','first_move','first_zone_arrival','first_npc_interaction','first_player_encounter','world_return')
          and surface='campus' and target is null)
      or (event_type in ('first_activity_start','first_activity_complete')
          and surface='campus' and target='inkyung_living')
      or (event_type in ('first_goal_seen','quest_started','first_reward','reward_seen','growth_seen','core_loop_complete','core15_complete')
          and surface='campus' and target='first_campus')
      or (event_type in ('next_goal_seen','next_discovery_click')
          and surface='campus' and target='main2_back_gate_guide')
      or (event_type in ('asset_canary_selected','asset_canary_active','asset_canary_rollback','asset_canary_failure')
          and surface='campus' and target='induck_v3')
    , false)
  )
);

create index if not exists hub_events_session_idx
  on public.hub_events (session_id, created_at desc);
create index if not exists hub_events_created_idx
  on public.hub_events (created_at desc);

-- ---------------------------------------------------------------------------
-- game_entries: rows written by POST /api/hub-entry (original: entry_id is not
-- null, surface='game'). entry_id is the event_id of the hub click that sent
-- the player to the game; session / visitor / acquisition are copied from it.
-- event_id is the primary key (UNIQUE). A resent event_id is NOT a 409: like
-- the original it is accepted without effect (idempotent). 409 means the RPC
-- refused the stage (no fresh click, wrong game, stage out of order).
-- ---------------------------------------------------------------------------
create table if not exists public.game_entries (
  event_id uuid primary key,
  entry_id uuid not null,
  session_id uuid not null,
  visitor_id uuid not null,
  event_type text not null,
  target text not null,
  acquisition_source text not null default 'unknown',
  campaign text,
  created_at timestamptz not null default now(),
  constraint game_entries_event_type_check check (
    event_type in (
      'game_landing','game_play_start','game_load_error','game_first_result',
      'game_first_clear','game_retry','classic_ranked_start'
    )
  ),
  constraint game_entries_target_check check (
    target in ('classic','induckup','survival','campus','induck-grow')
  ),
  constraint game_entries_ranked_target_check check (
    event_type <> 'classic_ranked_start' or target = 'classic'
  ),
  constraint game_entries_acquisition_source_check check (
    acquisition_source in ('direct','everytime','internal','external','unknown')
  ),
  constraint game_entries_campaign_check check (
    campaign is null or campaign ~ '^[a-z0-9][a-z0-9_-]{0,63}$'
  ),
  -- one row per stage per entry (original: inhagame_hub_entry_stage_unique)
  constraint game_entries_stage_unique unique (entry_id, event_type)
);

create index if not exists game_entries_session_idx
  on public.game_entries (session_id, created_at desc);
create index if not exists game_entries_created_idx
  on public.game_entries (created_at desc);

-- Original single-table row shape, for OPS / retention queries ported later.
create or replace view public.hub_events_all as
  select event_id, session_id, visitor_id, event_type, surface, target,
         created_at, null::uuid as entry_id, acquisition_source, campaign
    from public.hub_events
  union all
  select event_id, session_id, visitor_id, event_type, 'game'::text as surface, target,
         created_at, entry_id, acquisition_source, campaign
    from public.game_entries;

-- ---------------------------------------------------------------------------
-- runtime_flags: read by GET /api/asset-canary-flag. Default disabled, exactly
-- like the original migration; the Worker role can only read it.
-- ---------------------------------------------------------------------------
create table if not exists public.runtime_flags (
  flag text primary key,
  enabled boolean not null default false,
  updated_at timestamptz not null default now(),
  constraint runtime_flags_flag_check check (flag in ('asset_glb_canary_v1'))
);

insert into public.runtime_flags (flag, enabled)
values ('asset_glb_canary_v1', false)
on conflict (flag) do nothing;

-- ---------------------------------------------------------------------------
-- log_hub_event_v2: port of public.log_inhagame_hub_event_v2.
-- true  -> stored, or already stored (same event_id resent)     -> HTTP 204
-- false -> refused (vocabulary, context check, 120/hour limit)  -> HTTP 400
-- ---------------------------------------------------------------------------
create or replace function public.log_hub_event_v2(
  p_event_id uuid,
  p_session_id uuid,
  p_visitor_id uuid,
  p_event_type text,
  p_surface text,
  p_target text default null,
  p_acquisition_source text default 'unknown',
  p_campaign text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_event_id is null or p_session_id is null or p_visitor_id is null
     or p_event_type is null or p_event_type not in (
       'hub_visit','hub_panel_view','hub_game_click','campus_entry_click',
       'campus_boot_ready','campus_boot_error','campus_zone_enter','hub_card_impression',
       'profile_view','profile_edit_open','profile_edit_save','profile_game_click',
       'first_session_start','first_goal_seen','first_move','first_zone_arrival','first_npc_interaction',
       'quest_started','first_player_encounter','first_activity_start','first_activity_complete',
       'first_reward','reward_seen','growth_seen','core_loop_complete','next_goal_seen',
       'core15_complete','world_return','next_discovery_click',
       'asset_canary_selected','asset_canary_active','asset_canary_rollback','asset_canary_failure'
     )
     or p_acquisition_source not in ('direct','everytime','internal','external','unknown')
     or (p_campaign is not null and p_campaign !~ '^[a-z0-9][a-z0-9_-]{0,63}$')
     -- per-session limit counts hub events AND game stages, as the single
     -- original table did
     or (
       (select count(*) from public.hub_events
         where session_id = p_session_id and created_at > now() - interval '1 hour')
       + (select count(*) from public.game_entries
         where session_id = p_session_id and created_at > now() - interval '1 hour')
     ) >= 120
  then return false; end if;

  -- event_id was unique across both kinds of row in the original table
  if exists (select 1 from public.game_entries where event_id = p_event_id) then
    return true;
  end if;

  insert into public.hub_events(
    event_id, session_id, visitor_id, event_type, surface, target, acquisition_source, campaign
  )
  values(
    p_event_id, p_session_id, p_visitor_id, p_event_type, p_surface, p_target,
    p_acquisition_source, p_campaign
  )
  on conflict (event_id) do nothing;
  return true;
exception when check_violation or foreign_key_violation then return false;
end;
$$;

-- ---------------------------------------------------------------------------
-- log_game_entry_v1: port of public.log_inhagame_game_entry_v1.
-- true  -> stored, or duplicate event_id / duplicate stage (no effect) -> 204
-- false -> refused: no hub click for this target in the last 30 minutes,
--          or the previous stage is not stored yet                      -> 409
-- ---------------------------------------------------------------------------
create or replace function public.log_game_entry_v1(
  p_event_id uuid,
  p_entry_id uuid,
  p_event_type text,
  p_target text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v_click public.hub_events%rowtype;
begin
  if p_event_id is null or p_entry_id is null
     or p_event_type not in (
       'game_landing','game_play_start','game_load_error',
       'game_first_result','game_first_clear','game_retry','classic_ranked_start'
     )
     or p_target not in ('classic','induckup','survival','campus','induck-grow')
     or (p_event_type = 'classic_ranked_start' and p_target <> 'classic')
  then return false; end if;

  select * into v_click from public.hub_events
  where event_id = p_entry_id
    and event_type in ('hub_game_click','campus_entry_click','profile_game_click')
    and target = p_target
    and created_at > now() - interval '30 minutes';
  if not found then return false; end if;

  if p_event_type = 'game_play_start' and not exists (
      select 1 from public.game_entries
      where entry_id = p_entry_id and event_type = 'game_landing'
    ) then return false;
  elsif p_event_type = 'classic_ranked_start' and not exists (
      select 1 from public.game_entries
      where entry_id = p_entry_id and event_type = 'game_landing'
    ) then return false;
  elsif p_event_type = 'game_first_result' and not exists (
      select 1 from public.game_entries
      where entry_id = p_entry_id and event_type = 'game_play_start'
    ) then return false;
  elsif p_event_type in ('game_first_clear','game_retry') and not exists (
      select 1 from public.game_entries
      where entry_id = p_entry_id and event_type = 'game_first_result'
    ) then return false;
  end if;

  -- event_id was unique across both kinds of row in the original table
  if exists (select 1 from public.hub_events where event_id = p_event_id) then
    return true;
  end if;

  insert into public.game_entries(
    event_id, entry_id, session_id, visitor_id, event_type, target,
    acquisition_source, campaign
  )
  values (
    p_event_id, p_entry_id, v_click.session_id, v_click.visitor_id, p_event_type, p_target,
    v_click.acquisition_source, v_click.campaign
  )
  on conflict do nothing;
  return true;
exception when check_violation or foreign_key_violation then return false;
end;
$$;

-- ---------------------------------------------------------------------------
-- Least privilege, mirroring the original anon surface: the Worker may call
-- the two logging functions and read runtime_flags, and nothing else (it can
-- neither read nor write the event tables directly, nor change a flag).
-- `inha_world_tier2_app` is a NOLOGIN group role. Create the login role the
-- Worker connects as in the Neon console (its password never goes in a file),
-- then:  grant inha_world_tier2_app to <that login role>;
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'inha_world_tier2_app') then
    create role inha_world_tier2_app nologin;
  end if;
end;
$$;

revoke all on table public.hub_events, public.game_entries, public.hub_events_all,
  public.runtime_flags from public, inha_world_tier2_app;
grant select on table public.runtime_flags to inha_world_tier2_app;

revoke all on function public.log_hub_event_v2(uuid,uuid,uuid,text,text,text,text,text) from public;
revoke all on function public.log_game_entry_v1(uuid,uuid,text,text) from public;
grant execute on function public.log_hub_event_v2(uuid,uuid,uuid,text,text,text,text,text)
  to inha_world_tier2_app;
grant execute on function public.log_game_entry_v1(uuid,uuid,text,text)
  to inha_world_tier2_app;
