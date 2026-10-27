/**
 * Founding a trade station (spec §9.2, §9.5).
 *
 * A trade ship may end its move on a docking point ONLY if it immediately
 * founds a station there. `canFoundTradeStation` is the pure predicate the
 * movement validator and the `foundTradeStation` handler share:
 *   - the node is an outpost's docking point;
 *   - the ship is a trade ship of the active player;
 *   - the outpost has fewer than `MAX_STATIONS_PER_OUTPOST` stations;
 *   - `mothership.freightPods > stationsAlreadyAtOutpost`
 *     (0 stations → 1 pod, 3 stations → 4 pods);
 *   - the player still has a trade station piece;
 *   - the civilisation still has a friendship card to hand out.
 */

import { MAX_STATIONS_PER_OUTPOST } from '../config.js';
import { getNode, getPlayer, stationsAt } from '../board/query.js';
import type { Board, FriendshipCardId, GameError, GameState, NodeId, Sector, ShipId } from '../types.js';
import { gameError } from '../types.js';
import { ownShip } from './colony.js';
import { pickableFriendshipCards } from './friendship.js';

/** The outpost whose docking point is `nodeId`, if any. */
export function outpostAtNode(board: Board, nodeId: NodeId): Sector | undefined {
  return Object.values(board.sectors).find((s) => s.kind === 'outpost' && s.dockingPointId === nodeId);
}

export function canFoundTradeStation(state: GameState, shipId: ShipId, nodeId: NodeId): GameError | null {
  const player = getPlayer(state, state.activePlayer);
  const ship = ownShip(state, player, shipId);
  if ('kind' in ship && ship.kind === 'error') return ship;
  if (ship.kind !== 'trade') {
    return gameError('ruleViolation', `${shipId} is a colony ship; only trade ships found trade stations`, { shipId });
  }
  const node = getNode(state.board, nodeId);
  const outpost = node.siteType === 'dockingPoint' ? outpostAtNode(state.board, nodeId) : undefined;
  if (!outpost || !outpost.civ || !outpost.docks) {
    return gameError('invalidSite', `${nodeId} is not a docking point`, { nodeId });
  }
  const stations = stationsAt(state.board, outpost.id);
  if (stations >= MAX_STATIONS_PER_OUTPOST || stations >= outpost.docks.length) {
    return gameError('ruleViolation', `The ${outpost.civ} outpost already has ${MAX_STATIONS_PER_OUTPOST} trade stations`, {
      sectorId: outpost.id,
      stations,
    });
  }
  if (player.mothership.freightPods <= stations) {
    return gameError('ruleViolation', `Founding the ${stations + 1}. station here needs ${stations + 1} freight pods (you have ${player.mothership.freightPods})`, {
      sectorId: outpost.id,
      stations,
      freightPods: player.mothership.freightPods,
      needed: stations + 1,
    });
  }
  if (player.pieces.stationsLeft < 1) {
    return gameError('pieceLimit', 'No trade station piece left');
  }
  if (pickableFriendshipCards(state, outpost.civ).length < 1) {
    return gameError('ruleViolation', `The ${outpost.civ} have no friendship cards left`, { civ: outpost.civ });
  }
  return null;
}

/**
 * Apply the founding (validation already done): the ship becomes a station in
 * `dockIndex`, the player takes `cardId` from the civilisation's stack.
 */
export function placeTradeStation(state: GameState, shipId: ShipId, dockIndex: number, cardId: FriendshipCardId): Sector {
  const ship = state.board.ships[shipId];
  if (!ship) throw new Error(`placeTradeStation: unknown ship ${shipId}`);
  const outpost = outpostAtNode(state.board, ship.nodeId);
  if (!outpost || !outpost.civ || !outpost.docks) throw new Error(`placeTradeStation: ${ship.nodeId} is not a docking point`);
  const player = getPlayer(state, ship.owner);

  delete state.board.ships[shipId];
  delete state.turn.shipMovesUsed[shipId];
  state.turn.immobilized = state.turn.immobilized.filter((id) => id !== shipId);
  player.pieces.transportsLeft += 1;
  player.pieces.stationsLeft -= 1;
  outpost.docks[dockIndex] = player.id;

  const stack = state.friendshipCards[outpost.civ];
  const at = stack.indexOf(cardId);
  if (at < 0) throw new Error(`placeTradeStation: ${cardId} is not in the ${outpost.civ} stack`);
  stack.splice(at, 1);
  player.friendshipCards.push(cardId);
  return outpost;
}
