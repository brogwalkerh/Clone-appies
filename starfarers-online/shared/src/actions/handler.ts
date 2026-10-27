/**
 * Handler contract shared by every action module.
 *
 * A handler receives an ALREADY-CLONED state and may mutate it freely. It
 * returns the (same) state on success or a `GameError` to reject the action, in
 * which case the caller discards the clone and the original state is untouched.
 * `applyAction` has already checked that the player exists, the game is not
 * over, the phase is allowed for this action type and (where required) that the
 * sender is the active player — see `policy.ts`.
 *
 * After a handler succeeds `applyAction` recomputes every player's cached `vp`,
 * runs the registered post-action hooks (e.g. the win check from turn.ts) and
 * appends a `LogEntry` for the action. Handlers may push their own `event` log
 * entries with `logEvent` for anything the generic entry would not capture.
 */

import type { Rng } from '../rng.js';
import type { Action, ActionOf, ActionType, GameError, GameState, LogEntry, PlayerId } from '../types.js';

export type Handler<T extends ActionType> = (state: GameState, action: ActionOf<T>, rng: Rng) => GameState | GameError;

/** A module's handlers: `{ rollDice: handleRollDice, ... }`. Missing entries are `notImplemented`. */
export type HandlerMap = { [T in ActionType]?: Handler<T> };

/**
 * Runs after any successful action (state already mutated, VP recomputed).
 * May mutate the state further (e.g. set `winner` / `phase = 'gameOver'`).
 */
export type PostActionHook = (state: GameState, action: Action, rng: Rng) => void;

export interface ActionModule {
  handlers: HandlerMap;
  postHooks?: PostActionHook[];
}

/** Append an `event` log entry (handlers use this for side-effects worth recording). */
export function logEvent(state: GameState, message: string, playerId: PlayerId | null = state.activePlayer): void {
  const entry: LogEntry = { seq: state.log.length, turnNumber: state.turnNumber, playerId, kind: 'event', message };
  state.log.push(entry);
}
