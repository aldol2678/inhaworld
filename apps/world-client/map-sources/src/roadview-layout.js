import { BUILDINGS } from './basic-campus.js';
import { GATE_FRAME } from './main-gate-frame.js';
import { LIBRARY_ENTRY_HEIGHT, LIBRARY_FRONT_STAIR } from './library-route-layout.js';
export function edgeFrame(ring,index) {
  const a=ring[index],b=ring[(index+1)%ring.length],length=Math.hypot(b.x-a.x,b.z-a.z);
  const tx=(b.x-a.x)/length,tz=(b.z-a.z)/length;
  const area=ring.reduce((sum,p,i)=>sum+p.x*ring[(i+1)%ring.length].z-ring[(i+1)%ring.length].x*p.z,0);
  const nx=area>0?tz:-tz,nz=area>0?-tx:tx;
  return {length,yaw:-Math.atan2(tz,tx)*180/Math.PI,
    at:(u,out)=>({x:a.x+tx*u+nx*out,z:a.z+tz*u+nz*out}),
    local:p=>({u:(p.x-a.x)*tx+(p.z-a.z)*tz,out:(p.x-a.x)*nx+(p.z-a.z)*nz})};
}
export const MAIN_HALL_APPROACH={frame:edgeFrame(BUILDINGS.find(b=>b.id==='bldg_01').vertices,5),height:.28,landing:.55,run:1.4,steps:4};
export { GATE_FRAME };
const libraryRing=BUILDINGS.find(b=>b.id==='bldg_jungseok').vertices;
export const LIBRARY_APPROACHES=[
  {id:'library_front',frame:edgeFrame(libraryRing,6),height:LIBRARY_ENTRY_HEIGHT,...LIBRARY_FRONT_STAIR,steps:22},
  {id:'library_rear',frame:edgeFrame(libraryRing,13),height:.30,landing:1.1,run:1.2,steps:3,inset:.55}
];
export const librarySideRailStart=(t,side)=>t.id==='library_front'?(side===0?4:t.landing):0;
