import { describe, expect, it } from 'vitest';
import { coloniesOf, playerToLeft } from '../src/board/query.js';
import { WIN_VP } from '../src/config.js';
import { computeVp } from '../src/vp.js';
import type { GameState, PlayerId } from '../src/types.js';
import { fails, ok, opponents, player, setHand, tradeBuildState } from './support/tradeBuild.js';

/** Give a player enough fame pieces to sit at exactly `vp` (beginner start is 4 VP). */
function setVpViaFame(state: GameState, id: PlayerId, vp: number): void {
  const base = computeVp(state, id) - Math.floor(player(state, id).famePieces / 2);
  player(state, id).famePieces = 2 * (vp - base);
  expect(computeVp(state, id)).toBe(vp);
}

describe('endTurn', () => {
  it('rotates to the player on the left, bumps turnNumber, resets turn state and clears the open trade', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    const next = playerToLeft(state, me);
    const x = opponents(state)[0]!.id;
    setHand(state, me, ['ore']);
    setHand(state, x, ['fuel']);
    state.turn.rolled = 6;
    state.turn.reserveDrawTaken = true;
    state.turn.usedOncePerTurn = ['ezzel', 'fameForSale'];
    state.turn.shipMovesUsed = { 'ship:red:1': 2 };
    state.turn.immobilized = ['ship:red:1'];
    state.turn.baseSpeed = 3;
    state.turn.speed = 4;
    const withTrade = ok(state, { type: 'proposeTrade', playerId: me, to: x, give: { ore: 1 }, want: { fuel: 1 } });
    expect(withTrade.openTrade).not.toBeNull();

    const after = ok(withTrade, { type: 'endTurn', playerId: me });
    expect(after.activePlayer).toBe(next);
    expect(after.turnNumber).toBe(state.turnNumber + 1);
    expect(after.phase).toBe('production');
    expect(after.openTrade).toBeNull();
    expect(after.turn).toEqual({ reserveDrawTaken: false, shipMovesUsed: {}, immobilized: [], usedOncePerTurn: [] });
    expect(after.winner).toBeNull();
    // Hands are untouched by an abandoned proposal.
    expect(player(after, me).hand).toEqual(['ore']);
    expect(player(after, x).hand).toEqual(['fuel']);
    expect(after.log.at(-1)).toMatchObject({ kind: 'action', playerId: me, message: 'endTurn' });
  });

  it('wraps around turnOrder after a full round', () => {
    let state = tradeBuildState();
    const order = [...state.turnOrder];
    const start = state.activePlayer;
    for (let i = 0; i < order.length; i++) {
      expect(state.activePlayer).toBe(order[(order.indexOf(start) + i) % order.length]);
      state.phase = 'tradeBuild';
      state = ok(state, { type: 'endTurn', playerId: state.activePlayer });
    }
    expect(state.activePlayer).toBe(start);
    expect(state.turnNumber).toBe(1 + order.length);
  });

  it('may only be sent by the active player, and not during production', () => {
    const state = tradeBuildState();
    fails(state, { type: 'endTurn', playerId: opponents(state)[0]!.id }, 'notYourTurn');
    state.phase = 'production';
    fails(state, { type: 'endTurn', playerId: state.activePlayer }, 'wrongPhase');
  });
});

describe('win check (15 VP on your own turn)', () => {
  it(`the active player wins the moment an action brings them to ${WIN_VP} VP`, () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    setVpViaFame(state, me, WIN_VP - 1);
    player(state, me).vp = WIN_VP - 1;
    setHand(state, me, ['carbon', 'carbon', 'carbon', 'food', 'food']);
    const colony = coloniesOf(state, me)[0]!;

    const won = ok(state, { type: 'build', playerId: me, item: 'spaceport', siteId: colony.nodeId });
    expect(player(won, me).vp).toBe(WIN_VP);
    expect(won.winner).toBe(me);
    expect(won.phase).toBe('gameOver');
    expect(won.log.some((e) => e.kind === 'event' && /wins the game/.test(e.message))).toBe(true);
    // Nothing further is accepted.
    fails(won, { type: 'endTurn', playerId: me }, 'gameOver');
  });

  it('an action that does not change VP still triggers the check (VP recomputed after every action)', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    setVpViaFame(state, me, WIN_VP);
    setHand(state, me, ['ore', 'ore', 'ore']);
    const won = ok(state, { type: 'tradeWithSupply', playerId: me, give: ['ore', 'ore', 'ore'], want: 'fuel' });
    expect(won.winner).toBe(me);
    expect(won.phase).toBe('gameOver');
  });

  it(`a non-active player reaching ${WIN_VP} VP does not win until their own turn begins`, () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    const [x, y] = opponents(state).map((p) => p.id) as [PlayerId, PlayerId];
    expect(playerToLeft(state, me)).toBe(x);
    // y (two seats away) sits on 15 VP; x does not.
    setVpViaFame(state, y, WIN_VP);
    setHand(state, me, ['fuel', 'fuel']);

    const afterBuild = ok(state, { type: 'build', playerId: me, item: 'booster' });
    expect(player(afterBuild, y).vp).toBe(WIN_VP);
    expect(afterBuild.winner).toBeNull();
    expect(afterBuild.phase).toBe('tradeBuild');

    // me → x: x is not at 15, so still no winner.
    const xTurn = ok(afterBuild, { type: 'endTurn', playerId: me });
    expect(xTurn.activePlayer).toBe(x);
    expect(xTurn.winner).toBeNull();
    expect(xTurn.phase).toBe('production');

    // x → y: y starts their turn with 15 VP and wins immediately.
    xTurn.phase = 'tradeBuild';
    const yTurn = ok(xTurn, { type: 'endTurn', playerId: x });
    expect(yTurn.activePlayer).toBe(y);
    expect(yTurn.winner).toBe(y);
    expect(yTurn.phase).toBe('gameOver');
  });

  it('a trade that lifts a non-active player to 15 VP-equivalent fame does not end the game', () => {
    // Fame cannot move in a trade, so model it as the active player's action
    // (a Helping Hand draw) happening while an opponent already holds 15 VP.
    const state = tradeBuildState();
    const me = state.activePlayer;
    const [x, y] = opponents(state).map((p) => p.id) as [PlayerId, PlayerId];
    setVpViaFame(state, x, WIN_VP);
    player(state, x).vp = WIN_VP;
    setVpViaFame(state, y, 6);
    player(state, y).vp = 6;
    player(state, me).friendshipCards = ['raHna'];
    setHand(state, x, ['ore']);
    setHand(state, y, ['fuel']);
    const next = ok(state, { type: 'useFriendshipCard', playerId: me, cardId: 'raHna', targets: [x, y] });
    expect(player(next, x).vp).toBe(WIN_VP);
    expect(next.winner).toBeNull();
    expect(next.phase).toBe('tradeBuild');
  });
});
