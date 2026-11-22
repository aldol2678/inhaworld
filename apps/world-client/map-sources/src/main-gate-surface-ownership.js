// The editor owns the visible gate apron/frontage. Legacy GIS roads and
// their shoulders continue outside it, without painting across the new gate.
import { MAIN_GATE_FORECOURT_QUADS } from './main-gate-forecourt.js';
import { mainGateProductionPath } from './editor/main-gate-production.js';
import { signedArea as area, subtractGround } from './ground-clipping.js';
const EPS=1e-8;
const cross=(a,b,p)=>(b.x-a.x)*(p.z-a.z)-(b.z-a.z)*(p.x-a.x);
const road=mainGateProductionPath('sosung_ro_frontage');
const [a,b]=road.vertices,span=Math.hypot(b.x-a.x,b.z-a.z);
const nx=-(b.z-a.z)/span*road.width/2,nz=(b.x-a.x)/span*road.width/2;
export const MAIN_GATE_GROUND_MASKS=Object.freeze([
  ...MAIN_GATE_FORECOURT_QUADS,
  [{x:a.x+nx,z:a.z+nz},{x:b.x+nx,z:b.z+nz},{x:b.x-nx,z:b.z-nz},{x:a.x-nx,z:a.z-nz}]
].map(r=>Object.freeze((area(r)<0?[...r].reverse():[...r]).map(p=>Object.freeze({x:p.x,z:p.z})))));
export const clipLegacyGateGround = subtractGround(MAIN_GATE_GROUND_MASKS);
// Convex input quads stay convex after half-plane clipping. Emit a triangle
// fan as nondegenerate four-vertex faces for the existing batch API.
export function fillLegacyGateGround(batch,color,ring,y){
  for(let piece of clipLegacyGateGround(ring)){
    if(area(piece)>0)piece=[...piece].reverse();
    if(piece.length===4){batch.quad(color,...piece.map(p=>[p.x,y,p.z]));continue;}
    for(let i=1;i<piece.length-1;i++){
      const a=piece[0],b=piece[i],c=piece[i+1];
      if(Math.abs(cross(a,b,c))<=EPS)continue;
      batch.quad(color,[a.x,y,a.z],[b.x,y,b.z],[(b.x+c.x)/2,y,(b.z+c.z)/2],[c.x,y,c.z]);
    }
  }
}
export function gateClippedRoadBatch(batch){
  return {quad(color,...vertices){
    fillLegacyGateGround(batch,color,vertices.map(p=>({x:p[0],z:p[2]})),vertices[0][1]);
  },box(...args){return batch.box(...args);}};
}
