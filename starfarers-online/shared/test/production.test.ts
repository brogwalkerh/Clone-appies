import { describe, expect, it } from 'vitest';
import { applyAction } from '../src/actions/index.js';
import { reliefEligible, sevenWaitingOn } from '../src/actions/production.js';
import { planetAtHex } from '../src/board/query.js';
import { createRng, type Rng } from '../src/rng.js';
import { createBeginnerGame } from '../src/setup/beginner.js';
import { handToBag } from '../src/supply.js';
import type { Action, GameState, PlayerId, Resource } from '../src/types.js';
import { RESOURCES } from '../src/types.js';
import { recomputeAllVp } from '../src/vp.js';
import { computeProduction } from '../src/production/produce.js';
import { discardCountFor, discardThresholdFor } from '../src/production/seven.js';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const four = [
  { id: 'p1', name: 'Ann', color: 'red' as const },
  { id: 'p2', name: 'Bob', color: 'blue' as const },
  { id: 'p3', name: 'Cid', color: 'yellow' as const },
  { id: 'p4', name: 'Dee', color: 'white' as const },
];

/**
 * Beginner board, seed 'prod' (4 players): turn order p2, p3, p4, p1.
 * Catanian planets (hex → resource / disc → adjacent settlements):
 *   α P(0,1) food 11   p1 colony, p4 colony
 *   α P(1,0) carbon 8  p1 colony, p3 SPACEPORT
 *   α P(1,1) fuel 4    p4 colony, p3 SPACEPORT
 *   β P(3,0) ore 8     p2 colony, p4 colony
 *   β P(3,1) fuel 10   p2 colony, p1 spaceport
 *   β P(4,1) goods 3/12 p4 colony, p1 spaceport
 *   γ P(6,1) ore 5     p3 colony, p4 spaceport
 *   γ P(7,0) food 3    p3 colony, p2 colony
 *   γ P(7,1) carbon 6  p4 spaceport, p2 colony
 *   δ P(9,0) fuel 6    p3 colony, p1 colony
 *   δ P(9,1) goods 2/11 p3 colony, p2 spaceport
 *   δ P(10,1) ore 9    p1 colony, p2 spaceport
 */
function freshGame(): GameState {
  const state = createBeginnerGame({ players: four, seed: 'prod' });
  expect(state.turnOrder).toEqual(['p2', 'p3', 'p4', 'p1']);
  return state;
}

/** Rng whose `d6()` follows a script; everything else is a seeded generator. */
function scriptedRng(d6: number[], seed = 'script'): Rng {
  const base = createRng(seed);
  const queue = [...d6];
  return {
    ...base,
    next: () => base.next(),
    int: (n) => base.int(n),
    shuffle: (a) => base.shuffle(a),
    pick: (a) => base.pick(a),
    getState: () => base.getState(),
    d6: () => {
      const v = queue.shift();
      if (v === undefined) throw new Error('scriptedRng: d6 script exhausted');
      return v;
    },
  };
}

/** Rng that rolls `total` (split into two dice) then behaves like a seeded generator. */
function rollRng(total: number, seed = 'script'): Rng {
  const a = Math.min(6, total - 1);
  return scriptedRng([a, total - a], seed);
}

function apply(state: GameState, action: Action, rng: Rng): GameState {
  const r = applyAction(state, action, rng);
  if (!r.ok) throw new Error(`${action.type} rejected: ${r.error.code} ${r.error.message}`);
  return r.value;
}

function expectError(state: GameState, action: Action, rng: Rng, code: string): void {
  const r = applyAction(state, action, rng);
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.error.code).toBe(code);
}

function hand(state: GameState, id: PlayerId): Resource[] {
  return state.players.find((p) => p.id === id)!.hand;
}

function setHand(state: GameState, id: PlayerId, cards: Resource[]): void {
  state.players.find((p) => p.id === id)!.hand = [...cards];
}

function bag(state: GameState, id: PlayerId): Record<Resource, number> {
  return handToBag(hand(state, id));
}

function roll(state: GameState, total: number, seed?: string): GameState {
  return apply(state, { type: 'rollDice', playerId: state.activePlayer }, rollRng(total, seed));
}

