"""Reproduce the full-footprint hypothesis on PR #12, with QA-only overlays at real game cameras."""
from argparse import ArgumentParser
from contextlib import ExitStack
import json
from math import pi
import os
from pathlib import Path
from PIL import Image
from playwright.sync_api import sync_playwright
from measure import qa

OVERLAY = """
globalThis.markConflict = ({ring,body}) => {
  const group=new THREE.Group();
  function outline(points,bottom,top,color) {
    const lines=[];
    for(let i=0;i<points.length;i++) {
      const [x,z]=points[i],[u,v]=points[(i+1)%points.length];
      lines.push(x,bottom,z,u,bottom,v, x,top,z,u,top,v, x,bottom,z,x,top,z);
    }
    const geo=new THREE.BufferGeometry();
    geo.setAttribute('position',new THREE.Float32BufferAttribute(lines,3));
    const m=new THREE.LineSegments(geo,new THREE.LineBasicMaterial({color,depthTest:false}));
    m.renderOrder=10; group.add(m);
  }
  const faces=[];
  for(let i=0;i<ring.length;i++) {
    const [x,z]=ring[i],[u,v]=ring[(i+1)%ring.length];
    faces.push(x,0,z,u,0,v,u,14,v,x,0,z,u,14,v,x,14,z);
  }
  const geo=new THREE.BufferGeometry();
  geo.setAttribute('position',new THREE.Float32BufferAttribute(faces,3));
  group.add(new THREE.Mesh(geo,new THREE.MeshBasicMaterial({color:0xf08b60,transparent:true,opacity:0.18,
    side:THREE.DoubleSide,depthWrite:false})));
  outline(ring,0.035,14,0xff773f);
  outline(body.polygon.map(p=>[p.x,p.z]),0.045,body.maxY,0xffdf45);
  const crown=scene.getObjectByName('crowns'),m=new THREE.Matrix4();
  crown.getMatrixAt(58,m);
  const tree=new THREE.LineSegments(new THREE.WireframeGeometry(crown.geometry),
    new THREE.LineBasicMaterial({color:0x63efcd,transparent:true,opacity:0.7,depthTest:false}));
  tree.matrixAutoUpdate=false;tree.matrix.copy(m);tree.renderOrder=9;group.add(tree);
  scene.add(group);globalThis.conflictMarkers=group;
};
globalThis.showConflict = show => {conflictMarkers.visible=show;renderer.render(scene,camera);};
"""
if __name__=='__main__':
    ap=ArgumentParser(description=__doc__)
    for name in ['before','out','scratch']:ap.add_argument(name,type=Path)
    a=ap.parse_args();qa.PROBE+='\n'+OVERLAY
    fit=json.loads((a.out/'raw/interference.json').read_text())
    args=dict(ring=fit['footprint'],body=fit['trees']['58']['solid'])
    poses={'contact-ground':(133,-13,128.6682,-17.4066),'contact-plan':(128.4,-20.5,128.4,-17,26,-pi/2)}
    records={}
    with ExitStack() as stack,sync_playwright() as pw:
        origin=qa.serve(stack,a.before)
        browser=pw.chromium.launch(executable_path=os.getenv('CHROMIUM','/usr/bin/chromium'),
                                   args=['--use-angle=swiftshader','--enable-unsafe-swiftshader'])
        for size in qa.SIZES:
            tag='%dx%d'%size
            ctx,p,errors,_=qa.visit(browser,origin,a.before,size,'high')
            p.evaluate('v=>markConflict(v)',args)
            for name,pose in poses.items():
                state=p.evaluate('v=>captureMapView(v)',pose)
                records[tag+'/'+name]={k:state[k] for k in ['position','yaw','pitch','fov','buffer','pixelRatio']}
                imgs=[]
                for shown in [False,True]:
                    p.evaluate('v=>showConflict(v)',shown)
                    path=a.scratch/(tag+'-'+name+'-'+str(int(shown))+'.png')
                    p.locator('#scene').screenshot(path=path)
                    imgs.append(Image.open(path).convert('RGB'))
                qa.save_pair(imgs,['PR #12 | actual scene','QA hypothesis | OSM walls: orange / crown: teal / solid: yellow'],
                             a.out/'screens'/tag/(name+'.png'))
            assert not errors
            ctx.close()
        qa.dump(a.out/'raw/diagnostic-cameras.json',records)
        browser.close()
