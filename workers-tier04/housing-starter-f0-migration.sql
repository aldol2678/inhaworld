-- ============================================================================
-- Housing starter grant — reward.housing.starter_f0 (2026-11-25)
-- 알돌 결정: 스타터 가구 지급으로 간다 (상점가 인하 / LOCKED 해제 아님).
--
-- 배경: 신규 유저는 어떤 경로로도 가구를 얻을 수 없었다.
--   - 가구 카탈로그 17종 전부 COMING_SOON, 상점 최하 220코인 vs 신규 지갑 0코인
--     (첫날 최대 60코인), 스타터 7종 중 소파·학습서 세트는 LOCKED 상점 리스팅.
--   - 시드 없는 첫 저장 프로브는 409 ITEM_NOT_OWNED로 실패 (포트 버그 아님).
--
-- 설계 (기존 보상 시스템 재사용, 신규 권한·신규 테이블 없음):
--   1. 보상 정의 reward.housing.starter_f0 (ACTIVE, v1) + ITEM 지급 7행.
--   2. get_or_create_my_personal_room_v1() 안에서 첫 방 확보 시 지급 호출.
--      - 멱등키 'housing-starter:<uid>' — world_reward_grant_v1이 동일 키를
--        재생(replay)만 하고 재지급하지 않음. UNIQUE 아이템은 재호출 시
--        ALREADY_OWNED라 중복 지급 불가.
--      - 매 입장 호출이라 기존 방 소유자도 다음 입장 때 소급 지급됨.
--        별도 백필 마이그레이션 불필요.
--      - ACTIVE 정의가 없을 때(롤아웃 순서 꼬임)는 지급을 건너뛰고 방만 연다.
--        방 열기가 보상 정의 유무에 막히면 안 됨.
--   3. 카탈로그 상태는 건드리지 않음: world_inventory_grant_v1은
--      DISABLED/HIDDEN만 막고 COMING_SOON은 지급 가능. 저장 검증
--      (validate_world_room_furniture_v1)은 보유 수량만 보고 상태는 안 봄.
--      소파(480)·학습서 세트(120) LOCKED 리스팅도 그대로 둠 — UNIQUE라
--      지급받은 뒤 상점에서 중복 구매될 수 없음.
--
-- 적용 순서 (반드시 이 순서):
--   1. 스테이징 Neon에 적용 → 2. 신규 계정 방 첫 입장 시 7종 보유 확인 +
--      7종 전부 배치 저장 성공 + 재입장 시 중복 지급 없음 확인
--      + 기존 방 소유자(모아8699 등 테스트 계정) 소급 지급 확인
--      → 3. 라이브 적용 (Worker 재배포 불필요 — DB 함수·정의만 바뀜)
--   롤백: 보상 정의 status를 DISABLED로 바꾸면 신규 지급만 멈춤.
--   이미 지급된 아이템은 회수되지 않음 (의도된 동작).
-- ============================================================================

-- 1. 보상 정의 ---------------------------------------------------------------
insert into private.world_reward_definitions
  (reward_id, description, event_id, status, tags, version)
values
  ('reward.housing.starter_f0', '개인 방 첫 입장 스타터 가구 7종 지급',
   null, 'ACTIVE', array['housing', 'starter']::text[], 1)
on conflict (reward_id) do nothing;

-- 2. 지급 7행 (UNIQUE라 amount는 반드시 1 — validate 트리거가 강제) --------
insert into private.world_reward_grants
  (reward_id, grant_entry_id, grant_type, target_id, amount, position)
values
  ('reward.housing.starter_f0', 'item.furniture.dorm_single_sofa',  'ITEM', 'furniture.dorm_single_sofa',  1, 0),
  ('reward.housing.starter_f0', 'item.furniture.dorm_side_table_low','ITEM', 'furniture.dorm_side_table_low',1, 1),
  ('reward.housing.starter_f0', 'item.furniture.dorm_bookshelf_slim','ITEM', 'furniture.dorm_bookshelf_slim',1, 2),
  ('reward.housing.starter_f0', 'item.furniture.dorm_plant_medium',  'ITEM', 'furniture.dorm_plant_medium',  1, 3),
  ('reward.housing.starter_f0', 'item.furniture.dorm_monitor',       'ITEM', 'furniture.dorm_monitor',       1, 4),
  ('reward.housing.starter_f0', 'item.furniture.dorm_trophy_shelf',  'ITEM', 'furniture.dorm_trophy_shelf',  1, 5),
  ('reward.housing.starter_f0', 'item.furniture.study_books_set',    'ITEM', 'furniture.study_books_set',    1, 6)
on conflict do nothing;

-- 3. 방 확보 시 지급 훅 --------------------------------------------------------
--    원본과 달라진 부분은 지급 블록(주석 포함)뿐. 나머지 본문은 동일.
create or replace function public.get_or_create_my_personal_room_v1(p_user uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_uid uuid := private.world_room_caller_v1(p_user);
  v_room public.world_player_rooms%rowtype;
  v_grant jsonb;
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

  -- Housing starter F0: grant the 7 starter furniture items once per account.
  -- Idempotent via 'housing-starter:<uid>'; replays never re-grant (UNIQUE items
  -- return ALREADY_OWNED). Existing room owners are covered on next entry.
  -- Guarded so a missing/inactive reward never blocks opening the room.
  if exists (select 1 from private.world_reward_definitions d
              where d.reward_id = 'reward.housing.starter_f0' and d.status = 'ACTIVE') then
    v_grant := private.world_reward_grant_v1(
      v_uid, 'reward.housing.starter_f0', 'SYSTEM', 'housing.starter_f0',
      'housing-starter:' || v_uid::text);
  end if;

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

-- 4. 적용 후 검증 (불일치 시 즉시 실패 — 조용히 넘어가지 않음) --------------
do $$
begin
  if (select count(*) from private.world_reward_definitions
       where reward_id = 'reward.housing.starter_f0' and status = 'ACTIVE'
         and version = 1) <> 1 then
    raise exception 'STARTER_REWARD_DEFINITION_MISMATCH';
  end if;
  if (select count(*) from private.world_reward_grants
       where reward_id = 'reward.housing.starter_f0' and grant_type = 'ITEM'
         and amount = 1) <> 7 then
    raise exception 'STARTER_REWARD_GRANTS_MISMATCH';
  end if;
  if (select count(distinct position) from private.world_reward_grants
       where reward_id = 'reward.housing.starter_f0') <> 7 then
    raise exception 'STARTER_REWARD_POSITION_MISMATCH';
  end if;
  if (select count(*) from private.world_reward_grants g
       join private.world_item_catalog c on c.item_id = g.target_id
       where g.reward_id = 'reward.housing.starter_f0'
         and c.category = 'FURNITURE' and c.ownership_policy = 'UNIQUE') <> 7 then
    raise exception 'STARTER_REWARD_CATALOG_MISMATCH';
  end if;
end;
$$;
