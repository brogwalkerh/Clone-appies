/**
 * Table-driven test per encounter-card branch (CLAUDE.md: "Encounter cards are
 * data (§10) with a table-driven test per branch"). The expectation table below
 * is derived from the spec table in starfarers-clone-spec.md §10 (plus §1 ball
 * values, §9.7 space jump, §11) — NOT from `cards.ts` — so that a wrong card
 * datum or a wrong mechanic shows up as a failing branch.
 *
 * Fixture (test/support/tradeBuild.ts): p1 Ann (red, active), p2 Bob (blue),
 * p3 Cid (yellow); turn order p1 p2 p3, so from p1: L = p2, R = p3, LL = p3,
 * RR = p2. p1 starts with 1 booster, 0 cannons, 0 freight pods, 1 fame piece
 * and its colony ship `ship:red:1` on N(5,1); N(5,3) is a legal jump target.
 *
 * Every case drives the card to completion through `applyAction` (phase and
 * policy gating included) and then asserts the EXACT outcome: p1's hand, fame
 * and upgrades, immobilized ship, free trade ship, jump, every opponent's hand
 * (unchanged unless the card says otherwise), per-resource supply conservation,
 * the upgrade / fame trays, and the hand-back to `flight.move` at base speed 3.
 */

import { describe, expect, it } from 'vitest';
import { shipsOf } from '../src/board/query.js';
import {
  ENCOUNTER_SHAKE_BANDS,
  MOTHERSHIP_BALLS,
  TRAVELERS_DONATION_BRANCHES,
  WEAR_AND_TEAR_THRESHOLDS,
  type Ball,
} from '../src/config.js';
import { encounterCard } from '../src/encounters/cards.js';
import { beginEncounter } from '../src/encounters/engine.js';
import type { ContestKind, EncounterPickKind } from '../src/encounters/schema.js';
import { refreshSpeed, speedOf } from '../src/flight/stats.js';
import { createRng, type Rng } from '../src/rng.js';
import type { GameState, Mothership, NodeId, PlayerId, Resource, UpgradeKind } from '../src/types.js';
import { RESOURCES } from '../src/types.js';
import { cardsInPlay, fails, ok, player, setHand, tradeBuildState } from './support/tradeBuild.js';

const P1 = 'p1' as const;
const P2 = 'p2' as const;
const P3 = 'p3' as const;
const SHIP = 'ship:red:1';
const HOME: NodeId = 'N(5,1)';
const JUMP_TARGET: NodeId = 'N(5,3)';

/** p1's hand in every case (the offer takes the first N of these). */
const H1: Resource[] = ['ore', 'fuel', 'carbon'];
const H2: Resource[] = ['goods', 'goods'];
const H3: Resource[] = ['food'];

/** Scripted shakes: the active player shakes first, then the opponent (§10 "Combat"). */
const WIN: Ball[][] = [['red', 'yellow'], ['blue', 'black']]; // 5 vs 1
const LOSE: Ball[][] = [['blue', 'black'], ['red', 'yellow']]; // 1 vs 5

/**
 * Rng whose shuffles of the 5 mothership balls return the scripted pairs first,
 * in order, and whose shuffles of a number list (the encounter deck) return it
 * sorted ascending, so reshuffle-and-redraw is deterministic. Everything else
 * is seeded.
 */
type ScriptedRng = Rng & { remaining: () => number };

function scriptedRng(pairs: Ball[][], seed = 'enc-table'): ScriptedRng {
  const base = createRng(seed);
  const script = pairs.map((p) => [...p]);
  return {
    remaining: () => script.length,
    next: () => base.next(),
    int: (n) => base.int(n),
    pick: (a) => base.pick(a),
    d6: () => base.d6(),
    getState: () => base.getState(),
    shuffle: <T,>(arr: readonly T[]): T[] => {
      const isBalls = arr.length === MOTHERSHIP_BALLS.length && arr.every((b) => MOTHERSHIP_BALLS.includes(b as Ball));
      if (isBalls) {
        const first = script.shift();
        if (!first) throw new Error('scriptedRng: an unscripted shake happened');
        const rest = [...arr];
        for (const b of first) rest.splice(rest.indexOf(b as T), 1);
        return [...(first as unknown as T[]), ...rest];
      }
      if (arr.every((x) => typeof x === 'number')) return [...arr].sort((a, b) => (a as number) - (b as number));
      return base.shuffle(arr);
    },
  };
}

// ---------------------------------------------------------------------------
// Case table types
// ---------------------------------------------------------------------------

interface Pick {
  player: PlayerId;
  kind: EncounterPickKind;
  resources?: Resource[];
  upgrade?: UpgradeKind;
  shipId?: string;
  targetNodeId?: NodeId;
  decline?: true;
}

interface Expectation {
  /** p1's final hand (order-insensitive). */
  hand: Resource[];
  /** p1's final fame pieces. */
  fame: number;
  /** p1's final mothership (default: unchanged 1 booster / 0 cannons / 0 pods). */
  mothership?: Mothership;
  /** ship:red:1 is in `turn.immobilized`. */
  immobilized?: true;
  /** A free trade ship was placed now, or a marker is held. */
  tradeShip?: 'placed' | 'pending';
  /** Where ship:red:1 ends (default: where it started). */
  shipAt?: NodeId;
  /** Opponent hands that the card changes (default: every opponent unchanged). */
  opponents?: Partial<Record<PlayerId, Resource[]>>;
  contest?: { opponent: PlayerId; kind: ContestKind; won: boolean };
  flee?: { opponent: PlayerId; escaped: boolean };
  band?: 'low' | 'mid' | 'high';
}

interface Case {
  card: number;
  branch: string;
  setup?: (state: GameState) => void;
  /** Offer of 0–3 cards (offer0to3 cards, and the first step of 7/8). */
  offer?: number;
  /** Yes / no (yesno cards, and the second step of 7/8). */
  answer?: boolean;
  shakes?: Ball[][];
  picks?: Pick[];
  expect: Expectation;
}

// Pick shorthands
const take = (...resources: Resource[]): Pick => ({ player: P1, kind: 'resources', resources });
const pay = (...resources: Resource[]): Pick => ({ player: P1, kind: 'payResources', resources });
const give = (p: PlayerId, r: Resource): Pick => ({ player: p, kind: 'giveOne', resources: [r] });
const fit = (upgrade: UpgradeKind): Pick => ({ player: P1, kind: 'upgradeKind', upgrade });
const drop = (upgrade: UpgradeKind): Pick => ({ player: P1, kind: 'removeUpgrade', upgrade });
const pin = (): Pick => ({ player: P1, kind: 'immobilizeShip', shipId: SHIP });
const jump = (): Pick => ({ player: P1, kind: 'spaceJump', shipId: SHIP, targetNodeId: JUMP_TARGET });
const declineJump = (): Pick => ({ player: P1, kind: 'spaceJump', decline: true });

// Setup shorthands
const fameOf = (n: number) => (s: GameState) => { player(s, P1).famePieces = n; };
const boosters = (p: PlayerId, n: number) => (s: GameState) => { player(s, p).mothership.boosters = n; };
const cannons = (p: PlayerId, n: number) => (s: GameState) => { player(s, p).mothership.cannons = n; };
const scientist = (p: PlayerId, id: 'khaStar' | 'hirAkas') => (s: GameState) => { player(s, p).friendshipCards = [id]; };
const all = (...fns: Array<(s: GameState) => void>) => (s: GameState) => { for (const f of fns) f(s); };

const NO_BOOSTER: Mothership = { boosters: 0, cannons: 0, freightPods: 0 };
const PLUS_CANNON: Mothership = { boosters: 1, cannons: 1, freightPods: 0 };

const combat = (opponent: PlayerId, won: boolean) => ({ opponent, kind: 'combat' as const, won });
const race = (opponent: PlayerId, won: boolean) => ({ opponent, kind: 'speed' as const, won });

