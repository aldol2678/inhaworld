"""Package a verified local build; optionally add reports and original game captures for handoff."""
import argparse
import hashlib
import json
from pathlib import Path
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED

HERE=Path(__file__).resolve().parent
GUIDE="""# INHA WORLD P1D 로컬 플레이

ZIP을 푼 폴더에서 `python3 start.py`를 실행한 뒤 http://127.0.0.1:8080 을 연다. Windows에서는 `py start.py`를 사용할 수 있다. Python 3과 WebGL2 브라우저가 필요하다.

휴대폰은 PC와 같은 Wi-Fi에 연결한다. PC에서 `python3 start.py --lan`을 실행하고 휴대폰 브라우저에서 PC의 사설 IP와 8080 포트로 접속한다. 가로로 돌린 뒤 왼손으로 이동하고 오른손으로 시점을 돌린다. PC에서는 장면을 클릭하고 WASD와 마우스를 사용한다. Esc 키로 포인터 잠금을 푼다.

상단 그래픽 설정에서 자동 또는 다섯 단계의 수동 품질을 고를 수 있다. 같은 브라우저에서 다시 열면 선택이 복원된다. 이 빌드는 로컬 게스트 모드로 플레이한다. 3개 퀘스트와 방명록 등 개인 진행 사항은 해당 브라우저에 저장된다.

드림센터는 동쪽 원경에서 확인할 수 있다. 수목과 접하는 지상부는 현장 확인 대상으로 남겨 근접하면 원경 모델이 서서히 사라진다. 아고라에서는 기존 두 좌석과 포장 경계를 원거리에서도 볼 수 있다. 소스 커밋과 자료 출처는 SOURCE.txt에 있다.
"""
def add(z,name,data):
    entry=ZipInfo(str(name),(2026,11,23,0,0,0))
    entry.compress_type=ZIP_DEFLATED
    entry.external_attr=0o100644 << 16
    z.writestr(entry,data,compresslevel=9)
def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('dist',type=Path)
    ap.add_argument('zip',type=Path)
    ap.add_argument('--screens',type=Path,help='Include evidence and the original before/after PNGs')
    ap.add_argument('--pr',default='https://github.com/aldol2678/inhaworld/issues/13')
    a=ap.parse_args()
    receipt=json.loads((HERE/'raw/build.json').read_text())
    source=receipt['sourceCommit'];base=receipt['baseCommit']
    with ZipFile(HERE.parent/'p1bc/INHA-WORLD-play.zip') as parent, ZipFile(a.zip,'w') as z:
        add(z,'start.py',parent.read('start.py'))
        add(z,'PLAY-KO.md',GUIDE)
        add(z,'SOURCE.txt',f'INHA WORLD Three.js P1D\nSource {source}\nBase {base}\n{a.pr}\n'+
            'Map data © OpenStreetMap contributors, ODbL, https://www.openstreetmap.org/copyright\n'+
            'Three.js license: play/vendor/LICENSE\n')
        for key,item in receipt['after'].items():
            data=(a.dist/key).read_bytes()
            assert hashlib.sha256(data).hexdigest()==item['sha256'],key
            add(z,'play/'+key,data)
        if a.screens:
            for p in sorted(HERE.rglob('*')):
                if p.is_file() and p.suffix in ['.md','.json','.csv','.png','.txt','.xml','.py','.js','.mjs']:
                    add(z,'QA/'+p.relative_to(HERE).as_posix(),p.read_bytes())
            for p in sorted(a.screens.rglob('*.png')):
                add(z,'PNG-originals/'+p.relative_to(a.screens).as_posix(),p.read_bytes())
    with ZipFile(a.zip) as z: assert z.testzip() is None
    print(a.zip,a.zip.stat().st_size,hashlib.sha256(a.zip.read_bytes()).hexdigest())
if __name__=='__main__':main()
