# INHA WORLD — Tier 4 B/C/D: 프로필·메일 폴백·HTTP 폴링

A-3(65개 RPC)의 superset에 B/C/D를 더한 격리 패키지. 프로필 생성 RPC, 메일 501 수동 관리자 검증 폴백, 온라인 heartbeat HTTP 폴링을 새로 이식했다. 총 RPC **72개**(A-3 65 + BCD 7). 라이브(inhagame.app · 라이브 Neon main · 라이브 Worker · 원본 레포)는 건드리지 않았다. inhaworld 레포에 push/merge/PR 없음 — 패키지 형태만 준비했다.

결정 기록 55개(B 8 + C 8 + D 9 + 학습 8 + 시드 10 + 컷오버 12)는 `~/workspace/inhaworld-tier04-remaining/DECISIONS.md`에 있다. 이 README는 구현·검증만 다룬다.

## 범위 (BCD)

| 그룹 | 엔드포인트 | RPC |
|---|---|---|
| 프로필 생성 (D) | `POST /api/world-profile` (GET은 A-1 읽기 그대로) | `create_my_world_profile_v1` — 세션 id를 `p_user`로, 1:1, 멱등 200 기존 반환. 닉네임 2~12자·원본 CHECK `^[0-9A-Za-z가-힣_]+$`(공백 허용, 원본과 동일) + 금지어 필터, 학과는 `active=true`만, avatar classic/scholar/explorer/star, title 생성 시 null 고정 |
| 메일 501 폴백 (D) | `POST /api/world-mail-verify-request`, `POST /api/world-mail-verify-claim` | `request_world_mail_verification_v1` / `admin_claim_world_mail_verification_v1` — 인하 메일(inha.edu/inha.ac.kr) 제출·요청 행 기록(시간당 3건·10분 내 동일 요청은 duplicate), 관리자 claim은 Worker 시크릿 `MAIL_ADMIN_KEY`로만 호출. claim 시 `inha_mail_badges` 행 생성 + 프로필이 있으면 `inha_verified_v1` 업적 부여. **실제 메일 발송·외부 계정 생성 없음**, 개인정보(학생증 사진 등)도 받지 않음 |
| 온라인 폴링 (C) | `POST /api/world-online-touch`, `GET /api/world-online-count` | `touch_world_online_session_v2` / `get_world_online_count_v1` — 클로저 추출, `user_id`는 NULL(게스트), 세션은 `tier4_session_ref` 트리거 패턴, heartbeat 세션 id = 게스트 세션과 동일 id(C-3), 20초 간격·70초 윈도우·count 5초 캐시(Worker-local), touch 속도 제한 10초에 1회 초과 시 429 |
| B-3 유지 (B) | (엔드포인트 없음 — 전부 404) | NPC 3종·model-convert·JEV는 게스트 off. 격리 Worker에 핸들러를 만들지 않았고, curl probe로 404를 확인했다. B-1/B-2 구현은 하지 않았다 |

A-1 읽기·A-2 쓰기·A-3 상태머신(65개 RPC)은 그대로 포함된다. 학습 `world_learning_save_v1`/`read_v1`은 연기(L-1~L-8) — 이식하지 않았다. NPC 공유 틱 3개(`claim/commit/get_world_npc_shared_tick_v1`)도 재이식하지 않았다(휴면, 기대 차이 C-8로 기록).

## 설계 결정 (A-3 전제 + BCD 추가)