// ---------------------------------------------------------------------------
// The expectation table (spec §10). Hands: p1 = ore fuel carbon, p2 = goods goods, p3 = food.
// ---------------------------------------------------------------------------

const CASES: Case[] = [
  // ---- 1: Merchant. 0: everyone gives you 1 of their choice, lose 2 fame. 1: +1 food, −1 fame. 2: +1 any, +1 fame. 3: +2 any, +1 fame.
  { card: 1, branch: 'offer 0 — everyone gives 1 of their choice, lose 2 fame (floor at 0)', offer: 0, picks: [give(P2, 'goods'), give(P3, 'food')],
    expect: { hand: [...H1, 'goods', 'food'], fame: 0, opponents: { p2: ['goods'], p3: [] } } },
  { card: 1, branch: 'offer 0 — lose 2 fame from 3', offer: 0, setup: fameOf(3), picks: [give(P2, 'goods'), give(P3, 'food')],
    expect: { hand: [...H1, 'goods', 'food'], fame: 1, opponents: { p2: ['goods'], p3: [] } } },
  { card: 1, branch: 'offer 0 — an opponent with no cards gives nothing', offer: 0, setup: (s) => setHand(s, P3, []), picks: [give(P2, 'goods')],
    expect: { hand: [...H1, 'goods'], fame: 0, opponents: { p2: ['goods'], p3: [] } } },
  { card: 1, branch: 'offer 1 — +1 food, lose 1 fame', offer: 1, expect: { hand: ['fuel', 'carbon', 'food'], fame: 0 } },
  { card: 1, branch: 'offer 2 — +1 any, +1 fame', offer: 2, picks: [take('goods')], expect: { hand: ['carbon', 'goods'], fame: 2 } },
  { card: 1, branch: 'offer 3 — +2 any, +1 fame', offer: 3, picks: [take('goods', 'food')], expect: { hand: ['goods', 'food'], fame: 2 } },

  // ---- 2: Merchant. 0: −1 fame. 1: +1 any. 2: +1 any, +1 fame. 3: +1 any upgrade, +1 fame.
  { card: 2, branch: 'offer 0 — lose 1 fame', offer: 0, expect: { hand: H1, fame: 0 } },
  { card: 2, branch: 'offer 1 — +1 any', offer: 1, picks: [take('goods')], expect: { hand: ['fuel', 'carbon', 'goods'], fame: 1 } },
  { card: 2, branch: 'offer 2 — +1 any, +1 fame', offer: 2, picks: [take('food')], expect: { hand: ['carbon', 'food'], fame: 2 } },
  { card: 2, branch: 'offer 3 — +1 upgrade of choice, +1 fame', offer: 3, picks: [fit('cannon')], expect: { hand: [], fame: 2, mothership: PLUS_CANNON } },

  // ---- 3: Merchant. 0: −1 fame. 1: nothing. 2: +1 fame. 3: +1 goods, +1 fame.
  { card: 3, branch: 'offer 0 — lose 1 fame', offer: 0, expect: { hand: H1, fame: 0 } },
  { card: 3, branch: 'offer 1 — nothing', offer: 1, expect: { hand: ['fuel', 'carbon'], fame: 1 } },
  { card: 3, branch: 'offer 2 — +1 fame', offer: 2, expect: { hand: ['carbon'], fame: 2 } },
  { card: 3, branch: 'offer 3 — +1 goods, +1 fame', offer: 3, expect: { hand: ['goods'], fame: 2 } },

  // ---- 4: Merchant. 0: gift returned (nothing). 1: +1 goods. 2: +1 any, +1 fame. 3: +2 any, +1 fame.
  { card: 4, branch: 'offer 0 — nothing', offer: 0, expect: { hand: H1, fame: 1 } },
  { card: 4, branch: 'offer 1 — +1 goods', offer: 1, expect: { hand: ['fuel', 'carbon', 'goods'], fame: 1 } },
  { card: 4, branch: 'offer 2 — +1 any, +1 fame', offer: 2, picks: [take('goods')], expect: { hand: ['carbon', 'goods'], fame: 2 } },
  { card: 4, branch: 'offer 3 — +2 any, +1 fame', offer: 3, picks: [take('ore', 'ore')], expect: { hand: ['ore', 'ore'], fame: 2 } },

  // ---- 5 / 6: Merchant prince. 0: one ship cannot move, −1 fame. 1: −1 fame. 2: +1 any, +1 fame. 3: free trade ship.
  ...([5, 6] as const).flatMap((card): Case[] => [
    { card, branch: 'offer 0 — one ship cannot move, lose 1 fame', offer: 0, picks: [pin()], expect: { hand: H1, fame: 0, immobilized: true } },
    { card, branch: 'offer 0 — fame floor at 0', offer: 0, setup: fameOf(0), picks: [pin()], expect: { hand: H1, fame: 0, immobilized: true } },
    { card, branch: 'offer 1 — lose 1 fame', offer: 1, expect: { hand: ['fuel', 'carbon'], fame: 0 } },
    { card, branch: 'offer 2 — +1 any, +1 fame', offer: 2, picks: [take('food')], expect: { hand: ['carbon', 'food'], fame: 2 } },
    { card, branch: 'offer 3 — free trade ship placed now', offer: 3, expect: { hand: [], fame: 1, tradeShip: 'placed' } },
    { card, branch: 'offer 3 — free trade ship held as a marker when no transport is free', offer: 3,
      setup: (s) => { player(s, P1).pieces.transportsLeft = 0; }, expect: { hand: [], fame: 1, tradeShip: 'pending' } },
  ]),

  // ---- 7 / 8: pirate in disguise after the offer. No: gift lost. Yes: fight R (7) / L (8). Win: gift back, +1 fame. Lose: gift lost, one ship cannot move.
  ...([[7, P3], [8, P2]] as const).flatMap(([card, foe]): Case[] => [
    { card, branch: 'offer 2, no — the gift is lost', offer: 2, answer: false, expect: { hand: ['carbon'], fame: 1 } },
    { card, branch: 'offer 2, yes, win — gift back, +1 fame', offer: 2, answer: true, shakes: WIN,
      expect: { hand: H1, fame: 2, contest: combat(foe, true) } },
    { card, branch: 'offer 2, yes, lose — gift lost, one ship cannot move', offer: 2, answer: true, shakes: LOSE, picks: [pin()],
      expect: { hand: ['carbon'], fame: 1, immobilized: true, contest: combat(foe, false) } },
    { card, branch: 'offer 3, yes, win — the whole gift comes back', offer: 3, answer: true, shakes: WIN,
      expect: { hand: H1, fame: 2, contest: combat(foe, true) } },
    { card, branch: 'offer 0, no — nothing to lose', offer: 0, answer: false, expect: { hand: H1, fame: 1 } },
    { card, branch: 'offer 0, yes, lose — nothing to lose but a ship is pinned', offer: 0, answer: true, shakes: LOSE, picks: [pin()],
      expect: { hand: H1, fame: 1, immobilized: true, contest: combat(foe, false) } },
  ]),

  // ---- 9: Surrender? Yes: pay 2. No: fight R. Win: free trade ship. Lose: remove 1 upgrade, +1 fame.
  { card: 9, branch: 'yes — pay 2', answer: true, picks: [pay('ore', 'fuel')], expect: { hand: ['carbon'], fame: 1 } },
  { card: 9, branch: 'no, win — free trade ship', answer: false, shakes: WIN, expect: { hand: H1, fame: 1, tradeShip: 'placed', contest: combat(P3, true) } },
  { card: 9, branch: 'no, lose — remove 1 upgrade, +1 fame', answer: false, shakes: LOSE, picks: [drop('booster')],
    expect: { hand: H1, fame: 2, mothership: NO_BOOSTER, contest: combat(P3, false) } },

  // ---- 10: Yes: pay 2, −1 fame. No: fight RR. Win: +2 carbon, +1 fame. Lose: one ship cannot move, +1 fame.
  { card: 10, branch: 'yes — pay 2, lose 1 fame', answer: true, picks: [pay('ore', 'carbon')], expect: { hand: ['fuel'], fame: 0 } },
  { card: 10, branch: 'yes — fame floor at 0', answer: true, setup: fameOf(0), picks: [pay('ore', 'carbon')], expect: { hand: ['fuel'], fame: 0 } },
  { card: 10, branch: 'no, win — +2 carbon, +1 fame', answer: false, shakes: WIN,
    expect: { hand: [...H1, 'carbon', 'carbon'], fame: 2, contest: combat(P2, true) } },
  { card: 10, branch: 'no, lose — one ship cannot move, +1 fame', answer: false, shakes: LOSE, picks: [pin()],
    expect: { hand: H1, fame: 2, immobilized: true, contest: combat(P2, false) } },

  // ---- 11: Yes: pay 2 AND one ship cannot move. No: fight L. Win: +2 ore, +1 fame. Lose: remove 1 upgrade.
  { card: 11, branch: 'yes — pay 2 AND one ship cannot move', answer: true, picks: [pay('fuel', 'carbon'), pin()],
    expect: { hand: ['ore'], fame: 1, immobilized: true } },
  { card: 11, branch: 'no, win — +2 ore, +1 fame', answer: false, shakes: WIN,
    expect: { hand: [...H1, 'ore', 'ore'], fame: 2, contest: combat(P2, true) } },
  { card: 11, branch: 'no, lose — remove 1 upgrade', answer: false, shakes: LOSE, picks: [drop('booster')],
    expect: { hand: H1, fame: 1, mothership: NO_BOOSTER, contest: combat(P2, false) } },
  { card: 11, branch: 'no, tie with Scientist cannon bonus — the active player wins', answer: false,
    setup: all(scientist(P1, 'khaStar'), cannons(P2, 1)), shakes: [['blue', 'black'], ['yellow', 'black']], // 1+2 = 3 ≥ 2+1 = 3
    expect: { hand: [...H1, 'ore', 'ore'], fame: 2, contest: combat(P2, true) } },

  // ---- 12 / 13: 1-for-2 trade. No: +1 fame (12) / nothing (13). Yes: trade 1→2, then shake: low (1–2) confiscate the 2 + −1 fame; mid (3) −1 fame; high (4–5) safe.
  ...([[12, 2], [13, 1]] as const).flatMap(([card, fameAfterNo]): Case[] => [
    { card, branch: card === 12 ? 'no — +1 fame' : 'no — nothing', answer: false, expect: { hand: H1, fame: fameAfterNo } },
    { card, branch: 'yes, total 1 (low) — the 2 cards are confiscated, lose 1 fame', answer: true, shakes: [['blue', 'black']],
      picks: [pay('ore'), take('goods', 'food')], expect: { hand: ['fuel', 'carbon'], fame: 0, band: 'low' } },
    { card, branch: 'yes, total 2 (low) — the 2 cards are confiscated, lose 1 fame', answer: true, shakes: [['yellow', 'black']],
      picks: [pay('ore'), take('goods', 'food')], expect: { hand: ['fuel', 'carbon'], fame: 0, band: 'low' } },
    { card, branch: 'yes, total 3 (mid) — keep the cards, lose 1 fame', answer: true, shakes: [['yellow', 'blue']],
      picks: [pay('ore'), take('goods', 'food')], expect: { hand: ['fuel', 'carbon', 'goods', 'food'], fame: 0, band: 'mid' } },
    { card, branch: 'yes, total 4 (high) — safe voyage', answer: true, shakes: [['yellow', 'yellow']],
      picks: [pay('ore'), take('goods', 'food')], expect: { hand: ['fuel', 'carbon', 'goods', 'food'], fame: 1, band: 'high' } },
    { card, branch: 'yes, total 5 (high) — safe voyage', answer: true, shakes: [['red', 'yellow']],
      picks: [pay('ore'), take('goods', 'food')], expect: { hand: ['fuel', 'carbon', 'goods', 'food'], fame: 1, band: 'high' } },
  ]),

  // ---- 14 / 15: rob all opponents for 1. No: +1 fame (14) / nothing (15). Yes: pay 1, shake: low cheated −1 fame; mid steal 1 from each but −1 fame; high steal 1 from each.
  ...([[14, 2], [15, 1]] as const).flatMap(([card, fameAfterNo]): Case[] => [
    { card, branch: card === 14 ? 'no — +1 fame' : 'no — nothing', answer: false, expect: { hand: H1, fame: fameAfterNo } },
    { card, branch: 'yes, total 1 (low) — the pirate cheats you, lose 1 fame', answer: true, shakes: [['blue', 'black']], picks: [pay('ore')],
      expect: { hand: ['fuel', 'carbon'], fame: 0, band: 'low' } },
    { card, branch: 'yes, total 2 (low) — the pirate cheats you, lose 1 fame', answer: true, shakes: [['yellow', 'black']], picks: [pay('ore')],
      expect: { hand: ['fuel', 'carbon'], fame: 0, band: 'low' } },
    { card, branch: 'yes, total 3 (mid) — take 1 random card from each opponent, lose 1 fame', answer: true, shakes: [['yellow', 'blue']], picks: [pay('ore')],
      expect: { hand: ['fuel', 'carbon', 'goods', 'food'], fame: 0, band: 'mid', opponents: { p2: ['goods'], p3: [] } } },
    { card, branch: 'yes, total 4 (high) — take 1 random card from each opponent', answer: true, shakes: [['yellow', 'yellow']], picks: [pay('ore')],
      expect: { hand: ['fuel', 'carbon', 'goods', 'food'], fame: 1, band: 'high', opponents: { p2: ['goods'], p3: [] } } },
    { card, branch: 'yes, total 5 (high) — take 1 random card from each opponent', answer: true, shakes: [['red', 'yellow']], picks: [pay('ore')],
      expect: { hand: ['fuel', 'carbon', 'goods', 'food'], fame: 1, band: 'high', opponents: { p2: ['goods'], p3: [] } } },
    { card, branch: 'yes, high — an opponent without cards is skipped', answer: true, setup: (s) => setHand(s, P3, []), shakes: [['red', 'yellow']], picks: [pay('ore')],
      expect: { hand: ['fuel', 'carbon', 'goods'], fame: 1, band: 'high', opponents: { p2: ['goods'], p3: [] } } },
  ]),

  // ---- 16: Flee? boosters ≥ R → escape; else fight R. Win: +1 any upgrade, +1 fame. Lose: remove 1 upgrade.
  { card: 16, branch: 'flee, escaped (boosters equal) — nothing', answer: true, setup: boosters(P3, 1), shakes: [],
    expect: { hand: H1, fame: 1, flee: { opponent: P3, escaped: true } } },
  { card: 16, branch: 'flee, caught, win — +1 upgrade of choice, +1 fame', answer: true, setup: boosters(P3, 2), shakes: WIN, picks: [fit('cannon')],
    expect: { hand: H1, fame: 2, mothership: PLUS_CANNON, flee: { opponent: P3, escaped: false }, contest: combat(P3, true) } },
  { card: 16, branch: 'flee, caught, lose — remove 1 upgrade', answer: true, setup: boosters(P3, 2), shakes: LOSE, picks: [drop('booster')],
    expect: { hand: H1, fame: 1, mothership: NO_BOOSTER, flee: { opponent: P3, escaped: false }, contest: combat(P3, false) } },
  { card: 16, branch: 'fight, win — +1 upgrade of choice, +1 fame', answer: false, shakes: WIN, picks: [fit('freightPod')],
    expect: { hand: H1, fame: 2, mothership: { boosters: 1, cannons: 0, freightPods: 1 }, contest: combat(P3, true) } },
  { card: 16, branch: 'fight, lose — remove 1 upgrade', answer: false, shakes: LOSE, picks: [drop('booster')],
    expect: { hand: H1, fame: 1, mothership: NO_BOOSTER, contest: combat(P3, false) } },

  // ---- 17: Flee? boosters ≥ LL → escape but −1 fame; else fight LL. Win: +2 ore, +1 fame. Lose: remove 1 upgrade, +1 fame.
  { card: 17, branch: 'flee, escaped — lose 1 fame', answer: true, setup: boosters(P3, 1), shakes: [],
    expect: { hand: H1, fame: 0, flee: { opponent: P3, escaped: true } } },
  { card: 17, branch: 'flee, escaped — fame floor at 0', answer: true, setup: all(boosters(P3, 0), fameOf(0)), shakes: [],
    expect: { hand: H1, fame: 0, flee: { opponent: P3, escaped: true } } },
  { card: 17, branch: 'flee, caught, win — +2 ore, +1 fame', answer: true, setup: boosters(P3, 2), shakes: WIN,
    expect: { hand: [...H1, 'ore', 'ore'], fame: 2, flee: { opponent: P3, escaped: false }, contest: combat(P3, true) } },
  { card: 17, branch: 'flee, caught, lose — remove 1 upgrade, +1 fame', answer: true, setup: boosters(P3, 2), shakes: LOSE, picks: [drop('booster')],
    expect: { hand: H1, fame: 2, mothership: NO_BOOSTER, flee: { opponent: P3, escaped: false }, contest: combat(P3, false) } },
  { card: 17, branch: 'fight, win — +2 ore, +1 fame', answer: false, shakes: WIN,
    expect: { hand: [...H1, 'ore', 'ore'], fame: 2, contest: combat(P3, true) } },
  { card: 17, branch: 'fight, lose — remove 1 upgrade, +1 fame', answer: false, shakes: LOSE, picks: [drop('booster')],
    expect: { hand: H1, fame: 2, mothership: NO_BOOSTER, contest: combat(P3, false) } },

  // ---- 18: Flee? boosters ≥ L → escape; else fight L. Win: free trade ship. Lose: one ship cannot move.
  { card: 18, branch: 'flee, escaped — nothing', answer: true, setup: boosters(P2, 1), shakes: [],
    expect: { hand: H1, fame: 1, flee: { opponent: P2, escaped: true } } },
  { card: 18, branch: 'flee, escaped thanks to a Scientist speed bonus (1 + 2 ≥ 3)', answer: true, setup: all(scientist(P1, 'hirAkas'), boosters(P2, 3)), shakes: [],
    expect: { hand: H1, fame: 1, flee: { opponent: P2, escaped: true } } },
  { card: 18, branch: 'flee, caught, win — free trade ship', answer: true, setup: boosters(P2, 2), shakes: WIN,
    expect: { hand: H1, fame: 1, tradeShip: 'placed', flee: { opponent: P2, escaped: false }, contest: combat(P2, true) } },
  { card: 18, branch: 'flee, caught, lose — one ship cannot move', answer: true, setup: boosters(P2, 2), shakes: LOSE, picks: [pin()],
    expect: { hand: H1, fame: 1, immobilized: true, flee: { opponent: P2, escaped: false }, contest: combat(P2, false) } },
  { card: 18, branch: 'fight, win — free trade ship', answer: false, shakes: WIN,
    expect: { hand: H1, fame: 1, tradeShip: 'placed', contest: combat(P2, true) } },
  { card: 18, branch: 'fight, lose — one ship cannot move', answer: false, shakes: LOSE, picks: [pin()],
    expect: { hand: H1, fame: 1, immobilized: true, contest: combat(P2, false) } },

  // ---- 19: Distress. No: nothing. Yes: speed race vs RR. Win: free trade ship. Lose: remove 1 upgrade.
  { card: 19, branch: 'no — nothing', answer: false, expect: { hand: H1, fame: 1 } },
  { card: 19, branch: 'yes, win — free trade ship', answer: true, shakes: WIN, expect: { hand: H1, fame: 1, tradeShip: 'placed', contest: race(P2, true) } },
  { card: 19, branch: 'yes, lose — remove 1 upgrade', answer: true, shakes: LOSE, picks: [drop('booster')],
    expect: { hand: H1, fame: 1, mothership: NO_BOOSTER, contest: race(P2, false) } },
  { card: 19, branch: 'yes, tie with Scientist speed bonus — the active player wins', answer: true,
    setup: scientist(P1, 'hirAkas'), shakes: [['blue', 'black'], ['yellow', 'blue']], // 1+1+2 = 4 ≥ 3+1 = 4
    expect: { hand: H1, fame: 1, tradeShip: 'placed', contest: race(P2, true) } },

  // ---- 20: Distress. No: −1 fame. Yes: race vs L. Win: +1 fame, 1 random card from each opponent. Lose: remove 1 upgrade, +1 fame.
  { card: 20, branch: 'no — lose 1 fame', answer: false, expect: { hand: H1, fame: 0 } },
  { card: 20, branch: 'yes, win — +1 fame, take 1 random card from each opponent', answer: true, shakes: WIN,
    expect: { hand: [...H1, 'goods', 'food'], fame: 2, opponents: { p2: ['goods'], p3: [] }, contest: race(P2, true) } },
  { card: 20, branch: 'yes, lose — remove 1 upgrade, +1 fame', answer: true, shakes: LOSE, picks: [drop('booster')],
    expect: { hand: H1, fame: 2, mothership: NO_BOOSTER, contest: race(P2, false) } },

  // ---- 21: Distress. No: −1 fame. Yes: race vs R. Win: +1 upgrade of choice, +1 fame. Lose: remove 1 upgrade.
  { card: 21, branch: 'no — lose 1 fame', answer: false, expect: { hand: H1, fame: 0 } },
  { card: 21, branch: 'yes, win — +1 upgrade of choice, +1 fame', answer: true, shakes: WIN, picks: [fit('cannon')],
    expect: { hand: H1, fame: 2, mothership: PLUS_CANNON, contest: race(P3, true) } },
  { card: 21, branch: 'yes, lose — remove 1 upgrade', answer: true, shakes: LOSE, picks: [drop('booster')],
    expect: { hand: H1, fame: 1, mothership: NO_BOOSTER, contest: race(P3, false) } },

  // ---- 22: Rescue? No: nothing. Yes: fight RR. Win: +2 goods, +1 fame. Lose: one ship cannot move.
  { card: 22, branch: 'no — nothing', answer: false, expect: { hand: H1, fame: 1 } },
  { card: 22, branch: 'yes, win — +2 goods, +1 fame', answer: true, shakes: WIN, expect: { hand: [...H1, 'goods', 'goods'], fame: 2, contest: combat(P2, true) } },
  { card: 22, branch: 'yes, lose — one ship cannot move', answer: true, shakes: LOSE, picks: [pin()],
    expect: { hand: H1, fame: 1, immobilized: true, contest: combat(P2, false) } },
  { card: 22, branch: 'yes, tie on cannons — the active player wins', answer: true, setup: cannons(P2, 1),
    shakes: [['yellow', 'yellow'], ['blue', 'yellow']], // 4+0 ≥ 3+1
    expect: { hand: [...H1, 'goods', 'goods'], fame: 2, contest: combat(P2, true) } },

  // ---- 23: Rescue? No: −1 fame. Yes: fight R. Win: +2 any, +1 fame. Lose: remove 1 upgrade, +1 fame.
  { card: 23, branch: 'no — lose 1 fame', answer: false, expect: { hand: H1, fame: 0 } },
  { card: 23, branch: 'yes, win — +2 any, +1 fame', answer: true, shakes: WIN, picks: [take('goods', 'food')],
    expect: { hand: [...H1, 'goods', 'food'], fame: 2, contest: combat(P3, true) } },
  { card: 23, branch: 'yes, lose — remove 1 upgrade, +1 fame', answer: true, shakes: LOSE, picks: [drop('booster')],
    expect: { hand: H1, fame: 2, mothership: NO_BOOSTER, contest: combat(P3, false) } },

  // ---- 24: Rescue? No: −1 fame. Yes: fight L. Win: space jump for 1 ship, +1 fame. Lose: one ship cannot move, +1 fame.
  { card: 24, branch: 'no — lose 1 fame', answer: false, expect: { hand: H1, fame: 0 } },
  { card: 24, branch: 'yes, win — space jump, +1 fame', answer: true, shakes: WIN, picks: [jump()],
    expect: { hand: H1, fame: 2, shipAt: JUMP_TARGET, contest: combat(P2, true) } },
  { card: 24, branch: 'yes, win — the jump may be declined, +1 fame', answer: true, shakes: WIN, picks: [declineJump()],
    expect: { hand: H1, fame: 2, contest: combat(P2, true) } },
  { card: 24, branch: 'yes, lose — one ship cannot move, +1 fame', answer: true, shakes: LOSE, picks: [pin()],
    expect: { hand: H1, fame: 2, immobilized: true, contest: combat(P2, false) } },

  // ---- 25 / 26 / 27: Wormhole. Yes: race vs L / R / RR. Win: jump. Lose: one ship cannot move (25, 26) / remove 1 upgrade (27). ("No" = new card: see below.)
  { card: 25, branch: 'yes, win — space jump', answer: true, shakes: WIN, picks: [jump()], expect: { hand: H1, fame: 1, shipAt: JUMP_TARGET, contest: race(P2, true) } },
  { card: 25, branch: 'yes, lose — one ship cannot move', answer: true, shakes: LOSE, picks: [pin()], expect: { hand: H1, fame: 1, immobilized: true, contest: race(P2, false) } },
  { card: 26, branch: 'yes, win — space jump', answer: true, shakes: WIN, picks: [jump()], expect: { hand: H1, fame: 1, shipAt: JUMP_TARGET, contest: race(P3, true) } },
  { card: 26, branch: 'yes, lose — one ship cannot move', answer: true, shakes: LOSE, picks: [pin()], expect: { hand: H1, fame: 1, immobilized: true, contest: race(P3, false) } },
  { card: 27, branch: 'yes, win — space jump', answer: true, shakes: WIN, picks: [jump()], expect: { hand: H1, fame: 1, shipAt: JUMP_TARGET, contest: race(P2, true) } },
  { card: 27, branch: 'yes, lose — remove 1 upgrade', answer: true, shakes: LOSE, picks: [drop('booster')],
    expect: { hand: H1, fame: 1, mothership: NO_BOOSTER, contest: race(P2, false) } },

  // ---- 28: Travelers. 0: remove 1 upgrade, −1 fame. 1: +1 fame. 2: +1 fame. 3: space jump.
  { card: 28, branch: 'donate 0 — remove 1 upgrade, lose 1 fame', offer: 0, picks: [drop('booster')], expect: { hand: H1, fame: 0, mothership: NO_BOOSTER } },
  { card: 28, branch: 'donate 0 — fame floor at 0', offer: 0, setup: fameOf(0), picks: [drop('booster')], expect: { hand: H1, fame: 0, mothership: NO_BOOSTER } },
  { card: 28, branch: 'donate 1 — +1 fame', offer: 1, expect: { hand: ['fuel', 'carbon'], fame: 2 } },
  { card: 28, branch: 'donate 2 — +1 fame', offer: 2, expect: { hand: ['carbon'], fame: 2 } },
  { card: 28, branch: 'donate 3 — space jump', offer: 3, picks: [jump()], expect: { hand: [], fame: 1, shipAt: JUMP_TARGET } },

  // ---- 29: Travelers. 0: nothing. 1–2: +1 fame. 3: free trade ship.
  { card: 29, branch: 'donate 0 — nothing', offer: 0, expect: { hand: H1, fame: 1 } },
  { card: 29, branch: 'donate 1 — +1 fame', offer: 1, expect: { hand: ['fuel', 'carbon'], fame: 2 } },
  { card: 29, branch: 'donate 2 — +1 fame', offer: 2, expect: { hand: ['carbon'], fame: 2 } },
  { card: 29, branch: 'donate 3 — free trade ship', offer: 3, expect: { hand: [], fame: 1, tradeShip: 'placed' } },

  // ---- 30: Travelers. 0: −1 fame. 1–2: +1 fame. 3: space jump, +1 fame.
  { card: 30, branch: 'donate 0 — lose 1 fame', offer: 0, expect: { hand: H1, fame: 0 } },
  { card: 30, branch: 'donate 1 — +1 fame', offer: 1, expect: { hand: ['fuel', 'carbon'], fame: 2 } },
  { card: 30, branch: 'donate 2 — +1 fame', offer: 2, expect: { hand: ['carbon'], fame: 2 } },
  { card: 30, branch: 'donate 3 — space jump, +1 fame', offer: 3, picks: [jump()], expect: { hand: [], fame: 2, shipAt: JUMP_TARGET } },
];

