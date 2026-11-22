// Reality Base Runtime Adapter: bridges canonical WGS84 reality data to PlayCanvas runtime.
// Canonical source: apps/world/data/reality/campus-landmarks.json.
// Coordinates stay in canonical data; runtime geometry is derived here.

import { geoToWorld } from "./geo-coordinates.js";
/** Project a closed WGS84 [lat, lon] ring without inventing or shifting vertices. */
export function projectPolygon(polygon, project = geoToWorld, { closed = false } = {}) {
  if (!Array.isArray(polygon) || polygon.length < 4 || polygon.some(p =>
    !Array.isArray(p) || p.length !== 2 || !p.every(Number.isFinite) ||
    Math.abs(p[0]) > 90 || Math.abs(p[1]) > 180)) {
    throw new Error("Expected a finite WGS84 polygon ring");
  }
  const first = polygon[0], last = polygon.at(-1);
  if (first[0] !== last[0] || first[1] !== last[1]) throw new Error("Polygon ring must be closed");
  const vertices = (closed ? polygon : polygon.slice(0, -1)).map(([lat, lon]) => project(lat, lon));
  if (vertices.some(p => !Number.isFinite(p.x) || !Number.isFinite(p.z))) {
    throw new Error("Polygon projection must be finite");
  }
  return vertices;
}
const turn = (a, b, c) => (b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x);
/** Ear clipping for simple concave/convex rings, either winding, no holes.
 * Returns clockwise X/Z triangles so their 3D normals point upward.
 * A fan would fill areas outside the concave pond shoreline.
 */
export function triangulatePolygon(vertices) {
  const eps = 1e-9;
  if (vertices.length < 3 || vertices.some(p => !Number.isFinite(p.x) || !Number.isFinite(p.z))) {
    throw new Error("Expected finite polygon vertices");
  }
  if (new Set(vertices.map(p => `${p.x},${p.z}`)).size !== vertices.length) {
    throw new Error("Expected unique polygon vertices without closure");
  }
  const onSegment = (a, b, p) => Math.abs(turn(a, b, p)) <= eps &&
    p.x >= Math.min(a.x, b.x) - eps && p.x <= Math.max(a.x, b.x) + eps &&
    p.z >= Math.min(a.z, b.z) - eps && p.z <= Math.max(a.z, b.z) + eps;
  for (let i = 0; i < vertices.length; i++) {
    const a = vertices[i], b = vertices[(i + 1) % vertices.length];
    for (let j = i + 1; j < vertices.length; j++) {
      if (j === i + 1 || (i === 0 && j === vertices.length - 1)) continue;
      const c = vertices[j], d = vertices[(j + 1) % vertices.length];
      if ((turn(a, b, c) * turn(a, b, d) < 0 && turn(c, d, a) * turn(c, d, b) < 0) ||
        onSegment(a, b, c) || onSegment(a, b, d) || onSegment(c, d, a) || onSegment(c, d, b)) {
        throw new Error("Polygon must not self-intersect");
      }
    }
  }
  const signedArea2 = vertices.reduce((sum, p, i) => {
    const q = vertices[(i + 1) % vertices.length];
    return sum + p.x * q.z - q.x * p.z;
  }, 0);
  if (Math.abs(signedArea2) <= eps) throw new Error("Degenerate polygon");
  const remaining = vertices.map((_, i) => i);
  if (signedArea2 > 0) remaining.reverse();
  const triangles = [];
  while (remaining.length > 3) {
    let clipped = false;
    for (let i = 0; i < remaining.length; i++) {
      const a = remaining[(i + remaining.length - 1) % remaining.length];
      const b = remaining[i], c = remaining[(i + 1) % remaining.length];
      if (turn(vertices[a], vertices[b], vertices[c]) >= -eps) continue;
      if (remaining.some(p => p !== a && p !== b && p !== c &&
        turn(vertices[a], vertices[b], vertices[p]) <= eps &&
        turn(vertices[b], vertices[c], vertices[p]) <= eps &&
        turn(vertices[c], vertices[a], vertices[p]) <= eps)) continue;
      triangles.push(a, b, c);
      remaining.splice(i, 1);
      clipped = true;
      break;
    }
    if (!clipped) throw new Error("Cannot triangulate polygon without changing its boundary");
  }
  if (turn(...remaining.map(i => vertices[i])) >= -eps) throw new Error("Degenerate final triangle");
  return triangles.concat(remaining);
}