const cards = (n: number, r: Resource = 'ore'): Resource[] => Array.from({ length: n }, () => r);

// ---------------------------------------------------------------------------
// Production
// ---------------------------------------------------------------------------

describe('rollDice — production', () => {
  it('sets turn.rolled, pays every settlement adjacent to a producing planet and moves to tradeBuild', () => {
    const before = freshGame();
    const after = roll(before, 8);
    expect(after.turn.rolled).toBe(8);
    expect(after.phase).toBe('tradeBuild');
    expect(after.turn.reserveDrawTaken).toBe(false);
    // carbon 8 (α): p1 colony, p3 spaceport; ore 8 (β): p2, p4 colonies.
    expect(bag(after, 'p1').carbon).toBe(bag(before, 'p1').carbon + 1);
    expect(bag(after, 'p3').carbon).toBe(bag(before, 'p3').carbon + 1);
    expect(bag(after, 'p2').ore).toBe(bag(before, 'p2').ore + 1);
    expect(bag(after, 'p4').ore).toBe(bag(before, 'p4').ore + 1);
    for (const id of ['p1', 'p2', 'p3', 'p4']) expect(hand(after, id)).toHaveLength(hand(before, id).length + 1);
    expect(after.supply.carbon).toBe(before.supply.carbon - 2);
    expect(after.supply.ore).toBe(before.supply.ore - 2);
    expect(after.turn.productionReceived).toEqual({ p1: 1, p2: 1, p3: 1, p4: 1 });
    expect(after.log.some((e) => e.kind === 'event' && /rolls a 8/.test(e.message))).toBe(true);
  });

  it('rolls with the injected rng only (two d6)', () => {
    const state = freshGame();
    const a = apply(state, { type: 'rollDice', playerId: state.activePlayer }, scriptedRng([2, 3]));
    expect(a.turn.rolled).toBe(5);
    const b = apply(state, { type: 'rollDice', playerId: state.activePlayer }, scriptedRng([6, 6]));
    expect(b.turn.rolled).toBe(12);
  });

  it('a spaceport produces 1, not 2', () => {
    const before = freshGame();
    const after = roll(before, 8);
    // p3's spaceport touches carbon-8; same payout as p1's plain colony.
    expect(bag(after, 'p3').carbon - bag(before, 'p3').carbon).toBe(1);
    expect(bag(after, 'p1').carbon - bag(before, 'p1').carbon).toBe(1);
  });

  it('a two-number disc produces on either number', () => {
    const before = freshGame();
    const on3 = roll(before, 3);
    const on12 = roll(before, 12);
    for (const after of [on3, on12]) {
      expect(bag(after, 'p4').goods - bag(before, 'p4').goods).toBe(1);
      expect(bag(after, 'p1').goods - bag(before, 'p1').goods).toBe(1);
    }
    // 3 also hits food-3 (γ): p3 and p2; 12 hits nothing else.
    expect(bag(on3, 'p3').food - bag(before, 'p3').food).toBe(1);
    expect(bag(on3, 'p2').food - bag(before, 'p2').food).toBe(1);
    expect(hand(on12, 'p2')).toEqual(hand(before, 'p2'));
    expect(hand(on12, 'p3')).toEqual(hand(before, 'p3'));
    expect(on12.turn.productionReceived).toEqual({ p1: 1, p2: 0, p3: 0, p4: 1 });
  });

  it('a face-down disc produces nothing', () => {
    const before = freshGame();
    planetAtHex(before.board, [1, 0])!.disc!.faceUp = false; // carbon 8
    const after = roll(before, 8);
    expect(hand(after, 'p1')).toEqual(hand(before, 'p1'));
    expect(hand(after, 'p3')).toEqual(hand(before, 'p3'));
    expect(bag(after, 'p2').ore - bag(before, 'p2').ore).toBe(1); // ore-8 still produces
  });

  it('a planet with a token or without a disc produces nothing', () => {
    const before = freshGame();
    planetAtHex(before.board, [1, 0])!.token = { kind: 'pirateBase', value: 4 };
    planetAtHex(before.board, [3, 0])!.disc = null;
    const after = roll(before, 8);
    for (const id of ['p1', 'p2', 'p3', 'p4']) expect(hand(after, id)).toEqual(hand(before, id));
    expect(after.supply).toEqual(before.supply);
  });

  it('blocker pieces (owner null) produce for nobody', () => {
    const before = createBeginnerGame({ players: four.slice(0, 3), seed: 'prod3' });
    expect(before.blockerColor).toBe('white');
    // fuel-4 (α P(1,1)) touches the white colony and the yellow (p3) spaceport.
    const after = apply(before, { type: 'rollDice', playerId: before.activePlayer }, rollRng(4));
    expect(after.supply.fuel).toBe(before.supply.fuel - 1);
    expect(bag(after, 'p3').fuel - bag(before, 'p3').fuel).toBe(1);
    expect(hand(after, 'p1')).toEqual(hand(before, 'p1'));
    expect(hand(after, 'p2')).toEqual(hand(before, 'p2'));
  });

  it('computeProduction is table-correct for every Catanian number', () => {
    const state = freshGame();
    const table: [number, Record<PlayerId, Partial<Record<Resource, number>>>][] = [
      [2, { p3: { goods: 1 }, p2: { goods: 1 } }],
      [3, { p3: { food: 1 }, p2: { food: 1 }, p4: { goods: 1 }, p1: { goods: 1 } }],
      [4, { p4: { fuel: 1 }, p3: { fuel: 1 } }],
      [5, { p3: { ore: 1 }, p4: { ore: 1 } }],
      [6, { p4: { carbon: 1 }, p2: { carbon: 1 }, p3: { fuel: 1 }, p1: { fuel: 1 } }],
      [8, { p1: { carbon: 1 }, p3: { carbon: 1 }, p2: { ore: 1 }, p4: { ore: 1 } }],
      [9, { p1: { ore: 1 }, p2: { ore: 1 } }],
      [10, { p2: { fuel: 1 }, p1: { fuel: 1 } }],
      [11, { p1: { food: 1 }, p4: { food: 1 }, p3: { goods: 1 }, p2: { goods: 1 } }],
      [12, { p4: { goods: 1 }, p1: { goods: 1 } }],
    ];
    for (const [n, expected] of table) {
      const { paid, shortages } = computeProduction(state, n);
      expect(shortages).toEqual([]);
      for (const p of state.players) {
        for (const r of RESOURCES) expect(paid[p.id]![r], `roll ${n} ${p.id} ${r}`).toBe(expected[p.id]?.[r] ?? 0);
      }
    }
  });

  it('rejects a second roll in the same turn', () => {
    const after = freshGame();
    after.turn.rolled = 6;
    expectError(after, { type: 'rollDice', playerId: after.activePlayer }, rollRng(8), 'ruleViolation');
  });
});

