// Check the served triangles as well as the navigation data; dry grass can hide
// the lake in the renderer even when the capsule collision polygon is correct.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import evidence from '../map-sources/data/reality/evidence/roads/agora-inkyung.json' with { type: 'json' };
import { intersectGround, signedArea } from '../map-sources/src/ground-clipping.js';
import { roadFrame } from '../map-sources/src/campus-road-layout.js';
import { edgeFrame } from '../map-sources/src/roadview-layout.js';
import { FACILITIES } from '../map-sources/src/campus-facilities.js';
import { spatialSource } from '../tools/spatial-source.mjs';
import { createSpatial, CAMPUS_GRADE } from '../src/map/spatial.js';
import { triangulatePolygon } from '../map-sources/src/reality-adapter.js';

const layout = JSON.parse(readFileSync(new URL('../data/layout.json', import.meta.url)));
const packed = readFileSync(new URL('../data/layout.bin', import.meta.url));
const source = await spatialSource();
const spatial = createSpatial(layout);
const footprint = (id) => source.projectPolygon(source.LANDMARKS.find((l) => l.id === id).polygon);
const lake = footprint('lmk_inkyung_pond'),
  plaza = footprint('lmk_agora_plaza');
const allTriangles = [];
for (let i = 0; i < layout.ranges.base.count; i += 3) {
  const points = [0, 1, 2].map((k) => {
    const start = layout.ranges.base.offset + (i + k) * 16;
    return {
      x: packed.readFloatLE(start),
      y: packed.readFloatLE(start + 4),
      z: packed.readFloatLE(start + 8),
      rgb: packed.readUIntBE(start + 12, 3),
    };
  });
  allTriangles.push(points);
}
const { farVertices, sharedVertices } = layout.p1aLod;
const bufferTriangles = allTriangles.slice(farVertices / 3);
const farTriangles = allTriangles.slice(0, (farVertices + sharedVertices) / 3);

test('source nodes connect P0, the lakeside service way and its sidewalk on walkable grade', () => {
  const routes = evidence.ways.map((way) => {
    const route = layout.routes.find((r) => r.sourceId === 'osm_way_' + way.id);
    assert.equal(way.surveyedWidthM, null);
    assert.equal(route.highway, way.highway);
    assert.equal(route.sourceVersion, way.version);
    assert.deepEqual(
      route.line,
      way.nodes.map(([, lat, lon]) => source.geoToWorld(lat, lon)),
    );
    for (let i = 1; i < route.line.length; i++) {
      const a = route.line[i - 1],
        b = route.line[i];
      for (let j = 0; j <= 100; j++) {
        const x = a.x + ((b.x - a.x) * j) / 100,
          z = a.z + ((b.z - a.z) * j) / 100;
        assert(spatial.canStand(x, z), route.id);
        assert.equal(spatial.groundHeight(x, z), CAMPUS_GRADE);
      }
      // The middle of each segment must actually have the right rendered bed.
      const frame = roadFrame(a, b);
      const strip = [
        frame.at(frame.length / 2 - 0.05, -0.05),
        frame.at(frame.length / 2 + 0.05, -0.05),
        frame.at(frame.length / 2 + 0.05, 0.05),
        frame.at(frame.length / 2 - 0.05, 0.05),
      ];
      const color = way.highway === 'service' ? 0x80857e : 0xbba992;
      const covered = bufferTriangles
        .filter((t) => t[0].rgb === color)
        .reduce((area, t) => area + Math.abs(signedArea(intersectGround(t, strip))), 0);
      assert(Math.abs(covered - 0.01) < 1e-6, route.id);
    }
    return route;
  });
  assert.deepEqual(routes[0].line[0], layout.routes.find((r) => r.id === 'site_481241696').line.at(-2));
  assert.deepEqual(routes[0].line[1], routes[1].line[0]);
  assert.deepEqual(layout.rooms['main-gate'].spatialId, 'lmk_main_gate');
  assert.equal(layout.p1aLod.firstTree, 60);
  assert(layout.trees.slice(layout.p1aLod.firstTree).some((t) => t.form === 'willow'));
});

