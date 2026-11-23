// Candidate survey directions in the game's east-X/north-Z projection.
import { readFileSync } from 'node:fs';
import { geoToWorld, GEO_ORIGIN } from '../../map-sources/src/geo-coordinates.js';
import { edgeFrame } from '../../map-sources/src/roadview-layout.js';
import { FACILITIES } from '../../map-sources/src/campus-facilities.js';
import { createSpatial } from '../../src/map/spatial.js';
import entry from '../../map-sources/data/reality/evidence/student-center-entrance.json' with { type: 'json' };

const layout = JSON.parse(readFileSync(new URL('../../data/layout.json', import.meta.url)));
const spatial = createSpatial(layout);
const street = layout.routes.find(r => r.id === 'site_481241696').line;
const tree = layout.trees[58];
const plaza = { x: 128, z: -3 };
const door = geoToWorld(entry.lat, entry.lon);
const ring = FACILITIES.find(f => f.id === entry.facility).rings[0];
const wall = edgeFrame(ring, ring.findIndex(p => Math.hypot(p.x-door.x, p.z-door.z) < 1e-5));
const station = (id, label, eye, target, reference, observe, overhead = false) => {
  if (!overhead && !spatial.canStand(eye.x, eye.z)) throw Error('Occupied survey camera: ' + id);
  const east = geoToWorld(GEO_ORIGIN.lat, GEO_ORIGIN.lon + 1).x - GEO_ORIGIN.x;
  const north = geoToWorld(GEO_ORIGIN.lat + 1, GEO_ORIGIN.lon).z - GEO_ORIGIN.z;
  const pose = [eye.x, eye.z, target.x, target.z];
  if (overhead) pose.push(22, -Math.PI/2);
  return {
    id, label, pose, reference, observe,
    bearing: overhead ? null : Math.round((Math.atan2(target.x-eye.x, target.z-eye.z)*180/Math.PI+360)%360),
    suggestedWGS84: overhead ? null : [
      GEO_ORIGIN.lat + (eye.z-GEO_ORIGIN.z)/north, GEO_ORIGIN.lon + (eye.x-GEO_ORIGIN.x)/east,
    ],
  };
};
const stations = [
  station('agora-east', '광장 안에서 동쪽', plaza, {x:138,z:-3}, '1099894035 꼭짓점 2~4', '동측 포장 끝과 건물 기단을 함께 담고 사이 재질을 기록한다.'),
  station('agora-west', '광장 안에서 서쪽', plaza, {x:118,z:-3}, '1099894035 꼭짓점 6 / 481241696', '서측 잔디와 접근로가 만나는 선, 보도 유효 폭을 기록한다.'),
  station('agora-south', '광장 안에서 남쪽', plaza, {x:128,z:-13}, '1099894035 꼭짓점 5 / 568420970', '남쪽 진입 축과 나무 열, 벤치·가로등의 순서를 확인한다.'),
  station('agora-north', '광장 안에서 북쪽', plaza, {x:128,z:7}, '1099894035 꼭짓점 0 / 인경호', '좌석과 수목 보호대, 인경호 방향의 보행 연결을 기록한다.'),
  station('agora-overhead', '광장 높은 시점', plaza, {x:128,z:7}, '1099894035의 7개 꼭짓점', '접근 가능한 높은 지점에서 광장 외곽·건물 모서리·진입로를 함께 담고 실제 촬영점을 기록한다.', true),
  station('approach-in', '접근로에서 광장 방향', street.at(-2), street.at(-1), '481241696 노드 4741759444→4741759448', '문턱·포장 전환·경사·배수 경계와 폭을 기준척과 함께 기록한다.'),
  station('approach-out', '접근로에서 역방향', street.at(-1), street.at(-2), '481241696 노드 4741759448→4741759444', '같은 연결부를 반대쪽에서 보고 단차·계단·경사로의 존재를 확인한다.'),
  station('dream-contact', '드림센터와 58번 나무', {x:133,z:-13}, tree, '568420970 꼭짓점 2→3 / 게임 tree-58', '수간 밑동과 벽 하단을 한 컷에 담고 벽부터 수간 중심까지 수직 거리와 기준 방향을 기록한다.'),
  station('dream-return', '드림센터 3→0번 면', {x:117,z:-25}, tree, '568420970 꼭짓점 3→0 / 표지 16', '건물 모서리, 수관 아래 공간 및 출입구 유무를 반대 방향에서 기록한다.'),
  station('student-entry2', '학생회관 비룡플라자 입구2', wall.at(0,4.1), door, '218038027 / 노드 9767122970', '문틀 바깥 폭·문턱·경사·연결 보도·현장 표기를 기록한다.'),
];
if (process.argv.includes('--map')) {
  const evidence = JSON.parse(readFileSync(new URL('./raw/osm.json', import.meta.url)));
  const rings = Object.fromEntries(Object.entries(evidence.footprints).map(([id, record]) =>
    [id, record.orderedWGS84.slice(0,-1).map(([lat, lon]) => geoToWorld(lat, lon))]));
  const doors = Object.fromEntries(Object.entries(evidence.entrances).map(([id, n]) =>
    [id, geoToWorld(n.latitude, n.longitude)]));
  console.log(JSON.stringify({rings, doors, approach: street, tree}));
} else {
  console.log(JSON.stringify(stations, null, 2));
}
