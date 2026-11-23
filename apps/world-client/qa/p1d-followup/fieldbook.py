"""Turn registered game views and source footprints into a printable five-page survey and blank CSV."""
from argparse import ArgumentParser
import base64
import csv
from html import escape
from io import BytesIO
import json
import os
from pathlib import Path
import subprocess
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon
from PIL import Image
from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
TITLE = '아고라·드림센터 현장 대조표'


def plot_map(stations, output):
    plan = json.loads(subprocess.check_output(['node', HERE/'stations.mjs', '--map']))
    edges = [('lmk_agora_plaza','#f5dcab'),('bldg_dream1','#b6ced2'),('bldg_07','#e1e6e2')]
    fig, ax = plt.subplots(figsize=(7.4,5.0), layout='constrained')
    ax.set_facecolor('#f7f8f4')
    for key,color in edges:
        ring = [(p['x'],p['z']) for p in plan['rings'][key]]
        ax.add_patch(Polygon(ring,facecolor=color,edgecolor='#56615d',linewidth=.9))
        if key!='bldg_07':
            for i,(x,z) in enumerate(ring):
                ax.plot(x,z,'.',color='#404947',ms=4)
                ax.annotate(str(i),(x,z),xytext=(-6,-6),textcoords='offset points',size=6,color='#303335')
    road=plan['approach']
    ax.plot([p['x'] for p in road],[p['z'] for p in road],'--',color='#917246',linewidth=1.3)
    for id,label in [('9767122969','Entry 1'),('9767122970','Entry 2')]:
        p=plan['doors'][id]
        ax.plot(p['x'],p['z'],'s',color='#0d506b',ms=4)
        ax.annotate(label,(p['x'],p['z']),xytext=(5,2),textcoords='offset points',size=7,color='#0d506b')
    t=plan['tree']
    tree=json.loads((HERE.parent/'p1d/raw/interference.json').read_text())['trees']['58']
    ax.add_patch(Polygon(tree['tiers']['high']['crowns']['hull'],facecolor='#72aa77',edgecolor='#46794b',alpha=.7))
    ax.plot(t['x'],t['z'],'+',color='#284b30',ms=7)
    ax.annotate('Tree 58',(t['x'],t['z']),xytext=(5,-7),textcoords='offset points',size=7)
    label_offsets={1:(-29,8),6:(-12,-6),7:(4,-11),8:(6,4),9:(-12,-7),10:(-4,9)}
    for i,station in enumerate(stations,1):
        if i==5:
            continue
        x,z,tx,tz=station['pose'][:4]
        mag=((tx-x)**2+(tz-z)**2)**.5
        ax.annotate('',xy=(x+2.6*(tx-x)/mag,z+2.6*(tz-z)/mag),xytext=(x,z),
                    arrowprops=dict(arrowstyle='->',color='#a03e27',lw=1.0,shrinkA=0,shrinkB=0))
        if i in label_offsets:
            ax.plot(x,z,'o',color='#a03e27',ms=3)
            ax.annotate('1–4' if i==1 else str(i),(x,z),xytext=label_offsets[i],textcoords='offset points',
                        fontsize=8,color='#812f20',fontweight='bold')
    ax.text(124,2.3,'AGORA',fontsize=7)
    ax.text(121,-29,'DREAM',fontsize=7)
    ax.text(151,10,'STUDENT\nCENTER',ha='center',fontsize=8)
    ax.annotate('N',xy=(109,15),xytext=(109,10),ha='center',color='#35463e',
                arrowprops=dict(arrowstyle='-|>',color='#35463e'))
    ax.plot([108,118],[-36,-36],color='#333',lw=2)
    ax.text(108,-34.3,'10 WU ≈ 20 m',size=7)
    ax.set(xlim=(106,158),ylim=(-39,23),aspect='equal',xlabel='X · east (WU)',ylabel='Z · north (WU)')
    ax.tick_params(labelsize=7)
    fig.savefig(output,dpi=170,facecolor='white')
    plt.close(fig)


def picture(path, width=740):
    with Image.open(path) as original:
        im=original.convert('RGB')
        im.thumbnail((width,width))
        data=BytesIO()
        im.save(data,'JPEG',quality=84)
        return 'data:image/jpeg;base64,' + base64.b64encode(data.getvalue()).decode()


