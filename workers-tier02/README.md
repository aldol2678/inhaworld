# INHA WORLD — Tier 2 텔레메트리 Worker (Workers + Neon, 격리 테스트용)

Vercel + Supabase에서 돌던 텔레메트리 핸들러 3개를 Cloudflare Workers + Neon으로 옮긴 것이다.
원본은 `aldol2678/inhagame` HEAD `0b72d259`의 `apps/world/api/hub-entry.js`, `hub-event.js`,
`asset-canary-flag.js`이며 읽기 전용으로만 참고했다. 원본 저장소, 라이브 Worker, 라이브 Neon DB
(`inha-world-sync`), 라이브 배포는 건드리지 않았다.

**현재 상태: 코드와 로컬 검증까지만 끝났다. 격리 Neon 브랜치 적용과 실제 배포는 하지 않았다.**
(아래 "아직 안 된 것" 참고)

## 범위

| 경로 | 원본 | 동작 |
|---|---|---|
| `POST /api/hub-entry` (+ `OPTIONS`) | `api/hub-entry.js` → RPC `log_inhagame_game_entry_v1` | 게임 유입 퍼널 단계 기록. Origin allowlist 5개, UUID 2종, 이벤트 7종, 본문 512자. `204` 저장됨 / `409` 거절됨. |
| `POST /api/hub-event` | `api/hub-event.js` → RPC `log_inhagame_hub_event_v2` | 허브·캠퍼스 텔레메트리 기록. same-host Origin, UUID 3종, 이벤트 33종, 본문 1024자. `204` 저장됨 / `400` 거절됨. |
| `GET /api/asset-canary-flag` | `api/asset-canary-flag.js` → `world_runtime_flags` | `asset_glb_canary_v1` 1행 조회. `200 {"enabled":bool}` / 실패는 전부 `503` (클라이언트는 카나리 off로 처리). 200 응답은 Cache API에 5초 캐시(원본 Vercel CDN `s-maxage=5`와 같음). |

가드 순서는 원본과 같다.

- **hub-entry:** Origin allowlist(403) → CORS 헤더 설정 → `OPTIONS`(204) → 메서드(405) → 본문 크기(413) → JSON(400) → 필드 검증(400) → DB.
- **hub-event:** 메서드(405) → same-host Origin(403) → 본문 크기(413) → JSON(400) → 필드 검증(400) → DB.
- **asset-canary-flag:** 메서드(405, `Allow: GET`) → DB.

DB 단계의 상태코드:

| 상황 | hub-entry | hub-event | canary |
|---|---|---|---|
| 함수가 `true` 반환 (저장 또는 멱등 재전송) | 204 | 204 | — |
| 함수가 `false` 반환 (거절) | 409 | 400 | — |
| DB가 오류로 응답 (원본: Supabase가 non-2xx) | 502 | 502 | 503 |
| 연결 실패·타임아웃·응답 해석 불가·`DATABASE_URL` 미설정 | 503 | 503 | 503 |

타임아웃은 원본과 같이 4000ms(로거 2개), 1200ms(플래그)다.

### 409의 의미 (작업 지시서와 다른 점)

지시서와 계획서에는 "204 accepted / 409 duplicate"로 적혀 있지만, 원본에서 409는 **중복이 아니라 거절**이다.

- 원본 RPC는 같은 `event_id`가 다시 오면 `on conflict do nothing` 후 `true`를 돌려준다 → **204**.
  오라클 `10_hub_telemetry.test.sql`: "a duplicate event_id is accepted without effect (idempotent)".
- 409는 RPC가 `false`를 돌려줄 때다: 30분 안의 허브 클릭이 없음, 다른 게임의 entry 재사용, 이전 단계가 아직 없음.
- 클라이언트 `game-entry.js`는 409를 "클릭이나 이전 단계가 아직 저장 안 됨"으로 보고 최대 4번 재시도한다.
  중복을 409로 바꾸면 이미 저장된 이벤트를 계속 재시도하게 된다.

그래서 원본과 오라클을 따랐다. `game_entries.event_id`는 PK(UNIQUE)이고, 중복은 저장되지 않으며 204다.

## 파일

