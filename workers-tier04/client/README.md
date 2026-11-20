# INHA WORLD — Tier 4 A-1 읽기 전용 클라이언트 마이그레이션

8개 읽기 전용 클라이언트를 Supabase `client.rpc`에서 Tier 4 Worker
`GET` 엔드포인트 + `X-Session-Id` 헤더로 교체한 패치 묶음이다.
낚시(Tier 3)·도감(Tier 3)과 같은 폴더 패턴을 따른다.

- 원본: `~/workspace/inha-world-static-test/src` (읽기 전용 스냅샷, 수정 없음)
- 작업 폴더: `~/workspace/inhaworld-tier04-readonly/client/`
- Worker 계약: 부모가 같은 폴더에 만드는 `worker.js`·`schema.sql` 참조.
  Worker는 아직 배포 전이라 격리 실측은 하지 않았다 (VERIFY.md 참조).

## 파일 배치 (원본 경로 그대로)

마이그레이션된 파일은 스냅샷 안의 원래 위치로 그대로 복사해서 쓴다.
디렉터리는 `src/` 구조를 미러링한다.

| 이 폴더 | 원본 위치 | 엔드포인트 | 원본 RPC |
|---|---|---|---|
| `inventory/inventory-client.js` | `src/inventory/inventory-client.js` | `GET /api/world-inventory` | `get_my_world_inventory_v1` |
| `wallet/wallet-client.js` | `src/wallet/wallet-client.js` | `GET /api/world-wallet` | `get_my_world_wallet_v1` |
| `progression/progression-client.js` | `src/progression/progression-client.js` | `GET /api/world-progression` | `get_my_world_progression_v1` |
| `appearance/loadout-client.js` | `src/appearance/loadout-client.js` | `GET /api/world-loadout` (읽기만) | `get_my_world_appearance_loadout_v1` |
| `shop/shop-client.js` | `src/shop/shop-client.js` | `GET /api/world-shop?shop_id=<id>` (읽기만) | `get_world_shop_v1(p_shop_id)` |
| `shop/shop-capabilities.js` | `src/shop/shop-capabilities.js` | `GET /api/world-shop-capabilities` | `get_world_shop_capabilities_v1` |
| `shop/shop-router.js` | `src/shop/shop-router.js` | (위 두 개를 엮는 라우터) | — |
| `inventory/inventory-acquisition-client.js` | `src/inventory/inventory-acquisition-client.js` | `GET /api/world-shop?shop_id=<id>` | `get_world_shop_v1(p_shop_id)` |
| `staff-badges.js` | `src/staff-badges.js` | `GET /api/world-staff-badges?ids=<uuid,...>` | `get_world_staff_badges_v1(p_user_ids)` |
| `phone/student-id.js` | `src/phone/student-id.js` | `GET /api/world-profile` | `get_my_profile` + `get_my_achievements` |

그 밖의 파일:

| 파일 | 용도 |
|---|---|
| `main.js.patch` | Tier 4 단독 패치 (원본 `src/main.js` 기준) |
| `main.js.combined.patch` | 낚시 + 리포터 + 도감(Tier 3) + Tier 4 합친 패치 (원본 `src/main.js` 기준) |
| `world-online.js.patch` | 스태프 배지 배선 (원본 `src/online/world-online.js` 기준) |
| `smartphone.js.patch` | 학생증 배선 + `NO_PROFILE` 표시 (원본 `src/phone/smartphone.js` 기준) |
| `test-clients.mjs` | 단위 테스트 22개 (`node test-clients.mjs`) |
| `make-patches.py` | 패치 생성기 (원본에서 재생성 + dry-run 검증) |
| `README.md` | 이 문서 |
| `VERIFY.md` | 검증 기록 |

심볼릭 링크 (테스트용 참조, 산출물 아님 — 원본을 복사하지 않기 위해 링크만 둠):