describe('rollDice — Green Folk production increase', () => {
  it('gives +1 of the card type whenever the holder would receive ≥1 of it', () => {
    const before = freshGame();
    before.players.find((p) => p.id === 'p1')!.friendshipCards.push('xulu'); // carbon
    const after = roll(before, 8);
    expect(bag(after, 'p1').carbon - bag(before, 'p1').carbon).toBe(2);
    expect(bag(after, 'p3').carbon - bag(before, 'p3').carbon).toBe(1);
    expect(after.supply.carbon).toBe(before.supply.carbon - 3);
    expect(after.turn.productionReceived!.p1).toBe(2);
  });

  it('gives nothing when the holder receives 0 of that type', () => {
    const before = freshGame();
    before.players.find((p) => p.id === 'p1')!.friendshipCards.push('asox'); // ore; p1 gets carbon on an 8
    const after = roll(before, 8);
    expect(bag(after, 'p1').ore).toBe(bag(before, 'p1').ore);
    expect(bag(after, 'p1').carbon - bag(before, 'p1').carbon).toBe(1);
  });

  it.each([
    ['axxa', 'fuel', 10, 'p1'],
    ['xulu', 'carbon', 8, 'p3'],
    ['asox', 'ore', 9, 'p2'],
    ['esox', 'food', 11, 'p4'],
    ['xom', 'goods', 12, 'p1'],
  ] as const)('%s adds +1 %s', (card, resource, n, pid) => {
    const before = freshGame();
    before.players.find((p) => p.id === pid)!.friendshipCards.push(card);
    const after = roll(before, n);
    expect(bag(after, pid)[resource] - bag(before, pid)[resource]).toBe(2);
  });
});

