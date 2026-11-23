// Appended only to a locally intercepted QA copy of main.js.
globalThis.dreamStudy = (data) => {
  const { indices, eye, target } = data;
  const result = {};
  for (const index of indices) {
    const trunk = scene.getObjectByName('trunks');
    const matrix = new THREE.Matrix4();
    trunk.getMatrixAt(index, matrix);
    const center = new THREE.Vector3().setFromMatrixPosition(matrix);
    const parts = {};
    for (const name of ['trunks', 'crowns', 'secondary-crowns']) {
      const m = scene.getObjectByName(name);
      for (let i = 0; i < m.count; i++) {
        if (name !== 'secondary-crowns' && i !== index) continue;
        m.getMatrixAt(i, matrix);
        const origin = new THREE.Vector3().setFromMatrixPosition(matrix);
        if (Math.hypot(origin.x-center.x, origin.z-center.z) > 1.5) continue;
        const pos = m.geometry.attributes.position, seen = new Map();
        for (let j=0; j<pos.count; j++) {
          const v = new THREE.Vector3().fromBufferAttribute(pos,j).applyMatrix4(matrix);
          seen.set(v.toArray().join('/'), v.toArray());
        }
        parts[name] = { origin:origin.toArray(), vertices:[...seen.values()] };
      }
    }
    result[index] = parts;
  }
  const direction = new THREE.Vector3().fromArray(target).sub(new THREE.Vector3().fromArray(eye));
  const ray = new THREE.Raycaster(new THREE.Vector3().fromArray(eye),direction.clone().normalize(),0,direction.length());
  const hits = ray.intersectObjects(['trunks','crowns','dream'].map(n=>scene.getObjectByName(n)).filter(m=>m?.visible))
    .map(h=>({mesh:h.object.name, instance:h.instanceId, distance:h.distance,point:h.point.toArray()}));
  return { meshes:result, sightline:{eye,target,hits} };
};
globalThis.previewAgoraLod = (far) => {
  if (far) campus.updateVisibility(0,-110);
  renderer.render(scene,camera);
  return scene.getObjectByName('base').geometry.drawRange;
};
