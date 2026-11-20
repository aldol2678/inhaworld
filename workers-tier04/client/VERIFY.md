# VERIFY.md — Tier 4 A-1 읽기 전용 클라이언트 검증 기록

날짜: 2026-11-13. 작업자: 모아(서브에이전트).
원본: `~/workspace/inha-world-static-test/src` (읽기 전용 스냅샷).
라이브(inhagame.app, 라이브 Neon main, 라이브 Worker, 원본 레포
aldol2678/inhagame)는 건드리지 않았다.

## 0. 범위·전제

- **격리 실측을 하지 않았다 (의도적).** Tier 4 Worker가 아직 배포 전이라
  단위 테스트까지만 했다. 실측은 부모가 Worker 배포 후 한다.
  아래 "남은 실측" 항목 참조.
- Worker 엔드포인트 계약(8개 GET)은 과제에서 준 그대로 구현했다.
  staff-badges의 `ids`는 쿼리 파라미터(콤마 연결), JSON 본문 폴백 없음.
  shop의 `shop_id`도 쿼리 파라미터다.

## 1. 스냅샷 원본 md5 (작업 전후 동일)

작업 전 `/tmp/tier04-orig-md5.txt`에 기록하고, 모든 작업이 끝난 뒤
`md5sum -c`로 재확인했다. 13개 파일 전부 OK.

| 파일 | md5 |
|---|---|
| `inventory/inventory-client.js` | e4132c543aab19378fe1eeacfd8b99cb |
| `inventory/inventory-acquisition-client.js` | d542f8212d6db5d663e5cea235b8147c |
| `wallet/wallet-client.js` | 89ca66aff5d8a1314d7814dfb74db511 |
| `progression/progression-client.js` | 5a4f83a31fbb7eca6d4017ab138d7f88 |
| `appearance/loadout-client.js` | 7442e7aad1441ae3736d9d9b426593f3 |
| `shop/shop-client.js` | 1da3b51116c9bb7fa80777501437a10c |
| `shop/shop-capabilities.js` | 3c4d4bba228b019bc47bd9bfaf154d2b |
| `shop/shop-router.js` | 4d9cde7b5da7a645c435d64a0ca57fde |
| `staff-badges.js` | 5af4f332d63da2f962fe4da80ef57604 |
| `phone/student-id.js` | 8529e5aa36ae83816a70ded08c7b2f33 |
| `main.js` | b0d837a3a154e2238c17b660e5f60589 |
| `online/world-online.js` | a1c12a4a9c0f1fe228f90d5d87f1e0b4 |
| `phone/smartphone.js` | 1baf7fda2ee43f1033b6d1714640c231 |

## 2. 단위 테스트 (`node test-clients.mjs`)

스텁 fetch만 사용, 네트워크 없음. **22개 전부 통과** (pass 22, fail 0).

| 테스트 | 확인한 것 |
|---|---|
| inventory: X-Session-Id 발송 + READY/SIGNED_OUT | 헤더 1건, `Authorization` 없음, `setAccount(게스트)` → READY, `setAccount(null)` → SIGNED_OUT |
| inventory: 세션 없음 | 전송 0건, UNAVAILABLE |
| inventory: 401 | UNAVAILABLE, 스냅샷 null |
| wallet: 헤더 + 잔액 | `balance()` 120, 헤더 1건 |
| wallet: 403 | UNAVAILABLE |
| wallet: 보상 재시도 유지 | `daily-reward-recovery` 실패 → 재시도 타이머 1개 → 다음 읽기 성공 시 READY |
| progression: 헤더 + 파싱 | level 3, totalExp 1500 |
| progression: 세션 없음 0건 + 401 | 전송 0건(세션 없음), 401 → UNAVAILABLE |
| loadout: 읽기 헤더 + 9슬롯 파싱 | HEAD 장착 확인, BODY null |
| loadout: 세션 없음 + equip inert | 전송 0건, `equip` → SIGNED_OUT + PERMANENT_ACCOUNT_REQUIRED |
| shop: 헤더 + shop_id 쿼리 | `shop_id=shop.student_center`, offers 1건 |
| shop: shop_id 누락 400 | UNAVAILABLE, 폴백 id 없음 |
| shop: 세션 없음 + 403 + purchase inert | 전송 0건, 403 → UNAVAILABLE, `purchase` → SIGNED_OUT |
| shop-capabilities: split/404/401/세션 없음 | split 파싱, 404 → legacy 폴백, 401 → null, 세션 없음 → null·0건 |
| shop-router: 협상 + 읽기 | capabilities 1건 + shop 1건, mode split, READY, `setAccount(null)` → SIGNED_OUT |
| inventory-acquisition: legacy 2개 상점 | `shop.student_center`·`shop.dorm_furniture` 둘 다 READY, 헤더 확인 |
| inventory-acquisition: 세션 없음 + 부분 실패 | 세션 없음 0건, 500인 상점은 UNAVAILABLE 행이고 다른 상점은 READY 유지 |
| staff-badges: GM 칩 + ids 쿼리 | GM만 칩 1개, `ids=<uuid>,<uuid>` + X-Session-Id, 본문에 `p_user_ids` 없음 |
| staff-badges: 잘못된 id + 400 + 세션 없음 | UUID 아닌 id 전송 0건, 400 → null·예외 없음, 세션 없음 0건 |
| student-id: 200 프로필 + 업적 | READY, 닉네임·학과·칭호·뱃지 1개·Lv.3, 헤더 1건 |
| student-id: 409 | NO_PROFILE + "미설정" 기본값 + 배지 EMPTY |
| student-id: GUEST/세션 없음/401 | 신원 없음 → GUEST·0건, 세션 없음 → UNAVAILABLE·0건, 401 → UNAVAILABLE |

