/**
 * Encounter mechanics (spec §10): the choice → pick → done flow, offers,
 * contests, flees, shake tables, picks by other players, redraws, Wear and
 * Tear, free trade ships, space jumps and the hand-back to the flight phase.
 * (A table-driven per-branch test lives separately.)
 *
 * Fixture: seed 'trade-build', 3 players in turn order p1 (red, active), p2
 * (blue), p3 (yellow). Seats relative to p1: L = p2, R = p3, LL = p3, RR = p2.
 * p1's colony ship ship:red:1 stands on N(5,1); N(5,3) is a legal jump target
 * next to the unexplored system N4 (see flight.test.ts).
 */

import { describe, expect, it } from 'vitest';
import { ACTION_POLICY } from '../src/actions/index.js';
import { getSector, neighborsOf, shipsOf } from '../src/board/query.js';
import { MOTHERSHIP_BALLS, UPGRADE_CAPS, type Ball } from '../src/config.js';
import { encounterCard } from '../src/encounters/cards.js';
import { beginEncounter, physicalUpgradeCount, resolveOpponent, startEncounter } from '../src/encounters/engine.js';
import { visibleEncounterText } from '../src/encounters/text.js';
import { validateEndNode } from '../src/flight/movement.js';
import { refreshSpeed, speedOf } from '../src/flight/stats.js';
import { createRng, type Rng } from '../src/rng.js';
import type { Action, GameErrorCode, GameState, PlayerId, Resource } from '../src/types.js';
import { cardsInPlay, fails, ok, player, rng, setHand, tradeBuildState } from './support/tradeBuild.js';

const SHIP = 'ship:red:1';
const P1 = 'p1';
const P2 = 'p2';
const P3 = 'p3';

/** Rng whose shuffles of the 5 mothership balls put the scripted pairs first, in order; everything else seeded. */
function scriptedRng(pairs: Ball[][], seed = 'enc'): Rng {
  const base = createRng(seed);
  const script = pairs.map((p) => [...p]);
  return {
    next: () => base.next(),
    int: (n) => base.int(n),
    pick: (a) => base.pick(a),
    d6: () => base.d6(),
    getState: () => base.getState(),
    shuffle: <T,>(arr: readonly T[]): T[] => {
      const isBalls = arr.length === MOTHERSHIP_BALLS.length && arr.every((b) => MOTHERSHIP_BALLS.includes(b as Ball));
      const first = isBalls ? script.shift() : undefined;
      if (!first) return base.shuffle(arr);
      const rest = [...arr];
      for (const b of first) rest.splice(rest.indexOf(b as T), 1);
      return [...(first as unknown as T[]), ...rest];
    },
  };
}

/** Beginner game shaken black (base speed 3) with card `cardId` just drawn for p1. */
function encounterState(cardId: number, r: Rng = rng(), seed = 'trade-build'): GameState {
  const state = tradeBuildState(seed);
  state.turn.shake = ['black', 'red'];
  state.turn.baseSpeed = 3;
  refreshSpeed(state);
  beginEncounter(state, cardId, r);
  return state;
}

const choose = (state: GameState, value: number | boolean, cards?: Resource[], r?: Rng): GameState =>
  ok(state, cards ? { type: 'encounterChoice', playerId: P1, value, cards } : { type: 'encounterChoice', playerId: P1, value }, r);

const pick = (state: GameState, playerId: PlayerId, fields: Omit<Extract<Action, { type: 'encounterPick' }>, 'type' | 'playerId'>, r?: Rng): GameState =>
  ok(state, { type: 'encounterPick', playerId, ...fields }, r);

const pickFails = (state: GameState, playerId: PlayerId, fields: Omit<Extract<Action, { type: 'encounterPick' }>, 'type' | 'playerId'>, code: GameErrorCode): void =>
  fails(state, { type: 'encounterPick', playerId, ...fields }, code);

function expectDone(state: GameState, cardId: number): void {
  expect(state.phase).toBe('flight.move');
  expect(state.turn.encounter?.stage).toBe('done');
  expect(state.turn.encounter?.awaiting).toBeUndefined();
  expect(state.turn.encounter?.queue).toEqual([]);
  expect(state.turn.baseSpeed).toBe(3);
  expect(state.turn.speed).toBe(speedOf(state, P1)); // 3 + boosters + Scientist speed
  expect(state.encounterDiscard).toContain(cardId);
}

describe('fixture sanity', () => {
  it('seats and pieces', () => {
    const state = encounterState(1);
    expect(state.turnOrder).toEqual([P1, P2, P3]);
    expect(resolveOpponent(state, P1, 'L')).toBe(P2);
    expect(resolveOpponent(state, P1, 'R')).toBe(P3);
    expect(resolveOpponent(state, P1, 'LL')).toBe(P3);
    expect(resolveOpponent(state, P1, 'RR')).toBe(P2);
    expect(shipsOf(state, P1).map((s) => s.id)).toEqual([SHIP]);
    expect(player(state, P1).mothership).toEqual({ boosters: 1, cannons: 0, freightPods: 0 });
    expect(player(state, P1).famePieces).toBe(1);
    expect(state.phase).toBe('flight.encounter');
    expect(state.turn.speed).toBe(4);
  });

  it('policy: choice is active-only, picks are not (other players answer some of them)', () => {
    expect(ACTION_POLICY.encounterChoice).toEqual({ phases: ['flight.encounter'], activePlayerOnly: true });
    expect(ACTION_POLICY.encounterPick).toEqual({ phases: ['flight.encounter'], activePlayerOnly: false });
  });
});

