"""Compare the actual ordered WGS84 nodes with the current free OSM way endpoints."""
import json
from pathlib import Path
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT/'map-sources/data/reality'


def read(name):
    return json.loads((DATA/name).read_text())


def main():
    sites=read('campus-site.json')['features']
    sources=[(f['id'],int(f['id'].split('_')[1]),f.get('polygon',f.get('line')))
             for f in sites if f['kind'] in ['reflecting_pool','lawn']
             or f['id'] in ['site_481241657','site_258995842','site_481241696']]
    for f in read('campus-facilities.json')['features']:
        if f['id'] in ['bldg_lawschool','bldg_06','bldg_hawaii','bldg_07','bldg_02_south']:
            sources.append((f['id'],f['sourceWays'][0],f['rings'][0]))
    for f in read('campus-landmarks.json')['landmarks']:
        way={'lmk_agora_plaza':1099894035,'lmk_inkyung_pond':218264623}.get(f['id'])
        if way:
            sources.append((f['id'],way,f['polygon']))
    results=[]
    for name,way,expected in sources:
        url=f'https://api.openstreetmap.org/api/0.6/way/{way}/full.json'
        request=Request(url,headers={'User-Agent':'INHA-WORLD local campus map QA'})
        with urlopen(request,timeout=25) as response:
            elements=json.load(response)['elements']
        row=next(e for e in elements if e['type']=='way' and e['id']==way)
        nodes={e['id']:[e['lat'],e['lon']] for e in elements if e['type']=='node'}
        points=[nodes[k] for k in row['nodes']]
        results.append(dict(id=name,way=way,version=row['version'],uniqueNodes=len(set(row['nodes'])),
                            ledgerNodes=len(expected),identicalOrderedWGS84=points==expected,url=url))
    print(json.dumps(results,indent=2))
    if not all(r['identicalOrderedWGS84'] for r in results):
        raise SystemExit('Inspect current/source differences. No client coordinates were written.')


if __name__=='__main__':
    main()
