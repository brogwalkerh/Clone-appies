import { describe, expect, it } from 'vitest';
import type { GameState, Resource } from '../src/types.js';
import { cardsInPlay, fails, ok, opponents, player, setHand, tradeBuildState } from './support/tradeBuild.js';

describe('tradeWithSupply: base ratios', () => {
  it('3 identical → 1 any (cards go back to the supply)', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    setHand(state, me, ['ore', 'ore', 'ore', 'food']);
    const ore = state.supply.ore;
    const fuel = state.supply.fuel;
    const total = cardsInPlay(state);
    const next = ok(state, { type: 'tradeWithSupply', playerId: me, give: ['ore', 'ore', 'ore'], want: 'fuel' });
    expect(player(next, me).hand).toEqual(['food', 'fuel']);
    expect(next.supply.ore).toBe(ore + 3);
    expect(next.supply.fuel).toBe(fuel - 1);
    expect(cardsInPlay(next)).toBe(total);
  });

  it('2 goods → 1 any, and 3 goods also works as 3 identical', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    setHand(state, me, ['goods', 'goods', 'goods', 'goods', 'goods']);
    const a = ok(state, { type: 'tradeWithSupply', playerId: me, give: ['goods', 'goods'], want: 'ore' });
    expect(player(a, me).hand).toEqual(['goods', 'goods', 'goods', 'ore']);
    const b = ok(a, { type: 'tradeWithSupply', playerId: me, give: ['goods', 'goods', 'goods'], want: 'carbon' });
    expect(player(b, me).hand).toEqual(['ore', 'carbon']);
  });

  it('rejects wrong ratios, mixed cards and gifting', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    setHand(state, me, ['ore', 'ore', 'ore', 'fuel', 'goods']);
    fails(state, { type: 'tradeWithSupply', playerId: me, give: ['ore', 'ore'], want: 'fuel' }, 'ruleViolation');
    fails(state, { type: 'tradeWithSupply', playerId: me, give: ['ore', 'ore', 'fuel'], want: 'food' }, 'ruleViolation');
    fails(state, { type: 'tradeWithSupply', playerId: me, give: ['ore', 'ore', 'ore', 'ore'], want: 'food' }, 'ruleViolation');
    fails(state, { type: 'tradeWithSupply', playerId: me, give: ['goods'], want: 'food' }, 'ruleViolation');
    fails(state, { type: 'tradeWithSupply', playerId: me, give: [], want: 'food' }, 'ruleViolation');
    fails(state, { type: 'tradeWithSupply', playerId: me, give: ['ore', 'ore', 'ore'], want: 'gold' as Resource }, 'invalidAction');
  });

  it('rejects when the player lacks the cards or the supply lacks the wanted card', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    setHand(state, me, ['ore', 'ore', 'goods']);
    fails(state, { type: 'tradeWithSupply', playerId: me, give: ['ore', 'ore', 'ore'], want: 'fuel' }, 'insufficientResources');
    setHand(state, me, ['ore', 'ore', 'ore']);
    state.supply.fuel = 0;
    fails(state, { type: 'tradeWithSupply', playerId: me, give: ['ore', 'ore', 'ore'], want: 'fuel' }, 'supplyEmpty');
  });

  it('is active-player only and Trade & Build only', () => {
    const state = tradeBuildState();
    const other = opponents(state)[0]!;
    setHand(state, other.id, ['ore', 'ore', 'ore']);
    fails(state, { type: 'tradeWithSupply', playerId: other.id, give: ['ore', 'ore', 'ore'], want: 'fuel' }, 'notYourTurn');
    const me = state.activePlayer;
    setHand(state, me, ['ore', 'ore', 'ore']);
    state.phase = 'production';
    fails(state, { type: 'tradeWithSupply', playerId: me, give: ['ore', 'ore', 'ore'], want: 'fuel' }, 'wrongPhase');
  });
});

