# P1A 아고라 광장과 인경호 도보 검증

정문에서 기존 길 658과 696을 거쳐 아고라의 남쪽 입구에 들어간 뒤, 인경호 동쪽 서비스도로와 짧은 보도를 왕복할 수 있다. PR #7 기준은 `c536c73a285ea77a62751419f1554fd9a60b166c`, 맵 구현은 `88f798546bc4116c684d21a27c3368dd08408738`이다. 검증 대상은 각 커밋에서 로컬 빌드한 INHA WORLD Three.js 클라이언트다. [Issue #9](https://github.com/aldol2678/inhaworld/issues/9) · [현장자료 보강 지시](https://github.com/aldol2678/inhaworld/issues/9#issuecomment-7079499461)

## 지리적 근거와 표현의 한계

기준점 (37.44770°N, 126.65319°E)을 (0, −90) WU에 투영한다. 동쪽이 +X, 북쪽이 +Z이며 1 WU는 약 2m다. 다음 면적은 지도 폴리곤에서 계산한 값이다. 표의 `null`은 현장 실측값이 없다는 뜻이다.

| 장소·항목 | verified / derived | estimated presentation / HOLD |
|---|---|---|
| 아고라 `lmk_agora_plaza` | 학교 무선망 안내에서 이름 확인. OSM 1099894035 v1의 서로 다른 꼭짓점 7개. 원장 중심 (37.449281, 126.656140) → (130.357, −2.100). 투영 면적 중심은 (128.691, −4.033), 면적 599.05 m² | 원장이 ‘polygon-centroid’로 분류한 중심과 재계산값은 2.552 WU 차이가 있다. 바닥은 폴리곤이 결정한다. 높이·석재 색·줄눈·벤치·나무 그늘은 게임 표현. 역사적 `fac_agora_courtyard`의 중심은 78.32 WU 떨어져 있어 테라스·계단 배치는 HOLD. [학교 안내](https://internet.inha.ac.kr/internet/11475/subview.do) · [OSM 광장](https://www.openstreetmap.org/way/1099894035) |
| 인경호 `lmk_inkyung_pond` | 공식·Oldenburg 캠퍼스 지도와 대조된 OSM 218264623 v7, 서로 다른 꼭짓점 13개. 원장 중심 (37.449664980476, 126.65596360247206) → (122.563, 19.248)이 면적 중심과 일치. 면적 2,830.14 m² | 서쪽의 굽은 윤곽과 동쪽 사선을 보존했다. 수면의 색·잔물결, 수변석, 수목 8주와 벤치 위치는 표현 추정. 수심·실제 호안 단면·수위는 `null`. 섬·정자 설치는 HOLD. [OSM 호수](https://www.openstreetmap.org/way/218264623) · [원본 공간 원장](../../map-sources/data/reality/campus-landmarks.json) |
| 기존 길과 접속 | 길 658·696은 노드 4741759439에서 만난다. 696·661·663은 노드 4741759444 (119.68, −8.07)를 공유한다. 이 OSM 길들은 `highway=service`로 기록돼 있다 | 게임에서는 보행할 수 있다. 실제 보행 전용 지정과 실측 폭은 HOLD. 기존 정문 앞마당이 입구 바닥을 소유한다. [기존 중심선](../../map-sources/data/reality/campus-site.json) |
| 호수 동쪽 접근로 | 481241663 v3의 첫 3개 노드에서 2개 구간을 사용. 중간 노드 9767122971에서 1063267429 v2의 전체 2개 노드 보도와 연결 | 서비스도로 폭 2.04 WU, 보도 폭 1.24 WU, 가장자리 0.22 WU는 렌더링 값. 양쪽 실측 폭은 `null`. 이번 범위는 북쪽 4741759449까지다. [좌표·버전·OSM 출처](../../map-sources/data/reality/evidence/roads/agora-inkyung.json) |
| 중앙 수로·기타 시설 | 중앙 수로는 별도 물 폴리곤 `site_218220690`. 본관·정석만 건물 본체를 생성한다 | 확인되지 않은 건물 23개·랜드마크 5개와 5호관 보행로 실측 필드 6개는 HOLD. [시설 원장](../../map-sources/data/reality/campus-facilities.json) · [P0 공간 대응표](https://drive.google.com/file/d/1WC5pbuonfFqviN1ZROGQiWalcEkv9Kbg/view) |

**현장 대조.** 10월 14일 PDF 36쪽의 사진 48장을 원장 ID·파일명·PDF 쪽으로 대조했다. 아고라·인경호·정문의 직접 컷은 찾지 못했다. P01~P04는 본관, P14~P15는 정석, P12~P13과 P33~P37은 중앙 수로의 건물·잔디·수면·보행 관계를 비교하는 데 썼다. P28/P29는 PDF 22쪽 원제와 ‘울림돌’ 판독을 함께 남겼다. 33~34쪽의 붉은 보행로는 별도 건물 사이 구간이다. 촬영 좌표·방위·렌즈는 미상이며, 사진과 게임 간 대응은 유사 시점이다. [사진별 대조표 48행과 직접 컷이 없는 3개 장소](field-crosswalk.csv) · [답사 PDF](https://drive.google.com/file/d/1SLA3BbhV222JMTA_GguS61xtE3j_4d_0/view) · [16구역 시각 매트릭스](https://drive.google.com/file/d/17FS4YVYhcA_wvE2xzUsiVFDu_t-iSzZa/view)

10월 복원 명세·XLSX·HTML·캡처 ZIP의 PARTIAL 10 / UNKNOWN 6 / MATCH 0은 당시 PlayCanvas 평가다. 공간 감사와 60주년관–5호관 보행로 조사에서 사진과 실측의 경계를 확인했다. 10월 12일 캡처 목록도 역사 자료로만 사용했다. [복원 명세](https://drive.google.com/file/d/18aB6eWjgrYuvEBI3rdCpF0U_CrgReat9/view) · [비교 HTML](https://drive.google.com/file/d/16vhblrgG-w9_1MDim9bQbE7nRm05POuj/view) · [대조 XLSX](https://drive.google.com/file/d/1Nv7Pj0EY5pJPWGULw-j0I5Ol1i4zUvf_/view) · [캡처 ZIP](https://drive.google.com/file/d/15hu5CKphnW3j4C7QEyf7-2CilsADohib/view) · [공간 감사·보행로](https://drive.google.com/drive/folders/1LWvgFl5sIf1twsqUAcrBTHKi6mwavyAY) · [과거 캡처](https://drive.google.com/drive/folders/1BLK8PtZBx2UpZUAl0OqqXtNJ6mVCPob_)

절차 기하의 참고 커밋은 `inhagame@0b72d2593ecd3e9bb6293724771cdfb978e74ccf`다. 지형 절개·도로 프레임·정석 정원·수변석·버드나무 실루엣을 검토했다. Drive 환경 카탈로그는 코드 위치와 해시를 보존한 10월 스냅샷이다. 재배포물은 저장소 절차 기하, 기존 재질, OSM 공간 입력으로 구성했다. 답사 PDF의 SHA-256은 `287dc53859ab73e3d6da8bd31b2363c4ab43bedaf51baa23d96824a9b0495b7f`이다. [원본 수변 기하](https://github.com/aldol2678/inhagame/blob/0b72d2593ecd3e9bb6293724771cdfb978e74ccf/apps/world/src/pond-surroundings-geometry.js) · [환경 에셋 승인 경계](https://drive.google.com/file/d/1o7IdXRqgafSdYt8m8XriSYzdrhPBga9P/view) · [절차 기하 카탈로그](https://drive.google.com/file/d/1cr6qsrcCQ-aB9ntDfTe3MaTOeyPPgMqu/view) · [맵 리뉴얼 패킷](https://drive.google.com/drive/folders/1ndOEQfII4nS4a_V0hGl65_EXCgHaKA8t) · [P0 설계](https://drive.google.com/file/d/1wNqzDdo9YpydB9nRRUs-3k8zm7KJRC6y/view) · [© OpenStreetMap contributors](https://www.openstreetmap.org/copyright)

## 같은 카메라로 비교한 화면

각 PNG 왼쪽은 PR #7, 오른쪽은 P1A다. Chromium 156.0.8078.79, SwiftShader WebGL2, DPR 1, 수평 시선, 게임 눈높이 2.2 WU, 수직 FOV 70°를 사용했다. 두 빌드의 태양 (20, 30, 10), 고정 조명·안개 (85~240 WU), 본관·정석 상세 거리 110 WU는 같다. 새 구역도 같은 거리에서 상세 표현을 전환한다. 양쪽 모두 시간·날씨 애니메이션이 없는 클라이언트다. 프레임을 촬영할 때만 테스트가 카메라를 고정했다. 실제 이동은 별도 키보드·터치 왕복으로 검사했다. [카메라·원본 PNG 해시·픽셀·WebGL 측정값](camera-results.json) · [재촬영 코드](capture.py)

| 장소 | 카메라 (x, z) → 주시점 (x, z) | 기준 사진 및 화면 판독 | PC 변화 픽셀 / 473,760 |
|---|---|---|---:|
| 아고라 | (121.8, −10.4) → (131, −2) | 직접 컷 HOLD. 풀밭이던 공간에 같은 나무를 둘러싼 포장, 가장자리 띠와 벤치가 보인다. [비교](screens/agora.png) | 112,810 |
| 인경호 | (125.6, 5.05) → (121.5, 18.5) | 직접 컷 HOLD. 단색 수면·빈 맞은편 둑에서 수변석, 얕은 물의 색 변화, 수관과 휴식 지점이 읽힌다. [비교](screens/pond.png) | 216,301 |
| 정문 | (0, −98) → (0, −73) | PDF 정문 직접 컷 HOLD. 입구·횡단보도·본관 실루엣 유지. 차이는 원경 좌측 x=9~63, y=260~261에 한정. [비교](screens/gate.png) | 15 |
| 본관 | (46.8, −19.9) → (54, 4.5) | P01~P04, PDF 7·10~11쪽. 기둥·창띠·전면 도로의 P0 화면 일치. [비교](screens/hall.png) | 0 |
| 중앙 수로 | (41, −12) → (11, −71) | P13/P33, PDF 7·25쪽. 길·잔디·직선 수면의 분리와 원근 일치. [비교](screens/canal.png) | 0 |
| 정석 | (−8, −10.25) → (−20.5, −3.4) | P14/P15, PDF 8쪽. 유리 중앙부·캐노피·계단 화면 일치. [비교](screens/library.png) | 0 |

PC viewport는 1280×720, 실제 게임 캔버스는 940×504다. 844×390 가로 viewport의 캔버스는 844×273이다. 가로 고정뷰에서도 정석·중앙 수로가 픽셀 단위로 일치했다. 더 넓은 시야에서 정문 원경 5픽셀, 본관 좌측 원경 186픽셀이 달라졌다. [가로 아고라](screens/agora-landscape.png) · [가로 인경호](screens/pond-landscape.png)

## 기하와 렌더 비용

| 측정 | PR #7 | P1A |
|---|---:|---:|
| 정적 삼각형, 세 배치 전체, 양쪽 LOD 저장분 포함 | 11,447 | 12,994 |
| layout.bin / layout.json (bytes) | 549,456 / 121,519 | 623,712 / 127,010 |
| 수목 / 충돌체 | 60 / 142 | 68 / 153 |
| PC 아고라·인경호의 제출 삼각형 / 드로우콜 (각 시점) | 14,145 / 3 | 17,501 / 3 |
| PC 정문의 제출 삼각형 / 드로우콜 | 17,927 / 5 | 17,979 / 5 |
| 렌더러 geometry / texture / 생성 WebGL buffer 수, 6시점 예열 후 | 5 / 1 / 19 | 5 / 1 / 19 |

캠퍼스 지면에서 광장과 맞닿은 삼각형만 상세·원경 형태를 갖는다. 베이스 배치에서 연속된 정점 범위를 바꾸고, 기존 줄기·수관 인스턴스의 개수를 조절한다. 같은 구역을 24번 전환한 뒤와 새로고침 후 같은 6시점을 예열한 뒤에도 GPU 객체 수가 같았다. 테스트 종료 시 브라우저 컨텍스트를 닫았다. 물리 GPU 드라이버의 메모리 회수량과 실기기 FPS는 HOLD다.

실제 바이너리를 지리 링에 다시 잘라 검사했다. 기준 빌드에서는 기존 길 가장자리가 호수 안쪽을 약 7.372 WU² 덮었다. P1A에서는 호수 바닥 침범과 광장 면적 누락·중복이 Float32 판정 오차 0.002 WU² 미만이다. 원래 물 경계로 수면·지형 구멍·충돌을 생성하며 광장과 길의 지지 높이는 같은 평지 함수 0 WU다. 수변석과 줄눈의 미세한 렌더 오프셋은 보행 단차를 만들지 않는다.

## 도보와 입력

브라우저가 실제 게임의 입력 처리와 충돌 함수를 실행한다. 정문 스폰에서 길 658·696, 아고라 중앙, 인경호 동쪽을 잇고 663의 끝과 곁보도를 각각 밟은 뒤 같은 정문 스폰으로 돌아왔다. 수면을 향한 정면 입력은 둑에서 멈췄고, 대각 입력에서는 둑을 따라 이동했다. 아래 간격은 HUD 좌표(0.1 WU 단위)로 구한 값이다. 별도의 Node 검사는 원래 정밀도의 좌표로 13개 변 모두에서 캡슐 중심이 경계 바깥 0.599 WU 이상에 정지하는지 검사한다. [입력 테스트](../../tests/test_p1a_walk.py) · [측정 결과](browser-results.json)

| 화면 / 조작 | 게임 버퍼 | 자유 이동 최대 오차 | 둑을 따라 이동 / 이동 후 수면과 간격 | 실제 1인칭 도착 화면 |
|---|---:|---:|---:|---|
| 1280×720 · 키보드·마우스 | 940×504 | 0.100 WU | 5.057 / 0.539 WU | [PC](screens/walk-1280x720.png) |
| 320×568 · 터치 | 320×318 | 0.080 WU | 4.966 / 0.582 WU | [세로 320](screens/walk-320x568.png) |
| 390×844 · 터치 | 390×473 | 0.080 WU | 4.966 / 0.582 WU | [세로 390](screens/walk-390x844.png) |
| 844×390 · 터치 | 844×273 | 0.080 WU | 4.966 / 0.582 WU | [가로 844](screens/walk-844x390.png) |
| 891×411 · 터치 | 891×288 | 0.080 WU | 4.966 / 0.582 WU | [가로 891](screens/walk-891x411.png) |

각 왕복은 이동 입력 39구간, 1,492 게임 프레임을 실행했고 최종 HUD 위치는 모두 (0.0, −98.0)이었다. 터치 시점은 캔버스 오른쪽을 스와이프하고 왼쪽 조이스틱으로 방향을 조정했다. PC는 포인터 잠금과 WASD, 모바일은 두 손가락 동시 이동·회전, 화면 방향 전환과 조이스틱 해제를 기존 회귀에서도 확인한다. 비교용 가로 시점 4곳의 원본 크기 이미지도 제공한다. [정문](screens/gate-landscape.png) · [본관](screens/hall-landscape.png) · [정석](screens/library-landscape.png) · [중앙 수로](screens/canal-landscape.png)

## 변경 파일

아래 경로의 기준은 `apps/world-client`다.

| 경로 | 변경 |
|---|---|
| `map-sources/data/reality/evidence/roads/agora-inkyung.json` | 접근로 두 개의 버전·노드·라이선스·확인 범위·미상 실측 폭 |
| `tools/agora-inkyung.mjs`, `tools/build-layout.mjs`, `tools/mesh-batch.mjs` | 광장 포장과 나무 보호대, 길·잔디·물 경계 절개, 수변석·물색·잔물결·수목·벤치, 정점별 색과 상세 범위 생성 |
| `map-sources/src/ground-clipping.js`, `map-sources/src/main-gate-surface-ownership.js` | 정문의 기존 절개 루틴을 광장과 접근로에서도 재사용 |
| `src/campus.js`, `src/map/spatial.js` | 나무 인스턴스와 상세 거리 전환, 평지 기준 높이 공유 |
| `data/layout.bin`, `data/layout.json` | 생성된 정점 버퍼와 공간 메타데이터 |
| `package.json`, `tests/p1a-spatial.mjs`, `tests/spatial.mjs`, `tests/test_p1a_walk.py`, `tests/world-driver.js` | 새 공간 회귀, 정문부터의 입력 왕복과 테스트용 렌더 완료 대기 |
| `README.md`, `qa/p1a/` | 현장 대조표, 로컬 QA 결과, 카메라 재현 코드와 비교 이미지 |

## 로컬 재현

Node 24.22.3, npm 11.19.1, pytest 9.2.0, Python Playwright 1.62.0을 사용했다. 입력 검증은 Chrome for Testing 151.0.7922.34 전체 바이너리로 실행했고, 고정뷰의 두 빌드는 같은 Debian Chromium 156.0.8078.79로 촬영했다. 이미지 비교에는 Pillow 13.0.0을 사용했다. 아래 경로 변수는 로컬 빌드와 브라우저의 위치를 가리킨다.

```sh
cd apps/world-client
npm ci --ignore-scripts
npm run build
npm test
node tools/build-layout.mjs --check
MOA_CAMPUS_DATA="$PORT_DATA" node tools/build-layout.mjs --check
MOA_CAMPUS_DATA="$PORT_DATA" node tests/spatial.mjs
CHROMIUM="$CHROME_FOR_TESTING" WORLD_QA_DIR="$OUT/walk" python3 -m pytest -q tests

export CHROMIUM="$CHROMIUM_156"
python3 qa/p1a/capture.py "$PR7_DIST" "$OUT/before-pc"
python3 qa/p1a/capture.py dist "$OUT/after-pc"
python3 qa/p1a/capture.py "$PR7_DIST" "$OUT/before-mobile" --width 844 --height 390
python3 qa/p1a/capture.py dist "$OUT/after-mobile" --width 844 --height 390
python3 qa/p1a/compare.py "$OUT/before-pc" "$OUT/after-pc" "$OUT/before-mobile" "$OUT/after-mobile" "$OUT/report"
```

`PR7_DIST`는 `c536c73a285ea77a62751419f1554fd9a60b166c`의 `apps/world-client`에서 `npm run build`로 생성한 `dist`다. `PORT_DATA`는 복원 패킷의 `02_threejs-port/src/campus/campus-data.js`다. 이 입력으로 기존 174개 지점을 검산한 최대 차이는 0 WU였고, 저장소 입력·독립 포트에서 각각 충돌 스윕 72개를 통과했다. 구현 커밋의 깨끗한 아카이브에서 생성한 배포 파일 17개도 작업 디렉터리의 로컬 빌드와 바이트 단위로 일치했다. 그 아카이브에서 P1A의 고정 시점 12장을 다시 촬영해 각 PNG의 SHA-256과 렌더 카운터가 최초 캡처와 일치하는 것도 확인했다.

개발 중 광장 나무 보호대가 바깥 포장과 겹쳐 면적 검사가 실패했다. 보호대도 안쪽 포장 경계로 자른 후 재검사를 통과했다. 초기 병렬 SwiftShader 실행에서는 PC 캡처와 포인터 잠금 해제가 각각 30초 제한을 넘었다. 입력 테스트가 한 구간의 실제 그리기 완료를 기다리도록 고쳤고, 최종 입력 검사는 순차 실행했다.

| 로컬 검사 | 최종 결과 |
|---|---|
| Node 설치·빌드·테스트와 레이아웃 재생성 | PASS · 9/9, 공간 회귀 174점, 충돌 스윕 72개 |
| 전체 Chromium 입력 회귀 | PASS · 20/20, 실패·건너뜀 0건, 590.13초. 신규 P1A 왕복 5개와 기존 회귀 15개 |
| P0·서비스 회귀 | PASS · 정문–본관–중앙 수로 양안–정석 왕복, 진입·후퇴, 포인터 잠금, 터치·가로 회전, 3개 기존 서비스 방 확인. 새로고침 후 닉네임·3/3 퀘스트·방명록·기존 추가 진행 키 복원. 401·503 시 게스트 진입, 세션 복원·재시도·로그아웃·동기화 권한 픽스처 통과 |
| 반복 진입·리소스 | PASS · 방 36회 방문. 12회마다 GC 뒤 DOM 노드 수 243/243/243개, JS 사용 힙 5,115,964 / 5,118,584 / 5,121,220 bytes, WebGL 컨텍스트 손실 0회. 고정 카메라에서는 양쪽 빌드의 구역 전환·재로딩 후 GPU 객체 수도 검산 |
| 고정 카메라 | PASS · 두 빌드에서 PC·모바일 가로 각 6시점의 자세·FOV·실제 버퍼·픽셀비를 짝별로 검증. PNG 해시와 차이 영역은 [카메라 측정](camera-results.json), 39구간 입력 기록과 테스트별 결과는 [브라우저 측정](browser-results.json) |

Android 실기기, 실제 계정 로그인, 하드웨어 GPU의 프레임 속도와 메모리 회수량은 HOLD다. 인증·동기화·방명록은 루프백과 격리 픽스처로 검증했다. 접근로 실측 폭·단면·촬영 좌표와 방위, 현장 사진이 없는 두 새 장소의 가구·조경 배치도 HOLD다.