| 파일 | 내용 |
|---|---|
| `schema.sql` | Neon 스키마: 테이블 3개, 뷰 1개, 함수 2개, 최소 권한 그룹 역할. 여러 번 실행해도 안전. |
| `worker.js` | Worker 본체. Tier 01과 같은 단일 파일·핸들러별 함수·정확한 경로 일치 라우터. |
| `wrangler.toml` | Worker 이름 `inha-world-tier02-test`. `[vars]`·라우트 없음. 매일 03:00 UTC Cron Trigger(`[triggers] crons`) 있음. |
| `test-parity.mjs` | 패리티 테스트 (`node test-parity.mjs`). DB 없이 실행되고, `TEST_PG_URL`을 주면 실제 Postgres로 end-to-end까지 확인. 카나리 5초 캐시와 scheduled purge 핸들러 테스트 포함. |
| `test-schema.sql` | DB 쪽 동등성 오라클. 원본 pgTAP 2개를 plain SQL로 옮긴 것 + `purge_telemetry_90d` 신규 검증 5건. |
| `package.json`, `package-lock.json` | `@neondatabase/serverless` 0.10.4 고정. `pg`는 선택적 통합 테스트용 devDependency. |

## 스키마

원본은 허브 이벤트와 게임 진입 단계를 `inhagame_hub_events` 한 테이블에 `entry_id` 유무로 구분해 넣는다.
여기서는 지시대로 두 테이블로 나눴다.

- **`hub_events`** — `event_id` PK. 원본의 이벤트·surface·target·acquisition·campaign CHECK와
  컨텍스트 CHECK(이벤트별 허용 surface/target, NULL도 거절하는 2값 형태)를 그대로 옮겼다.
- **`game_entries`** — `event_id` PK(UNIQUE), `entry_id`는 유입시킨 허브 클릭의 `event_id`.
  `(entry_id, event_type)` UNIQUE로 단계당 1행. `session_id`·`visitor_id`·`acquisition_source`·`campaign`은
  클릭 행에서 복사한다(게임이 보낸 값이 아님).
- **`runtime_flags`** — `flag` PK, `enabled boolean not null default false`. 허용 플래그 이름은
  `asset_glb_canary_v1` 하나로 CHECK. 시드 행은 원본 마이그레이션과 같이 `enabled = false`.
- **`hub_events_all`** (뷰) — 두 테이블을 원본 행 모양으로 합친 것. 아직 이식 안 한 OPS 집계용.
- **`log_hub_event_v2(...)`, `log_game_entry_v1(...)`** — 원본 RPC의 plpgsql 이식. `security definer`,
  `search_path = ''`. 한 번의 호출이 한 트랜잭션이라 검증·순서 확인·삽입이 원자적이다.
  세션당 시간당 120건 제한은 원본처럼 두 종류의 행을 합쳐서 센다.
- **`purge_telemetry_90d()`** — 원본 `private.purge_inhagame_hub_events_90d()`의 이식. 90일 지난
  행을 두 테이블에서 각각 최대 5000건씩 지우고 지운 총건수를 돌려준다. Worker의 매일 03:00 UTC
  Cron Trigger(scheduled 핸들러)가 호출한다. 멱등이라 실패 시 재시도해도 안전하다.
- **`inha_world_tier2_app`** (NOLOGIN 그룹 역할) — 원본의 `anon` 권한 범위와 같다. 두 함수 실행과
  `runtime_flags` 조회만 가능하고, 이벤트 테이블을 직접 읽거나 쓰거나 플래그를 바꿀 수 없다.
  Worker가 접속할 로그인 역할은 Neon 콘솔에서 만들고(비밀번호는 파일에 두지 않음)
  `grant inha_world_tier2_app to <로그인 역할>;`로 붙인다.

DB 접근은 `@neondatabase/serverless` 0.10.4의 태그 템플릿 호출이다
(``sql`select ... ${value}` `` — 값은 전부 `$1..$n` 바인드 파라미터로 나가고, SQL 문자열에 섞이지 않는다.
`sql([statement], ...values)`와 같은 호출 형태다).

## 검증 방법

```sh
cd workers-tier02
npm install
node test-parity.mjs
```

DB나 네트워크 없이 돈다. 수정하지 않은 `worker.js`를 실제 Neon 드라이버와 함께 실행하고, 드라이버의
HTTP 전송 계층(`neonConfig.fetchFunction`)만 대체한다. 원본 계약 테스트가 `fetch`를 대체하는 것과 같은 방식이다.

실제 Postgres까지 확인하려면 `schema.sql`을 적용한 **일회용 DB**를 가리킨다.

```sh
psql "$TEST_PG_URL" -v ON_ERROR_STOP=1 -q -f schema.sql
psql "$TEST_PG_URL" -v ON_ERROR_STOP=1 -q -f test-schema.sql   # 롤백되는 트랜잭션 안에서만 실행됨
TEST_PG_URL="$TEST_PG_URL" node test-parity.mjs                # 만든 행은 끝에 지움
```

