"""Register equal cameras, capture native game pixels and inspect real instanced geometry."""
from argparse import ArgumentParser
from contextlib import ExitStack
from math import pi,hypot
from pathlib import Path
import hashlib
import json
import os

from PIL import Image,ImageChops
from playwright.sync_api import sync_playwright
from measure import qa, ROOT

CAMERAS = {
    'dream-east': (160.17,-53,128,-26),
    'dream-street': (143,-64,128,-26),
    'dream-tree': (121.8,-10.4,128.7,-19.5),
    'dream-oblique': (155,-66,128,-26,38,-0.59),
    'dream-plan': (128,-26,128,-20,35,-pi/2),
    'sightline': (101.57,21.89,128,-26),
    'agora-approach': (121.8,-10.4,131,-2,2.2,-0.20),
    'agora-overhead': (128,-3,128,2,22,-pi/2),
    'agora-paving-far': (128,-3,128,2,22,-pi/2),
    'canal': qa.CAMERAS['canal-west'],
}
PHASES=['before','after']


def main():
    ap=ArgumentParser(description=__doc__)
    for name in ['before','after','out','scratch']:
        ap.add_argument(name,type=Path)
    a=ap.parse_args()
    layout=json.loads((a.after/'data/layout.json').read_text())
    center=layout['dreamSkyline']
    indices=[i for i,t in enumerate(layout['trees']) if hypot(t['x']-center['x'],t['z']-center['z'])<24]
    t=layout['trees'][56]
    eye=[t['x']+3*(t['x']-center['x']),2.2,t['z']+3*(t['z']-center['z'])]
    CAMERAS['sightline']=(eye[0],eye[2],center['x'],center['z'])
    qa.PROBE+='\n'+Path(__file__).with_name('scene-probe.js').read_text()
    report={}; extraction={}
    with ExitStack() as stack,sync_playwright() as pw:
        br=pw.chromium.launch(executable_path=os.getenv('CHROMIUM','/usr/bin/chromium'),
                              args=['--use-angle=swiftshader','--enable-unsafe-swiftshader'])
        origins={name:qa.serve(stack,getattr(a,name)) for name in PHASES}
        for size in qa.SIZES:
            tag='%dx%d'%size
            report[tag]={}
            for phase in PHASES:
                ctx,p,errors,_=qa.visit(br,origins[phase],getattr(a,phase),size,'high')
                folder=a.scratch/tag/phase
                folder.mkdir(parents=True,exist_ok=True)
                for name,pose in CAMERAS.items():
                    state=p.evaluate('p=>captureMapView(p)',pose)
                    state['baseDrawRange']=p.evaluate('far=>previewAgoraLod(far)',name=='agora-paving-far')
                    state['graphics']=p.evaluate('gfxState()')
                    f=folder/(name+'.png')
                    p.locator('#scene').screenshot(path=f)
                    state['pngSha256']=hashlib.sha256(f.read_bytes()).hexdigest()
                    report[tag].setdefault(name,{})[phase]=state
                if size==qa.SIZES[0]:
                    extraction[phase]={}
                    for tier in ['very_low','high','ultra']:
                        p.locator('#graphics-quality').select_option(tier)
                        p.evaluate('p=>captureMapView(p)',CAMERAS['sightline'])
                        extraction[phase][tier]=p.evaluate('v=>dreamStudy(v)',dict(indices=indices,eye=eye,
                                                       target=[center['x'],4,center['z']]))
                assert not errors,errors
                ctx.close()
            dst=a.out/'screens'/tag
            dst.mkdir(parents=True,exist_ok=True)
            for name,rows in report[tag].items():
                before,after=rows['before'],rows['after']
                for key in ['position','pitch','yaw','fov','buffer','pixelRatio']:
                    assert before[key]==after[key],(name,key)
                imgs=[Image.open(a.scratch/tag/phase/(name+'.png')).convert('RGB') for phase in PHASES]
                diff=ImageChops.difference(*imgs)
                hist=diff.convert('L').histogram()
                rows['changedLumaPixels']=sum(hist[1:])
                qa.save_pair(imgs,['Before | PR #12','After | P1D'],dst/(name+'.png'))
                assert all(not r['contextLost'] and r['graphics']['error']==0 for r in [before,after])
        qa.dump(a.out/'raw/cameras.json',report)
        qa.dump(a.out/'raw/tree-meshes.json',extraction)
        br.close()

if __name__=='__main__':
    main()