추가 인라인 확인 (테스트 파일 밖, `node --input-type=module`):
레거시 클라이언트를 직접 넘기면 `equip` → `SUCCESS`
(`equip_my_world_item_v1` 호출됨), `purchase` → `SUCCESS`로 쓰기
경로가 원본 그대로 동작한다.

## 3. 정적 검사

- `node --check` 통과: 마이그레이션된 파일 10개, `test-clients.mjs`,
  패치 적용본 `main.js`(단독·합친 것)·`world-online.js`·`smartphone.js`.
- 금지 토큰 grep (`supabase|auth.getSession|access_token|Authorization|Bearer`,
  대소문자 구분 없음): 마이그레이션된 파일 10개 + 테스트 + 생성기 **0건**,
  패치 4개의 추가 라인(`+` 행) **0건**.
  - `getClient`/`client.rpc`는 쓰기 경로에만 남았다 (로드아웃 장착/해제,
    상점 구매, 라우터 전달). A-2 범위이며 README에 기록했다.
  - 심볼링크 원본 `fishing-reporter-wiring.js` 38행 주석에 옛날 설명 한 줄이
    있으나 산출물이 아니라 단일 원본 링크이므로 그대로 두었다.

## 4. 패치 clean apply 검증 (`/tmp/tier04-verify`)

`python3 make-patches.py`가 생성과 검증을 함께 수행했다:

- `main.js.patch`: 원본 `main.js` 복사본에 `patch -p1` 적용 성공,
  `node --check` 통과. 적용본에서 마이그레이션된 생성·`setAccount`
  12곳이 전부 `readGuestSessionId()`이고, 낚시·도감 라인은 원본 그대로.
- `main.js.combined.patch`: 원본 `main.js` 복사본에 적용 성공,
  `node --check` 통과. 적용본에 낚시(`fishing.setAccount(...)`),
  도감(`collectionBook.setAccount(...)`), Tier 4 5개 라인이 모두
  `readGuestSessionId()`이며, import 라인은 1개로 합쳐졌다.
  (Tier 3 combined 패치도 원본 `main.js`에 깨끗이 적용됨을 먼저 확인했다.)
- `world-online.js.patch`, `smartphone.js.patch`: 원본 복사본에 적용
  성공, `node --check` 통과. 적용본에서 배지 바인딩이
  `setStaffBadgeClient({ getSessionId: () => readGuestSessionId() })`,
  학생증 생성이 `getClient` 없이, `NO_PROFILE` 표시 줄이 들어감을 확인했다.
- 4개 패치 전부 `patch --dry-run` 통과 (생성기가 자동 수행).

## 5. 남은 실측 (부모가 Worker 배포 후)

단위 테스트는 스텁으로 계약을 확인했을 뿐, 실제 Worker와는 아직
맞물려보지 않았다. 격리 환경에서 확인할 것:

1. 8개 엔드포인트 200 + 스냅샷 파싱 (인벤토리·지갑·진행도·로드아웃·
   상점 2개 상점·capabilities·배지·프로필).
2. 세션 없음 → 401, 클라이언트는 전송 없이 UNAVAILABLE/SIGNED_OUT.
3. 프로필 없는 세션 → 409 → 학생증 NO_PROFILE.
4. `shop_id` 누락 → 400 → 상점 UNAVAILABLE.
5. 잘못된 id 목록 → 400 → 배지 없이 표시, 예외 없음.
6. capabilities 404 → 레거시 모드 폴백.
7. 지갑·진행도 보상 재시도가 실서버에서도 한 번만 재시도하는지
   (지연 `[1000, 3000, 8000]`).
8. 로드아웃 장착·상점 구매가 A-2 전까지 SIGNED_OUT으로 막히는지.

## 6. 미확인·알려진 한계

- 실제 폰·브라우저 동작 미확인 (헤드리스 단위 테스트만 했다).
- `loadout.onChange`의 `change.accountId`를 로그인 userId처럼 쓰는
  main.js 두 곳(장비 전파)은 이번에 손대지 않았다. accountId가 이제
  세션 id라 비교가 맞지 않는다 — 세션→사용자 매핑이 정해지면 고칠 것
  (README "남은 것" 참조).
- 상점 `scopedPurchase`·`getPurchaseRpc` 분기, capabilities의 split
  판정은 단위 테스트의 스텁 응답으로만 확인했다 (실서버 split 응답은
  실측 때 확인).
