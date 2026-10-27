/**
 * Advanced set-up draft (spec §3.4): the `setup` axis of `createGame`, the
 * snake order, `draftColony` / `draftFinish` validation, the closing of the
 * draft (cards, fame, blockers, turn 1), the 3-player pool and the
 * [VERIFY] config items, redaction and determinism.
 */

import { describe, expect, it } from 'vitest';
import { applyAction, ACTION_POLICY } from '../src/actions/index.js';
import { boardLayout } from '../src/board/data.js';
import { getSector, isOccupied, settlementsOf, shipsOf, spaceportSites, spaceportsOf } from '../src/board/query.js';
import {
  DRAFT_3P_BLOCK_FREE_SITES,
  DRAFT_3P_REMOVED_UPGRADE,
  DRAFT_COLONY_ROUNDS,
  DRAFT_UPGRADE_POOL,
  ENCOUNTER_CARD_COUNT,
  STARTING_HAND_SIZE,
  UPGRADE_TRAY_KEY,
} from '../src/config.js';
import { actionRevealsHiddenCards, redactState } from '../src/net/redact.js';
import { createRng } from '../src/rng.js';
import { createBeginnerGame } from '../src/setup/beginner.js';
import { makePlayer, makeReserveDiscs, rollForStart } from '../src/setup/common.js';
import { draftOrder, draftSpaceportCandidates, draftUpgradePool, draftableSites, finishDraft } from '../src/setup/draft.js';
import { SETUP_MODES, createGame, isSetupMode } from '../src/setup/index.js';
import { createVariableGame } from '../src/setup/variants.js';
import { buildReservePile } from '../src/supply.js';
import { RESOURCES, type Action, type GameState, type GameVariant, type NodeId, type PlayerId, type UpgradeKind } from '../src/types.js';
import { fails, ok } from './support/tradeBuild.js';

const FOUR = [
  { id: 'p1', name: 'Ann', color: 'red' as const },
  { id: 'p2', name: 'Bob', color: 'blue' as const },
  { id: 'p3', name: 'Cid', color: 'yellow' as const },
  { id: 'p4', name: 'Dee', color: 'white' as const },
];
const THREE = FOUR.slice(0, 3);

function draftGame(n: 3 | 4 = 4, seed = 'draft', variant: GameVariant = 'beginner'): GameState {
  return createGame({ variant, setup: 'draft', players: n === 4 ? FOUR : THREE, seed });
}

function cardsInPlay(state: GameState): number {
  return RESOURCES.reduce((s, r) => s + state.supply[r], 0) + state.reservePile.length + state.players.reduce((s, p) => s + p.hand.length, 0);
}

/** The greedy pick for whoever is up: first free site, first own colony, a colony ship (or trade for `tradeFor`), the first pool upgrade. */
function greedyPick(state: GameState, tradeFor: PlayerId[] = []): Action {
  const draft = state.draft!;
  const pid = state.activePlayer;
  if (draft.round <= DRAFT_COLONY_ROUNDS) return { type: 'draftColony', playerId: pid, siteId: draftableSites(state)[0] as NodeId };
  const spaceportSiteId = draftSpaceportCandidates(state, pid)[0] as NodeId;
  const shipSiteId = spaceportSites(state.board, spaceportSiteId).find((n) => !isOccupied(state.board, n)) as NodeId;
  return { type: 'draftFinish', playerId: pid, spaceportSiteId, ship: tradeFor.includes(pid) ? 'trade' : 'colony', shipSiteId, upgrade: draft.pool[0] as UpgradeKind };
}