describe('rollDice — supply shortage', () => {
  it('nobody receives a type the supply cannot pay in full; other types are paid', () => {
    const before = freshGame();
    before.supply.carbon = 1; // demand on an 8 is 2
    const after = roll(before, 8);
    expect(bag(after, 'p1').carbon).toBe(bag(before, 'p1').carbon);
    expect(bag(after, 'p3').carbon).toBe(bag(before, 'p3').carbon);
    expect(after.supply.carbon).toBe(1);
    expect(bag(after, 'p2').ore - bag(before, 'p2').ore).toBe(1);
    expect(bag(after, 'p4').ore - bag(before, 'p4').ore).toBe(1);
    expect(after.turn.productionReceived).toEqual({ p1: 0, p2: 1, p3: 0, p4: 1 });
    expect(after.log.some((e) => /shortage.*carbon/i.test(e.message))).toBe(true);
  });

  it('pays when the supply exactly covers the demand', () => {
    const before = freshGame();
    before.supply.carbon = 2;
    const after = roll(before, 8);
    expect(after.supply.carbon).toBe(0);
    expect(bag(after, 'p1').carbon - bag(before, 'p1').carbon).toBe(1);
  });

  it('counts the Green Folk bonus towards the demand', () => {
    const before = freshGame();
    before.players.find((p) => p.id === 'p1')!.friendshipCards.push('xulu');
    before.supply.carbon = 2; // demand 2 + 1 bonus = 3
    const after = roll(before, 8);
    expect(after.supply.carbon).toBe(2);
    expect(bag(after, 'p1').carbon).toBe(bag(before, 'p1').carbon);
    expect(bag(after, 'p3').carbon).toBe(bag(before, 'p3').carbon);
  });
});

// ---------------------------------------------------------------------------
// Reserve draw
// ---------------------------------------------------------------------------

describe('takeReserveDraw', () => {
  function withVp(state: GameState, id: PlayerId, famePieces: number): GameState {
    state.players.find((p) => p.id === id)!.famePieces = famePieces;
    recomputeAllVp(state);
    return state;
  }

  it.each([
    [4, 2],
    [7, 2],
    [8, 1],
    [9, 1],
    [10, 0],
    [14, 0],
  ])('draws by the VP table: %i VP → %i cards', (vp, expected) => {
    // Base VP is 4; each 2 fame pieces add 1 VP.
    const state = withVp(freshGame(), 'p2', (vp - 4) * 2);
    expect(state.players[1]!.vp).toBe(vp);
    const rolled = roll(state, 8);
    const rng = createRng('draw');
    const pile = [...rolled.reservePile];
    const after = apply(rolled, { type: 'takeReserveDraw', playerId: 'p2' }, rng);
    expect(after.turn.reserveDrawTaken).toBe(true);
    expect(hand(after, 'p2')).toEqual([...hand(rolled, 'p2'), ...pile.slice(0, expected)]);
    expect(after.reservePile).toEqual(pile.slice(expected));
  });

  it('is once per turn', () => {
    const rolled = roll(freshGame(), 8);
    const rng = createRng('draw');
    const once = apply(rolled, { type: 'takeReserveDraw', playerId: 'p2' }, rng);
    expectError(once, { type: 'takeReserveDraw', playerId: 'p2' }, rng, 'ruleViolation');
  });

  it('requires the dice to have been rolled', () => {
    expectError(freshGame(), { type: 'takeReserveDraw', playerId: 'p2' }, createRng('draw'), 'ruleViolation');
  });

  it('rebuilds the reserve pile from the supply when it runs out', () => {
    const rolled = roll(freshGame(), 8);
    rolled.reservePile = ['food'];
    const supplyBefore = { ...rolled.supply };
    const after = apply(rolled, { type: 'takeReserveDraw', playerId: 'p2' }, createRng('draw'));
    expect(hand(after, 'p2')).toHaveLength(hand(rolled, 'p2').length + 2);
    expect(hand(after, 'p2')[hand(rolled, 'p2').length]).toBe('food');
    expect(after.reservePile).toHaveLength(40 - 1);
    const supplyTotal = (s: Record<Resource, number>) => RESOURCES.reduce((n, r) => n + s[r], 0);
    expect(supplyTotal(after.supply)).toBe(supplyTotal(supplyBefore) - 40);
  });
});