| 링크 | 가리키는 단일 원본 |
|---|---|
| `activity/fishing-reporter-wiring.js` | `~/workspace/inha-world-fishing-reporter-wiring/client/fishing-reporter-wiring.js` (`readGuestSessionId`의 유일한 출처) |
| `collection/item-catalog.js` | 스냅샷 `src/collection/item-catalog.js` (`APPEARANCE_SLOTS`, 무수정) |
| `progression/progression-hud.js` | 스냅샷 `src/progression/progression-hud.js` (`formatProgression`, 무수정) |
| `shop/shop-routes.js` | 스냅샷 `src/shop/shop-routes.js` (`SHOP_ROUTE_IDS`, 무수정) |

배포할 때는 마이그레이션된 파일 10개 + 패치 4개만 쓰면 된다.
링크 4개는 로컬 테스트용이다 (배포 트리에는 이미 해당 원본 파일들이 있다).

## 전 / 후 인증 흐름

공통 (낚시·도감과 같은 패턴):

- 전: 생성자 `getClient: () => online?.supabase ?? null`, 읽기는
  `client.rpc('<rpc명>', ...)` + 로그인 계정의 세션.
- 후: 생성자 `getSessionId` (+ `fetcher`, `endpoint`) — 기본값은
  `readGuestSessionId()`를 직접 import한 것 (배선 모듈이 유일한 출처,
  로직을 두 곳에 복사하지 않음). 읽기는 `fetch(endpoint, { headers:
  { "X-Session-Id": <세션 id> } })`. `Authorization`·Bearer·토큰은
  어떤 형태로도 보내지 않는다.
- 세션 id는 요청 때마다 공급자에서 새로 확인한다 (도감 패턴):
  바인딩된 `accountId`는 세대 키이자 `SIGNED_OUT` 표시일 뿐, 헤더 값은
  항상 live 공급자 값이다. 공급자가 null이면 요청을 보내지 않고
  `UNAVAILABLE`로 머문다 (가짜 id를 만들지 않음). `setAccount(null)`은
  `SIGNED_OUT`.
- 서버 401/403은 `UNAVAILABLE` (스냅샷 없음). 404도 `UNAVAILABLE`
  (capabilities만 예외: 404 → 레거시 폴백, 아래 참조).
- 응답 파싱·상태·세대·합치기(coalesce)·재시도 로직은 원본 그대로.
  바꾼 것은 인증과 transport뿐이다.

클라이언트별 특이점:

- **inventory / wallet / progression / loadout(읽기) / shop(읽기)**:
  `fetchOnce`만 교체. 지갑·진행도의 보상 재시도
  (`daily-reward-recovery`·`reward`·`core15-first-campus-reward`,
  지연 `[1000, 3000, 8000]`)는 그대로 두고 단위 테스트로 확인했다.
- **loadout / shop 쓰기 (A-2 범위, 이번에 건드리지 않음)**:
  `equip`/`unequip`/`purchase` 코드는 원본 그대로이며, 선택적
  `getClient` (기본값 `() => null`)를 통해서만 옛 transport를 쓴다.
  main.js 패치는 `getClient`를 넘기지 않으므로, A-2까지 쓰기는
  `SIGNED_OUT` + `PERMANENT_ACCOUNT_REQUIRED`를 반환한다 (레거시
  클라이언트를 직접 넘기면 원래대로 동작함을 인라인 확인했다).
  읽기 경로는 `getClient`를 절대 보지 않는다.
- **shop-client**: `shopId` 생성자 옵션 유지, `shop_id` 쿼리 파라미터로
  전달 (`?shop_id=<id>`, URL 인코딩). `shop_id`가 비면 서버 400을
  `UNAVAILABLE`로 처리하고 폴백 id를 만들지 않는다.
- **shop-capabilities**: `readShopCapabilities(client)` →
  `readShopCapabilities({ getSessionId, fetcher, endpoint })`.
  옛 `isMissingShopCapabilities` (PostgREST PGRST202 판별)는 transport
  전용이라 제거했다. 대신 404 → `{ mode: 'legacy', purchaseRpc:
  'purchase_world_shop_listing_v1' }` 폴백으로 같은 의미를 유지한다.
  401/403·네트워크 실패·형식 오류는 null (구매 재전송의 근거로 쓰지 않음).