// ---------------------------------------------------------------------------
// Generic runner
// ---------------------------------------------------------------------------

const sorted = (hand: readonly Resource[]): Resource[] => [...hand].sort();

/** Beginner game shaken black (base speed 3) with the fixture hands, `setup` applied and `cardId` just drawn for p1. */
function encounterState(cardId: number, r: Rng, setup?: (s: GameState) => void): GameState {
  const state = tradeBuildState();
  setHand(state, P1, H1);
  setHand(state, P2, H2);
  setHand(state, P3, H3);
  setup?.(state);
  state.turn.shake = ['black', 'red'];
  state.turn.baseSpeed = 3;
  refreshSpeed(state);
  beginEncounter(state, cardId, r);
  return state;
}

function countBy(hands: readonly Resource[][]): Record<Resource, number> {
  const out = Object.fromEntries(RESOURCES.map((r) => [r, 0])) as Record<Resource, number>;
  for (const hand of hands) for (const r of hand) out[r] += 1;
  return out;
}

/** Trays + every player's pieces: conserved by every encounter. */
function trayTotals(state: GameState): Record<string, number> {
  const sum = (f: (p: GameState['players'][number]) => number) => state.players.reduce((n, p) => n + f(p), 0);
  return {
    boosters: state.upgradesTray.boosters + sum((p) => p.mothership.boosters),
    cannons: state.upgradesTray.cannons + sum((p) => p.mothership.cannons),
    freightPods: state.upgradesTray.freightPods + sum((p) => p.mothership.freightPods),
    famePieces: state.upgradesTray.famePieces + sum((p) => p.famePieces),
  };
}

