"""Render the handoff PDF from this run's measurements and registered before/after images."""
import base64
import csv
from datetime import datetime
import json
import os
from pathlib import Path
from playwright.sync_api import sync_playwright

HERE=Path(__file__).resolve().parent
RAW=HERE/'raw'


def table(headers,rows):
    h=''.join('<th>'+x+'</th>' for x in headers)
    return '<table><thead><tr>'+h+'</tr></thead><tbody>'+''.join('<tr>'+''.join('<td>'+str(x)+'</td>' for x in row)+'</tr>' for row in rows)+'</tbody></table>'


def raw(name):
    return json.loads((RAW/(name+'.json')).read_text())


def picture(name):
    return 'data:image/png;base64,'+base64.b64encode((HERE/'screens'/name).read_bytes()).decode()


def main():
    receipts=raw('device-check')
    diff=raw('build-diff')
    camera=raw('cameras')
    tab=raw('device-tab')
    gap=(datetime.fromisoformat(tab['finishedAt'])-datetime.fromisoformat(tab['startedAt'])).total_seconds()-tab['activeMs']/1000
    data=list(csv.DictReader((HERE/'performance.csv').open()))
    def header(page,title):
        return f'<header><small>INHA WORLD　·　로컬 QA　　{page} / 3</small><h1>{title}</h1></header>'
    def compare(name):
        return f'<img class="pair" src="{picture(name)}">'
    pages=[header(1,'아고라에서 본 학생회관 입구2')+
        '<p>OSM 노드 9767122970은 학생회관 외곽 218038027에 속한다. 공개 원장의 문 위치에 기존 건물의 이중문 표현을 추가했다. 문 폭과 외장 재질은 같은 건물의 근경 모델을 따른 추정이다.</p>'+
        compare('1280x720-student-entry2.png')+'<p class="caption">PC · 학생회관 외벽 정면. 왼쪽 PR #14, 오른쪽 이번 빌드.</p>'+
        compare('891x411-agora-east.png')+'<p class="caption">모바일 가로 · 아고라 동쪽 조망. 왼쪽과 오른쪽은 같은 위치·방위·렌즈·해상도다.</p>'+
        table(['검증','관찰값'],[
            ['입구2 정면 변경 화소 (휘도)','PC {:,} / 모바일 {:,}'.format(*[camera[t]['student-entry2']['changedLumaPixels'] for t in ['1280x720','891x411']])],
            ['기존 북쪽 입구1 정면','PC·모바일 모두 전후 RGB 픽셀 동일'],
            ['근경 메시','기존 정점 바이트 동일. 문 +14삼각형 / 맵 +672 B'],
            ['게임 공간','수목 68, 충돌체 158, 보행 동선 10 동일']])+
        '<p>드림센터 지상 외벽과 58번 나무, 아고라 가구·단차, 입구2 문턱은 현장 실측 대기다. 동봉한 5쪽 촬영표는 후보 10개와 실제 관측값을 나눠 기록한다.</p>'+
        f'<p class="caption">기준 664e465d5b34932bdda530c6680aca380be84348<br>게임 소스 {receipts["source"]} · 지도 © OpenStreetMap contributors, ODbL</p>']
    rows=[]
    for case in receipts['cases']:
        s=case['summary']
        rows.append(['×'.join(map(str,case['viewport'])),f'{case["activeMs"]/1000:.2f}',f'{case["walkedWU"]:.2f}',
                     s['count'],f'{s["fps"]:.1f}',f'{s["medianMs"]:.1f} / {s["p95Ms"]:.1f}'])
    paired=[]
    for key,label in [('auto','자동 → 높음'),('high','수동 높음')]:
        pair=[next(r for r in data if r['series']=='canal' and r['build']==b and r['preset']==key) for b in ['before','after']]
        paired.append([label]+[' → '.join(r[k] for r in pair) for k in ['rafFPS','frameMedianMs','frameP95Ms','syncP95Ms']])
    pages.append(header(2,'플레이·측정 결과')+
        table(['실행','결과'],[
            ['Node 24 · 기본 및 독립 원장','각 18/18 통과. 좌표 174점 최대 차이 0 WU, 스윕 77개'],
            ['Chromium 151 · 전체 회귀','32/32 통과. anyio·pytest 호환 경고 1건'],
            ['PC·터치 가로','정문 왕복 각 39개 입력 구간, 중앙 수로 양안 각 10개 구간. 호수 13/13변, 수로 4/4변 차단'],
            ['입구2·드림센터 수목','입구2 외벽 여유 약 0.58 WU. 벽 옆 이동, 58번 줄기 정지와 기존 통로 복귀'],
            ['퀘스트·설정·로컬 서비스','3/3 완료·새로고침, 인증 세션·동기화 재시도, 품질 하향·복구와 조작 유지 검증'],
            ['배포 파일',f'{diff["buildFiles"]}개 중 레이아웃 JSON·바이너리 2개 변경']])+
        '<h2>기기용 JSON 내보내기</h2><p>두 환경에서 실제로 30초간 플레이하며 높음에서 매우 낮음으로 전환했다. 모바일은 Chromium 156 터치 에뮬레이션이며, 수치에는 전환 전·후가 함께 들어 있다.</p>'+
        table(['화면','전경 초','이동 WU','프레임','FPS','중앙 / p95 ms'],rows)+
        f'<p>재녹화·수동 종료·기기 회전·다운로드를 확인했다. 실제 두 탭을 전환한 별도 시험은 백그라운드 대기 약 {gap:.2f}초를 제외했다. ADB에서 연결된 기기는 0대로 실물 Android 장시간·발열 측정은 HOLD다.</p>'+
        '<h2>PC 중앙 수로 비교</h2><p>1280×720, DPR 1, 내부 940×504. 각 행은 두 빌드 각각 표시 간격 160개와 동기 렌더·읽기 96개의 집계다.</p>'+
        table(['설정','FPS 전→후','중앙 ms','표시 p95 ms','렌더·읽기 p95 ms'],paired)+
        '<p>두 설정 모두 같은 높음, 9드로우콜, 27,101삼각형이었다. 정점·인덱스 버퍼는 1,407,574→1,408,330 B다. 표본별 편차가 있어 전체 성능 향상으로 판정하기 어렵다.</p>')
    tiers={'auto':'자동','very_low':'매우 낮음','low':'낮음','medium':'중간','high':'높음','ultra':'울트라'}
    content=header(3,'여섯 설정별 실제 렌더링')+'<p>중앙 수로 서안 고정 카메라. 프리셋을 순방향·역방향으로 각 1회 측정했다. 각 전후 값은 표시 간격 80개, 동기 렌더·읽기 48개를 모은 결과다.</p>'
    for viewport in ('1280x720','891x411'):
        trows=[]
        for key,label in tiers.items():
            b,a=[next(r for r in data if r['series']=='tiers' and r['build']==ph and r['preset']==key and r['viewport']==viewport) for ph in ['before','after']]
            trows.append([label,a['resolution'],b['rafFPS']+'→'+a['rafFPS'],b['frameP95Ms']+'→'+a['frameP95Ms'],
                        a['syncP95Ms'],a['calls']+' / '+a['triangles'],f'{int(a["webglBufferBytes"]):,}'])
        content+='<h2>'+viewport.replace('x','×')+'</h2>'+table(['선택','내부 픽셀','FPS 전→후','표시 p95<br>ms 전→후','렌더·읽기<br>p95 ms 후','콜 / 삼각형<br>후','버퍼 B 후'],trows)
    content+='<p>PC 자동은 높음, 터치 자동은 중간을 선택했다. 높음·울트라는 네이티브 MSAA 4×였다. 버퍼 바이트는 활성 정점·인덱스 버퍼에 한정한다. 원시 프레임·품질·AA·동기 렌더·읽기·버퍼 데이터는 ZIP의 qa/raw, 집계표는 qa/performance.csv에 있다.</p>'
    pages.append(content)
    style="""@page{size:A4;margin:15mm}*{box-sizing:border-box}body{margin:0;color:#20382e;font:10pt/1.55 'Noto Sans CJK KR',sans-serif}header{border-bottom:1pt solid #668c7a}small,.caption{color:#486759;font-size:8pt}h1{font-size:21pt;margin:2mm 0}h2{font-size:13pt;margin:5mm 0 1mm}p{margin:2.5mm 0}section{break-after:page}section:last-child{break-after:auto}table{border-collapse:collapse;margin:2mm 0 4mm;width:100%;font-size:8.4pt;font-variant-numeric:tabular-nums}th,td{padding:1.8mm;text-align:left;border-bottom:.25mm solid #b3c4b9}th{background:#eaf0ec}.pair{width:100%;max-height:64mm;object-fit:contain;background:#edf1ee}"""
    html='<!DOCTYPE html><html lang="ko"><meta charset="utf-8"><title>INHA WORLD 현장 검증 QA</title><style>'+style+'</style><body>'+''.join('<section>'+s+'</section>' for s in pages)+'</body></html>'
    with sync_playwright() as pw:
        br=pw.chromium.launch(executable_path=os.getenv('CHROMIUM','/usr/bin/chromium'),args=['--no-sandbox'])
        p=br.new_page()
        p.set_content(html)
        p.evaluate('document.fonts.ready')
        p.pdf(path=HERE/'QA-KO.pdf',prefer_css_page_size=True,print_background=True)
        br.close()


if __name__=='__main__':
    main()