- **shop-router**: `createShopRouter`가 `getSessionId` (+ 선택적
  `fetcher`·`apiBase`)를 받아 상점 클라이언트들과 capabilities 협상에
  넘긴다. `getClient`는 구매용으로만 전달되며 기본값은 `() => null`.
  `setAccount`·`select`·`refresh`·`purchase`의 나머지 동작은 그대로.
- **inventory-acquisition-client**: 상점별 읽기를 같은
  `/api/world-shop?shop_id=` GET으로 교체. 타임아웃 경쟁, 상점별
  `READY`/`UNAVAILABLE` 행, 실패한 상점이 다른 상점을 가리지 않는
  동작은 그대로. 세션이 없으면 읽지 않고 빈 스냅샷 + `false`.
- **staff-badges**: `setStaffBadgeClient(클라이언트)` →
  `setStaffBadgeClient({ getSessionId, fetcher, endpoint } | null)`.
  배치(최대 64개)·캐시·렌더링은 그대로. id 목록은 `ids` 쿼리 파라미터에
  콤마로 연결하고 JSON 본문은 보내지 않는다. UUID가 아닌 id는 요청 전에
  걸러낸다. 400·401/403·네트워크 실패는 배지 없이 해석(null)하고
  World를 절대 중단시키지 않는다. 응답은 배열 또는 `{ badges: [...] }`
  둘 다 받는다.
- **student-id**: 두 번의 RPC를 한 번의 `GET /api/world-profile`로
  묶는다. 응답은 `{ profile, achievements, stats? }`로 본다.
  409 `PROFILE_REQUIRED` → 새 상태 **`NO_PROFILE`** (프로필 없음,
  배지는 `EMPTY`, 스냅샷은 "미설정" 기본값). 나머지 실패는 기존대로
  `UNAVAILABLE`. `GUEST`(신원 없음)·`LOADING`·`READY`·에포크 가드는 그대로.
  배지 필터(획득한 것만, 최신순, 최대 3개)도 그대로.

## main.js 배선 지점 (원본 `src/main.js` 기준 행 번호)

`main.js.patch` / `main.js.combined.patch`가 바꾸는 곳:

| 지점 | 원본 행 | 변경 |
|---|---|---|
| import 추가 | 191 뒤 | `import { readGuestSessionId } from "./activity/fishing-reporter-wiring.js";` (낚시·도감 패치와 같은 자리 — 겹치므로 combined 패치도 함께 제공) |
| progression 생성 | 1152 | `getClient: () => online?.supabase ?? null` → `getSessionId: () => readGuestSessionId()` (+ AUTH 주석 블록) |
| wallet 생성 | 1180 | 동일 교체 |
| inventory 생성 | 1189 | 동일 교체 |
| loadout 생성 | 1224 | 동일 교체 (+ "읽기만, 장착은 A-2" 주석) |
| shop 라우터 생성 | 1349–1352 | `createShopRouter({ getSessionId: () => readGuestSessionId(), shopIds: SHOP_ROUTE_IDS })` |
| inventoryAcquisition 생성 | 1365 | 동일 교체 |
| identity 핸들러 | 4046, 4048, 4050, 4054, 4059 | `progression`·`shop`·`wallet`·`inventory`·`loadout`의 `setAccount(...)` → `setAccount(readGuestSessionId())` (+ 설명 주석). `if (shop.accountId) void shop.refresh("account-capability");`는 그대로 (accountId가 이제 세션 id다) |

main.js에 없는 배선 지점 (별도 패치 파일로 분리):

| 지점 | 원본 파일·행 | 패치 |
|---|---|---|
| 스태프 배지 바인딩 | `src/online/world-online.js:21` import, `:218` `openSession` 안 `setStaffBadgeClient(transportClient)` | `world-online.js.patch` → `setStaffBadgeClient({ getSessionId: () => readGuestSessionId() })`. Realtime transport 자체는 안 건드림 (C그룹 범위) |
| 학생증 생성 | `src/phone/smartphone.js:76` `createStudentId({getClient, ...})` | `smartphone.js.patch` → `getClient` 인자 제거 (클라이언트 기본 공급자 사용). 폰의 `getClient`는 메시지·알림·앨범이 계속 쓰므로 main.js 쪽은 안 건드림 |
| 학생증 `NO_PROFILE` 표시 | `src/phone/smartphone.js:207` `renderStudent` | `smartphone.js.patch` → `NO_PROFILE`일 때 "프로필이 아직 없어요." 한 줄 추가 (안 그러면 "확인하고 있어요"로 보여 오해됨) |

