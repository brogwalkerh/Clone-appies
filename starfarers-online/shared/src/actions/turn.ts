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
 */

import { WIN_VP } from '../config.js';
import { getPlayer, playerToLeft } from '../board/query.js';
import type { GameState, TurnState } from '../types.js';
import type { ActionModule, Handler, HandlerMap, PostActionHook } from './handler.js';
import { logEvent } from './handler.js';

/** Fresh per-turn bookkeeping for the next player. */
export function freshTurnState(): TurnState {
  return { reserveDrawTaken: false, shipMovesUsed: {}, immobilized: [], usedOncePerTurn: [] };
}

const handleEndTurn: Handler<'endTurn'> = (state, action) => {
  const ending = getPlayer(state, action.playerId);
  state.openTrade = null;
  const next = playerToLeft(state, state.activePlayer);
  state.activePlayer = next;
  state.turnNumber += 1;
  state.turn = freshTurnState();
  state.phase = 'production';
  logEvent(state, `${ending.name} ended their turn; ${getPlayer(state, next).name} is up`, ending.id);
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
