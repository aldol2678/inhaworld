"""Intersect the actual captured tree hulls with the ledger, collision shapes and shipped triangles."""
import argparse
import json
import math
from pathlib import Path
import struct

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
from scipy.spatial import ConvexHull

ROOT=Path(__file__).resolve().parents[2]

def area(ring):
    return abs(sum(p[0]*q[1]-q[0]*p[1] for p,q in zip(ring,ring[1:]+ring[:1]))/2)

def clipped(poly,normal,offset):
    out=[]
    for a,b in zip(poly,poly[1:]+poly[:1]):
        da,db=np.dot(a,normal)+offset,np.dot(b,normal)+offset
        if da<=1e-8: out.append(a)
        if (da<=1e-8)!=(db<=1e-8):
            out.append(a+(b-a)*da/(da-db))
    return out

def intersect(points,planes):
    poly=list(points)
    for plane in planes:
        if not poly: break
        poly=clipped(poly,plane[:-1],plane[-1])
    return poly

def dist_segment(p,a,b):
    line=b-a
    return float(np.linalg.norm(p-(a+line*np.clip(np.dot(p-a,line)/np.dot(line,line),0,1))))

def clearance(poly,ring):
    return min(dist_segment(p,a,b) for aa,bb in [(poly,ring),(ring,poly)] for p in aa
               for a,b in zip(bb,bb[1:]+bb[:1]))

def xy(row):
    return np.array([row['x'],row['z']])

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for key in ['before','after','out']: ap.add_argument(key,type=Path)
    a=ap.parse_args()
    layouts=[json.loads((dist/'data/layout.json').read_text()) for dist in [a.before,a.after]]
    layout=layouts[1]
    keys=['obstacles','trees','routes','stairs','cells','depressions','rooms','spawn','bounds']
    assert all(layout[k]==layouts[0][k] for k in keys)
    osm=json.loads((a.out/'raw/osm.json').read_text())
    geo=next(r for r in osm if r['id']=='bldg_dream1')['currentWGS84'][:-1]
    ring=[np.array([(lon-126.65319)*111320*math.cos(math.radians(37.44770))/2,
                    -90+(lat-37.44770)*111195/2]) for lat,lon in geo]
    planes=ConvexHull(ring).equations
    groups=json.loads((a.out/'raw/tree-meshes.json').read_text())
    data=(a.after/'data/layout.bin').read_bytes()
    r=layout['ranges']['dream']
    mesh=np.array([struct.unpack_from('<fff',data,r['offset']+i*16) for i in range(r['count'])]).reshape((-1,3,3))
    report={'units':'projected game WU, WU²; not field measurements','footprint':[p.tolist() for p in ring],
            'ringArea':area(ring),'unchanged':{k:len(layout[k]) for k in keys},'trees':{},'route':{},'views':{}}
    checked=set()
    for tier,entry in groups['after'].items():
        assert groups['before'][tier]['meshes']==entry['meshes']
        report['views'][tier]=entry['sightline']
        for key,parts in entry['meshes'].items():
            index=int(key); checked.add(index)
            tree=layout['trees'][index]; center=xy(tree)
            distances=[dist_segment(center,p,q) for p,q in zip(ring,ring[1:]+ring[:1])]
            signed=min(distances)*(-1 if max(planes[:,:2]@center+planes[:,2])<=0 else 1)
            solid=next(o for o in layout['obstacles'] if o['id']=='tree-'+key)
            octagon=[xy(p) for p in solid['polygon']]
            row=report['trees'].setdefault(key,dict(center=center.tolist(),signedEdgeDistance=signed,
                closestEdge=int(np.argmin(distances)),solid=solid,
                solidOverlapWithFullFootprint=area(intersect(octagon,planes)),tiers={}))
            measures=row['tiers'][tier]={}
            for name,part in parts.items():
                v=np.array(part['vertices'])
                flat=v[:,[0,2]]
                hull=[flat[i] for i in ConvexHull(flat).vertices]
                overlap=area(intersect(hull,planes))
                bounds=np.min(v,axis=0),np.max(v,axis=0)
                candidates=mesh[(mesh.max(axis=1)>=bounds[0]-1e-7).all(axis=1)&
                                (mesh.min(axis=1)<=bounds[1]+1e-7).all(axis=1)]
                faces=ConvexHull(v).equations
                touches=sum(bool(intersect(tri,faces)) for tri in candidates)
                measures[name]=dict(visualOrigin=part['origin'],ySpan=[float(bounds[0][1]),float(bounds[1][1])],
                    hull=[p.tolist() for p in hull],planOverlapWithFullFootprint=overlap,
                    planClearance=0 if overlap>0 else clearance(hull,ring),shippedTrianglesIntersecting=touches)
                assert touches==0,(tier,key,name,touches)
    route=next(r for r in layout['routes'] if r['id']=='site_481241696')
    line=[xy(p) for p in route['line']]
    roadGap=min(
        [dist_segment(p,x,y) for p in ring for x,y in zip(line,line[1:])] +
        [dist_segment(p,x,y) for p in line for x,y in zip(ring,ring[1:]+ring[:1])])
    t=xy(layout['trees'][58])
    report['route']=dict(source=route['sourceId'],centerline=[p.tolist() for p in line],
        nominalGameWidth=route['width'],centerlineToOutline=roadGap,
        centerlineToTree58=min(dist_segment(t,x,y) for x,y in zip(line,line[1:])),nominalHalfWidth=route['width']/2)
    report['checkedIndices']=sorted(checked)
    report['closestExcludedTreeToOutline']=min(dist_segment(xy(tree),p,q) for i,tree in enumerate(layout['trees'])
            if i not in checked for p,q in zip(ring,ring[1:]+ring[:1]))
    assert abs(report['trees']['58']['solidOverlapWithFullFootprint']-.32696618)<1e-6
    assert any(h.get('instance')==56 and h['mesh']=='crowns' for h in report['views']['high']['hits'])
    (a.out/'raw/interference.json').write_text(json.dumps(report,indent=2)+'\n')
    # Diagram of game coordinates, with traceable collider vs visual crown footprints.
    fig,(ax,zoom)=plt.subplots(1,2,figsize=(10.5,5.2),layout='constrained')
    for panel in [ax,zoom]:
        panel.set_aspect('equal');panel.set_xlabel('East  /  game X (WU)');panel.set_ylabel('North  /  game Z (WU)')
        panel.grid(True,alpha=.18)
        panel.fill(*zip(*ring),facecolor='#d9dad5',edgecolor='#394957',label='OSM 568420970')
        for i in [0,1]:
            p,q=ring[i:i+2];panel.plot([p[0],q[0]],[p[1],q[1]],lw=3,color='#576b7d')
        panel.plot(*zip(*line),color='#a78552',ls='--',label='481241696 centerline')
        for k,row in report['trees'].items():
            pts=row['tiers']['ultra']['crowns']['hull']
            panel.fill(*zip(*pts),facecolor='#5b9c68',alpha=.35,edgecolor='#237344')
            panel.fill(*zip(*[xy(p) for p in row['solid']['polygon']]),color='#623f30')
            p=row['center'];panel.annotate(k,p,xytext=(4,4),textcoords='offset points',fontsize=9)
    ax.set(xlim=(113,140),ylim=(-38,-4),title='Mapped envelope and existing avenue')
    zoom.set(xlim=(125,132),ylim=(-21,-14),title='Tree 58 / primary crown and solid trunk')
    ax.legend(loc='lower right',fontsize=8)
    fig.savefig(a.out/'screens/tree-footprint.png',dpi=150)
    plt.close(fig)
if __name__=='__main__':main()