`TEST_PG_URL`이 loopback이 아니면 `test-parity.mjs`는 실행을 거부한다. 격리 Neon 브랜치에 한해
`TEST_PG_ALLOW_REMOTE=1`을 함께 준다. 연결 문자열은 환경 변수로만 읽고 출력하지 않는다.

### 검증 결과 (2026-11-11, 로컬)

| 검증 | 결과 |
|---|---|
| `node test-parity.mjs` (DB 없음) | **185/185 통과** (카나리 캐시 3건 + scheduled purge 2건 포함) |
| `TEST_PG_URL=<로컬 Postgres 16.15> node test-parity.mjs` | 미측정 — 이 환경에서는 pg TCP 연결이 안 돼 end-to-end를 실행할 수 없다(아래 참고). 구조는 DB-less 185 + end-to-end 14건. |
| `test-schema.sql` (격리 Neon, HTTP 드라이버 경유) | **101/101 통과** (purge 신규 5건 포함) |
| 원본 핸들러와 차등 비교 | 요청 1,734개 × 업스트림 응답 조합 2,825쌍에서 **상태코드·헤더·본문·업스트림 호출 여부 전부 일치**. 유일한 차이는 아래 "원본과 달라진 점" 7번의 파라미터 직렬화 160쌍(상태코드는 같음). |
| 변형 검사 | `worker.js`에 결함 9개를 하나씩 넣었을 때 8개를 테스트가 잡음. 남은 1개는 동작이 같은 변형(`target` 대신 이미 같은 값으로 검증된 `body.target` 사용). |
| `wrangler deploy --dry-run` (4.160.0) | 번들 성공, 201 KiB / gzip 53 KiB |
| `wrangler dev --local` (workerd, `DATABASE_URL` 없음) | canary GET 503 / POST 405, hub-entry 403·204(OPTIONS)·405·400·503, hub-event 405·403·413·503, 그 외 404 |

차등 비교는 원본 핸들러 파일을 읽기 전용 클론에서 직접 불러와 같은 입력을 넣은 일회성 스크립트라서
저장소에는 넣지 않았다(원본 코드를 이 저장소에 두지 않기 위해). 원본에 문자열 본문을 넘기는
`text/plain` 경로 기준이다.

패리티 테스트가 다루는 것: 메서드, Origin(allowlist·same-host·prototype 키), UUID, 이벤트 화이트리스트,
본문 크기 경계(512/513, 1024/1025), JSON 오류, 가드 순서, 함수 반환값별 상태코드, DB 오류 502, 연결 실패·
타임아웃·`DATABASE_URL` 미설정 503, 계정 필드·Authorization·Cookie가 DB로 넘어가지 않는 것,
카나리 5초 캐시(적중·미적중·만료·503 미캐시), scheduled purge 핸들러(호출·실패 전파).

## 격리 배포 방법 (아직 실행하지 않음)

라이브 `inha-world-sync` DB와 라이브 Worker는 대상이 아니다. 아래는 전부 새 격리 리소스다.

1. **격리 Neon 브랜치(또는 별도 프로젝트) 만들기** — 콘솔 또는 `neonctl branches create --name tier2-test`.
2. **스키마 적용** — 그 브랜치의 소유자 연결 문자열을 셸 변수로만 두고:
   `psql "$ISOLATED_URL" -v ON_ERROR_STOP=1 -q -f schema.sql`
3. **DB 오라클 실행** — `psql "$ISOLATED_URL" -v ON_ERROR_STOP=1 -q -f test-schema.sql` → `96/96 passed`.
4. **Worker용 로그인 역할** — 콘솔에서 만들고 `grant inha_world_tier2_app to <로그인 역할>;`.
   소유자 역할로 Worker를 접속시키지 않는다.
5. **end-to-end** — `TEST_PG_URL="$ISOLATED_URL" TEST_PG_ALLOW_REMOTE=1 node test-parity.mjs`.
6. **Worker 배포** — `npx wrangler deploy` (새 Worker `inha-world-tier02-test`, workers.dev 전용).
   이 시점에는 시크릿이 없으므로 로컬 `wrangler dev`와 같은 503 경로가 나와야 한다.
7. **시크릿** — `npx wrangler secret put DATABASE_URL` 에 4번 로그인 역할의 연결 문자열을 입력.
   파일·`[vars]`·로그·커밋에 넣지 않는다.
8. **curl 확인** — `GET /api/asset-canary-flag` → `200 {"enabled":false}`,
   `POST /api/hub-event`(Origin 없음, 유효 본문) → 204, 같은 `event_id` 재전송 → 204,
   `POST /api/hub-entry`(`Origin: https://duck.inhagame.app`, 없는 `entry_id`) → 409.
   SQL로 플래그를 `true`로 바꾸면 다음 GET이 `{"enabled":true}`인지 확인.

