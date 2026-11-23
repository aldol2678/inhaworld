"""Compare the live OSM full ways with the ledger, the baked lake and its two access ways."""

import json
import math
from pathlib import Path
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[3]
REALITY = ROOT / 'map-sources/data/reality'


def read(path):
    return json.loads(path.read_text())


def world(ll):
    lat, lon = ll
    return ((lon - 126.65319) * (111320 * math.cos(math.radians(37.44770))) / 2,
            -90 + (lat - 37.44770) * 111195 / 2)


def main():
    landmarks = {f['id']: f for f in read(REALITY / 'campus-landmarks.json')['landmarks']}
    facilities = {f['id']: f for f in read(REALITY / 'campus-facilities.json')['features']}
    layout = read(ROOT / 'data/layout.json')
    lake = next(o['polygon'] for o in layout['obstacles'] if o['id'] == 'lmk_inkyung_pond')
    sources = [
        (218264623, 7, landmarks['lmk_inkyung_pond']['polygon'], lake),
        (1099894035, 1, landmarks['lmk_agora_plaza']['polygon'], None),
        (218038027, 6, facilities['bldg_07']['rings'][0], None),
        (219983082, 8, facilities['bldg_02_south']['rings'][0], None),
    ]
    roads = read(REALITY / 'evidence/roads/agora-inkyung.json')['ways']
    road_nodes = {r['id']: r['nodes'] for r in roads}
    for r in roads:
        line = next(v['line'] for v in layout['routes'] if v['id'] == f"site_{r['id']}")
        sources.append((r['id'], r['version'], [p[1:] for p in r['nodes']], line))
    result = []
    for way_id, version, expected, baked in sources:
        url = f'https://api.openstreetmap.org/api/0.6/way/{way_id}/full.json'
        with urlopen(Request(url, headers={'User-Agent': 'INHA-WORLD map QA'}), timeout=20) as response:
            elements = json.load(response)['elements']
        way = next(e for e in elements if e['type'] == 'way' and e['id'] == way_id)
        nodes = {e['id']: e for e in elements if e['type'] == 'node'}
        assert way['version'] == version, (way_id, 'upstream revision changed', way['version'])
        ids = way['nodes']
        if way_id in road_nodes:
            ids = ids[:len(expected)]  # existing client covers the first 3 nodes of the service way
            assert ids == [p[0] for p in road_nodes[way_id]]
        points = [[nodes[i]['lat'], nodes[i]['lon']] for i in ids]
        assert points == expected, way_id
        row = dict(way=way_id, version=version, uniqueNodes=len(set(ids)), source=url,
                   comparedNodeIds=ids, identicalWGS84=True)
        if baked is not None:
            distinct = points[:-1] if ids[0] == ids[-1] else points
            deltas = [math.dist(world(p), (q['x'], q['z'])) for p, q in zip(distinct, baked, strict=True)]
            row['bakedMaxDeltaWU'] = max(deltas)
            assert max(deltas) < 1e-8
            if way_id == 218264623:
                row['shoreEdges'] = [dict(edge=i + 1, fromNode=ids[i], toNode=ids[i + 1],
                                         startLatLon=p, startXZ=world(p), deltaWU=deltas[i])
                                     for i, p in enumerate(distinct)]
        if way_id == 218038027:
            node = nodes[9767122969]
            assert node['tags'].get('entrance') and node['id'] == road_nodes[1063267429][-1][0]
            row['sharedEntrance'] = {'node': node['id'], 'ref': node['tags']['ref']}
        result.append(row)
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
