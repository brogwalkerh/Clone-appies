/**
 * `applyAction(state, action, rng)` — the engine's single entry point.
 *
 *   validate player / phase / turn  →  clone state  →  dispatch to handler
 *   →  recompute VP  →  post-action hooks (win check …)  →  append log entry
 *
 * Handler modules register themselves in `MODULES`; adding behaviour means
 * filling `production.ts`, `tradeBuild.ts` or `turn.ts`, never editing this
 * file. Unhandled action types are rejected with `notImplemented`.
 */

import type { Rng } from '../rng.js';
import type { Action, ActionType, GameState, LogEntry, Result } from '../types.js';
import { err, gameError, isGameError, ok } from '../types.js';
import { recomputeAllVp } from '../vp.js';
import type { ActionModule, Handler, HandlerMap, PostActionHook } from './handler.js';
import { ACTION_POLICY } from './policy.js';
import { flightModule } from './flight.js';
import { productionModule } from './production.js';
import { tradeBuildModule } from './tradeBuild.js';
import { turnModule } from './turn.js';
import { foundModule } from './found.js';

export type { ActionModule, Handler, HandlerMap, PostActionHook } from './handler.js';
export { logEvent } from './handler.js';
export { ACTION_POLICY } from './policy.js';

const MODULES: readonly ActionModule[] = [productionModule, tradeBuildModule, flightModule, turnModule, foundModule];

function assembleHandlers(modules: readonly ActionModule[]): HandlerMap {
  const map: HandlerMap = {};
  for (const m of modules) {
    for (const [type, handler] of Object.entries(m.handlers) as [ActionType, Handler<ActionType>][]) {
      if (map[type]) throw new Error(`applyAction: handler for '${type}' registered twice`);
      (map as Record<string, unknown>)[type] = handler;
    }
  }
  return map;
}

const HANDLERS: HandlerMap = assembleHandlers(MODULES);
const POST_HOOKS: readonly PostActionHook[] = MODULES.flatMap((m) => m.postHooks ?? []);

/** Pure pre-checks shared by every action; `null` when the action may proceed. */
export function validateActionEnvelope(state: GameState, action: Action) {
  if (state.phase === 'gameOver' || state.winner !== null) {
    return gameError('gameOver', 'The game is over');
  }
  if (!state.players.some((p) => p.id === action.playerId)) {
    return gameError('unknownPlayer', `Unknown player ${action.playerId}`);
  }
  const policy = ACTION_POLICY[action.type];
  if (!policy) {
    return gameError('invalidAction', `Unknown action type ${String((action as { type: unknown }).type)}`);
  }
  if (!policy.phases.includes(state.phase)) {
    return gameError('wrongPhase', `${action.type} is not allowed during ${state.phase}`, {
      phase: state.phase,
      allowed: [...policy.phases],
    });
  }
  if (policy.activePlayerOnly && state.activePlayer !== action.playerId) {
    return gameError('notYourTurn', `${action.type} may only be sent by the active player`);
  }
  return null;
}

export function applyAction(state: GameState, action: Action, rng: Rng): Result<GameState> {
  const envelopeError = validateActionEnvelope(state, action);
  if (envelopeError) return err(envelopeError);

  const handler = HANDLERS[action.type] as Handler<typeof action.type> | undefined;
  if (!handler) {
    return err(gameError('notImplemented', `Action '${action.type}' is not implemented yet`));
  }

  const next = structuredClone(state);
  const outcome = handler(next, action, rng);
  if (isGameError(outcome)) return err(outcome);

  recomputeAllVp(outcome);
  for (const hook of POST_HOOKS) hook(outcome, action, rng);

  const entry: LogEntry = {
    seq: outcome.log.length,
    turnNumber: outcome.turnNumber,
    playerId: action.playerId,
    kind: 'action',
    action,
    message: action.type,
  };
  outcome.log.push(entry);
  return ok(outcome);
}

/** Action types that currently have a handler (useful for clients / tests). */
export function implementedActions(): ActionType[] {
  return Object.keys(HANDLERS) as ActionType[];
}