describe('tradeWithSupply: Merchants friendship cards', () => {
  const merchants: { card: 'zuzzo' | 'orzel' | 'crizzetu' | 'utuzzo'; resource: Resource }[] = [
    { card: 'zuzzo', resource: 'carbon' },
    { card: 'orzel', resource: 'food' },
    { card: 'crizzetu', resource: 'ore' },
    { card: 'utuzzo', resource: 'fuel' },
  ];

  for (const { card, resource } of merchants) {
    it(`${card}: 2 ${resource} → 1 any, unlimited times per turn`, () => {
      let state = tradeBuildState();
      const me = state.activePlayer;
      player(state, me).friendshipCards = [card];
      setHand(state, me, [resource, resource, resource, resource]);
      state = ok(state, { type: 'tradeWithSupply', playerId: me, give: [resource, resource], want: 'goods' });
      state = ok(state, { type: 'tradeWithSupply', playerId: me, give: [resource, resource], want: 'goods' });
      expect(player(state, me).hand).toEqual(['goods', 'goods']);
      expect(state.turn.usedOncePerTurn).toEqual([]);
    });
  }

  it('a Merchants card only discounts its own resource', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    player(state, me).friendshipCards = ['orzel'];
    setHand(state, me, ['carbon', 'carbon']);
    fails(state, { type: 'tradeWithSupply', playerId: me, give: ['carbon', 'carbon'], want: 'food' }, 'ruleViolation');
  });

  it('Ezzel: 1 goods → 1 any, once per turn, reset by endTurn', () => {
    let state = tradeBuildState();
    const me = state.activePlayer;
    player(state, me).friendshipCards = ['ezzel'];
    setHand(state, me, ['goods', 'goods', 'goods']);
    state = ok(state, { type: 'tradeWithSupply', playerId: me, give: ['goods'], want: 'ore' });
    expect(player(state, me).hand).toEqual(['goods', 'goods', 'ore']);
    expect(state.turn.usedOncePerTurn).toContain('ezzel');
    fails(state, { type: 'tradeWithSupply', playerId: me, give: ['goods'], want: 'ore' }, 'ruleViolation');
    // The normal 2 goods → 1 is still available.
    state = ok(state, { type: 'tradeWithSupply', playerId: me, give: ['goods', 'goods'], want: 'fuel' });

    // Next own turn: cycle the turn back around to `me`.
    for (let i = 0; i < state.turnOrder.length; i++) {
      state.phase = 'flight.move';
      state = ok(state, { type: 'endTurn', playerId: state.activePlayer });
    }
    expect(state.activePlayer).toBe(me);
    expect(state.turn.usedOncePerTurn).toEqual([]);
    state.phase = 'tradeBuild';
    setHand(state, me, ['goods']);
    state = ok(state, { type: 'tradeWithSupply', playerId: me, give: ['goods'], want: 'ore' });
    expect(player(state, me).hand).toEqual(['ore']);
  });

  it('Merchants cards cannot be "used" through useFriendshipCard', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    player(state, me).friendshipCards = ['zuzzo', 'ezzel'];
    setHand(state, me, ['carbon', 'carbon', 'goods']);
    fails(state, { type: 'useFriendshipCard', playerId: me, cardId: 'zuzzo', give: 'carbon', want: 'ore' }, 'invalidAction');
    fails(state, { type: 'useFriendshipCard', playerId: me, cardId: 'ezzel', give: 'goods', want: 'ore' }, 'invalidAction');
  });
});