// ---------------------------------------------------------------------------
// Offer cards
// ---------------------------------------------------------------------------

describe('offer cards (0–3)', () => {
  it('start → choice → pick → done: card 1, offer 2 → 1 resource of your choice + 1 fame', () => {
    const state = encounterState(1);
    setHand(state, P1, ['ore', 'fuel', 'goods']);
    const total = cardsInPlay(state);
    expect(state.turn.encounter).toMatchObject({ cardId: 1, stage: 'choice', queue: [] });
    expect(visibleEncounterText(state)).toEqual([encounterCard(1).prompt]);

    const chosen = choose(state, 2, ['ore', 'fuel']);
    const ctx = chosen.turn.encounter!;
    expect(ctx.stage).toBe('resolving');
    expect(ctx.choice).toBe('2');
    expect(ctx.offerPaid).toEqual(['ore', 'fuel']);
    expect(player(chosen, P1).hand).toEqual(['goods']);
    expect(chosen.supply.ore).toBe(state.supply.ore + 1);
    expect(chosen.supply.fuel).toBe(state.supply.fuel + 1);
    expect(ctx.awaiting).toMatchObject({ kind: 'resources', playerId: P1, count: 1 });
    expect(visibleEncounterText(chosen)).toEqual([encounterCard(1).prompt, encounterCard(1).branches['2']!.text]);
    expect(chosen.phase).toBe('flight.encounter');

    const done = pick(chosen, P1, { resources: ['carbon'] });
    expect(player(done, P1).hand).toEqual(['goods', 'carbon']);
    expect(player(done, P1).famePieces).toBe(2);
    expect(done.upgradesTray.famePieces).toBe(state.upgradesTray.famePieces - 1);
    expectDone(done, 1);
    expect(done.encounterDiscard).toEqual([1]);
    expect(cardsInPlay(done)).toBe(total);
    // Nothing more to answer.
    fails(done, { type: 'encounterChoice', playerId: P1, value: 1 }, 'wrongPhase');
  });

  it('the offer must be held and is paid before the result; with no cards only 0 is possible', () => {
    const state = encounterState(3);
    setHand(state, P1, ['ore']);
    fails(state, { type: 'encounterChoice', playerId: P1, value: 2, cards: ['ore', 'fuel'] }, 'insufficientResources');
    fails(state, { type: 'encounterChoice', playerId: P1, value: 1, cards: ['fuel'] }, 'insufficientResources');
    fails(state, { type: 'encounterChoice', playerId: P1, value: 1, cards: [] }, 'invalidAction');
    fails(state, { type: 'encounterChoice', playerId: P1, value: 1 }, 'invalidAction');
    fails(state, { type: 'encounterChoice', playerId: P1, value: 0, cards: ['ore'] }, 'invalidAction');
    fails(state, { type: 'encounterChoice', playerId: P1, value: 4, cards: ['ore'] }, 'invalidAction');
    fails(state, { type: 'encounterChoice', playerId: P1, value: true }, 'invalidAction');
    fails(state, { type: 'encounterChoice', playerId: P2, value: 0 }, 'notYourTurn');

    const empty = encounterState(3);
    setHand(empty, P1, []);
    fails(empty, { type: 'encounterChoice', playerId: P1, value: 1, cards: ['ore'] }, 'insufficientResources');
    const done = choose(empty, 0, []);
    expect(done.turn.encounter?.choice).toBe('0');
    expect(player(done, P1).famePieces).toBe(0); // card 3, offer 0: lose 1 fame
    expectDone(done, 3);
  });

  it('fame never drops below 0 (card 1 offer 0 loses 2 with only 1 held) and returns to the tray', () => {
    const state = encounterState(1);
    setHand(state, P1, []);
    setHand(state, P2, []);
    setHand(state, P3, []);
    const tray = state.upgradesTray.famePieces;
    const done = choose(state, 0, []);
    expect(player(done, P1).famePieces).toBe(0);
    expect(done.upgradesTray.famePieces).toBe(tray + 1);
    expectDone(done, 1);
  });

  it('card 4 offer 0 returns the (empty) gift; a resource branch with a specific type needs no pick', () => {
    const state = encounterState(4);
    setHand(state, P1, ['goods']);
    const done = choose(state, 1, ['goods']);
    expect(player(done, P1).hand).toEqual(['goods']); // paid 1 goods, received 1 goods
    expectDone(done, 4);
  });

  it('"any" picks are rejected when the supply lacks that type, and the count is capped by the supply', () => {
    const state = encounterState(1);
    setHand(state, P1, ['ore', 'ore', 'ore']);
    state.supply.carbon = 0;
    const chosen = choose(state, 3, ['ore', 'ore', 'ore']);
    expect(chosen.turn.encounter?.awaiting).toMatchObject({ kind: 'resources', count: 2 });
    pickFails(chosen, P1, { resources: ['carbon', 'fuel'] }, 'supplyEmpty');
    pickFails(chosen, P1, { resources: ['fuel'] }, 'invalidAction');
    pickFails(chosen, P1, { resources: ['fuel', 'fuel', 'fuel'] }, 'invalidAction');
    pickFails(chosen, P1, { upgrade: 'booster' }, 'invalidAction');
    const done = pick(chosen, P1, { resources: ['fuel', 'food'] });
    expect(player(done, P1).hand).toEqual(['fuel', 'food']);
    expectDone(done, 1);

    // Supply almost empty: only what is there can be taken; completely empty → no pick at all.
    const short = encounterState(1);
    setHand(short, P1, ['ore', 'ore', 'ore']);
    for (const r of ['ore', 'fuel', 'carbon', 'food', 'goods'] as const) short.supply[r] = 0;
    short.supply.goods = 1;
    // The 3 ore paid go back to the supply, so 4 cards are available; count stays 2.
    const chosen2 = choose(short, 3, ['ore', 'ore', 'ore']);
    expect(chosen2.turn.encounter?.awaiting).toMatchObject({ kind: 'resources', count: 2 });
  });
});

