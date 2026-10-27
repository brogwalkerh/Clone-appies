/**
 * Board graph builder: fixed layout + placement → `Board` (spec §2).
 *
 * Rules (board.json → intersections._comment):
 *  - A tri-lobe sector's 3 hexes share one CENTRE vertex.
 *  - Planetary system: the centre vertex is NOT a node (ships cannot cross it);
 *    the outer vertex of each pairwise lobe edge is a colony site adjacent to
 *    those 2 planets. Catanian systems α–δ are systems too.
 *  - Outpost: the centre vertex IS a node — the docking point. Its 5 docks are
 *    not nodes.
 *  - Empty sector: the centre vertex is an ordinary node.
 *  - Every other vertex of an in-grid hex is an ordinary node; edges are hex
 *    sides between two nodes (sides touching a removed centre are dropped).
 */

import type { Board, BoardNode, ColonySite, Edge, HexCoord, NodeId, Planet, PlanetId, Sector, SectorId } from '../types.js';
import { MAX_STATIONS_PER_OUTPOST } from '../config.js';
import { edgeKey, hexCorners, hexKey, hexSides, inGrid, sharedSide, sharedVertex, vertexPosition } from './geometry.js';
import type { BoardLayout, Placement, SlotPlacement, TileLayout } from './layout.js';

export function planetId(hex: HexCoord): PlanetId {
  return `P(${hex[0]},${hex[1]})`;
}

interface SectorSpec {
  id: SectorId;
  tileId: string;
  tile: TileLayout;
  region: Sector['region'];
  lobes: HexCoord[];
  /** Systems: lobe hex key → planet resource. */
  planetsByLobe?: Record<string, { resource: Planet['resource']; icon?: Planet['icon'] }>;
}

function catanianSpecs(layout: BoardLayout): SectorSpec[] {
  return layout.catanian.map((sys) => {
    const planetsByLobe: SectorSpec['planetsByLobe'] = {};
    for (const lobe of sys.lobes) planetsByLobe[hexKey(lobe.hex)] = { resource: lobe.resource };
    return {
      id: sys.letter,
      tileId: sys.letter,
      tile: { id: sys.letter, type: 'system', stars: 1 },
      region: 'catanian',
      lobes: sys.lobes.map((l) => l.hex),
      planetsByLobe,
    };
  });
}

function slotSpec(layout: BoardLayout, p: SlotPlacement): SectorSpec {
  const slot = layout.slots.find((s) => s.id === p.slotId);
  if (!slot) throw new Error(`buildBoard: unknown slot ${p.slotId}`);
  const tile = layout.tiles[p.tileId];
  if (!tile) throw new Error(`buildBoard: unknown tile ${p.tileId}`);
  const spec: SectorSpec = { id: slot.id, tileId: tile.id, tile, region: slot.region, lobes: slot.lobes };
  if (tile.type === 'system') {
    if (!p.lobes) throw new Error(`buildBoard: slot ${slot.id} holds system ${tile.id} but has no lobe→planet map`);
    const planets = tile.planets ?? [];
    const planetsByLobe: NonNullable<SectorSpec['planetsByLobe']> = {};
    for (const lobe of slot.lobes) {
      const res = p.lobes[hexKey(lobe)];
      if (!res) throw new Error(`buildBoard: slot ${slot.id} lobe ${hexKey(lobe)} has no planet`);
      const tp = planets.find((pl) => pl.resource === res);
      if (!tp) throw new Error(`buildBoard: tile ${tile.id} has no ${res} planet for lobe ${hexKey(lobe)}`);
      planetsByLobe[hexKey(lobe)] = { resource: tp.resource, icon: tp.icon };
    }
    if (new Set(Object.values(planetsByLobe).map((v) => v.resource)).size !== 3) {
      throw new Error(`buildBoard: slot ${slot.id} places the same planet twice`);
    }
    spec.planetsByLobe = planetsByLobe;
  }
  return spec;
}

