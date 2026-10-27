/**
 * Reachability for clients and bots (spec §14 "highlight legal end nodes"):
 * BFS over `board.adjacency` with the ship's remaining step budget (intermediate
 * nodes may be anything, §9.2), then each reachable node is filtered through
 * `validateEndNode`, so a highlight can never disagree with `moveShip`.
 */

import type { GameState, NodeId, ShipId } from '../types.js';
import { validateJumpTarget } from './jump.js';
import { stepsLeft, validateEndNode } from './movement.js';

/** Shortest paths (nodes AFTER `start`) to every node within `budget` steps; `start` itself is excluded. */
export function reachablePaths(state: GameState, start: NodeId, budget: number): Map<NodeId, NodeId[]> {
  const paths = new Map<NodeId, NodeId[]>();
  if (budget <= 0) return paths;
  const dist = new Map<NodeId, number>([[start, 0]]);
  const queue: NodeId[] = [start];
  const prev = new Map<NodeId, NodeId>();
  while (queue.length > 0) {
    const node = queue.shift() as NodeId;
    const d = dist.get(node) as number;
    if (d >= budget) continue;
    for (const next of state.board.adjacency[node] ?? []) {
      if (dist.has(next)) continue;
      dist.set(next, d + 1);
      prev.set(next, node);
      queue.push(next);
    }
  }
  for (const [node] of dist) {
    if (node === start) continue;
    const path: NodeId[] = [];
    let cur: NodeId | undefined = node;
    while (cur !== undefined && cur !== start) {
      path.unshift(cur);
      cur = prev.get(cur);
    }
    paths.set(node, path);
  }
  return paths;
}

/** End node → path for every move the engine would accept for `shipId` right now. */
export function legalMoves(state: GameState, shipId: ShipId): Map<NodeId, NodeId[]> {
  const ship = state.board.ships[shipId];
  if (!ship || state.phase !== 'flight.move') return new Map();
  if (state.turn.pendingFound !== undefined || state.turn.immobilized.includes(shipId)) return new Map();
  const paths = reachablePaths(state, ship.nodeId, stepsLeft(state, shipId));
  for (const node of [...paths.keys()]) {
    if (validateEndNode(state, ship, node) !== null) paths.delete(node);
  }
  return paths;
}

/** Every node a space jump of `shipId` may land on (encounter pick 'spaceJump'). */
export function legalJumpTargets(state: GameState, shipId: ShipId): NodeId[] {
  if (!state.board.ships[shipId]) return [];
  return Object.keys(state.board.nodes).filter((node) => validateJumpTarget(state, shipId, node) === null);
}
