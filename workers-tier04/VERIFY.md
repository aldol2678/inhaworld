# Tier 4 B/C/D 검증 기록 (2026-11-20)

격리 환경에서만 검증했다. 라이브(inhagame.app · 라이브 Neon main · 라이브 Worker · 원본 레포)는 읽기 전용 참고만 했고, 마지막에 inhagame.app 200 유지만 확인했다. 비밀값(비밀번호·연결 문자열·토큰·관리자 키)은 이 문서에 없다.

A-1(읽기 전용)·A-2(쓰기)·A-3(상태머신) 검증 기록은 A-3 폴더에 있으며, BCD는 그 superset이다. BCD 수치는 A-3를 포함한다 (오라클 715 = A-3 639 + BCD 76, 패리티 607 = A-3 575 + BCD 32, 클라이언트 56 = A-3 50 + BCD 6, curl 264 = A-3 회귀 203 + BCD 61). 시드 게이트는 별도 21건이다.

## 격리 배포

- Neon 프로젝트 `odd-smoke-58843454` (`inha-world-sync`)
  - 스크래치 `tier4-scratch` (`br-lingering-field-aor2ph0y`) — 원본 마이그레이션 52개 적용 · 클로저 추출용 (A-3와 동일, 재사용)
  - 테스트 **`tier4-bcd-test`** (`br-rough-night-aotbxv14`, main `br-rapid-dust-aofiyhry`에서 분기; A-3의 `tier4-a3-test`와 별개 브랜치). 호스트 `ep-divine-heart-aouh7u04.c-2.ap-southeast-1.aws.neon.tech`
- Worker **`inha-world-tier04-bcd-test`** — https://inha-world-tier04-bcd-test.aldol-lab.workers.dev, Version ID **`8c5311ad-e343-4268-926a-a0e2f87d8aed`** (2026-11-20 v2 재배포본; 첫 배포 `5afee336-bf7f-4215-87f7-5c31474c9295`는 아래 Worker 버그 수정 후 교체됨. workers.dev 전용, 라우트·커스텀 도메인 없음). 로그인 역할 `tier4_writes_app_login` + `DATABASE_URL`·`MAIL_ADMIN_KEY` 시크릿은 stdin 경유로 격리 Worker에만 설정했다. 역할명은 A-3와 동일 (`inha_world_tier4_writes_app` 그룹) — 격리성은 브랜치 단위라 충돌 없음.
- `schema.sql` SHA-256 `c2c3e21cffa6b151d62677809566a0e051842edaec961295bf41c67ae4ba9aef` (10,466줄), `worker.js` SHA-256 `1e64d9798ef4bf4f9296426d8ac7fbc5c17510cf11270340ceb26d15b65888b0` (1,302줄).
- 해시 대조 (`hash-report-bcd.json`): BCD 함수 7개 — 신규 3개(`create_my_world_profile_v1`, `request_world_mail_verification_v1`, `admin_claim_world_mail_verification_v1`) + 적응 2개(`touch_world_online_session_v2`, `get_world_online_count_v1`, 클로저 추출 후 세션 기반 적응) + 헬퍼 2개(`world_profile_normalize_nickname_v1`, `world_profile_nickname_banned_v1`). 테이블 +3개, 세션 트리거 50→52개, invoker 함수 40→42개, grant execute 65→72개.

## 0. 스키마 적용 — 2회로 수렴 + touch 기본값 수정 1건

`python3 provision-tier4bcd.py` 경유 적용 (2026-11-20). 1차: 1356 ok, 34 failed (FK 순서 + 미존재 함수 참조, A-3와 동일 패턴). 2차: 1383 ok, 7 failed:

- 1188/1189/1191 `LIFE_SKILL_CURVE_INVALID` / `LIFE_PROGRESSION_CURVE_INVALID`, 1200 `DAILY_QUIZ_50_POOL_POSTCONDITION_FAILED total=100 active=100 major=74 general=8 inha=2` — A-3 최종 실패와 동일한 4건(재실행 전용 stale 가드, 데이터 이상 아님 — 더 재적용하지 않음).
- 1364/1373 트리거 이미 존재 — 재적용 중복, 무해.
- 1374 "cannot remove parameter defaults from existing function" — 1차 적용 때 touch가 기본값 있는 상태로 만들어졌고, `CREATE OR REPLACE`로는 기본값을 제거할 수 없어서다. `fix-touch-defaults.sql`(drop + 기본값 없는 재생성 + 재GRANT)로 해결했고, 단일 문장씩 나눈 파일로 실행한 뒤 삭제했다. 적용 후 DB 확인: BCD 함수 7개 전부 `has_defaults=false`, 금지어 47단어, BCD 테이블 3개, `tier4_session_ref` 트리거 52개.