- **금지 파일**: 금지어 목록은 단어연금술 닉네임 필터 patch35(`BATTLE_NICK_BANNED`)를 파일에서 직접 확인해 재사용했다 — **47단어(한국어 37 + 영어 10)** + 정규화기(`btNormalizeNickForFilter`: 소문자화, leet 1→i/0→o/@→a/$→s, 구분자 제거, 반복 문자 축소) + 검사기(`btNickHasBanned`). SQL 포트는 `private.world_profile_banned_words` 테이블 + `world_profile_normalize_nickname_v1` + `world_profile_nickname_banned_v1`(SQL에는 NFKC가 없어 Worker JS 검사가 NFKC를 먼저 한다). `년` 단독은 목록에 없어 `소년연금술사`는 오탐이 아니다(직접 확인).
- **닉네임 중복 금지**: 부분 UNIQUE 인덱스 `profiles_nickname_unique_active ON public.profiles (lower(nickname)) WHERE is_banned = false` — 밴 계정 닉네임은 재사용 가능. 중복은 `NICKNAME_TAKEN`(P0001, unique_violation 경합도 포착) → Worker 409.
- **밴 은폐**: 밴 프로필 재요청은 `PROFILE_NOT_FOUND`(P0001) → Worker 409 `PROFILE_REQUIRED`로 상태를 숨긴다. 밴 닉네임 재사용은 허용된다.
- **메일 폴백**: 최종 방식 (b) 코드/매직링크 발송이 1순위지만 발송 수단(계정·도메인 인증)이 없어 (c) 수동 관리자 검증을 폴백으로 구현했다. claim은 `guard()`(메서드 + Origin 검사) + `X-Admin-Key` 헤더 = Worker 시크릿 `MAIL_ADMIN_KEY`로만 호출 가능. 시크릿은 로그에 남기지 않으며, 값은 어느 파일에도 기록하지 않았다 — 이후 실행 시 새로 생성해 `printf '%s' "$KEY" | python3 wrangler-tier4bcd.py secret put MAIL_ADMIN_KEY`로 설정하고 같은 셸에서 `MAIL_ADMIN_KEY` 환경변수로 `run-curl-bcd.py`에 넘긴다(미설정 시 런처가 rc 2로 즉시 실패).
- **touch 시그니처에 DEFAULT 없음 (의도적)**: `touch_world_online_session_v2(p_user, p_visitor_id, p_place_zone_id, p_space)` — 패리티 정적 검사가 `schemaSql.includes(sig)`로 시그니처를 찾고 시그니처 목록에 기본값이 없어서다. Worker·오라클은 항상 4개 인자를 전부 넘긴다. 킥 차단 분기는 원본에 있으나 Tier 4에서는 드롭했다.
- **세션 id 합치기 (C-3)**: heartbeat가 쓰는 세션 id는 게스트 세션 id와 동일하다. 온라인 수는 게스트 세션 기준으로 센다.
- **Worker 버그 수정 (v2 배포)**: `RPC_ERRORS`에 `INPUT_UNAVAILABLE` → 409와 `INSUFFICIENT_QUANTITY` → 409를 추가했다. 없으면 정상적인 "재료 부족" 거부가 503 `COOKING_UNAVAILABLE` 폴백으로 떨어졌다(시드 게이트 run 2에서 실측 확인).
- **권한**: A-3와 동일 — Worker 전용 NOLOGIN 그룹 역할 `inha_world_tier4_writes_app`에 쓰기 RPC EXECUTE + 최소 컬럼 조회만 허용. `private` 직접 접근 금지, RLS 대신 테이블 권한. PUBLIC에는 RPC 실행 권한 없음(REVOKE). 역할명은 A-3와 동일 — 격리성은 브랜치 단위다.
- **FK 대체**: A-3와 동일 — `sessions.id`는 TEXT라 uuid 컬럼 FK는 행 트리거 `tier4_session_ref`(`private.tier4_require_session_v1`, 23503)로 대체. BCD 테이블 3개에도 동일 패턴을 적용했다.

## 만드는 방법 (A-3 복사 + 손으로 쓴 addendum — 클로저 재생성 아님)

1. A-3 폴더를 통째로 복사했다 (`cp -a`, `.wrangler/`·`__pycache__/`·`node_modules/`는 제외 후 `node_modules`만 A-3에서 다시 복사). **A-3 폴더 원본은 건드리지 않았다.**
2. BCD 델타는 손으로 쓴 `schema-bcd-addendum.sql`을 `schema.sql` 끝에 붙였다. 함수 7개·테이블 3개·부분 UNIQUE 인덱스 1개·트리거 2개·GRANT 7개다. `hash-report-bcd.json`에 7개 함수의 해시를 기록했다(원본 대조가 아니라 신규 3개 + 적응 2개 + 헬퍼 2개라는 성격 기록).
3. 스크립트 이름만 바꿔 BCD용으로 적응했다: `provision-tier4bcd.py`, `wrangler-tier4bcd.py`, `set-worker-secret-tier4bcd.py`, `create-login-role-tier4bcd.mjs`, `run-curl-bcd.py`. `wrangler.toml`의 Worker 이름은 `inha-world-tier04-bcd-test`다.

## 격리 배포

