/**
 * Read-only accessors over `Board` / `GameState`. Pure functions, no mutation.
 */

import type {
  Board,
  BoardNode,
  GameState,
  HexCoord,
  NodeId,
  Planet,
  PlanetId,
  Player,
  PlayerId,
  Sector,
  SectorId,
  Settlement,
  Ship,
} from '../types.js';
import { hexKey, sharedSide, slotInteriorVertices, vertexHexes } from './geometry.js';
import { planetId } from './graph.js';

export function getNode(board: Board, id: NodeId): BoardNode {
  const n = board.nodes[id];
  if (!n) throw new Error(`Unknown node ${id}`);
  return n;
}

export function hasNode(board: Board, id: NodeId): boolean {
  return board.nodes[id] !== undefined;
}

/** Nodes joined to `id` by one edge. */
export function neighborsOf(board: Board, id: NodeId): NodeId[] {
  return board.adjacency[id] ?? [];
}

export function areAdjacent(board: Board, a: NodeId, b: NodeId): boolean {
  return neighborsOf(board, a).includes(b);
}

export function getPlanet(board: Board, id: PlanetId): Planet {
  const p = board.planets[id];
  if (!p) throw new Error(`Unknown planet ${id}`);
  return p;
}

export function planetAtHex(board: Board, hex: HexCoord): Planet | undefined {
  return board.planets[planetId(hex)];
}

export function getSector(board: Board, id: SectorId): Sector {
  const s = board.sectors[id];
  if (!s) throw new Error(`Unknown sector ${id}`);
  return s;
}

export function planetsOfSector(board: Board, sectorId: SectorId): Planet[] {
  return getSector(board, sectorId).planetIds.map((id) => getPlanet(board, id));
}

/** All nodes whose adjacentPlanets include the planet. */
export function nodesAdjacentToPlanet(board: Board, planetId_: PlanetId): BoardNode[] {
  return Object.values(board.nodes).filter((n) => n.adjacentPlanets.includes(planetId_));
}

export function planetsAdjacentToNode(board: Board, nodeId: NodeId): Planet[] {
  return getNode(board, nodeId).adjacentPlanets.map((id) => getPlanet(board, id));
}

/** Sectors (systems) that have a planet touching this node. */
export function sectorsAdjacentToNode(board: Board, nodeId: NodeId): Sector[] {
  const ids = new Set(planetsAdjacentToNode(board, nodeId).map((p) => p.sectorId));
  return [...ids].map((id) => getSector(board, id));
}

/** Sectors whose tile is still face down (explorer / wild space). */
export function undiscoveredSectors(board: Board): Sector[] {
  return Object.values(board.sectors).filter((s) => !s.discovered);
}

/**
 * Every node inside an undiscovered slot (centre, colony sites / docking
 * point): ships may neither end on nor pass through them until the tile is
 * discovered. Works on authoritative and redacted boards alike (a redacted
 * board simply has no such nodes).
 */
export function undiscoveredInteriorNodes(board: Board): Set<NodeId> {
  const out = new Set<NodeId>();
  for (const sector of undiscoveredSectors(board)) {
    for (const v of slotInteriorVertices(sector.lobes)) if (board.nodes[v]) out.add(v);
  }
  return out;
}

/** Undiscovered sectors one of whose lobe hexes touches the node (discovery trigger). */
export function undiscoveredSectorsTouchingNode(board: Board, nodeId: NodeId): Sector[] {
  const hexes = new Set(vertexHexes(nodeId).map(hexKey));
  return undiscoveredSectors(board).filter((s) => s.lobes.some((lobe) => hexes.has(hexKey(lobe))));
}

export function colonySiteNodes(board: Board): BoardNode[] {
  return Object.values(board.nodes).filter((n) => n.siteType === 'colonySite');
}

export function dockingPointNodes(board: Board): BoardNode[] {
  return Object.values(board.nodes).filter((n) => n.siteType === 'dockingPoint');
}

/**
 * The colony site lying between two lobe hexes of the same sector: the outer
 * vertex of their shared side (the centre vertex is never a node).
 */
export function colonySiteBetween(board: Board, a: HexCoord, b: HexCoord): NodeId {
  const pa = planetAtHex(board, a);
  const pb = planetAtHex(board, b);
  if (!pa || !pb) throw new Error(`No planets at ${hexKey(a)} / ${hexKey(b)}`);
  if (pa.sectorId !== pb.sectorId) throw new Error(`Hexes ${hexKey(a)} and ${hexKey(b)} are in different sectors`);
  const centre = getSector(board, pa.sectorId).centreVertex;
  const outer = sharedSide(a, b).find((v) => v !== centre);
  if (!outer || !board.nodes[outer]) throw new Error(`No colony site between ${hexKey(a)} and ${hexKey(b)}`);
  return outer;
}

/** The two spaceport sites of a (potential) spaceport at `nodeId`: its graph neighbours. */
export function spaceportSites(board: Board, nodeId: NodeId): NodeId[] {
  return neighborsOf(board, nodeId);
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

export function settlementAt(board: Board, nodeId: NodeId): Settlement | undefined {
  return board.settlements[nodeId];
}

export function settlementsOf(state: GameState, playerId: PlayerId): Settlement[] {
  return Object.values(state.board.settlements).filter((s) => s.owner === playerId);
}

export function coloniesOf(state: GameState, playerId: PlayerId): Settlement[] {
  return settlementsOf(state, playerId).filter((s) => s.kind === 'colony');
}

export function spaceportsOf(state: GameState, playerId: PlayerId): Settlement[] {
  return settlementsOf(state, playerId).filter((s) => s.kind === 'spaceport');
}

export function shipsOf(state: GameState, playerId: PlayerId): Ship[] {
  return Object.values(state.board.ships).filter((s) => s.owner === playerId);
}

export function shipAt(board: Board, nodeId: NodeId): Ship | undefined {
  return Object.values(board.ships).find((s) => s.nodeId === nodeId);
}

/** True if a ship or settlement sits on the node (one piece per intersection). */
export function isOccupied(board: Board, nodeId: NodeId): boolean {
  return board.settlements[nodeId] !== undefined || shipAt(board, nodeId) !== undefined;
}

/** Trade stations of a player at an outpost. */
export function stationsAt(board: Board, sectorId: SectorId, playerId?: PlayerId): number {
  const docks = getSector(board, sectorId).docks ?? [];
  return docks.filter((d) => d !== null && (playerId === undefined || d === playerId)).length;
}

export function getPlayer(state: GameState, playerId: PlayerId): Player {
  const p = state.players.find((pl) => pl.id === playerId);
  if (!p) throw new Error(`Unknown player ${playerId}`);
  return p;
}

export function findPlayer(state: GameState, playerId: PlayerId): Player | undefined {
  return state.players.find((pl) => pl.id === playerId);
}

export function isActivePlayer(state: GameState, playerId: PlayerId): boolean {
  return state.activePlayer === playerId;
}

/** Player `offset` seats to the left (clockwise) of `playerId` in turn order. */
export function playerToLeft(state: GameState, playerId: PlayerId, offset = 1): PlayerId {
  const i = state.turnOrder.indexOf(playerId);
  if (i < 0) throw new Error(`Unknown player ${playerId}`);
  const n = state.turnOrder.length;
  return state.turnOrder[(((i + offset) % n) + n) % n] as PlayerId;
}

/** Player `offset` seats to the right (counter-clockwise). */
export function playerToRight(state: GameState, playerId: PlayerId, offset = 1): PlayerId {
  return playerToLeft(state, playerId, -offset);
}
