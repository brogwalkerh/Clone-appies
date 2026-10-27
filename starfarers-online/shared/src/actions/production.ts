/**
 * PRODUCTION phase handlers (spec §5.1, §6):
 *   rollDice, takeReserveDraw, discardForSeven, stealForSeven
 *
 * Owns `state.turn.rolled`, `state.turn.reserveDrawTaken`, `state.turn.seven`,
 * `state.turn.productionReceived` and the production → tradeBuild transition.
 *
 * Phase model for a 7: the phase stays 'production' while `turn.seven` is
 * unresolved. Resolution order (§6): discards → steal → opponent reserve draws
 * → phase 'tradeBuild' (the roller's own VP-based reserve draw is then taken
 * with `takeReserveDraw`, as on any other roll).
 */

import { reserveDrawFor } from '../config.js';
import { getPlayer } from '../board/query.js';
import type { Rng } from '../rng.js';
import { applyProduction } from '../production/produce.js';
import {
  discardCountFor,
  opponentReserveDraws,
  playersWhoMustDiscard,
  stealTargets,
} from '../production/seven.js';
import { drawFromReserve, handHas, handToBag, removeFromHand, returnToSupply } from '../supply.js';
import type { GameState, PlayerId } from '../types.js';
import { gameError } from '../types.js';
import { logEvent, type ActionModule, type Handler, type HandlerMap } from './handler.js';

export { reliefEligible } from '../production/relief.js';

/** Steal (if possible), then opponent draws and the phase change. */
function finishSeven(state: GameState, rng: Rng): void {
  const seven = state.turn.seven;
  if (!seven) return;
  opponentReserveDraws(state, state.activePlayer, rng);
  seven.stealDone = true;
  state.phase = 'tradeBuild';
}

/** Called when no discards are pending: wait for the steal or skip it. */
function afterDiscards(state: GameState, rng: Rng): void {
  if (stealTargets(state, state.activePlayer).length > 0) return; // awaiting stealForSeven
  logEvent(state, 'No opponent holds a card: the steal is skipped');
  finishSeven(state, rng);
}

const rollDice: Handler<'rollDice'> = (state, _action, rng) => {
  if (state.turn.rolled !== undefined) {
    return gameError('ruleViolation', 'The dice have already been rolled this turn', { rolled: state.turn.rolled });
  }
  const roll = rng.d6() + rng.d6();
  state.turn.rolled = roll;
  state.turn.reserveDrawTaken = false;
  const roller = getPlayer(state, state.activePlayer);
  logEvent(state, `${roller.name} rolls a ${roll}`);

  if (roll === 7) {
    const awaitingDiscard = playersWhoMustDiscard(state, state.activePlayer);
    state.turn.seven = { awaitingDiscard, stealDone: false };
    for (const id of awaitingDiscard) {
      const p = getPlayer(state, id);
      logEvent(state, `${p.name} must discard ${discardCountFor(p.hand.length)} cards`, id);
    }
    if (awaitingDiscard.length === 0) afterDiscards(state, rng);
    return state;
  }

  applyProduction(state, roll);
  state.phase = 'tradeBuild';
  return state;
};

const discardForSeven: Handler<'discardForSeven'> = (state, action, rng) => {
  const seven = state.turn.seven;
  if (!seven) return gameError('ruleViolation', 'No 7 is being resolved');
  if (!seven.awaitingDiscard.includes(action.playerId)) {
    return gameError('ruleViolation', 'You do not have to discard', { awaiting: [...seven.awaitingDiscard] });
  }
  const player = getPlayer(state, action.playerId);
  const required = discardCountFor(player.hand.length);
  if (action.cards.length !== required) {
    return gameError('invalidAction', `You must discard exactly ${required} cards`, { required, given: action.cards.length });
  }
  const bag = handToBag(action.cards);
  if (!handHas(player.hand, bag)) {
    return gameError('insufficientResources', 'You do not hold all of those cards');
  }
  removeFromHand(player.hand, bag);
  returnToSupply(state, bag);
  seven.awaitingDiscard = seven.awaitingDiscard.filter((id) => id !== action.playerId);
  logEvent(state, `${player.name} discards ${required} cards`, action.playerId);
  if (seven.awaitingDiscard.length === 0) afterDiscards(state, rng);
  return state;
};

const stealForSeven: Handler<'stealForSeven'> = (state, action, rng) => {
  const seven = state.turn.seven;
  if (!seven) return gameError('ruleViolation', 'No 7 is being resolved');
  if (seven.awaitingDiscard.length > 0) {
    return gameError('ruleViolation', 'Players still have to discard', { awaiting: [...seven.awaitingDiscard] });
  }
  if (seven.stealDone) return gameError('ruleViolation', 'The steal has already been resolved');
  const targets = stealTargets(state, action.playerId);
  if (!targets.includes(action.target)) {
    return gameError('invalidTarget', 'Target must be an opponent holding at least one card', { targets });
  }
  const roller = getPlayer(state, action.playerId);
  const victim = getPlayer(state, action.target);
  const [card] = victim.hand.splice(rng.int(victim.hand.length), 1);
  if (card) roller.hand.push(card);
  logEvent(state, `${roller.name} steals a card from ${victim.name}`);
  finishSeven(state, rng);
  return state;
};

const takeReserveDraw: Handler<'takeReserveDraw'> = (state, action, rng) => {
  if (state.turn.rolled === undefined) return gameError('ruleViolation', 'Roll the dice first');
  if (state.phase === 'production' && state.turn.seven && !state.turn.seven.stealDone) {
    return gameError('ruleViolation', 'Resolve the 7 before taking the reserve draw');
  }
  if (state.turn.reserveDrawTaken) return gameError('ruleViolation', 'The reserve draw was already taken this turn');
  const player = getPlayer(state, action.playerId);
  const count = reserveDrawFor(player.vp);
  const drawn = drawFromReserve(state, count, rng);
  player.hand.push(...drawn);
  state.turn.reserveDrawTaken = true;
  logEvent(state, `${player.name} draws ${drawn.length} card(s) from the reserve pile (${player.vp} VP)`);
  return state;
};

export const handlers: HandlerMap = { rollDice, discardForSeven, stealForSeven, takeReserveDraw };

export const productionModule: ActionModule = { handlers };

/** Convenience for clients: the ids the engine is waiting on while a 7 is resolved. */
export function sevenWaitingOn(state: GameState): PlayerId[] {
  const seven = state.turn.seven;
  if (!seven || state.phase !== 'production') return [];
  if (seven.awaitingDiscard.length > 0) return [...seven.awaitingDiscard];
  return seven.stealDone ? [] : [state.activePlayer];
}