// ---------------------------------------------------------------------------
// Yes/no cards, contests, flees
// ---------------------------------------------------------------------------

describe('yes/no cards', () => {
  it('card 9 "surrender": pay 2 cards of your choice (pick), then done', () => {
    const state = encounterState(9);
    setHand(state, P1, ['ore', 'fuel', 'goods']);
    fails(state, { type: 'encounterChoice', playerId: P1, value: 1 }, 'invalidAction');
    const chosen = choose(state, true);
    expect(chosen.turn.encounter?.awaiting).toMatchObject({ kind: 'payResources', playerId: P1, count: 2 });
    pickFails(chosen, P1, { resources: ['ore', 'carbon'] }, 'insufficientResources');
    pickFails(chosen, P1, { resources: ['ore'] }, 'invalidAction');
    const done = pick(chosen, P1, { resources: ['ore', 'goods'] });
    expect(player(done, P1).hand).toEqual(['fuel']);
    expect(done.supply.ore).toBe(state.supply.ore + 1);
    expectDone(done, 9);
  });

  it('paying with fewer cards than demanded pays what you have; with none, nothing', () => {
    const one = encounterState(10);
    setHand(one, P1, ['ore']);
    const chosen = choose(one, true);
    expect(chosen.turn.encounter?.awaiting).toMatchObject({ kind: 'payResources', count: 1 });
    const done = pick(chosen, P1, { resources: ['ore'] });
    expect(player(done, P1).hand).toEqual([]);
    expect(player(done, P1).famePieces).toBe(0);
    expectDone(done, 10);

    const none = encounterState(10);
    setHand(none, P1, []);
    const d2 = choose(none, true);
    expectDone(d2, 10);
  });
});

