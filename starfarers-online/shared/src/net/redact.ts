/**
 * Per-viewer redaction of the authoritative state (spec §12.1, §13). The
 * server calls this once per socket before emitting `state`; the engine never
 * sees a redacted state.
 *
 * Hidden from a viewer:
 *   - every OTHER player's `hand` (emptied; `handCount` carries the size for all players),
 *   - the order and contents of `reservePile` and `encounterDeck` (emptied; counts kept),
 *   - `seed` (knowing it would let a client replay the rng),
 *   - `log[*].action` payloads that reveal cards other players chose
 *     (`discardForSeven.cards`, `encounterPick.resources` for `payResources` /
 *     `giveOne`), stripped unless the viewer is the actor; the human-readable
 *     `message` stays,
 *   - the per-icon number-disc pools (emptied; `discPoolCounts` kept),
 *   - every UNDISCOVERED sector's tile (explorer / wild space, `redactBoard`):
 *     the sector becomes `kind: 'hidden'` with no planets, colony sites, civ,
 *     docks or docking point; its planets leave `board.planets`; the slot's
 *     interior nodes (centre + the three pairwise-side vertices, see
 *     `slotInteriorVertices`) and the edges touching them leave the graph and
 *     the rim nodes lose their `adjacentPlanets`. What remains is the same for
 *     a system, an outpost and an empty tile, so nothing in the view tells them
 *     apart; the engine's own reachability already keeps ships out of those
 *     interiors, so client highlights still agree with the validator.
 *
 * The result keeps the `GameState` shape so every pure helper that only reads
 * public data (board queries, VP, action policy, movement validation) works on
 * it unchanged.
 */

import { slotInteriorVertices } from '../board/geometry.js';
import type { Action, Board, BoardNode, Edge, GameState, LogEntry, NodeId, PlayerId, Sector } from '../types.js';

/** Actions whose payload names cards that opponents should not see. */
export function actionRevealsHiddenCards(action: Action): boolean {
  switch (action.type) {
    case 'discardForSeven':
      return action.cards.length > 0;
    case 'encounterPick':
      return action.resources !== undefined && action.resources.length > 0;
    default:
      return false;
  }
}

function redactLogEntry(entry: LogEntry, viewerId: PlayerId): LogEntry {
  if (!entry.action || entry.action.playerId === viewerId || !actionRevealsHiddenCards(entry.action)) return entry;
  const { action: _action, ...rest } = entry;
  return rest;
}

/** A face-down sector as every viewer sees it: the slot, nothing about the tile. */
function hiddenSector(sector: Sector): Sector {
  return {
    id: sector.id,
    tileId: '',
    kind: 'hidden',
    region: sector.region,
    lobes: sector.lobes,
    centreVertex: sector.centreVertex,
    planetIds: [],
    colonySites: [],
    explored: false,
    discovered: false,
  };
}

/**
 * Hide every undiscovered sector's tile. Returns the board itself when all
 * sectors are discovered; idempotent on an already redacted board.
 */
export function redactBoard(board: Board): Board {
  const hidden = Object.values(board.sectors).filter((s) => !s.discovered);
  if (hidden.length === 0) return board;
  const hiddenIds = new Set(hidden.map((s) => s.id));
  const dropNodes = new Set<NodeId>();
  for (const s of hidden) for (const v of slotInteriorVertices(s.lobes)) dropNodes.add(v);

  const planets = Object.fromEntries(Object.entries(board.planets).filter(([, p]) => !hiddenIds.has(p.sectorId)));
  const nodes: Record<NodeId, BoardNode> = {};
  for (const [id, node] of Object.entries(board.nodes)) {
    if (dropNodes.has(id)) continue;
    const adjacentPlanets = node.adjacentPlanets.filter((p) => planets[p] !== undefined);
    nodes[id] = adjacentPlanets.length === node.adjacentPlanets.length ? node : { ...node, adjacentPlanets };
  }
  const edges: Edge[] = board.edges.filter(([a, b]) => !dropNodes.has(a) && !dropNodes.has(b));
  const adjacency: Record<NodeId, NodeId[]> = {};
  for (const id of Object.keys(nodes)) adjacency[id] = [];
  for (const [a, b] of edges) {
    (adjacency[a] as NodeId[]).push(b);
    (adjacency[b] as NodeId[]).push(a);
  }
  const sectors: Record<string, Sector> = {};
  for (const [id, s] of Object.entries(board.sectors)) sectors[id] = s.discovered ? s : hiddenSector(s);
  return { ...board, nodes, edges, adjacency, sectors, planets };
}

export function redactState(state: GameState, viewerId: PlayerId): GameState {
  return {
    ...state,
    seed: '',
    board: redactBoard(state.board),
    discPools: { tri: [], br: [], hex: [] },
    discPoolCounts: { tri: state.discPools.tri.length, br: state.discPools.br.length, hex: state.discPools.hex.length },
    players: state.players.map((p) => ({
      ...p,
      hand: p.id === viewerId ? [...p.hand] : [],
      handCount: p.hand.length,
    })),
    reservePile: [],
    reservePileCount: state.reservePile.length,
    encounterDeck: [],
    encounterDeckCount: state.encounterDeck.length,
    log: state.log.map((e) => redactLogEntry(e, viewerId)),
  };
}

/** Hand size that works on both authoritative and redacted states. */
export function handSize(player: { hand: readonly unknown[]; handCount?: number | undefined }): number {
  return player.handCount ?? player.hand.length;
}
