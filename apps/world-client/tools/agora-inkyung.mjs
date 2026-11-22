// Build-only P1A surfaces. Polygons and way nodes are GIS inputs; all dressing is estimated.
import access from '../map-sources/data/reality/evidence/roads/agora-inkyung.json' with { type: 'json' };
import { CAMPUS_GRADE } from '../src/map/spatial.js';
import { FLAT_GROUND_Y as Y } from '../map-sources/src/flat-ground-surface.js';
import { roadFrame, roadTreeClear } from '../map-sources/src/campus-road-layout.js';
import { edgeFrame } from '../map-sources/src/roadview-layout.js';
import { polygonOverlap } from '../map-sources/src/polygon-collision.js';
import { triangulatePolygon } from '../map-sources/src/reality-adapter.js';
import { intersectGround, signedArea, subtractGround } from '../map-sources/src/ground-clipping.js';

const rect = (f, u0, u1, v0, v1) => [f.at(u0, v0), f.at(u1, v0), f.at(u1, v1), f.at(u0, v1)];
const mix = (a, b, t) => ({ x: a.x + (b.x - a.x) * t, z: a.z + (b.z - a.z) * t });
const pointAt = (p, y) => [p.x, CAMPUS_GRADE + y, p.z];

function flat(batch, color, ring, y = Y.SURFACE) {
  const points = signedArea(ring) > 0 ? [...ring].reverse() : ring;
  const vertices = points.map((p) => [pointAt(p, y), typeof color === 'function' ? color(p) : color]);
  for (let i = 1; i < vertices.length - 1; i++)
    batch.coloredTriangle(vertices[0], vertices[i], vertices[i + 1]);
}

function triangles(ring) {
  const indices = triangulatePolygon(ring);
  const faces = [];
  for (let i = 0; i < indices.length; i += 3)
    faces.push(indices.slice(i, i + 3).map((index) => ring[index]));
  return faces;
}

// Mitered sections share endpoints at the interior OSM node. The pavement and
// its two shoulders have disjoint interiors even at the bend.
function roadRibbon(line, left, right) {
  const normals = line.slice(1).map((b, i) => {
    const a = line[i],
      length = Math.hypot(b.x - a.x, b.z - a.z);
    return { x: (a.z - b.z) / length, z: (b.x - a.x) / length };
  });
  const sections = line.map((p, i) => {
    const a = normals[Math.max(i - 1, 0)],
      b = normals[Math.min(i, normals.length - 1)];
    const divisor = 1 + a.x * b.x + a.z * b.z;
    return [left, right].map((v) => ({
      x: p.x + (v * (a.x + b.x)) / divisor,
      z: p.z + (v * (a.z + b.z)) / divisor,
    }));
  });
  return sections.slice(1).map(([l, r], i) => [sections[i][0], l, r, sections[i][1]]);
}

function ringBorder(batch, outer, inner, color, clip) {
  for (let i = 0; i < outer.length; i++) {
    const j = (i + 1) % outer.length;
    for (const piece of clip([outer[i], outer[j], inner[j], inner[i]])) flat(batch, color, piece);
  }
}

function plazaPaving(batch, plaza, trees, approachMasks) {
  const center = {
    x: plaza.reduce((sum, p) => sum + p.x, 0) / plaza.length,
    z: plaza.reduce((sum, p) => sum + p.z, 0) / plaza.length,
  };
  const inner = plaza.map((p) => mix(p, center, 0.075));
  const outsideApproach = subtractGround(approachMasks);
  ringBorder(batch, plaza, inner, '#b3a690', outsideApproach);
  const wells = trees
    .filter((p) => polygonOverlap(p.x, p.z, inner))
    .map((tree) =>
      Array.from({ length: 12 }, (_, i) => ({
        x: tree.x + 0.79 * Math.cos((i * Math.PI) / 6),
        z: tree.z + 0.79 * Math.sin((i * Math.PI) / 6),
      })),
    );
  const wellInterior = (ring) => {
    const inside = intersectGround(ring, inner);
    return inside.length ? outsideApproach(inside) : [];
  };
  for (const well of wells) {
    const tree = mix(well[0], well[6], 0.5);
    const soil = well.map((p) => mix(p, tree, 0.17));
    ringBorder(batch, well, soil, '#978b70', wellInterior);
    for (const piece of wellInterior(soil)) flat(batch, '#746e52', piece);
  }
  const clip = subtractGround([...approachMasks, ...wells]);
  const f = edgeFrame(plaza, 6),
    points = inner.map((p) => f.local(p));
  const u0 = Math.floor(Math.min(...points.map((p) => p.u)));
  const u1 = Math.ceil(Math.max(...points.map((p) => p.u)));
  const v0 = Math.floor(Math.min(...points.map((p) => p.out)));
  const v1 = Math.ceil(Math.max(...points.map((p) => p.out)));
  const shadeTrees = trees.filter((t) => polygonOverlap(t.x, t.z, plaza, 3));
  // Fixed sun, vertex colors only. Keep the canopy shade inside the paving.
  function shadedStone(color, p) {
    const light = shadeTrees.reduce((factor, tree) => {
      const d = Math.hypot((p.x - tree.x + 1.3) / 2.3, (p.z - tree.z + 0.7) / 1.75);
      return Math.min(factor, 0.76 + 0.24 * Math.min(1, d * d));
    }, 1);
    return (
      '#' +
      color
        .slice(1)
        .match(/../g)
        .map((byte) =>
          Math.round(parseInt(byte, 16) * light)
            .toString(16)
            .padStart(2, '0'),
        )
        .join('')
    );
  }
  const stone = ['#c9b79e', '#cdbca5', '#c6b49c', '#d1bfa7'];
  for (let row = 0, v = v0; v < v1; row++, v += 0.68) {
    const start = u0 - (row % 2) * 0.73;
    for (let col = 0, u = start; u < u1; col++, u += 1.46) {
      const tile = intersectGround(rect(f, u, u + 1.46, v, v + 0.68), inner);
      if (!tile.length) continue;
      const color = row % 7 === 0 ? '#ded5bf' : stone[(row * 3 + col) % stone.length];
      for (const piece of clip(tile)) flat(batch, (p) => shadedStone(color, p), piece);
    }
  }
}