## 1. 오라클 `test-schema.sql` — 715/715 통과

`python3 provision-tier4bcd.py oracle` (2026-11-20 실행) — **715/715 passed, leftover fixture rows: 0**.

범위 (A-3 639문항의 superset): BCD 추가 ~76문항 — 정적 검사(금지 47단어·함수 7개·시그니처 3개·부분 인덱스·ACL), 닉네임 정규화/금지 검사(`소년연금술사`·`인덕이` 정상 판정 포함), 프로필 생성(생성·재요청 기존 유지·대소문자 무시 중복·금지·반복 축소·짧음·특수문자 `a!b`·미지/비활성 학과·잘못된 avatar·긴 title·밴 은폐·null user·밴 닉네임 재사용·`get_my_profile` 역참조), 메일(잘못된 도메인·소문자화·10분 내 중복·미지 claim·프로필 없는 claim → 뱃지 yes/업적 no·두 번 claim·시간당 3건 제한·프로필 있는 claim → 업적 yes + `get_my_achievements` 노출), 온라인 touch/count(user_id NULL·visitor 저장/합치기/교체·즉시 재touch 429·잘못된 zone/space·null user·count 형태 signedIn 0/guests=online·80초 지난 행 제외·1일 지난 행 touch 시 삭제).

오라클 첫 실행은 712/715였다. 실패 3건은 전부 오라클 기대치·경로 버그였고 Tier 4 구현 결함이 아니다:

- 세션 삭제 시 `v_mail::text` 캐스트 누락 (`sessions.id`는 text, 변수는 uuid).
- 나머지 2건도 같은 계열의 오라클 내 경로 문제로, 수정 후 715/715가 됐다.

오라클은 한 트랜잭션에서 `now()`를 동결해 실행하므로 10초 touch 제한과 1시간 메일 제한이 결정적으로 검증된다. 인블록 정리는 BCD 온라인/메일/뱃지/업적/프로필/세션 행을 삭제한다(`v_noprofile`의 생성 프로필은 runner 정리용으로 남긴다).

## 2. 패리티 `test-parity.mjs` — 607/607 통과

`python3 provision-tier4bcd.py parity` (2026-11-20 실행) — **pass=607 fail=0 compared=297 leftoverOwner=0 leftoverOrig=0**.