// ---------------------------------------------------------------------------
// Rolling a 7
// ---------------------------------------------------------------------------

describe('rolling a 7 — discard threshold', () => {
  it.each([
    [8, 4],
    [9, 4],
    [10, 5],
    [13, 6],
  ])('a hand of %i discards %i', (size, expected) => {
    expect(discardCountFor(size)).toBe(expected);
  });

  it('only players with 8+ cards must discard; Reduced Tribute raises it to >12', () => {
    const state = freshGame();
    setHand(state, 'p1', cards(7));
    setHand(state, 'p2', cards(8));
    setHand(state, 'p3', cards(9));
    setHand(state, 'p4', cards(12));
    state.players.find((p) => p.id === 'p4')!.friendshipCards.push('raHal');
    expect(discardThresholdFor(state.players[3]!)).toBe(12);
    const after = roll(state, 7);
    expect(after.phase).toBe('production');
    expect(after.turn.rolled).toBe(7);
    expect(after.turn.seven).toEqual({ awaitingDiscard: ['p2', 'p3'], stealDone: false });
    expect(after.turn.productionReceived).toBeUndefined();
    expect(sevenWaitingOn(after)).toEqual(['p2', 'p3']);
    for (const id of ['p1', 'p2', 'p3', 'p4']) expect(hand(after, id)).toEqual(hand(state, id));
  });

  it('a Reduced Tribute holder with 13 cards still discards 6', () => {
    const state = freshGame();
    setHand(state, 'p4', cards(13));
    state.players.find((p) => p.id === 'p4')!.friendshipCards.push('raHal');
    const after = roll(state, 7);
    expect(after.turn.seven!.awaitingDiscard).toEqual(['p4']);
    expectError(after, { type: 'discardForSeven', playerId: 'p4', cards: cards(5) }, createRng('x'), 'invalidAction');
    const done = apply(after, { type: 'discardForSeven', playerId: 'p4', cards: cards(6) }, createRng('x'));
    expect(hand(done, 'p4')).toHaveLength(7);
  });
});