function bench(batch, solid, id, f, u, v) {
  // One ground-based support rectangle for the complete timber seat and back.
  const hw = 1.06,
    hd = 0.29;
  const box = (color, du, dv, y, size) =>
    batch.box(color, pointAt(f.at(u + du, v + dv), y), size, f.yaw);
  for (const side of [-1, 1]) {
    box('#59605a', side * 0.76, 0, 0.14, [0.12, 0.28, 0.45]);
    box('#59605a', side * 0.76, 0.21, 0.38, [0.07, 0.48, 0.07]);
  }
  for (const offset of [-0.18, 0, 0.18]) box('#aa7951', 0, offset, 0.3, [2 * hw, 0.08, 0.15]);
  for (const height of [0.47, 0.62]) box('#996f4d', 0, 0.24, height, [2 * hw, 0.12, 0.08]);
  solid(id, rect(f, u - hw, u + hw, v - hd, v + hd), CAMPUS_GRADE, CAMPUS_GRADE + 0.68);
}

function pondSurface(batch, faces, edges) {
  // Color a single continuous water mesh. Shore distance comes from the same
  // ring as the terrain hole and capsule obstacle, including its concavities.
  function shoreDistance(p) {
    return Math.min(
      ...edges.map((f) => {
        const { u, out } = f.local(p);
        return Math.hypot(out, u - Math.max(0, Math.min(f.length, u)));
      }),
    );
  }
  function vertex(p) {
    const t = Math.min(1, shoreDistance(p) / 4.5);
    const shade = 1.7 * Math.sin(p.z * 0.72 + p.x * 0.15);
    const rgb = [116 - 52 * t, 157 - 40 * t, 144 - 20 * t]
      .map((c) =>
        Math.round(c + shade)
          .toString(16)
          .padStart(2, '0'),
      )
      .join('');
    return [pointAt(p, 0.025), '#' + rgb];
  }
  const divisions = 5;
  for (const [index, [a, b, c]] of faces.entries()) {
    const rows = Array.from({ length: divisions + 1 }, (_, i) =>
      Array.from({ length: divisions - i + 1 }, (_, j) =>
        vertex({
          x: a.x + ((b.x - a.x) * i + (c.x - a.x) * j) / divisions,
          z: a.z + ((b.z - a.z) * i + (c.z - a.z) * j) / divisions,
        }),
      ),
    );
    for (let i = 0; i < divisions; i++) {
      for (let j = 0; j < divisions - i; j++) {
        batch.coloredTriangle(rows[i][j], rows[i + 1][j], rows[i][j + 1]);
        if (j + 1 < divisions - i)
          batch.coloredTriangle(rows[i + 1][j], rows[i + 1][j + 1], rows[i][j + 1]);
      }
    }
    // Slender, low-contrast wind ripples entirely within the water. Distances
    // bound each pair inside the ring, including near the concave western bank.
    for (let k = 1; k <= 5; k++) {
      const u = (((index * 7 + k * 13) % 29) + 2) / 34;
      const v = (1 - u) * ((((index + k * 7) % 17) + 1) / 19);
      const p = {
        x: a.x + u * (b.x - a.x) + v * (c.x - a.x),
        z: a.z + u * (b.z - a.z) + v * (c.z - a.z),
      };
      const length = Math.min(0.87 + 0.16 * (k % 3), shoreDistance(p) - 0.28);
      if (length < 0.4) continue;
      for (const offset of [0, 0.19]) {
        const l = length * (offset ? 0.57 : 1);
        flat(
          batch,
          '#609493',
          [
            { x: p.x - l, z: p.z + offset - 0.08 * l },
            { x: p.x - 0.12 * l, z: p.z + offset + 0.048 },
            { x: p.x + l, z: p.z + offset + 0.08 * l },
            { x: p.x + 0.1 * l, z: p.z + offset - 0.035 },
          ],
          0.031,
        );
      }
    }
  }
}

