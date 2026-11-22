// Check the served triangles as well as the navigation data; dry grass can hide
// the lake in the renderer even when the capsule collision polygon is correct.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import evidence from '../map-sources/data/reality/evidence/roads/agora-inkyung.json' with { type: 'json' };
import { intersectGround, signedArea } from '../map-sources/src/ground-clipping.js';
import { roadFrame } from '../map-sources/src/campus-road-layout.js';
import { edgeFrame } from '../map-sources/src/roadview-layout.js';
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
const bufferTriangles = [];
for (let i = layout.p1aLod.farVertices; i < layout.ranges.base.count; i += 3) {
  const points = [0, 1, 2].map((k) => {
    const start = layout.ranges.base.offset + (i + k) * 16;
    return {
      x: packed.readFloatLE(start),
      y: packed.readFloatLE(start + 4),
      z: packed.readFloatLE(start + 8),
      rgb: packed.readUIntBE(start + 12, 3),
    };
  });
  bufferTriangles.push(points);
}

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

test('only water occupies the source lake and a single surface owns the mapped plaza', () => {
  const indices = triangulatePolygon(lake),
    masks = [];
  for (let i = 0; i < indices.length; i += 3) masks.push(indices.slice(i, i + 3).map((j) => lake[j]));
  let water = 0,
    dry = 0,
    plazaFloor = 0;
  const xs = [...lake, ...plaza].map((p) => p.x),
    zs = [...lake, ...plaza].map((p) => p.z);
  const minX = Math.min(...xs),
    maxX = Math.max(...xs),
    minZ = Math.min(...zs),
    maxZ = Math.max(...zs);
  for (const t of bufferTriangles) {
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
});

test('each shoreline edge stops a swept capsule and every seat has a solid base', () => {
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
    assert(f.local(stop).out >= 0.599, 'capsule crossed edge ' + i);
  }
  for (const id of ['agora-seat-0', 'agora-seat-4', 'inkyung-seat-west']) {
    const seat = layout.obstacles.find((o) => o.id === id);
    const x = seat.polygon.reduce((s, p) => s + p.x, 0) / 4,
      z = seat.polygon.reduce((s, p) => s + p.z, 0) / 4;
    assert.equal(seat.minY, spatial.groundHeight(x, z));
    assert.equal(spatial.canStand(x, z), false);
  }
});