describe('player trades: proposals', () => {
  function seeded(): { state: GameState; me: string; x: string; y: string } {
    const state = tradeBuildState();
    const me = state.activePlayer;
    const [x, y] = opponents(state).map((p) => p.id) as [string, string];
    setHand(state, me, ['ore', 'ore', 'fuel']);
    setHand(state, x, ['carbon', 'food']);
    setHand(state, y, ['goods', 'goods']);
    return { state, me, x, y };
  }

  it('the active player may propose to anyone', () => {
    const { state, me, x } = seeded();
    const next = ok(state, { type: 'proposeTrade', playerId: me, to: x, give: { ore: 1 }, want: { carbon: 1 } });
    expect(next.openTrade).toEqual({ from: me, to: x, give: { ore: 1 }, want: { carbon: 1 } });
    // Hands untouched until finalised.
    expect(player(next, me).hand).toEqual(['ore', 'ore', 'fuel']);
  });

  it('a non-active player may propose only to the active player', () => {
    const { state, me, x, y } = seeded();
    const next = ok(state, { type: 'proposeTrade', playerId: x, to: me, give: { carbon: 1 }, want: { ore: 1 } });
    expect(next.openTrade?.from).toBe(x);
    fails(state, { type: 'proposeTrade', playerId: x, to: y, give: { carbon: 1 }, want: { goods: 1 } }, 'ruleViolation');
  });

  it('rejects gifting, trades with oneself, the supply, unknown players and cards not held', () => {
    const { state, me, x } = seeded();
    fails(state, { type: 'proposeTrade', playerId: me, to: x, give: {}, want: { carbon: 1 } }, 'ruleViolation');
    fails(state, { type: 'proposeTrade', playerId: me, to: x, give: { ore: 1 }, want: {} }, 'ruleViolation');
    fails(state, { type: 'proposeTrade', playerId: me, to: x, give: { ore: 0 }, want: { carbon: 1 } }, 'ruleViolation');
    fails(state, { type: 'proposeTrade', playerId: me, to: me, give: { ore: 1 }, want: { carbon: 1 } }, 'invalidTarget');
    fails(state, { type: 'proposeTrade', playerId: me, to: 'supply', give: { ore: 1 }, want: { carbon: 1 } }, 'invalidAction');
    fails(state, { type: 'proposeTrade', playerId: me, to: 'nobody', give: { ore: 1 }, want: { carbon: 1 } }, 'invalidTarget');
    fails(state, { type: 'proposeTrade', playerId: me, to: x, give: { ore: 3 }, want: { carbon: 1 } }, 'insufficientResources');
    fails(state, { type: 'proposeTrade', playerId: me, to: x, give: { ore: -1 }, want: { carbon: 1 } }, 'invalidAction');
  });

  it('keeps one open proposal: the active player may replace it, a non-active player only their own', () => {
    const { state, me, x, y } = seeded();
    const open = ok(state, { type: 'proposeTrade', playerId: x, to: me, give: { carbon: 1 }, want: { ore: 1 } });
    fails(open, { type: 'proposeTrade', playerId: y, to: me, give: { goods: 1 }, want: { ore: 1 } }, 'ruleViolation');
    const replacedByOwner = ok(open, { type: 'proposeTrade', playerId: x, to: me, give: { food: 1 }, want: { ore: 1 } });
    expect(replacedByOwner.openTrade?.give).toEqual({ food: 1 });
    const replacedByActive = ok(open, { type: 'proposeTrade', playerId: me, to: y, give: { fuel: 1 }, want: { goods: 1 } });
    expect(replacedByActive.openTrade).toEqual({ from: me, to: y, give: { fuel: 1 }, want: { goods: 1 } });
  });

  it('is only allowed during Trade & Build', () => {
    const { state, me, x } = seeded();
    state.phase = 'production';
    fails(state, { type: 'proposeTrade', playerId: me, to: x, give: { ore: 1 }, want: { carbon: 1 } }, 'wrongPhase');
  });
});