export function agoraInkyung(port, pond) {
  const plaza = port.projectPolygon(port.LANDMARKS.find((f) => f.id === 'lmk_agora_plaza').polygon);
  const water = triangles(pond),
    edges = pond.map((_, i) => edgeFrame(pond, i));
  const routes = access.ways.map((w) => ({
    id: 'site_' + w.id,
    sourceId: 'osm_way_' + w.id,
    sourceVersion: w.version,
    highway: w.highway,
    line: w.nodes.map(([, lat, lon]) => port.geoToWorld(lat, lon)),
    width: w.highway === 'service' ? 2.04 : 1.24,
    accuracy: 'source-centerline / estimated width',
  }));
  const shoulder = 0.22;
  const accessMasks = routes.flatMap((r) =>
    roadRibbon(r.line, -r.width / 2 - shoulder, r.width / 2 + shoulder),
  );
  const clipWater = subtractGround(water);
  return {
    routes,
    clipWater,
    fillTerrain(shared, near, far, mesh) {
      const outsidePlaza = subtractGround([plaza]);
      for (let i = 0; i < mesh.indices.length; i += 3) {
        const triangle = mesh.indices.slice(i, i + 3).map((index) => ({
          x: mesh.positions[index * 3],
          z: mesh.positions[index * 3 + 2],
        }));
        if (!intersectGround(triangle, plaza).length) {
          flat(shared, '#93aa77', triangle, 0);
          continue;
        }
        // Only the intersecting P0 triangles need a second representation.
        flat(far, '#93aa77', triangle, 0);
        for (const piece of outsidePlaza(triangle)) flat(near, '#93aa77', piece, 0);
      }
    },
    fillWater(batch) {
      pondSurface(batch, water, edges);
    },
    fillLand(batch, trees, solid, approach) {
      const approachMasks = approach.line.slice(1).map((b, i) => {
        const f = roadFrame(approach.line[i], b),
          h = (approach.width + 2.1) / 2;
        return rect(f, 0, f.length, -h, h);
      });
      const owners = [...water, ...approachMasks, plaza];
      for (const route of routes) {
        const clip = subtractGround(owners),
          h = route.width / 2;
        const bed = route.highway === 'service' ? '#80857e' : '#bba992';
        for (const [left, right, color] of [
          [-h - shoulder, -h, '#aba999'],
          [-h, h, bed],
          [h, h + shoulder, '#aba999'],
        ])
          for (const strip of roadRibbon(route.line, left, right))
            for (const piece of clip(strip)) flat(batch, color, piece);
        owners.push(...roadRibbon(route.line, -h - shoulder, h + shoulder));
      }
      plazaPaving(batch, plaza, trees, approachMasks);
      for (const i of [0, 4]) {
        const f = edgeFrame(plaza, i);
        bench(batch, solid, 'agora-seat-' + i, f, f.length * 0.52, -1.2);
      }
      const outsidePaving = subtractGround(owners);
      const stone = ['#ada995', '#a4a08e', '#b7b39d'];
      for (const [i, f] of edges.entries()) {
        // Flush segmented coping follows the irregular bank. Keep the junction
        // and the true water boundary open and assign only exposed land to it.
        const count = Math.ceil(f.length / 1.25);
        for (let n = 0; n < count; n++) {
          const margin = 0.34 + 0.08 * Math.sin(i + n * 2.1);
          const cap = rect(
            f,
            (n * f.length) / count + 0.02,
            ((n + 1) * f.length) / count - 0.02,
            0,
            margin,
          );
          for (const piece of outsidePaving(cap)) flat(batch, stone[(n + i) % 3], piece, Y.EDGE);
        }
      }
      // The pinned pond-surroundings study supports shade planting on the landward
      // bank. Spacing, species silhouettes and seating positions are presentation.
      for (let i = 3; i < edges.length; i++) {
        const f = edges[i];
        for (let u = 0.45 * Math.min(7, f.length); u < f.length; u += 7) {
          const p = f.at(u, 2.8 + 0.5 * Math.sin(i + u));
          if (
            !roadTreeClear(p, 1.2) ||
            [...water, plaza, ...accessMasks].some((r) => polygonOverlap(p.x, p.z, r, 1.2)) ||
            trees.some((t) => Math.hypot(t.x - p.x, t.z - p.z) < 4.7)
          )
            continue;
          trees.push({ ...p, trunkHeight: 3.15, form: [5, 8, 11].includes(i) ? 'willow' : 'bank' });
        }
      }
      const west = edges[8];
      bench(batch, solid, 'inkyung-seat-west', west, west.length * 0.55, 1.25);
    },
  };
}
