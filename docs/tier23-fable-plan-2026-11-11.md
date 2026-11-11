# INHA WORLD Tier 2/3 — Fable 5.2 실행 계획 (초안, 2026-11-11)

## 전제 (이미 결정된 것, 다시 열지 않음)
- 데이터 계층: **Workers + Neon으로 갈아타기** (알돌 선택, 2026-11-11 15:11). Supabase 유지 안 함.
- Tier 0+1 완료 (2026-11-11 15:13): 격리 테스트 Worker `inha-world-tier01-test.aldol-lab.workers.dev`, 코드 `workspace/inha-world-migration/workers-tier01/` (world-time·public-supabase-config·npc-ai·npc-relationship·world-quest). 비밀값 없음, 라이브 무변경.
- 원본 (읽기 전용): `aldol2678/inhagame` HEAD `0b72d259`, 로컬 클론 `~/workspace/inhagame-github-check/`. 원본은 건드리지 않음.
- Fable 5.2 프로필: 1M 컨텍스트·128K 출력, $8/$40, FrontierCode 2.0 49.1% (Opus 5.5 45.5% 대비 작업당 비용 절반 수준). 일상 코딩용이 아니라 다단계·검증 많은 기술 작업용.

## 범위

### Tier 2 — 텔레메트리 (먼저, Auth 없음)
| 핸들러 | 원본 동작 | Neon 재구현 |
|---|---|---|
| `POST /api/hub-entry` | Origin allowlist 5개(inhagame.app 계열), UUID 검증, 이벤트 7종, RPC `log_inhagame_game_entry_v1`, 204 accepted / 409 duplicate | `game_entries` 테이블 + 중복 키(`event_id` UNIQUE) + 동일 검증·상태코드 |
| `POST /api/hub-event` | same-host Origin, UUID 3종, 이벤트 30여 종, RPC `log_inhagame_hub_event_v2`, 204 / 400 | `hub_events` 테이블 + 동일 검증·상태코드 |
| `GET /api/asset-canary-flag` | `world_runtime_flags`에서 `asset_glb_canary_v1` 1행 조회, 실패 시 503 | `runtime_flags` 테이블 + 동일 200/503 |

원본 RPC 정의는 마이그레이션에서 확인할 것: `20261002120000_core15_activation_funnel_contract_v2.sql`, `20261003072000_world_asset_canary_remote_control.sql`, 테스트 `supabase/tests/database/10_hub_telemetry.test.sql`, `91_world_asset_canary_remote_control.test.sql`.

### Tier 3 — 데이터 계층 재설계 (핵심, 가장 큼)
| 핸들러 / 함수 | 원본 의존 | Neon 재구현 과제 |
|---|---|---|
| `world-fishing` | RPC 3종(`world_fishing_start_v1`·`world_fishing_input_v1`·`world_fishing_<op>_v1`) + Supabase Auth 검증 | 낚시 상태머신·RPC 동등 SQL·세션 검증 재설계. 스펙 `server/fishing-service.mjs`(110행), 마이그레이션 `world_fishing_f2/f3` + skill effects, 테스트 `87_world_fishing_f2.test.sql` |
| `world-collection-book` | RPC `world_collection_list_v1` 하나만 허용, service-role, 본인 데이터만 투영 | 도감 조회 SQL + 본인 투영. `server/collection-book-service.mjs`(104행), 마이그레이션 `world_collection_discovery_p0`, 테스트 `84_...test.sql` |
| Auth (`verifyNpcAiUser`) | Supabase `/auth/v1/user`에 Bearer 조회 | **결정 게이트**: v0.1 Neon `sessions` 테이블(서버 발급 세션 ID, `X-Session-Id`)을 재사용할지, 별도 회원 세션을 만들지 알돌 승인 필요. model-convert·npc-dialogue-route도 같은 검증에 묶임 |
| `ranked-run-start` / `ranked-run-finish` | Edge Function, 룰셋 `secret-2.1-r1`/`2.2-r1`, 결과 검증 후 점수 확정 | 랭크 세션·점수 테이블 + 검증 로직 이식. 테스트 `40_ranked_lifecycle.test.sql` |
| `verify-inha-mail` | Edge Function, 학교 액세스 토큰 + Supabase Auth로 인하 메일 소유 확인 | 메일 소유 확인 흐름 재설계 (학교 토큰 발급 방식 확인 필요). 테스트 `30_inha_mail_badge.test.sql` |
| `world-duck-observe` | Edge Function, 인경호 오리 4마리 관찰 기록 | 관찰 기록 테이블 (작음, Tier 3 말미) |