낚시·도감 라인은 건드리지 않는다 (`fishing.setAccount`,
`collectionBook.setAccount`는 각자 패치 범위).

## combined 패치 규칙

import 블록(원본 191–192행)이 낚시·도감 패치와 겹친다. 따로 순서대로
적용하면 두 번째 패치가 실패하므로, 합친 패치도 함께 제공한다.

- `main.js.patch`: Tier 4 단독. 원본 main.js에만 적용한다.
- `main.js.combined.patch`: 낚시 + 리포터 + 도감(Tier 3) + Tier 4를
  합친 것. 원본 main.js에만 적용한다. (Tier 3 combined 패치를 먼저
  적용한 결과에 Tier 4 교체(import 제외)를 얹어 diff를 만들었다.)
- `world-online.js.patch`, `smartphone.js.patch`: 다른 파일이라 겹치지
  않고, combined/main 단독 어느 쪽과도 독립적으로 적용된다.
- 생성: `python3 make-patches.py` (교체 1회씩 적용 확인 + 4개 패치
  전부 dry-run 검증).

## Supabase 제거 확인 결과

마이그레이션된 파일 10개 + 테스트 + 생성기 전체를 대소문자 구분 없이
grep한 결과 (`supabase|auth.getSession|access_token|Authorization|Bearer`):
**0건**. 패치 4개의 추가 라인(`+` 행)에도 **0건**.
(마이너스 행에는 제거되는 옛 코드가 보이는 것이 정상이다.)

예외·주의:

- `getClient`/`client.rpc`는 **쓰기 경로에만** 남았다
  (`loadout-client.js`의 `equip`/`unequip`, `shop-client.js`의
  `purchase`, `shop-router.js`의 전달). 읽기 경로는 보지 않는다.
  A-2에서 교체할 때까지 쓰기는 `SIGNED_OUT`이다.
- `activity/fishing-reporter-wiring.js` 심볼링크의 원본 파일에는 옛날
  주석 한 줄에 `Authorization: Bearer <Supabase token>`이라는 말이 있다
  (38행, "낚시 클라이언트가 아직 옛 인증을 쓴다"는 역사 설명).
  산출물이 아니라 단일 원본을 링크한 것이라 그대로 두었다.
- `main.js`·`world-online.js`·`smartphone.js`의 나머지 부분에는 다른
  클라이언트(퀴즈·출석·소셜·방명록·온라인 백본 등)의 옛 인증이 그대로
  있다. 이번 범위 밖이다.

## 단위 테스트 결과

`node test-clients.mjs` — **22개 전부 통과** (Node 내장 테스트, 스텁
fetch만 사용, 네트워크 없음). `node --check`는 마이그레이션된 파일
10개 + 테스트 + 패치 적용본 4개 전부 통과.

- 헤더: 8개 클라이언트 전부 `X-Session-Id` 발송,
  `Authorization`·`Bearer` 미발송 확인.
- 세션 없음: 전 클라이언트 전송 0건. 바인딩된 계정은 `UNAVAILABLE`,
  `setAccount(null)`은 `SIGNED_OUT`.
- `setAccount(게스트 id)` → `READY` (상점은 `refresh()` 후 `READY`,
  원래 `setAccount`가 동기라서 그렇다).
- 서버 401/403 → `UNAVAILABLE`, 스냅샷 없음 (inventory 401, wallet 403,
  progression 401, shop 403, capabilities 401, student-id 401).
- profile 409 → `NO_PROFILE` + "미설정" 기본값 + 배지 `EMPTY`.
- `shop_id` 누락: 빈 `shop_id` → 서버 400 → `UNAVAILABLE`, 폴백 id 없음.
  정상 요청은 `shop_id=shop.student_center`를 쿼리로 보낸다.
