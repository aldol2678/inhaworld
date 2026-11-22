import { roadFrame } from './campus-road-layout.js';
export function exteriorFrame(ring,index,hole=false) {
  const a=ring[index],b=ring[(index+1)%ring.length],f=roadFrame(a,b);
  const area=ring.reduce((s,p,i)=>s+p.x*ring[(i+1)%ring.length].z-ring[(i+1)%ring.length].x*p.z,0);
  const sign=(area>0?-1:1)*(hole?-1:1),t=f.at(1),tx=t.x-a.x,tz=t.z-a.z;
  return {length:f.length,yaw:-Math.atan2(tz,tx)*180/Math.PI,
    at:(u,out)=>f.at(u,out*sign),local:p=>({u:(p.x-a.x)*tx+(p.z-a.z)*tz,out:((p.x-a.x)*-tz+(p.z-a.z)*tx)*sign})};
}