describe('contests (combat / speed race)', () => {
  it('combat vs L (card 11, "no"): ball total + cannons + Scientist bonus, ties go to the active player, opponent unaffected', () => {
    const state = encounterState(11);
    player(state, P2).mothership.cannons = 1;
    const p2Before = structuredClone(player(state, P2));
    // p1: Y+R = 5 + 0 cannons = 5; p2: Y+Y = 4 + 1 cannon = 5 → p1 wins the tie.
    const won = choose(state, false, undefined, scriptedRng([['yellow', 'red'], ['yellow', 'yellow']]));
    const ctx = won.turn.encounter!;
    expect(ctx.contestResults).toEqual([
      {
        kind: 'combat',
        yours: { playerId: P1, balls: ['yellow', 'red'], total: 5, bonus: 0, strength: 5 },
        theirs: { playerId: P2, balls: ['yellow', 'yellow'], total: 4, bonus: 1, strength: 5 },
        won: true,
      },
    ]);
    expect(player(won, P1).hand).toEqual(['ore', 'ore'].concat(player(state, P1).hand).sort()) ;
    expect(player(won, P1).famePieces).toBe(2);
    expect(player(won, P2)).toEqual({ ...p2Before, vp: player(won, P2).vp });
    expect(visibleEncounterText(won)).toHaveLength(3);
    expect(visibleEncounterText(won)[2]).toMatch(/Combat/);
    expectDone(won, 11);

    // Lose: p1 B+K = 1 + Kha-Star 2 = 3 < p2 Y+Y 4 + 1 = 5 → remove 1 upgrade (pick). Black = 0, no new encounter.
    const lose = encounterState(11);
    player(lose, P2).mothership.cannons = 1;
    player(lose, P1).friendshipCards = ['khaStar'];
    const lost = choose(lose, false, undefined, scriptedRng([['blue', 'black'], ['yellow', 'yellow']]));
    expect(lost.turn.encounter?.contestResults?.[0]).toMatchObject({
      won: false,
      yours: { balls: ['blue', 'black'], total: 1, bonus: 2, strength: 3 },
      theirs: { strength: 5 },
    });
    expect(lost.turn.encounter?.cardId).toBe(11);
    expect(lost.turn.encounter?.awaiting).toMatchObject({ kind: 'removeUpgrade', playerId: P1, options: ['booster'] });
    pickFails(lost, P1, { upgrade: 'cannon' }, 'invalidTarget');
    pickFails(lost, P1, { shipId: SHIP }, 'invalidTarget');
    const done = pick(lost, P1, { upgrade: 'booster' });
    expect(player(done, P1).mothership.boosters).toBe(0);
    expect(done.upgradesTray.boosters).toBe(lose.upgradesTray.boosters + 1);
    expect(player(done, P1).friendshipCards).toEqual(['khaStar']); // Scientist cards are never removed
    expectDone(done, 11);
    expect(done.turn.speed).toBe(3);
  });

  it('speed race vs RR (card 19, "yes"): ball total + boosters + Scientist speed bonus', () => {
    const state = encounterState(19);
    player(state, P1).friendshipCards = ['hirAkas']; // +2 speed → race boosters 1 + 2 = 3
    player(state, P2).mothership.boosters = 4;
    // p1: Y+B = 3 + 3 = 6; p2 (RR): B+K = 1 + 4 = 5 → win → free trade ship.
    const won = choose(state, true, undefined, scriptedRng([['yellow', 'blue'], ['blue', 'black']]));
    expect(won.turn.encounter?.contestResults?.[0]).toMatchObject({
      kind: 'speed',
      yours: { playerId: P1, total: 3, bonus: 3, strength: 6 },
      theirs: { playerId: P2, total: 1, bonus: 4, strength: 5 },
      won: true,
    });
    expect(shipsOf(won, P1).filter((s) => s.kind === 'trade')).toHaveLength(1);
    expectDone(won, 19);

    const lost = choose(state, true, undefined, scriptedRng([['blue', 'black'], ['yellow', 'red']]));
    expect(lost.turn.encounter?.contestResults?.[0]).toMatchObject({ won: false, yours: { strength: 4 }, theirs: { strength: 9 } });
    expect(lost.turn.encounter?.awaiting).toMatchObject({ kind: 'removeUpgrade', playerId: P1 });
  });

  it('flee (card 16): boosters ≥ R\'s → escaped with no shake; otherwise caught and the fight follows', () => {
    const state = encounterState(16);
    player(state, P3).mothership.boosters = 1; // equal → escape
    const escaped = choose(state, true, undefined, scriptedRng([]));
    expect(escaped.turn.encounter?.fleeResults).toEqual([{ opponent: P3, yours: 1, theirs: 1, escaped: true }]);
    expect(escaped.turn.encounter?.contestResults).toBeUndefined();
    expectDone(escaped, 16);

    const caught = encounterState(16);
    player(caught, P3).mothership.boosters = 2;
    player(caught, P3).mothership.cannons = 1;
    // Fight R (p3): p1 R+Y = 5 + 0 ≥ p3 Y+Y = 4 + 1 → win → upgrade of choice + 1 fame.
    const fought = choose(caught, true, undefined, scriptedRng([['red', 'yellow'], ['yellow', 'yellow']]));
    expect(fought.turn.encounter?.fleeResults?.[0]).toMatchObject({ escaped: false, yours: 1, theirs: 2 });
    expect(fought.turn.encounter?.contestResults?.[0]).toMatchObject({ won: true });
    expect(fought.turn.encounter?.awaiting).toMatchObject({ kind: 'upgradeKind', playerId: P1, options: ['booster', 'cannon', 'freightPod'] });
    const done = pick(fought, P1, { upgrade: 'cannon' });
    expect(player(done, P1).mothership.cannons).toBe(1);
    expect(player(done, P1).famePieces).toBe(2);
    expectDone(done, 16);

    // Card 17: escaping costs 1 fame; "no" fights straight away.
    const c17 = encounterState(17);
    const ran = choose(c17, true, undefined, scriptedRng([]));
    expect(player(ran, P1).famePieces).toBe(0);
    expectDone(ran, 17);
    const stood = choose(c17, false, undefined, scriptedRng([['yellow', 'yellow'], ['blue', 'black']]));
    expect(stood.turn.encounter?.fleeResults).toBeUndefined();
    expect(stood.turn.encounter?.contestResults?.[0]).toMatchObject({ theirs: { playerId: P3 }, won: true });
  });

  it('gainUpgrade: blocked by the cap or an empty tray (no pick, logged); "any" offers only placeable kinds', () => {
    const state = encounterState(2);
    setHand(state, P1, ['ore', 'ore', 'ore']);
    state.upgradesTray.boosters = 0;
    player(state, P1).mothership.cannons = UPGRADE_CAPS.cannon;
    const chosen = choose(state, 3, ['ore', 'ore', 'ore']);
    expect(chosen.turn.encounter?.awaiting).toMatchObject({ kind: 'upgradeKind', options: ['freightPod'] });
    pickFails(chosen, P1, { upgrade: 'booster' }, 'invalidTarget');
    const done = pick(chosen, P1, { upgrade: 'freightPod' });
    expect(player(done, P1).mothership.freightPods).toBe(1);
    expectDone(done, 2);

    const blocked = encounterState(2);
    setHand(blocked, P1, ['ore', 'ore', 'ore']);
    blocked.upgradesTray = { ...blocked.upgradesTray, boosters: 0, cannons: 0, freightPods: 0 };
    const d2 = choose(blocked, 3, ['ore', 'ore', 'ore']);
    expect(d2.log.some((e) => /none can be placed/.test(e.message))).toBe(true);
    expect(player(d2, P1).famePieces).toBe(2);
    expectDone(d2, 2);
  });
});

// ---------------------------------------------------------------------------
// Shake tables (cards 12–15)
// ---------------------------------------------------------------------------

