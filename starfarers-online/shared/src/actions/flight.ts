/**
 * FLIGHT phase handlers (spec §5.3, §9):
 *   shakeMothership — the transition out of Trade & Build. 0 ships on the
 *                     board → flight is skipped (§5.3a): baseSpeed = speed = 0,
 *                     phase 'flight.move' where nothing but endTurn can do
 *                     anything. Otherwise draw 2 balls: black → baseSpeed 3 and
 *                     an encounter (`startEncounter`, encounters/engine.ts:
 *                     top card → `turn.encounter`, phase 'flight.encounter');
 *                     else baseSpeed = sum, phase 'flight.move'. `turn.speed`
 *                     is set from `speedOf`. Before
 *                     the balls are drawn, every ship already adjacent to a
 *                     pirate base / ice planet whose threshold the player now
 *                     meets (upgrades built this Trade & Build) claims it —
 *                     §9.6 is "immediately", at the latest when flight starts,
 *                     and a parked colony ship may then found there.
 *   moveShip        — move one of your ships along `path` (nodes after the
 *                     current one), see flight/movement.ts.
 *   encounterChoice / encounterPick live in actions/encounter.ts.
 *
 * Once shaken, the reserve draw is forfeited: ACTION_POLICY only allows
 * `takeReserveDraw` in 'production' / 'tradeBuild'.
 *
 * While `turn.pendingFound` is set (a trade ship just docked) every handler in
 * this module rejects with `ruleViolation`; only `foundTradeStation` may run.
 */

import { getPlayer, shipsOf } from '../board/query.js';
import { startEncounter } from '../encounters/engine.js';
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

  if (!startEncounter(state, rng)) {
    logEvent(state, 'Black ball, but no encounter card is left; flight continues', player.id);
    state.phase = 'flight.move';
  }
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

export const handlers: HandlerMap = {
  shakeMothership: handleShakeMothership,
  moveShip: handleMoveShip,
};

export const flightModule: ActionModule = { handlers };