test('only water occupies the source lake and a single surface owns the mapped plaza', (t) => {
  const indices = triangulatePolygon(lake),
    masks = [];
  for (let i = 0; i < indices.length; i += 3) masks.push(indices.slice(i, i + 3).map((j) => lake[j]));
  const xs = [...lake, ...plaza].map((p) => p.x),
    zs = [...lake, ...plaza].map((p) => p.z);
  const minX = Math.min(...xs),
    maxX = Math.max(...xs),
    minZ = Math.min(...zs),
    maxZ = Math.max(...zs);
  for (const [lod, triangles] of [['near', bufferTriangles], ['far', farTriangles]]) {
    let water = 0,
      dry = 0,
      plazaFloor = 0;
    for (const t of triangles) {
      if (
        t.every((p) => p.x < minX) ||
        t.every((p) => p.x > maxX) ||
        t.every((p) => p.z < minZ) ||
        t.every((p) => p.z > maxZ) ||
        Math.abs(signedArea(t)) < 1e-9
      )
        continue;
      const overlap = masks.reduce((n, mask) => n + Math.abs(signedArea(intersectGround(t, mask))), 0);
      const at = (height) => t.every((p) => Math.abs(p.y - height) < 1e-6);
      if (at(0.025)) water += overlap;
      else if (at(0.031) && t[0].rgb === 0x609493) {
        assert(Math.abs(overlap - Math.abs(signedArea(t))) < 1e-5, 'ripple beyond shore');
      } else dry += overlap;
      // Tile, surround and well interiors plus the existing 696 shoulder/bed underlay.
      if (at(0.022) || at(0.032)) plazaFloor += Math.abs(signedArea(intersectGround(t, plaza)));
    }
    // Baked coordinates are Float32 while the source rings are Float64.
    assert(Math.abs(water - Math.abs(signedArea(lake))) < 0.002, 'water area ' + water);
    assert(dry < 0.002, 'dry surface inside lake ' + dry);
    assert(Math.abs(plazaFloor - Math.abs(signedArea(plaza))) < 0.002, 'plaza area ' + plazaFloor);
    t.diagnostic(JSON.stringify({ lod, waterAreaWU2: water, dryInsideLakeWU2: dry, plazaFloorWU2: plazaFloor }));
  }
});

test('each shoreline edge stops a swept capsule and every seat has a solid base', (t) => {
  const clearance = [];
  const body = layout.obstacles.find((o) => o.id === 'lmk_inkyung_pond');
  assert.deepEqual(body.polygon, lake);
  for (let i = 0; i < lake.length; i++) {
    const f = edgeFrame(lake, i);
    const u = [0.26, 0.52, 0.76]
      .map((t) => t * f.length)
      .find((u) => {
        const p = f.at(u, 1.45);
        return spatial.canStand(p.x, p.z);
      });
    assert.notEqual(u, undefined, 'dry approach on edge ' + i);
    const start = f.at(u, 1.45),
      target = f.at(u, -1.45);
    assert.equal(spatial.canStand(target.x, target.z), false);
    const stop = spatial.move(start.x, start.z, target.x - start.x, target.z - start.z);
    assert(spatial.canStand(stop.x, stop.z));
    clearance.push(f.local(stop).out);
    assert(clearance[i] >= 0.599, 'capsule crossed edge ' + i);
  }
  t.diagnostic(JSON.stringify({ edgeClearanceWU: clearance }));
  for (const id of ['agora-seat-0', 'agora-seat-4', 'inkyung-seat-west']) {
    const seat = layout.obstacles.find((o) => o.id === id);
    const x = seat.polygon.reduce((s, p) => s + p.x, 0) / 4,
      z = seat.polygon.reduce((s, p) => s + p.z, 0) / 4;
    assert.equal(seat.minY, spatial.groundHeight(x, z));
    assert.equal(spatial.canStand(x, z), false);
  }
});

test('the two lake-facing shells use the ledger roofs and keep the east footway entrance open', () => {
  for (const id of ['bldg_02_south', 'bldg_07']) {
    const { rings: [ring], height } = FACILITIES.find(f => f.id === id);
    const solid = layout.obstacles.find(o => o.id === id);
    const area = Math.abs(signedArea(ring));
    const recessArea = area - Math.abs(signedArea(solid.polygon));
    if (id === 'bldg_02_south') assert.deepEqual(solid.polygon, ring);
    else assert(recessArea > 0 && recessArea < 4, 'only the entrance clearance is recessed');
    assert.equal(solid.maxY, height);
    const roof = bufferTriangles.filter(t => t.every(p => p.y === height && p.rgb === 0xa9aaa0));
    const roofArea = roof.reduce((sum, t) => sum + Math.abs(signedArea(t)), 0);
    assert(Math.abs(roofArea - area) < 0.002, `roof footprint ${id}`);
    // The area centroid of a concave building can lie outside its walls.
    const triangle = triangulatePolygon(ring).slice(0, 3).map(i => ring[i]);
    const inside = triangle.reduce((p, v) => ({ x: p.x + v.x / 3, z: p.z + v.z / 3 }), { x: 0, z: 0 });
    assert(!spatial.canStand(inside.x, inside.z));
  }
  const [start, end] = layout.routes.find(r => r.id === 'site_1063267429').line;
  const f = roadFrame(start, end);
  const backWall = f.at(f.length + 3);
  const stop = spatial.move(end.x, end.z, backWall.x - end.x, backWall.z - end.z);
  assert(spatial.canStand(end.x, end.z) && spatial.canStand(stop.x, stop.z));
  assert(Math.hypot(stop.x - end.x, stop.z - end.z) < 1.2);
  assert(!spatial.canStand(backWall.x, backWall.z));
});
