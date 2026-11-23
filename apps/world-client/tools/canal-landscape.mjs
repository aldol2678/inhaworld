// Photos 4/5/19 establish the planting pattern. Only source lawns, paths and
// pre-existing trunks anchor dressing. No generated foliage owns navigation.
import { subtractGround } from '../map-sources/src/ground-clipping.js';
import { roadFrame, roadTreeClear } from '../map-sources/src/campus-road-layout.js';
import { gateDormRoadTreeClear } from '../map-sources/src/main-gate-road-layout.js';
import { libraryRouteTreeClear } from '../map-sources/src/library-route-layout.js';
import { polygonOverlap } from '../map-sources/src/polygon-collision.js';
import { triangulatePolygon } from '../map-sources/src/reality-adapter.js';
import { edgeFrame } from '../map-sources/src/roadview-layout.js';

const point = (p, y) => [p.x, y, p.z];
const bankIds = ['site_481241657', 'site_258995842'];
export function fillLawn(batch, ring) {
  function vertex(p) {
    const v = Math.sin(p.x * 0.18 + p.z * 0.11) * 4 + Math.cos(p.z * 0.24 - p.x * 0.09) * 3;
    const rgb = [153 + v, 161 + v * 0.8, 100 + v * 0.65];
    return [point(p, 0.018), '#' + rgb.map((c) => Math.round(c).toString(16).padStart(2, '0')).join('')];
  }
  // Interpolate across each GIS triangle with the same field at shared edges.
  const ids = triangulatePolygon(ring);
  for (let i = 0; i < ids.length; i += 3) {
    const [a, b, c] = ids.slice(i, i + 3).map((k) => ring[k]);
    const n = 3;
    const rows = Array.from({ length: n + 1 }, (_, j) =>
      Array.from({ length: n - j + 1 }, (_, k) =>
        vertex({
          x: a.x + ((b.x - a.x) * j) / n + ((c.x - a.x) * k) / n,
          z: a.z + ((b.z - a.z) * j) / n + ((c.z - a.z) * k) / n,
        }),
      ),
    );
    for (let j = 0; j < n; j++)
      for (let k = 0; k < n - j; k++) {
        batch.coloredTriangle(rows[j][k], rows[j + 1][k], rows[j][k + 1]);
        if (k < n - j - 1) batch.coloredTriangle(rows[j + 1][k], rows[j + 1][k + 1], rows[j][k + 1]);
      }
  }
}

