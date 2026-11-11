# INHA WORLD — Vercel API 핸들러 인벤토리 (Cloudflare 이전용)

- **Source (read-only):** `~/workspace/inhagame-github-check/apps/world` — `aldol2678/inhagame`, HEAD `0b72d259` (2026-11-01, #450), `apps/world` only
- **Date:** 2026-11-11
- **Scope:** `apps/world/api/*.js` 17개 핸들러, `apps/world/server/`, repo-root `supabase/functions/` 5개. 읽기 전용 조사. 비밀값은 읽지 않았고, 환경변수·테이블·RPC·호스트는 **이름만** 기록.
- **Route convention:** Vercel 파일 라우팅 — `api/<name>.js` → `/api/<name>`. 전부 CommonJS (`module.exports = handler`, `(req, res)`).

## 1. 핸들러 17개 요약표

| # | Route | Methods | Purpose (1 line) | Supabase 사용 | 환경변수 | 외부 호출 (호스트만) |
|---|-------|---------|------------------|---------------|----------|---------------------|
| 1 | `/api/asset-canary-flag` | GET | GLB 카나리 플래그(`asset_glb_canary_v1`) on/off 조회 | REST `world_runtime_flags` 테이블 조회 | `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` | `SUPABASE_URL` 호스트 |
| 2 | `/api/brand-asset` | GET, HEAD | 브랜드 GLB 바이트 프록시 (가구류는 서명 URL 307 리다이렉트) | Edge Functions `inhagame-world-brand-assets-v1` / `inhagame-world-brand-assets-optimized-v1`; Storage 버킷 `inhagame-furniture-private` (서명 URL) | `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` | `SUPABASE_URL` 호스트 |
| 3 | `/api/brand-induck` | GET, HEAD | 인덕 브랜드 GLB 프록시 | Edge Function `inhagame-induck-brand-v1` | `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` | `SUPABASE_URL` 호스트 |
| 4 | `/api/brand-media` | GET, HEAD | 브랜드 미디어 프록시 (indeoki.png, annyongi.png, biryong-tower-01.mp3) | Edge Function `inhagame-brand-media-v1` | `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` | `SUPABASE_URL` 호스트 |
| 5 | `/api/dev-status` | GET | 배포/소스 상태 조회 (GitHub main SHA vs 배포 SHA 비교, 읽기 전용) | 없음 | `VERCEL_GIT_COMMIT_SHA`, `VERCEL_ENV` | `api.github.com` |
| 6 | `/api/hub-entry` | POST, OPTIONS | 게임 유입 퍼널 이벤트 기록 (landing/play/error/result/clear/retry/ranked) | RPC `log_inhagame_game_entry_v1` | `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` | `SUPABASE_URL` 호스트 |
| 7 | `/api/hub-event` | POST | 허브 텔레메트리 이벤트 기록 | RPC `log_inhagame_hub_event_v2` | `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` | `SUPABASE_URL` 호스트 |
| 8 | `/api/model-convert` | GET (probe), POST | 모델 변환 Cloud Run 프록시 (회원 세션 검증 + 허용목록 + 속도 제한 게이트) | Auth 검증 (`npc-ai-auth.mjs` → `/auth/v1/user`) | `MODEL_CONVERT_CLOUD_RUN_URL`, `MODEL_CONVERT_ENABLED`, `MODEL_CONVERT_PROXY_SECRET`, `MODEL_CONVERT_ALLOWED_USER_IDS`, `MODEL_CONVERT_RATE_USER_MAX`, `MODEL_CONVERT_RATE_IP_MAX`, `MODEL_CONVERT_RATE_WINDOW_SEC`, `MODEL_CONVERT_RATE_AUTH_FAIL_IP_MAX`, `MODEL_CONVERT_RATE_AUTH_FAIL_WINDOW_SEC`, `VERCEL` | `MODEL_CONVERT_CLOUD_RUN_URL` 호스트, `SUPABASE_URL` 호스트 (Auth) |
| 9 | `/api/npc-ai` | GET (probe), POST | NPC AI Cloud Run 얇은 프록시 (Bearer 토큰 그대로 전달) | 없음 (직접; 인증은 업스트림이 Bearer로 검증) | `NPC_AI_CLOUD_RUN_URL`, `NPC_AI_ENABLED` | `NPC_AI_CLOUD_RUN_URL` 호스트 |
| 10 | `/api/npc-dialogue-route` | GET (probe), POST | NPC 대화 판단 JEV 실험 전용 (권한 효과 없음, shadow) | Auth 검증 (`npc-ai-auth.mjs`) | `NPC_JEV_ENABLED`, `TYPESAFE_API_KEY`, `TYPESAFE_MODEL`, `TYPESAFE_SYSTEMONE_URL` | `TYPESAFE_SYSTEMONE_URL` 호스트, `SUPABASE_URL` 호스트 (Auth) |
| 11 | `/api/npc-relationship` | GET (probe), POST | NPC 관계 이벤트를 Cloud Run `/relationship`으로 프록시 | 없음 (직접) | `NPC_AI_CLOUD_RUN_URL`, `NPC_RELATIONSHIP_ENABLED` | `NPC_AI_CLOUD_RUN_URL` 호스트 |
| 12 | `/api/npc-shared-state` | GET | 장소 구역별 공유 NPC 권한 스냅샷 (인메모리 P0, DB 없음) | 없음 | `NPC_SHARED_AUTHORITY_P0` | 없음 |
| 13 | `/api/public-supabase-config` | GET | 공개 Supabase URL + publishable key를 JS로 서빙 (미설정 시 503 JS `console.error`) | 없음 (설정값만 반환) | `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` | 없음 |
| 14 | `/api/world-collection-book` | (서비스가 처리; 기본 GET) | 도감(컬렉션 북) 본인 전용 읽기 | RPC `world_collection_list_v1` (service-role), Auth 검증 | `SUPABASE_SERVICE_ROLE_KEY` (+ `SUPABASE_URL`은 설정 모듈 경유) | `SUPABASE_URL` 호스트 |
| 15 | `/api/world-fishing` | (서비스가 처리) | 낚시 게임 서비스 (start/input/<op>) | RPC `world_fishing_start_v1`, `world_fishing_input_v1`, `world_fishing_<op>_v1` (service-role), Auth 검증 | `WORLD_FISHING_API_ENABLED`, `SUPABASE_SERVICE_ROLE_KEY` (+ `SUPABASE_URL`은 설정 모듈 경유) | `SUPABASE_URL` 호스트 |
| 16 | `/api/world-quest` | GET (probe), POST | 퀘스트 이벤트를 Cloud Run `/quest`로 프록시 | 없음 (직접) | `NPC_AI_CLOUD_RUN_URL`, `NPC_QUEST_ENABLED` | `NPC_AI_CLOUD_RUN_URL` 호스트 |
| 17 | `/api/world-time` | GET | 공개 읽기 전용 서버 시계 | 없음 | 없음 | 없음 |

### 핸들러별 메모

- **1 asset-canary-flag:** `world_runtime_flags`에서 `flag=eq.asset_glb_canary_v1` 1행 조회, `enabled` boolean 반환. 실패 시 503 (클라이언트는 카나리 off로 처리).
- **2 brand-asset:** 허용 GLB 5종(인덕 v3, 안뇽이 비행, 캡/백팩/후드) + 가구 GLB 5종. `variant=optimized`면 optimized 함수, 아니면 canonical 함수. 가구류는 Edge Function이 307 + 서명 URL 반환 → sha256/바이트수 검증 후 그대로 307 중계, `Cache-Control: no-store`. `annyongi-flight-v1.glb`는 `revision=5cc0bc54…` 고정 파라미터 첨부. GLB 매직 바이트(`glTF`) 검증 있음.
- **3 brand-induck / 4 brand-media:** 구조 동일 — Edge Function 프록시 + GLB/미디어 바이트 검증. brand-media 허용 목록은 이미지 2개 + mp3 1개뿐.
- **5 dev-status:** GitHub API로 main 브랜치 SHA 조회 후 `VERCEL_GIT_COMMIT_SHA`와 비교. 월드 런타임이 아니라 운영/상태 확인용. 클라이언트 호출처 없음 (외부 모니터링/상태 페이지용으로 보임). Cloudflare 이전 시 `VERCEL_GIT_COMMIT_SHA`/`VERCEL_ENV`는 존재하지 않으므로 `CF_PAGES_COMMIT_SHA`/`CF_PAGES_BRANCH` 등으로 교체 필요.
- **6 hub-entry:** Origin allowlist 5개(`inhagame.app`, `duck/induckup/survival/grow.inhagame.app`) + UUID 검증 + 이벤트 7종 화이트리스트. 204 accepted / 409 duplicate. 클라이언트(`game-entry.js`)는 `ih_entry` 파라미터가 있고 호스트가 allowlist에 있을 때만 호출 — 격리 테스트 도메인에서는 호출 자체가 안 됨.
- **7 hub-event:** 이벤트 30여 종 화이트리스트, `session_id`/`visitor_id` UUID 검증, same-host Origin 검사. 클라이언트(`hub-telemetry.js`)가 상대 경로로 POST — 정적 테스트에서는 Pages 405로 실패하고 fire-and-forget이라 무시됨.
- **8 model-convert:** `GET`은 `{enabled}`만 반환. POST는 게이트(`server/model-convert-gate.mjs`) 경유: Supabase 회원 세션 확인 → 허용목록 → per-user/per-IP 속도 제한 → Cloud Run 프록시. 속도 제한은 **서버리스 인스턴스별 인메모리 슬라이딩 윈도우** (공유 상태 없음).
- **9 npc-ai / 11 npc-relationship / 16 world-quest:** 같은 패턴의 얇은 프록시. `GET`은 `{enabled:true}` probe, `POST`는 Bearer 필수 + same-host Origin 검사 + 본문 크기 제한(2048 / 256 / 256 바이트) 후 Cloud Run으로 전달 (`/`, `/relationship`, `/quest`). 미설정 시 404. 클라이언트는 기능 플래그 probe(`probeFeatureFlag`)로 GET을 먼저 찔러보고, 404/실패면 기능 off로 처리 — 그래서 게스트/정적 환경에서도 조용히 꺼짐.
- **10 npc-dialogue-route:** 실험 전용. Supabase 유저 검증 후 Typesafe/SystemOne LLM(`TYPESAFE_MODEL`, 기본 `jev-latest`)에 판단 위임, 결과에 `shadow.latencyMs` 첨부. `NPC_JEV_ENABLED=1` + API 키 없으면 404.
- **12 npc-shared-state:** `NPC_SHARED_AUTHORITY_P0=1`일 때만 동작. `placeZoneId` 없으면 `{enabled:true}`, 있으면 `AREA_[A-Z0-9_]{1,60}` 패턴 검증 후 `npc-shared-authority-server.mjs`의 인메모리 스냅샷 반환. DB·외부 호출 없음. 다만 **공유 상태가 인메모리**라서 멀티 인스턴스 환경(Workers)에서는 인스턴스 간 공유가 안 됨 — 스냅샷이 정적 데이터에서 결정적으로 계산되는지 확인 후 Durable Object 또는 순수 함수화 필요.
- **13 public-supabase-config:** 설정이 유효하면 `globalThis.__INHAGAME_PUBLIC_SUPABASE__ = Object.freeze({url, publishableKey})` JS 반환, 아니면 503 JS(`console.error('INHAGAME public Supabase config is unavailable')`). 클라이언트는 없으면 내장 플레이스홀더(`http://127.0.0.1:54321`)로 폴백 — 정적 테스트의 stand-in이 이 503 본문을 그대로 재현한 것.
- **14 world-collection-book:** `server/collection-book-service.mjs` 경유. RPC는 `world_collection_list_v1` 하나만 허용(allowlist). service-role 키로 REST RPC 호출, 본인 데이터만 투영(내부 ID/제목 등 노출 안 함).
- **15 world-fishing:** `server/fishing-service.mjs` 경유. RPC 3종(`world_fishing_start_v1`, `world_fishing_input_v1`, `world_fishing_<op>_v1`), `p_user`는 소문자 회원 ID. `WORLD_FISHING_API_ENABLED=1` 아니면 404.
- **17 world-time:** 순수 함수(`npc-factory/npc-world-time-contract.mjs`의 `worldTimePayload()`). DB·환경변수·외부 호출 전무. 가장 쉽게 포팅 가능. 클라이언트 내 직접 호출처는 못 찾음 (NPC 시간 계약용 유틸로 보임).

### 공통 패턴

- **인증:** `npc-factory/npc-ai-auth.mjs`의 `verifyNpcAiUser` — `SUPABASE_URL/auth/v1/user`에 Bearer 토큰으로 조회해서 user id 반환. 쓰는 핸들러: model-convert, npc-dialogue-route, world-collection-book, world-fishing.
- **Service-role 사용:** world-collection-book, world-fishing만 `SUPABASE_SERVICE_ROLE_KEY` 사용 (REST RPC 호출용, 브라우저에는 절대 안 들어감).
- **Cloud Run 프록시:** npc-ai, npc-relationship, world-quest, model-convert가 각자 `*_CLOUD_RUN_URL`로 전달. NPC AI 백엔드 자체는 Cloud Run에 남는 구조.
- **환경변수 전체 목록 (이름만):** `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `NPC_AI_CLOUD_RUN_URL`, `NPC_AI_ENABLED`, `NPC_QUEST_ENABLED`, `NPC_RELATIONSHIP_ENABLED`, `NPC_JEV_ENABLED`, `TYPESAFE_API_KEY`, `TYPESAFE_MODEL`, `TYPESAFE_SYSTEMONE_URL`, `MODEL_CONVERT_CLOUD_RUN_URL`, `MODEL_CONVERT_ENABLED`, `MODEL_CONVERT_PROXY_SECRET`, `MODEL_CONVERT_ALLOWED_USER_IDS`, `MODEL_CONVERT_RATE_USER_MAX`, `MODEL_CONVERT_RATE_IP_MAX`, `MODEL_CONVERT_RATE_WINDOW_SEC`, `MODEL_CONVERT_RATE_AUTH_FAIL_IP_MAX`, `MODEL_CONVERT_RATE_AUTH_FAIL_WINDOW_SEC`, `WORLD_FISHING_API_ENABLED`, `NPC_SHARED_AUTHORITY_P0`, `VERCEL_GIT_COMMIT_SHA`, `VERCEL_ENV`, `VERCEL`.

## 2. `server/` 요약

`apps/world/server/`는 핸들러 뒤의 서비스 계층(순수 ESM, Node 전용 API 없음). 월드 클라이언트는 `server/`를 직접 호출하지 않고, 핸들러 3개(`world-collection-book`, `world-fishing`, `model-convert`)만 경유한다.

| 파일 | 행수 | 역할 | 런타임 필요 여부 |
|------|------|------|-----------------|
| `collection-book-service.mjs` | 104 | 도감 읽기 서비스. `createCollectionBookRpc`는 `world_collection_list_v1` RPC 하나만 허용하는 service-role REST 클라이언트. `createCollectionBookService`는 본인 데이터만 투영해서 반환. | `world-collection-book` 핸들러를 포팅할 때만 필요 |
| `fishing-service.mjs` | 110 | 낚시 서비스. `world_fishing_start_v1` / `world_fishing_input_v1` / `world_fishing_<op>_v1` RPC 호출, `p_user` 소문자화. | `world-fishing` 핸들러를 포팅할 때만 필요 |
| `model-convert-gate.mjs` | 255 | 모델 변환 게이트. 인메모리 슬라이딩 윈도우 속도 제한(per-user / per-IP / 인증 실패 IP), 허용목록(env), 클라이언트 IP 파싱(`trustProxyHeaders`), Cloud Run 프록시 핸들러 생성. | `model-convert` 핸들러를 포팅할 때만 필요. 단, 속도 제한이 인스턴스별 인메모리라 Workers 멀티 인스턴스에서는 공유 안 됨 — KV/Durable Object로 옮기거나 제한을 완화해야 함 |
| `fishing-f2.md`, `fishing-f3.md` | — | 낚시 기능 스펙 문서. 런타임 코드 아님 | 불필요 |

## 3. Supabase Edge Functions (repo-root `supabase/functions/`, 5개)

| 함수 | Purpose (1 line) |
|------|------------------|
| `ranked-run-start` | 랭크 게임(오리 클래식) 런 시작 — 인증 확인 후 룰셋 버전(`secret-2.1-r1`/`2.2-r1`)과 함께 세션 개시 |
| `ranked-run-finish` | 랭크 런 종료 — 결과 검증 후 점수 제출/확정 |
| `verify-inha-mail` | 인하대 메일 인증 — 학교 액세스 토큰 + Supabase Auth로 인하 메일 소유 확인 |
| `world-duck-observe` | 인경호 오리 4마리(`inkyung_duck_white_01~03`, `inkyung_duck_mallard_01`) 관찰 기록 |
| `inhagame-world-brand-assets-optimized-v1` | 브랜드 GLB 최적화 — canonical 함수를 소스로 받아 gltf-transform(dedup/prune)으로 최적화, 필수 노드(DuckWing/DuckLeg, DragonWing) 검증 |

**⚠️ 주의 — 핸들러가 참조하는데 이 repo에 없는 함수 3개:** `inhagame-world-brand-assets-v1` (canonical, brand-asset이 소스로 사용), `inhagame-induck-brand-v1` (brand-induck), `inhagame-brand-media-v1` (brand-media). `supabase/functions/`에는 없음. 별도 repo에서 배포되거나 누락된 상태 — brand 계열 핸들러를 포팅하려면 이 3개 함수의 소재를 먼저 확인해야 함.

## 4. 정적 테스트에서 이미 불필요함이 증명된 것 vs 로그인/온라인 월드에 필요한 것

정적 테스트(2026-11-11, `inha-world-github-static-test.pages.dev`, Steel 스모크 4차: pageerror 0건, 10/30/60초 3D 렌더)가 **핸들러 없이도** 증명한 것:

- **핸들러 없이 되는 것 (게스트 모드):** 허브 렌더, 월드 부팅·3D 렌더, NPC 스폰, 퀘스트 HUD 표시, 미니맵. 게스트는 `인덕이` 닉네임으로 오프라인 플레이.
- **게스트 모드에서 클라이언트가 찌르지만 없어도 조용히 꺼지는 것:** 기능 플래그 probe `GET /api/npc-ai`, `/api/world-quest`, `/api/npc-relationship`, `/api/npc-dialogue-route`, `/api/npc-shared-state` (404/실패 → 기능 off), `GET /api/asset-canary-flag` (503 → 카나리 off), `POST /api/hub-event` (정적 Pages 405, fire-and-forget이라 무시됨), `GET /api/public-supabase-config` (정적 stand-in으로 대체 완료, 미설정 시 본문과 동일). 즉 이 8개는 **게스트 월드에 필수가 아님** — 없어도 월드는 뜬다.
- **게스트 모드에서 아예 호출 안 되는 것:** `/api/hub-entry` (호스트가 inhagame.app 계열 + `ih_entry` 파라미터일 때만 호출), `/api/brand-asset` (방/가구 기능 진입 시에만 — 오리 본체는 로컬 `assets/induck-v3.glb` 사용), `/api/world-fishing`, `/api/world-collection-book`, `/api/model-convert` (로그인 후 기능 진입 시에만).

**로그인/온라인 월드에 필요한 것:**

| 필요 | 핸들러 |
|------|--------|
| 로그인·프로필·게스트북 동기화 | 클라이언트가 Supabase JS로 직접 호출 (핸들러 경유 아님) — 데이터 계층 결정에 직결 |
| 텔레메트리·퍼널 | `hub-event`, `hub-entry` (RPC 2개) |
| NPC AI 대화·관계·퀘스트 | `npc-ai`, `npc-relationship`, `world-quest` (Cloud Run 프록시) + `npc-dialogue-route` (JEV 실험, 낮음) |
| 공유 NPC 상태 | `npc-shared-state` (인메모리 → Workers에서 상태 공유 방식 재설계 필요) |
| 낚시·도감 | `world-fishing`, `world-collection-book` (service-role RPC — 데이터 계층 결정 대기) |
| 공개 설정 | `public-supabase-config` (정적 JS 또는 초소형 Worker로 대체 가능) |
| 브랜드 에셋 | `brand-asset`, `brand-induck`, `brand-media` (Edge Functions 3개가 repo 밖에 있음 — 소재 확인 필요) |
| 서버 시계 | `world-time` (순수 함수, trivial) |
| 모델 변환 (에디터) | `model-convert` (Cloud Run + 게이트, 속도 제한 재설계 필요) |
| 운영 상태 | `dev-status` (월드 런타임 아님, 모니터링용) |

## 5. 포팅 순서에 대한 시사점

**Tier 0 — 백엔드 없이 바로 가능 (정적 또는 초소형 Worker):**
- `world-time` — 순수 함수, 그대로 옮기면 끝.
- `public-supabase-config` — 정적 stand-in이 이미 테스트에서 동작 증명. 실제 설정값이 정해지면 같은 형태의 JS 파일 또는 환경변수 읽는 초소형 Worker.
- `dev-status` — GitHub API fetch 하나. 단 `VERCEL_*` 환경변수를 Cloudflare 값(`CF_PAGES_COMMIT_SHA` 등)으로 교체해야 함. 월드 런타임이 아니라서 후순위.

**Tier 1 — 무상태 프록시, DB 없이 가능 (Cloud Run URL만 유지되면 됨):**
- `npc-ai`, `npc-relationship`, `world-quest` — 얇은 fetch 프록시. Workers/Pages Functions로 거의 그대로 이식 가능. NPC AI 백엔드(Cloud Run)는 그대로 두는 전제.
- `npc-shared-state` — 외부 호출이 없어서 이식 자체는 쉽지만, 인메모리 공유 상태라 Workers 멀티 인스턴스에서 의미가 달라짐. 스냅샷이 정적 데이터에서 결정적으로 계산되는지 확인하고, 아니면 Durable Object로 승격.
- `npc-dialogue-route` — Typesafe 키·엔드포인트 + Supabase Auth 검증만 있으면 됨. 실험 전용이라 후순위.

**Tier 2 — RPC 전달만 필요하지만 데이터 계층 결정에 묶임:**
- `hub-event`, `hub-entry`, `asset-canary-flag` — Supabase REST(`rest/v1/rpc/...`, `rest/v1/world_runtime_flags`)로 그대로 전달하는 구조라, Supabase를 유지하면 이식 trivial. Neon으로 갈아타면 RPC 3개(`log_inhagame_game_entry_v1`, `log_inhagame_hub_event_v2`, `world_runtime_flags` 조회)를 Neon + Workers로 재구현해야 함. 텔레메트리라서 **정식 이전 전에는 없어도 되는** 쪽 — 게스트 테스트가 이미 증명.

**Tier 3 — 데이터 계층 결정을 기다려야 함 (Supabase 유지 vs Neon 교체):**
- `world-fishing`, `world-collection-book` — `SUPABASE_SERVICE_ROLE_KEY`로 RPC 4개(`world_fishing_start_v1`, `world_fishing_input_v1`, `world_fishing_<op>_v1`, `world_collection_list_v1`) + Supabase Auth 검증(`verifyNpcAiUser`)에 전면 의존. Supabase를 유지하면 거의 그대로 이식. Neon으로 가면 Auth·RPC·RLS를 전부 재설계해야 해서 가장 큰 작업.
- `verifyNpcAiUser` 자체(Supabase `/auth/v1/user`)도 같은 결정에 묶임 — model-convert, npc-dialogue-route 포함.
- Edge Functions 5개 중 DB를 쓰는 `ranked-run-start`, `ranked-run-finish`, `verify-inha-mail`, `world-duck-observe`도 같은 결정 대기. DB를 안 쓰는 `inhagame-world-brand-assets-optimized-v1`(gltf-transform 연산)은 Workers + npm 호환으로 옮길 수 있지만, 소스인 canonical 함수가 repo 밖에 있어 단독 이식 불가.

**Tier 4 — 소재 확인이 먼저:**
- `brand-asset`, `brand-induck`, `brand-media` — 참조하는 Edge Function 3개가 이 repo에 없음. 소재 확인 전에는 포팅 범위조차 확정 불가. GLB/미디어를 R2 + Workers로 옮기는 방안도 있으나, 가구 서명 URL·sha256 검증 로직까지 같이 옮겨야 함.
- `model-convert` — Cloud Run 유지 전제 + 인메모리 속도 제한을 Workers 환경에 맞게 재설계(KV/Durable Object) 필요. 에디터 기능이라 후순위.

**결론:** 데이터 계층 결정(Supabase 유지 vs Workers+Neon)과 무관하게 먼저 할 수 있는 것은 Tier 0 + Tier 1(프록시 3개 + world-time + public-supabase-config)이다. 텔레메트리(Tier 2)는 없어도 월드가 뜨므로 급하지 않다. 진짜 분기점은 Tier 3 — 낚시·도감·Auth·랭크·메일인증이 Supabase에 묶여 있어, 이 결정을 미루면 온라인 월드의 핵심이 전부 대기 상태가 된다. 반대로 Supabase 유지를 택하면 Tier 2·3의 대부분이 fetch 대상 URL만 바꾸는 수준으로 축소된다.
