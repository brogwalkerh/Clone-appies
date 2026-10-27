/**
 * Turn flow (spec §4 win, §5 structure):
 *   endTurn — advance `activePlayer` along `turnOrder`, reset `state.turn`,
 *             bump `turnNumber`, phase → 'production'.
 *   Win check — a `PostActionHook` that sets `state.winner` and
 *             `phase = 'gameOver'` when the ACTIVE player has >= WIN_VP
 *             (spec §4: only on their own turn). Registered in `postHooks`.
 *
 * "On their own turn" (spec §4): a player who reaches 15 VP while somebody
 * else is active (e.g. through a trade or a Helping Hand draw) is not the
 * winner yet. `applyAction` runs the hook after every action, including
 * `endTurn`, and by then `activePlayer` already points at the next player, so
 * a player who starts their turn with >= 15 VP wins at that moment, before
 * rolling. Reaching 15 while active (spaceport, fame, marker …) wins
 * immediately after the action that got them there.
 *
 * Flight gating (spec §5.3, §9.2), see `flightEndTurnError`:
 *   - from 'tradeBuild' only when the player has 0 ships on the board (else
 *     "shake the mothership first"); from 'flight.move' always;
 *   - never while `turn.pendingFound` is set (a docked trade ship must found);
 *   - a ship flagged `mustFoundOrLeave` on an earlier turn that is still on a
 *     colony site must have founded or left, unless it is immobilized this
 *     turn; one flagged on an opponent's spaceport site (§7.2) must have left
 *     if it could move at all (speed > 0, not immobilized, some legal end node
 *     among its neighbours);
 *   - afterwards every colony ship of the ending player resting on a colony
 *     site is flagged `mustFoundOrLeave`, and every ship's `leftSite` is cleared.
 */

import { WIN_VP } from '../config.js';
import { getPlayer, neighborsOf, playerToLeft, shipsOf } from '../board/query.js';
import { validateEndNode } from '../flight/movement.js';
import { tryPlacePendingTradeShips } from '../found/freeTradeShip.js';
import type { GameError, GameState, TurnState } from '../types.js';
import { gameError } from '../types.js';
import type { ActionModule, Handler, HandlerMap, PostActionHook } from './handler.js';
import { logEvent } from './handler.js';

/** Fresh per-turn bookkeeping for the next player. */
export function freshTurnState(): TurnState {
  return { reserveDrawTaken: false, shipMovesUsed: {}, immobilized: [], usedOncePerTurn: [] };
}

/** Flight-phase reasons the active player may not end their turn yet; `null` when fine. */
export function flightEndTurnError(state: GameState): GameError | null {
  const ending = getPlayer(state, state.activePlayer);
  const ships = shipsOf(state, ending.id);
  if (state.phase === 'tradeBuild' && ships.length > 0) {
    return gameError('ruleViolation', 'Shake the mothership first (flight phase)', { ships: ships.map((s) => s.id) });
  }
  if (state.turn.pendingFound !== undefined) {
    return gameError('ruleViolation', `${state.turn.pendingFound} must found a trade station first`, {
      shipId: state.turn.pendingFound,
    });
  }
  for (const ship of ships) {
    if (!ship.mustFoundOrLeave || state.turn.immobilized.includes(ship.id)) continue;
    const node = state.board.nodes[ship.nodeId];
    if (node?.siteType === 'colonySite') {
      return gameError('ruleViolation', `${ship.id} must found a colony at ${ship.nodeId} or leave it this turn`, { shipId: ship.id });
    }
    // Flagged on an opponent's new spaceport site (§7.2): must leave if it can.
    const canMove =
      (state.turn.speed ?? 0) > 0 &&
      neighborsOf(state.board, ship.nodeId).some((n) => validateEndNode(state, ship, n) === null);
    if (canMove) {
      return gameError('ruleViolation', `${ship.id} sits on an opponent's spaceport site and must move away this turn`, { shipId: ship.id });
    }
  }
  return null;
}

/** Flag parked colony ships and clear per-turn ship fields (runs on a successful endTurn). */
function flightEndTurnBookkeeping(state: GameState): void {
  const ending = getPlayer(state, state.activePlayer);
  for (const ship of Object.values(state.board.ships)) {
    delete ship.leftSite;
    if (ship.owner !== ending.id || ship.kind !== 'colony' || ship.mustFoundOrLeave) continue;
    if (state.board.nodes[ship.nodeId]?.siteType === 'colonySite') {
      ship.mustFoundOrLeave = true;
      logEvent(state, `${ending.name}'s ship ${ship.id} is parked on colony site ${ship.nodeId} and must found or leave next turn`, ending.id);
    }
  }
}

const handleEndTurn: Handler<'endTurn'> = (state, action) => {
  const blocked = flightEndTurnError(state);
  if (blocked) return blocked;
  flightEndTurnBookkeeping(state);
  const ending = getPlayer(state, action.playerId);
  state.openTrade = null;
  const next = playerToLeft(state, state.activePlayer);
  state.activePlayer = next;
  state.turnNumber += 1;
  state.turn = freshTurnState();
  state.phase = 'production';
  logEvent(state, `${ending.name} ended their turn; ${getPlayer(state, next).name} is up`, ending.id);
  // §7.3: owed trade-ship markers are placed "as soon as possible" — at the latest when the owner's turn starts.
  const placed = tryPlacePendingTradeShips(state, next);
  if (placed > 0) logEvent(state, `${getPlayer(state, next).name} placed ${placed} pending trade ship${placed === 1 ? '' : 's'}`, next);
  return state;
};

/** Post-action hook: the active player wins the moment they hold >= WIN_VP. */
export const checkWin: PostActionHook = (state: GameState) => {
  if (state.winner !== null || state.phase === 'gameOver') return;
  const active = getPlayer(state, state.activePlayer);
  if (active.vp >= WIN_VP) {
    state.winner = active.id;
    state.phase = 'gameOver';
    logEvent(state, `${active.name} reaches ${active.vp} VP and wins the game`, active.id);
  }
};

export const handlers: HandlerMap = {
  endTurn: handleEndTurn,
};

export const postHooks: PostActionHook[] = [checkWin];

export const turnModule: ActionModule = { handlers, postHooks };
