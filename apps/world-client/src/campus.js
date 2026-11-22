import * as THREE from '../vendor/three.module.js';
import { createSpatial } from './map/spatial.js';

const DETAIL_DISTANCE = 110;

async function readAsset(path, format) {
  const response = await fetch(new URL('../data/' + path, import.meta.url));
  if (!response.ok) throw Error('캠퍼스 자료를 불러오지 못했습니다 (' + response.status + '): ' + path);
  return response[format]();
}
function meshFromBatch(bytes, range) {
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
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.BufferAttribute(points, 3));
  geo.setAttribute('color', new THREE.BufferAttribute(colors, 3));
  geo.computeVertexNormals();
  geo.computeBoundingSphere();
  return new THREE.Mesh(
    geo,
    new THREE.MeshStandardMaterial({ vertexColors: true, roughness: 0.91, side: THREE.DoubleSide }),
  );
}
function plantTrees(scene, trees) {
  const trunk = new THREE.InstancedMesh(
    new THREE.CylinderGeometry(0.24, 0.34, 2.5, 7),
    new THREE.MeshStandardMaterial({ color: 0x796453 }),
    trees.length,
  );
  const willowLobes = 4;
  const extraCrowns = trees.filter(t => t.form === 'willow').length * willowLobes;
  const crown = new THREE.InstancedMesh(
    new THREE.IcosahedronGeometry(1, 1),
    new THREE.MeshStandardMaterial({ roughness: 1 }),
    trees.length + extraCrowns,
  );
  const transform = new THREE.Object3D();
  let lobe = trees.length;
  trees.forEach(({ x, z, form, trunkHeight = 2.5 }, i) => {
    transform.position.set(x, trunkHeight / 2, z);
    transform.scale.set(1, trunkHeight / 2.5, 1);
    transform.updateMatrix();
    trunk.setMatrixAt(i, transform.matrix);
    const spread = 1 + 0.14 * Math.sin(i * 2.4);
    transform.position.y = form ? 4.32 + 0.2 * Math.cos(i) : 3.35;
    if (form === 'willow') transform.scale.set(3.0 * spread, 1.65, 2.65 * spread);
    else if (form === 'bank') transform.scale.set(2.05 * spread, 1.95, 1.9 * spread);
    else transform.scale.set(1.55, 2.05, 1.6);
    transform.rotation.y = i * 1.9;
    transform.updateMatrix();
    crown.setMatrixAt(i, transform.matrix);
    crown.setColorAt(i, new THREE.Color(form === 'willow' ? 0x708963 : [0x537c55, 0x628153, 0x77935e][i % 3]));
    if (form === 'willow') {
      for (let j = 0; j < willowLobes; j++) {
        const angle = i + j * 2 * Math.PI / willowLobes;
        transform.position.set(x + 2.0 * spread * Math.cos(angle), 3.82, z + 1.88 * spread * Math.sin(angle));
        transform.scale.set(0.92, 1.58, 0.81);
        transform.updateMatrix();
        crown.setMatrixAt(lobe, transform.matrix);
        crown.setColorAt(lobe++, new THREE.Color(j % 2 ? 0x69835e : 0x789367));
      }
    }
  });
  trunk.computeBoundingSphere();
  crown.computeBoundingSphere();
  scene.add(trunk, crown);
  return (near, firstTree) => {
    trunk.count = near ? trees.length : firstTree;
    crown.count = near ? trees.length + extraCrowns : firstTree;
  };
}
export async function createCampus(scene) {
  const [layout, bytes] = await Promise.all([
    readAsset('layout.json', 'json'),
    readAsset('layout.bin', 'arrayBuffer'),
  ]);
  const spatial = createSpatial(layout),
    details = [];
  let baseGeometry;
  for (const [zone, range] of Object.entries(layout.ranges)) {
    const mesh = meshFromBatch(bytes, range);
    mesh.name = zone;
    scene.add(mesh);
    if (zone === 'base') baseGeometry = mesh.geometry;
    else
      details.push({ mesh, anchor: spatial.rooms[zone === 'hall' ? 'main-building' : 'library'] });
  }
  const updateTrees = plantTrees(scene, layout.trees);
  const region = layout.p1aLod;
  return {
    ...spatial,
    updateVisibility(x, z) {
      if (region) {
        const near = Math.hypot(x - region.x, z - region.z) < DETAIL_DISTANCE;
        if (near) baseGeometry.setDrawRange(region.farVertices, layout.ranges.base.count - region.farVertices);
        else baseGeometry.setDrawRange(0, region.farVertices + region.sharedVertices);
        updateTrees(near, region.firstTree);
      }
      for (const { mesh, anchor } of details)
        mesh.visible = Math.hypot(anchor.x - x, anchor.z - z) < DETAIL_DISTANCE;
    },
  };
}
