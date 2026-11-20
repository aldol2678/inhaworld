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
