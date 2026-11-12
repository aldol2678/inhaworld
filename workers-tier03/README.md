# INHA WORLD — Tier 3 데이터 계층 Worker (Workers + Neon, 격리 테스트용)

도감·낚시·랭크·오리 관찰·메일 인증을 Vercel / Supabase Edge Function + Supabase에서
Cloudflare Workers + Neon으로 옮긴 것이다. 원본은 `aldol2678/inhagame` HEAD `0b72d259`이며
읽기 전용으로만 참고했다. 원본 저장소, 라이브 Worker, 라이브 Neon DB(`inha-world-sync`),
라이브 배포는 건드리지 않았다.

**현재 상태: 코드와 로컬 검증까지만 끝났다. 격리 Neon 브랜치 적용과 실제 배포는 하지 않았다.**

먼저 알아야 할 세 가지:

1. **프로필 행이 없는 세션은 낚시·도감·오리 관찰도 전부 403이다.** 원본의 계정 검사
   (`world_*_account_ok_v1`)는 "익명이 아님"과 함께 "`profiles` 행이 있고 밴이 아님"을 요구한다.
   A안으로 앞쪽만 세션 존재 검사로 바뀌었고 뒤쪽은 그대로다. Tier 3에는 프로필 생성 흐름이
   없으므로, 지금 상태로 배포하면 게스트 세션은 랭크(`PROFILE_REQUIRED`)뿐 아니라 이 세 기능도
   `ACCOUNT_UNAVAILABLE`을 받는다. ("원본과 달라진 점" 5번)
2. **낚시는 위치 피드가 없으면 시작되지 않는다.** 원본 런타임 기본값이 `presence_required = true`이고,
   위치를 넣는 `world_fishing_observe_position_v1`을 호출하는 핸들러는 Tier 3 범위에 없다.
   그 상태에서 `start`는 항상 `409 FISHING_POSITION_UNAVAILABLE`이다. ("아직 안 된 것")
3. **메일 인증은 501이다.** 신원 검증은 이식하지 않았다. ("메일 인증 이식에 필요한 것")

## 엔드포인트

| 경로 | 원본 | 동작 |
|---|---|---|
| `GET /api/world-collection-book` | `api/world-collection-book.js` + `server/collection-book-service.mjs` → RPC `world_collection_list_v1` | 본인 도감 조회. `200` 투영 결과 / `401 AUTH_REQUIRED` / `403 ACCOUNT_UNAVAILABLE` / `503 COLLECTION_BOOK_UNAVAILABLE` |
| `POST /api/world-fishing` | `api/world-fishing.js` + `server/fishing-service.mjs` → RPC `world_fishing_{start,input,settle,read}_v1` | `op`별 낚시 상태머신. `WORLD_FISHING_API_ENABLED != "1"`이면 `404` |
| `POST /api/ranked-run-start` (+ `OPTIONS`) | `functions/ranked-run-start` | 랭크 세션 발급. `200` / `401 UNAUTHENTICATED` / `409 PROFILE_REQUIRED` / `403 RANKING_BLOCKED` / `429 RATE_LIMITED` / `500 START_FAILED` |
| `POST /api/ranked-run-finish` (+ `OPTIONS`) | `functions/ranked-run-finish` → RPC `record_ranked_result_v4/v5`, `get_my_rank_v3` | 결과 검증·확정. `200` / `401` / `404 RUN_NOT_FOUND` / `409 RUN_ALREADY_PROCESSED` / `410 RUN_EXPIRED` / `403·422 RUN_REJECTED` / `500 FINISH_FAILED` |
| `POST /api/world-duck-observe` (+ `OPTIONS`) | `functions/world-duck-observe` → RPC `world_inkyung_duck_observe_v1` | 인경호 오리 4마리 관찰 기록. `200` / `401` / `400 INVALID_DUCK_ID` / `403 ACCOUNT_UNAVAILABLE` / `409 OBSERVATION_REJECTED` / `500 OBSERVATION_FAILED` |
| `POST /api/verify-inha-mail` (+ `OPTIONS`) | `functions/verify-inha-mail` | **`501 {"error":"NOT_IMPLEMENTED"}`** — 신원 검증 미이식 |

신원은 전부 `X-Session-Id` 헤더(v0.1 서버 발급 세션 ID)다. `verifySession`은 헤더가 UUID 형태이고
`public.sessions`에 그 id가 있으면 소문자 id를 actor로 돌려주고, 아니면 null이다.

가드 순서는 원본과 같다.

