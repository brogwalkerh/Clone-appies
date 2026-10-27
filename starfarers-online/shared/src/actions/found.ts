/**
 * FOUNDING handlers (spec §9.4, §9.5, §8):
 *   foundColony{shipId}                                   — colony ship → colony
 *   foundTradeStation{shipId, dockIndex, friendshipCardId} — trade ship → station + friendship card
 *
 * Both are flight-move actions of the active player (`ACTION_POLICY`). Rules
 * live in `found/colony.ts` and `found/station.ts`; friendship markers and
 * card bookkeeping in `found/friendship.ts`.
 *
 * `turn.pendingFound` is set by the movement handler when a trade ship ends
 * its move on a docking point (§9.2: allowed only if it founds immediately).
 * While it is set, only that ship may act: `foundTradeStation` for it consumes
 * and clears the flag; founding with any other ship is rejected.
 *
 * A ship leaving the board returns a transport, so both handlers end by placing
 * any trade-ship markers the player is still owed (§7.3 "as soon as possible").
 */

import { FRIENDSHIP_CARDS } from '../config.js';
import { getPlayer } from '../board/query.js';
import type { GameState, ShipId } from '../types.js';
import { gameError } from '../types.js';
import { canFoundColony, placeColony } from '../found/colony.js';
import { tryPlacePendingTradeShips } from '../found/freeTradeShip.js';
import { pickableFriendshipCards, updateFriendshipMarker } from '../found/friendship.js';
import { canFoundTradeStation, placeTradeStation } from '../found/station.js';
import { refreshSpeed } from '../flight/stats.js';
import { checkSpecialTokensForPlayer } from '../flight/tokens.js';
import type { ActionModule, Handler, HandlerMap } from './handler.js';
import { logEvent } from './handler.js';

/** A trade ship parked on a docking point must found before anything else happens. */
function pendingFoundBlocks(state: GameState, shipId: ShipId) {
  const pending = state.turn.pendingFound;
  if (pending !== undefined && pending !== shipId) {
    return gameError('ruleViolation', `${pending} ended on a docking point and must found a trade station first`, {
      pendingFound: pending,
    });
  }
  return null;
}

const handleFoundColony: Handler<'foundColony'> = (state, action) => {
  const player = getPlayer(state, action.playerId);
  if (typeof action.shipId !== 'string') return gameError('invalidAction', 'foundColony needs a shipId');
  const blocked = pendingFoundBlocks(state, action.shipId);
  if (blocked) return blocked;
  const error = canFoundColony(state, action.shipId);
  if (error) return error;

  const nodeId = placeColony(state, action.shipId);
  logEvent(state, `${player.name} founded a colony at ${nodeId} (${action.shipId} returned to the supply)`, player.id);
  tryPlacePendingTradeShips(state, player.id);
  return state;
};

const handleFoundTradeStation: Handler<'foundTradeStation'> = (state, action) => {
  const player = getPlayer(state, action.playerId);
  if (typeof action.shipId !== 'string') return gameError('invalidAction', 'foundTradeStation needs a shipId');
  const blocked = pendingFoundBlocks(state, action.shipId);
  if (blocked) return blocked;
  const ship = state.board.ships[action.shipId];
  if (!ship) return gameError('invalidTarget', `Unknown ship ${action.shipId}`, { shipId: action.shipId });
  const error = canFoundTradeStation(state, action.shipId, ship.nodeId);
  if (error) return error;

  // Validation above guarantees an outpost with docks at the ship's node.
  const outpost = Object.values(state.board.sectors).find((s) => s.dockingPointId === ship.nodeId);
  const docks = outpost?.docks;
  const civ = outpost?.civ;
  if (!outpost || !docks || !civ) return gameError('invalidSite', `${ship.nodeId} is not a docking point`);

  const { dockIndex, friendshipCardId } = action;
  if (!Number.isInteger(dockIndex) || dockIndex < 0 || dockIndex >= docks.length) {
    return gameError('invalidSite', `dockIndex must be 0–${docks.length - 1}`, { dockIndex });
  }
  if (docks[dockIndex] !== null) {
    return gameError('invalidSite', `Dock ${dockIndex} at the ${civ} outpost is already taken`, { dockIndex, by: docks[dockIndex] });
  }
  if (!pickableFriendshipCards(state, civ).includes(friendshipCardId)) {
    return gameError('invalidTarget', `${String(friendshipCardId)} is not an available ${civ} friendship card`, {
      friendshipCardId,
      available: pickableFriendshipCards(state, civ),
    });
  }

  placeTradeStation(state, action.shipId, dockIndex, friendshipCardId);
  delete state.turn.pendingFound;

  const previousHolder = state.friendshipMarkers[civ];
  const holder = updateFriendshipMarker(state, civ);
  const card = FRIENDSHIP_CARDS[friendshipCardId];
  logEvent(
    state,
    `${player.name} founded a trade station at the ${civ} outpost (dock ${dockIndex}) and took ${card.name}`,
    player.id,
  );
  if (holder !== previousHolder && holder !== null) {
    logEvent(state, `${getPlayer(state, holder).name} takes the ${civ} friendship marker`, holder);
  }

  // Effects start immediately (§8): a Scientists speed card taken mid-flight
  // raises this turn's remaining speed, so re-derive `turn.speed`; a combat
  // bonus may let another ship already next to a pirate base defeat it (§9.6).
  if (card.effect.kind === 'combatBonus') {
    if (state.turn.speed !== undefined) refreshSpeed(state);
    checkSpecialTokensForPlayer(state, player.id);
  }

  tryPlacePendingTradeShips(state, player.id);
  return state;
};

export const handlers: HandlerMap = {
  foundColony: handleFoundColony,
  foundTradeStation: handleFoundTradeStation,
};

export const foundModule: ActionModule = { handlers };
