# 아고라 쪽 학생회관 출입구와 현장 검증

아고라 동쪽을 바라보면 학생회관 1층 벽에 비룡플라자 입구2가 보인다. 2026-11-23 OSM에서 위치와 건물 소속을 확인했다. 이 노드에 연결된 보행로는 없어서 기존 벽의 외부 접촉을 유지했다. 화면에 보이는 문 폭·높이·유리·손잡이는 같은 건물의 기존 입구1 모델을 이용한 표현상 추정이다. [PC 정면 전후](screens/1280x720-student-entry2.png) · [모바일 정면 전후](screens/891x411-student-entry2.png) · [아고라에서 본 PC 화면](screens/1280x720-agora-east.png) · [모바일 화면](screens/891x411-agora-east.png)

새 작업 이슈나 PR #14의 후속 리뷰가 없는 상태에서 Issue #13의 현장 실측·Android 보류 항목과 관련된 작업을 진행했다. 기준은 PR #14의 `664e465d5b34932bdda530c6680aca380be84348`, 게임 소스는 `4ef469da690bf3441558c01942ab3b0ec838262f`다. [Issue #13](https://github.com/aldol2678/inhaworld/issues/13) · [기준 Draft PR](https://github.com/aldol2678/inhaworld/pull/14)

## 공간 근거와 촬영표

| 대상 | 확인한 근거 | 구현·실측 상태 |
|---|---|---|
| 학생회관 입구2 | OSM 노드 9767122970 v1, 위도 37.4491754·경도 126.6563578. 소속 way는 학생회관 218038027 v6 한 개 | 정확한 노드에 근거리 문 14개 삼각형. 문턱·경사·연결 보도 폭과 재질은 HOLD |
| 기존 북쪽 입구1 | 9767122969는 같은 건물과 보도 1063267429에 연결 | 기존 출입구·진입 동선 유지. PC와 모바일 정면 전후 픽셀 차이 0 |
| 아고라 | 1099894035의 7개 꼭짓점 순서와 시설 원장 일치 | 광장 사방, 높은 시점, 보행 진입·역방향 촬영 후보. 가구 위치·수량, 계단·경사와 단차는 HOLD |
| 드림센터·게임 tree-58 | 건물 568420970의 4개 꼭짓점 일치. 게임 나무 중심은 2→3번 변 안쪽 0.3881 WU | 게임 내 평면 겹침과 실제 지상 벽·수목 간격을 구분. 현장 기준 사진과 수직 거리 필요 |
| 중앙 수로 | 68장 중 #4·#5·#19는 수로 축과 잔디·보행로 자료 | 아고라·드림센터의 직접 근거로 사용하지 않음 |
| 10월 답사 | 48장 분류·복원 대조표의 16개 장면과 11월 분류표 재확인 | 아고라·드림센터 지상부의 직접 촬영점·치수를 특정할 근거 부족 |

