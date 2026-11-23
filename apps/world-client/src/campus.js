import * as THREE from '../vendor/three.module.js';
import { createSpatial } from './map/spatial.js';

import { canalWater } from './canal-water.js';

async function readAsset(path, format) {
  const response = await fetch(new URL('../data/' + path, import.meta.url));
  if (!response.ok) throw Error('캠퍼스 자료를 불러오지 못했습니다 (' + response.status + '): ' + path);
  return response[format]();
}
// Matte static faces have one fixed normal. Evaluate the scene's Lambert sun
// and hemisphere irradiance once per face, for either winding. The native
// material still owns fog and output color conversion on both sides.
function groundLighting(scene) {
  const sun = scene.children.find((o) => o.isDirectionalLight);
  const sky = scene.children.find((o) => o.isHemisphereLight);
  const light = sun.position.clone().sub(sun.target.position).normalize();
  const up = sky.position.clone().normalize();
  const irradiance = new THREE.Color();
  function shade(normal, sign, out) {
    const weight = (sign * normal.dot(up) + 1) / 2;
    irradiance.lerpColors(sky.groundColor, sky.color, weight).multiplyScalar(sky.intensity);
    const direct = Math.max(0, sign * normal.dot(light)) * sun.intensity;
    irradiance.r += sun.color.r * direct;
    irradiance.g += sun.color.g * direct;
    irradiance.b += sun.color.b * direct;
    irradiance.multiplyScalar(1 / Math.PI).toArray(out);
  }
  const material = new THREE.MeshBasicMaterial({ vertexColors: true, side: THREE.DoubleSide });
  material.onBeforeCompile = (shader) => {
    shader.vertexShader =
      'attribute vec3 reverseColor; varying vec3 vReverseColor;\n' +
      shader.vertexShader.replace(
        '#include <color_vertex>',
        '#include <color_vertex>\nvReverseColor=reverseColor;',
      );
    shader.fragmentShader =
      'varying vec3 vReverseColor;\n' +
      shader.fragmentShader.replace(
        '#include <color_fragment>',
        'diffuseColor.rgb *= gl_FrontFacing ? vColor.rgb : vReverseColor;',
      );
  };
  return { material, shade };
}
function meshFromBatch(bytes, range, lighting) {
  const view = new DataView(bytes, range.offset, range.count * 16);
  const points = new Float32Array(range.count * 3),
    colors = new Float32Array(points.length);
  const color = new THREE.Color();
  for (let i = 0; i < range.count; i++) {
    const j = i * 16;
    for (let k = 0; k < 3; k++) points[i * 3 + k] = view.getFloat32(j + 4 * k, true);
    color.setRGB(
      view.getUint8(j + 12) / 255,
      view.getUint8(j + 13) / 255,
      view.getUint8(j + 14) / 255,
      THREE.SRGBColorSpace,
    );
    color.toArray(colors, i * 3);
  }
  // Index shared face vertices while keeping sharp edges and independent vertex
  // colors. Draw-range offsets remain offsets in the original triangle stream.
  const positions = [],
    pigments = [],
    reverse = [],
    indices = [],
    seen = new Map();
  const a = new THREE.Vector3(),
    b = new THREE.Vector3(),
    c = new THREE.Vector3();
  const front = [],
    back = [];
  for (let i = 0; i < range.count; i += 3) {
    a.fromArray(points, 3 * i);
    b.fromArray(points, 3 * (i + 1));
    c.fromArray(points, 3 * (i + 2));
    c.sub(b).cross(a.sub(b)).normalize();
    const nx = Math.round(c.x * 32767),
      ny = Math.round(c.y * 32767),
      nz = Math.round(c.z * 32767);
    lighting.shade(c, 1, front);
    lighting.shade(c, -1, back);
    for (let j = i; j < i + 3; j++) {
      const k = j * 3;
      const key = [points[k], points[k + 1], points[k + 2], view.getUint32(16 * j + 12), nx, ny, nz].join(
        '/',
      );
      let index = seen.get(key);
      if (index === undefined) {
        index = seen.size;
        seen.set(key, index);
        positions.push(points[k], points[k + 1], points[k + 2]);
        for (let ch = 0; ch < 3; ch++) {
          pigments.push(Math.min(65535, Math.round(65535 * colors[k + ch] * front[ch])));
          reverse.push(Math.min(65535, Math.round(65535 * colors[k + ch] * back[ch])));
        }
      }
      indices.push(index);
    }
  }
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
  geo.setAttribute('color', new THREE.Uint16BufferAttribute(pigments, 3, true));
  geo.setAttribute('reverseColor', new THREE.Uint16BufferAttribute(reverse, 3, true));
  geo.setIndex(indices);
  geo.computeBoundingSphere();
  // The opaque campus batch uses matte pigments under the fixed sun and sky.
  return new THREE.Mesh(geo, lighting.material);
}
function plantTrees(scene, trees) {
  // The ground and primary crowns cover the two ends of each trunk.
  const trunk = new THREE.InstancedMesh(
    new THREE.CylinderGeometry(0.24, 0.34, 2.5, 6, 1, true),
    new THREE.MeshStandardMaterial({ color: 0x796453 }),
    trees.length,
  );
  const crown = new THREE.InstancedMesh(
    new THREE.IcosahedronGeometry(1, 1),
    new THREE.MeshLambertMaterial({ vertexColors: true }),
    trees.length,
  );
  const transform = new THREE.Object3D();
  const fineCrown = crown.geometry;
  const coarseCrown = new THREE.IcosahedronGeometry(1, 0);
  // Bake crown self-shading into the reusable templates in linear light.
  for (const g of [fineCrown, coarseCrown]) {
    const pos = g.attributes.position,
      light = [];
    for (let i = 0; i < pos.count; i++) {
      const x = pos.getX(i),
        y = pos.getY(i),
        z = pos.getZ(i);
      const v = 0.83 + 0.21 * y + 0.07 * Math.sin(x * 8 + z * 5);
      light.push(v, v * 0.99, v * 0.93);
    }
    g.setAttribute('color', new THREE.Float32BufferAttribute(light, 3));
  }
  const avenue = trees.filter((t) => !t.form);
  const branches = new THREE.InstancedMesh(coarseCrown, crown.material, avenue.length);
  const autumn = [0x879354, 0x929954, 0xb5a053, 0x6c8957, 0xa3814c, 0x87944e];
  trees.forEach(({ x, z, form, trunkHeight = 2.5 }, i) => {
    transform.position.set(x, trunkHeight / 2, z);
    transform.scale.set(1, trunkHeight / 2.5, 1);
    transform.updateMatrix();
    trunk.setMatrixAt(i, transform.matrix);
    const spread = 1 + 0.14 * Math.sin(i * 2.4);
    transform.position.y = form ? 4.68 + 0.44 * Math.cos(i) : 3.35;
    if (form === 'willow') transform.scale.set(3.0 * spread, 2.15, 2.65 * spread);
    else if (form === 'bank') transform.scale.set(2.55 * spread, 2.4, 2.35 * spread);
    else {
      transform.position.y = 3.55 + 0.27 * Math.cos(i * 0.9);
      transform.scale.set(1.8 * spread, 2 + 0.31 * Math.cos(i), 1.88 * spread);
    }
    transform.rotation.y = i * 1.9;
    transform.updateMatrix();
    crown.setMatrixAt(i, transform.matrix);
    const palette = form ? [0x80935d, 0x929d64, 0x6f8b63, 0xa1a367] : autumn;
    crown.setColorAt(i, new THREE.Color(palette[i % palette.length]));
  });
  trunk.computeBoundingSphere();
  crown.computeBoundingSphere();
  const order = avenue.map((_, i) => i).sort((a, b) => ((a * 2654435761) >>> 0) - ((b * 2654435761) >>> 0));
  for (let i = 0; i < avenue.length; i++) {
    // Interleave the two banks and the connector so a reduced density samples all rows.
    const j = order[i],
      t = avenue[j],
      angle = j * 2.4;
    transform.position.set(
      t.x + 1.03 * Math.cos(angle),
      3.45 + 0.32 * Math.sin(j),
      t.z + 0.95 * Math.sin(angle),
    );
    transform.rotation.y = angle;
    transform.scale.set(1.18 + 0.2 * Math.cos(j), 1.32, 1.16);
    transform.updateMatrix();
    branches.setMatrixAt(i, transform.matrix);
    branches.setColorAt(i, new THREE.Color(autumn[j % autumn.length]).offsetHSL(0.006, 0, 0.026));
  }
  branches.computeBoundingSphere();
  trunk.name = 'trunks';
  crown.name = 'crowns';
  branches.name = 'secondary-crowns';
  scene.add(trunk, crown, branches);
  const matrices = branches.instanceMatrix.array.slice(),
    colors = branches.instanceColor.array.slice();
  let lastX = Infinity,
    lastZ = Infinity;
  function density(detail) {
    crown.geometry = detail < 2 ? coarseCrown : fineCrown;
    lastX = Infinity;
  }
  function update(x, z, detail, distance) {
    if (Math.hypot(x - lastX, z - lastZ) < 3) return;
    lastX = x;
    lastZ = z;
    const budget = Math.floor(avenue.length * [0, 0, 0.32, 0.72, 1][detail]);
    let count = 0;
    for (let i = 0; i < budget; i++) {
      const p = avenue[order[i]];
      if (Math.hypot(p.x - x, p.z - z) > distance * 0.7) continue;
      branches.instanceMatrix.array.set(matrices.subarray(16 * i, 16 * (i + 1)), 16 * count);
      branches.instanceColor.array.set(colors.subarray(3 * i, 3 * (i + 1)), 3 * count);
      count++;
    }
    branches.instanceMatrix.needsUpdate = branches.instanceColor.needsUpdate = true;
    branches.count = count;
    branches.visible = count > 0;
  }
  return { density, update, templates: [fineCrown, coarseCrown] };
}
export async function createCampus(scene) {
  const [layout, bytes] = await Promise.all([
    readAsset('layout.json', 'json'),
    readAsset('layout.bin', 'arrayBuffer'),
  ]);
  const spatial = createSpatial(layout);
  const meshes = {};
  const lighting = groundLighting(scene);
  for (const [zone, range] of Object.entries(layout.ranges)) {
    const mesh = meshFromBatch(bytes, range, lighting);
    mesh.name = zone;
    scene.add(mesh);
    meshes[zone] = mesh;
  }
  // Fade this survey-limited model out before the player reaches the site.
  // Screen-door opacity keeps the opaque depth ordering of trees and masonry.
  const dream = meshes.dream;
  const coverage = { value: 1 };
  const dreamMaterial = dream.material = lighting.material.clone();
  const shadeDream = lighting.material.onBeforeCompile;
  dreamMaterial.onBeforeCompile = (shader) => {
    shadeDream(shader);
    shader.uniforms.dreamCoverage = coverage;
    shader.fragmentShader = 'uniform float dreamCoverage;\n' + shader.fragmentShader.replace(
      '#include <alphatest_fragment>',
      `#include <alphatest_fragment>
       if (dreamCoverage < 1.0) {
         float threshold = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
         if (threshold >= dreamCoverage) discard;
       }`,
    );
  };
  const foliage = plantTrees(scene, layout.trees);
  const region = layout.p1aLod;
  const water = canalWater(layout.obstacles.find((o) => o.id === 'site_218220690').polygon, scene.fog);
  scene.add(water.mesh);
  let visibilityX, visibilityZ;
  let distance = 110,
    detail = 3;
  return {
    ...spatial,
    releaseGpu() {
      // Dispose per-context buffers/listeners, including the inactive crown LOD.
      // Three keeps the CPU vertex/instance arrays for the incoming renderer.
      const resources = new Set(foliage.templates);
      scene.traverse((object) => {
        if (!object.isMesh) return;
        resources.add(object.geometry);
        resources.add(object.material);
        if (object.isInstancedMesh) resources.add(object);
      });
      for (const resource of resources) resource.dispose();
    },
    setProfile(profile) {
      visibilityX = undefined;
      distance = profile.distance;
      detail = profile.detail;
      foliage.density(detail);
      water.uniforms.detail.value = detail;
    },
    updateWater(seconds) {
      water.uniforms.phase.value = seconds % (Math.PI * 100);
    },
    updateVisibility(x, z) {
      if (x === visibilityX && z === visibilityZ) return;
      visibilityX = x;
      visibilityZ = z;
      foliage.update(x, z, detail, distance);
      const skyline = layout.dreamSkyline;
      const separation = Math.hypot(x - skyline.x, z - skyline.z);
      const fadeIn = THREE.MathUtils.smoothstep(separation, 21, 38);
      coverage.value = fadeIn * (1 - THREE.MathUtils.smoothstep(separation, distance - 12, distance));
      dream.visible = coverage.value > 0;
      dream.geometry.setDrawRange(0, detail >= 2 && separation < distance * 0.65
        ? layout.ranges.dream.count : skyline.silhouetteVertices);
      const close = (anchor, limit) => Math.hypot(anchor.x - x, anchor.z - z) < limit;
      if (close(region, Math.max(75, distance)))
        meshes.base.geometry.setDrawRange(region.farVertices, layout.ranges.base.count - region.farVertices);
      else meshes.base.geometry.setDrawRange(0, region.farVertices + region.sharedVertices);
      meshes.hall.visible = close(spatial.rooms['main-building'], distance);
      meshes.library.visible = close(spatial.rooms.library, distance);
      for (const [zone, { anchors, counts }] of Object.entries(layout.detailZones)) {
        const level = anchors.some((anchor) => close(anchor, distance)) ? detail : 0;
        meshes[zone].geometry.setDrawRange(0, counts[level]);
        meshes[zone].visible = counts[level] > 0;
      }
    },
  };
}
