// Horizontal surface ownership in X/Z. Each mask and input piece is convex.
const EPSILON = 1e-8;
const cross = (a, b, p) => (b.x - a.x) * (p.z - a.z) - (b.z - a.z) * (p.x - a.x);
export function signedArea(ring) {
  return (
    ring.reduce((sum, p, i) => {
      const next = ring[(i + 1) % ring.length];
      return sum + p.x * next.z - next.x * p.z;
    }, 0) / 2
  );
}
const counterclockwise = (ring) => (signedArea(ring) < 0 ? [...ring].reverse() : ring);
const bounds = (ring) => ({
  minX: Math.min(...ring.map((p) => p.x)),
  maxX: Math.max(...ring.map((p) => p.x)),
  minZ: Math.min(...ring.map((p) => p.z)),
  maxZ: Math.max(...ring.map((p) => p.z)),
});
const overlaps = (a, b) =>
  a.minX < b.maxX - EPSILON &&
  a.maxX > b.minX + EPSILON &&
  a.minZ < b.maxZ - EPSILON &&
  a.maxZ > b.minZ + EPSILON;
const hasArea = (ring) => ring.length >= 3 && Math.abs(signedArea(ring)) > EPSILON;

function halfPlane(ring, a, b, inside) {
  const out = [];
  for (let i = 0; i < ring.length; i++) {
    const p = ring[i],
      q = ring[(i + 1) % ring.length];
    const dp = cross(a, b, p) * (inside ? 1 : -1),
      dq = cross(a, b, q) * (inside ? 1 : -1);
    const pin = dp >= -EPSILON,
      qin = dq >= -EPSILON;
    if (pin) out.push(p);
    if (pin !== qin) {
      const t = dp / (dp - dq);
      out.push({ x: p.x + (q.x - p.x) * t, z: p.z + (q.z - p.z) * t });
    }
  }
  return out.filter((p, i) => {
    const q = out[(i + 1) % out.length];
    return Math.hypot(p.x - q.x, p.z - q.z) > EPSILON;
  });
}

export function intersectGround(ring, boundary) {
  const mask = counterclockwise(boundary);
  for (let i = 0; i < mask.length && ring.length >= 3; i++)
    ring = halfPlane(ring, mask[i], mask[(i + 1) % mask.length], true);
  return hasArea(ring) ? ring : [];
}

export function subtractGround(rings) {
  const masks = rings.map((ring) => ({ ring: counterclockwise(ring), bounds: bounds(ring) }));
  return (ring) => {
    let pieces = [ring];
    for (const mask of masks) {
      const next = [];
      for (const piece of pieces) {
        if (!overlaps(bounds(piece), mask.bounds)) {
          next.push(piece);
          continue;
        }
        let remainder = piece;
        for (let i = 0; i < mask.ring.length && remainder.length >= 3; i++) {
          const a = mask.ring[i],
            b = mask.ring[(i + 1) % mask.ring.length];
          const outside = halfPlane(remainder, a, b, false);
          if (hasArea(outside)) next.push(outside);
          remainder = halfPlane(remainder, a, b, true);
        }
      }
      pieces = next;
    }
    return pieces;
  };
}