def main():
    p=ArgumentParser(description=__doc__)
    p.add_argument('screens',type=Path,help='1280x720/after snapshot directory from capture.py')
    p.add_argument('out',type=Path)
    a=p.parse_args()
    a.out.mkdir(parents=True,exist_ok=True)
    stations=json.loads((HERE/'stations.json').read_text())
    checked=json.loads((HERE/'raw/osm.json').read_text())['checkedUTC']
    plot_map(stations,a.out/'view-plan.png')
    actual=['observedAt','photoFile','actualLatitude','actualLongitude','actualBearingDeg','cameraLensOrFov',
            'cameraHeightM','referenceObject','measurementMethod','wallToTrunkCentreM','trunkDiameterM',
            'canopyClearanceM','doorOuterWidthM','pathClearWidthM','thresholdRiseM','rampRunM',
            'materialOrFixture','permissionToUse','confidence','notes']
    with (a.out/'observations.csv').open('w',encoding='utf-8-sig',newline='') as f:
        writer=csv.writer(f)
        writer.writerow(['shot','station','label','mappedReference','suggestedLat','suggestedLon','suggestedBearingDeg',*actual])
        for i,s in enumerate(stations,1):
            coords=[round(v,7) for v in s['suggestedWGS84']] if s['suggestedWGS84'] else ['','']
            writer.writerow([i,s['id'],s['label'],s['reference'],*coords,s['bearing'],*['']*len(actual)])
    style="""
    @page{size:A4;margin:13mm 15mm}*{box-sizing:border-box}body{margin:0;color:#1d322c;font:10pt/1.48 'Noto Sans CJK KR',sans-serif}
    section{break-after:page}section:last-child{break-after:auto}header{border-bottom:1.2pt solid #2e5a4a;padding-bottom:2mm;margin:0 0 4mm}
    .k{font-size:8pt;letter-spacing:.6pt;color:#436654}h1{font-size:23pt;margin:1mm 0 0}h2{font-size:19pt;margin:1mm 0 0}
    h3{font-size:11pt;margin:2mm 0 1mm}p{margin:2mm 0}figure{margin:0}small{color:#465e56;font-size:8pt}
    .plan{width:100%;height:110mm;object-fit:contain}.cards{display:grid;grid-template-columns:1fr 1fr;gap:5mm}
    article{break-inside:avoid;border-top:1px solid #82998d;padding-top:2mm}.shot{width:100%;aspect-ratio:1.87;object-fit:contain;background:#edf2ee}
    .id{font:8pt monospace;color:#375549}.ref{font-size:8.25pt;color:#44584e}.ask{min-height:12mm}
    .note{border-bottom:1px solid #a2b2a9;height:8mm;font-size:8pt;color:#53665d}
    table{border-collapse:collapse;width:100%;margin:2mm 0 4mm;font-size:9pt}th,td{text-align:left;border:1px solid #aebbb3;padding:2mm}
    th{background:#ecf2ed}.measure td{height:11mm}.wide{margin-bottom:3mm}ul{padding-left:6mm;margin:2mm 0}li{margin:1mm 0}
    """
    def header(title,num):
        return f'<header><span class="k">INHA WORLD　|　공간 고증　·　현장용　　{num} / 5</span><h2>{title}</h2></header>'
    def card(index):
        s=stations[index-1]
        ll=s['suggestedWGS84']
        location=(f'후보 {ll[0]:.6f}, {ll[1]:.6f}　{int(s["bearing"])}°' if ll else '게임 수직 부감 · 실제 촬영점과 방향은 현장 기입')
        image=picture(a.screens/(s['id']+'.png'))
        return f"""<article><span class="id">SHOT {index:02}　{escape(s['id'])}</span>
        <h3>{escape(s['label'])}</h3><img class="shot" src="{image}"><p class="ref">{escape(s['reference'])}<br>{location}</p>
        <p class="ask">{escape(s['observe'])}</p><div class="note">실제 위치 / 방향</div><div class="note">사진 파일 / 현장 메모</div></article>"""
    pages=['<section>'+header(TITLE,1)+
        '<p>지도에 등록된 건물과 광장 경계를 기준으로 같은 장면을 다시 촬영하고, 실제 동선과 치수를 기록한다. 각 장면의 그림은 이번 게임 빌드의 화면이다.</p>'+
        f'<img class="plan" src="{picture(a.out/"view-plan.png",1140)}">'+
        '<p class="ref">붉은 번호·화살표는 촬영 후보와 방향, 점선은 접근로 중심선, 녹색은 게임의 58번 나무 수관이다. 작은 숫자는 OSM 외곽 꼭짓점 순서(0부터)다. 1 WU는 투영 좌표에서 약 2 m이다.</p>'+
        '<table><tr><th>기준물</th><th>OSM 식별자</th><th>확인할 부분</th></tr>'
        '<tr><td>아고라 광장</td><td>1099894035 · 7점</td><td>포장 끝, 진입부 단차, 가구 위치</td></tr>'
        '<tr><td>김현태인하드림센터</td><td>568420970 · 4점</td><td>2→3면과 수간, 실제 지상 벽</td></tr>'
        '<tr><td>학생회관</td><td>218038027</td><td>입구1 9767122969 / 입구2 9767122970</td></tr>'
        '<tr><td>아고라 접근로</td><td>481241696</td><td>끝 두 노드 사이의 보도 폭과 재질</td></tr></table>'
        f'<p>지도 자료 © OpenStreetMap contributors · ODbL. 좌표 대조일 {checked}. 광장 높은 시점(5번)은 실제 촬영 가능 위치가 정해지지 않아 지도에서 생략했다.</p></section>']
    for title,num,indices,intro in [
        ('광장 한 지점에서 네 방향',2,[1,2,3,4],'같은 자리에 선 뒤 진북 기준 방위를 적고 네 방향을 촬영한다. 벤치·보호대·조명은 보이는 개수와 기준점부터의 거리를 적는다.'),
        ('광장 외곽·접근로·학생회관',3,[5,6,7,10],'6번과 7번은 같은 보행 연결을 반대쪽에서 본다. 입구2의 문틀·문턱·접근 동선은 10번에 기록한다.'),
        ('드림센터 지상과 58번 나무',4,[8,9],'게임의 58번은 현장 수목 대조용 번호다. 실제 수목은 건물 모서리와 줄기 밑동을 한 사진에 담아 식별한다.')]:
        body=header(title,num)+f'<p class="wide">{intro}</p><div class="cards">'+''.join(card(i) for i in indices)+'</div>'
        if num==4:
            body+='<h3>두 방향에서 확인할 실측</h3><table class="measure"><tr><th>관측 항목</th><th>측정값 · 단위</th><th>사진 파일 / 기준점</th></tr>'+''.join(
                f'<tr><td>{label}</td><td></td><td></td></tr>' for label in ['벽면~수간 중심 수직 거리','수간 직경과 측정 높이','최저 수관 높이와 벽까지의 간격','지상층 벽·통로·출입구 위치'])+'</table><p>확인이 어려운 면은 가림 사유와 재촬영 방향을 기록한다.</p>'
        pages.append('<section>'+body+'</section>')
    pages.append('<section>'+header('촬영·관측 기록지',5)+
        '<p>한 촬영 지점마다 이 페이지를 복사하거나 같은 ZIP의 <b>observations.csv</b> 한 행을 작성한다. 좌표는 WGS84, 방향은 진북 0°, 길이·높이는 m로 기록한다.</p>'+
        '<table class="measure"><tr><th>항목</th><th style="width:65%">현장 기록</th></tr>'+''.join(
            f'<tr><td>{item}</td><td></td></tr>' for item in ['지점 번호 / 날짜·시간','사진 파일명 / 촬영 방향','실제 위도 / 경도','카메라 높이 / 화각·렌즈','기준 물체 / 측정 도구','보도 유효 폭 / 재질','계단 단차 / 경사 구간 길이','벤치·보호대·등 위치 / 개수','문틀 외폭 / 문턱 높이','지상층 통행 또는 가림','관측 신뢰도 / 그 근거','사진 사용 권한 / 허용 범위'])+
        '</table><h3>관측 결과를 게임에 반영할 때</h3><ul><li>관측값을 사진 파일 및 기준물과 함께 연결한다. 사진 #4·#5·#19는 중앙 수로 자료다.</li><li>측정할 수 없었던 치수와 보이지 않았던 구조는 HOLD로 남긴다.</li><li>현장사진의 게임 에셋 사용에는 별도로 확인한 권한이 필요하다.</li></ul></section>')
    html='<!DOCTYPE html><html lang="ko"><meta charset="utf-8"><title>'+TITLE+'</title><style>'+style+'</style><body>'+''.join(pages)+'</body></html>'
    with sync_playwright() as pw:
        browser=pw.chromium.launch(executable_path=os.environ.get('CHROMIUM','/usr/bin/chromium'),args=['--no-sandbox'])
        page=browser.new_page()
        page.set_content(html)
        page.evaluate('document.fonts.ready')
        page.pdf(path=a.out/'INHA-WORLD-fieldbook.pdf',prefer_css_page_size=True,print_background=True)
        browser.close()


if __name__=='__main__':
    main()