describe('shake tables (cards 12–15, bands from config)', () => {
  function smuggle(balls: Ball[]): GameState {
    const state = encounterState(12);
    setHand(state, P1, ['ore']);
    const r = scriptedRng([balls]);
    const chosen = choose(state, true, undefined, r);
    expect(chosen.turn.encounter?.awaiting).toMatchObject({ kind: 'payResources', playerId: P1, count: 1 });
    const paid = pick(chosen, P1, { resources: ['ore'] }, r);
    expect(paid.turn.encounter?.awaiting).toMatchObject({ kind: 'resources', playerId: P1, count: 2 });
    expect(player(paid, P1).hand).toEqual([]);
    return pick(paid, P1, { resources: ['fuel', 'carbon'] }, r);
  }

  it('low total: the 2 received cards are confiscated and 1 fame is lost', () => {
    const done = smuggle(['blue', 'black']);
    expect(done.turn.encounter?.tableShakes).toEqual([{ balls: ['blue', 'black'], total: 1, band: 'low' }]);
    expect(done.turn.encounter?.tradeReceived).toEqual(['fuel', 'carbon']);
    expect(player(done, P1).hand).toEqual([]);
    expect(player(done, P1).famePieces).toBe(0);
    expectDone(done, 12);
  });

  it('mid total: keep the cards, lose 1 fame', () => {
    const done = smuggle(['yellow', 'blue']);
    expect(done.turn.encounter?.tableShakes?.[0]).toMatchObject({ total: 3, band: 'mid' });
    expect(player(done, P1).hand).toEqual(['fuel', 'carbon']);
    expect(player(done, P1).famePieces).toBe(0);
    expectDone(done, 12);
  });

  it('high total: keep everything', () => {
    const done = smuggle(['red', 'yellow']);
    expect(done.turn.encounter?.tableShakes?.[0]).toMatchObject({ total: 5, band: 'high' });
    expect(player(done, P1).hand).toEqual(['fuel', 'carbon']);
    expect(player(done, P1).famePieces).toBe(1);
    expectDone(done, 12);
  });

  it('the trade needs a card in hand; "no" on card 12 gives 1 fame', () => {
    const state = encounterState(12);
    setHand(state, P1, []);
    fails(state, { type: 'encounterChoice', playerId: P1, value: true }, 'insufficientResources');
    const done = choose(state, false);
    expect(player(done, P1).famePieces).toBe(2);
    expectDone(done, 12);
  });

  it('card 14 "yes": pay 1, then high → 1 random card from every opponent (rng.int), mid also costs 1 fame, low cheats you', () => {
    const state = encounterState(14);
    setHand(state, P1, ['goods']);
    setHand(state, P2, ['ore', 'fuel']);
    setHand(state, P3, []);
    const r = scriptedRng([['yellow', 'red']]);
    const chosen = choose(state, true, undefined, r);
    const done = pick(chosen, P1, { resources: ['goods'] }, r);
    expect(done.turn.encounter?.tableShakes?.[0]).toMatchObject({ band: 'high' });
    expect(player(done, P1).hand).toHaveLength(1);
    expect(player(done, P2).hand).toHaveLength(1);
    expect([...player(done, P1).hand, ...player(done, P2).hand].sort()).toEqual(['fuel', 'ore']);
    expect(player(done, P1).famePieces).toBe(1);
    expectDone(done, 14);

    const mid = scriptedRng([['yellow', 'blue']]);
    const m = pick(choose(state, true, undefined, mid), P1, { resources: ['goods'] }, mid);
    expect(player(m, P1).hand).toHaveLength(1);
    expect(player(m, P1).famePieces).toBe(0);

    const low = scriptedRng([['blue', 'black']]);
    const l = pick(choose(state, true, undefined, low), P1, { resources: ['goods'] }, low);
    expect(player(l, P1).hand).toHaveLength(0);
    expect(player(l, P2).hand).toHaveLength(2);
    expect(player(l, P1).famePieces).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// Picks by other players, no-ops, wrong senders
// ---------------------------------------------------------------------------

describe('picks', () => {
  it('card 1 offer 0: every opponent with a card gives 1 of THEIR choice, in turn order from the left', () => {
    const state = encounterState(1);
    setHand(state, P1, []);
    setHand(state, P2, ['ore', 'fuel']);
    setHand(state, P3, ['goods']);
    const chosen = choose(state, 0, []);
    expect(chosen.turn.encounter?.awaiting).toMatchObject({ kind: 'giveOne', playerId: P2, count: 1 });
    pickFails(chosen, P1, { resources: ['ore'] }, 'notYourTurn');
    pickFails(chosen, P3, { resources: ['goods'] }, 'notYourTurn');
    pickFails(chosen, P2, { resources: ['goods'] }, 'insufficientResources');
    pickFails(chosen, P2, { resources: ['ore', 'fuel'] }, 'invalidAction');
    const second = pick(chosen, P2, { resources: ['fuel'] });
    expect(player(second, P2).hand).toEqual(['ore']);
    expect(player(second, P1).hand).toEqual(['fuel']);
    expect(second.turn.encounter?.awaiting).toMatchObject({ kind: 'giveOne', playerId: P3 });
    const done = pick(second, P3, { resources: ['goods'] });
    expect(player(done, P1).hand).toEqual(['fuel', 'goods']);
    expect(player(done, P1).famePieces).toBe(0); // lose 2, had 1
    expectDone(done, 1);

    // Opponents without cards are skipped entirely.
    const nobody = encounterState(1);
    setHand(nobody, P1, []);
    setHand(nobody, P2, []);
    setHand(nobody, P3, ['ore']);
    const only3 = choose(nobody, 0, []);
    expect(only3.turn.encounter?.awaiting).toMatchObject({ kind: 'giveOne', playerId: P3 });
    expectDone(pick(only3, P3, { resources: ['ore'] }), 1);
  });

  it('picks are rejected when none is pending', () => {
    const state = encounterState(9);
    pickFails(state, P1, { resources: ['ore'] }, 'ruleViolation');
  });

  it('removeUpgrade with no upgrades and immobilizeShip with no ships are no-ops (card 27 lose, card 22 lose)', () => {
    const noUpgrades = encounterState(27);
    player(noUpgrades, P1).mothership.boosters = 0;
    refreshSpeed(noUpgrades);
    player(noUpgrades, P2).mothership.boosters = 6;
    const lost = choose(noUpgrades, true, undefined, scriptedRng([['blue', 'black'], ['yellow', 'red']]));
    expect(lost.turn.encounter?.contestResults?.[0]).toMatchObject({ won: false, theirs: { playerId: P2 } });
    expect(lost.log.some((e) => /no upgrade to remove/.test(e.message))).toBe(true);
    expectDone(lost, 27);

    const noShips = encounterState(22);
    for (const s of shipsOf(noShips, P1)) delete noShips.board.ships[s.id];
    player(noShips, P2).mothership.cannons = 6;
    const l2 = choose(noShips, true, undefined, scriptedRng([['blue', 'black'], ['yellow', 'red']]));
    expect(l2.log.some((e) => /no ship that could be immobilized/.test(e.message))).toBe(true);
    expectDone(l2, 22);
  });

  it('immobilizeShip: the active player picks which ship; it is added to turn.immobilized', () => {
    const state = encounterState(5);
    setHand(state, P1, []);
    state.board.ships['ship:red:2'] = { id: 'ship:red:2', owner: P1, kind: 'trade', nodeId: 'N(4,2)', mustFoundOrLeave: false };
    const chosen = choose(state, 0, []);
    expect(chosen.turn.encounter?.awaiting).toMatchObject({ kind: 'immobilizeShip', playerId: P1, options: [SHIP, 'ship:red:2'] });
    pickFails(chosen, P1, { shipId: 'ship:blue:1' }, 'invalidTarget');
    pickFails(chosen, P1, { upgrade: 'booster' }, 'invalidTarget');
    const done = pick(chosen, P1, { shipId: 'ship:red:2' });
    expect(done.turn.immobilized).toEqual(['ship:red:2']);
    expect(done.turn.encounter?.immobilizedShip).toBe('ship:red:2');
    expect(player(done, P1).famePieces).toBe(0);
    expectDone(done, 5);
    fails(done, { type: 'moveShip', playerId: P1, shipId: 'ship:red:2', path: ['S(3,1)'] }, 'ruleViolation');
    ok(done, { type: 'moveShip', playerId: P1, shipId: SHIP, path: ['S(4,2)'] });
  });
});

// ---------------------------------------------------------------------------
// Redraw, Wear and Tear
// ---------------------------------------------------------------------------

describe('redraw (wormhole "no") and Wear and Tear (31 / 32)', () => {
  it('card 25 "no": discard it and start over with the next card of the deck', () => {
    const state = encounterState(25);
    state.encounterDeck = [9, 10];
    const next = choose(state, false);
    expect(next.encounterDiscard).toEqual([25]);
    expect(next.encounterDeck).toEqual([10]);
    expect(next.turn.encounter).toMatchObject({ cardId: 9, stage: 'choice', queue: [] });
    expect(next.turn.encounter?.awaiting).toBeUndefined();
    expect(visibleEncounterText(next)).toEqual([encounterCard(9).prompt]);
    expect(next.phase).toBe('flight.encounter');
    const done = choose(next, true);
    expect(done.turn.encounter?.awaiting).toMatchObject({ kind: 'payResources' });
  });

  it('redraw with an empty deck reshuffles the discard pile (which may hand the same card back)', () => {
    const state = encounterState(26);
    state.encounterDeck = [];
    state.encounterDiscard = [];
    const next = choose(state, false);
    expect(next.turn.encounter).toMatchObject({ cardId: 26, stage: 'choice' });
    expect(next.encounterDeck).toEqual([]);
    expect(next.encounterDiscard).toEqual([]);
    expect(next.log.some((e) => /reshuffled into a new deck/.test(e.message))).toBe(true);
  });

  it('card 31: players with > 8 upgrades remove 1 each (active player first), then the whole deck is reshuffled and a new card drawn', () => {
    const state = tradeBuildState();
    state.turn.shake = ['black', 'blue'];
    state.turn.baseSpeed = 3;
    refreshSpeed(state);
    player(state, P1).mothership = { boosters: 4, cannons: 3, freightPods: 2 }; // 9
    player(state, P2).mothership = { boosters: 3, cannons: 3, freightPods: 2 }; // 8 → safe
    player(state, P3).mothership = { boosters: 6, cannons: 3, freightPods: 0 }; // 9
    player(state, P3).friendshipCards = ['khaStar', 'hirAkas']; // not upgrades
    state.encounterDeck = [1, 2, 3];
    state.encounterDiscard = [4, 5];
    expect(physicalUpgradeCount(player(state, P1))).toBe(9);

    beginEncounter(state, 31, rng());
    const ctx = state.turn.encounter!;
    expect(ctx).toMatchObject({ cardId: 31, stage: 'resolving', choice: 'auto' });
    expect(ctx.awaiting).toMatchObject({ kind: 'removeUpgrade', playerId: P1, options: ['booster', 'cannon', 'freightPod'] });
    expect(visibleEncounterText(state)[2]).toMatch(/Ann, Cid must each remove 1 upgrade/);
    pickFails(state, P2, { upgrade: 'booster' }, 'notYourTurn');

    const second = pick(state, P1, { upgrade: 'freightPod' });
    expect(player(second, P1).mothership.freightPods).toBe(1);
    expect(second.turn.encounter?.awaiting).toMatchObject({ kind: 'removeUpgrade', playerId: P3, options: ['booster', 'cannon'] });
    const after = pick(second, P3, { upgrade: 'cannon' });
    expect(player(after, P3).mothership.cannons).toBe(2);
    expect(player(after, P2).mothership).toEqual({ boosters: 3, cannons: 3, freightPods: 2 });

    // Deck 3 + discard 2 + card 31 = 6 cards reshuffled, one drawn for p1.
    expect(after.encounterDiscard).toEqual([]);
    expect(after.encounterDeck).toHaveLength(5);
    expect([1, 2, 3, 4, 5, 31]).toContain(after.turn.encounter?.cardId);
    expect(after.turn.encounter?.cardId === 31 || after.turn.encounter?.stage === 'choice').toBe(true);
    expect([...after.encounterDeck, after.turn.encounter!.cardId].sort((a, b) => a - b)).toEqual([1, 2, 3, 4, 5, 31]);
    expect(after.phase).toBe('flight.encounter');
    expect(after.log.some((e) => /whole encounter deck is reshuffled/.test(e.message))).toBe(true);
  });

  it('card 31 with nobody over the threshold goes straight to the new card', () => {
    const state = encounterState(31);
    expect(state.turn.encounter?.stage === 'choice' || state.turn.encounter?.cardId === 31).toBe(true);
    // The fixture deck still held all 32 cards, so 32 + this card 31 were reshuffled and one was drawn.
    expect(state.encounterDeck.length + 1).toBe(33);
    expect(state.encounterDiscard).toEqual([]);
    expect(state.log.some((e) => /nobody has more than 8 upgrades/.test(e.message))).toBe(true);
  });

  it('card 32: > 6 upgrades remove 1; the galactic council gives +1 fame to everyone tied for most freight pods (≥ 1)', () => {
    const state = tradeBuildState();
    state.turn.shake = ['black', 'blue'];
    state.turn.baseSpeed = 3;
    refreshSpeed(state);
    player(state, P1).mothership = { boosters: 2, cannons: 2, freightPods: 3 }; // 7 → remove 1
    player(state, P2).mothership = { boosters: 1, cannons: 2, freightPods: 3 }; // 6 → safe
    player(state, P3).mothership = { boosters: 1, cannons: 0, freightPods: 1 };
    beginEncounter(state, 32, rng());
    expect(state.turn.encounter?.awaiting).toMatchObject({ kind: 'removeUpgrade', playerId: P1 });
    const after = pick(state, P1, { upgrade: 'freightPod' }); // now 2 pods: p2 alone has most (3)
    expect(player(after, P1).famePieces).toBe(1);
    expect(player(after, P2).famePieces).toBe(2);
    expect(player(after, P3).famePieces).toBe(1);
    expect(after.turn.encounter?.stage === 'choice' || after.turn.encounter?.cardId === 32).toBe(true);

    const tied = tradeBuildState();
    tied.turn.shake = ['black', 'blue'];
    tied.turn.baseSpeed = 3;
    refreshSpeed(tied);
    player(tied, P1).mothership.freightPods = 2;
    player(tied, P3).mothership.freightPods = 2;
    beginEncounter(tied, 32, rng());
    expect(player(tied, P1).famePieces).toBe(2);
    expect(player(tied, P2).famePieces).toBe(1);
    expect(player(tied, P3).famePieces).toBe(2);

    const nobody = encounterState(32); // everyone has 0 pods
    expect(nobody.players.map((p) => p.famePieces)).toEqual([1, 1, 1]);
    expect(nobody.log.some((e) => /nobody owns a freight pod/.test(e.message))).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Free trade ship, space jump, hand-back to flight
// ---------------------------------------------------------------------------

describe('free trade ship and space jump', () => {
  it('card 5 offer 3: a free trade ship is placed at once, or held as a marker when no transport is free', () => {
    const state = encounterState(5);
    setHand(state, P1, ['ore', 'fuel', 'carbon']);
    const placed = choose(state, 3, ['ore', 'fuel', 'carbon']);
    const trade = shipsOf(placed, P1).filter((s) => s.kind === 'trade');
    expect(trade).toHaveLength(1);
    expect(player(placed, P1).pieces.transportsLeft).toBe(player(state, P1).pieces.transportsLeft - 1);
    expectDone(placed, 5);
    // The new ship may move this turn.
    const ship = trade[0]!;
    const step = neighborsOf(placed.board, ship.nodeId).find((n) => validateEndNode(placed, ship, n) === null)!;
    ok(placed, { type: 'moveShip', playerId: P1, shipId: ship.id, path: [step] });

    const stuck = encounterState(5);
    setHand(stuck, P1, ['ore', 'fuel', 'carbon']);
    player(stuck, P1).pieces.transportsLeft = 0;
    const pending = choose(stuck, 3, ['ore', 'fuel', 'carbon']);
    expect(shipsOf(pending, P1)).toHaveLength(1);
    expect(pending.pendingTradeShips[P1]).toBe(1);
    expectDone(pending, 5);
  });

  it('card 28 offer 3: pick a ship and a target validated like a jump; the jump explores and ends that ship\'s move', () => {
    const state = encounterState(28);
    setHand(state, P1, ['ore', 'fuel', 'carbon']);
    const chosen = choose(state, 3, ['ore', 'fuel', 'carbon']);
    expect(chosen.turn.encounter?.awaiting).toMatchObject({ kind: 'spaceJump', playerId: P1, options: [SHIP] });
    pickFails(chosen, P1, { shipId: 'ship:blue:1', targetNodeId: 'N(5,3)' }, 'invalidTarget');
    pickFails(chosen, P1, { shipId: SHIP }, 'invalidAction');
    pickFails(chosen, P1, { shipId: SHIP, targetNodeId: 'N(5,1)' }, 'invalidTarget'); // already there
    pickFails(chosen, P1, { shipId: SHIP, targetNodeId: 'S(3,1)' }, 'invalidTarget'); // own spaceport
    pickFails(chosen, P1, { shipId: SHIP, targetNodeId: 'N(2,9)' }, 'ruleViolation'); // colony ship on a docking point
    const done = pick(chosen, P1, { shipId: SHIP, targetNodeId: 'N(5,3)' });
    expect(done.board.ships[SHIP]!.nodeId).toBe('N(5,3)');
    expect(getSector(done.board, 'N4').explored).toBe(true);
    expect(done.turn.encounter?.jumpedTo).toEqual({ shipId: SHIP, nodeId: 'N(5,3)' });
    expectDone(done, 28);
    expect(done.turn.shipMovesUsed[SHIP]).toBe(done.turn.speed);
    fails(done, { type: 'moveShip', playerId: P1, shipId: SHIP, path: ['S(4,3)'] }, 'ruleViolation');

    const declined = pick(chosen, P1, { decline: true });
    expect(declined.board.ships[SHIP]!.nodeId).toBe('N(5,1)');
    expectDone(declined, 28);
    ok(declined, { type: 'moveShip', playerId: P1, shipId: SHIP, path: ['S(4,2)'] });
  });
});

describe('hand-back to the flight phase', () => {
  it('after resolution: phase flight.move, base speed 3, speed re-derived from new boosters, ships move normally', () => {
    const state = encounterState(2);
    setHand(state, P1, ['ore', 'ore', 'ore']);
    const chosen = choose(state, 3, ['ore', 'ore', 'ore']);
    const done = pick(chosen, P1, { upgrade: 'booster' });
    expect(player(done, P1).mothership.boosters).toBe(2);
    expect(done.turn.baseSpeed).toBe(3);
    expect(done.turn.speed).toBe(5);
    expectDone(done, 2);
    const moved = ok(done, { type: 'moveShip', playerId: P1, shipId: SHIP, path: ['S(4,2)', 'N(5,2)', 'S(4,3)', 'N(5,3)', 'S(4,4)'] });
    expect(moved.board.ships[SHIP]!.nodeId).toBe('S(4,4)');
    const ended = ok(moved, { type: 'endTurn', playerId: P1 });
    expect(ended.turn.encounter).toBeUndefined();
  });

  it('the black-ball flow end to end: shake → card → choice → flight.move; a black ball inside the encounter is just 0', () => {
    const state = tradeBuildState();
    state.encounterDeck = [23, 7];
    const r = scriptedRng([['black', 'yellow'], ['blue', 'black'], ['yellow', 'black']]);
    const enc = ok(state, { type: 'shakeMothership', playerId: P1 }, r);
    expect(enc.phase).toBe('flight.encounter');
    expect(enc.turn.encounter).toMatchObject({ cardId: 23, stage: 'choice' });
    expect(enc.turn.baseSpeed).toBe(3);
    // Fight R (p3): p1 B+K = 1 vs p3 Y+K = 2 → lose → remove 1 upgrade, +1 fame. No second encounter: deck still holds 7.
    const lost = ok(enc, { type: 'encounterChoice', playerId: P1, value: true }, r);
    expect(lost.turn.encounter?.contestResults?.[0]).toMatchObject({ won: false, yours: { total: 1 }, theirs: { total: 2 } });
    expect(lost.encounterDeck).toEqual([7]);
    const done = ok(lost, { type: 'encounterPick', playerId: P1, upgrade: 'booster' }, r);
    expect(player(done, P1).famePieces).toBe(2);
    expect(done.phase).toBe('flight.move');
    expect(done.turn.speed).toBe(3);
    expect(done.encounterDiscard).toEqual([23]);
  });

  it('startEncounter returns false and changes nothing when no card is left', () => {
    const state = tradeBuildState();
    state.encounterDeck = [];
    state.encounterDiscard = [];
    const before = structuredClone(state);
    expect(startEncounter(state, rng())).toBe(false);
    expect(state).toEqual(before);
  });

  it('cards 7/8: the offer is paid first, then the yes/no; winning the fight returns the gift', () => {
    const state = encounterState(7);
    setHand(state, P1, ['ore', 'fuel']);
    fails(state, { type: 'encounterChoice', playerId: P1, value: true }, 'invalidAction'); // offer first
    const offered = choose(state, 2, ['ore', 'fuel']);
    expect(offered.turn.encounter).toMatchObject({ stage: 'choice', offerPaid: ['ore', 'fuel'] });
    expect(player(offered, P1).hand).toEqual([]);
    fails(offered, { type: 'encounterChoice', playerId: P1, value: 1, cards: ['ore'] }, 'invalidAction'); // now yes/no
    const declined = choose(offered, false);
    expect(player(declined, P1).hand).toEqual([]);
    expectDone(declined, 7);

    // Attack R (p3): p1 Y+R 5 vs p3 B+Y 3 → win → gift back + 1 fame.
    const won = choose(offered, true, undefined, scriptedRng([['yellow', 'red'], ['blue', 'yellow']]));
    expect(player(won, P1).hand.sort()).toEqual(['fuel', 'ore']);
    expect(player(won, P1).famePieces).toBe(2);
    expectDone(won, 7);
    // Lose → gift stays lost and one ship cannot move.
    const lost = choose(offered, true, undefined, scriptedRng([['blue', 'black'], ['yellow', 'red']]));
    expect(player(lost, P1).hand).toEqual([]);
    expect(lost.turn.encounter?.awaiting).toMatchObject({ kind: 'immobilizeShip', playerId: P1 });
  });
});
