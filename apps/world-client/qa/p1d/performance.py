"""Pool equal-length blocks; keep RAF cadence distinct from synchronized render/readback time."""
from pathlib import Path
import csv
import json
import math
from statistics import mean, median

OUT=Path(__file__).resolve().parent

def p95(samples):return sorted(samples)[math.ceil(.95*len(samples))-1]
def summarize(rows):
    frames=[v for r in rows for v in r['frameMs']]
    draws=[v for r in rows for v in r['renderReadbackMs']]
    states=[r['state'] for r in rows]
    def unique(f):return '|'.join(map(str,sorted(set(f(s) for s in states))))
    return dict(blocks=len(rows),frames=len(frames),syncDraws=len(draws),
        modes='|'.join(sorted({t for r in rows for t in r['tiers']})),
        resolution=unique(lambda s:'x'.join(map(str,s['buffer']))),aa=unique(lambda s:s['graphics']['aa']),
        rafFPS=round(1000/mean(frames),2),frameMedianMs=round(median(frames),2),frameP95Ms=round(p95(frames),2),
        syncMedianMs=round(median(draws),2),syncP95Ms=round(p95(draws),2),calls=unique(lambda s:s['calls']),
        triangles=unique(lambda s:s['triangles']),webglBufferBytes=unique(lambda s:s['glBuffers']['bytes']),
        renderbufferBytes=unique(lambda s:s['graphics']['renderbuffers']['logicalBytes']))
def main():
    out=[]
    for build in ['before','after']:
        for mode in ['paired','tiers']:
            report=json.loads((OUT/'raw'/f'{build}-{mode}.json').read_text())
            rows=report['samples']
            for size in sorted({tuple(r.get('size',[1280,720])) for r in rows},reverse=True):
                for p in ['auto','very_low','low','medium','high','ultra']:
                    subset=[r for r in rows if r['preset']==p and tuple(r.get('size',[1280,720]))==size]
                    if not subset: continue
                    if mode=='paired':
                        assert all(r['sameContext'] and set(r['tiers'])=={'high'} for r in subset)
                    out.append(dict(build=build,mode=mode,viewport='x'.join(map(str,size)),preset=p,**summarize(subset)))
    with (OUT/'performance.csv').open('w') as f:
        writer=csv.DictWriter(f,fieldnames=out[0],lineterminator="\n");writer.writeheader();writer.writerows(out)
    sites=[]
    for build in ['before','after']:
        runs=json.loads((OUT/'raw'/f'{build}-sites.json').read_text())['samples']
        assert len(runs)==24
        for r in runs:
            sites.append(dict(build=build,view=r['view'],viewport='x'.join(map(str,r['size'])),
                              preset=r['preset'],skylineVisible=(r['skyline'] or {}).get('visible'),**summarize([r])))
    with (OUT/'site-performance.csv').open('w') as f:
        writer=csv.DictWriter(f,fieldnames=sites[0],lineterminator="\n");writer.writeheader();writer.writerows(sites)
if __name__=='__main__':main()
