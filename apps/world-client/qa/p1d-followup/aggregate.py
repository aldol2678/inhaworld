"""Use the same P1D calculations on the repeated render/cadence samples from this follow-up."""
import csv
import importlib.util
import json
from pathlib import Path

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('p1d_performance',HERE.parent/'p1d/performance.py')
performance=importlib.util.module_from_spec(spec)
spec.loader.exec_module(performance)


def main():
    rows=[]
    for phase in ('before','after'):
        for series in ('canal','tiers'):
            runs=json.loads((HERE/'raw'/f'{series}-{phase}.json').read_text())['samples']
            for size in sorted({tuple(s.get('size',[1280,720])) for s in runs},reverse=True):
                for preset in ('auto','very_low','low','medium','high','ultra'):
                    block=[s for s in runs if tuple(s.get('size',[1280,720]))==size and s['preset']==preset]
                    if not block:
                        continue
                    if series=='canal':
                        assert len(block)==4 and all(s['sameContext'] and set(s['tiers'])=={'high'} for s in block)
                    elif series=='tiers':
                        assert len(block)==2
                    rows.append(dict(build=phase,series=series,viewport='%dx%d'%size,preset=preset,
                                     **performance.summarize(block)))
    with (HERE/'performance.csv').open('w',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=rows[0],lineterminator='\n')
        writer.writeheader()
        writer.writerows(rows)


if __name__=='__main__':
    main()