// A low multi-plane crown uses large uninterrupted faces at distance. Close
// shrubs get an asymmetric shoulder and a lighter side facing the scene sun.
function shrub(batch, p, r, h, seed, palette) {
  const rim = [],
    shoulder = [];
  for (let i = 0; i < 7; i++) {
    const angle = (i * 2 * Math.PI) / 7 + seed;
    const size = r * (0.86 + 0.14 * Math.sin(i * 3 + seed));
    const dx = Math.cos(angle) * size,
      dz = Math.sin(angle) * size * 0.81;
    rim.push([p.x + dx, 0.035, p.z + dz]);
    shoulder.push([p.x + 0.77 * dx, h * (0.51 + 0.09 * Math.cos(i + seed)), p.z + 0.77 * dz]);
  }
  const top = [p.x + r * 0.11, h, p.z - r * 0.1];
  for (let i = 0; i < 7; i++) {
    const j = (i + 1) % 7;
    const color = palette[shoulder[i][0] - p.x + (shoulder[i][2] - p.z) * 0.5 > 0 ? 1 : 0];
    batch.quad(color, rim[i], shoulder[i], shoulder[j], rim[j]);
    batch.triangle(palette[1], shoulder[i], top, shoulder[j]);
  }
}
function ribbon(batch, f, start, end, left, right, y, color) {
  batch.polygon(color, [f.at(start, left), f.at(end, left), f.at(end, right), f.at(start, right)], y);
}
function trimPath(route, layers, canal) {
  for (let i = 1; i < route.line.length; i++) {
    const f = roadFrame(route.line[i - 1], route.line[i]);
    const end = f.length - 1.15;
    if (end < 1.2) continue;
    for (const sign of [-1, 1]) {
      const edge = sign * (route.width / 2 - 0.08);
      ribbon(layers[0], f, 1.1, end, edge - 0.05, edge + 0.05, 0.051, canal ? '#c4baa3' : '#b6b3a4');
    }
    if (canal)
      for (let u = 2, row = 0; u + 1.48 < end; u += 1.48, row++) {
        const offset = row % 2 ? 0.38 : -0.38;
        for (const v of [offset - 0.72, offset + 0.72])
          ribbon(layers[3], f, u, u + 1.48, v, v + 0.025, 0.051, '#969589');
      }
    // Fine cross joints only on the verified paved bed; leave intersections clear.
    for (let u = 2; u < end; u += canal ? 1.48 : 2.3)
      ribbon(layers[2], f, u, u + 0.033, -route.width * 0.45, route.width * 0.45, 0.052, '#777b72');
  }
}
export function fillLandscape({ lawns, pool, plaza, routes, trees, treeRoad, canal, connector }) {
  const ids = triangulatePolygon(plaza),
    masks = [];
  for (let i = 0; i < ids.length; i += 3) masks.push(ids.slice(i, i + 3).map((j) => plaza[j]));
  const outsidePlaza = subtractGround(masks);
  const approach = connector.map((batch) => ({
    polygon(color, ring, y) {
      for (const piece of outsidePlaza(ring)) batch.polygon(color, piece, y);
    },
  }));
  for (const route of routes) {
    if (bankIds.includes(route.id)) trimPath(route, canal, true);
    if (route.id === 'site_481241696') trimPath(route, approach, false);
  }
  for (let i = 0; i < pool.length; i++) {
    const f = edgeFrame(pool, i);
    for (let u = 0.9; u < f.length - 0.2; u += 1.45)
      ribbon(canal[1], f, u, u + 0.034, -0.146, 0.146, 0.081, '#878b7f');
  }
  let state = 78125;
  const random = () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 4294967296;
  };
  const shrubs = [
    ['#607854', '#849459'],
    ['#75814b', '#9b9c5a'],
    ['#866941', '#aa844d'],
  ];
  for (const ring of lawns) {
    const xs = ring.map((p) => p.x),
      zs = ring.map((p) => p.z);
    const left = Math.min(...xs),
      bottom = Math.min(...zs),
      right = Math.max(...xs),
      top = Math.max(...zs);
    for (let i = 0; i < 96; i++) {
      const p = { x: left + random() * (right - left), z: bottom + random() * (top - bottom) };
      const r = 0.42 + random() * 0.86;
      if (
        !polygonOverlap(p.x, p.z, ring) ||
        !roadTreeClear(p, r + 0.4) ||
        !gateDormRoadTreeClear(p, r) ||
        !libraryRouteTreeClear(p) ||
        trees.some((t) => Math.hypot(t.x - p.x, t.z - p.z) < 2)
      )
        continue;
      const h = 0.32 + random() * 0.53;
      // A small low shrub never reads as a solid tree or a walking barrier.
      shrub(canal[1 + (i % 3)], p, r, h, i * 0.7, shrubs[i % 3]);
    }
  }
  for (const [i, t] of trees.entries()) {
    if (t.form) continue; // The lakeside crowns already have their own P1A treatment.
    const layers = treeRoad.get(t) === 'site_481241696' ? connector : canal;
    // Dappled ground and leaf litter at existing trunks; positions are illustrative.
    const radius = 1.14 + 0.23 * Math.sin(i * 2);
    const angle = i * 2.4;
    const branch = (scale, height) => [t.x + scale * Math.cos(angle), height, t.z + scale * Math.sin(angle)];
    layers[2].tube('#796849', point(t, 1.45), branch(0.85, 3.05), 0.11, 5);
    layers[2].tube('#827157', point(t, 1.85), branch(-0.72, 3.22), 0.085, 5);
    if (polygonOverlap(t.x, t.z, plaza, 2)) continue; // P1A owns the tree wells and surrounding paving.
    const ring = Array.from({ length: 8 }, (_, k) => ({
      x: t.x + 0.27 + radius * Math.cos((k * Math.PI) / 4),
      z: t.z + 0.15 + radius * 0.77 * Math.sin((k * Math.PI) / 4),
    }));
    layers[1].polygon('#808854', ring, 0.029);
    for (let k = 0; k < 7; k++) {
      const a = random() * Math.PI * 2,
        dist = 0.6 + random() * 0.9;
      const x = t.x + Math.cos(a) * dist,
        z = t.z + Math.sin(a) * dist;
      layers[3].triangle(
        k % 3 ? '#a99766' : '#a5824a',
        [x - 0.1, 0.031, z],
        [x + 0.14, 0.031, z + 0.07],
        [x + 0.03, 0.031, z - 0.09],
      );
    }
  }
}
