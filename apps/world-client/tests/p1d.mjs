import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { FACILITIES } from '../map-sources/src/campus-facilities.js';
import { intersectGround, signedArea } from '../map-sources/src/ground-clipping.js';
import { createQuality, initialTier } from '../src/graphics-quality.js';
import { createSpatial } from '../src/map/spatial.js';

const layout = JSON.parse(readFileSync(new URL('../data/layout.json', import.meta.url)));
const dream = FACILITIES.find((f) => f.id === 'bldg_dream1');
test('the distant Dream Center keeps the disputed tree solid, route and open ground', () => {
  const ring = dream.rings[0];
  assert.equal(ring.length, 4);
  const body = layout.obstacles.find((o) => o.id === 'tree-58');
  assert(Math.abs(Math.abs(signedArea(intersectGround(body.polygon, ring))) - 0.32696618) < 1e-6);
  assert.equal(layout.obstacles.some((o) => o.id === dream.id), false);
  const spatial = createSpatial(layout), t = layout.trees[58];
  for (const deg of [0, 45, 90, 135, 180, 225, 270, 315]) {
    const dx = Math.cos(deg*Math.PI/180), dz = Math.sin(deg*Math.PI/180);
    const from = {x:t.x + 2*dx, z:t.z + 2*dz};
    assert(spatial.canStand(from.x, from.z));
    const stop = spatial.move(from.x, from.z, -3*dx, -3*dz);
    assert(Math.abs(Math.hypot(stop.x-t.x, stop.z-t.z) - 0.94) < 0.005);
  }
  assert(spatial.canStand(dream.footprintCenter.x, dream.footprintCenter.z));
  assert.equal(layout.dreamSkyline.x, dream.footprintCenter.x);
  assert(layout.dreamSkyline.silhouetteVertices < layout.ranges.dream.count);
});

test('30 Hz PC retains high; suspension clears mixed windows and recovery takes headroom', () => {
  const hardware = { width: 940, height: 504, dpr: 1, touch: false, maxTextureSize: 16384 };
  assert.equal(initialTier(hardware), 'high');
  assert.equal(initialTier({...hardware, width:3840, height:2160}), 'medium');
  assert.equal(initialTier({...hardware, touch:true, dpr:3}), 'low');
  const changes = [];
  const q = createQuality({device:()=>hardware, apply:(tier)=>changes.push(tier)});
  let t = 0;
  const frames = (n,ms) => { for (let i=0; i<n; i++) q.frame(t+=ms); };
  frames(500,1000/30);
  frames(80,40);
  assert.equal(q.tier,'high');
  q.resume();
  frames(65,40);
  assert.equal(q.tier,'high');
  frames(65,40);
  assert.equal(q.tier,'medium');
  frames(600,22);
  assert.equal(q.tier,'medium');
  frames(610,22);
  assert.equal(q.tier,'high');
  assert.deepEqual(changes,['high','medium','high']);
  q.select('low');
  frames(2000,16);
  assert.equal(q.tier,'low');
});
