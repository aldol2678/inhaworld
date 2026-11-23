import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { Fog } from '../vendor/three.module.js';
import { canalWater } from '../src/canal-water.js';
import { createQuality, initialTier, profiles, readQuality } from '../src/graphics-quality.js';
import { createSpatial } from '../src/map/spatial.js';
import { spatialSource } from '../tools/spatial-source.mjs';
import { triangulatePolygon } from '../map-sources/src/reality-adapter.js';
import { FACILITIES } from '../map-sources/src/campus-facilities.js';
import { intersectGround, signedArea } from '../map-sources/src/ground-clipping.js';

const layout = JSON.parse(readFileSync(new URL('../data/layout.json', import.meta.url)));
const data = readFileSync(new URL('../data/layout.bin', import.meta.url));
const source = await spatialSource();
const body = (id) => layout.obstacles.find((o) => o.id === id);
const extra = ['bldg_lawschool', 'bldg_06', 'bldg_hawaii'];
const digest = (value) => createHash('sha256').update(JSON.stringify(value)).digest('hex');
test('P1A collision, routes, stairs and trees match the parent commit; new solids use source footprints', () => {
  // Canonical arrays at b8356ed, before adding the three new ledger-backed walls.
  assert.equal(
    digest(layout.obstacles.filter((o) => !extra.includes(o.id))),
    'd1c9879964b64842efc62f58230636846a1085b239f0864df935b5327f9cef48',
  );
  assert.equal(digest(layout.routes), '21661303a2dcfbec05c88ff4182b3af64935f32a2284bcd5d61e9fcdfb0503f6');
  assert.equal(digest(layout.stairs), '334b8df6bf6dcb35b67b05e77103000437a34bb8a1f6533f0fa4a6e817d87f94');
  assert.equal(digest(layout.trees), '30dd493b1dacf2c1b870f3d8c5ec8d91131bc1b99f938c35d26a8ddac3903809');
  for (const id of extra) {
    const f = FACILITIES.find((f) => f.id === id);
    assert.deepEqual(body(id).polygon, f.rings[0]);
    assert.equal(body(id).maxY, f.height);
  }
  const spatial = createSpatial(layout);
  for (const id of ['site_481241657', 'site_258995842', 'site_481241696']) {
    const line = layout.routes.find((r) => r.id === id).line;
    for (let i = 1; i < line.length; i++)
      for (let k = 0; k <= 100; k++) {
        const a = line[i - 1],
          b = line[i],
          x = a.x + ((b.x - a.x) * k) / 100,
          z = a.z + ((b.z - a.z) * k) / 100;
        assert(spatial.canStand(x, z), id);
      }
  }
});
test('one water quad occupies the source pool, only the existing coping covers its perimeter', (t) => {
  const ring = source.projectPolygon(source.SITE_FEATURES.find((f) => f.id === 'site_218220690').polygon);
  assert.deepEqual(body('site_218220690').polygon, ring);
  const water = canalWater(ring, new Fog(0, 85, 240)).mesh.geometry;
  const xyz = water.attributes.position;
  for (let i = 0; i < 4; i++) {
    assert(Math.abs(xyz.getX(i) - ring[i].x) < 0.00001 && Math.abs(xyz.getZ(i) - ring[i].z) < 0.00001);
    assert(Math.abs(xyz.getY(i) - 0.025) < 1e-7);
  }
  const idx = water.index.array,
    area = [0, 3].reduce(
      (sum, i) => sum + Math.abs(signedArea(Array.from(idx.slice(i, i + 3), (n) => ring[n]))),
      0,
    );
  assert(Math.abs(Math.abs(signedArea(ring)) - area) < 1e-6);
  let intrusion = 0;
  for (const { offset, count } of Object.values(layout.ranges)) {
    for (let i = 0; i < count; i += 3) {
      const tri = [0, 1, 2].map((k) => {
        const n = offset + (i + k) * 16;
        return { x: data.readFloatLE(n), y: data.readFloatLE(n + 4), z: data.readFloatLE(n + 8) };
      });
      // Ignore only the dedicated stone rim and its inset joints.
      const color = data.readUIntBE(offset + i * 16 + 12, 3);
      if ([0xc7c3b4, 0x878b7f].includes(color) && tri.every((p) => p.y <= 0.0811)) continue;
      if (
        tri.some((p) => p.y < 0.0249) ||
        tri.every((p) => p.x < 8 || p.x > 44) ||
        tri.every((p) => p.z > -15 || p.z < -75)
      )
        continue;
      intrusion += Math.abs(signedArea(intersectGround(tri, ring)));
    }
  }
  t.diagnostic(JSON.stringify({ poolAreaWU2: area, dryOverWaterWU2: intrusion }));
  assert(intrusion < 0.003, 'opaque geometry crosses the reflecting pool');
});

