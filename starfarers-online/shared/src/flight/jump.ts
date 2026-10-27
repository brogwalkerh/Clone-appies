/**
 * Space jump (spec §9.7): move one ship to ANY unoccupied intersection,
 * obeying every no-blockade rule (§11); a trade ship may not jump to a colony
 * site (already an end-node rule). The ship may explore / claim tokens on
 * arrival and its movement for the turn is over. Encounter cards (phase 3)
 * call `validateJumpTarget` then `applySpaceJump`.
 */

import { getPlayer } from '../board/query.js';
import { logEvent } from '../actions/handler.js';
import type { GameError, GameState, NodeId, ShipId } from '../types.js';
import { gameError } from '../types.js';
import { exploreAt } from './explore.js';
import { afterArrival, validateEndNode } from './movement.js';

export function validateJumpTarget(state: GameState, shipId: ShipId, nodeId: NodeId): GameError | null {
  const ship = state.board.ships[shipId];
  if (!ship) return gameError('invalidTarget', `Unknown ship ${shipId}`, { shipId });
  if (nodeId === ship.nodeId) {
    return gameError('invalidTarget', `${shipId} already stands on ${nodeId}`, { nodeId });
  }
  return validateEndNode(state, ship, nodeId);
}

/** Apply an already validated jump; ends the ship's movement for the turn. */
export function applySpaceJump(state: GameState, shipId: ShipId, nodeId: NodeId): void {
  const ship = state.board.ships[shipId];
  if (!ship) throw new Error(`applySpaceJump: unknown ship ${shipId}`);
  const from = ship.nodeId;
  if (ship.mustFoundOrLeave) {
    ship.mustFoundOrLeave = false;
    ship.leftSite = from;
  }
  ship.nodeId = nodeId;
  const owner = getPlayer(state, ship.owner);
  logEvent(state, `${owner.name}'s ship ${shipId} space-jumped ${from} → ${nodeId}`, owner.id);
  exploreAt(state, nodeId, shipId);
  // A jump ends the ship's movement: spend whatever speed is left.
  state.turn.shipMovesUsed[shipId] = Math.max(state.turn.shipMovesUsed[shipId] ?? 0, state.turn.speed ?? 0);
  afterArrival(state, ship);
}
