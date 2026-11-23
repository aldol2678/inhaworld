"""Check the present entrance tags, parent ways and nearby mapped survey features."""
from datetime import datetime, timezone
import json
from pathlib import Path
from urllib.request import Request, urlopen
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "map-sources/data/reality"
BASE = "https://api.openstreetmap.org/api/0.6/"
BBOX = "126.65555,37.44850,126.65665,37.44957"


def fetch(endpoint):
    request = Request(BASE + endpoint, headers={"User-Agent": "INHA WORLD public map QA"})
    with urlopen(request, timeout=25) as response:
        return response.read()


def main():
    entry = json.loads((DATA / "evidence/student-center-entrance.json").read_text())
    receipt = {"checkedUTC": datetime.now(timezone.utc).date().isoformat(), "entrances": {}, "footprints": {}}
    for node in [9767122969, entry["node"]]:
        node_url = f"node/{node}.json"
        parent_url = f"node/{node}/ways.json"
        live = json.loads(fetch(node_url))["elements"][0]
        parents = json.loads(fetch(parent_url))["elements"]
        receipt["entrances"][str(node)] = {
            "latitude": live["lat"], "longitude": live["lon"], "version": live["version"],
            "tags": live["tags"], "ways": [p["id"] for p in parents],
            "sources": [BASE + node_url, BASE + parent_url],
        }
        if node == entry["node"]:
            assert (live["lat"], live["lon"], live["tags"], live["version"]) == (
                entry["lat"], entry["lon"], entry["tags"], entry["version"])
            assert [p["id"] for p in parents] == [entry["sourceWay"]]
    facilities = json.loads((DATA / "campus-facilities.json").read_text())["features"]
    landmarks = json.loads((DATA / "campus-landmarks.json").read_text())["landmarks"]
    for osm, fid, expected in [
        (218038027, "bldg_07", next(f["rings"][0] for f in facilities if f["id"] == "bldg_07")),
        (568420970, "bldg_dream1", next(f["rings"][0] for f in facilities if f["id"] == "bldg_dream1")),
        (1099894035, "lmk_agora_plaza", next(f["polygon"] for f in landmarks if f["id"] == "lmk_agora_plaza")),
    ]:
        endpoint = f"way/{osm}/full.json"
        elements = json.loads(fetch(endpoint))["elements"]
        way = next(e for e in elements if e["type"] == "way")
        nodes = {e["id"]: e for e in elements if e["type"] == "node"}
        coords = [[nodes[i]["lat"], nodes[i]["lon"]] for i in way["nodes"]]
        assert coords == expected
        receipt["footprints"][fid] = {
            "way": osm, "version": way["version"], "nodes": way["nodes"],
            "orderedWGS84": coords, "matchesLedger": True, "tags": way["tags"], "source": BASE + endpoint,
        }
    root = ElementTree.fromstring(fetch("map?bbox=" + BBOX))
    features = []
    for el in root:
        tags = {t.get("k"): t.get("v") for t in el.findall("tag")}
        if (tags.get("natural") == "tree" or tags.get("amenity") == "bench"
                or tags.get("highway") in ["street_lamp", "steps"] or "ramp" in tags):
            features.append({"type": el.tag, "id": el.get("id"), "tags": tags})
    receipt["neighborhood"] = {"bbox": BBOX, "source": BASE + "map?bbox=" + BBOX, "mappedSurveyFeatures": features}
    print(json.dumps(receipt, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
