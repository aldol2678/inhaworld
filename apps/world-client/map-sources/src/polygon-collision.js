function edges(polygon) {
  const area = polygon.reduce((s,p,i)=>{const q=polygon[(i+1)%polygon.length];return s+p.x*q.z-q.x*p.z},0);
  return polygon.map((a,i)=>{
    const b=polygon[(i+1)%polygon.length],dx=b.x-a.x,dz=b.z-a.z,length=Math.hypot(dx,dz);
    return {a,b,length,t:{x:dx/length,z:dz/length},n:{x:(area>0?dz:-dz)/length,z:(area>0?-dx:dx)/length}};
  });
}
export function polygonOverlap(x,z,polygon,radius=0) {
  let inside=false;
  for(const {a,b,t,length} of edges(polygon)) {
    if((a.z>z)!==(b.z>z)&&x<(b.x-a.x)*(z-a.z)/(b.z-a.z)+a.x)inside=!inside;
    const u=Math.max(0,Math.min(length,(x-a.x)*t.x+(z-a.z)*t.z));
    if(Math.hypot(x-a.x-u*t.x,z-a.z-u*t.z)<radius)return true;
  }
  return inside;
}
