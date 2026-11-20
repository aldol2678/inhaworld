-- Fix #1374: pass 1 created touch with parameter defaults (old file);
-- CREATE OR REPLACE cannot remove defaults, so drop + recreate.
drop function if exists public.touch_world_online_session_v2(uuid, uuid, text, text);
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
grant execute on function public.touch_world_online_session_v2(uuid, uuid, text, text) to inha_world_tier4_writes_app;
revoke all on function public.touch_world_online_session_v2(uuid, uuid, text, text) from public;
