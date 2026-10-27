import { describe, expect, it } from 'vitest';
import { applyAction, implementedActions } from '../src/actions/index.js';
import { createRng } from '../src/rng.js';
import { createBeginnerGame } from '../src/setup/beginner.js';

const players = [
  { id: 'p1', name: 'Ann', color: 'red' as const },
  { id: 'p2', name: 'Bob', color: 'blue' as const },
  { id: 'p3', name: 'Cid', color: 'yellow' as const },
];

describe('applyAction skeleton', () => {
  const state = createBeginnerGame({ players, seed: 'actions' });
  const rng = createRng('actions-rng');

  it('rejects unknown players', () => {
    const r = applyAction(state, { type: 'rollDice', playerId: 'ghost' }, rng);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error.code).toBe('unknownPlayer');
  });

  it('rejects the wrong phase', () => {
    const r = applyAction(state, { type: 'build', playerId: state.activePlayer, item: 'booster' }, rng);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error.code).toBe('wrongPhase');
  });

  it('rejects non-active players for active-only actions', () => {
    const other = state.players.find((p) => p.id !== state.activePlayer)!;
    const r = applyAction(state, { type: 'rollDice', playerId: other.id }, rng);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error.code).toBe('notYourTurn');
  });

  it('reports notImplemented for valid-but-unhandled actions and leaves the state untouched', () => {
    const before = structuredClone(state);
    const r = applyAction(state, { type: 'rollDice', playerId: state.activePlayer }, rng);
    if (implementedActions().includes('rollDice')) {
      expect(r.ok).toBe(true);
    } else {
      expect(r.ok).toBe(false);
      if (!r.ok) expect(r.error.code).toBe('notImplemented');
    }
    expect(state).toEqual(before);
  });

  it('rejects everything once the game is over', () => {
    const over = structuredClone(state);
    over.phase = 'gameOver';
    over.winner = 'p1';
    const r = applyAction(over, { type: 'endTurn', playerId: 'p1' }, rng);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error.code).toBe('gameOver');
  });
});