/** Everything about a player that an encounter may never touch (hands and fame are asserted separately). */
function invariantsOf(state: GameState, id: PlayerId) {
  const p = player(state, id);
  return { mothership: p.mothership, pieces: p.pieces, friendshipCards: p.friendshipCards, medals: p.medals };
}

/** The shared end-of-encounter assertions (§10 "After any encounter…"). */
function expectDone(state: GameState, cardId: number): void {
  expect(state.phase).toBe('flight.move');
  expect(state.turn.encounter?.cardId).toBe(cardId);
  expect(state.turn.encounter?.stage).toBe('done');
  expect(state.turn.encounter?.awaiting).toBeUndefined();
  expect(state.turn.encounter?.queue).toEqual([]);
  expect(state.turn.baseSpeed).toBe(3);
  expect(state.turn.speed).toBe(speedOf(state, P1));
  expect(state.encounterDiscard).toEqual([cardId]);
  // Nothing more may be answered.
  fails(state, { type: 'encounterChoice', playerId: P1, value: true }, 'wrongPhase');
  fails(state, { type: 'encounterPick', playerId: P1, upgrade: 'booster' }, 'wrongPhase');
}

function runCase(c: Case): void {
  const r = scriptedRng(c.shakes ?? []);
  const card = encounterCard(c.card);
  let state = encounterState(c.card, r, c.setup);
  const before = structuredClone(state);
  const cardsBefore = cardsInPlay(before);
  const traysBefore = trayTotals(before);
  const shipsBefore = shipsOf(before, P1).length;
  const opponentHandsBefore: Record<typeof P2 | typeof P3, Resource[]> = { p2: sorted(player(before, P2).hand), p3: sorted(player(before, P3).hand) };
  const deckBefore = [...before.encounterDeck];

  expect(state.phase).toBe('flight.encounter');
  expect(state.turn.encounter).toMatchObject({ cardId: c.card, stage: 'choice', queue: [] });
  expect(state.turn.encounter?.revealed).toEqual([card.prompt]);

  // Only the active player answers the card, and only with the kind of answer it asks for.
  fails(state, { type: 'encounterChoice', playerId: P2, value: c.offer ?? c.answer ?? 0, cards: [] }, 'notYourTurn');
  if (c.offer !== undefined) {
    fails(state, { type: 'encounterChoice', playerId: P1, value: true }, 'invalidAction');
  } else {
    fails(state, { type: 'encounterChoice', playerId: P1, value: 0, cards: [] }, 'invalidAction');
  }

  // Offer: paid to the supply BEFORE the result is revealed (§10 Mechanics).
  if (c.offer !== undefined) {
    const offered = player(state, P1).hand.slice(0, c.offer);
    const supplyBefore = { ...state.supply };
    state = ok(state, { type: 'encounterChoice', playerId: P1, value: c.offer, cards: offered }, r);
    expect(state.turn.encounter?.offerPaid).toEqual(offered);
    // The offer is logged (paid) before anything of the branch resolves.
    const offerLog = state.log.findIndex((e) => /offers \d card/.test(e.message));
    expect(offerLog).toBeGreaterThan(before.log.length - 1);
    expect(state.log.slice(before.log.length, offerLog).some((e) => /receives|gains|loses|removes|cannot move|trade ship|jump/.test(e.message))).toBe(false);
    if (card.choice === 'offerThenYesno') {
      // Observable here because the yes/no has not been answered yet: the cards are already in the supply.
      expect(state.turn.encounter?.stage).toBe('choice');
      expect(state.turn.encounter?.choice).toBeUndefined();
      expect(sorted(player(state, P1).hand)).toEqual(expectHandAfterOffer(before, c.offer));
      for (const res of RESOURCES) {
        expect(state.supply[res] - supplyBefore[res], `${res} paid to the supply`).toBe(offered.filter((x) => x === res).length);
      }
      // The second step is yes/no now; another offer is refused.
      fails(state, { type: 'encounterChoice', playerId: P1, value: 1, cards: [] }, 'invalidAction');
    } else {
      expect(state.turn.encounter?.choice).toBe(String(c.offer));
    }
  }
  if (c.answer !== undefined) {
    state = ok(state, { type: 'encounterChoice', playerId: P1, value: c.answer }, r);
    expect(state.turn.encounter?.choice).toBe(c.answer ? 'yes' : 'no');
  }
  // Revealed text: prompt, (the "hands over" line of 7/8), the chosen branch's text, then results.
  const branchText = card.branches[state.turn.encounter!.choice!]!.text;
  expect(state.turn.encounter?.revealed[card.choice === 'offerThenYesno' ? 2 : 1]).toBe(branchText);

  // Picks, each answered by the player the engine names.
  for (const p of c.picks ?? []) {
    expect(state.phase).toBe('flight.encounter');
    expect(state.turn.encounter?.awaiting, `expected a ${p.kind} pick by ${p.player}`).toMatchObject({ kind: p.kind, playerId: p.player });
    const other = p.player === P1 ? P2 : P1;
    const { player: playerId, kind: _kind, ...fields } = p;
    fails(state, { type: 'encounterPick', playerId: other, ...fields }, 'notYourTurn');
    state = ok(state, { type: 'encounterPick', playerId, ...fields }, r);
  }

  expectDone(state, c.card);
  expect(state.encounterDeck).toEqual(deckBefore); // no second card was drawn
  expect(r.remaining(), 'every scripted shake was used').toBe(0);

  // Contest / flee / table bookkeeping, and the opponent named on the card.
  const ctx = state.turn.encounter!;
  if (c.expect.contest) {
    expect(ctx.contestResults).toHaveLength(1);
    expect(ctx.contestResults![0]).toMatchObject({ kind: c.expect.contest.kind, won: c.expect.contest.won, yours: { playerId: P1 }, theirs: { playerId: c.expect.contest.opponent } });
    const [res] = ctx.contestResults!;
    expect(res!.won).toBe(res!.yours.strength >= res!.theirs.strength);
  } else {
    expect(ctx.contestResults).toBeUndefined();
  }
  if (c.expect.flee) {
    expect(ctx.fleeResults).toEqual([expect.objectContaining(c.expect.flee)]);
    expect(ctx.fleeResults![0]!.escaped).toBe(ctx.fleeResults![0]!.yours >= ctx.fleeResults![0]!.theirs);
  } else {
    expect(ctx.fleeResults).toBeUndefined();
  }
  if (c.expect.band) {
    expect(ctx.tableShakes).toHaveLength(1);
    expect(ctx.tableShakes![0]!.band).toBe(c.expect.band);
  } else {
    expect(ctx.tableShakes).toBeUndefined();
  }

  // p1: hand, fame, upgrades.
  const p1 = player(state, P1);
  expect(sorted(p1.hand)).toEqual(sorted(c.expect.hand));
  expect(p1.famePieces).toBe(c.expect.fame);
  expect(p1.mothership).toEqual(c.expect.mothership ?? player(before, P1).mothership);
  expect(p1.friendshipCards).toEqual(player(before, P1).friendshipCards);
  expect(p1.medals).toEqual(player(before, P1).medals);

  // Ship immobilized / jumped.
  expect(state.turn.immobilized).toEqual(c.expect.immobilized ? [SHIP] : []);
  expect(ctx.immobilizedShip).toBe(c.expect.immobilized ? SHIP : undefined);
  expect(state.board.ships[SHIP]!.nodeId).toBe(c.expect.shipAt ?? HOME);
  if (c.expect.shipAt) {
    expect(ctx.jumpedTo).toEqual({ shipId: SHIP, nodeId: c.expect.shipAt });
    expect(state.turn.shipMovesUsed[SHIP]).toBe(state.turn.speed);
  } else {
    expect(ctx.jumpedTo).toBeUndefined();
    expect(state.turn.shipMovesUsed[SHIP] ?? 0).toBe(0);
  }

  // Free trade ship.
  const tradeShips = shipsOf(state, P1).filter((s) => s.kind === 'trade');
  const piecesBefore = player(before, P1).pieces;
  if (c.expect.tradeShip === 'placed') {
    expect(tradeShips).toHaveLength(1);
    expect(shipsOf(state, P1)).toHaveLength(shipsBefore + 1);
    expect(p1.pieces).toEqual({ ...piecesBefore, transportsLeft: piecesBefore.transportsLeft - 1, stationsLeft: piecesBefore.stationsLeft - 1 });
    expect(state.pendingTradeShips[P1] ?? 0).toBe(0);
  } else if (c.expect.tradeShip === 'pending') {
    expect(tradeShips).toHaveLength(0);
    expect(shipsOf(state, P1)).toHaveLength(shipsBefore);
    expect(p1.pieces).toEqual(piecesBefore);
    expect(state.pendingTradeShips[P1]).toBe(1);
  } else {
    expect(tradeShips).toHaveLength(0);
    expect(shipsOf(state, P1)).toHaveLength(shipsBefore);
    expect(p1.pieces).toEqual(piecesBefore);
    expect(state.pendingTradeShips[P1] ?? 0).toBe(0);
  }

  // Opponents: hands only as the card says; everything else untouched (the pirate player gains / loses nothing).
  for (const id of [P2, P3] as const) {
    const expectedHand = c.expect.opponents?.[id] ?? opponentHandsBefore[id];
    expect(sorted(player(state, id).hand), `${id} hand`).toEqual(sorted(expectedHand));
    expect(player(state, id).famePieces, `${id} fame`).toBe(player(before, id).famePieces);
    expect(invariantsOf(state, id)).toEqual(invariantsOf(before, id));
  }
  expect(state.turn.immobilized.filter((s) => !s.startsWith('ship:red:'))).toEqual([]);

  // Supply: every card that left a hand is in the supply and vice versa (no card vanishes).
  const handsBefore = countBy(before.players.map((p) => p.hand));
  const handsAfter = countBy(state.players.map((p) => p.hand));
  for (const res of RESOURCES) {
    expect(state.supply[res], `supply ${res}`).toBe(before.supply[res] + handsBefore[res] - handsAfter[res]);
  }
  expect(cardsInPlay(state)).toBe(cardsBefore);
  expect(state.reservePile).toEqual(before.reservePile);
  expect(trayTotals(state)).toEqual(traysBefore);
}