describe('player trades: responses and finalisation', () => {
  function seeded(): { state: GameState; me: string; x: string; y: string } {
    const state = tradeBuildState();
    const me = state.activePlayer;
    const [x, y] = opponents(state).map((p) => p.id) as [string, string];
    setHand(state, me, ['ore', 'ore', 'fuel']);
    setHand(state, x, ['carbon', 'food']);
    setHand(state, y, ['goods', 'goods']);
    return { state, me, x, y };
  }

  it("the opponent accepting the active player's offer finalises it (active already consented)", () => {
    const { state, me, x } = seeded();
    const total = cardsInPlay(state);
    const open = ok(state, { type: 'proposeTrade', playerId: me, to: x, give: { ore: 2 }, want: { carbon: 1 } });
    const done = ok(open, { type: 'respondTrade', playerId: x, accept: true });
    expect(done.openTrade).toBeNull();
    expect(player(done, me).hand).toEqual(['fuel', 'carbon']);
    expect(player(done, x).hand).toEqual(['food', 'ore', 'ore']);
    expect(cardsInPlay(done)).toBe(total);
  });

  it('an opponent offer is finalised only when the active player accepts', () => {
    const { state, me, x, y } = seeded();
    const open = ok(state, { type: 'proposeTrade', playerId: x, to: me, give: { carbon: 1 }, want: { ore: 1 } });
    // The proposer cannot accept their own proposal, nor can a third party.
    fails(open, { type: 'respondTrade', playerId: x, accept: true }, 'ruleViolation');
    fails(open, { type: 'respondTrade', playerId: y, accept: true }, 'ruleViolation');
    fails(open, { type: 'respondTrade', playerId: y, accept: false }, 'ruleViolation');
    const done = ok(open, { type: 'respondTrade', playerId: me, accept: true });
    expect(done.openTrade).toBeNull();
    expect(player(done, me).hand).toEqual(['ore', 'fuel', 'carbon']);
    expect(player(done, x).hand).toEqual(['food', 'ore']);
  });

  it('rejecting closes the proposal; the proposer may withdraw', () => {
    const { state, me, x } = seeded();
    const open = ok(state, { type: 'proposeTrade', playerId: me, to: x, give: { ore: 1 }, want: { carbon: 1 } });
    const rejected = ok(open, { type: 'respondTrade', playerId: x, accept: false });
    expect(rejected.openTrade).toBeNull();
    expect(player(rejected, me).hand).toEqual(['ore', 'ore', 'fuel']);
    const withdrawn = ok(open, { type: 'respondTrade', playerId: me, accept: false });
    expect(withdrawn.openTrade).toBeNull();
  });

  it('a counter-offer replaces the proposal from the responder, and the other side then accepts', () => {
    const { state, me, x } = seeded();
    const open = ok(state, { type: 'proposeTrade', playerId: me, to: x, give: { ore: 1 }, want: { carbon: 1 } });
    const countered = ok(open, {
      type: 'respondTrade',
      playerId: x,
      accept: false,
      counter: { give: { carbon: 1 }, want: { ore: 2 } },
    });
    expect(countered.openTrade).toEqual({ from: x, to: me, give: { carbon: 1 }, want: { ore: 2 } });
    // Only the recipient (now the active player) may accept or counter.
    fails(countered, { type: 'respondTrade', playerId: x, accept: true }, 'ruleViolation');
    fails(countered, { type: 'respondTrade', playerId: x, accept: false, counter: { give: { food: 1 }, want: { ore: 1 } } }, 'ruleViolation');
    const done = ok(countered, { type: 'respondTrade', playerId: me, accept: true });
    expect(player(done, me).hand).toEqual(['fuel', 'carbon']);
    expect(player(done, x).hand).toEqual(['food', 'ore', 'ore']);
    expect(done.openTrade).toBeNull();
  });

  it('a counter must not gift and must be backed by the responder hand', () => {
    const { state, me, x } = seeded();
    const open = ok(state, { type: 'proposeTrade', playerId: me, to: x, give: { ore: 1 }, want: { carbon: 1 } });
    fails(open, { type: 'respondTrade', playerId: x, accept: false, counter: { give: {}, want: { ore: 1 } } }, 'ruleViolation');
    fails(open, { type: 'respondTrade', playerId: x, accept: false, counter: { give: { carbon: 1 }, want: {} } }, 'ruleViolation');
    fails(open, { type: 'respondTrade', playerId: x, accept: false, counter: { give: { goods: 1 }, want: { ore: 1 } } }, 'insufficientResources');
  });

  it('finalisation re-checks both hands and keeps the proposal open on failure', () => {
    const { state, me, x } = seeded();
    const open = ok(state, { type: 'proposeTrade', playerId: me, to: x, give: { ore: 2 }, want: { carbon: 1 } });
    const drained = structuredClone(open);
    setHand(drained, me, ['fuel']);
    fails(drained, { type: 'respondTrade', playerId: x, accept: true }, 'insufficientResources');
    const theyDrained = structuredClone(open);
    setHand(theyDrained, x, ['food']);
    fails(theyDrained, { type: 'respondTrade', playerId: x, accept: true }, 'insufficientResources');
  });

  it('responding without an open proposal is rejected', () => {
    const { state, me } = seeded();
    fails(state, { type: 'respondTrade', playerId: me, accept: true }, 'invalidAction');
  });
});

