// Build-only P1A surfaces. Polygons and way nodes are GIS inputs; all dressing is estimated.
import access from '../map-sources/data/reality/evidence/roads/agora-inkyung.json' with { type: 'json' };
import { FACILITIES } from '../map-sources/src/campus-facilities.js';
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
  const footprint = rect(f, u - hw, u + hw, v - hd, v + hd);
  solid(id, footprint, CAMPUS_GRADE, CAMPUS_GRADE + 0.68);
  return footprint;
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

// The outer mortar line meets at the bisector of adjacent source edges. Each
// cap shares its two end vertices with the next cap, including the closing joint.
function shoreCoping(batch, pond, edges, clip) {
  const outer = pond.map((p, i) => {
    const before = edges[(i + edges.length - 1) % edges.length];
    const a = before.at(before.length, 1), b = edges[i].at(0, 1);
    const ax = a.x - p.x, az = a.z - p.z, bx = b.x - p.x, bz = b.z - p.z;
    const scale = 0.34 / (1 + ax * bx + az * bz);
    return { x: p.x + (ax + bx) * scale, z: p.z + (az + bz) * scale };
  });
  const stone = ['#a8a594', '#b8b2a0', '#b0aa98', '#a7a497'];
  edges.forEach((edge, i) => {
    const j = (i + 1) % edges.length, count = Math.ceil(edge.length / 1.25);
    for (let n = 0; n < count; n++) {
      const start = n / count, end = (n + 1) / count;
      const cap = [mix(pond[i], pond[j], start), mix(pond[i], pond[j], end),
        mix(outer[i], outer[j], end), mix(outer[i], outer[j], start)];
      for (const piece of clip(cap)) flat(batch, stone[(i + n) % stone.length], piece, Y.EDGE);
    }
  });
}

const foliage = [
  ['#3e5b48', '#688757', '#99a36c'], ['#465f43', '#7c9254', '#a9ac6d'],
  ['#3e5b50', '#678969', '#92a677'], ['#536947', '#899558', '#b3ac75'],
];

// Bake asymmetric crowns with lighter upper leaves into the near static batch.
// Short shrubs end at grade, taller crowns also have a visible underside.
function leafCluster(batch, x, y, z, rx, ry, rz, seed, sides) {
  const [shade, leaf, tip] = foliage[seed % foliage.length];
  const bottom = [[x, y - ry, z], shade], top = [[x + rx * 0.12, y + ry, z], tip];
  function ring(radius, level, twist, color) {
    return Array.from({ length: sides }, (_, i) => {
      const a = seed + twist + (i * Math.PI * 2) / sides;
      const r = radius * (1 + 0.12 * Math.sin(3 * a + seed));
      return [[x + rx * r * Math.cos(a), y + ry * (level + 0.12 * Math.sin(2 * a)),
        z + rz * r * Math.sin(a)], color];
    });
  }
  const low = ring(0.78, -0.62, 0, shade), belt = ring(1, 0.10, 0.20, leaf);
  const high = ring(0.65, 0.76, 0.36, tip);
  if (y <= ry) low.forEach(([position]) => { position[1] = 0; });
  for (let i = 0; i < sides; i++) {
    const j = (i + 1) % sides;
    if (y > ry) batch.coloredTriangle(bottom, low[i], low[j]);
    for (const [a, b] of [[low, belt], [belt, high]]) {
      batch.coloredTriangle(a[i], b[i], b[j]);
      batch.coloredTriangle(a[i], b[j], a[j]);
    }
    batch.coloredTriangle(high[i], top, high[j]);
  }
}

function bankPlanting(batch, trees, routes, owners, shoulder) {
  const exclude = [...owners, ...FACILITIES.filter(f => f.kind === 'building').flatMap(f => f.rings.slice(0, 1))];
  const clear = (x, z, r) => !exclude.some(ring => polygonOverlap(x, z, ring, r));
  trees.forEach(({ x, z, form }, i) => {
    if (!form) return;
    const willow = form === 'willow';
    const count = willow ? 4 : 3;
    for (let j = 0; j < count; j++) {
      const a = i + (j * 2 * Math.PI) / count;
      const height = (willow ? 4.35 : 5.1) + 0.98 * Math.sin(2 * a);
      const cx = x + 1.7 * Math.cos(a), cz = z + 1.6 * Math.sin(a);
      if (!clear(cx, cz, 2.05)) continue;
      leafCluster(batch, cx, height, cz, 1.5 + 0.24 * Math.cos(a),
        willow ? 1.72 : 1.27, 1.42, i * 3 + j, 7);
    }
    // Low, irregular planting between the trunks also frames the opposite bank
    // at eye level. Leave dry openings for the seat and the walking surfaces.
    const next = trees[i + 1];
    if (next?.form) {
      const p = mix({ x, z }, next, 0.40 + 0.12 * Math.sin(i));
      if (clear(p.x, p.z, 1.90) && roadTreeClear(p, 1.7))
        leafCluster(batch, p.x, 0.78, p.z, 1.63, 0.94, 1.37, i + 2, 7);
    }
  });
  // Low planting uses only dry verges. None of these soft clusters creates a
  // trunk, moves a bench or implies a surveyed planting position.
  let seed = 0;
  for (const route of routes) {
    route.line.slice(1).forEach((b, i) => {
      const f = roadFrame(route.line[i], b);
      for (let u = 2.2; u < f.length - 1; u += 4.7 + 1.25 * Math.sin(u)) {
        for (const side of [-1, 1]) {
          const index = seed++, radius = 0.83 + 0.24 * Math.cos(index * 1.7);
          const p = f.at(u, side * (route.width / 2 + shoulder + radius + 0.46));
          if (!roadTreeClear(p, radius) || !clear(p.x, p.z, radius + 0.2)) continue;
          leafCluster(batch, p.x, 0.40, p.z, radius, 0.49 + 0.09 * Math.sin(index), radius, index, 6);
        }
      }
    });
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
    plaza,
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
      shoreCoping(batch, pond, edges, subtractGround(owners));
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
      const seat = bench(batch, solid, 'inkyung-seat-west', west, west.length * 0.55, 1.25);
      bankPlanting(batch, trees, routes, [...owners, seat], shoulder);
    },
  };
}