/** p1's hand right after paying an offer of `n`: the fixture hand minus its first `n` cards. */
function expectHandAfterOffer(before: GameState, n: number): Resource[] {
  return sorted(player(before, P1).hand.slice(n));
}

describe('encounter table: one test per card branch (spec §10)', () => {
  it('covers every branch key of every choice card (1–30)', () => {
    for (let id = 1; id <= 30; id++) {
      const card = encounterCard(id);
      const branchKeys = Object.keys(card.branches);
      const cases = CASES.filter((c) => c.card === id);
      expect(cases.length, `card ${id} has table cases`).toBeGreaterThan(0);
      for (const key of branchKeys) {
        if (id >= 25 && id <= 27 && key === 'no') continue; // "draw a new card": hand-written below
        const hit = cases.some((c) => (c.answer !== undefined ? (c.answer ? 'yes' : 'no') : String(c.offer)) === key);
        expect(hit, `card ${id} branch '${key}' has a table case`).toBe(true);
      }
    }
  });

  for (const c of CASES) {
    it(`card ${c.card}: ${c.branch}`, () => runCase(c));
  }
});

// ---------------------------------------------------------------------------
// Config that the [VERIFY] items of §10 hang on
// ---------------------------------------------------------------------------

describe('[VERIFY] config matches the spec defaults', () => {
  it('shake bands 12–15: low = 1–2, mid = 3, high = 4–5 (every reachable total is covered once)', () => {
    expect(ENCOUNTER_SHAKE_BANDS).toEqual({ low: [1, 2], mid: [3], high: [4, 5] });
  });

  it('travelers 28–30: 0 / 1 / 2 / 3 map to the spec outcomes', () => {
    expect(TRAVELERS_DONATION_BRANCHES[28]).toEqual({ 0: 'removeUpgradeLoseFame', 1: 'gainFame', 2: 'gainFame', 3: 'spaceJump' });
    expect(TRAVELERS_DONATION_BRANCHES[29]).toEqual({ 0: 'nothing', 1: 'gainFame', 2: 'gainFame', 3: 'freeTradeShip' });
    expect(TRAVELERS_DONATION_BRANCHES[30]).toEqual({ 0: 'loseFame', 1: 'gainFame', 2: 'gainFame', 3: 'spaceJumpAndFame' });
  });

  it('wear and tear thresholds: 31 → more than 8, 32 → more than 6', () => {
    expect(WEAR_AND_TEAR_THRESHOLDS).toEqual({ 31: 8, 32: 6 });
  });
});