/** Build the board graph from the fixed layout and a tile placement. Discs are not placed. */
export function buildBoard(layout: BoardLayout, placement: Placement): Board {
  const { rows, cols } = layout.grid;
  const specs = [...catanianSpecs(layout), ...placement.slots.map((p) => slotSpec(layout, p))];

  // Validate: every lobe in grid, lobes don't overlap across sectors.
  const lobeOwner = new Map<string, SectorId>();
  for (const s of specs) {
    for (const lobe of s.lobes) {
      if (!inGrid(lobe, rows, cols)) throw new Error(`buildBoard: sector ${s.id} lobe ${hexKey(lobe)} outside grid`);
      const prev = lobeOwner.get(hexKey(lobe));
      if (prev) throw new Error(`buildBoard: hex ${hexKey(lobe)} belongs to both ${prev} and ${s.id}`);
      lobeOwner.set(hexKey(lobe), s.id);
    }
  }

  // Planets.
  const planets: Record<PlanetId, Planet> = {};
  const planetAtHex = new Map<string, PlanetId>();
  for (const s of specs) {
    if (!s.planetsByLobe) continue;
    for (const lobe of s.lobes) {
      const info = s.planetsByLobe[hexKey(lobe)];
      if (!info) throw new Error(`buildBoard: sector ${s.id} lobe ${hexKey(lobe)} has no planet`);
      const id = planetId(lobe);
      const planet: Planet = { id, hex: lobe, sectorId: s.id, resource: info.resource, disc: null, token: null };
      if (info.icon) planet.icon = info.icon;
      planets[id] = planet;
      planetAtHex.set(hexKey(lobe), id);
    }
  }

  // Sectors + the set of removed centre vertices.
  const sectors: Record<SectorId, Sector> = {};
  const removedVertices = new Set<NodeId>();
  const siteType = new Map<NodeId, { type: BoardNode['siteType']; sectorId: SectorId }>();
  for (const s of specs) {
    const centre = sharedVertex(s.lobes);
    const sector: Sector = {
      id: s.id,
      tileId: s.tileId,
      kind: s.tile.type,
      region: s.region,
      lobes: s.lobes,
      centreVertex: centre,
      planetIds: [],
      colonySites: [],
      explored: s.tile.type !== 'system' || s.region === 'catanian',
      // Face-down tiles (explorer / wild space) are flipped to false by the set-up.
      discovered: true,
    };
    if (s.tile.type === 'system') {
      removedVertices.add(centre);
      sector.planetIds = s.lobes.map((l) => planetAtHex.get(hexKey(l)) as PlanetId);
      const pairs: [number, number][] = [[0, 1], [1, 2], [0, 2]];
      for (const [i, j] of pairs) {
        const a = s.lobes[i] as HexCoord;
        const b = s.lobes[j] as HexCoord;
        const outer = sharedSide(a, b).find((v) => v !== centre);
        if (!outer) throw new Error(`buildBoard: sector ${s.id} lobes ${hexKey(a)}/${hexKey(b)} have no outer vertex`);
        const site: ColonySite = { nodeId: outer, planetIds: [planetAtHex.get(hexKey(a)) as PlanetId, planetAtHex.get(hexKey(b)) as PlanetId] };
        sector.colonySites.push(site);
        siteType.set(outer, { type: 'colonySite', sectorId: s.id });
      }
    } else if (s.tile.type === 'outpost') {
      sector.civ = s.tile.civ as NonNullable<Sector['civ']>;
      sector.dockingPointId = centre;
      sector.docks = Array.from({ length: MAX_STATIONS_PER_OUTPOST }, () => null);
      siteType.set(centre, { type: 'dockingPoint', sectorId: s.id });
    } else {
      siteType.set(centre, { type: 'plain', sectorId: s.id });
    }
    sectors[s.id] = sector;
  }

  // Nodes: all corners of in-grid hexes except removed centres.
  const nodes: Record<NodeId, BoardNode> = {};
  const adjacentPlanets = new Map<NodeId, PlanetId[]>();
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      const hex: HexCoord = [r, c];
      const pid = planetAtHex.get(hexKey(hex));
      for (const v of hexCorners(hex)) {
        if (removedVertices.has(v)) continue;
        if (!nodes[v]) {
          const st = siteType.get(v);
          const node: BoardNode = { id: v, pos: vertexPosition(v), adjacentPlanets: [], siteType: st?.type ?? 'plain' };
          if (st) node.sectorId = st.sectorId;
          nodes[v] = node;
        }
        if (pid) {
          const list = adjacentPlanets.get(v) ?? [];
          if (!list.includes(pid)) list.push(pid);
          adjacentPlanets.set(v, list);
        }
      }
    }
  }
  for (const [v, list] of adjacentPlanets) (nodes[v] as BoardNode).adjacentPlanets = list;

  // Edges: hex sides between two nodes, deduplicated.
  const edges: Edge[] = [];
  const seen = new Set<string>();
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      for (const [a, b] of hexSides([r, c])) {
        if (!nodes[a] || !nodes[b]) continue;
        const k = edgeKey(a, b);
        if (seen.has(k)) continue;
        seen.add(k);
        edges.push(a < b ? [a, b] : [b, a]);
      }
    }
  }

  const adjacency: Record<NodeId, NodeId[]> = {};
  for (const id of Object.keys(nodes)) adjacency[id] = [];
  for (const [a, b] of edges) {
    (adjacency[a] as NodeId[]).push(b);
    (adjacency[b] as NodeId[]).push(a);
  }

  return { grid: { rows, cols }, nodes, edges, adjacency, sectors, planets, settlements: {}, ships: {} };
}
