/**
 * FLIGHT phase handlers (spec §5.3, §9):
 *   shakeMothership — the transition out of Trade & Build. 0 ships on the
 *                     board → flight is skipped (§5.3a): baseSpeed = speed = 0,
 *                     phase 'flight.move' where nothing but endTurn can do
 *                     anything. Otherwise draw 2 balls: black → baseSpeed 3 and
 *                     an encounter (top card of `encounterDeck` → `turn.encounter`,
 *                     phase 'flight.encounter'); else baseSpeed = sum, phase
 *                     'flight.move'. `turn.speed` is set from `speedOf`. Before
 *                     the balls are drawn, every ship already adjacent to a
 *                     pirate base / ice planet whose threshold the player now
 *                     meets (upgrades built this Trade & Build) claims it —
 *                     §9.6 is "immediately", at the latest when flight starts,
 *                     and a parked colony ship may then found there.
 *   moveShip        — move one of your ships along `path` (nodes after the
 *                     current one), see flight/movement.ts.
 *   encounterChoice / encounterPick — placeholders until the encounter module
 *                     (phase 3) replaces them; they return `notImplemented`.
 *
 * Once shaken, the reserve draw is forfeited: ACTION_POLICY only allows
 * `takeReserveDraw` in 'production' / 'tradeBuild'.
 *
 * Temporary switch `ENCOUNTERS_ENABLED.value === false` (config.ts): a black
 * shake still gives base speed 3 but the card is discarded and the turn goes
 * straight to 'flight.move'. Remove once phase 3 lands.
 *
 * While `turn.pendingFound` is set (a trade ship just docked) every handler in
 * this module rejects with `ruleViolation`; only `foundTradeStation` may run.
 */

import { BLACK_BALL_BASE_SPEED, ENCOUNTERS_ENABLED } from '../config.js';
import { getPlayer, shipsOf } from '../board/query.js';
import type { Rng } from '../rng.js';
import type { GameError, GameState } from '../types.js';
import { gameError } from '../types.js';
import { applyMove, stepsLeft, validateEndNode, validatePath } from '../flight/movement.js';
import { evaluateShake, drawBalls } from '../flight/shake.js';
import { refreshSpeed } from '../flight/stats.js';
import { checkSpecialTokensForPlayer } from '../flight/tokens.js';
import type { ActionModule, Handler, HandlerMap } from './handler.js';
import { logEvent } from './handler.js';

/** Shared guard: a docked trade ship must found before anything else happens. */
export function pendingFoundError(state: GameState): GameError | null {
  if (state.turn.pendingFound === undefined) return null;
  return gameError('ruleViolation', `${state.turn.pendingFound} must found a trade station first`, {
    shipId: state.turn.pendingFound,
  });
}

/** Top card of the encounter deck, reshuffling the discard pile when the deck is empty. */
function drawEncounterCard(state: GameState, rng: Rng): number | undefined {
  if (state.encounterDeck.length === 0 && state.encounterDiscard.length > 0) {
    state.encounterDeck = rng.shuffle(state.encounterDiscard);
    state.encounterDiscard = [];
    logEvent(state, 'Encounter discard pile reshuffled into a new deck', null);
  }
  return state.encounterDeck.shift();
}

const handleShakeMothership: Handler<'shakeMothership'> = (state, action, rng) => {
  const pending = pendingFoundError(state);
  if (pending) return pending;
  if (state.turn.baseSpeed !== undefined) {
    return gameError('ruleViolation', 'The mothership has already been shaken this turn');
  }
  const player = getPlayer(state, action.playerId);
  state.openTrade = null;

  if (shipsOf(state, player.id).length === 0) {
    state.turn.baseSpeed = 0;
    state.turn.speed = 0;
    state.phase = 'flight.move';
    logEvent(state, `${player.name} has no ships on the board; flight is skipped`, player.id);
    return state;
  }

  // Ships already next to a pirate base / ice planet claim it now (§9.6).
  checkSpecialTokensForPlayer(state, player.id);

  const result = evaluateShake(drawBalls(rng));
  state.turn.shake = result.balls;
  state.turn.baseSpeed = result.baseSpeed;
  refreshSpeed(state);
  logEvent(state, `${player.name} shook the mothership: ${result.balls.join(' + ')} → base speed ${result.baseSpeed}, speed ${state.turn.speed}`, player.id);

  if (!result.black) {
    state.phase = 'flight.move';
    return state;
  }

  const cardId = drawEncounterCard(state, rng);
  if (cardId === undefined) {
    logEvent(state, 'Black ball, but no encounter card is left; flight continues', player.id);
    state.phase = 'flight.move';
    return state;
  }
  if (!ENCOUNTERS_ENABLED.value) {
    state.encounterDiscard.push(cardId);
    logEvent(state, `Black ball: encounter card ${cardId} drawn and discarded (encounters disabled), base speed ${BLACK_BALL_BASE_SPEED}`, player.id);
    state.phase = 'flight.move';
    return state;
  }
  state.turn.encounter = { cardId, step: 'pending' };
  state.phase = 'flight.encounter';
  logEvent(state, `Black ball: encounter card ${cardId} drawn`, player.id);
  return state;
};

const handleMoveShip: Handler<'moveShip'> = (state, action) => {
  const pending = pendingFoundError(state);
  if (pending) return pending;
  const player = getPlayer(state, action.playerId);
  const ship = state.board.ships[action.shipId];
  if (!ship) return gameError('invalidTarget', `Unknown ship ${action.shipId}`, { shipId: action.shipId });
  if (ship.owner !== player.id) return gameError('invalidTarget', `${ship.id} is not your ship`, { shipId: ship.id });
  if (state.turn.immobilized.includes(ship.id)) {
    return gameError('ruleViolation', `${ship.id} cannot move this turn`, { shipId: ship.id });
  }
  const pathError = validatePath(state, ship, action.path);
  if (pathError) return pathError;
  const left = stepsLeft(state, ship.id);
  if (action.path.length > left) {
    return gameError('ruleViolation', `${ship.id} has ${left} step${left === 1 ? '' : 's'} left this turn, path needs ${action.path.length}`, {
      shipId: ship.id,
      speed: state.turn.speed ?? 0,
      used: state.turn.shipMovesUsed[ship.id] ?? 0,
      requested: action.path.length,
    });
  }
  const end = action.path[action.path.length - 1]!;
  const endError = validateEndNode(state, ship, end);
  if (endError) return endError;

  applyMove(state, ship, action.path);
  return state;
};

const notYetImplemented = (type: string): GameError =>
  gameError('notImplemented', `Action '${type}' is not implemented yet (encounter module, phase 3)`);

const handleEncounterChoice: Handler<'encounterChoice'> = (_state, action) => notYetImplemented(action.type);
const handleEncounterPick: Handler<'encounterPick'> = (_state, action) => notYetImplemented(action.type);

export const handlers: HandlerMap = {
  shakeMothership: handleShakeMothership,
  moveShip: handleMoveShip,
  encounterChoice: handleEncounterChoice,
  encounterPick: handleEncounterPick,
};

export const flightModule: ActionModule = { handlers };