// ---------------------------------------------------------------------------
// 25–27 "No": draw a new encounter card
// ---------------------------------------------------------------------------

describe('cards 25–27 "no": the card is discarded and a new one is drawn and played', () => {
  for (const id of [25, 26, 27] as const) {
    it(`card ${id}, no — new card from the top of the deck, nothing else changes`, () => {
      const r = scriptedRng([]);
      const state = encounterState(id, r);
      state.encounterDeck = [3, 9];
      state.encounterDiscard = [];
      const before = structuredClone(state);

      const next = ok(state, { type: 'encounterChoice', playerId: P1, value: false }, r);
      expect(next.encounterDiscard).toEqual([id]);
      expect(next.encounterDeck).toEqual([9]);
      expect(next.phase).toBe('flight.encounter');
      expect(next.turn.encounter).toMatchObject({ cardId: 3, stage: 'choice', queue: [], revealed: [encounterCard(3).prompt] });
      expect(next.turn.encounter?.awaiting).toBeUndefined();
      expect(next.turn.encounter?.offerPaid).toBeUndefined();
      for (const p of next.players) {
        const b = player(before, p.id);
        expect({ hand: p.hand, fame: p.famePieces, mothership: p.mothership }).toEqual({ hand: b.hand, fame: b.famePieces, mothership: b.mothership });
      }
      expect(next.turn.immobilized).toEqual([]);
      expect(next.turn.baseSpeed).toBe(3);

      // The new card (3, offer 2 → +1 fame) is played out normally and ends the encounter.
      const done = ok(next, { type: 'encounterChoice', playerId: P1, value: 2, cards: ['ore', 'fuel'] }, r);
      expect(done.phase).toBe('flight.move');
      expect(done.turn.encounter).toMatchObject({ cardId: 3, stage: 'done' });
      expect(done.encounterDiscard).toEqual([id, 3]);
      expect(player(done, P1).famePieces).toBe(2);
      expect(player(done, P1).hand).toEqual(['carbon']);
      expect(done.turn.baseSpeed).toBe(3);
    });
  }

  it('with an empty deck the discard pile (this card included) is reshuffled first', () => {
    const r = scriptedRng([]);
    const state = encounterState(26, r);
    state.encounterDeck = [];
    state.encounterDiscard = [4];
    const next = ok(state, { type: 'encounterChoice', playerId: P1, value: false }, r);
    // Sorted reshuffle of [4, 26] → 4 is drawn, 26 stays in the deck.
    expect(next.turn.encounter).toMatchObject({ cardId: 4, stage: 'choice' });
    expect(next.encounterDeck).toEqual([26]);
    expect(next.encounterDiscard).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// 31 / 32 Wear and Tear: all players, in order, no choices
// ---------------------------------------------------------------------------

describe('card 31: every player with > 8 upgrades removes 1 (turn order from the active player), then reshuffle + redraw', () => {
  function wearState(): GameState {
    const state = tradeBuildState();
    setHand(state, P1, H1);
    setHand(state, P2, H2);
    setHand(state, P3, H3);
    state.turn.shake = ['black', 'blue'];
    state.turn.baseSpeed = 3;
    refreshSpeed(state);
    return state;
  }

  it('full sequence: p1 (9) and p3 (9) remove 1 each, p2 (8) is spared, Scientist cards never count, then card 4 is drawn from the reshuffled deck', () => {
    const state = wearState();
    player(state, P1).mothership = { boosters: 4, cannons: 3, freightPods: 2 }; // 9
    player(state, P2).mothership = { boosters: 3, cannons: 3, freightPods: 2 }; // 8 → safe
    player(state, P3).mothership = { boosters: 6, cannons: 3, freightPods: 0 }; // 9
    player(state, P2).friendshipCards = ['khaStar', 'hirAkas']; // would be 10 if cards counted
    state.encounterDeck = [10];
    state.encounterDiscard = [5, 4];
    const traysBefore = trayTotals(state);
    const r = scriptedRng([]);

    beginEncounter(state, 31, r); // 'none': resolves at once, no choice
    expect(state.turn.encounter).toMatchObject({ cardId: 31, stage: 'resolving', choice: 'auto' });
    expect(state.turn.encounter?.awaiting).toMatchObject({ kind: 'removeUpgrade', playerId: P1, options: ['booster', 'cannon', 'freightPod'] });
    fails(state, { type: 'encounterChoice', playerId: P1, value: true }, 'ruleViolation'); // no choice on this card
    fails(state, { type: 'encounterPick', playerId: P3, upgrade: 'cannon' }, 'notYourTurn'); // p1 first
    fails(state, { type: 'encounterPick', playerId: P2, upgrade: 'cannon' }, 'notYourTurn');

    const second = ok(state, { type: 'encounterPick', playerId: P1, upgrade: 'freightPod' }, r);
    expect(player(second, P1).mothership).toEqual({ boosters: 4, cannons: 3, freightPods: 1 });
    expect(second.turn.encounter?.awaiting).toMatchObject({ kind: 'removeUpgrade', playerId: P3, options: ['booster', 'cannon'] });
    fails(second, { type: 'encounterPick', playerId: P3, upgrade: 'freightPod' }, 'invalidTarget');

    const after = ok(second, { type: 'encounterPick', playerId: P3, upgrade: 'cannon' }, r);
    expect(player(after, P3).mothership).toEqual({ boosters: 6, cannons: 2, freightPods: 0 });
    expect(player(after, P2).mothership).toEqual({ boosters: 3, cannons: 3, freightPods: 2 });
    expect(after.players.map((p) => p.famePieces)).toEqual([1, 1, 1]);
    expect(after.players.map((p) => p.hand)).toEqual([H1, H2, H3]);
    expect(trayTotals(after)).toEqual(traysBefore);

    // Deck [10] + discard [5, 4] + card 31 reshuffled (sorted by the scripted rng) → 4 drawn for p1.
    expect(after.encounterDiscard).toEqual([]);
    expect(after.encounterDeck).toEqual([5, 10, 31]);
    expect(after.phase).toBe('flight.encounter');
    expect(after.turn.encounter).toMatchObject({ cardId: 4, stage: 'choice', queue: [], revealed: [encounterCard(4).prompt] });
    expect(after.turn.baseSpeed).toBe(3);

    // The redrawn card completes the encounter as usual.
    const done = ok(after, { type: 'encounterChoice', playerId: P1, value: 0, cards: [] }, r);
    expect(done.phase).toBe('flight.move');
    expect(done.turn.encounter).toMatchObject({ cardId: 4, stage: 'done' });
    expect(done.encounterDiscard).toEqual([4]);
    expect(done.turn.baseSpeed).toBe(3);
    expect(done.turn.speed).toBe(speedOf(done, P1));
  });

  it('exactly 8 upgrades is safe; nobody over the threshold → straight to the new card', () => {
    const state = wearState();
    player(state, P1).mothership = { boosters: 3, cannons: 3, freightPods: 2 }; // 8
    state.encounterDeck = [2];
    state.encounterDiscard = [];
    beginEncounter(state, 31, scriptedRng([]));
    expect(state.turn.encounter).toMatchObject({ cardId: 2, stage: 'choice' });
    expect(state.encounterDeck).toEqual([31]);
    expect(player(state, P1).mothership).toEqual({ boosters: 3, cannons: 3, freightPods: 2 });
  });

  it('the order is turn order starting with the active player, even when the active player is not first in turn order', () => {
    const state = wearState();
    state.activePlayer = P2;
    for (const id of [P1, P2, P3] as const) player(state, id).mothership = { boosters: 6, cannons: 3, freightPods: 0 }; // 9 each
    state.encounterDeck = [2];
    state.encounterDiscard = [];
    const r = scriptedRng([]);
    beginEncounter(state, 31, r);
    expect(state.turn.encounter?.awaiting).toMatchObject({ kind: 'removeUpgrade', playerId: P2 });
    const s2 = ok(state, { type: 'encounterPick', playerId: P2, upgrade: 'booster' }, r);
    expect(s2.turn.encounter?.awaiting).toMatchObject({ kind: 'removeUpgrade', playerId: P3 });
    const s3 = ok(s2, { type: 'encounterPick', playerId: P3, upgrade: 'booster' }, r);
    expect(s3.turn.encounter?.awaiting).toMatchObject({ kind: 'removeUpgrade', playerId: P1 });
    const s4 = ok(s3, { type: 'encounterPick', playerId: P1, upgrade: 'cannon' }, r);
    expect(s4.players.map((p) => p.mothership)).toEqual([
      { boosters: 6, cannons: 2, freightPods: 0 },
      { boosters: 5, cannons: 3, freightPods: 0 },
      { boosters: 5, cannons: 3, freightPods: 0 },
    ]);
    expect(s4.turn.encounter).toMatchObject({ cardId: 2, stage: 'choice' });
  });
});

describe('card 32: > 6 upgrades remove 1, the Galactic Council gives +1 fame to the most freight pods, then reshuffle + redraw', () => {
  function wearState(): GameState {
    const state = tradeBuildState();
    setHand(state, P1, H1);
    setHand(state, P2, H2);
    setHand(state, P3, H3);
    state.turn.shake = ['black', 'blue'];
    state.turn.baseSpeed = 3;
    refreshSpeed(state);
    state.encounterDeck = [10];
    state.encounterDiscard = [5];
    return state;
  }

  it('full sequence: p1 (7) and p3 (7) remove 1, p2 (6) is spared; the council honours the single leader; card 5 is redrawn', () => {
    const state = wearState();
    player(state, P1).mothership = { boosters: 2, cannons: 2, freightPods: 3 }; // 7
    player(state, P2).mothership = { boosters: 1, cannons: 2, freightPods: 3 }; // 6 → safe
    player(state, P3).mothership = { boosters: 3, cannons: 3, freightPods: 1 }; // 7
    const traysBefore = trayTotals(state);
    const r = scriptedRng([]);

    beginEncounter(state, 32, r);
    expect(state.turn.encounter).toMatchObject({ cardId: 32, stage: 'resolving', choice: 'auto' });
    expect(state.turn.encounter?.awaiting).toMatchObject({ kind: 'removeUpgrade', playerId: P1 });
    expect(state.players.map((p) => p.famePieces)).toEqual([1, 1, 1]); // the council sits AFTER the removals
    const second = ok(state, { type: 'encounterPick', playerId: P1, upgrade: 'freightPod' }, r); // p1 now 2 pods
    expect(second.turn.encounter?.awaiting).toMatchObject({ kind: 'removeUpgrade', playerId: P3 });
    const after = ok(second, { type: 'encounterPick', playerId: P3, upgrade: 'booster' }, r);

    expect(after.players.map((p) => p.mothership)).toEqual([
      { boosters: 2, cannons: 2, freightPods: 2 },
      { boosters: 1, cannons: 2, freightPods: 3 },
      { boosters: 2, cannons: 3, freightPods: 1 },
    ]);
    expect(after.players.map((p) => p.famePieces)).toEqual([1, 2, 1]); // p2 alone has the most pods (3)
    expect(after.players.map((p) => p.hand)).toEqual([H1, H2, H3]);
    expect(trayTotals(after)).toEqual(traysBefore);
    expect(after.encounterDiscard).toEqual([]);
    expect(after.encounterDeck).toEqual([10, 32]);
    expect(after.turn.encounter).toMatchObject({ cardId: 5, stage: 'choice' });
    expect(after.phase).toBe('flight.encounter');

    const done = ok(after, { type: 'encounterChoice', playerId: P1, value: 1, cards: ['ore'] }, r); // card 5 offer 1: −1 fame
    expect(done.phase).toBe('flight.move');
    expect(done.encounterDiscard).toEqual([5]);
    expect(player(done, P1).famePieces).toBe(0);
    expect(done.turn.baseSpeed).toBe(3);
  });

  it('a tie for the most freight pods honours everyone tied; exactly 6 upgrades is safe', () => {
    const state = wearState();
    player(state, P1).mothership = { boosters: 2, cannons: 2, freightPods: 2 }; // 6 → safe
    player(state, P3).mothership = { boosters: 1, cannons: 0, freightPods: 2 };
    beginEncounter(state, 32, scriptedRng([]));
    expect(state.players.map((p) => p.famePieces)).toEqual([2, 1, 2]);
    expect(player(state, P1).mothership).toEqual({ boosters: 2, cannons: 2, freightPods: 2 });
    expect(state.turn.encounter).toMatchObject({ cardId: 5, stage: 'choice' });
  });

  it('with no freight pods anywhere nobody is honoured (documented reading of "most freight pods")', () => {
    const state = wearState();
    beginEncounter(state, 32, scriptedRng([]));
    expect(state.players.map((p) => p.famePieces)).toEqual([1, 1, 1]);
    expect(state.turn.encounter).toMatchObject({ cardId: 5, stage: 'choice' });
  });
});