- **도감:** 메서드(405, `Allow: GET`) → 쿼리스트링·본문 있음(400) → same-host Origin(403) → 세션(401) → RPC.
- **낚시:** 플래그(404) → 메서드(405, `Allow: POST`) → Content-Type(415) → same-host Origin(403) →
  본문 크기(413)·JSON(400) → 요청 형태(400 `INVALID_REQUEST`) → 세션(401) → RPC.
  요청 형태 검사가 세션보다 먼저인 것도 원본 그대로다.
- **랭크·오리:** `OPTIONS`(200) → 메서드(405) → 세션(401) → 본문 → 이하 원본 순서.

낚시 RPC 예외 → 상태코드 대응(원본 `ERRORS` 표 그대로):

| 상태 | 코드 |
|---|---|
| 400 | `INVALID_REQUEST`, `FISHING_IDENTITY_MISMATCH` |
| 403 | `ACCOUNT_UNAVAILABLE` |
| 404 | `ATTEMPT_NOT_FOUND` |
| 409 | `FISHING_POSITION_UNAVAILABLE`, `FISHING_POSITION_STALE`, `FISHING_POSITION_INELIGIBLE`, `FISHING_OUT_OF_RANGE`, `FISHING_SPOT_OCCUPIED`, `FISHING_LEASE_LOST`, `FISHING_SESSION_CHANGED`, `FISHING_UNAVAILABLE`(런타임 꺼짐), `ATTEMPT_ALREADY_ACTIVE`, `IDEMPOTENCY_CONFLICT`, `TERMINAL_COMMAND_CONFLICT`, `ACTIVITY_OUTCOME_CONFLICT`, `FISHING_NOT_SUCCEEDED`, `OUTPUT_UNAVAILABLE`, `MAX_STACK_EXCEEDED`, `COLLECTION_ENTRY_INACTIVE`, `LIFE_SKILL_INACTIVE`, `SETTLEMENT_PLAN_CONFLICT` |
| 429 | `FISHING_RATE_LIMITED` |
| 503 | `AUTH_UNAVAILABLE`(세션 조회 실패), `FISHING_UNAVAILABLE`(그 외 DB 오류·연결 실패) |

멱등 재전송은 거절이 아니다. 같은 `clientAttemptKey`로 다시 `start`, 종결된 시도에 같은 명령 재전송,
`settle` 재호출, 같은 오리 재관찰은 전부 **200**이고 본문의 `status`가 `ALREADY_PROCESSED`다.
409는 위 표의 실제 충돌·거절일 때만 나온다.

## 파일

| 파일 | 내용 |
|---|---|
| `schema.sql` | Neon 스키마. 테이블 49개, 함수 78개, 시드, 최소 권한 그룹 역할. 여러 번 실행해도 안전. |
| `worker.js` | Worker 본체. 핸들러 6개 + 세션 검증. Tier 2와 같은 단일 파일 구조. |
| `wrangler.toml` | Worker 이름 `inha-world-tier03-test`. `[vars]`·라우트 없음. |
| `test-parity.mjs` | 패리티 테스트 (`node test-parity.mjs`). DB 없이 실행. `TEST_PG_URL`을 주면 실제 Postgres로 end-to-end까지. |
| `test-schema.sql` | DB 쪽 오라클. 원본 pgTAP 6개 + 낚시 상태머신·랭크 생명주기·오리 멱등성·메일 뱃지. |
| `package.json`, `package-lock.json` | `@neondatabase/serverless` 0.10.4 고정. `pg`는 선택적 통합 테스트용 devDependency. |

## 스키마

### 어떻게 만들었나

Tier 3 RPC는 겉으로는 14개지만, 낚시 정산과 오리 관찰이 활동·인벤토리·도감·생활 스킬·생물 계층을
전부 지난다. 실제로 닿는 범위는 **테이블 47개, 함수 77개**다. 손으로 옮기지 않았다.

1. 원본 마이그레이션 52개 전부를 순서대로 로컬 스크래치 DB에 적용했다(Supabase 전용 객체는 최소 스텁).
2. Tier 3 RPC에서 출발해 함수 본문·FK·트리거·컬럼 기본값을 따라가며 닿는 객체를 계산했다.
3. 그 객체들의 **최종 정의**를 카탈로그에서 읽어 `schema.sql`을 생성했다.
   `world_fishing_start_v1`/`input_v1`처럼 f2 → f3 → skill-effects로 세 번 재정의되는 함수는
   세 파일을 순서대로 적용한 결과가 들어 있다.

