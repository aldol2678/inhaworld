// Geometry follows the mapped shells. Materials, bays and heights are public
// presentation estimates. #4/#5/#19 establish massing relative to the lawns.
import { FACILITIES } from '../map-sources/src/campus-facilities.js';
import { edgeFrame } from '../map-sources/src/roadview-layout.js';

function point(f, u, y, v) {
  const p = f.at(u, v);
  return [p.x, y, p.z];
}
function panel(b, c, f, l, r, low, high, v = 0.02) {
  b.quad(c, point(f, l, low, v), point(f, r, low, v), point(f, r, high, v), point(f, l, high, v));
}
function sill(b, f, l, r, y) {
  b.quad(
    '#d8d4c7',
    point(f, l, y, 0.015),
    point(f, r, y, 0.015),
    point(f, r, y, 0.115),
    point(f, l, y, 0.115),
  );
  panel(b, '#aaa99d', f, l, r, y - 0.075, y, 0.115);
}
const buildings = [
  { id: 'bldg_lawschool', wall: '#d5c8b6', glass: '#69878a', roof: '#9a9485' },
  { id: 'bldg_06', wall: '#e5dfd2', glass: '#577985', roof: '#92968e' },
  { id: 'bldg_hawaii', wall: '#c5b399', glass: '#667771', roof: '#938c7c' },
];
export function fillCorridorBuildings(shared, canal, connector, solid) {
  const axis = { x: 36, z: -32 };
  for (const { id, wall, glass, roof } of buildings) {
    const b = FACILITIES.find((f) => f.id === id);
    const ring = b.rings[0],
      h = b.height,
      floors = b.floors;
    const layers = id === 'bldg_lawschool' ? canal : connector;
    shared.polygon(roof, ring, h);
    solid(id, ring, 0, h);
    ring.forEach((_, i) => {
      const f = edgeFrame(ring, i),
        len = f.length;
      panel(shared, wall, f, 0, len, 0, h, 0);
      if (len < 1.6) return;
      // 6 Hall edge 0 alone has documented tall arched bays in the legacy
      // north-campus-photo-geometry ledger. Other elevations stay rectangular.
      if (id === 'bldg_06' && i === 0) {
        const count = Math.max(1, Math.floor(len / 3.7)),
          pitch = len / count,
          rad = pitch * 0.38;
        for (let j = 0; j < count; j++) {
          const u = (j + 0.5) * pitch,
            spring = h - 0.65 - rad;
          panel(shared, glass, f, u - rad, u + rad, 0.5, spring);
          for (let k = 0; k < 8; k++) {
            const at = (angle) => point(f, u + rad * Math.cos(angle), spring + rad * Math.sin(angle), 0.02);
            shared.triangle(
              glass,
              point(f, u, spring, 0.02),
              at((k * Math.PI) / 8),
              at(((k + 1) * Math.PI) / 8),
            );
          }
          panel(layers[1], '#b1bcba', f, u - 0.042, u + 0.042, 0.55, spring + rad, 0.035);
          for (let y = 2; y < spring; y += 2)
            panel(layers[2], '#bec5bc', f, u - rad, u + rad, y, y + 0.08, 0.04);
        }
        return;
      }
      panel(shared, '#ece6d7', f, 0, len, h - 0.27, h, 0.025);
      if (len < 2.7) return;
      const pitch = h / floors,
        bays = Math.max(1, Math.round(len / 3.2));
      for (let level = 0; level < floors; level++) {
        const y = level * pitch + pitch * 0.29;
        panel(shared, glass, f, 0.38, len - 0.38, y, y + pitch * 0.47);
        if (f.local(axis).out < 0) continue;
        for (let j = 1; j < bays; j++) {
          const u = (len * j) / bays;
          panel(layers[0], wall, f, u - 0.15, u + 0.15, y - 0.012, y + pitch * 0.47 + 0.012, 0.05);
          panel(
            layers[2],
            '#b6bcb3',
            f,
            u + (len / bays) * 0.36,
            u + (len / bays) * 0.36 + 0.05,
            y,
            y + pitch * 0.47,
            0.055,
          );
        }
        sill(layers[1], f, 0.26, len - 0.26, y);
      }
    });
  }
}
export function fillStudentDoor(batch, frame) {
  const w = frame.length;
  panel(batch, '#4d6567', frame, 0.09, w - 0.09, 0.04, 2.1, 0.012);
  for (const u of [0.12, w / 2, w - 0.12])
    panel(batch, '#b9c0b9', frame, u - 0.038, u + 0.038, 0.04, 2.1, 0.033);
  panel(batch, '#cbd0c7', frame, 0.1, w - 0.1, 1.78, 1.83, 0.035);
  for (const u of [w * 0.43, w * 0.57])
    panel(batch, '#ded8c7', frame, u - 0.026, u + 0.026, 0.8, 1.23, 0.055);
}

// Continue the existing architecture around the unmodelled returns. Keep the
// photo-modelled fronts, entry volumes, steps and library west wall as sole owners.
export function fillCampusReturns(shared, layers, buildings) {
  for (const b of buildings) {
    const hall = b.id === 'bldg_01';
    const ring = b.vertices,
      h = b.height;
    ring.forEach((_, i) => {
      if (hall ? i === 5 : [0, 6, 13].includes(i)) return;
      const f = edgeFrame(ring, i),
        len = f.length;
      if (len < 3) return;
      const floors = hall ? 4 : 6,
        storey = (h - 0.65) / floors;
      const bays = Math.max(1, Math.round(len / (hall ? 3.1 : 2.65))),
        span = len / bays;
      panel(shared, '#e8e3d5', f, 0, len, h - 0.31, h, 0.035);
      for (let k = 0; k < floors; k++) {
        const bottom = 0.55 + k * storey,
          top = bottom + storey * 0.53;
        for (let j = 0; j < bays; j++) {
          const l = (j + 0.1) * span,
            r = (j + 0.9) * span;
          panel(shared, hall ? '#74898a' : '#769197', f, l, r, bottom, top, 0.019);
          panel(layers[1], '#b4bdb6', f, (l + r) / 2 - 0.041, (l + r) / 2 + 0.041, bottom, top, 0.035);
        }
        sill(layers[2], f, 0.1, len - 0.1, bottom);
      }
    });
  }
}

export function fillStudentSpandrel(b, f, level, storey) {
  const y = level * storey;
  // Reveal, sill and mullion lie within the existing curved face rhythm.
  sill(b, f, 0, f.length, y + 0.305 * storey);
  for (let u = 1.35; u < f.length - 0.2; u += 1.85)
    panel(b, '#a8b4ac', f, u - 0.031, u + 0.031, y + storey * 0.31, y + storey * 0.74, 0.035);
}