### Tier 1 잔여 (Tier 2/3 뒤)
- `npc-shared-state`: 인메모리 스냅샷이라 Workers 멀티 인스턴스에서 공유 안 됨. 스냅샷이 정적 데이터에서 결정적으로 계산되는지 확인하고, 아니면 Durable Object 승격.
- `npc-dialogue-route`: JEV 실험 전용, 후순위.
- `dev-status`: `VERCEL_*` → `CF_PAGES_*` 교체, 모니터링용이라 후순위.
- `model-convert`: Cloud Run 유지 전제 + 인메모리 속도 제한을 KV/Durable Object로 재설계. 에디터 기능이라 후순위.

### Tier 4 — 브랜드 (BLOCKED, 소재 확인 먼저)
- `brand-asset`·`brand-induck`·`brand-media`: 참조하는 Edge Function 3개(`inhagame-world-brand-assets-v1`·`inhagame-induck-brand-v1`·`inhagame-brand-media-v1`)가 repo에 없음. 소재 확인 전에는 포팅 범위 확정 불가. R2 + Workers 방안은 소재 확인 뒤.

## 순서 (권장)
1. **Tier 2 텔레메트리** — Auth가 없어 Neon RPC 패턴을 가장 작게 증명. 격리 Worker + 격리 Neon 브랜치에서 먼저.
2. **Tier 2 canary flag** — 테이블 1개라 Tier 2와 함께.
3. **Auth 설계 결정 (게이트)** — v0.1 세션 재사용 vs 별도 회원 세션. 알돌 승인 없이는 Tier 3 본작업 시작 금지.
4. **Tier 3 도감 → 낚시** — 도감이 읽기 전용이라 작고, 낚시가 상태머신이라 큼.
5. **Tier 3 랭크·메일·오리 관찰** — 랭크는 검증 로직, 메일은 외부 토큰 확인이 관건.
6. **Tier 1 잔여 + Tier 4** — 브랜드는 소재 확인이 풀린 뒤.

## Fable에 줄 입력 (전부 읽기 전용 원본)
- `workspace/inha-world-migration/api-inventory-2026-11-11.md` (전체 인벤토리)
- `workspace/inha-world-migration/workers-tier01/` (Tier 0+1 패턴·가드 순서·헤더 관례 — 그대로 따를 것)
- 원본 핸들러 `apps/world/api/hub-entry.js`·`hub-event.js`·`asset-canary-flag.js`·`world-fishing.js`·`world-collection-book.js`, `apps/world/server/*.mjs`
- 관련 마이그레이션 + `supabase/tests/database/` 위 테스트 파일들 (동등성 오라클)
- v0.1 Neon 스키마 `workspace/inha-world-rebuild-v01/sync-worker/schema.sql` (sessions·guestbook·progress만 있음 — Tier 2/3 테이블은 **새 스키마 파일**로 추가, 라이브 `inha-world-sync` DB는 건드리지 말 것)

## 검증 기준 (각 단계마다)
- 원본과 상태코드·가드 순서 동일: enabled→probe→content-type→Origin→Bearer→본문 크기→JSON/형태→업스트림. 204/409 (hub-entry), 204/400 (hub-event), 200/503 (canary) 포함.
- 중복·무효 입력·Origin 불일치·본문 초과에 대한 패리티 테스트를 원본 핸들러 기준으로 작성하고 통과할 것.
- 격리 배포로 검증: 새 테스트 Worker (Tier 01과 같은 방식, env 미설정 시 404/503 경로 포함), 격리 Neon 브랜치. 라이브 Worker·라이브 DB·라이브 배포는 건드리지 말 것.
- 비밀값은 파일·로그에 절대 남기지 말 것. `wrangler secret put` / 대시보드 경유만.

## 저장소
- 새 저장소 `aldol2678/inha-world-cloudflare` (private 권장) 생성은 알돌 승인 대기 중. 승인되면 이 계획서 + Tier 0+1 코드 + Tier 2/3 산출물을 그 저장소로 옮김. 그전까지 산출물은 `workspace/inha-world-migration/`에 둠.
- Fable 작업은 이 저장소가 생긴 뒤, 그 안에서 브랜치 단위로 진행하는 것을 권장.

## 하지 말 것
- 원본 `inhagame` 저장소 수정·푸시 금지. 라이브 배포·DNS·DB 쓰기 금지.
- Supabase를 유지하는 방향으로 되돌리지 말 것 (결정 완료).
- Auth 설계를 알돌 승인 없이 단정하지 말 것.
- 브랜드 3종은 소재 확인 없이 이식하지 말 것.