- Neon 프로젝트 `odd-smoke-58843454` (`inha-world-sync`), 브랜치 **`tier4-bcd-test`** (`br-rough-night-aotbxv14`, main `br-rapid-dust-aofiyhry`에서 분기; A-3의 `tier4-a3-test`와 별개). 호스트 `ep-divine-heart-aouh7u04.c-2.ap-southeast-1.aws.neon.tech`.
- Worker **`inha-world-tier04-bcd-test`** — https://inha-world-tier04-bcd-test.aldol-lab.workers.dev (workers.dev 전용, 라우트·커스텀 도메인 없음). 현재 버전 **`8c5311ad-e343-4268-926a-a0e2f87d8aed`** (2026-11-20 v2 재배포본; 첫 배포 `5afee336-bf7f-4215-87f7-5c31474c9295`는 아래 Worker 버그 수정 — `INPUT_UNAVAILABLE`/`INSUFFICIENT_QUANTITY` 매핑 — 후 교체됨). 로그인 역할 `tier4_writes_app_login` + `DATABASE_URL`·`MAIL_ADMIN_KEY` 시크릿은 stdin 경유로 격리 Worker에만 설정했다.
- `schema.sql` SHA-256: `c2c3e21cffa6b151d62677809566a0e051842edaec961295bf41c67ae4ba9aef` (10,466줄). `worker.js` SHA-256: `1e64d9798ef4bf4f9296426d8ac7fbc5c17510cf11270340ceb26d15b65888b0` (1,302줄).
- 스키마 적용은 2회로 수렴했다. 1차 적용에서 34건이 순서 문제로 실패해 멱등 재적용했고(A-3와 동일 패턴), 2차 적용 뒤 남은 7건 중 4건은 A-3 최종 실패와 동일(재실행 전용 stale 가드, 데이터 이상 아님 — 더 재적용하지 않음), 2건은 재적용 중복 트리거(무해), 1건은 touch 기본값 제거 문제로 drop + 재생성 + 재GRANT로 해결했다. 상세는 VERIFY.md §0 참조.

## 검증 결과 (자세한 수치는 VERIFY.md — 2026-11-20 실행)

- 오라클 `test-schema.sql`: **715/715 통과**, 잔여 픽스처 행 0건 (A-3 639 + BCD 76).
- 패리티 `test-parity.mjs`: **607/607 통과** (직접 대조 297쌍 + 기대 차이 15건), 잔여 행 test=0 scratch=0.
- 클라이언트 `client/test-clients.mjs`: **56/56 통과** (A-3 50 + BCD 6).
- curl 실측: **264/264 통과** (A-3 회귀 203 + BCD 61). 테스트 행 전부 정리(leftover=0), inhagame.app 200 유지.
- 시드 게이트 격리 검증 `seed-gate-verify.sh`: **21/21 통과**, 게이트 전부 COMING_SOON으로 복원 확인, 잔여 0건. 라이브 전환 없음.

## 기대 차이 15건 (원본과 의도적으로 다름 — 패리티에서 각각 assert함)

A-3의 12건(VERIFY.md §2 참조)에 BCD 3건이 추가됐다:

13. **온라인 user_id**: 원본 `touch`는 `auth.uid()`를 `user_id`로 저장하고 count는 `signedIn`을 세지만, Tier 4는 게스트라 `user_id`가 항상 NULL이고 `signedIn`은 0이다. 원본에는 touch 10초 속도 제한이 없고 Tier 4는 10초 내 재touch 시 429다.
14. **닉네임 중복**: 원본에는 프로필 생성 RPC가 없어 직접 INSERT하면 중복 닉네임도 들어가지만, Tier 4는 `NICKNAME_TAKEN` 409다.
15. **금지 필터**: 원본은 금지어를 그대로 INSERT하지만, Tier 4는 `INVALID_NICKNAME` 400이다.

## 클라이언트 (BCD)

A-3 클라이언트 50개 테스트에 BCD 6개가 추가됐다. 원본 스냅샷(`~/workspace/inha-world-static-test/src`, 무수정)에서 가져온 것은 heartbeat뿐이고, 프로필·메일 클라이언트는 새로 썼다.

- `client/profile/profile-client.js` — `createWorldProfile`, `parseWorldProfile`, `NICKNAME_RE`는 원본 CHECK과 동일하게 공백 허용(`/^[0-9A-Za-z가-힣_]{2,12}$/`).
- `client/mail/mail-verify-client.js` — `requestWorldMailVerification` (관리자 claim 클라이언트는 없음 — 시크릿 전용).
- `client/online/world-population-heartbeat.js` — 원본 heartbeat를 Tier 4 포트로 이식: POST touch + GET count, 세션 id = 게스트 세션 id, 20초 간격, visitor 키 `inhagame-hub-visitor-v1`, `parseWorldPopulationSnapshot` verbatim.