함수 78개 중 **61개는 본문이 원본과 바이트 단위로 같다**(해시 비교). 다른 17개는 아래 표가 전부다.

| 함수 | 바뀐 점 |
|---|---|
| `private.world_{activity,collection,creature,inventory,life_skill}_account_ok_v1` (5) | `auth.users` + `is_anonymous is not true` → `public.sessions` 존재. `profiles` 조인과 `is_banned = false`는 유지 |
| `private.world_fishing_require_server_v1`, `public.world_collection_list_v1`, `public.world_collection_discover_v1`, `public.world_inkyung_duck_observe_v1` (4) | `auth.role() = 'service_role'` 검사(`SERVER_ONLY`) 제거 |
| `private.world_activity_settlement_append_only_v1`, `world_creature_append_only_v1`, `world_life_nodes_append_only_v1`, `world_life_sp_append_only_v1`, `world_life_tree_resets_append_only_v1` (5) | DELETE 허용 조건이 "`auth.users` 행이 없음" → "`sessions` 행이 없음" |
| `public.get_my_rank_v3` | 시그니처 `()` → `(p_user uuid)`, `auth.uid()` → `p_user` |
| `public.claim_inha_mail_badge` | 두 계정의 `auth.users` 조회 → 기본 계정은 세션 존재, 학교 메일은 `private.inha_mail_verified_mailboxes` 조회 |
| `private.tier3_require_session_v1` | 신규. `auth.users` FK를 대신하는 트리거 함수 |

### 신원: `uuid` 컬럼이 `sessions`를 가리킨다

- 모든 `user_id uuid` / `p_user uuid`는 이제 `auth.users`가 아니라 **`public.sessions`의 행**을 뜻한다.
  RPC 시그니처는 그대로다.
- `sessions.id`는 TEXT라서 `uuid` 컬럼이 FK로 참조할 수 없다(타입 불일치). 그래서
  `FOREIGN KEY (user_id) REFERENCES auth.users` 31개를 행 트리거 `tier3_session_ref`로 바꿨다.
  `sessions.id = user_id::text`인 행이 없으면 `foreign_key_violation`(23503)을 낸다.
  **`sessions`에서 지워질 때의 cascade는 없다.**
- `sessions` 테이블은 다시 만들지 않는다. `create table if not exists`로, 없을 때만 v0.1과 같은
  컬럼(`id`, `nickname`, `created_at`)으로 만든다.
- `uuid::text`는 소문자다. `verifySession`은 헤더를 소문자로 바꿔 조회하므로, v0.1이 발급한 id가
  `crypto.randomUUID()` 그대로(소문자)라는 전제에 선다.

### 권한

`inha_world_tier3_app`(NOLOGIN 그룹 역할, DO 블록에서 생성)만 Worker가 쓴다. 할 수 있는 것:

- `sessions(id)` 조회, `profiles(user_id, is_banned)` 조회
- `ranked_sessions` 조회·삽입·수정, `ranked_runs` 삽입 (원본 Edge Function이 service key로 직접 하던 것)
- RPC 10개 실행: `world_collection_list_v1`, `world_fishing_{start,input,settle,read}_v1`,
  `world_inkyung_duck_observe_v1`, `expire_ranked_sessions_v1`, `record_ranked_result_v4/v5`, `get_my_rank_v3`

할 수 없는 것: `private` 스키마 전체, 그 외 모든 테이블, `claim_inha_mail_badge`,
`world_collection_discover_v1`, `world_fishing_observe_position_v1`. Worker가 접속할 로그인 역할은
Neon 콘솔에서 만들고 `grant inha_world_tier3_app to <로그인 역할>;`로 붙인다.

### 시드

카탈로그·정책·시드(아이템 42, 학과 67, 도감 4, 오리 4, 낚시 지점 2, 낚시 런타임 1 등)는 원본
마이그레이션을 다 적용한 뒤의 상태 그대로다. 테이블이 비어 있을 때만 넣으므로 재실행해도 운영자가
바꾼 값을 덮어쓰지 않는다.

## 원본과 달라진 점

지시서 1–6:

1. **신원이 Supabase Auth UUID에서 게스트 세션 ID로 바뀌었다.** `Authorization: Bearer <토큰>` 대신
   `X-Session-Id`. Supabase 토큰은 더 이상 자격 증명이 아니다.
2. **낚시·도감의 "익명 불가" 검사가 세션 존재 검사로 바뀌었다.** 원본 `verifyNpcAiUser`는
   `is_anonymous === false`인 유저만 받았다. 의도된 변경이다.
