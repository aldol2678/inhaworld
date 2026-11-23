"""Aggregate the two counterbalanced runs in raw/performance.json. Python standard library."""
import csv
import json
from math import ceil
from pathlib import Path
from statistics import mean, median

ROOT = Path(__file__).resolve().parent
TIERS = ['legacy', 'auto', 'very_low', 'low', 'medium', 'high', 'ultra']


def p95(values):
    return sorted(values)[ceil(.95*len(values))-1]


def main():
    runs = json.loads((ROOT/'raw/performance.json').read_text())['samples']
    rows = []
    for size in [[1280,720],[891,411]]:
        for tier in TIERS:
            cases = [r for r in runs if r['size']==size and r['tier']==tier]
            assert len(cases)==2
            intervals = [v for r in cases for v in r['canalCadence']['intervalsMs']]
            assert len(intervals)==80
            for name in ['canal-west','pond']:
                views = [r['views'][name] for r in cases]
                times = [v for state in views for v in state['renderReadbackMs']]
                assert len(times)==60
                b=views[0]
                assert all(v['buffer']==b['buffer'] and v['triangles']==b['triangles'] and
                           v['calls']==b['calls'] and not v['contextLost'] for v in views)
                rows.append(dict(viewport='%dx%d'%tuple(size),preference=tier,effective=b['graphics']['tier'],
                                 view=name,buffer='%dx%d'%tuple(b['buffer']),aa=b['graphics']['aa'],
                                 calls=b['calls'],triangles=b['triangles'],
                                 liveGLBufferBytes=max(v['glBuffers']['bytes'] for v in views),
                                 jsHeapAfterGcBytesMax=max(r['heap']['usedSize'] for r in cases),
                                 renderMedianMs=round(median(times),2),renderP95Ms=round(p95(times),2),
                                 canalRafFps=round(1000/mean(intervals),2),
                                 canalRafP95Ms=round(p95(intervals),2)))
    with (ROOT/'performance.csv').open('w',newline='') as output:
        table=csv.DictWriter(output,fieldnames=list(rows[0]),lineterminator='\n')
        table.writeheader()
        table.writerows(rows)


if __name__=='__main__':
    main()
