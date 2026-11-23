# 중앙 수로와 아고라·인경호 연결 구역

PR #10의 현장 반영 커밋 `b8356ed`에서 분기한 Three.js 클라이언트다. P1B·P1C의 경계, 그래픽 LOD와 플레이 결과를 같은 빌드로 비교했다. [작업 지시 #11](https://github.com/aldol2678/inhaworld/issues/11) · [기준 Draft PR #10](https://github.com/aldol2678/inhaworld/pull/10) · [공간별 근거와 다음 우선순위](evidence.md) · [사진별 판정 68건](photo-crosswalk.csv)

[로컬 플레이 ZIP](INHA-WORLD-play.zip)을 풀고 `python3 start.py`를 실행한다. 같은 Wi-Fi의 휴대폰에서는 `python3 start.py --lan`으로 연 PC의 로컬 주소와 8080 포트에 접속한다. 두 기기는 동일한 정적 빌드를 사용한다. [압축 해제 후 일반 게임 프레임으로 실행한 기록](raw/zip-play.json)

| 구역 | 플레이에서 확인할 부분 | PC 전후 PNG | 891×411 전후 PNG |
|---|---|---|---|
| 중앙 잔디광장 | 네 잔디 구획, 양안 수목 열, 건물 높낮이 | [부감](screens/1280x720/lawns.png) | [부감](screens/891x411/lawns.png) |
| 수로 서안 | 보도·잔디 경계와 호안석, 본관 방향 수면 반사광 | [서안](screens/1280x720/canal-west.png) | [서안](screens/891x411/canal-west.png) |
| 수로 동안 | 건너편 보행로·정석 측면 창호와 원경 | [동안](screens/1280x720/canal-east.png) | [동안](screens/891x411/canal-east.png) |
| 아고라·인경호 | 접근로 정렬, 광장 가장자리·수관, 학생회관 입구 후면 | [연결부](screens/1280x720/connector.png) · [입구](screens/1280x720/student-entry.png) | [광장](screens/891x411/agora.png) · [인경호](screens/891x411/pond.png) |
| 화면과 품질 UI | 같은 조망에서 여섯 선택의 결과와 적용 해상도 | [단계별](screens/1280x720/quality.png) · [UI](screens/1280x720-settings.png) | [단계별](screens/891x411/quality.png) · [UI](screens/891x411-settings.png) |

두 빌드에서 각 기기당 11개 카메라의 위치·방위·피치·FOV·DPR·버퍼 크기를 대조했다. 비교 PNG 왼쪽은 PR #10, 오른쪽은 개선 빌드의 높음이다. 분류표의 현장사진과 게임 카메라 사이에는 알려진 보정값이 없다. [PC 11쌍](screens/1280x720/) · [가로 터치 11쌍](screens/891x411/) · [카메라 수치](raw/cameras.json)

## 그래픽 설정

| 선택 | DPR 상한 | 단순화 거리 WU | 적용되는 기능 |
|---|---:|---:|---|
| 자동 | 현재 단계 | 현재 단계 | 화면 픽셀 수·DPR, 터치 포인터, GPU 최대 텍스처 크기로 시작해 실측 프레임 간격으로 조정 |
| 매우 낮음 | 0.65 | 57 | 기본 건물 외곽·창띠, 수면·보행로, 모든 주 수관·줄기, 저폴리 수관 |
| 낮음 | 0.80 | 78 | 접근로 경계와 창 사이 기둥, 저폴리 수관 |
| 중간 | 1.25 | 100 | 세분 수관과 일부 보조 수관, 호안석 이음·일부 관목, 보도 표면 |
| 높음 | 2.00 | 120 | 추가 관목·가지·창턱·줄눈, 더 조밀한 보조 수관, 지원 기기의 네이티브 MSAA |
| 울트라 | 2.00 | 154 | 최장 가시 거리, 가까운 보조 수관 전체, 낙엽·세부 줄눈·관목 전 단계, 네이티브 MSAA |

수면·지형·충돌은 공통 원장을 사용한다. 인경호 근경의 최소 거리는 75 WU다. 고품질 MSAA는 이 Chromium에서 4샘플이었다. AA가 바뀔 때 고정 입력 영역은 유지하고 이전 GPU 자원을 해제한다. 그림자는 기존 고정 조명·지면 색과 수관의 명암 표현을 쓴다. 실시간 그림자맵 옵션은 제공하지 않는다.

