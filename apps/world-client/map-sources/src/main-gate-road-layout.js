import { roadFrame, distanceToRoad } from './campus-road-layout.js';
import { mainGateProductionPath } from './editor/main-gate-production.js';
import { gateForecourtTreeClear } from './main-gate-forecourt.js';
const authored=id=>mainGateProductionPath(id);
export const SOSUNG_RO=authored('sosung_ro_frontage');
export const MAIN_GATE_APPROACH_ROAD=authored('main_gate_approach');
export const GATE_DORM_ROADS=[SOSUNG_RO,MAIN_GATE_APPROACH_ROAD];
export const GATE_DORM_PATHS=[
  authored('sosung_north_sidewalk_west'),
  authored('sosung_north_sidewalk_east'),
  authored('sosung_south_sidewalk'),
  authored('main_gate_pedestrian_exit'),
  authored('dorm1_entry_path'),
  authored('main_gate_red_promenade')
];
export const GATE_DORM_CROSSINGS=[
  authored('sosung_crossing_west'),
  authored('sosung_crossing_east')
];
export const MAIN_GATE_INNER_ZEBRA=authored('main_gate_inner_zebra');
export const GATE_DORM_CORRIDORS=[...GATE_DORM_ROADS,...GATE_DORM_PATHS,...GATE_DORM_CROSSINGS];
export const GATE_DORM_SEGMENTS=GATE_DORM_CORRIDORS.flatMap(road=>road.vertices.slice(1).map((b,i)=>({
  id:`${road.id}_${i}`,road,frame:roadFrame(road.vertices[i],b)
})));
export const gateDormRoadTreeClear=(p,radius=1.9)=>gateForecourtTreeClear(p,radius)&&GATE_DORM_SEGMENTS.every(s=>distanceToRoad(p,s)>s.road.width/2+radius);