## 파일 목록 (BCD 추가·변경분)

- `schema-bcd-addendum.sql` — BCD 스키마 델타 (schema.sql에 이미 병합됨)
- `hash-report-bcd.json` — BCD 7개 함수 해시 기록
- `worker.js` · `wrangler.toml` — Worker (BCD 엔드포인트 5개 + B-3 404 명시)
- `test-schema.sql` · `test-parity.mjs` · `run-oracle-tier4w.mjs` — 검증 (BCD 단언·대조·정리 추가)
- `curl-fixtures.mjs` · `curl-verify.sh` · `run-curl-bcd.py` — 격리 Worker curl 실측 (BCD 섹션 + 세션 E/F/G/H)
- `seed-gate-verify.sh` · `seed-gate-fixtures.mjs` — 시드 게이트 격리 검증 (flip/setup/teardown)
- `provision-tier4bcd.py` · `wrangler-tier4bcd.py` · `set-worker-secret-tier4bcd.py` · `create-login-role-tier4bcd.mjs` — BCD용 도구 (A-3에서 이름만 변경)
- `fix-touch-defaults.sql` — touch 기본값 제거용 drop + 재생성 스크립트 (적용 완료 후 보관)
- `client/profile/profile-client.js` · `client/mail/mail-verify-client.js` · `client/online/world-population-heartbeat.js` — BCD 클라이언트
- `README.md` · `VERIFY.md` — 이 문서와 검증 기록

## 남은 것

- **B-2 보류**: NPC Cloud Run 소유가 여전히 미확인이다. 워크스페이스·원본 레포·GitHub를 직접 다시 찾아봤으나 환경변수 이름·주석·예시 URL만 있고 GCP 프로젝트 ID·서비스명·배포 스크립트·배포자는 없었다. 새 단서는 `gcp-usage-review-20261111/GCP-USAGE-REVIEW-20261111.md`에 기존 서비스 `inha-npc-ai`가 두 번 언급된 것뿐인데, 어느 GCP 프로젝트·리전에 속하는지, NPC AI 백엔드인지는 그 문서에 없다. 이 VM에는 `gcloud` CLI가 없어 콘솔 확인도 불가했다. 해제 조건은 DECISIONS.md의 B-DECISION.md §1.3 네 가지 확인이다.
- **C그룹 DO 도입 보류**: (b) HTTP 폴링 분리안만 구현했고, Durable Objects는 설계만 남았다.
- **D그룹 메일 (b) 발송**: 발송 수단(Resend/MailChannels/SES 등 계정·도메인 인증)이 없어 (c) 수동 관리자 검증 폴백만 구현했다. (b)로 가려면 발송 계정·도메인 인증이 알돌 단계다.
- **프로필 수정 API**: 생성과 분리해 후속으로 미뤘다.
- **학습 (L-1~L-8)**: (c) 연기로 기록만 했다. 재검토 트리거(D그룹 결정 완료)가 충족됐으므로 다음 단계에서 재검토한다.
- **시드 게이트**: 격리 검증만 완료했다. 라이브 전환은 컷오버 단계에서만 한다. 정석·요리 동시 전환이 격리에서 검증됐으나, 요리 전환의 전제는 조리대·재료 경로가 **격리 픽스처로만** 확인된 상태다 — 라이브에서는 조리대 획득 경로가 없고 재료(잉어)는 낚시 성공으로만 얻는데 낚시가 게임에 아직 구현되지 않았다. DECISIONS.md G-3은 정석만 전환 가능 상태로 분리 전환을 정했다.
- **컷오버**: 준비·결정 기록까지만 했다. 전제 충족 여부는 VERIFY.md §7 참조. 라이브 Neon 스키마 적용, 라이브 Worker(`inha-world-tier04`) 배포, inhagame.app `/api` 라우팅, 기존 Supabase 데이터 이관은 부모가 따로 한다. (참고: 2026-11-20 알돌 정정 — 공식 전환 대상은 신규레포 `aldol2678/inhaworld`로 확정됐고, 컷오버 자체는 미실시.)
- **브라우저 실측**: BCD 기능이 게임 클라이언트에 아직 붙지 않아 범위 밖(낚시 때와 동일). 낚시 기능 자체는 게임에 아직 구현되지 않음.
