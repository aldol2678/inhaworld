// Public QA: OSM footprint/centerline facts and existing game navigation anchors only. Neutral generated presentation; no image-derived facades or measured visual dressing.
import { FACILITIES } from './campus-facilities.js';
import { exteriorFrame } from './north-campus-layout.js';
export const SPORTS_FLOOR=-.9;
const stadium=FACILITIES.find(f=>f.id==='fac_stadium').rings[0];
const basketball=FACILITIES.find(f=>f.id==='fac_basketball').rings[0];
export const STANDS={frame:exteriorFrame(basketball,5),run:4,rows:4,aisleSteps:12,aisleWidth:1.4};
STANDS.aisles=[2,STANDS.frame.length/2,STANDS.frame.length-2];
const f=STANDS.frame;
export const SPORTS_CUT_RING=[...stadium,...basketball.slice(3,6),
  f.at(0,STANDS.run),f.at(f.length,STANDS.run),...basketball.slice(6),basketball[0]];
