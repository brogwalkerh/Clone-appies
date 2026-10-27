/**
 * Shared fixtures for the trade / build / turn tests. Builds a beginner game
 * with a fixed seed and jumps straight to the Trade & Build phase so the tests
 * do not depend on the production handlers.
 */

import { expect } from 'vitest';
import { applyAction } from '../../src/actions/index.js';
import { createRng, type Rng } from '../../src/rng.js';
import { createBeginnerGame, type PlayerSpec } from '../../src/setup/beginner.js';
import { getPlayer } from '../../src/board/query.js';
import type { Action, GameErrorCode, GameState, Player, PlayerId, Resource } from '../../src/types.js';

export const THREE: PlayerSpec[] = [
  { id: 'p1', name: 'Ann', color: 'red' },
  { id: 'p2', name: 'Bob', color: 'blue' },
  { id: 'p3', name: 'Cid', color: 'yellow' },
];

/** Beginner game in phase 'tradeBuild' with the given seed. */
export function tradeBuildState(seed = 'trade-build'): GameState {
  const state = createBeginnerGame({ players: THREE, seed });
  state.phase = 'tradeBuild';
  return state;
}

export function rng(seed = 'test-rng'): Rng {
  return createRng(seed);
}

export function player(state: GameState, id: PlayerId): Player {
  return getPlayer(state, id);
}

/** Players other than the active one, in turn order starting left of the active player. */
export function opponents(state: GameState): Player[] {
  const i = state.turnOrder.indexOf(state.activePlayer);
  const ids = [...state.turnOrder.slice(i + 1), ...state.turnOrder.slice(0, i)];
  return ids.map((id) => getPlayer(state, id));
}

export function setHand(state: GameState, id: PlayerId, hand: Resource[]): void {
  getPlayer(state, id).hand = [...hand];
}

/** Apply an action that must succeed; returns the new state. */
export function ok(state: GameState, action: Action, r: Rng = rng()): GameState {
  const result = applyAction(state, action, r);
  if (!result.ok) throw new Error(`Expected ${action.type} to succeed, got ${result.error.code}: ${result.error.message}`);
  return result.value;
}

/** Apply an action that must fail with `code`; asserts the input state is untouched. */
export function fails(state: GameState, action: Action, code: GameErrorCode, r: Rng = rng()): void {
  const before = structuredClone(state);
  const result = applyAction(state, action, r);
  expect(result.ok, `expected ${action.type} to fail with ${code}`).toBe(false);
  if (!result.ok) expect(result.error.code, result.error.message).toBe(code);
  expect(state).toEqual(before);
}

export function supplyTotal(state: GameState): number {
  return Object.values(state.supply).reduce((a, b) => a + b, 0);
}

/** Total cards in play (supply + reserve + every hand) — must be conserved by trades/builds. */
export function cardsInPlay(state: GameState): number {
  return supplyTotal(state) + state.reservePile.length + state.players.reduce((n, p) => n + p.hand.length, 0);
}
