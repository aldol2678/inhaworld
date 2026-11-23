"""Read current OSM ways and their ordered nodes; this script only writes a QA receipt."""
from pathlib import Path
import json
from urllib.request import Request, urlopen

root = Path(__file__).resolve().parents[2] / 'map-sources/data/reality'
def record(file, key):
    return json.loads((root/('campus-'+file+'.json')).read_text())[key]

sites = {e['id']:e for e in record('site','features')}
facility = next(e for e in record('facilities','features') if e['id']=='bldg_dream1')
sources = [(facility['id'],facility['sourceWays'][0],facility['rings'][0])]
for e in record('landmarks','landmarks'):
    way = {'lmk_agora_plaza':1099894035,'lmk_inkyung_pond':218264623}.get(e['id'])
    if way:
        sources.append((e['id'],way,e['polygon']))
for way in [481241696,218220690,481241657,258995842]:
    e = sites['site_'+str(way)]
    sources.append((e['id'],way,e.get('line',e.get('polygon'))))
rows = []
for name,way,expected in sources:
    request = Request(f'https://api.openstreetmap.org/api/0.6/way/{way}/full.json',
                      headers={'User-Agent':'INHA WORLD spatial QA'})
    with urlopen(request,timeout=30) as response:
        elements = json.load(response)['elements']
    item = next(e for e in elements if e['type']=='way' and e['id']==way)
    nodes = {e['id']:[e['lat'],e['lon']] for e in elements if e['type']=='node'}
    coordinates = [nodes[n] for n in item['nodes']]
    rows.append(dict(id=name,way=way,url=request.full_url,version=item['version'],nodeIds=item['nodes'],
                     currentWGS84=coordinates,ledgerWGS84=expected,identical=coordinates==expected))
print(json.dumps(rows,ensure_ascii=False,indent=2))
assert all(r['identical'] for r in rows)
