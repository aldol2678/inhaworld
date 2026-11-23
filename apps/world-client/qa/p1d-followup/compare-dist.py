"""Compare two real build outputs and verify that the geometry addition is contiguous."""
from argparse import ArgumentParser
from hashlib import sha256
import json
from pathlib import Path


def main():
    p=ArgumentParser(description=__doc__)
    p.add_argument('before',type=Path)
    p.add_argument('after',type=Path)
    p.add_argument('out',type=Path)
    a=p.parse_args()
    files={}
    for name,directory in [('before',a.before),('after',a.after)]:
        files[name]={f.relative_to(directory).as_posix():sha256(f.read_bytes()).hexdigest()
                     for f in directory.rglob('*') if f.is_file()}
    assert files['before'].keys()==files['after'].keys()
    changed={k:{n:files[n][k] for n in files} for k in files['before'] if files['before'][k]!=files['after'][k]}
    assert set(changed)=={'data/layout.json','data/layout.bin'},changed
    before,after=[json.loads((p/'data/layout.json').read_text()) for p in [a.before,a.after]]
    assert before.keys()==after.keys()
    assert [k for k in before if before[k]!=after[k]]==['ranges']
    old,new=[(p/'data/layout.bin').read_bytes() for p in [a.before,a.after]]
    extra=len(new)-len(old)
    assert extra==42*16
    vc=before['ranges']['base']['count']
    first=next(i for i in range(vc) if old[16*i:16*i+16]!=new[16*i:16*i+16])
    index=16*first
    assert old[:index]+new[index:index+extra]+old[index:]==new
    assert first>=before['p1aLod']['sharedVertices']+before['p1aLod']['farVertices']
    for key,vertices in before['ranges'].items():
        if key=='base':
            assert after['ranges'][key]['count']==vertices['count']+42
        else:
            assert after['ranges'][key]==dict(count=vertices['count'],offset=vertices['offset']+extra)
    out=dict(buildFiles=len(files['before']),changedFiles=changed,allOriginalVerticesByteIdentical=True,
             insertion=dict(range='base near',vertex=first,vertices=42,triangles=14,bytes=extra),
             unchangedLayoutKeys=[k for k in before if k!='ranges'],
             unchangedCounts={k:len(before[k]) for k in ('trees','routes','obstacles','stairs','cells','rooms','depressions')})
    a.out.write_text(json.dumps(out,indent=2)+'\n')


if __name__=='__main__':
    main()
