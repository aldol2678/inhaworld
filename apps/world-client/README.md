# INHA WORLD 캠퍼스 클라이언트

정적 Pages 앱의 루트는 `apps/world-client/`다. 게임의 표시·입력·저장 계약은 기존 Draft PR #452에서 가져왔다. 맵을 생성하는 Node 코드와 데이터는 `map-sources/`에 있고, 브라우저는 생성한 레이아웃과 Three.js만 읽는다. [원본 PR](https://github.com/aldol2678/inhagame/pull/452) · [원본 커밋](https://github.com/aldol2678/inhagame/commit/aeb5d1d7ff17082e1a7a2a876f1a36fd0bf2b320)

## 로컬 실행과 검증

Node 24에서 다음 명령을 실행한다. Three.js와 MIT 라이선스가 저장소에 포함되어 있다.

```sh
cd apps/world-client
npm ci --ignore-scripts
npm run build
npm test
python3 -m http.server 8080 --bind 127.0.0.1 --directory dist
```

브라우저로 `http://127.0.0.1:8080`에 접속한다. Pages 빌드 루트는 `apps/world-client`, 명령은 `npm run build`, 출력은 그 아래 `dist/`다. `dist/`에는 HTML, 브라우저 모듈, 공개 설정, 방·퀘스트 JSON, 생성한 맵과 Three.js가 들어간다. Worker 구성과 배포는 각각 기존 `workers-tier01/`부터 `workers-tier04/`까지의 경로에서 계속 관리한다.

| 빌드 환경변수 | 연결 계약 |
|---|---|
| `WORLD_PUBLIC_ORIGIN` | 설정을 적용할 정확한 origin. HTTPS를 쓰며 로컬 루프백은 HTTP도 허용한다. |
| `WORLD_SYNC_ORIGIN` | 승인된 환경의 v0.1 진행도·방명록 동기화 Worker origin. `/api/health`의 sync 모드를 확인한 후 선택한다. |
| `WORLD_FIREBASE_WEB_CONFIG` | Firebase 공개 Web App 설정 JSON. 브라우저에 그대로 제공한다. 서버 자격증명은 Worker가 관리한다. |

기본 빌드는 게스트를 지원한다. 동기화 서비스 미설정·미응답 시 기존 같은 호스트 개발 API와 로컬 저장소 순으로 전환한다. Firebase 서버 세션은 항상 현재 origin의 `/api/auth/firebase/*`에서 처리한다. 외부 SDK 로그인은 명시적으로 설정한 환경에서만 제공한다. 원격 QA에는 승인된 테스트 프로젝트와 분리된 DB를 지정한다. 운영용 공개 설정은 정식 승인 시 해당 환경에서 주입한다.

독립 모아 포트와 비교할 때는 인계 패킷의 실제 파일 경로를 제공한다. 기본 `npm test`는 저장소 입력에 대한 회귀를 수행한다.

```sh
node tools/build-layout.mjs --check
MOA_CAMPUS_DATA=/path/to/02_threejs-port/src/campus/campus-data.js node tools/build-layout.mjs --check
MOA_CAMPUS_DATA=/path/to/02_threejs-port/src/campus/campus-data.js node tests/spatial.mjs
```

Python 3, pytest, Python Playwright와 Chromium이 설치된 환경에서 `python3 -m pytest -q tests`로 실제 Pages 출력의 브라우저 회귀를 실행한다. `CHROMIUM`은 브라우저 경로, `WORLD_QA_DIR`은 입력·수치·스크린샷 저장 경로다. 테스트는 루프백과 가상 호스트에서 실행한다.

`snapshot.sha256`는 11월 21일 운영 정적 파일 10개의 역사적 지문이다. 당시 조립에 쓰인 소스와 `scripts/build-pages.sh`는 미확보다. 원래 스냅샷은 이전 저장소의 복원 커밋에서 확인할 수 있다. [복원 커밋](https://github.com/aldol2678/inhagame/commit/a0d361c)

## 공간과 서비스 ID

| v0.1 서비스 ID | 지리 ID | 외부 방문 중심 (x, z) | 기준 |
|---|---|---|---|
| main-gate | lmk_main_gate | 0, −76 | 정문 투어 지점. WGS84 원점은 0, −90, 스폰은 0, −98 |
| main-building | bldg_01 | 49.481, −4.714 | 본관 전면에서 바깥쪽 5 WU |
| library | bldg_jungseok | −19.448, −3.969 | 정석 전면 로컬 프레임의 (0, 1.8) |

월드·보행 좌표는 원본 WGS84 변환을 따른다. 기준점은 37.44770°N, 126.65319°E이고 1 WU는 약 2m다. 경도 증가 방향은 +X, 위도 증가 방향은 +Z다. 운영 방 반경 9, 퀘스트 ID 3개, 방명록 키, 진행도 키와 서버 세션 헤더를 유지한다. 운영의 ‘중앙도서관’과 정석 외부 입구를 연결한 것은 이 후보에 한정한 방문 판정 설계다.

| 파일 | 담당 |
|---|---|
| `tools/spatial-source.mjs` | 모아 포트·Reality Base의 공간 ID/좌표 입력 선택. 이관한 지리 JSON은 map-sources/data/reality에 보관 |
| `tools/build-layout.mjs`, `mesh-batch.mjs` | 원본 다각형 삼각분할, 4개 지형 절개, 8개 경로, 도로·정문 구조물·본관·정석 파사드 생성 루틴을 정점·색상 배치로 변환 |
| `data/layout.json`, `layout.bin` | 지형·도로·입구·충돌·수목 메타데이터와 렌더링 버퍼. 엔진 독립적인 생성 입력에서 재생성 가능 |
| `src/map/polygon-collision.js`, `spatial.js` | 원본 모서리·꼭짓점 연속 충돌과 미끄러짐, 경사·단 높이, 도착 가능 여부 |
| `src/campus.js` | Three.js 버텍스 컬러 배치, 본관·정석 상세 거리 제한, 수목 인스턴싱 |
| `src/main.js`, `index.html`, `src/api.js` | 기존 1인칭 카메라·입력·HUD·서비스 UI 연결. 같은 호스트 인증, 선택적 SDK, 오프라인 진행과 온라인 재연결 |
| `tests/` | 174점 회귀, 접촉, 브라우저 입력·시점·회전·저장·권한 실패 및 두 수로 왕복 재생 |

건물 2개만 본체를 생성한다. 위치가 확정되지 않은 나머지 건물 23개와 랜드마크 5개는 보류한다. 주차장 시설 링과 비룡탑의 게임용 앵커가 건물·랜드마크 배치 승인으로 쓰이지 않는다. 도로폭, 계단 단수·높이, 수목 위치와 파사드는 표현 추정치다. 5호관 보행로 실측 필드 6개는 `walkwaySurvey`에 null로 유지한다.

모아 원본 외부 미디어, 현장 사진, 미승인 GLB, 브랜딩 이미지는 후보의 입력에 포함하지 않는다. 배경은 저장소의 절차 기하와 색으로 구성한다. © OpenStreetMap contributors. 공간 데이터의 ODbL 출처와 엔진 MIT 전문을 보존한다. [OpenStreetMap 저작권](https://www.openstreetmap.org/copyright) · [Three.js 라이선스](vendor/LICENSE)