3. **오리 관찰의 `403 PERMANENT_ACCOUNT_REQUIRED`가 없어졌다.** 세션이 있으면 통과한다.
4. **`get_my_rank_v3`가 세션 id를 파라미터로 받는다.** (`auth.uid()` 제거)
5. **`profiles`는 세션 id 기준이고, 프로필 생성 흐름은 Tier 3 범위 밖이다.**
   프로필 행이 없는 세션은 랭크 실행 시 원본과 똑같이 `409 PROFILE_REQUIRED`를 받는다(`runType: "qa"`는 통과).
   **추가로 발견한 것:** 같은 이유로 낚시·도감·오리 관찰도 프로필 행이 없으면
   `403 ACCOUNT_UNAVAILABLE`이다. 원본에서도 프로필 없는 계정은 그랬다. 프로필 없이 열고 싶다면
   `private.world_*_account_ok_v1` 5개에서 `profiles` 조인을 빼는 결정이 따로 필요하다. 임의로 풀지 않았다.
6. **메일 인증 핸들러는 501이다.**

추가로 발견한 것:

7. **v5 → v4는 폴백이 아니라 분기다.** 지시서에는 "v5를 먼저 시도하고 실패 시 v4"로 적혀 있지만,
   원본은 세션의 `ruleset_version`이 `secret-2.2-r1`이면 v5, 아니면 v4를 **한 번만** 호출하고, 실패하면
   `500 FINISH_FAILED`다. 원본을 따랐다.
8. **`auth.users` FK → 트리거, cascade 없음.** 위 "신원" 참고. 원본은 계정 삭제 시 전부 cascade로 지워졌다.
9. **`SERVER_ONLY` 역할 검사 제거.** 함수 안의 `auth.role()` 검사 대신 EXECUTE 권한으로 막는다.
10. **RLS·정책을 옮기지 않았다.** 테이블 권한만으로 같은 범위를 만든다.
11. **랭크 테이블의 운영/분석 미러 트리거 7개와 그 테이블을 옮기지 않았다.**
    (`log_ranked_*_event`, `trg_sync_inha_duck_*`, `touch_inha_duck_ops_refresh`, `log_general_stage_best_event`,
    `games`·`players`·`runs`·`game_events` 등). 핸들러 응답에는 영향이 없지만 OPS 집계는 채워지지 않는다.
12. **Edge Function 경로가 바뀌었다.** `/functions/v1/<이름>` → `/api/<이름>`.
13. **Supabase 게이트웨이의 JWT 검사가 없다.** 원본 `config.toml`은 랭크·오리 함수에 `verify_jwt = true`라
    유효한 JWT가 없으면 함수에 닿기 전에 거절됐다. 여기서는 함수 수준의 `401 UNAUTHENTICATED`만 있다.
14. **CORS `Access-Control-Allow-Headers`에 `x-session-id`를 추가했다.** 나머지 CORS 헤더는 같다.
15. **도감의 `Vary`가 `Authorization` → `X-Session-Id`.**
16. **세션 조회 실패 시 상태코드.** 낚시 `503 AUTH_UNAVAILABLE`, 도감 `503`은 원본과 같다.
    랭크·오리는 `401`이다: 원본은 `auth.getUser()`가 실패하면 이유와 무관하게 유저 없음으로 처리했다.
    결과적으로 **DB가 내려가도 랭크·오리는 500이 아니라 401**을 낸다.
17. **`claim_inha_mail_badge`의 신원 출처.** 원본은 두 계정의 이메일·확인 여부를 `auth.users`에서 읽었다.
    세션에는 이메일이 없으므로 학교 메일은 `private.inha_mail_verified_mailboxes`에서 읽는다.
    이 테이블은 Tier 3의 어떤 코드도 쓰지 않고, 따라서 함수는 항상 실패한다.
18. **도감 레지스트리 사본.** 원본 서비스는 `src/collection/collection-discovery-contract.mjs`를 import했다.
    Worker에는 그 4개 항목 중 투영에 쓰는 필드만 복사돼 있다. 클라이언트 쪽 레지스트리가 바뀌면 같이 바꿔야 한다.
19. **타임아웃.** 세션 조회 5초(원본 Auth 조회와 같음), RPC·쿼리 10초(낚시·도감 원본과 같음).
    원본 Edge Function에는 명시적 타임아웃이 없었다.