자동은 게임이 실제 렌더링한 프레임 사이의 시간으로 2초 구간의 p75를 구한다. 29 ms를 넘는 두 구간에서 한 단계 낮추고, 19 ms 미만인 다섯 구간에서 한 단계 복구한다. 하향 뒤 14초, 상향 뒤 8초 동안 다시 판단하지 않는다. 탭 복귀 때 표본을 비우며 자동의 터치 상한은 높음이다. 수동 선택은 즉시 적용하며 같은 출처의 PlayCanvas v1 미러와 기존 v2 설정의 품질 필드만 쓴다. [기존 PlayCanvas 원본](https://github.com/aldol2678/inhagame/blob/0b72d2593ecd3e9bb6293724771cdfb978e74ccf/apps/world/src/graphics-presets.js) · [설정 키 원장](https://github.com/aldol2678/inhagame/blob/0b72d2593ecd3e9bb6293724771cdfb978e74ccf/apps/world/src/settings-registry.js)

## 로컬 검증

- **빌드와 공간**. Node 24.22.3의 깨끗한 소스 빌드가 개발 빌드와 파일 단위로 일치했다. Node 테스트 15개, 독립 좌표 174점(최대 편차 0 WU), 충돌 스윕 77건을 통과했다. 기존 충돌체 155개·보행로·수목·계단 배열을 기준 커밋과 대조했고 신규 건물 3채의 충돌은 원장 외곽에 일치한다. 수로 수면 면적은 304.3424 WU²이며 마른 표면이 수면을 가린 면적은 0이다. 새 조경·줄눈과 아고라 경계의 겹침을 자르는 별도 회귀 검사가 있다. OSM 15개 way의 현행 WGS84 순서가 원장과 일치했다. [Node 원시 출력](raw/node.txt) · [OSM 재조회](raw/osm.json) · [빌드 해시](raw/build.json)
- **플레이와 저장**. Chromium 151에서 브라우저 테스트 25개가 통과했다. 정문→아고라→호수 동측→정문 왕복은 5개 뷰포트에서 모두 원래 위치 (0, −98)로 복귀했다. PC와 891×411에서는 중앙 수로 양안의 전체 중심선도 키보드·마우스 및 조이스틱으로 걸었다. 모든 수동 단계에서 호수 13변과 수로 4변을 검사했고, 건물 외벽·도서관 유리 출입구·벤치 차단을 확인했다. 로컬 퀘스트 3/3·방명록·닉네임 복원, 인증 실패 401/503에서 게스트 부팅, 서버 세션 복구·재시도·로그아웃과 동기화 소유권 거부를 로컬 픽스처로 검증했다. [케이스별 결과·이동 기록](raw/playthrough.json) · [PC 왕복 중 화면](screens/1280x720-walk.png) · [모바일 왕복 중 화면](screens/891x411-walk.png)
- **그래픽과 입력**. DPR 2에서 각 단계의 실제 버퍼 크기, MSAA, 수관·프리셋별 드로우 범위와 원본 충돌을 확인했다. 포인터 잠금 또는 조이스틱 입력을 유지한 상태에서 AA를 바꿔도 이동이 이어졌다. 실제 RAF에 지속 부하를 주자 자동이 중간→낮음으로 내려갔다. 통제한 프레임 간격에서는 낮음→중간 복구와 수동 울트라 유지, 새로고침 저장을 확인했다. [프리셋별 실제 GPU 상태](raw/cameras.json) · [자동 전환 기록](raw/playthrough.json)
- **HOLD**. Android 실물, 장시간 발열·배터리, 운영 인증·동기화 실계정은 검증을 보류했다. 아고라 직접 사진, 시설 치수·위치·조형물 권리는 공간 근거표에 남겼다. [근거와 우선순위](evidence.md)

## 성능

DPR 1, Chromium 156 SwiftShader에서 게임을 한 번에 하나만 돌렸다. 두 측정 회차의 순서를 반대로 했다. 수로에서 실제 게임 RAF 40구간씩, 수로·인경호 고정 카메라 각각 워밍업 12회 후 1픽셀 동기 읽기까지 30프레임씩 기록했다. 아래 FPS는 수로 실제 프레임 간격의 평균에서 구했고, p95는 각각 60개 동기 렌더 표본의 95번째 백분위다. 두 지표는 측정 방식과 장면이 다르다. GPU 메모리 수치는 WebGL 정점·색·인덱스·인스턴스 버퍼 할당량이다. 드라이버 전체 메모리와 기본 프레임버퍼는 포함하지 않는다. [프레임별 원시값·드로우콜·삼각형·버퍼·GC 후 JS 힙](raw/performance.json) · [기기·프리셋·장소별 집계](performance.csv)

| 선택 | PC 수로 FPS | PC 수로 p95 | PC 인경호 p95 | 모바일 수로 FPS | 모바일 수로 p95 | 모바일 인경호 p95 |
|---|---:|---:|---:|---:|---:|---:|
| PR #10 | 31.2 | 38.6 ms | 37.8 ms | 37.5 | 36.0 ms | 35.5 ms |
| 자동 | 24.1 | 40.5 ms | 29.8 ms | 60.0 | 26.7 ms | 24.3 ms |
| 매우 낮음 | 60.0 | 9.8 ms | 9.6 ms | 60.0 | 4.0 ms | 7.6 ms |
| 낮음 | 58.5 | 25.0 ms | 21.9 ms | 60.0 | 16.7 ms | 18.2 ms |
| 중간 | 51.1 | 28.3 ms | 24.6 ms | 59.3 | 25.5 ms | 23.9 ms |
| 높음 | 31.4 | 36.7 ms | 28.3 ms | 41.0 | 35.8 ms | 29.9 ms |
| 울트라 | 28.4 | 39.5 ms | 29.6 ms | 34.0 | 36.6 ms | 31.3 ms |

891×411 인경호 낮음에서는 기존 4회·18,850삼각형에서 5회·16,844삼각형으로 바뀌었다. 해당 카메라의 WebGL 버퍼는 1,356,110 → 1,389,220바이트다. PC 수로 높음은 5 → 9드로우콜, 17,968 → 26,877삼각형이다. 모바일 낮음과 울트라의 잔디 구획·양안·건물 윤곽을 같은 구도에서 육안으로 비교했다. 자동 행은 이 환경의 시작 단계(PC 높음, 터치 중간)를 포함한다. 이전 보고서의 모바일 인경호 p95 33.5 → 34.7 ms는 별도 실행의 기록이다. [P1A 측정 원본](../p1a/field-study/render-times.json)

로컬 SwiftShader와 두 회차 표본은 실기기 성능을 확정하기에 부족하다. 창 크기와 화면상의 시점에 따라 결과가 달라지므로 플레이 프레임·동기 렌더·버퍼 수를 함께 기록했다.

전체 정적 파일은 3,035,110 → 3,565,551바이트, 파일별 gzip-9 합계는 619,436 → 748,751바이트다. `layout.bin`은 713,808 → 1,225,152바이트다. gzip 합계는 로컬 압축 크기이며 네트워크 전송 실측은 HOLD다. [파일별 크기·해시](raw/build.json)

## 재현

`apps/world-client`에서 Node 24 이상으로 다음을 실행한다.

```sh
npm ci --ignore-scripts
npm run build
npm test
node tools/build-layout.mjs --check
python3 -m http.server 8080 --bind 127.0.0.1 --directory dist
```

브라우저 테스트에는 Python의 pytest·Playwright와 Chromium이 필요하다. `CHROMIUM=/path/to/chrome WORLD_QA_DIR=/tmp/inha-input python3 -m pytest -q tests`로 실행한다. PNG 생성에는 Pillow가 추가로 필요하다. PR #10의 기준 커밋을 별도 작업 폴더에서 빌드한 뒤 아래 명령의 첫 번째 경로에 지정한다. 운영 자격 증명이나 유료 서비스가 필요하지 않다.

```sh
python3 qa/p1bc/capture.py /path/to/baseline/dist dist qa/p1bc /tmp/inha-cameras --mode screens
python3 qa/p1bc/capture.py /path/to/baseline/dist dist qa/p1bc /tmp/inha-cameras --mode perf
python3 qa/p1bc/summarize.py
python3 qa/p1bc/check_sources.py
```