- staff-badges 잘못된 id: UUID가 아닌 id는 전송 0건, 서버 400은 배지
  없이 해석(null)하고 예외 없음.
- 지갑 보상 재시도: `daily-reward-recovery` 실패 후 재시도 타이머가
  잡히고, 다음 읽기 성공 시 `READY`로 복구됨 (로직 유지 확인).
- 쓰기 inert: 레거시 클라이언트 없이 `equip`·`purchase`는
  `SIGNED_OUT` + `PERMANENT_ACCOUNT_REQUIRED`. 레거시 클라이언트를
  직접 넘기면 원래대로 `SUCCESS` (인라인 확인).

## 남은 것

- **격리 실측 없음 (의도적)**: Tier 4 Worker가 아직 배포 전이다.
  부모가 Worker 배포 후 격리 환경에서 실측할 것 — 단위 테스트까지만
  했다. 실측 시 확인할 것: 8개 엔드포인트 200 + 스냅샷 파싱,
  세션 없음 401, 프로필 없음 409, `shop_id` 누락 400, 잘못된 id 400,
  capabilities 404 → 레거시 폴백.
- **쓰기 (A-2)**: 로드아웃 장착/해제, 상점 구매 transport 교체.
- **알려진 후속 (이번 범위 밖)**:
  `main.js`의 `loadout.onChange` 두 곳이 `change.accountId`를 로그인
  userId처럼 쓴다 (`online?.setLocalEquipment(change.accountId, ...)`과
  `change.accountId === online?.userId` 비교 후 `roomSession?.setEquipment`).
  accountId가 이제 세션 id라 방 장비 전파 비교가 맞지 않는다.
  세션→사용자 매핑이 정해지면(C그룹 신원 작업과 함께) 고쳐야 한다.
  패치에서는 손대지 않고 여기에 기록만 남긴다.
- **프로필 생성 흐름**: 409를 받는 세션의 프로필 생성은 범위 밖
  (메일 501·프로필 생성은 앞 단계와 동일하게 범위 밖). 학생증은
  "프로필이 아직 없어요"만 보여준다.
- 라이브(inhagame.app, 라이브 Neon main, 라이브 Worker, 원본 레포,
  원본 스냅샷)는 건드리지 않았다. 스냅샷 md5는 작업 전후 동일하다
  (VERIFY.md 참조).

---

## A-3 상태머신 클라이언트 (2026-11-20)

`client/make-clients-a3.py` 생성기가 원본을 읽어 Tier 4 전송으로 교체한다
(각 교체 exactly-once 검증, `node --check` 검증). 전송만 바꾸고 파싱·
상태·생성·멱등 규칙은 그대로 둔다. A-1/A-2와 같은 관용구다:
생성자 `getSessionId` (+ `fetcher`, `endpoint`), `X-Session-Id` 헤더만
보내고 `Authorization`/Bearer는 어떤 형태로도 보내지 않는다.

