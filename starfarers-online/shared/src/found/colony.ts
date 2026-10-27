/**
 * Founding a colony (spec §9.2, §9.4, §9.6).
 *
 * A colony ship on an unoccupied colony site that is not adjacent to any
 * pirate base or ice planet may found at any point of the owner's move phase
 * (even after 0 steps). The transport returns to the player's supply, the
 * colony piece is placed, +1 VP (recomputed by `applyAction`). In a 3-player
 * game at most `MAX_COLONIES_PER_SYSTEM_3P` colonies may be founded per
 * unexplored planetary system; the Catanian systems are exempt.
 */

import { MAX_COLONIES_PER_SYSTEM_3P } from '../config.js';
import { getNode, getPlayer, getSector, planetsAdjacentToNode, settlementAt } from '../board/query.js';
import type { Board, GameError, GameState, NodeId, Player, SectorId, Ship, ShipId } from '../types.js';
import { gameError } from '../types.js';

/**
 * True when any planet touching the node still carries a pirate-base or
 * ice-planet token (§9.4: no colony next to an active token). Private
 * equivalent of `flight/tokens.nodeTouchesToken`.
 */
export function nodeTouchesSpecialToken(board: Board, nodeId: NodeId): boolean {
  return planetsAdjacentToNode(board, nodeId).some((p) => p.token !== null);
}

/** Colonies / spaceports standing on the colony sites of a planetary system. */
export function settlementsInSystem(state: GameState, sectorId: SectorId): number {
  const sector = getSector(state.board, sectorId);
  return sector.colonySites.filter((site) => settlementAt(state.board, site.nodeId) !== undefined).length;
}

/** The player's ship, or a typed error when it does not exist or is not theirs. */
export function ownShip(state: GameState, player: Player, shipId: ShipId): Ship | GameError {
  const ship = state.board.ships[shipId];
  if (!ship) return gameError('invalidTarget', `Unknown ship ${shipId}`, { shipId });
  if (ship.owner !== player.id) return gameError('invalidTarget', `${shipId} is not your ship`, { shipId });
  return ship;
}

/**
 * Pure predicate: may `shipId` found a colony where it stands right now?
 * `null` when allowed, else the error to return to the client.
 */
export function canFoundColony(state: GameState, shipId: ShipId): GameError | null {
  const player = getPlayer(state, state.activePlayer);
  const ship = ownShip(state, player, shipId);
  if ('kind' in ship && ship.kind === 'error') return ship;
  if (ship.kind !== 'colony') {
    return gameError('ruleViolation', `${shipId} is a trade ship; only colony ships found colonies`, { shipId });
  }
  const node = getNode(state.board, ship.nodeId);
  if (node.siteType !== 'colonySite') {
    return gameError('invalidSite', `${ship.nodeId} is not a colony site`, { nodeId: ship.nodeId });
  }
  if (settlementAt(state.board, ship.nodeId)) {
    return gameError('invalidSite', `Colony site ${ship.nodeId} is already settled`, { nodeId: ship.nodeId });
  }
  if (nodeTouchesSpecialToken(state.board, ship.nodeId)) {
    return gameError('ruleViolation', 'No colony may be founded next to a pirate base or ice planet', {
      nodeId: ship.nodeId,
    });
  }
  if (player.pieces.coloniesLeft < 1) {
    return gameError('pieceLimit', 'No colony piece left');
  }
  const sectorId = node.sectorId;
  if (state.players.length === 3 && sectorId !== undefined) {
    const sector = getSector(state.board, sectorId);
    if (sector.region !== 'catanian' && settlementsInSystem(state, sectorId) >= MAX_COLONIES_PER_SYSTEM_3P) {
      return gameError('ruleViolation', `3-player game: at most ${MAX_COLONIES_PER_SYSTEM_3P} colonies per planetary system`, {
        sectorId,
        max: MAX_COLONIES_PER_SYSTEM_3P,
      });
    }
  }
  return null;
}

/**
 * Apply the founding (validation already done): the ship becomes a colony.
 * Returns the node the colony was placed on.
 */
export function placeColony(state: GameState, shipId: ShipId): NodeId {
  const ship = state.board.ships[shipId];
  if (!ship) throw new Error(`placeColony: unknown ship ${shipId}`);
  const player = getPlayer(state, ship.owner);
  const nodeId = ship.nodeId;
  delete state.board.ships[shipId];
  delete state.turn.shipMovesUsed[shipId];
  state.turn.immobilized = state.turn.immobilized.filter((id) => id !== shipId);
  player.pieces.transportsLeft += 1;
  player.pieces.coloniesLeft -= 1;
  state.board.settlements[nodeId] = { nodeId, kind: 'colony', color: player.color, owner: player.id };
  return nodeId;
}
