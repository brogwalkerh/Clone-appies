import type { Action, GameState } from '@starfarers/shared';
import { describe, expect, it } from 'vitest';
import { legalMoves } from '../src/board/legalMoves.js';
import { createGameStore } from '../src/store/gameStore.js';
import { PLAYERS, game, shipsOfActive } from './fixtures.js';

/**
 * Scripted full turn through the store with a seeded rng:
 * roll → build (booster) → shake → move → endTurn. Seeds are scanned until
 * one yields neither a 7 nor a black ball, so the script is deterministic.
 */
function runTurn(seed: string) {
  const store = createGameStore();
  const start: GameState = game(seed);
  const me = start.players.find((p) => p.id === start.activePlayer)!;
  me.hand = ['fuel', 'fuel', 'ore'];
  store.getState().loadGame({ players: PLAYERS, seed }, start);
  const d = (a: Action) => store.getState().dispatch(a);
  const g = () => store.getState().game!;
  const pid = me.id;

  if (!d({ type: 'rollDice', playerId: pid })) return null;
  if (g().turn.rolled === 7) return null;
  return { store, d, g, pid };
}

describe('scripted full turn', () => {
  it('plays roll → build → shake → move → endTurn and replays identically', () => {
    let run: ReturnType<typeof runTurn> = null;
    let seed = '';
    for (let i = 0; i < 50 && !run; i++) {
      seed = `full-turn-${i}`;
      run = runTurn(seed);
      if (run && run.g().turn.shake?.includes('black')) run = null;
      if (run) {
        // Shake now to check for a black ball; discard this seed if an encounter comes up.
        run.d({ type: 'build', playerId: run.pid, item: 'booster' });
        if (!run.d({ type: 'shakeMothership', playerId: run.pid }) || run.g().phase !== 'flight.move') run = null;
      }
    }
    expect(run, 'no seed without a 7 or a black ball in 50 tries').not.toBeNull();
    const { store, d, g, pid } = run!;
    const me = () => g().players.find((p) => p.id === pid)!;

    // Production happened and the build was paid.
    expect(g().turn.rolled).not.toBe(7);
    expect(me().mothership.boosters).toBe(2);
    expect(g().turn.speed).toBe((g().turn.baseSpeed ?? 0) + 2);

    // Move one ship to a highlighted node with the BFS path.
    const shipId = shipsOfActive(g())[0]!;
    const moves = legalMoves(g(), shipId);
    expect(moves.size).toBeGreaterThan(0);
    const [target, path] = [...moves.entries()].sort((a, b) => b[1].length - a[1].length)[0]!;
    expect(d({ type: 'moveShip', playerId: pid, shipId, path })).toBe(true);
    expect(g().board.ships[shipId]?.nodeId).toBe(target);
    expect(g().turn.shipMovesUsed[shipId]).toBe(path.length);

    // End the turn: next player, production phase, laptop must be passed.
    expect(d({ type: 'endTurn', playerId: pid })).toBe(true);
    expect(g().activePlayer).not.toBe(pid);
    expect(g().phase).toBe('production');
    expect(g().turnNumber).toBe(2);
    expect(store.getState().pendingViewer).toBe(g().activePlayer);
    expect(store.getState().actions.map((a) => a.type)).toEqual(['rollDice', 'build', 'shakeMothership', 'moveShip', 'endTurn']);

    // Replay from the action log reproduces every intermediate state, including the rng-driven ones.
    const replay = store.getState().replayState;
    expect(replay(5)).toEqual(g());
    expect(replay(1).turn.rolled).toBe(replay(4).turn.rolled);
    expect(replay(3).turn.shake).toEqual(replay(4).turn.shake);
    expect(replay(0).turn.rolled).toBeUndefined();
    expect(replay(4).board.ships[shipId]?.nodeId).toBe(target);
    expect(replay(2).players.find((p) => p.id === pid)!.mothership.boosters).toBe(2);
  });
});
