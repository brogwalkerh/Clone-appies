/** Shared test fixtures: a beginner game and helpers to jump to a phase. */

import { createBeginnerGame, refreshSpeed, type GameState, type PlayerSpec, type ShipId } from '@starfarers/shared';
import type { GameSetup } from '../src/store/gameStore.js';

export const PLAYERS: PlayerSpec[] = [
  { id: 'p1', name: 'Ann', color: 'red' },
  { id: 'p2', name: 'Bob', color: 'blue' },
  { id: 'p3', name: 'Cid', color: 'yellow' },
];

export function setup(seed = 'client-test'): GameSetup {
  return { players: PLAYERS, seed };
}

export function game(seed = 'client-test'): GameState {
  return createBeginnerGame({ players: PLAYERS, seed });
}

/** Put the active player into flight.move with the given base speed. */
export function inFlight(state: GameState, baseSpeed = 3): GameState {
  const s = structuredClone(state);
  s.phase = 'flight.move';
  s.turn.rolled = 6;
  s.turn.baseSpeed = baseSpeed;
  refreshSpeed(s);
  return s;
}

export function shipsOfActive(state: GameState): ShipId[] {
  return Object.values(state.board.ships)
    .filter((sh) => sh.owner === state.activePlayer)
    .map((sh) => sh.id);
}
