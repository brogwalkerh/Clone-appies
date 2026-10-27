/**
 * Ship movement rules (spec §9.2, §11 no-blockade rules).
 *
 * Path convention: `path` lists the nodes AFTER the ship's current node, in
 * order; `path.length` is the number of steps used. A ship may be moved in
 * several `moveShip` calls per turn as long as the cumulative steps stay within
 * `state.turn.speed`; backtracking is allowed; intermediate nodes may be
 * occupied by anything (ships, colonies, spaceports).
 *
 * End-node rules (`validateEndNode`, also used by space jumps):
 *   - no settlement and no other ship on the node (one piece per intersection;
 *     a colony site holding a colony/spaceport is therefore never a legal end);
 *   - not a spaceport site (graph neighbour) of a spaceport ANOTHER PLAYER
 *     owns; the 3-player blocker colour's spaceport (owner null) counts only
 *     when `BLOCKER_SPACEPORT_SITES_BLOCK_END_NODES` says so (config, default
 *     false: the blockers "only block the sites" they stand on);
 *   - trade ship never on a colony site; colony ship never on a docking point;
 *   - trade ship on a docking point only if `canFoundTradeStation` says a
 *     station can be founded right now (the move then sets `turn.pendingFound`);
 *   - a ship flagged `mustFoundOrLeave` may not end on the node it stands on,
 *     and a ship that left such a node this turn (`ship.leftSite`) may not end
 *     there again — "may only return by founding" is modelled strictly: a ship
 *     that wants to found there founds from where it already stands.
 *
 *   - never inside an undiscovered slot (explorer / wild space): the slot's
 *     interior nodes (`undiscoveredInteriorNodes`) can be neither an end node
 *     nor a step of a path until the tile is discovered; the slot's rim nodes
 *     are ordinary space.
 *
 * `applyMove` walks the path one node at a time, discovering face-down
 * sectors (flight/discover.ts), exploring and resolving pirate / ice tokens at
 * every step (§9.3 "at any point in its move", §9.6 "immediately"), then does
 * the parking bookkeeping (`afterArrival`, shared
 * with space jumps): a docked trade ship sets `turn.pendingFound`, and any
 * trade-ship marker the owner still holds is placed if the move just freed a
 * spaceport site (§7.3 "as soon as possible"; the new ship may move this turn).
 */

import { tryPlacePendingTradeShips } from '../found/freeTradeShip.js';
import { canFoundTradeStation } from '../found/station.js';
import { areAdjacent, getPlayer, hasNode, settlementAt, shipAt, spaceportSites, undiscoveredInteriorNodes } from '../board/query.js';
import { logEvent } from '../actions/handler.js';
import { BLOCKER_SPACEPORT_SITES_BLOCK_END_NODES, DISCOVERY_ENDS_MOVE } from '../config.js';
import type { Rng } from '../rng.js';
import type { GameError, GameState, NodeId, Ship } from '../types.js';
import { gameError } from '../types.js';
import { discoverAt } from './discover.js';
import { exploreAt } from './explore.js';

/**
 * Is `nodeId` a spaceport site of a spaceport the player does not own (§9.2 /
 * §11 "another player's spaceport site")? The unused colour's blocker
 * spaceport in a 3-player game belongs to nobody; whether its sites count is
 * `blockerSitesBlock` (`BLOCKER_SPACEPORT_SITES_BLOCK_END_NODES`, **[VERIFY]**).
 */
export function isForeignSpaceportSite(
  state: GameState,
  nodeId: NodeId,
  playerId: string,
  blockerSitesBlock: boolean = BLOCKER_SPACEPORT_SITES_BLOCK_END_NODES,
): boolean {
  for (const s of Object.values(state.board.settlements)) {
    if (s.kind !== 'spaceport' || s.owner === playerId) continue;
    if (s.owner === null && !blockerSitesBlock) continue;
    if (spaceportSites(state.board, s.nodeId).includes(nodeId)) return true;
  }
  return false;
}

/** Geometry of a path: non-empty, known nodes, a chain of edges from the ship's node. */
export function validatePath(state: GameState, ship: Ship, path: readonly NodeId[]): GameError | null {
  if (path.length === 0) return gameError('invalidPath', 'A move needs at least one step');
  const hidden = undiscoveredInteriorNodes(state.board);
  let prev = ship.nodeId;
  for (const [i, node] of path.entries()) {
    if (!hasNode(state.board, node)) return gameError('invalidPath', `Unknown node ${node}`, { node });
    if (hidden.has(node)) return gameError('invalidPath', `${node} lies inside an undiscovered sector (step ${i + 1})`, { node });
    if (!areAdjacent(state.board, prev, node)) {
      return gameError('invalidPath', `${prev} and ${node} are not joined by an edge (step ${i + 1})`, { from: prev, to: node });
    }
    prev = node;
  }
  return null;
}

