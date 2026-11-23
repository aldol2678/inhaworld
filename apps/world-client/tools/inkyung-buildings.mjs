// The two shoreline backdrops have named OSM footprints in the existing facility ledger.
// Heights/floor spacing are its public-QA blockout values. The window treatment is illustrative.
import { FACILITIES } from '../map-sources/src/campus-facilities.js';
import { edgeFrame } from '../map-sources/src/roadview-layout.js';

function wall(batch, color, a, b, low, high) {
  batch.quad(color, [a.x, low, a.z], [b.x, low, b.z], [b.x, high, b.z], [a.x, high, a.z]);
}

function shell(batch, color, ring, low, high) {
  ring.forEach((p, i) => wall(batch, color, p, ring[(i + 1) % ring.length], low, high));
}

// The footway and Student Center share OSM entrance node 9767122969. Keep its
// arrival point walkable under the mapped upper footprint. The recess is capsule clearance.
function entranceRecess(ring, sidewalk) {
  const landing = sidewalk.line.at(-1);
  const i = ring.findIndex(p => Math.hypot(p.x - landing.x, p.z - landing.z) < 1e-5);
  if (i < 0) throw Error('Student Center entrance no longer meets the mapped sidewalk');
  const left = edgeFrame(ring, (i + ring.length - 1) % ring.length);
  const right = edgeFrame(ring, i);
  const half = sidewalk.width / 2 + 0.6;
  const inset = 1.10;
  const notch = [left.at(left.length - half, 0), left.at(left.length - half, -inset),
    right.at(half, -inset), right.at(half, 0)];
  return { ground: [...ring.slice(0, i), ...notch, ...ring.slice(i + 1)], soffit: [...notch, landing] };
}

export function fillInkyungBuildings(shared, near, solid, lake, sidewalk) {
  for (const id of ['bldg_02_south', 'bldg_07']) {
    const { rings: [ring], height, floors } = FACILITIES.find(f => f.id === id);
    const curved = id === 'bldg_07';
    const stone = curved ? '#ded7c5' : '#cabea8';
    const storey = height / floors;
    if (curved) {
      const { ground, soffit } = entranceRecess(ring, sidewalk);
      shell(shared, stone, ground, 0, storey);
      shell(shared, stone, ring, storey, height);
      shared.polygon('#b9b4a5', soffit, storey);
      solid(id, ground, 0, height);
    } else {
      shell(shared, stone, ring, 0, height);
      solid(id, ring, 0, height);
    }
    shared.polygon('#a9aaa0', ring, height);

    // Carry the horizontal window ribbons around the existing bends. All visible
    // edges keep their exact source vertices, including the short curved frontage.
    ring.forEach((p, i) => {
      const f = edgeFrame(ring, i);
      if (f.local(lake).out <= 0) return;
      const bays = Math.ceil(f.length / (curved ? 4.0 : 3.3));
      const span = f.length / bays;
      for (let j = 0; j < bays; j++) {
        const margin = Math.min(curved ? 0.055 : 0.21, span * 0.12);
        const a = f.at(j * span + margin, 0.014);
        const b = f.at((j + 1) * span - margin, 0.014);
        // Keep the entrance face clear at player height.
        for (let level = curved ? 1 : 0; level < floors; level++) {
          const y = storey * level;
          const glass = curved ? '#718e90' : '#798785';
          wall(near, glass, a, b, y + storey * 0.31, y + storey * 0.73);
        }
      }
      wall(near, '#ece6d5', f.at(0, 0.018), f.at(f.length, 0.018), height - 0.23, height);
    });
  }
}
