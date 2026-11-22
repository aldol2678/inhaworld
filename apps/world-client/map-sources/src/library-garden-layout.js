// Public QA: OSM footprint/centerline facts and existing game navigation anchors only. Neutral generated presentation; no image-derived facades or measured visual dressing.
import { projectPolygon } from './reality-adapter.js';
import { CAMPUS_ROADS, roadFrame } from './campus-road-layout.js';
import { BUILDINGS } from './basic-campus.js';
import { exteriorFrame } from './north-campus-layout.js';
const url=new URL('../data/reality/evidence/roads/library-garden.json',import.meta.url);
const data=url.protocol==='file:'
  ? JSON.parse((await import('node:fs')).readFileSync(url,'utf8'))
  : await (async()=>{const r=await fetch(url);if(!r.ok)throw Error(`Library garden load failed: ${r.status}`);return r.json();})();
export const LIBRARY_GREENS=data.features.map(q=>({...q,polygon:projectPolygon(q.ring)}));
const garden=LIBRARY_GREENS[0],a=garden.polygon[1],b=garden.polygon[2];
export const GARDEN_FRAME=roadFrame(a,b);
GARDEN_FRAME.yaw=-Math.atan2(b.z-a.z,b.x-a.x)*180/Math.PI;
export function nearestPolylinePoint(point,vertices){
  let best=null;
  for(let i=1;i<vertices.length;i++){
    const a=vertices[i-1],b=vertices[i],dx=b.x-a.x,dz=b.z-a.z,lengthSq=dx*dx+dz*dz;
    const t=lengthSq<=1e-12?0:Math.max(0,Math.min(1,((point.x-a.x)*dx+(point.z-a.z)*dz)/lengthSq));
    const hit={x:a.x+dx*t,z:a.z+dz*t},distance=Math.hypot(point.x-hit.x,point.z-hit.z);
    if(!best||distance<best.distance)best={...hit,distance};
  }
  if(!best)throw Error('Polyline requires at least two points');
  return {x:best.x,z:best.z};
}
export const GARDEN_FLOOR=-.6;
const libraryWest=exteriorFrame(BUILDINGS.find(b=>b.id==='bldg_jungseok').vertices,0);
const westJoin=libraryWest.at(libraryWest.length,.85);
const westRoad=CAMPUS_ROADS.find(road=>road.id==='road_481241681');
if(!westRoad)throw Error('Jungseok west road 481241681 is required');
export const GARDEN_LIBRARY_ROAD_LINK=[
  westJoin,
  nearestPolylinePoint(westJoin,westRoad.vertices)
];
export const GARDEN_LIBRARY_PATHS=[
  [GARDEN_FRAME.at(14,0),GARDEN_FRAME.at(14,-2)],
  [GARDEN_FRAME.at(6,0),GARDEN_FRAME.at(6,-2)],
  [GARDEN_FRAME.at(14,-2),GARDEN_FRAME.at(0,-2),...GARDEN_LIBRARY_ROAD_LINK]
];