- 정적 검사: 함수 184→**191**개(183 클로저 + `tier4_require_session_v1` + BCD 7개), 테이블 85→**88**개, 세션 트리거 52개/58문장(트리거 문장이 두 줄에 걸친 것이 있어 정규식은 `/before insert or update of \w+\s+on/` — 같은 줄만 찾는 엄격한 정규식은 50개만 찾는다), invoker 함수 40→42개, `grant execute` 65→**72**개, BCD 시그니처 5개.
- 직접 대조 297쌍 (원본 RPC vs Tier 4, 동일 픽스처, Tier 4는 로그인 역할로 호출해 권한까지 증명): A-3 전수 + BCD — touch 행(user_id 제거 후 대조 + 뒤집힘 assert), count(signedIn/guests 제거 후 대조 + 뒤집힘 assert), 프로필 최종 상태(원본 직접 INSERT vs Tier 4 RPC), 중복/금지 기대 차이, 메일 claim(원본 `claim_inha_mail_badge(DAVE, CAROL)` vs Tier 4 관리자 claim 최종 상태). `cleanupWorld`에 BCD 삭제(양쪽 온라인 세션, Tier 4 쪽 메일 요청)를 추가했다.
- 기대 차이 15건 (각각 assert, 실패 아님 — A-3 12건 + BCD 3건):
  1. 업적 `inha_verified`: 원본은 이메일 전용 인증(`auth.users`)으로도 부여, Tier 4는 `inha_mail_badges` 행만 본다.
  2. 프로필 inha-duck `lastPlayedAt`: 원본은 ops 미러 트리거가 만든 `game_events` 시각(now), Tier 4는 classic 마지막 시각.
  3. 정석 carol: 원본은 이메일만으로 INHA_MAIL 부여, Tier 4는 패스가 필요하다.
  4. 프로필 없는 세션의 게스트 개방 경로 (의도적 설계 차이, A-1부터).
  6. 소셜 caller noprofile/banned: 원본 `ACCOUNT_UNAVAILABLE` vs Tier 4 `PROFILE_NOT_FOUND`.
  8. Self-reads banned: 원본 `ACCOUNT_UNAVAILABLE` vs Tier 4 데이터 반환.
  9. **advance_mcm_2026_event_v1 SERVER_ONLY**: 원본은 `auth.role()='service_role'` 필요(42501), Tier 4는 게이트를 드롭했다 (Worker가 유일한 서버 호출자이며 HTTP 엔드포인트가 없다).
  10. **A-3 세션 전용 게이트**: 퀴즈/라이프/MCM/비룡 진행·NPC 관계의 account_ok는 원본이 프로필 필요(noprofile/banned → `ACCOUNT_UNAVAILABLE`), Tier 4는 세션만으로 성공한다. 소셜/동행은 프로필 규칙을 유지한다(#6).
  11. **world_card inhaVerified carol/dave**: 원본 true(`auth.users` 이메일 확인) vs Tier 4 false(badges-only, badge 행 없음). 프로필 단건뿐 아니라 소셜 목록 안의 카드에도 적용된다.
  12. **비룡 merge noprofile FK**: 원본 progress 테이블의 `auth.users` FK 때문에 noprofile 픽스처는 FK 위반으로 실패, Tier 4는 세션이 계정이라 성공한다. 실제 사용자는 항상 `auth.users` 행이 있어 라이브에서 발동하지 않는다.
  13. **온라인 user_id**: 원본 touch는 `auth.uid()`를 저장하고 count는 `signedIn`을 세지만, Tier 4는 `user_id` NULL·`signedIn` 0이다. 원본에는 touch 10초 제한이 없고 Tier 4는 10초 내 재touch 시 429다.
  14. **닉네임 중복**: 원본에는 프로필 생성 RPC가 없어 직접 INSERT하면 중복도 들어가지만, Tier 4는 `NICKNAME_TAKEN` 409다.
  15. **금지 필터**: 원본은 금지어를 그대로 INSERT하지만, Tier 4는 `INVALID_NICKNAME` 400이다.

## 3. 클라이언트 테스트 — 56/56 통과

`node client/test-clients.mjs` (2026-11-20 실행) — **pass 56, fail 0** (A-3 50 + BCD 6).

BCD 클라이언트 6개 테스트: 프로필 생성(생성·재요청·닉네임 정규식)·메일 요청(정상·잘못된 도메인)·heartbeat(touch/count 파싱·세션 id 동일). 테스트 중 수정한 것 1건: 닉네임 정규식이 공백을 막고 있었는데, 원본 CHECK을 직접 읽어보니 공백이 허용된다 — 클라이언트 `NICKNAME_RE`를 `/^[0-9A-Za-z가-힣_]{2,12}$/`로 고쳤다(클라이언트 기대치 버그, RPC 결함 아님).

## 4. Worker 버그 1건 수정 후 재배포 (curl 전)

시드 게이트 run 2에서 발견했다: 요리 RPC의 재고 부족 헬퍼가 `INSUFFICIENT_QUANTITY`(P0001)를 내는데 Worker `RPC_ERRORS`에 매핑이 없어, 정상적인 "재료 부족" 거부가 503 `COOKING_UNAVAILABLE` 폴백으로 떨어졌다. `INPUT_UNAVAILABLE`(카탈로그 입력 없음/비활성화 전용, P0001)도 함께 409로 매핑했다. 둘은 다른 조건이다 — `INPUT_UNAVAILABLE`은 입력 자체가 없거나 비활성화일 때, `INSUFFICIENT_QUANTITY`는 가진 수량이 레시피 필요량보다 적을 때다. 수정 후 Worker 재배포 — 새 버전 `8c5311ad-e343-4268-926a-a0e2f87d8aed` (curl run 2·시드 게이트 run 3은 이 배포본을 실측했다; 재료 부족 409가 통과해 수정이 라이브에 반영됐음을 증명한다).

## 5. curl 실측 (배포 Worker, 게스트 세션) — 264/264 통과

`python3 run-curl-bcd.py` (2026-11-20 실행: `curl-fixtures.mjs setup` → `curl-verify.sh` → `teardown`, `TEST_OWNER_URL`은 런처 경유, `MAIL_ADMIN_KEY`는 환경변수로 주입 — 미설정 시 rc 2로 즉시 실패) — **curl: pass=264 fail=0** (로그 `curl-run.log`).

세션: A-3 회귀 세션(alice `d1000000-…0001`·bob `d2000000-…0002`·밴 `d3000000-…0003`·프로필 없음 `d4000000-…0004`·dave `d5000000-…0005`·미지 `d9000000-…0009`) + BCD 세션 E/F/G/H(`e600…`/`e700…`/`e800…`/`e900…` — 프로필 신규·메일 신규·온라인 + 오탐/중복·밴 probe + 프로필 없는 claim). A-3 섹션 203건은 회귀 그대로 실행돼 전부 통과했다.

| 그룹 | 케이스 | 결과 |
|---|---|---|
| 프로필 (~22) | 생성 201 → GET 200 → 재요청 200 기존(내용 무시) → 대소문자 무시 중복 409 `NICKNAME_TAKEN` → 금지어 400 → 반복 축소(`ㅋㅋㅋ`→`ㅋ` 계열) 금지 판정 → 오탐 `소년연금술사` 201 → title 강제 null 확인 → 밴 프로필 재요청 409 `PROFILE_REQUIRED`(상태 은폐) → 밴 닉네임 재사용 201 → 짧음/특수문자/미지·비활성 학과/잘못된 avatar/긴 title 400 → 세션 없음 401 | 22/22 |
| 메일 (~17) | 요청 201 → 10분 내 동일 요청 200 duplicate(동일 requestId) → 잘못된 도메인 400 → G 세션 3×201 후 4번째 429(시간당 3건) → claim 잘못된 키 403/키 없음 403/미지 404 → 프로필 없는 claim 200(뱃지 yes·업적 no) → 프로필 있는 claim 200(뱃지 + 업적) → 두 번 claim 404 → 세션 없음 401 | 17/17 |
| 온라인 (~13) | touch 200 → 즉시 재touch 429 → count 200 형태(signedIn 0, guests==online) → 잘못된 zone/space 400 → 세션 없음 401 → 미지 세션 touch 200(게스트는 세션만으로 생성) → count GET 405 없음(세션 없이 읽힘) → touch GET 405 | 13/13 |
| B-3 probe (8) | `/api/npc-ai`·`/api/npc-relationship`·`/api/world-quest`·`/api/model-convert`·`/api/npc-dialogue-route` 등 NPC·model-convert·JEV 경로 전부 404 | 8/8 |
| 가드 (1, 회귀에 포함) | 잘못된 Origin 403 | 1/1 |

Run 1은 255/9였다. 실패 9건 중 6건은 Cloudflare 일시 장애(아래 관찰 사항), 2건은 테스트 기대치 버그(닉네임 공백 허용 — 원본 CHECK과 동일, §3 참조 — 과 그 여파로 `goodname`이 201이 아니라 200), 1건은 count 캐시 `asOf` 동일성 기대(아래 관찰 사항)였다. 전부 고쳐 run 2에서 264/264가 됐다.

핵심 실측값: 프로필 생성 201 → 재요청 200 기존 반환, 중복은 대소문자 무시 409, 메일 요청 duplicate는 동일 requestId, G 세션 4번째 요청 429, 프로필 없는 claim은 뱃지 yes·업적 no, 프로필 있는 claim은 뱃지 + 업적 yes, 온라인 touch 즉시 재시도는 429, B-3 경로 8개 전부 404.

## 6. 시드 게이트 격리 검증 — 21/21 통과

`bash seed-gate-verify.sh` (2026-11-20 실행, `TEST_OWNER_URL`은 런처 경유) — **seed-gate: pass=21 fail=0, teardown leftover=0, rc 0**. SEED-GATE-ROLLOUT.md 단계 0대로 격리 브랜치(`tier4-bcd-test`)에서만 전환했고, 라이브는 건드리지 않았다.

전환 전 값(0-1): 5개 행 전부 COMING_SOON — `gate_policy`, `pass_catalog`(jeongseok.visitor.day), `recipe_catalog`(recipe.carp_grill), `item_cooking_station`, `item_grilled_carp`.

| 단계 | 케이스 | 결과 |
|---|---|---|
| 닫힌 게이트 기준선 | 정석 조회 200 COMING_SOON → 구매 409 `JEONGSEOK_GATE_UNAVAILABLE` → 요리 409 `RECIPE_UNAVAILABLE` | 3/3 |
| 0-2 ACTIVE 전환 | 5개 행 전부 ACTIVE 확인 | 1/1 |
| 0-3 curl 재실측 | 정석 조회 ACTIVE·NEEDS_PASS·100코인 offer → 구매 100코인(지갑 500→400, GRANTED via VISITOR_PASS) → 재전송 동일 영수증(이중 차감 없음) → 활성 중 재구매 409 `PASS_ALREADY_ACTIVE` → 요리 성공(잉어 3→2, 구운 잉어 0→1) → 재전송 동일 영수증(이중 소비 없음) → 2·3번째 요리 성공(잉어 0까지) → 재료 부족 409 `INSUFFICIENT_QUANTITY` → 조리대 없음 403 `COOKING_STATION_REQUIRED` | 10/10 |
| 0-4 COMING_SOON 복원 | 5개 행 전부 COMING_SOON 확인 | 1/1 |
| 복원 후 닫힌 게이트 재확인 | 정석 조회 200 COMING_SOON → 구매 409 `JEONGSEOK_GATE_UNAVAILABLE` → 요리 409 `RECIPE_UNAVAILABLE` → access `gateStatus` COMING_SOON | 4/4 |
| 정리 | 픽스처 teardown, leftover=0 | 2/2 (setup·방 배치 포함) |

Run 1은 15/5였다. 실패 5건은 전부 요리 403 `COOKING_STATION_REQUIRED` — 픽스처에 방 + 바닥 배치가 없었다. 요리 RPC는 (a) 사용자가 소유한 `DORM_1_BASIC` 방, (b) `furniture.cooking_station`이 `surface='floor'`로 배치된 layout 행, (c) 조리대 인벤토리 소유를 전부 요구한다(인벤토리만으로는 부족 — SQL 직접 확인). teardown도 `JEONGSEOK_PASS_RECEIPT_APPEND_ONLY` 트리거 때문에 중단돼 픽스처 행이 누수됐고, 수정된 teardown으로 나중에 정리했다(leftover=0).

Run 2는 19/2였다. 실패 2건: 요리 재전송 검사가 `inventory.status == 'ALREADY_PROCESSED'`를 요구했는데 재전송은 저장된 영수증을 그대로(`SUCCESS`) 돌려준다(테스트 기대치 버그 — 전체 영수증 동일성으로 고침), 재료 부족이 503 `COOKING_UNAVAILABLE`(Worker 매핑 누락 — §4에서 수정).

Run 3이 21/21로 전부 통과했다. 방 배치(방 `3bc6ba63-54eb-4cf4-9a5f-6fb11a766986`에 조리대 floor 배치 200)를 포함한다.

## 7. 정리 · 라이브 · 컷오버 전제

- 테스트 행 정리: curl 픽스처 세션/프로필/메일 요청/온라인 세션/업적 전부 삭제 — `curl fixtures teardown done, leftover=0`. 오라클 잔여 0건, 패리티 잔여 test=0 scratch(orig)=0. 시드 게이트 픽스처도 teardown leftover=0, 게이트 5개 행은 COMING_SOON으로 복원 확인했다.
- **inhagame.app: 200 유지** (실측 마지막에 확인, 4052B, A-3 때와 동일).
- A-2 격리 리소스(`tier4-writes-test` 브랜치·Worker)와 A-3 격리 리소스(`tier4-a3-test` 브랜치·Worker)는 건드리지 않았다. A-3 폴더 원본도 건드리지 않았다(복사만 했다).
- 컷오버 전제(DECISIONS.md 기준) 충족 여부:
  - 충족: A-3 완료, B-3 유지(게스트 NPC off), D 프로필 생성 + 메일 폴백 구현·검증, 시드 결정(정석·요리 분리 전환, 정석만 전환 가능 상태).
  - 미충족: B-2 NPC Cloud Run 소유 미확인(보류 유지), 메일 (b) 발송 수단 없음(폴백 (c)로만 구현), 프로필 수정 API 미구현(후속), 학습 재검토 미실시(트리거는 충족됐으나 본 작업 범위 밖), loadout `accountId` 문제 미해결(A-3부터 기록된 후속 과제), 이중화 2주·전환 시간대·스모크 기준은 컷오버 계획 단계에서 정할 것.

## 관찰 사항 (실패 아님)

- **Cloudflare error 1042 (일시 장애, 2026-11-20 curl run 1)**: 초반 6개 요청이 HTTP 404 + Cloudflare "error code: 1042" 본문을 받았다. Worker 404는 평문 `Not found`라서 이건 엣지/프록시 일시 장애이지 Worker 응답이 아니다. 쓰기는 서버 측에서 성공했다(재실행 시 운동화 구매 500→260 확인). 깨끗한 재실행(run 2)에서 전부 통과했다.
- **온라인 count 5초 캐시는 Worker-local(격리별)**: 연속 요청이 다른 격리에 닿으면 cold 캐시라 `asOf`가 달라질 수 있다. 두 번 연속 읽기의 `asOf` 동일성은 유효한 단언이 아니고, 캐시는 최선형(best-effort)이지 계약이 아니다. run 1의 실패 1건이 이 기대치였다 — 형태 검사로 바꿨다.
- **append-only 트리거가 DELETE를 막는다**: `world_jeongseok_pass_purchases_append_only`와 `world_recipe_receipts_append_only`는 `BEFORE DELETE OR UPDATE`다(다른 append-only 트리거는 UPDATE 전용). 테스트 teardown은 삭제 전후로 `ALTER TABLE … DISABLE TRIGGER …` / re-enable을 해야 한다. 시드 게이트 run 1 teardown이 이 때문에 중단됐다.
- **닉네임 공백 허용**: BCD RPC 정규식은 `^[0-9A-Za-z가-힣_]+$` — 공백이 허용되며, 원본 CHECK과 정확히 같다(라이브 curl + SQL 직접 확인). 초반 curl 기대치(공백 → 400)가 틀렸었다.
- **재료 부족 vs 입력 없음**: 재고 부족은 `INSUFFICIENT_QUANTITY`(P0001), 카탈로그 입력 없음/비활성화는 `INPUT_UNAVAILABLE`이다. 둘 다 Worker에서 409로 매핑해야 정상 거부가 503으로 안 떨어진다.
- **요리 재전송은 저장된 영수증을 그대로 돌려준다**: `inventory.status`가 `ALREADY_PROCESSED`가 아니라 `SUCCESS`다. 재전송 검사는 전체 영수증 동일성으로 해야 한다.
- **메일 rate limit은 요청 기준**: 동일 사용자 + 동일 이메일 pending 요청이 10분 내 있으면 duplicate(동일 requestId), 시간당 3건을 넘으면 `RATE_LIMITED`(54000)다.
- **claim은 프로필 없이도 뱃지를 만든다**: 프로필이 없는 사용자의 claim은 `inha_mail_badges` 행은 만들지만 `inha_verified_v1` 업적은 부여하지 않는다(업적 부여는 밴이 아닌 프로필이 있을 때만).

## 미확인 사항

- 실제 폰 터치 · 브라우저 실측: BCD 기능이 게임 클라이언트에 아직 붙지 않아 범위 밖(낚시 때와 동일).
- `wrangler dev --local` 재확인 안 함(A-1 때 번들 workerd 날짜 제한이 있었음). 배포본은 엣지에서 curl로 동작을 확인했다.
- 프로필 `avatar`는 픽스처 기본값 `classic`으로만 확인했다(avatar 값 자체는 4종 전부 오라클에서 검증했다).
- B-2 NPC Cloud Run 소유: 이 VM에서 `gcloud` CLI가 없어 콘솔 확인 불가 — 알돌 단계(콘솔 직접 확인) 또는 별도 경로가 필요하다.
- CPU 폴백 렌더·실기기 터치는 본 작업 범위 밖이다.