`wrangler dev`는 로컬(`--local`)에서만 실행한다.

## 원본과 달라진 점

1. **409는 중복이 아니라 거절** — 위 "409의 의미". 지시서 문구와 다르고 원본과는 같다.
2. **본문 읽기** — 원본은 Vercel이 넘겨준 `req.body`가 문자열·Buffer일 때만 크기 제한과 JSON 파싱을 하고,
   이미 객체면(`Content-Type: application/json`) 그대로 쓴다. Worker는 Content-Type과 무관하게 항상
   원문을 읽어 크기 제한 → JSON 파싱을 한다. 결과적으로 `application/json` 본문에도 512/1024자 제한이
   걸린다(더 엄격). 실제 클라이언트 본문은 200자 안팎이라 영향이 없다. 반대로 Content-Type이 없거나
   알 수 없는 요청은 원본에서 본문이 비어 400이 되지만 Worker는 JSON이면 처리한다.
3. **hub-entry Origin 조회** — 원본은 `ORIGINS[origin]`이라 `constructor` 같은 prototype 키가 403 가드를
   통과한 뒤 400이 된다. Worker는 own property만 보므로 바로 403이다.
4. **테이블 분리** — 한 테이블이 `hub_events` + `game_entries`로 나뉘었다. 원본에서 `event_id`는 두 종류를
   통틀어 유일했는데, 여기서는 DB 제약이 아니라 두 함수 안의 확인으로 맞춘다(동시 요청 사이의 아주 좁은
   틈이 있고, 그 경우에도 각 테이블 안에서는 PK로 유일하다).
5. **502/503 구분 기준** — 원본은 "Supabase가 non-2xx로 응답"이 502, "fetch 자체가 실패"가 503이다.
   Neon HTTP 드라이버에서는 `sourceError` 없는 `NeonDbError`(DB나 Neon 프록시가 오류로 응답)를 502,
   나머지(연결 문자열 없음, 네트워크 실패, 타임아웃, 응답 해석 불가)를 503으로 대응시켰다.
6. **권한 모델** — Supabase의 `anon` + RLS 대신 `inha_world_tier2_app` 그룹 역할의 권한만으로 같은 범위를 만든다.
7. **UUID 정규식의 암묵적 형변환** — `UUID.test()`가 `["<uuid>"]` 같은 1원소 배열을 통과시키는 것은 원본과 같다.
   원본은 PostgREST가, 여기서는 Postgres 캐스트가 거부해서 둘 다 502다. DB로 넘어가는 값의 직렬화만 다르다.
8. **`Vercel-CDN-Cache-Control` 헤더** — 원본과 같은 값으로 내보낸다. Cloudflare CDN이 이 헤더를
   보지는 않지만, Worker가 Cache API(`caches.default`)로 200 응답을 직접 5초 캐시하므로 원본과
   같은 5초 의미가 유지된다. 200 응답의 `Cache-Control`은 원본의 `no-store`에서
   `public, max-age=5`로 바뀌었다(503·405는 그대로 `no-store`).

## 아직 안 된 것

- **격리 Neon 브랜치 적용 미실시.** 스키마와 함수는 로컬 Postgres 16.15에서만 검증했다. Neon에서의
  역할 생성(`create role ... nologin`)과 권한 부여는 슈퍼유저가 아닌 `CREATEROLE` 역할로 로컬에서
  흉내만 냈다.
- **실제 배포 미실시.** Worker는 `wrangler deploy --dry-run`과 로컬 `wrangler dev`까지만 했다.
  실제 Neon HTTP 엔드포인트를 통한 왕복(드라이버 → Neon → 함수)은 한 번도 실행되지 않았다.
  DB 연결 경로는 전송 계층을 대체한 테스트로만 확인했다.
- **OPS 집계 `get_inhagame_hub_ops_v1`** — 핸들러가 호출하지 않아 이식하지 않았다.
- **90일 보존 정리** — `purge_telemetry_90d()`와 매일 03:00 UTC Cron Trigger로 이식했다.
  Cron은 배포된 Worker에 등록되며, 처음 실행은 다음 03:00 UTC다.
- **라우팅·컷오버** — 클라이언트는 `https://inhagame.app/api/hub-entry`와 상대 경로 `/api/hub-event`를
  호출한다. 이 Worker를 그 경로에 붙이는 일과 기존 Supabase 데이터 이전은 이 작업 범위가 아니다.
- **Tier 3(낚시·도감·Auth·랭크·메일), Tier 4(브랜드)** — 범위 밖. Auth 설계는 별도 승인 게이트다.
