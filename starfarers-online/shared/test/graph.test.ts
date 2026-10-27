import { describe, expect, it } from 'vitest';
import { beginnerPlacement, boardLayout } from '../src/board/data.js';
import { hexCorners, parseVertexId, sharedVertex, vertexNeighbors } from '../src/board/geometry.js';
import { buildBoard } from '../src/board/graph.js';
import {
  colonySiteBetween,
  colonySiteNodes,
  dockingPointNodes,
  neighborsOf,
  nodesAdjacentToPlanet,
  planetsAdjacentToNode,
  spaceportSites,
} from '../src/board/query.js';
import type { Board, NodeId } from '../src/types.js';

function bfsReach(board: Board, start: NodeId): Set<NodeId> {
  const seen = new Set<NodeId>([start]);
  const queue = [start];
  while (queue.length) {
    const n = queue.shift()!;
    for (const m of neighborsOf(board, n)) {
      if (!seen.has(m)) {
        seen.add(m);
        queue.push(m);
      }
    }
  }
  return seen;
}

describe('hex geometry', () => {
  it('each vertex has 3 neighbours which are mutually consistent', () => {
    for (const id of ['N(3,4)', 'S(3,4)', 'N(4,4)', 'S(0,0)', 'N(10,15)']) {
      const nbrs = vertexNeighbors(id);
      expect(new Set(nbrs).size).toBe(3);
      for (const m of nbrs) expect(vertexNeighbors(m)).toContain(id);
    }
  });

  it('hex corners are consistent with neighbour adjacency', () => {
    for (const hex of [[2, 3], [3, 3], [0, 0]] as const) {
      const corners = hexCorners(hex);
      expect(new Set(corners).size).toBe(6);
      for (let i = 0; i < 6; i++) {
        expect(vertexNeighbors(corners[i]!)).toContain(corners[(i + 1) % 6]!);
      }
      for (const c of corners) expect(() => parseVertexId(c)).not.toThrow();
    }
  });
});

describe('beginner board graph (spec §15)', () => {
  const layout = boardLayout();
  const placement = beginnerPlacement();
  const board = buildBoard(layout, placement);

  it('has 24 colony sites on unexplored systems and 12 Catanian colony sites', () => {
    const sites = colonySiteNodes(board);
    const catanian = sites.filter((n) => board.sectors[n.sectorId!]!.region === 'catanian');
    const unexplored = sites.filter((n) => board.sectors[n.sectorId!]!.region !== 'catanian');
    expect(catanian).toHaveLength(12);
    expect(unexplored).toHaveLength(24);
    expect(sites).toHaveLength(36);
  });

  it('has exactly 4 docking points, each adjacent to 0 planets', () => {
    const docks = dockingPointNodes(board);
    expect(docks).toHaveLength(4);
    for (const d of docks) {
      expect(d.adjacentPlanets).toHaveLength(0);
      const sector = board.sectors[d.sectorId!]!;
      expect(sector.kind).toBe('outpost');
      expect(sector.dockingPointId).toBe(d.id);
      expect(sector.docks).toHaveLength(5);
    }
    const civs = docks.map((d) => board.sectors[d.sectorId!]!.civ).sort();
    expect(civs).toEqual(['diplomats', 'greenFolk', 'merchants', 'scientists']);
  });

  it('has no node or edge at any planetary-system centre vertex', () => {
    const systems = Object.values(board.sectors).filter((s) => s.kind === 'system');
    expect(systems).toHaveLength(12);
    for (const s of systems) {
      const centre = sharedVertex(s.lobes);
      expect(s.centreVertex).toBe(centre);
      expect(board.nodes[centre]).toBeUndefined();
      expect(board.adjacency[centre]).toBeUndefined();
      for (const [a, b] of board.edges) {
        expect(a).not.toBe(centre);
        expect(b).not.toBe(centre);
      }
    }
    // Outpost and empty centres ARE nodes.
    for (const s of Object.values(board.sectors)) {
      if (s.kind === 'system') continue;
      expect(board.nodes[s.centreVertex]).toBeDefined();
      expect(board.nodes[s.centreVertex]!.siteType).toBe(s.kind === 'outpost' ? 'dockingPoint' : 'plain');
    }
  });

  it('every edge connects two existing distinct nodes, with no duplicates', () => {
    const seen = new Set<string>();
    for (const [a, b] of board.edges) {
      expect(a).not.toBe(b);
      expect(board.nodes[a]).toBeDefined();
      expect(board.nodes[b]).toBeDefined();
      expect(a < b).toBe(true);
      const k = `${a}|${b}`;
      expect(seen.has(k)).toBe(false);
      seen.add(k);
    }
    for (const [id, nbrs] of Object.entries(board.adjacency)) {
      expect(nbrs.length).toBeLessThanOrEqual(3);
      expect(new Set(nbrs).size).toBe(nbrs.length);
      for (const m of nbrs) expect(board.adjacency[m]).toContain(id);
    }
  });

  it('is connected', () => {
    const ids = Object.keys(board.nodes);
    const reach = bfsReach(board, ids[0]!);
    expect(reach.size).toBe(ids.length);
  });

  it('every colony site has exactly 2 adjacent planets of the same system', () => {
    for (const n of colonySiteNodes(board)) {
      const planets = planetsAdjacentToNode(board, n.id);
      expect(planets).toHaveLength(2);
      expect(planets[0]!.sectorId).toBe(n.sectorId);
      expect(planets[1]!.sectorId).toBe(n.sectorId);
      const site = board.sectors[n.sectorId!]!.colonySites.find((s) => s.nodeId === n.id)!;
      expect([...site.planetIds].sort()).toEqual(planets.map((p) => p.id).sort());
    }
    for (const s of Object.values(board.sectors)) {
      expect(s.colonySites).toHaveLength(s.kind === 'system' ? 3 : 0);
    }
  });

  it('no node is adjacent to planets of two different sectors', () => {
    for (const n of Object.values(board.nodes)) {
      const sectors = new Set(n.adjacentPlanets.map((p) => board.planets[p]!.sectorId));
      expect(sectors.size).toBeLessThanOrEqual(1);
    }
  });

  it('each planet touches 5 nodes (6 corners minus the system centre)', () => {
    expect(Object.keys(board.planets)).toHaveLength(36);
    for (const p of Object.values(board.planets)) {
      expect(nodesAdjacentToPlanet(board, p.id)).toHaveLength(5);
    }
  });

  it('each starting spaceport node has exactly 2 spaceport-site neighbours', () => {
    for (const pieces of Object.values(placement.startingPieces!)) {
      const sp = colonySiteBetween(board, pieces.spaceport.between[0], pieces.spaceport.between[1]);
      expect(board.nodes[sp]!.siteType).toBe('colonySite');
      const sites = spaceportSites(board, sp);
      expect(sites).toHaveLength(2);
      for (const s of sites) expect(board.nodes[s]!.siteType).toBe('plain');
    }
  });

  it('places beginner planets as listed in beginner.json', () => {
    expect(board.planets['P(1,4)']!.resource).toBe('goods');
    expect(board.planets['P(1,4)']!.icon).toBe('br');
    expect(board.planets['P(2,5)']!.resource).toBe('ore');
    expect(board.planets['P(0,1)']!.resource).toBe('food');
    expect(board.sectors['N1']!.tileId).toBe('S2');
    expect(board.sectors['N3']!.civ).toBe('greenFolk');
    expect(board.sectors['alpha']!.region).toBe('catanian');
  });
});