describe('useFriendshipCard: Diplomats', () => {
  it('Fame for Sale: 1 goods → 1 fame piece, once per turn even with both copies', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    player(state, me).friendshipCards = ['reBah', 'reOhm'];
    setHand(state, me, ['goods', 'goods']);
    const tray = state.upgradesTray.famePieces;
    const goods = state.supply.goods;

    const next = ok(state, { type: 'useFriendshipCard', playerId: me, cardId: 'reBah' });
    expect(player(next, me).famePieces).toBe(2);
    expect(player(next, me).vp).toBe(5);
    expect(next.upgradesTray.famePieces).toBe(tray - 1);
    expect(next.supply.goods).toBe(goods + 1);
    expect(player(next, me).hand).toEqual(['goods']);
    expect(next.turn.usedOncePerTurn).toContain('fameForSale');
    fails(next, { type: 'useFriendshipCard', playerId: me, cardId: 'reOhm' }, 'ruleViolation');
    fails(next, { type: 'useFriendshipCard', playerId: me, cardId: 'reBah' }, 'ruleViolation');
  });

  it('Fame for Sale: needs the card, 1 goods, a fame piece in the tray, and the Trade & Build phase', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    setHand(state, me, ['goods']);
    fails(state, { type: 'useFriendshipCard', playerId: me, cardId: 'reBah' }, 'ruleViolation');
    player(state, me).friendshipCards = ['reBah'];
    const broke = structuredClone(state);
    setHand(broke, me, ['ore']);
    fails(broke, { type: 'useFriendshipCard', playerId: me, cardId: 'reBah' }, 'insufficientResources');
    const empty = structuredClone(state);
    empty.upgradesTray.famePieces = 0;
    fails(empty, { type: 'useFriendshipCard', playerId: me, cardId: 'reBah' }, 'supplyEmpty');
    const prod = structuredClone(state);
    prod.phase = 'production';
    fails(prod, { type: 'useFriendshipCard', playerId: me, cardId: 'reBah' }, 'wrongPhase');
    fails(state, { type: 'useFriendshipCard', playerId: opponents(state)[0]!.id, cardId: 'reBah' }, 'notYourTurn');
  });

  it('A Helping Hand: needs ≥2 opponents ahead; draws 1 random card from each of 2 chosen ones, once per turn', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    const [x, y] = opponents(state) as [ReturnType<typeof player>, ReturnType<typeof player>];
    player(state, me).friendshipCards = ['raHna'];
    setHand(state, me, []);
    setHand(state, x.id, ['ore', 'fuel', 'carbon']);
    setHand(state, y.id, ['goods']);

    // Nobody ahead yet (everyone on 4 VP).
    fails(state, { type: 'useFriendshipCard', playerId: me, cardId: 'raHna', targets: [x.id, y.id] }, 'ruleViolation');
    // Only one ahead.
    x.famePieces = 2;
    x.vp = 5;
    fails(state, { type: 'useFriendshipCard', playerId: me, cardId: 'raHna', targets: [x.id, y.id] }, 'ruleViolation');
    y.famePieces = 2;
    y.vp = 5;

    fails(state, { type: 'useFriendshipCard', playerId: me, cardId: 'raHna' }, 'invalidTarget');
    fails(state, { type: 'useFriendshipCard', playerId: me, cardId: 'raHna', targets: [x.id] }, 'invalidTarget');
    fails(state, { type: 'useFriendshipCard', playerId: me, cardId: 'raHna', targets: [x.id, x.id] }, 'invalidTarget');
    fails(state, { type: 'useFriendshipCard', playerId: me, cardId: 'raHna', targets: [x.id, me] }, 'invalidTarget');

    const total = cardsInPlay(state);
    const next = ok(state, { type: 'useFriendshipCard', playerId: me, cardId: 'raHna', targets: [x.id, y.id] });
    expect(player(next, me).hand).toHaveLength(2);
    expect(player(next, x.id).hand).toHaveLength(2);
    expect(player(next, y.id).hand).toEqual([]);
    expect(player(next, me).hand).toContain('goods');
    expect(cardsInPlay(next)).toBe(total);
    expect(next.turn.usedOncePerTurn).toContain('helpingHand');
    fails(next, { type: 'useFriendshipCard', playerId: me, cardId: 'raHna', targets: [x.id, y.id] }, 'ruleViolation');
  });

  it('A Helping Hand is deterministic for a given rng and skips empty hands', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    const [x, y] = opponents(state) as [ReturnType<typeof player>, ReturnType<typeof player>];
    player(state, me).friendshipCards = ['raHna'];
    setHand(state, me, []);
    setHand(state, x.id, ['ore', 'fuel', 'carbon', 'food', 'goods']);
    setHand(state, y.id, []);
    for (const p of [x, y]) {
      p.famePieces = 4;
      p.vp = 6;
    }
    const a = ok(state, { type: 'useFriendshipCard', playerId: me, cardId: 'raHna', targets: [x.id, y.id] });
    const b = ok(state, { type: 'useFriendshipCard', playerId: me, cardId: 'raHna', targets: [x.id, y.id] });
    expect(player(a, me).hand).toEqual(player(b, me).hand);
    expect(player(a, me).hand).toHaveLength(1);
    expect(player(a, x.id).hand).toHaveLength(4);
  });

  it('Galactic Relief Fund: an eligible holder takes 1 chosen card from the supply, once per turn', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    const other = opponents(state)[0]!.id;
    player(state, me).friendshipCards = ['raHno'];
    setHand(state, me, []);
    state.turn.rolled = 8;
    state.turn.productionReceived = { [me]: 0, [other]: 2 };
    const ore = state.supply.ore;

    const next = ok(state, { type: 'useFriendshipCard', playerId: me, cardId: 'raHno', want: 'ore' });
    expect(player(next, me).hand).toEqual(['ore']);
    expect(next.supply.ore).toBe(ore - 1);
    expect(next.turn.usedOncePerTurn).toContain('raHno');
    // Second claim in the same turn is rejected.
    fails(next, { type: 'useFriendshipCard', playerId: me, cardId: 'raHno', want: 'ore' }, 'ruleViolation');
    // Claimable during production too (right after the roll).
    const prod = structuredClone(state);
    prod.phase = 'production';
    expect(player(ok(prod, { type: 'useFriendshipCard', playerId: me, cardId: 'raHno', want: 'food' }), me).hand).toEqual(['food']);
  });

  it('Galactic Relief Fund: rejected for a player who produced, before any roll, on a 7, without the card, or with no `want`', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    player(state, me).friendshipCards = ['raHno'];
    setHand(state, me, []);
    state.turn.rolled = 8;
    state.turn.productionReceived = { [me]: 1 };
    fails(state, { type: 'useFriendshipCard', playerId: me, cardId: 'raHno', want: 'ore' }, 'ruleViolation');

    const unrolled = structuredClone(state);
    delete unrolled.turn.rolled;
    unrolled.turn.productionReceived = { [me]: 0 };
    fails(unrolled, { type: 'useFriendshipCard', playerId: me, cardId: 'raHno', want: 'ore' }, 'ruleViolation');

    const seven = structuredClone(state);
    seven.turn.rolled = 7;
    seven.turn.productionReceived = { [me]: 0 };
    fails(seven, { type: 'useFriendshipCard', playerId: me, cardId: 'raHno', want: 'ore' }, 'ruleViolation');

    const eligible = structuredClone(state);
    eligible.turn.productionReceived = { [me]: 0 };
    fails(eligible, { type: 'useFriendshipCard', playerId: me, cardId: 'raHno' }, 'invalidAction');
    const dry = structuredClone(eligible);
    dry.supply.ore = 0;
    fails(dry, { type: 'useFriendshipCard', playerId: me, cardId: 'raHno', want: 'ore' }, 'supplyEmpty');

    const noCard = structuredClone(eligible);
    player(noCard, me).friendshipCards = [];
    fails(noCard, { type: 'useFriendshipCard', playerId: me, cardId: 'raHno', want: 'ore' }, 'ruleViolation');
  });

  it('Galactic Relief Fund: a NON-active holder who produced nothing may claim it on another player\'s roll', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    const holder = opponents(state)[0]!.id;
    player(state, holder).friendshipCards = ['raHno', 'reBah', 'raHna'];
    setHand(state, holder, ['goods']);
    state.turn.rolled = 8;
    state.turn.productionReceived = { [me]: 2, [holder]: 0 };
    const goods = state.supply.goods;

    const next = ok(state, { type: 'useFriendshipCard', playerId: holder, cardId: 'raHno', want: 'goods' });
    expect(player(next, holder).hand).toEqual(['goods', 'goods']);
    expect(next.supply.goods).toBe(goods - 1);
    expect(next.activePlayer).toBe(me);
    expect(next.phase).toBe('tradeBuild');
    fails(next, { type: 'useFriendshipCard', playerId: holder, cardId: 'raHno', want: 'goods' }, 'ruleViolation');
    // The Trade & Build cards are still the active player's only.
    fails(next, { type: 'useFriendshipCard', playerId: holder, cardId: 'reBah' }, 'notYourTurn');
    fails(next, { type: 'useFriendshipCard', playerId: holder, cardId: 'raHna', targets: [me, opponents(state)[1]!.id] }, 'notYourTurn');
  });

  it('rejects passive cards and unknown cards', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    player(state, me).friendshipCards = ['raHal', 'axxa', 'khaStar'];
    setHand(state, me, ['goods']);
    fails(state, { type: 'useFriendshipCard', playerId: me, cardId: 'raHal' }, 'invalidAction');
    fails(state, { type: 'useFriendshipCard', playerId: me, cardId: 'axxa' }, 'invalidAction');
    fails(state, { type: 'useFriendshipCard', playerId: me, cardId: 'khaStar' }, 'invalidAction');
    fails(state, { type: 'useFriendshipCard', playerId: me, cardId: 'bogus' as never }, 'invalidAction');
    for (const cardId of ['__proto__', 'toString', 'constructor']) {
      fails(state, { type: 'useFriendshipCard', playerId: me, cardId: cardId as never }, 'invalidAction');
    }
  });
});