20. **옮기지 않은 RPC.** 핸들러가 아니라 클라이언트가 `auth.uid()`로 직접 부르던 것:
    `my_inha_mail_badge`, `abandon_ranked_session_v1`, `get_my_duck_companion_v1`, `bond_my_duck_companion_v1`,
    그리고 `world_life_node_unlock_v1`, `world_life_tree_reset_v1`. Tier 3 RPC가 닿지 않는 나머지 객체도 없다.

원본과 **같게 유지한** 것(바뀌었을 것 같지만 아닌 것): 랭크 시작·종료는 원본처럼 여러 문장을 따로
실행한다(한 트랜잭션이 아니다). 프로필·카운트·랭크 조회 실패를 무시하는 것, 거절 기록 쓰기 실패를
무시하는 것도 원본 그대로다. 응답의 `startedAt`·`expiresAt`은 PostgREST와 같은 형식
(`2026-11-11T17:00:00.123456+00:00`)이다.

## 검증 방법

```sh
cd workers-tier03
npm install
node test-parity.mjs
```

실제 Postgres까지 확인하려면 `schema.sql`을 적용한 **일회용 DB**를 가리킨다.

```sh
psql "$TEST_PG_URL" -v ON_ERROR_STOP=1 -q -f schema.sql
psql "$TEST_PG_URL" -v ON_ERROR_STOP=1 -q -f test-schema.sql   # 롤백되는 트랜잭션 안에서만 실행됨, 약 3초
TEST_PG_URL="$TEST_PG_URL" node test-parity.mjs                # 만든 행은 끝에 지움
```

`TEST_PG_URL`이 loopback이 아니면 `test-parity.mjs`는 실행을 거부한다. 격리 Neon 브랜치에 한해
`TEST_PG_ALLOW_REMOTE=1`을 함께 준다. 연결 문자열은 환경 변수로만 읽고 출력하지 않는다.

### 검증 결과 (2026-11-12, 로컬)

| 검증 | 결과 |
|---|---|
| `node test-parity.mjs` (DB 없음) | **244/244 통과** |
| `TEST_PG_URL=<로컬 Postgres 16> node test-parity.mjs` | **253/253 통과** (위 244 + DB end-to-end 9) |
| `test-schema.sql` 오라클 (로컬 Postgres 16.15) | **169/169 통과** — 슈퍼유저, 그리고 Neon 소유자처럼 슈퍼유저가 아닌 `CREATEROLE` 역할 양쪽에서 |
| 원본 핸들러·RPC와 직접 대조 | **4,160쌍, 차이 0건** (아래) |
| 함수 본문 해시 비교 | 78개 중 61개 원본과 동일, 17개는 위 표의 의도한 수정 |
| 변형 검사 | `worker.js`에 결함 14개를 하나씩 넣었을 때 14개 모두 테스트가 잡음 |
| `wrangler deploy --dry-run` (4.160.1) | 번들 성공, 228 KiB / gzip 59 KiB |
| `wrangler dev --local` (workerd, `DATABASE_URL` 없음) | 가드·401·503·501 경로와 낚시 플래그 404 확인 |

**원본 직접 대조**는 이렇게 했다. 원본 쪽은 수정하지 않은 원본 핸들러(Vercel 서비스 모듈 2개, Edge Function
`index.ts` 3개)를 원본 마이그레이션 52개를 적용한 기준 DB에 물렸다. 포트 쪽은 이 Worker를 `schema.sql`을
적용한 DB에 Worker 역할로 물렸다. 같은 요청을 같은 순서로 양쪽에 보내고 상태코드·헤더·본문, 그리고
요청 뒤의 DB 상태를 비교했다(서버가 만든 id·시각만 정규화, 위 14·15번 헤더 차이만 허용).

| 구간 | 비교 쌍 | 차이 |
|---|---|---|
| ranked-run-start | 39 | 0 |
| ranked-run-finish (고정 사례 + 생성 페이로드 1,200개, 각각 응답과 DB 상태) | 2,429 | 0 |
| world-duck-observe | 30 | 0 |
| verify-inha-mail (`OPTIONS`·잘못된 메서드만; POST는 결정에 따라 다름) | 4 | 0 |
| world-fishing 가드·요청 형태 (생성 1,500개 포함) | 1,534 | 0 |
| world-fishing 상태머신 (성공·정산·취소·조기·놓침·만료·충돌·속도 제한·위치·임대) | 101 | 0 |
| world-collection-book | 23 | 0 |

