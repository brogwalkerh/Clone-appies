/**
 * Pointy-top hex geometry with odd-r offset coordinates `[row, col]`
 * (odd rows shifted half a hex to the right).
 *
 * Vertex ids: every vertex of a pointy-top grid is the N (top) corner of exactly
 * one hex or the S (bottom) corner of exactly one hex — possibly a hex just
 * outside the grid. We therefore id vertices as `N(r,c)` / `S(r,c)` and derive
 * everything else (corners of a hex, neighbours of a vertex) from that.
 */

import type { HexCoord, HexKey, NodeId } from '../types.js';

/** Hex height in units of hex width (pointy-top). */
export const HEX_HEIGHT = 2 / Math.sqrt(3);

export function hexKey(h: HexCoord): HexKey {
  return `${h[0]},${h[1]}`;
}

export function parseHexKey(key: string): HexCoord {
  const m = /^\s*\[?\s*(-?\d+)\s*,\s*(-?\d+)\s*\]?\s*$/.exec(key);
  if (!m) throw new Error(`Bad hex key: ${key}`);
  return [Number(m[1]), Number(m[2])];
}

export function hexEquals(a: HexCoord, b: HexCoord): boolean {
  return a[0] === b[0] && a[1] === b[1];
}

function isOdd(r: number): boolean {
  return (r & 1) === 1;
}

export function upperLeft([r, c]: HexCoord): HexCoord {
  return isOdd(r) ? [r - 1, c] : [r - 1, c - 1];
}
export function upperRight([r, c]: HexCoord): HexCoord {
  return isOdd(r) ? [r - 1, c + 1] : [r - 1, c];
}
export function lowerLeft([r, c]: HexCoord): HexCoord {
  return isOdd(r) ? [r + 1, c] : [r + 1, c - 1];
}
export function lowerRight([r, c]: HexCoord): HexCoord {
  return isOdd(r) ? [r + 1, c + 1] : [r + 1, c];
}

/** The 6 neighbouring hexes, clockwise from the upper-right. */
export function hexNeighbors(h: HexCoord): HexCoord[] {
  const [r, c] = h;
  return [upperRight(h), [r, c + 1], lowerRight(h), lowerLeft(h), [r, c - 1], upperLeft(h)];
}

export function hexesAdjacent(a: HexCoord, b: HexCoord): boolean {
  return hexNeighbors(a).some((n) => hexEquals(n, b));
}

/** Hex centre in hex-width units (y grows downwards). */
export function hexCenter([r, c]: HexCoord): { x: number; y: number } {
  return { x: c + (isOdd(r) ? 0.5 : 0) + 0.5, y: r * 0.75 * HEX_HEIGHT + HEX_HEIGHT / 2 };
}

export type VertexKind = 'N' | 'S';

export function vertexId(kind: VertexKind, [r, c]: HexCoord): NodeId {
  return `${kind}(${r},${c})`;
}

export function parseVertexId(id: NodeId): { kind: VertexKind; hex: HexCoord } {
  const m = /^([NS])\((-?\d+),(-?\d+)\)$/.exec(id);
  if (!m) throw new Error(`Bad vertex id: ${id}`);
  return { kind: m[1] as VertexKind, hex: [Number(m[2]), Number(m[3])] };
}

export function vertexPosition(id: NodeId): { x: number; y: number } {
  const { kind, hex } = parseVertexId(id);
  const c = hexCenter(hex);
  return { x: c.x, y: kind === 'N' ? c.y - HEX_HEIGHT / 2 : c.y + HEX_HEIGHT / 2 };
}

/** The 6 corner vertex ids of a hex, clockwise from the top: N, NE, SE, S, SW, NW. */
export function hexCorners(h: HexCoord): NodeId[] {
  return [
    vertexId('N', h),
    vertexId('S', upperRight(h)),
    vertexId('N', lowerRight(h)),
    vertexId('S', h),
    vertexId('N', lowerLeft(h)),
    vertexId('S', upperLeft(h)),
  ];
}