test('connector dressing respects all seven Agora paving edges and the thirteen lake edges', () => {
  for (const [id, count] of [
    ['lmk_agora_plaza', 7],
    ['lmk_inkyung_pond', 13],
  ]) {
    const ring = source.projectPolygon(source.LANDMARKS.find((f) => f.id === id).polygon);
    assert.equal(ring.length, count);
    const indices = triangulatePolygon(ring),
      masks = [];
    for (let i = 0; i < indices.length; i += 3) masks.push(indices.slice(i, i + 3).map((j) => ring[j]));
    let intrusion = 0;
    for (const zone of ['canal', 'connector']) {
      const r = layout.ranges[zone];
      for (let i = 0; i < r.count; i += 3) {
        const tri = [0, 1, 2].map((k) => {
          const n = r.offset + (i + k) * 16;
          return { x: data.readFloatLE(n), y: data.readFloatLE(n + 4), z: data.readFloatLE(n + 8) };
        });
        if (tri.some((p) => p.y > 0.085)) continue;
        for (const mask of masks) intrusion += Math.abs(signedArea(intersectGround(tri, mask)));
      }
    }
    assert(intrusion < 0.001, id + ' area ' + intrusion);
  }
});

function memory(initial = {}) {
  const values = new Map(Object.entries(initial));
  return { getItem: (key) => values.get(key), setItem: (key, value) => values.set(key, value) };
}
const device = () => ({ width: 1280, height: 720, dpr: 1, touch: false, maxTextureSize: 16384 });
test('legacy graphics preference restores and preserves other registry fields', () => {
  const registry = 'inhagame-device-settings-v2',
    mirror = 'inha-world-graphics-quality-v1';
  const original = {
    schemaVersion: 2,
    graphics: { quality: 'low', viewDistance: 'FAR' },
    audio: { master: 0.85 },
  };
  const storage = memory({ [registry]: JSON.stringify(original), [mirror]: 'low' });
  assert.equal(readQuality(memory({ [registry]: JSON.stringify(original), [mirror]: 'medium' })), 'medium');
  const q = createQuality({ device, storage, apply() {} });
  assert.equal(q.tier, 'low');
  for (const tier of Object.keys(profiles)) {
    q.select(tier);
    assert.equal(readQuality(storage), tier);
    assert.deepEqual(JSON.parse(storage.getItem(registry)), {
      ...original,
      graphics: { ...original.graphics, quality: tier },
    });
    assert.equal(storage.getItem(mirror), tier);
  }
  assert.equal(readQuality(memory({ [mirror]: 'very_low' })), 'very_low');
  assert.equal(readQuality(memory({ [registry]: 'broken', [mirror]: 'unknown' })), 'auto');
  assert.equal(initialTier({ ...device(), touch: true, dpr: 3 }), 'low');
});
test('auto needs sustained render windows, recovers and leaves manual selection in control', () => {
  const applied = [],
    q = createQuality({
      device,
      storage: memory(),
      apply: (tier, preference) => applied.push([tier, preference]),
    });
  let time = 0;
  const frames = (ms, n) => {
    for (let i = 0; i < n; i++) q.frame((time += ms));
  };
  q.frame(0);
  frames(16, 100);
  frames(180, 1);
  frames(16, 90);
  assert.equal(q.tier, 'high');
  frames(42, 145);
  assert.equal(q.tier, 'medium');
  frames(16, 300);
  assert.equal(q.tier, 'medium');
  frames(16, 1460);
  assert.equal(q.tier, 'high');
  q.select('ultra');
  frames(75, 1000);
  assert.equal(q.tier, 'ultra');
  q.select('auto');
  q.resume();
  frames(520, 19);
  assert.equal(q.tier, 'medium');
  assert(applied.length < 9);
});