describe('rolling a 7 — full flow', () => {
  /** p2 rolls; p3 (9 cards) and p4 (8 cards) must discard; p1 holds 5. */
  function sevenState(): GameState {
    const state = freshGame();
    setHand(state, 'p1', ['ore', 'fuel', 'carbon', 'food', 'goods']);
    setHand(state, 'p2', ['food', 'food']);
    setHand(state, 'p3', [...cards(5, 'ore'), ...cards(4, 'food')]);
    setHand(state, 'p4', [...cards(6, 'carbon'), ...cards(2, 'goods')]);
    return roll(state, 7);
  }

  it('resolves in order: discards → steal → opponent reserve draws → tradeBuild', () => {
    const rng = createRng('seven');
    const s0 = sevenState();
    expect(s0.turn.seven!.awaitingDiscard).toEqual(['p3', 'p4']);
    expect(s0.phase).toBe('production');

    // Nothing else is allowed before the discards are done.
    expectError(s0, { type: 'stealForSeven', playerId: 'p2', target: 'p1' }, rng, 'ruleViolation');
    expectError(s0, { type: 'takeReserveDraw', playerId: 'p2' }, rng, 'ruleViolation');
    expectError(s0, { type: 'discardForSeven', playerId: 'p1', cards: cards(2) }, rng, 'ruleViolation');
    // Wrong count / cards not held.
    expectError(s0, { type: 'discardForSeven', playerId: 'p3', cards: cards(3, 'ore') }, rng, 'invalidAction');
    expectError(s0, { type: 'discardForSeven', playerId: 'p3', cards: cards(4, 'goods') }, rng, 'insufficientResources');

    const s1 = apply(s0, { type: 'discardForSeven', playerId: 'p3', cards: ['ore', 'ore', 'food', 'food'] }, rng);
    expect(hand(s1, 'p3').sort()).toEqual([...cards(3, 'ore'), ...cards(2, 'food')].sort());
    expect(s1.supply.ore).toBe(s0.supply.ore + 2);
    expect(s1.supply.food).toBe(s0.supply.food + 2);
    expect(s1.turn.seven!.awaitingDiscard).toEqual(['p4']);
    expect(s1.phase).toBe('production');
    // Already discarded: cannot discard again.
    expectError(s1, { type: 'discardForSeven', playerId: 'p3', cards: cards(2, 'ore') }, rng, 'ruleViolation');

    const s2 = apply(s1, { type: 'discardForSeven', playerId: 'p4', cards: cards(4, 'carbon') }, rng);
    expect(hand(s2, 'p4')).toHaveLength(4);
    expect(s2.turn.seven).toEqual({ awaitingDiscard: [], stealDone: false });
    expect(s2.phase).toBe('production');
    expect(sevenWaitingOn(s2)).toEqual(['p2']);

    // Steal: must be an opponent with cards; reserve draw still blocked.
    expectError(s2, { type: 'stealForSeven', playerId: 'p2', target: 'p2' }, rng, 'invalidTarget');
    expectError(s2, { type: 'stealForSeven', playerId: 'p2', target: 'nobody' }, rng, 'invalidTarget');
    expectError(s2, { type: 'takeReserveDraw', playerId: 'p2' }, rng, 'ruleViolation');
    const pile = [...s2.reservePile];
    const s3 = apply(s2, { type: 'stealForSeven', playerId: 'p2', target: 'p1' }, rng);
    expect(hand(s3, 'p1')).toHaveLength(5 - 1 + 1); // lost one to p2, drew one
    expect(hand(s3, 'p2')).toHaveLength(3); // 2 + stolen card (roller does not draw here)
    const stolen = hand(s3, 'p2')[2]!;
    expect(hand(s2, 'p1')).toContain(stolen);
    // Opponent draws, in order left of the roller: p3, p4, p1 take the top 3 pile cards.
    expect(hand(s3, 'p3').at(-1)).toBe(pile[0]);
    expect(hand(s3, 'p4').at(-1)).toBe(pile[1]);
    expect(hand(s3, 'p1').at(-1)).toBe(pile[2]);
    expect(s3.reservePile).toEqual(pile.slice(3));
    expect(s3.turn.seven).toEqual({ awaitingDiscard: [], stealDone: true });
    expect(s3.phase).toBe('tradeBuild');
    expect(sevenWaitingOn(s3)).toEqual([]);

    // The roller's own VP draw is still available afterwards (§6 step 4), once.
    const s4 = apply(s3, { type: 'takeReserveDraw', playerId: 'p2' }, rng);
    expect(hand(s4, 'p2')).toHaveLength(5);
    expect(s4.reservePile).toEqual(pile.slice(5));
    expectError(s4, { type: 'takeReserveDraw', playerId: 'p2' }, rng, 'ruleViolation');
    expectError(s4, { type: 'stealForSeven', playerId: 'p2', target: 'p1' }, rng, 'wrongPhase');
  });

  it('the stolen card is chosen by the rng', () => {
    const s = sevenState();
    setHand(s, 'p3', cards(3));
    setHand(s, 'p4', cards(3));
    s.turn.seven = { awaitingDiscard: [], stealDone: false };
    const seen = new Set<Resource>();
    for (let i = 0; i < 30; i++) {
      const after = apply(s, { type: 'stealForSeven', playerId: 'p2', target: 'p1' }, createRng(`steal-${i}`));
      seen.add(hand(after, 'p2')[2]!);
    }
    expect(seen.size).toBeGreaterThan(1);
    // Scripted: int(5) → 2 picks the third card.
    const scripted: Rng = { ...createRng('x'), int: () => 2, d6: () => 1 };
    const after = apply(s, { type: 'stealForSeven', playerId: 'p2', target: 'p1' }, scripted);
    expect(hand(after, 'p2')[2]).toBe('carbon');
    expect(hand(after, 'p1').slice(0, 4)).toEqual(['ore', 'fuel', 'food', 'goods']);
  });

  it('skips the discard step when nobody is over the limit', () => {
    const state = freshGame();
    const after = roll(state, 7);
    expect(after.turn.seven).toEqual({ awaitingDiscard: [], stealDone: false });
    expect(after.phase).toBe('production');
    expect(sevenWaitingOn(after)).toEqual(['p2']);
    const done = apply(after, { type: 'stealForSeven', playerId: 'p2', target: 'p3' }, createRng('s'));
    expect(done.phase).toBe('tradeBuild');
    expect(hand(done, 'p2')).toHaveLength(4);
    expect(hand(done, 'p3')).toHaveLength(3); // -1 stolen, +1 drawn
    expect(hand(done, 'p4')).toHaveLength(4);
    expect(hand(done, 'p1')).toHaveLength(4);
  });

  it('skips the steal when no opponent holds a card, still giving opponents their draw', () => {
    const state = freshGame();
    for (const id of ['p1', 'p3', 'p4']) setHand(state, id, []);
    const pile = [...state.reservePile];
    const after = roll(state, 7);
    expect(after.phase).toBe('tradeBuild');
    expect(after.turn.seven).toEqual({ awaitingDiscard: [], stealDone: true });
    expect(hand(after, 'p3')).toEqual([pile[0]]);
    expect(hand(after, 'p4')).toEqual([pile[1]]);
    expect(hand(after, 'p1')).toEqual([pile[2]]);
    expect(hand(after, 'p2')).toEqual(hand(state, 'p2'));
    expect(after.log.some((e) => /steal is skipped/.test(e.message))).toBe(true);
  });

  it('skips the steal after discards when the discarders emptied the only hands', () => {
    const state = freshGame();
    setHand(state, 'p1', []);
    setHand(state, 'p4', []);
    setHand(state, 'p3', cards(8));
    const s0 = roll(state, 7);
    expect(s0.turn.seven!.awaitingDiscard).toEqual(['p3']);
    // p3 keeps 4 cards, so a steal target exists → wait for the steal.
    const s1 = apply(s0, { type: 'discardForSeven', playerId: 'p3', cards: cards(4) }, createRng('s'));
    expect(s1.phase).toBe('production');
    expect(s1.turn.seven!.stealDone).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Galactic Relief Fund
// ---------------------------------------------------------------------------

describe('Galactic Relief Fund eligibility', () => {
  function withCard(state: GameState, id: PlayerId): void {
    state.players.find((p) => p.id === id)!.friendshipCards.push('raHno');
  }

  it('is true only for a holder who received 0 cards from a non-7 roll', () => {
    const state = freshGame();
    withCard(state, 'p2');
    withCard(state, 'p1');
    expect(reliefEligible(state, 'p2')).toBe(false); // not rolled yet
    const after = roll(state, 12); // goods to p4 and p1 only
    expect(reliefEligible(after, 'p2')).toBe(true);
    expect(reliefEligible(after, 'p1')).toBe(false); // produced
    expect(reliefEligible(after, 'p3')).toBe(false); // no card
    expect(reliefEligible(after, 'ghost')).toBe(false);
  });

  it('is false on a 7 and once the card was used this turn', () => {
    const state = freshGame();
    withCard(state, 'p2');
    const seven = roll(state, 7);
    expect(reliefEligible(seven, 'p2')).toBe(false);
    const after = roll(state, 12);
    after.turn.usedOncePerTurn.push('raHno');
    expect(reliefEligible(after, 'p2')).toBe(false);
  });

  it('counts a shortage as receiving 0', () => {
    const state = freshGame();
    withCard(state, 'p1');
    state.supply.carbon = 0;
    const after = roll(state, 8);
    expect(after.turn.productionReceived!.p1).toBe(0);
    expect(reliefEligible(after, 'p1')).toBe(true);
  });
});
