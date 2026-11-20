# INHA WORLD Tier 4 — 프로덕션 컷오버 실행 기록 (2026-11-20/21)

- **실행일:** 2026-11-20 23:08 KST 시작 (알돌 승인 "다 알아서 해줘, 적당한 방식 찾아서")
- **범위:** CUTOVER-PLAN.md 6단계 + DECISIONS.md 결정 55개 기준. **전환 완료 선언은 아님** — 스모크 통과 후 알돌 승인 필요 (C-12).
- **비밀값:** 없음. 연결 문자열·토큰·키는 이 문서에 없다.

## 결과 요약 (부분 완료 — ④ Supabase 이관 차단, ⑤ GitHub 푸시 승인 만료 + 라이브 클라이언트 미적용, ③ 라우팅 방식 변경)

| 단계 | 결과 |
|---|---|
| ① Neon 스키마 | ✅ 완료 — 백업 `pre-tier4-cutover-20261120` (`br-wild-recipe-aokf11ng`, main과 테이블/함수 3/0 일치 확인), `tier4-live` (`br-wild-star-aohu8otf`)에 BCD schema 적용(2회: 1356/34 → 1384/6, 잔여 6건은 알려진 무해 집합), 오라클 715/715·패리티 607/607(재실행, 1차 606/1은 재시작으로 중단된 실행이 남긴 스크래치 잔여 상태 때문), **main으로 승격 완료** (`tier4-live` primary+default, 구 main은 일반 브랜치로 보존). v0.1 테이블(sessions/guestbook/progress) 형태·0행 보존 확인 |
| ② 라이브 Worker | ✅ 완료 — `inha-world-tier04` (https://inha-world-tier04.aldol-lab.workers.dev), 배포 버전 `117a5a3f-d4ac-40d2-bf7f-512e86f6b706`, 로그인 역할 `inha_world_tier4_live_app` (그룹 `inha_world_tier4_writes_app` 소속), DATABASE_URL·MAIL_ADMIN_KEY는 stdin 경유로만 설정. curl 실측 264/264 (1차 249/15는 콜드 Neon 컴퓨트 일시 장애 — 웜업 후 재실행 264/264, 픽스처 정리 leftover=0) |
| ③ /api 라우팅 | ⚠️ 방식 변경 — **Worker route 직접 연결** (`inhagame.app/api/*` → `inha-world-tier04`, route id `d7b06d9e…`). C-7 결정(Pages Functions 경유)과 다름: 라이브 Pages 프로젝트(`inhagame-world-migrate`)에 Functions가 존재하지 않음이 실측 확인됨(`/api/*`가 전부 SPA HTML 폴백 200 반환). Functions 추가는 사이트 전체 재배포가 필요한데, 라이브 JS(`src/main.js`·`src/api.js`)와 일치하는 로컬 소스가 없어 재배포 시 라이브 클라이언트 바이트가 바뀌는 위험이 있어 Worker route를 택함. 검증: 루트 200·4052B 바이트 동일, `/api/world-online-count` 200 JSON, `/api/world-time` 404( Tier 4에 없음 — 스모크는 online-count 사용), `/api/hub-entry` GET 404(hub-entry는 Tier 2 텔레메트리 Worker 범위, Tier 4에 없음). 롤백: 해당 route 1개 삭제 |
| ④ Supabase 이관 | ❌ **차단 — 이관 미실시.** 이 환경에 Supabase 접근 경로가 없음(커넥터 없음, 프로젝트 URL·키 없음, 워크스페이스 설정 전부 placeholder `127.0.0.1:54321`/`sb_publishable_PUBLIC_PLACEHOLDER`). 실측 가능한 라이브 저장소(Neon main의 v0.1 sessions/guestbook/progress)는 전부 **0행**이라 이관할 행이 없음은 확인됨. Supabase 프로젝트 접근 수단( URL·service key 또는 대시보드 내보내기)이 확보되면 그때 이관 재개. 이중화 2주는 이관 시점부터 기산 (미개시) |
| ⑤ 클라이언트 패치 | ❌ **차단 — GitHub 푸시 미실시 (승인 만료).** Tier 4 패키지는 `~/workspace/inhaworld-tier04-cutover/`에 `workers-tier04/` 형태로 푸시 준비 완료했으나, `create_branch` 호출이 승인 타임아웃으로 수행되지 않음 (approval `connector-attempt-014f0718…`, 브랜치 `tier4-cutover` 부재 404 확인). 재시도에는 승인 필요 — 지시 없이 재시도하지 않음. **라이브 클라이언트에는 미적용:** (a) `inhaworld` 레포에 게임 클라이언트가 없음(Workers + 문서만 있음) — 패치 대상(`inha-world-static-test/src/main.js` = 포털 클라이언트)은 `aldol2678/inhagame`의 `apps/world`에 있음. (b) 라이브 `inhagame.app`은 v0.1 rebuild 클라이언트(별개 코드)라 Tier 4 패치가 적용되지 않음. (c) `game-entry.js` 55행 절대 URL은 라이브에서 서빙되지만 라이브 페이지가 로드하지 않음(참조 0건 — `campus/index.html`만 로드, 포털 범위). 라이브 클라이언트 Tier 4 이식은 별도 작업 필요. **loadout accountId (C-9):** 패치 자체에 수정 포함됨(`change.accountId` 비교를 `readGuestSessionId()`와 대조 — `main.js.combined.patch` 102행). 라이브 미적용이라 실측은 불가 |
| ⑥ 스모크·시드 게이트 | ✅ 서버 스모크 통과 (아래). 라우트 경유 GET 스모크도 통과 (프로필·인벤토리·지갑·정석 조회·온라인 수). **주의:** `inhagame.app`으로의 POST 스모크는 이 실행 환경의 승인 게이트에서 타임아웃돼 수행하지 못함 — 동일 Worker·동일 DB에 대한 POST 검증은 `workers.dev` 경유로 수행했고(264/264), `inhagame.app` 경유는 GET까지만 확인됨. 브라우저 스모크(⑧)는 미실시 |
| 시드 게이트 | ✅ 정석만 라이브 ACTIVE 전환 (게이트 정책 + 패스 카탈로그 ACTIVE, 레시피·조리대·구운 잉어 COMING_SOON 유지). 테스트 계정 구매 실측: 100코인 500→400, GRANTED via VISITOR_PASS, 재전송 동일 영수증, 활성 중 재구매 409, 요리 409 유지. 픽스처 정리 leftover=0. 전원 유료 (메일 무료 분기는 발송 수단 확보 뒤) |

## 스모크 결과 (라이브 Worker + 라이브 DB, 테스트 픽스처만 사용)

| # | 항목 | 결과 |
|---|---|---|
| ① | `inhagame.app` 200 + 타이틀 | ✅ 200, 4052B, 라우팅 전과 바이트 동일 |
| ② | 가벼운 GET 200 | ✅ `/api/world-online-count` 200 JSON (경유: Worker route). `/api/world-time`은 Tier 4에 없어 404 — 스모크는 online-count로 대체 |
| ③ | 세션 발급 → 프로필 조회 → 인벤토리·지갑 조회 | ✅ curl 264/264에 포함 (프로필 생성·조회, 인벤토리·지갑 전 구간) |
| ④ | 상점 구매 → 멱등 재전송 | ✅ 구매 200 + 재전송 동일 영수증 (curl 264/264) |
| ⑤ | 출석 청구 → 재청구 replay | ✅ 청구 200 + 재청구 replay (curl 264/264) |
| ⑥ | 방명록 생성·조회 | ✅ curl 264/264에 포함 |
| ⑦ | 정석 조회 (ACTIVE 확인) | ✅ ACTIVE·NEEDS_PASS·100코인 offer, 구매·재전송·재구매 거절 실측 (위 시드 게이트 절) |
| ⑧ | 콘솔·페이지 에러 0건 | ⚠️ 미실시 — 브라우저 실측은 이 실행 범위 밖 (Steel/브라우저 작업 필요). curl·API 단에서는 에러 0건 |
| ⑨ | 라우트 경유 GET 스모크 (`inhagame.app`) | ✅ 프로필 200(닉네임 smoke·환경공학과)·인벤토리 200·지갑 200(500코인)·정석 조회 200(ACTIVE offer)·온라인 수 200·루트 200 + 타이틀. 테스트 픽스처 정리 leftover=0, v0.1 테이블 0행 복원 |

## 승인 대기 중인 항목 (이 실행에서 타임아웃으로 수행되지 않음 — 재시도에는 승인 필요)

- **GitHub `tier4-cutover` 브랜치 생성 + `workers-tier04/` 푸시 + PR** (`aldol2678/inhaworld`): `create_branch` 승인 만료 (`connector-attempt-014f0718…`). 브랜치 부재 확인됨. 승인 후 재시도 가능.
- **`inhagame.app` 경유 POST 스모크** (구매·출석·방명록·정석 구매를 라우트 경유로): POST to `inhagame.app`이 승인 게이트에서 2회 타임아웃 (curl 000). 동일 Worker·DB에 대한 POST는 `workers.dev`로 전부 검증됨 (264/264 + 정석 실측). 승인 후 재시도 가능.
- **전환 완료 선언**: 스모크 통과했으나 ④·⑤ 미완료 상태라 선언하지 않음 — 알돌 승인 필요 (C-12).

## 라이브 상태 (이 기록 작성 시점 기준)

- `inhagame.app` 200 (v0.1, 변경 없음), `/api/*` → Tier 4 라이브 Worker (route)
- Neon `inha-world-sync`: 기본 브랜치 `tier4-live` (Tier 4 스키마, 88테이블·191함수), 백업 `pre-tier4-cutover-20261120` (전환 전 main 복제), 구 `main` 브랜치 보존
- Worker `inha-world-tier04` 버전 `117a5a3f…` (DATABASE_URL → 승격된 기본 브랜치)
- 정석 게이트 ACTIVE (전원 유료), 요리 COMING_SOON

## 롤백 방법 (역순)

1. Worker route 삭제 (`inhagame.app/api/*`, id `d7b06d9e24e74989bb2aca1a68bc122e`) → `/api`는 다시 SPA 폴백으로
2. (클라이언트 변경 없음 — 되돌릴 것 없음)
3. (Supabase 이관 없음 — 되돌릴 것 없음)
4. Worker 삭제하지 말고 route 제거로 격리 (②와 동일)
5. Neon 기본 브랜치를 구 `main`(`br-rapid-dust-aofiyhry`)으로 되돌리기 (`set_as_default`) 또는 백업 브랜치 `pre-tier4-cutover-20261120`으로 복원. 단, 되돌리면 전환 후 Neon에만 생긴 쓰기(정석 구매 등)는 소실됨
6. 게이트 되돌리기: `world_jeongseok_gate_policy` + `world_jeongseok_pass_catalog`를 `COMING_SOON`으로 (이미 부여된 패스는 그대로 둠, G-9)

## 남은 미확인 사항

- **모니터링 24~72시간** (담당자 미지정 — 알돌 지정 필요): 오류율·지연·사용자 신고. 롤백 기준은 CUTOVER-PLAN.md §⑥ (스모크 핵심 ①~③ 실패, 구매·지갑 오류율 급증, 데이터 정합 오류, 보안 사고, 알돌 취소 결정)
- **학습 재검토** (L-8 트리거 충족됨 — D그룹 결정 완료): (a)/(b) 재검토는 알돌에게 물을 것
- **B-2 소유 확인**: NPC Cloud Run (`inha-npc-ai` 단서만 있음) 소유·프로젝트 귀속 미확인 — 콘솔 직접 확인은 알돌 단계
- **메일 발송 계정**: (b) 코드/매직링크 발송 수단(Resend/MailChannels/SES 등) 없음 — (c) 수동 관리자 검증 폴백만 라이브 동작 중
- **프로필 수정 API**: 미구현 (후속)
- **라이브 클라이언트 Tier 4 이식**: v0.1 rebuild 클라이언트용 별도 포팅 필요 (현 패치는 포털 클라이언트용)
- **Supabase 이관**: 접근 수단 확보 후 재개 (대상·행 수는 그때 실측)
- **브라우저 실측**: Steel 스모크(콘솔·페이지 에러 0건, 3D 렌더, 주요 기능) + 실기기 터치는 별도

## 산출물

- 작업 디렉토리: `~/workspace/inhaworld-tier04-cutover/` (schema.sql SHA `c2c3e21c…`, worker.js SHA `1e64d979…`, 프로비저너·curl·시드 게이트 스크립트, 로그 `curl-run-live.log`·`seed-gate-live.log`)
- `workers-tier04/` 푸시용 패키지: 위 디렉토리와 동일 내용 (푸시 미실시 — 승인 대기 중)