생성 페이로드는 수락 444건과 거절 사유 24종을 밟았다. 이 대조에서 차이가 한 번 나왔고 고쳤다:
공백으로 8192바이트를 넘긴 유효 JSON을 원본은 처리하는데 초안은 413으로 거절했다.
대조 스크립트는 원본 코드를 읽기 전용 클론에서 직접 불러오므로 저장소에 넣지 않았다.

## 메일 인증 이식에 필요한 것

`POST /api/verify-inha-mail`은 어떤 입력에도 501이고 DB에 닿지 않는다. 검증을 흉내 내는 경로는 없다.

원본은 **Supabase Auth 토큰 두 개**(기본 계정, 인하 메일 계정)를 받아 둘 다 확인된 비익명 계정이고
서로 다르며 학교 계정 이메일이 `inha.edu` / `inha.ac.kr`일 때만 뱃지를 준다. 즉 "이 사람이 그 인하 메일
주소의 주인"이라는 증명을 Supabase Auth의 이메일 확인이 대신 해 주고 있었다.

이식하려면 먼저 정해져야 하는 것:

1. **학교 메일 소유를 무엇으로 증명하는가.** 원본의 `school_access_token`이 어떻게 발급되는지
   (학교 메일로 Supabase 가입·확인을 한 세션 토큰인지, 다른 경로인지)는 이 패키지에서 확인되지 않는다.
   Supabase Auth를 떠나면 그 증명 수단 자체를 새로 정해야 한다.
2. **기본 계정이 무엇인가.** 게스트 세션에는 이메일도 확인 상태도 없다.
3. 그 결과를 `claim_inha_mail_badge`에 어떻게 넘기는가. 지금은 `private.inha_mail_verified_mailboxes`가
   자리만 잡고 있다.

**1번이 확인되지 않으면 이 핸들러는 더 진행할 수 없다.** DB 쪽(`inha_mail_badges`, `claim_inha_mail_badge`,
`is_inha_mail`)은 옮겨져 있고 오라클로 검증했다(같은 id 거절, 미확인·비인하 주소 거절, 소문자 저장,
재클레임 멱등, 한 주소로 두 세션 불가 23505).

## 아직 안 된 것 · 확인 못 한 것

**안 한 것**

- **격리 Neon 브랜치 적용, 실제 배포.** 스키마와 함수는 로컬 Postgres 16.15에서만 돌렸다(원본은 Postgres 17).
  실제 Neon HTTP 엔드포인트를 통한 왕복은 한 번도 실행되지 않았다.
- **프로필 생성 흐름.** 없으면 위 5번대로 모든 게스트가 403 / `PROFILE_REQUIRED`다.
- **낚시 위치 피드.** `world_fishing_observe_position_v1`은 스키마에 있지만 부르는 쪽이 없다.
  원본에서 누가 불렀는지(신뢰된 실시간 서버)는 Tier 3 입력에 없다. 피드 없이 낚시를 열려면
  운영자가 `private.world_fishing_runtime.presence_required`를 `false`로 바꿔야 한다.
- **메일 인증 신원 검증**, **옮기지 않은 클라이언트 RPC**(20번), **분석 미러**(11번).
- **라우팅·컷오버, 기존 Supabase 데이터 이전.**

**미확인**

- **실제 Neon의 오류 메시지 전달.** 낚시·도감은 DB가 올린 예외 메시지(`ATTEMPT_NOT_FOUND` 등)로
  상태코드를 정한다. 드라이버가 그 메시지를 그대로 넘긴다는 것은 전송 계층을 대체한 테스트로만 확인했다.
- **Vercel에서의 깨진 JSON.** 낚시에 `application/json`으로 깨진 본문이 오면 핸들러 계약과 원본 단위 테스트는
  `400 INVALID_REQUEST`다. Vercel 런타임이 핸들러보다 먼저 본문을 파싱하므로 실제 배포에서는 다른 코드가
  나갔을 수 있다. 계약대로 400으로 했다.
- **인증 백엔드 장애 시 401**(16번)은 supabase-js가 그 실패를 예외가 아니라 오류 값으로 돌려준다는
  이해에 근거한다. 원본 테스트에 그 사례는 없다.
- **원본 pgTAP 스위트를 기준 DB에서 직접 실행하지는 못했다**(pgTAP 미설치). 기준 DB는 Supabase 플랫폼 객체
  (`auth`, `realtime`, 역할)를 최소 스텁으로 대체해 만들었다.
- **v0.1 세션 id가 전부 소문자 UUID인지**는 라이브 DB를 보지 않았으므로 확인하지 않았다.