[OSM 원시 응답에서 추출한 좌표·노드 소속](raw/osm.json) · [입구2 OSM 이력](https://www.openstreetmap.org/node/9767122970/history/1) · [11월 원본 사진](https://drive.google.com/file/d/1BUc_dwW6ugZ_4sZHQUqLIuPO3mEl0E8A/view) · [사진 분류표](https://docs.google.com/spreadsheets/d/1Hgj_Qiyr_-EWfW6DxZ2wTU5OaB9ELGQI/edit) · [ARK 대조 보고서](https://docs.google.com/document/d/1rLeZsskkzRVrQzebvnxYap7MxvLynt3I/edit) · [10월 원장](https://docs.google.com/spreadsheets/d/16F7XBG0XYlfpMVoWzcRugFLAqpk4jvBR/edit) · [10월 복원 대조표](https://docs.google.com/spreadsheets/d/1Nv7Pj0EY5pJPWGULw-j0I5Ol1i4zUvf_/edit)

촬영표는 게임 카메라 10개를 실제 촬영 방향·기준물과 대조할 수 있게 구성했다. 지상 9개 시점은 게임의 보행 여유를 확인했다. 부감은 가상 시점으로, 실제 촬영 위치와 방위는 비워 뒀다. 모든 실제 관측·권한 칸은 비어 있다. PDF 속 그림은 이 게임에서 캡처했다. [현장 촬영표 5쪽](field/INHA-WORLD-fieldbook.pdf) · [현장 입력 CSV](field/observations.csv) · [방향 지도](field/view-plan.png)

## 로컬 플레이와 기기 측정

플레이 ZIP을 풀고 `python3 start.py` 또는 Windows의 `py start.py`를 실행한 뒤 `http://127.0.0.1:8080/`을 연다. PC는 장면을 클릭해 WASD·마우스로 조작한다. 휴대폰은 같은 Wi-Fi에서 PC의 `python3 start.py --lan`과 사설 IP를 이용한다. [플레이·측정 ZIP](INHA-WORLD-field-kit.zip)

`/device/`의 **기기 측정**에서 장소와 시간을 선택하고 실제로 이동한 뒤 **JSON 저장**을 누른다. 30초·2분·10분 또는 수동 종료를 지원한다. 기기 모델과 실물 여부는 작성자 기입값이다. JSON에는 품질·DPR·버퍼 해상도별 프레임 원시 간격, 초당 드로우콜·삼각형·활성 정점/인덱스 버퍼 바이트, 이동 위치와 탭 상태가 담긴다. 기록기는 로컬 게스트 게임을 사용하므로 QA 출발점 이동이 같은 브라우저의 게스트 방문 기록에 반영될 수 있다.

| 실행한 검증 | 결과 |
|---|---|
| Node 24.22.3, npm 11.19.1 | 빌드 완료. 기본 원장과 독립 MOA 포트에서 각각 18/18. 좌표 174점 최대 차이 0 WU, 스윕 77개씩 |
| Chromium 151 전체 회귀 | 32/32 통과, 건너뜀 0. anyio의 pytest 차기 버전 호환 경고 1건 |
| PC 1280×720 / 터치 891×411 | 정문→아고라→인경호→정문 각각 39개 입력 구간, 정문 (0, −98) 복귀. 수로 양안 각각 10개 구간. 수로 4/4변, 호수 13/13변 차단 |
| 학생회관 입구2 | 키보드·조이스틱 모두 외벽 앞 0.582 WU에서 멈추고 벽을 따라 이동. HUD는 소수점 한 자리. 연속 좌표 Node 검사는 캡슐 여유 0.60 WU |
| 게임 회귀 | 퀘스트 3/3·저장 복원, 로컬 인증 세션 복원·로그아웃·동기화 재시도, 수목·건물 접촉, 여섯 품질 선택·수동 복원 통과. 인증·동기화는 로컬 서비스 응답 사용 |
| 자동 품질 | 원래 PC 자동 하향·상향을 실제 RAF에서 재현. 이동·마우스 잠금 유지, 회전·크기 변경·탭 복귀 검증 |
| 녹화기 Chromium 156 | PC 키보드·터치 가로 조이스틱 각각 실제 30초 녹화·JSON 재다운로드. 터치판 회전, 높음→매우 낮음, MSAA 문맥 교체, 같은 페이지 재녹화·수동 종료 검증 |
| 백그라운드 | 실제 두 탭에서 hidden→visible 관찰. 벽시계 5.094초 중 기록된 전경 시간 1.983초. 구간 사이 정지 시간이 프레임 p95에 포함되지 않음 |
| 일반 빌드·기하 | 정적 파일 19개 중 맵 바이너리·목록 2개 변경. 기존 정점 모두 바이트 동일. 근접 레이어 +42정점/+14삼각형/+672파일 바이트. 기존 수목 68, 충돌체 158, 보행 경로 10 |

[QA 보고서 PDF](QA-KO.pdf) · [Node 원시 로그](raw/node.txt) · [Chromium JUnit](raw/chromium.xml) · [이동·충돌과 품질 기록](raw/play/) · [녹화기 두 화면](raw/device-check.json) · [실제 탭 전환](raw/device-tab.json) · [빌드 바이트 대조](raw/build-diff.json) · [등록 카메라별 원시값](raw/cameras.json)

## 성능

PC 중앙 수로 서안에서 PR #14와 이번 빌드를 측정했다. 양쪽 모두 DPR 1, 내부 940×504, 네이티브 MSAA 4×, 드로우콜 9, 삼각형 27,101이었다. 같은 WebGL 문맥에서 자동·수동 높음을 ABBA/BAAB 순으로 비교했다. 각 빌드·설정당 표시 간격 160개와 별도 동기 렌더·읽기 96개를 사용했다. FPS는 표시 간격의 평균으로 산출했다.

| PC 수로 | FPS 전→후 | 표시 간격 중앙값 / p95 전→후 (ms) | 동기 렌더·읽기 p95 전→후 (ms) |
|---|---:|---:|---:|
| 자동, 높음으로 해석 | 29.09→28.49 | 33.3 / 50.1→33.3 / 66.6 | 44.2→42.1 |
| 수동 높음 | 26.30→30.10 | 33.4 / 66.7→33.3 / 50.1 | 40.7→40.7 |

같은 지점의 정점·인덱스 버퍼는 1,407,574→1,408,330 B(+756 B)였다. 두 설정의 프레임 p95는 반대 방향으로 변해 성능 향상으로 판정하기 어렵다. 프리셋 전체는 PC·모바일 각각 순방향과 역방향으로 측정했다. 모바일 에뮬레이션 매우 낮음의 내부 해상도는 579×187, 표시 p95는 16.7→16.8 ms였다. 수치는 SwiftShader에서 얻었고, GPU 전체 메모리·실물 발열·온도는 측정하지 않았다. [전후·여섯 설정 성능 CSV](performance.csv) · [기준 수로 반복](raw/canal-before.json) · [후보 수로 반복](raw/canal-after.json) · [기준 전 설정](raw/tiers-before.json) · [후보 전 설정](raw/tiers-after.json)

## 후속 순서

1. 드림센터 2→3번 면의 지상 사진, 나무 밑동과 벽의 수직 거리·수관 높이를 함께 수집한다. 근경 벽과 실제 나무 위치는 HOLD다.
2. 아고라 네 방향과 보행 접근로를 양방향으로 촬영한다. 입구2 문턱·보도·경사, 광장 포장과 가구는 기준점·실측·사진 사용 권한을 연결한 뒤 반영한다.
3. 실제 Android에서 중앙 수로와 광장 구간을 10분씩 측정한다. 기기 모델·브라우저·품질·시작/종료 상태를 기록해 이번 에뮬레이션 결과와 대조한다. ADB 기기 목록은 비어 있었다. [ADB 실행 기록](raw/adb.txt)

## 재현

아래 경로는 `apps/world-client` 기준이다. `BASE_DIST`는 PR #14의 빌드, `WORK`는 임시 출력 경로다. 지도·집계는 해당 코드의 좌표 투영·P1D 성능 집계를 재사용한다. 브라우저 검증에는 Chromium·Playwright가, 인쇄본 생성에는 Pillow·Matplotlib이 필요하다.

```sh
npm ci --ignore-scripts
npm run build
npm test
python3 qa/p1d-followup/compare-dist.py "$BASE_DIST" dist qa/p1d-followup/raw/build-diff.json
node qa/p1d-followup/stations.mjs > qa/p1d-followup/stations.json
python3 qa/p1d-followup/capture.py "$BASE_DIST" dist qa/p1d-followup "$WORK/screens"
python3 qa/p1d-followup/fieldbook.py "$WORK/screens/1280x720/after" qa/p1d-followup/field
python3 qa/p1d-followup/aggregate.py
python3 qa/p1d-followup/report.py
python3 qa/p1d-followup/build-kit.py dist "$WORK/field-kit.zip" --source 4ef469da690bf3441558c01942ab3b0ec838262f --field qa/p1d-followup/field --qa
python3 qa/p1d-followup/check-device.py "$WORK/field-kit.zip" "$WORK/device"
python3 qa/p1d-followup/check-background.py "$WORK/field-kit.zip" "$WORK/device/tab.json"
```