/** May `ship` END a move (or a jump) on `nodeId`? `null` when allowed. */
export function validateEndNode(state: GameState, ship: Ship, nodeId: NodeId): GameError | null {
  const board = state.board;
  if (!hasNode(board, nodeId)) return gameError('invalidTarget', `Unknown node ${nodeId}`, { nodeId });
  const node = board.nodes[nodeId]!;
  if (undiscoveredInteriorNodes(board).has(nodeId)) {
    return gameError('invalidTarget', `${nodeId} lies inside an undiscovered sector`, { nodeId });
  }
  if (settlementAt(board, nodeId)) {
    return gameError('invalidTarget', `${nodeId} holds a colony or spaceport`, { nodeId });
  }
  const other = shipAt(board, nodeId);
  if (other && other.id !== ship.id) {
    return gameError('invalidTarget', `${nodeId} is occupied by ship ${other.id}`, { nodeId, shipId: other.id });
  }
  if (isForeignSpaceportSite(state, nodeId, ship.owner)) {
    return gameError('ruleViolation', `${nodeId} is another player's spaceport site`, { nodeId });
  }
  if (ship.mustFoundOrLeave && nodeId === ship.nodeId) {
    return gameError('ruleViolation', `${ship.id} must found or leave ${nodeId}; it may not end its move there again`, { nodeId });
  }
  if (ship.leftSite !== undefined && ship.leftSite === nodeId) {
    return gameError('ruleViolation', `${ship.id} left ${nodeId} this turn and may only return there by founding`, { nodeId });
  }
  if (ship.kind === 'trade' && node.siteType === 'colonySite') {
    return gameError('ruleViolation', 'A trade ship may never end its move on a colony site', { nodeId });
  }
  if (ship.kind === 'colony' && node.siteType === 'dockingPoint') {
    return gameError('ruleViolation', 'A colony ship may never end its move on a docking point', { nodeId });
  }
  if (ship.kind === 'trade' && node.siteType === 'dockingPoint') {
    const cannot = canFoundTradeStation(state, ship.id, nodeId);
    if (cannot) {
      return gameError('ruleViolation', `A trade ship may end on a docking point only to found a station: ${cannot.message}`, {
        nodeId,
        cause: cannot,
      });
    }
  }
  return null;
}

/** Steps still available to the ship this turn. */
export function stepsLeft(state: GameState, shipId: string): number {
  return (state.turn.speed ?? 0) - (state.turn.shipMovesUsed[shipId] ?? 0);
}

/**
 * Move the ship along an already validated path, discovering, exploring and
 * claiming tokens at every step, and record the steps in `turn.shipMovesUsed`.
 * `rng` draws the number discs of a system discovered on the way.
 */
export function applyMove(state: GameState, ship: Ship, path: readonly NodeId[], rng?: Rng): void {
  const start = ship.nodeId;
  if (ship.mustFoundOrLeave) {
    ship.mustFoundOrLeave = false;
    ship.leftSite = start;
  }
  let discovered = false;
  for (const node of path) {
    ship.nodeId = node;
    if (discoverAt(state, node, rng).length > 0) discovered = true;
    exploreAt(state, node, ship.id);
  }
  state.turn.shipMovesUsed[ship.id] = (state.turn.shipMovesUsed[ship.id] ?? 0) + path.length;
  if (discovered && DISCOVERY_ENDS_MOVE) {
    // [VERIFY] config: discovery forfeits the rest of the ship's budget (the validated path is still completed).
    state.turn.shipMovesUsed[ship.id] = Math.max(state.turn.shipMovesUsed[ship.id] ?? 0, state.turn.speed ?? 0);
  }
  const owner = getPlayer(state, ship.owner);
  logEvent(state, `${owner.name} moved ${ship.id} ${start} → ${ship.nodeId} (${path.length} step${path.length === 1 ? '' : 's'})`, owner.id);
  afterArrival(state, ship);
}

/** Bookkeeping once a ship has come to rest (shared by moves and jumps). */
export function afterArrival(state: GameState, ship: Ship): void {
  const node = state.board.nodes[ship.nodeId];
  if (ship.kind === 'trade' && node?.siteType === 'dockingPoint') {
    state.turn.pendingFound = ship.id;
    logEvent(state, `${ship.id} docked at ${ship.nodeId} and must found a trade station now`, ship.owner);
  }
  tryPlacePendingTradeShips(state, ship.owner);
}
