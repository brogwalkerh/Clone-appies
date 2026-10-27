import { describe, expect, it } from 'vitest';
import { createBeginnerGame } from '../src/setup/beginner.js';
import { computeVp } from '../src/vp.js';
import type { GameState } from '../src/types.js';

function baseState(): GameState {
  return createBeginnerGame({
    seed: 'vp',
    players: [
      { id: 'a', name: 'A', color: 'red' },
      { id: 'b', name: 'B', color: 'blue' },
      { id: 'c', name: 'C', color: 'yellow' },
    ],
  });
}

describe('computeVp', () => {
  it('counts colonies 1, spaceports 2 (once), markers 2, medals 1 and floor(fame/2)', () => {
    const state = baseState();
    // Strip player a's starting pieces and build a hand-made position.
    for (const [id, s] of Object.entries(state.board.settlements)) {
      if (s.owner === 'a') delete state.board.settlements[id];
    }
    expect(computeVp(state, 'a')).toBe(0);

    state.board.settlements['N(5,8)'] = { nodeId: 'N(5,8)', kind: 'colony', color: 'red', owner: 'a' };
    state.board.settlements['S(5,8)'] = { nodeId: 'S(5,8)', kind: 'colony', color: 'red', owner: 'a' };
    expect(computeVp(state, 'a')).toBe(2);

    state.board.settlements['N(6,8)'] = { nodeId: 'N(6,8)', kind: 'spaceport', color: 'red', owner: 'a' };
    expect(computeVp(state, 'a')).toBe(4);

    state.friendshipMarkers.merchants = 'a';
    expect(computeVp(state, 'a')).toBe(6);
    state.friendshipMarkers.diplomats = 'b';
    expect(computeVp(state, 'a')).toBe(6);

    const a = state.players.find((p) => p.id === 'a')!;
    a.medals.pirate = 1;
    a.medals.ice = 2;
    expect(computeVp(state, 'a')).toBe(9);

    a.famePieces = 0;
    expect(computeVp(state, 'a')).toBe(9);
    a.famePieces = 1;
    expect(computeVp(state, 'a')).toBe(9);
    a.famePieces = 2;
    expect(computeVp(state, 'a')).toBe(10);
    a.famePieces = 5;
    expect(computeVp(state, 'a')).toBe(11);
    a.famePieces = -3;
    expect(computeVp(state, 'a')).toBe(9);
  });

  it('ignores blocker pieces and other players', () => {
    const state = baseState();
    expect(state.blockerColor).not.toBeNull();
    const blockers = Object.values(state.board.settlements).filter((s) => s.owner === null);
    expect(blockers).toHaveLength(3);
    for (const p of state.players) expect(computeVp(state, p.id)).toBe(4);
    expect(() => computeVp(state, 'nobody')).toThrow();
  });
});