/** Play the draft to the end (or for `picks` actions); returns every intermediate state (index 0 = start) and the actions. */
function playDraft(start: GameState, options: { picks?: number; tradeFor?: PlayerId[]; seed?: string } = {}) {
  const rng = createRng(options.seed ?? 'draft-play');
  const states = [start];
  const actions: Action[] = [];
  let state = start;
  const max = options.picks ?? Infinity;
  while (state.phase === 'setup' && actions.length < max) {
    const action = greedyPick(state, options.tradeFor ?? []);
    const r = applyAction(state, action, rng);
    if (!r.ok) throw new Error(`${action.type} by ${action.playerId} rejected: ${r.error.message}`);
    state = r.value;
    states.push(state);
    actions.push(action);
  }
  return { state, states, actions };
}

describe("createGame's setup axis", () => {
  it("defaults to 'preset' and then produces exactly today's states", () => {
    for (const variant of ['beginner', 'strategic', 'explorer', 'wild'] as const) {
      const viaCreate = createGame({ variant, players: THREE, seed: 'axis' });
      const direct = variant === 'beginner' ? createBeginnerGame({ players: THREE, seed: 'axis' }) : createVariableGame(variant, { players: THREE, seed: 'axis' });
      expect(viaCreate).toEqual(direct);
      expect(viaCreate).toEqual(createGame({ variant, setup: 'preset', players: THREE, seed: 'axis' }));
      expect(viaCreate.setup).toBe('preset');
      expect(viaCreate.phase).toBe('production');
      expect('draft' in viaCreate).toBe(false);
    }
    expect(SETUP_MODES).toEqual(['preset', 'draft']);
    expect(isSetupMode('draft')).toBe(true);
    expect(isSetupMode('snake')).toBe(false);
    expect(isSetupMode(undefined)).toBe(false);
  });

  it('is deterministic per seed and independent of the board variant', () => {
    expect(draftGame(4, 'same')).toEqual(draftGame(4, 'same'));
    expect(draftGame(4, 'same').draft).toBeDefined();
    for (const variant of ['strategic', 'explorer', 'wild'] as const) {
      const state = draftGame(3, `draft-${variant}`, variant);
      expect(state.setup).toBe('draft');
      expect(state.variant).toBe(variant);
      expect(state.phase).toBe('setup');
      expect(draftableSites(state)).toHaveLength(12);
      expect(Object.values(state.board.settlements)).toHaveLength(0);
      // The Catanian discs are on the board whatever the variant; the draft only concerns the pieces.
      for (const letter of ['alpha', 'beta', 'gamma', 'delta']) {
        for (const id of getSector(state.board, letter).planetIds) expect(state.board.planets[id]?.disc?.faceUp).toBe(true);
      }
    }
  });
});