| 이 폴더 | 원본 위치 | 엔드포인트 | 원본 RPC |
|---|---|---|---|
| `daily-quiz/daily-quiz-client.js` | `src/daily-quiz/daily-quiz-client.js` | GET `/api/world-daily-quiz`, POST `/api/world-daily-quiz-start`, POST `/api/world-daily-quiz-answer` `{runId, questionId, answerIndex}` | 퀴즈 3개 |
| `life-skills/life-skill-book-client.js` | `src/life-skills/life-skill-book-client.js` | GET `/api/world-life-skills`, GET `/api/world-life-skill-tree?skill_id=`, POST `/api/world-life-node-unlock` `{nodeId, requestId}`, POST `/api/world-life-tree-reset` `{skillId, requestId}` | 생활스킬 4개 |
| `social/social-client.js` | `src/social/social-client.js` | GET `/api/world-social`, GET `/api/world-public-profile?target=`, GET `/api/world-relationship?target=`, POST `/api/world-friend-request` `{action, target, accept?}`, POST `/api/world-report-user`, POST `/api/world-block-user` `{action, target}` | 소셜 10개 |
| `social/accompany-client.js` | `src/social/accompany-client.js` | GET `/api/world-accompany`, POST `/api/world-accompany` `{action: propose\|respond\|end, ...}` | 동행 4개 |
| `biryong/biryong-cloud-sync.js` | `src/biryong/biryong-cloud-sync.js` | GET/POST `/api/world-biryong-progress` `{progress, migratedFromLocal}` | 비룡 진행 2개 |
| `biryong/biryong-village-relationship-client.js` | `src/biryong/biryong-village-relationship-client.js` | GET `/api/world-biryong-npc-relationships` (읽기 전용 유지) | 비룡 NPC 관계 조회 2개 |
| `events/event-client.js` | (MCM 클라이언트) | GET `/api/world-mcm-event`, POST `/api/world-mcm-landlord-run`, POST `/api/world-mcm-landlord-choice`, POST `/api/world-mcm-claim` | MCM 5개 (advance 제외) |
| `events/event-data.js`, `events/event-phase.js`, `event-registry.js` | 원본 그대로 | — (verbatim 복사) | — |

클라이언트별 특이점:

- **daily-quiz**: start 반환에 questionIds가 없다 — 현재 question만
  반환한다. 답안은 `{runId, questionId, answerIndex}`로 보낸다.
- **life-skills**: unlock/reset의 `requestId`는 uuid 멱등 키다.
  트리는 ACTIVE 노드만 반환한다(원본 book view와 동일).
- **social**: `PROFILE_NOT_FOUND`를 KNOWN_ERRORS에 추가했다
  (프로필 없음·밴은 409 `PROFILE_REQUIRED`).
- **accompany**: `PROFILE_NOT_FOUND`를 ERRORS에 추가했다.
  propose/respond/end를 한 POST 엔드포인트의 `action`으로 나눈다.
- **biryong-cloud-sync**: 진행 병합은 `{progress, migratedFromLocal}`
  JSON을 그대로 보낸다. fresh get은 null을 반환한다(원본과 동일).
- **biryong-village-relationship-client**: 원본이 의도적으로 읽기
  전용이라 ("deliberately NO mutation method") advance 메서드를
  만들지 않았다. `BIRYONG_RELATIONSHIPS_RPC` 상수는
  `"get_my_biryong_npc_relationships_v1"`이다.
- **event-client**: `advance_mcm_2026_event_v1`은 서버 전용이라
  HTTP 엔드포인트가 없다. 비프리뷰 `advance()`는
  `MCM_ADVANCE_UNAVAILABLE`을 던진다 (기존 `/api/world-quest`
  Bearer POST는 Tier 4 이전 경로라 제거). 프리뷰 분기는 로컬
  advance 그대로 유지한다. `event-data.js`의
  `../event-registry.js` import는 `src/events/event-registry.js`가
  원본이라 유효하다.

의도적으로 만들지 않은 것 (임의로 만들지 않고 기록한다):

- 캠퍼스 NPC 관계 클라이언트: 원본 스냅샷에 전용 클라이언트 파일이
  없다.
- 비룡 NPC advance 클라이언트 메서드: 위 읽기 전용 규칙 참조.
- MCM advance 클라이언트 호출: 위 서버 전용 규칙 참조.

## A-3 단위 테스트 결과

`node test-clients.mjs` — **50개 전부 통과** (기존 35 + A-3 15).
A-3 테스트 15개: 퀴즈 3, 생활스킬 3, 소셜 2, 동행 1, 비룡 sync 2,
비룡 관계 1, MCM 3 (Node 내장 테스트, 스텁 fetch만 사용, 네트워크 없음).

- 비룡 관계 클라이언트 테스트에서는 `getUserId: () => SESSION`을
  넘겨야 한다 (원본 클라이언트가 `getUserId() !== accountId`면
  `SIGNED_OUT`으로 처리 — 테스트 픽스처 문제, 클라이언트 결함 아님).
- MCM advance는 테스트하지 않는다 (HTTP 엔드포인트 없음).
