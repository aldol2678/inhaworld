"""Make an offline play/field kit. Reuse the normal server and keep every release file byte-identical."""
from argparse import ArgumentParser
from hashlib import sha256
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

HERE = Path(__file__).resolve().parent
GUIDE = """# INHA WORLD 현장 대조 · 기기 측정

ZIP을 풀고 Python 3으로 `python3 start.py`를 실행한다(Windows는 `py start.py`). PC 브라우저에서 http://127.0.0.1:8080 으로 접속하면 일반 게임이 열린다.

휴대폰은 같은 Wi-Fi에 연결하고 PC에서 `python3 start.py --lan`을 실행한다. 휴대폰 Chrome에서 PC의 사설 IP와 포트 8080을 연다. 주소 뒤에 `/device/`를 붙이면 같은 게임에 **기기 측정** 버튼이 나타난다.

1. 휴대폰을 가로로 놓고 게임 상단에서 그래픽 품질을 고른다. **기기 측정**에서 실행 환경과 기기 모델을 직접 표시한다.
2. 중앙 수로 서안, 아고라, 드림센터, 학생회관 또는 현재 위치를 정한다. 30초는 짧은 비교, 2분은 왕복, 10분은 지속 성능 기록에 쓸 수 있다.
3. **측정 시작**을 누르고 실제 조이스틱과 시점 드래그로 이동한다. 자동 품질을 평가할 때는 시작과 마지막의 기기 온도·배터리 상태를 별도로 관찰한다.
4. 지정한 시간이 지나거나 **측정 종료**를 누르면 **JSON 저장**이 활성화된다. JSON은 휴대폰에 내려받는다. 실제 기기 여부는 작성자의 기입값이다. 배경 탭 시간은 표본에서 분리한다.

PC에서 게임 장면을 클릭하면 WASD와 마우스로 조작한다. Esc로 마우스 잠금을 해제한다. 휴대폰 가로 화면에서는 왼쪽에서 이동하고 오른쪽에서 시점을 돌린다.

일반 게임은 각 브라우저에 퀘스트를 로컬 저장한다. QA 시작 위치 이동도 같은 브라우저의 게스트 방문 진행에 반영될 수 있다. 별도 브라우저 프로필을 쓰면 개인 플레이 기록과 독립적으로 측정할 수 있다.

현장 대조 자료가 포함된 ZIP은 `field/`에서 촬영표와 PDF를 열 수 있다. 촬영표에 인쇄된 좌표·방향은 게임 카메라의 대조 후보이며, 현장의 실제 관측값은 빈 칸에 별도로 기록한다.
"""


def put(archive, name, data):
    item = ZipInfo(name, (2026, 11, 23, 0, 0, 0))
    item.compress_type = ZIP_DEFLATED
    item.external_attr = 0o100644 << 16
    archive.writestr(item, data, compresslevel=9)


def main():
    ap = ArgumentParser(description=__doc__)
    ap.add_argument("dist", type=Path)
    ap.add_argument("zip", type=Path)
    ap.add_argument("--source", required=True, help="Git SHA of the game source being packaged")
    ap.add_argument("--field", type=Path, help="Include the survey handoff directory")
    ap.add_argument("--qa", action="store_true", help="Include this change’s raw evidence, PNGs and QA report")
    a = ap.parse_args()
    files = {p.relative_to(a.dist).as_posix(): p.read_bytes() for p in a.dist.rglob("*") if p.is_file()}
    manifest = {k: sha256(v).hexdigest() for k, v in sorted(files.items())}
    build = {"source": a.source, "releaseFileSHA256": manifest}
    local = HERE / "device"
    index = files["index.html"].decode()
    entry = '<script type="module" src="./src/main.js"></script>'
    assert index.count(entry) == 1 and index.count("<head>") == 1
    index = index.replace("<head>", '<head>\n<base href="../"><link rel="stylesheet" href="device/panel.css">\n'
                          '<script src="device/buffers.js"></script>')
    index = index.replace(entry, (local / "panel.html").read_text() +
                          '\n<script type="module" src="./src/device-qa-main.js"></script>')
    with ZipFile(HERE.parent / "p1d/INHA-WORLD-play.zip") as parent, ZipFile(a.zip, "w") as z:
        put(z, "start.py", parent.read("start.py"))
        put(z, "PLAY-KO.md", GUIDE)
        put(z, "SOURCE.txt", f"INHA WORLD\n{a.source}\nOSM © OpenStreetMap contributors · ODbL\n")
        for name, data in sorted(files.items()):
            put(z, "play/" + name, data)
        put(z, "play/device/index.html", index)
        put(z, "play/device/build.json", json.dumps(build))
        put(z, "play/device/stations.json", (HERE / "stations.json").read_bytes())
        put(z, "play/src/device-qa-main.js", files["src/main.js"] + b"\n" + (local / "attach.js").read_bytes())
        for name in ["buffers.js", "recorder.js", "panel.css"]:
            put(z, "play/device/" + name, (local / name).read_bytes())
        if a.field:
            for p in sorted(a.field.rglob("*")):
                if p.is_file():
                    put(z, "field/" + p.relative_to(a.field).as_posix(), p.read_bytes())
        if a.qa:
            for name in ["README.md", "QA-KO.pdf", "performance.csv"]:
                data = (HERE / name).read_bytes()
                if name == "README.md":
                    data = data.replace(b"(field/", b"(../field/").replace(b"(INHA-WORLD-field-kit.zip)", b"(../PLAY-KO.md)")
                put(z, "qa/" + name, data)
            for part in ["screens", "raw"]:
                for p in sorted((HERE / part).rglob("*")):
                    if p.is_file() and p.name != "zip-play.json":
                        put(z, "qa/" + p.relative_to(HERE).as_posix(), p.read_bytes())
    with ZipFile(a.zip) as z:
        assert z.testzip() is None
        assert all(sha256(z.read("play/" + k)).hexdigest() == v for k, v in manifest.items())
    print(a.zip.name, a.zip.stat().st_size, sha256(a.zip.read_bytes()).hexdigest())


if __name__ == "__main__":
    main()