describe('a drafted game starts in phase setup', () => {
  it('4 players: nothing placed, empty hands, the full pool, the opening roll decides who picks first', () => {
    const state = draftGame(4);
    expect(state.phase).toBe('setup');
    expect(state.setup).toBe('draft');
    expect(state.turnNumber).toBe(1);
    expect(state.blockerColor).toBeNull();
    expect(Object.values(state.board.settlements)).toHaveLength(0);
    expect(Object.values(state.board.ships)).toHaveLength(0);
    expect(draftableSites(state)).toHaveLength(12);
    for (const site of draftableSites(state)) expect(getSector(state.board, state.board.nodes[site]!.sectorId!).region).toBe('catanian');
    for (const p of state.players) {
      expect(p.hand).toEqual([]);
      expect(p.vp).toBe(0);
      expect(p.famePieces).toBe(0);
      expect(p.mothership).toEqual({ boosters: 1, cannons: 0, freightPods: 0 });
      expect(p.pieces).toEqual({ coloniesLeft: 9, stationsLeft: 7, transportsLeft: 3, shipyardsLeft: 3 });
    }
    expect(state.upgradesTray).toEqual({ boosters: 24 - 4, cannons: 24, freightPods: 20, famePieces: 40 });
    expect(state.reservePile).toHaveLength(40);
    expect(cardsInPlay(state)).toBe(100);
    const draft = state.draft!;
    expect(draft.round).toBe(1);
    expect(draft.index).toBe(0);
    expect(draft.order).toEqual(state.turnOrder);
    expect(draft.starter).toBe(state.turnOrder[0]);
    expect(state.activePlayer).toBe(draft.starter);
    expect(draft.pool).toEqual([...DRAFT_UPGRADE_POOL]);
    expect(Object.values(draft.colonies)).toEqual([[], [], [], []]);
    expect(state.log).toHaveLength(1);
    expect(state.log[0]!.message).toMatch(/set-up draft \(round 1 of 4\)/);
  });

  it('3 players: the 4th colour is reserved for blocking and one upgrade stays out of the pool', () => {
    const state = draftGame(3);
    expect(state.blockerColor).toBe('white');
    expect(Object.values(state.board.settlements)).toHaveLength(0);
    expect(state.draft!.pool).toEqual(draftUpgradePool(3));
    expect(state.draft!.pool).toHaveLength(3);
    expect(state.upgradesTray.boosters).toBe(24 - 3);
  });

  it('picks the starter with the same highest-2d6 rule as the preset set-up (rng order: deck, discs, pile, roll)', () => {
    const seed = 'who-starts';
    const state = draftGame(4, seed);
    const rng = createRng(seed);
    const layout = boardLayout();
    for (const icon of ['tri', 'br', 'hex'] as const) rng.shuffle(layout.numberDiscs[icon]); // beginner board: unexplored discs
    rng.shuffle(Array.from({ length: ENCOUNTER_CARD_COUNT }, (_, i) => i + 1));
    makeReserveDiscs(layout, rng);
    const supply = { ore: 20, fuel: 20, carbon: 20, food: 20, goods: 20 };
    const pile = buildReservePile({ supply } as unknown as GameState, rng);
    expect(state.reservePile).toEqual(pile);
    expect(state.draft!.starter).toBe(rollForStart(FOUR.map(makePlayer), rng));
    // Different seeds do not all agree on the starter.
    const starters = new Set(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'].map((s) => draftGame(4, s).activePlayer));
    expect(starters.size).toBeGreaterThan(1);
  });
});

describe('rounds 1–3: draftColony in snake order', () => {
  it('goes clockwise, counter-clockwise, clockwise, then round 4 counter-clockwise from the last placer of round 3', () => {
    const start = draftGame(4);
    const T = start.turnOrder;
    const R = [...T].reverse();
    const { states, state } = playDraft(start);
    const pickers = states.slice(0, -1).map((s) => s.activePlayer);
    expect(pickers).toEqual([...T, ...R, ...T, ...R]);
    expect(draftOrder(1, T)).toEqual(T);
    expect(draftOrder(2, T)).toEqual(R);
    expect(draftOrder(3, T)).toEqual(T);
    expect(draftOrder(4, T)).toEqual(R);
    expect(R[0]).toBe(T[T.length - 1]);
    const rounds = states.slice(0, -1).map((s) => s.draft!.round);
    expect(rounds).toEqual([1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4]);
    expect(state.phase).toBe('production');
    // After round 3 everybody holds 3 drafted colonies and 6 colony pieces.
    const afterR3 = states[12]!;
    for (const p of afterR3.players) {
      expect(afterR3.draft!.colonies[p.id]).toHaveLength(3);
      expect(settlementsOf(afterR3, p.id)).toHaveLength(3);
      expect(p.pieces.coloniesLeft).toBe(6);
      expect(p.vp).toBe(3);
    }
    expect(draftableSites(afterR3)).toEqual([]);
  });

  it('accepts only a free Catanian colony site from the current picker', () => {
    const state = draftGame(4);
    const me = state.activePlayer;
    const other = state.turnOrder[1] as PlayerId;
    const sites = draftableSites(state);
    fails(state, { type: 'draftColony', playerId: other, siteId: sites[0]! }, 'notYourTurn');
    fails(state, { type: 'draftColony', playerId: me, siteId: 'N(99,99)' }, 'invalidSite');
    fails(state, { type: 'draftColony', playerId: me, siteId: 'S(4,4)' }, 'invalidSite'); // a colony site of system N4, not Catanian
    fails(state, { type: 'draftColony', playerId: me, siteId: 'N(5,1)' }, 'invalidSite'); // plain intersection
    fails(state, { type: 'draftColony', playerId: me, siteId: undefined as unknown as string }, 'invalidSite');
    const pool = state.draft!.pool[0]!;
    fails(state, { type: 'draftFinish', playerId: me, spaceportSiteId: sites[0]!, ship: 'colony', shipSiteId: 'N(5,1)', upgrade: pool }, 'ruleViolation');
    // Nothing else is allowed during the draft.
    fails(state, { type: 'rollDice', playerId: me }, 'wrongPhase');
    fails(state, { type: 'build', playerId: me, item: 'booster' }, 'wrongPhase');
    fails(state, { type: 'endTurn', playerId: me }, 'wrongPhase');
    fails(state, { type: 'shakeMothership', playerId: me }, 'wrongPhase');
    // And the draft actions are not allowed outside it.
    const preset = createBeginnerGame({ players: FOUR, seed: 'preset' });
    fails(preset, { type: 'draftColony', playerId: preset.activePlayer, siteId: sites[0]! }, 'wrongPhase');

    const after = ok(state, { type: 'draftColony', playerId: me, siteId: sites[0]! });
    expect(after.board.settlements[sites[0]!]).toEqual({ nodeId: sites[0], kind: 'colony', color: state.players.find((p) => p.id === me)!.color, owner: me });
    expect(after.activePlayer).toBe(other);
    expect(after.draft!.index).toBe(1);
    expect(after.draft!.colonies[me]).toEqual([sites[0]]);
    expect(after.players.find((p) => p.id === me)!.pieces.coloniesLeft).toBe(8);
    expect(after.players.find((p) => p.id === me)!.vp).toBe(1);
    expect(draftableSites(after)).toHaveLength(11);
    expect(after.log.at(-1)).toMatchObject({ kind: 'action', playerId: me, action: { type: 'draftColony' } });
    // The same site is now taken.
    fails(after, { type: 'draftColony', playerId: other, siteId: sites[0]! }, 'invalidSite');
    // Round 4 refuses draftColony.
    const { state: r4 } = playDraft(state, { picks: 12 });
    expect(r4.draft!.round).toBe(4);
    fails(r4, { type: 'draftColony', playerId: r4.activePlayer, siteId: 'N(5,1)' }, 'ruleViolation');
  });
});

describe('round 4: draftFinish (spaceport + ship + bonus upgrade as one action)', () => {
  function roundFour(n: 3 | 4 = 4): GameState {
    return playDraft(draftGame(n, 'round-four'), { picks: n * 3 }).state;
  }

  it('validates the three choices together', () => {
    const state = roundFour();
    const me = state.activePlayer;
    const mine = draftSpaceportCandidates(state, me);
    expect(mine).toHaveLength(3);
    const theirs = draftSpaceportCandidates(state, state.turnOrder[0] as PlayerId)[0]!;
    const sp = mine[0]!;
    const sites = spaceportSites(state.board, sp);
    const site = sites[0]!;
    const pool = state.draft!.pool;
    const base = { type: 'draftFinish' as const, playerId: me, spaceportSiteId: sp, ship: 'colony' as const, shipSiteId: site, upgrade: pool[0]! };
    fails(state, { ...base, spaceportSiteId: theirs }, 'invalidSite');
    fails(state, { ...base, spaceportSiteId: 'N(5,1)' }, 'invalidSite');
    fails(state, { ...base, shipSiteId: 'N(5,1)' }, 'invalidSite');
    fails(state, { ...base, shipSiteId: sp }, 'invalidSite');
    fails(state, { ...base, ship: 'battle' as 'colony' }, 'invalidAction');
    fails(state, { ...base, upgrade: 'laser' as UpgradeKind }, 'invalidAction');
    fails(state, { ...base, playerId: state.turnOrder[0] as PlayerId }, 'notYourTurn');
    // An occupied spaceport site.
    const busy = structuredClone(state);
    busy.board.ships['ship:x'] = { id: 'ship:x', owner: state.turnOrder[0] as PlayerId, kind: 'colony', nodeId: site, mustFoundOrLeave: false };
    fails(busy, base, 'invalidSite');
    // Tray empty / cap reached for the chosen upgrade.
    const empty = structuredClone(state);
    empty.upgradesTray[UPGRADE_TRAY_KEY[pool[0]!]] = 0;
    fails(empty, base, 'supplyEmpty');
    const capped = structuredClone(state);
    capped.players.find((p) => p.id === me)!.mothership[UPGRADE_TRAY_KEY[pool[0]!]] = 6;
    fails(capped, base, 'upgradeCap');
    // Piece limits.
    const noYard = structuredClone(state);
    noYard.players.find((p) => p.id === me)!.pieces.shipyardsLeft = 0;
    fails(noYard, base, 'pieceLimit');
    const noShip = structuredClone(state);
    noShip.players.find((p) => p.id === me)!.pieces.transportsLeft = 0;
    fails(noShip, base, 'pieceLimit');

    const after = ok(state, base);
    const p = after.players.find((x) => x.id === me)!;
    expect(after.board.settlements[sp]).toMatchObject({ kind: 'spaceport', owner: me });
    expect(spaceportsOf(after, me).map((s) => s.nodeId)).toEqual([sp]);
    const ship = shipsOf(after, me)[0]!;
    expect(ship).toMatchObject({ kind: 'colony', nodeId: site, owner: me, mustFoundOrLeave: false });
    expect(ship.id).toBe(`ship:${p.color}:1`);
    expect(p.pieces).toEqual({ coloniesLeft: 5, stationsLeft: 7, transportsLeft: 2, shipyardsLeft: 2 });
    expect(p.mothership[UPGRADE_TRAY_KEY[pool[0]!]]).toBe(state.players.find((x) => x.id === me)!.mothership[UPGRADE_TRAY_KEY[pool[0]!]] + 1);
    expect(after.upgradesTray[UPGRADE_TRAY_KEY[pool[0]!]]).toBe(state.upgradesTray[UPGRADE_TRAY_KEY[pool[0]!]] - 1);
    expect(after.draft!.pool).toEqual(pool.slice(1));
    expect(p.vp).toBe(4);
    expect(after.activePlayer).toBe(state.draft!.order[1]);
    // The next picker cannot take an upgrade that is gone from the pool.
    const next = after.activePlayer;
    const gone = pool.find((u) => !after.draft!.pool.includes(u));
    if (gone) {
      const sp2 = draftSpaceportCandidates(after, next)[0]!;
      const site2 = spaceportSites(after.board, sp2).find((n) => !isOccupied(after.board, n))!;
      fails(after, { type: 'draftFinish', playerId: next, spaceportSiteId: sp2, ship: 'colony', shipSiteId: site2, upgrade: gone }, 'ruleViolation');
    }
  });

  it('a trade ship may be chosen instead of a colony ship', () => {
    const state = roundFour();
    const me = state.activePlayer;
    const sp = draftSpaceportCandidates(state, me)[1]!;
    const site = spaceportSites(state.board, sp)[1]!;
    const after = ok(state, { type: 'draftFinish', playerId: me, spaceportSiteId: sp, ship: 'trade', shipSiteId: site, upgrade: 'freightPod' });
    const p = after.players.find((x) => x.id === me)!;
    expect(shipsOf(after, me)[0]).toMatchObject({ kind: 'trade', nodeId: site });
    expect(p.pieces).toEqual({ coloniesLeft: 6, stationsLeft: 6, transportsLeft: 2, shipyardsLeft: 2 });
    expect(p.mothership.freightPods).toBe(1);
    expect(after.draft!.pool).toEqual(['booster', 'booster', 'cannon']);
  });
});

describe('the last pick closes the draft', () => {
  it('4 players: 3 reserve cards and a fame piece each in seating order, VP from the pieces, turn 1 for the starter', () => {
    const start = draftGame(4, 'close');
    const { state, states, actions } = playDraft(start);
    const before = states.at(-2)!;
    expect(actions).toHaveLength(16);
    expect(state.phase).toBe('production');
    expect(state.draft).toBeUndefined();
    expect(state.activePlayer).toBe(start.draft!.starter);
    expect(state.turnOrder).toEqual(start.turnOrder);
    expect(state.turnNumber).toBe(1);
    expect(state.turn).toEqual({ reserveDrawTaken: false, shipMovesUsed: {}, immobilized: [], usedOncePerTurn: [] });
    expect(state.openTrade).toBeNull();
    expect(state.winner).toBeNull();
    const taken: UpgradeKind[] = [];
    state.players.forEach((p, i) => {
      expect(p.hand).toEqual(before.reservePile.slice(i * STARTING_HAND_SIZE, (i + 1) * STARTING_HAND_SIZE));
      expect(p.famePieces).toBe(1);
      expect(p.vp).toBe(4);
      const mine = settlementsOf(state, p.id);
      expect(mine.filter((s) => s.kind === 'colony')).toHaveLength(2);
      expect(mine.filter((s) => s.kind === 'spaceport')).toHaveLength(1);
      expect(shipsOf(state, p.id)).toHaveLength(1);
      expect(p.pieces).toEqual({ coloniesLeft: 5, stationsLeft: 7, transportsLeft: 2, shipyardsLeft: 2 });
      const extra = (['booster', 'cannon', 'freightPod'] as const).filter((k) => p.mothership[UPGRADE_TRAY_KEY[k]] > (k === 'booster' ? 1 : 0));
      expect(extra).toHaveLength(1);
      taken.push(extra[0]!);
    });
    expect([...taken].sort()).toEqual([...DRAFT_UPGRADE_POOL].sort());
    expect(state.upgradesTray).toEqual({ boosters: 24 - 4 - 2, cannons: 23, freightPods: 19, famePieces: 36 });
    expect(state.reservePile).toHaveLength(40 - 12);
    expect(cardsInPlay(state)).toBe(100);
    expect(Object.values(state.board.settlements)).toHaveLength(12);
    expect(Object.values(state.board.settlements).every((s) => s.owner !== null)).toBe(true);
    expect(draftableSites(state)).toEqual([]);
    expect(state.log.at(-2)!.message).toMatch(/Set-up draft complete/);
    // Turn 1 proceeds as usual.
    const rolled = ok(state, { type: 'rollDice', playerId: state.activePlayer }, createRng('roll'));
    expect(rolled.turn.rolled).toBeGreaterThanOrEqual(2);
    // The whole sequence is deterministic: replaying the actions reproduces every state.
    const twin = playDraft(draftGame(4, 'close'));
    expect(twin.state).toEqual(state);
    expect(twin.states).toEqual(states);
  });

  it('3 players: the three free Catanian sites are filled by the unused colour (DRAFT_3P_BLOCK_FREE_SITES) — both values', () => {
    expect(DRAFT_3P_BLOCK_FREE_SITES).toBe(true);
    const start = draftGame(3, 'close-3p');
    const { state, states } = playDraft(start, { tradeFor: [start.turnOrder[1] as PlayerId] });
    const before = states.at(-2)!;
    const free = draftableSites(before);
    expect(free).toHaveLength(3);
    expect(state.phase).toBe('production');
    const blockers = Object.values(state.board.settlements).filter((s) => s.owner === null);
    expect(blockers.map((b) => b.nodeId).sort()).toEqual(free);
    expect(blockers.every((b) => b.kind === 'colony' && b.color === 'white')).toBe(true);
    expect(Object.values(state.board.settlements)).toHaveLength(12);
    expect(draftableSites(state)).toEqual([]);
    expect(state.players.every((p) => p.hand.length === 3 && p.famePieces === 1 && p.vp === 4)).toBe(true);
    expect(shipsOf(state, start.turnOrder[1] as PlayerId)[0]!.kind).toBe('trade');
    // The pool of three was used up and the upgrade that stayed out is still in the tray.
    expect(state.upgradesTray).toEqual({ boosters: 24 - 3 - 1, cannons: 23, freightPods: 19, famePieces: 37 });
    expect(cardsInPlay(state)).toBe(100);

    // With the flag off the sites stay open; with it on, finishDraft places exactly those blockers.
    const open = structuredClone(before);
    finishDraft(open, createRng('x'), false);
    expect(open.phase).toBe('production');
    expect(Object.values(open.board.settlements).filter((s) => s.owner === null)).toHaveLength(0);
    expect(draftableSites(open)).toEqual(free);
    const closed = structuredClone(before);
    finishDraft(closed, createRng('x'), true);
    expect(Object.values(closed.board.settlements).filter((s) => s.owner === null).map((s) => s.nodeId).sort()).toEqual(free);
    // In a 4-player draft nothing is left to block.
    const four = structuredClone(playDraft(draftGame(4, 'close'), { picks: 15 }).state);
    finishDraft(four, createRng('x'), true);
    expect(Object.values(four.board.settlements).some((s) => s.owner === null)).toBe(false);
  });

  it('DRAFT_3P_REMOVED_UPGRADE: which upgrade stays out of a 3-player pool (default: one booster)', () => {
    expect(DRAFT_3P_REMOVED_UPGRADE).toBe('booster');
    expect(DRAFT_UPGRADE_POOL).toEqual(['booster', 'booster', 'cannon', 'freightPod']);
    expect(draftUpgradePool(4)).toEqual(['booster', 'booster', 'cannon', 'freightPod']);
    expect(draftUpgradePool(3)).toEqual(['booster', 'cannon', 'freightPod']);
    expect(draftUpgradePool(3, 'cannon')).toEqual(['booster', 'booster', 'freightPod']);
    expect(draftUpgradePool(3, 'freightPod')).toEqual(['booster', 'booster', 'cannon']);
    const random = draftUpgradePool(3, 'random', createRng('pool'));
    expect(random).toHaveLength(3);
    expect(random.every((u) => DRAFT_UPGRADE_POOL.includes(u))).toBe(true);
    expect(() => draftUpgradePool(2, 'cannon')).toThrow(/holds no cannon/);
    expect(draftGame(3).draft!.pool).toEqual(draftUpgradePool(3));
  });
});

describe('draft state is public and the actions are gated by the policy table', () => {
  it('redactState keeps setup and draft; the legal sites agree on the redacted view', () => {
    const state = playDraft(draftGame(3, 'redact'), { picks: 5 }).state;
    const view = redactState(state, 'p2');
    expect(view.setup).toBe('draft');
    expect(view.draft).toEqual(state.draft);
    expect(draftableSites(view)).toEqual(draftableSites(state));
    expect(view.players.every((p) => p.hand.length === 0 && p.handCount === 0)).toBe(true);
    for (const type of ['draftColony', 'draftFinish'] as const) {
      expect(ACTION_POLICY[type]).toEqual({ phases: ['setup'], activePlayerOnly: true });
    }
    expect(actionRevealsHiddenCards({ type: 'draftColony', playerId: 'p1', siteId: 'x' })).toBe(false);
    expect(actionRevealsHiddenCards({ type: 'draftFinish', playerId: 'p1', spaceportSiteId: 'x', ship: 'colony', shipSiteId: 'y', upgrade: 'booster' })).toBe(false);
  });
});