/** The 6 sides of a hex as vertex pairs, in corner order. */
export function hexSides(h: HexCoord): [NodeId, NodeId][] {
  const c = hexCorners(h);
  return c.map((v, i) => [v, c[(i + 1) % 6] as NodeId] as [NodeId, NodeId]);
}

/** The 3 vertices joined to a vertex by a hex side. */
export function vertexNeighbors(id: NodeId): NodeId[] {
  const { kind, hex } = parseVertexId(id);
  const [r, c] = hex;
  return kind === 'N'
    ? [vertexId('S', upperLeft(hex)), vertexId('S', upperRight(hex)), vertexId('S', [r - 2, c])]
    : [vertexId('N', lowerLeft(hex)), vertexId('N', lowerRight(hex)), vertexId('N', [r + 2, c])];
}

/** The 3 hexes that meet at a vertex. */
export function vertexHexes(id: NodeId): HexCoord[] {
  const { kind, hex } = parseVertexId(id);
  return kind === 'N' ? [hex, upperLeft(hex), upperRight(hex)] : [hex, lowerLeft(hex), lowerRight(hex)];
}

export function inGrid(h: HexCoord, rows: number, cols: number): boolean {
  return h[0] >= 0 && h[0] < rows && h[1] >= 0 && h[1] < cols;
}

/** Canonical undirected edge key: smaller id first. */
export function edgeKey(a: NodeId, b: NodeId): string {
  return a < b ? `${a}|${b}` : `${b}|${a}`;
}

/**
 * The single vertex shared by three mutually adjacent hexes (a tri-lobe centre).
 * Throws if the hexes do not meet at one point.
 */
export function sharedVertex(lobes: readonly HexCoord[]): NodeId {
  if (lobes.length !== 3) throw new Error(`sharedVertex: expected 3 lobes, got ${lobes.length}`);
  const [a, b, c] = lobes as [HexCoord, HexCoord, HexCoord];
  const setB = new Set(hexCorners(b));
  const setC = new Set(hexCorners(c));
  const common = hexCorners(a).filter((v) => setB.has(v) && setC.has(v));
  if (common.length !== 1) {
    throw new Error(`sharedVertex: lobes ${lobes.map(hexKey).join(' ')} share ${common.length} vertices, expected 1`);
  }
  return common[0] as NodeId;
}

/** The two vertices of the side shared by two adjacent hexes. */
export function sharedSide(a: HexCoord, b: HexCoord): [NodeId, NodeId] {
  const setB = new Set(hexCorners(b));
  const common = hexCorners(a).filter((v) => setB.has(v));
  if (common.length !== 2) throw new Error(`sharedSide: hexes ${hexKey(a)} and ${hexKey(b)} are not adjacent`);
  return [common[0] as NodeId, common[1] as NodeId];
}

/**
 * Order the lobes of a tri-lobe sector clockwise around their shared centre
 * (screen coordinates, y down ⇒ clockwise = increasing angle).
 */
export function lobesClockwise(lobes: readonly HexCoord[]): HexCoord[] {
  const centre = vertexPosition(sharedVertex(lobes));
  return [...lobes].sort((p, q) => {
    const cp = hexCenter(p);
    const cq = hexCenter(q);
    return Math.atan2(cp.y - centre.y, cp.x - centre.x) - Math.atan2(cq.y - centre.y, cq.x - centre.x);
  });
}

/**
 * The vertices that lie INSIDE a tri-lobe slot and are not shared with any
 * neighbouring space: the centre vertex plus the outer vertex of each pairwise
 * lobe side (a system's colony sites, an outpost's docking point, an empty
 * sector's centre). The slot's other 9 vertices sit on its rim and belong to
 * outside hexes as well. Purely geometric, so it is identical for every tile
 * type — that is what keeps an undiscovered slot's redacted shape neutral.
 */
export function slotInteriorVertices(lobes: readonly HexCoord[]): NodeId[] {
  const centre = sharedVertex(lobes);
  const [a, b, c] = lobes as [HexCoord, HexCoord, HexCoord];
  const outer = ([[a, b], [b, c], [a, c]] as const).map(([p, q]) => sharedSide(p, q).find((v) => v !== centre) as NodeId);
  return [centre, ...outer];
}
