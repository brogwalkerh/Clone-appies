/**
 * Rule constants and every value the spec marks as inferred or **[VERIFY]**.
 * Game logic imports from here; it never hard-codes these numbers.
 */

import type { Civ, FriendshipCardId, Resource, ResourceBag, UpgradeKind } from './types.js';

// ---------------------------------------------------------------------------
// Victory and hand limits (spec §4, §6)
// ---------------------------------------------------------------------------

/** A player who reaches this many VP on their own turn wins immediately. */
export const WIN_VP = 15;
/** VP marker start position in the beginner set-up (2 colonies + 1 spaceport). */
export const STARTING_VP = 4;
/** On a 7, every player holding MORE than this many cards discards half (round down). */
export const DISCARD_THRESHOLD = 7;
/** Diplomats "Reduced Tribute" (Ra'Hal) raises the threshold to MORE than this. */
export const REDUCED_TRIBUTE_THRESHOLD = 12;

/**
 * Reserve-pile draw by VP at the start of the active player's turn (spec §5.1c).
 * Checked top to bottom: first row whose `maxVp` is >= the player's VP applies.
 */
export const RESERVE_DRAW_BY_VP: readonly { maxVp: number; cards: number }[] = [
  { maxVp: 7, cards: 2 },
  { maxVp: 9, cards: 1 },
  { maxVp: Number.POSITIVE_INFINITY, cards: 0 },
];

export function reserveDrawFor(vp: number): number {
  for (const row of RESERVE_DRAW_BY_VP) {
    if (vp <= row.maxVp) return row.cards;
  }
  return 0;
}

// ---------------------------------------------------------------------------
// Supply (spec §1, §3.5)
// ---------------------------------------------------------------------------

export const SUPPLY_PER_RESOURCE = 20;
/** Reserve pile: this many of each of the 5 types, shuffled face down (40 cards). */
export const RESERVE_PILE_PER_RESOURCE = 8;
export const STARTING_HAND_SIZE = 3;
export const STARTING_FAME_PIECES = 1;
export const STARTING_BOOSTERS = 1;

export const UPGRADES_TRAY_TOTAL = {
  freightPods: 20,
  cannons: 24,
  boosters: 24,
  famePieces: 40,
} as const;

/** Player pieces per colour (spec §1). */
export const PIECE_LIMITS = {
  colonies: 9,
  tradeStations: 7,
  transportShips: 3,
  shipyards: 3,
} as const;

/** Max ships on the board = number of transports. */
export const MAX_SHIPS_ON_BOARD = PIECE_LIMITS.transportShips;

export const UPGRADE_CAPS: Readonly<Record<UpgradeKind, number>> = {
  booster: 6,
  cannon: 6,
  freightPod: 5,
};

// ---------------------------------------------------------------------------
// Build costs (spec §7.2)
// ---------------------------------------------------------------------------

export const BUILD_COSTS: Readonly<Record<'colonyShip' | 'tradeShip' | 'spaceport' | UpgradeKind, ResourceBag>> = {
  colonyShip: { ore: 1, fuel: 1, carbon: 1, food: 1 },
  tradeShip: { ore: 1, fuel: 1, goods: 2 },
  spaceport: { carbon: 3, food: 2 },
  booster: { fuel: 2 },
  cannon: { carbon: 2 },
  freightPod: { ore: 2 },
};

/** Trade with the supply (spec §7.1). */
export const SUPPLY_TRADE = {
  /** N identical cards → 1 of any type. */
  identicalForOne: 3,
  /** N goods → 1 of any type. */
  goodsForOne: 2,
  /** Merchants friendship card: 2 of the named resource → 1 any. */
  merchantsRate: 2,
} as const;

// ---------------------------------------------------------------------------
// Mothership (spec §1 "Ball values", §9.1)
// ---------------------------------------------------------------------------

export type Ball = 'yellow' | 'red' | 'blue' | 'black';

export const MOTHERSHIP_BALLS: readonly Ball[] = ['yellow', 'yellow', 'red', 'blue', 'black'];

export const BALL_VALUES: Readonly<Record<Ball, number>> = {
  blue: 1,
  yellow: 2,
  red: 3,
  black: 0,
};

/** Base speed when a black ball is drawn (an encounter follows). */
export const BLACK_BALL_BASE_SPEED = 3;
/** Balls revealed per shake. */
export const BALLS_PER_SHAKE = 2;

// ---------------------------------------------------------------------------
// Flight / outposts / tokens (spec §9)
// ---------------------------------------------------------------------------

export const MAX_STATIONS_PER_OUTPOST = 5;
/** 3-player game: max colonies that may be founded per unexplored planetary system. */
export const MAX_COLONIES_PER_SYSTEM_3P = 2;
export const PIRATE_BASE_TOKENS: readonly number[] = [4, 5, 6];
export const ICE_PLANET_TOKENS: readonly number[] = [3, 4];
/** Fame pieces per VP (VP = floor(pieces / FAME_PIECES_PER_VP)). */
export const FAME_PIECES_PER_VP = 2;
export const FRIENDSHIP_MARKER_VP = 2;
export const ENCOUNTER_CARD_COUNT = 32;

// ---------------------------------------------------------------------------
// Inferred / [VERIFY] items (spec §16)
// ---------------------------------------------------------------------------

/**
 * **[VERIFY]** Tile star backs (1-star → near slots, 2-star → far slots in the
 * strategic set-up). The values live in `layouts/board.json` → `sectors[*].stars`
 * and are INFERRED from the beginner picture, not read off the physical tiles.
 * Nothing in the beginner set-up depends on them.
 */
export const TILE_STARS_SOURCE = 'layouts/board.json#sectors[*].stars (inferred, see spec §16.1)';

/**
 * **[VERIFY]** Shake-result bands for encounter cards 12–15 (spec §10). A shake
 * inside an encounter sums two balls with black = 0, so totals are 1–5.
 * Default mapping: low total = bad, high = good.
 */
export const ENCOUNTER_SHAKE_BANDS: Readonly<Record<'low' | 'mid' | 'high', readonly number[]>> = {
  low: [1, 2],
  mid: [3],
  high: [4, 5],
};

export function shakeBand(total: number): 'low' | 'mid' | 'high' {
  if (ENCOUNTER_SHAKE_BANDS.low.includes(total)) return 'low';
  if (ENCOUNTER_SHAKE_BANDS.mid.includes(total)) return 'mid';
  return 'high';
}

/**
 * **[VERIFY]** Travelers cards 28–30 (donation 0–3): which donations map to which
 * branch. Spec §10 lists "1: +1 fame, 2: +1 fame, 3: ..." for 28 and "1–2: +1 fame"
 * for 29/30; the exact split between 1 and 2 could not be read off the cards.
 * Keyed by donation amount → branch name used by the encounter data.
 */
export const TRAVELERS_DONATION_BRANCHES: Readonly<Record<28 | 29 | 30, Readonly<Record<0 | 1 | 2 | 3, string>>>> = {
  28: { 0: 'removeUpgradeLoseFame', 1: 'gainFame', 2: 'gainFame', 3: 'spaceJump' },
  29: { 0: 'nothing', 1: 'gainFame', 2: 'gainFame', 3: 'freeTradeShip' },
  30: { 0: 'loseFame', 1: 'gainFame', 2: 'gainFame', 3: 'spaceJumpAndFame' },
};

/**
 * **[VERIFY]** Beginner starting colony-ship sites. `layouts/beginner.json` →
 * `startingPieces[color].spaceport.shipSide` names the planet hex whose outer
 * edge holds the ship. Read from a small picture (spec §16.3); either of the two
 * spaceport sites is legal, so a mistake does not change play. The loader uses
 * the JSON value; this flag only documents that the data is unverified.
 */
export const BEGINNER_SHIP_SIDE_VERIFIED = false;

// ---------------------------------------------------------------------------
// Friendship cards (spec §8) — static catalogue
// ---------------------------------------------------------------------------

export type FriendshipEffect =
  | { kind: 'productionIncrease'; resource: Resource }
  | { kind: 'combatBonus'; combat: number; speed: number }
  | { kind: 'reducedTribute' }
  | { kind: 'fameForSale' }
  | { kind: 'helpingHand' }
  | { kind: 'galacticReliefFund' }
  | { kind: 'merchant2for1'; resource: Resource }
  | { kind: 'merchant1for1'; resource: Resource };

export interface FriendshipCardDef {
  id: FriendshipCardId;
  civ: Civ;
  name: string;
  effect: FriendshipEffect;
}

export const FRIENDSHIP_CARDS: Readonly<Record<FriendshipCardId, FriendshipCardDef>> = {
  axxa: { id: 'axxa', civ: 'greenFolk', name: 'Axxa', effect: { kind: 'productionIncrease', resource: 'fuel' } },
  xulu: { id: 'xulu', civ: 'greenFolk', name: 'Xulu', effect: { kind: 'productionIncrease', resource: 'carbon' } },
  asox: { id: 'asox', civ: 'greenFolk', name: 'Asox', effect: { kind: 'productionIncrease', resource: 'ore' } },
  esox: { id: 'esox', civ: 'greenFolk', name: 'Esox', effect: { kind: 'productionIncrease', resource: 'food' } },
  xom: { id: 'xom', civ: 'greenFolk', name: 'Xom', effect: { kind: 'productionIncrease', resource: 'goods' } },

  khaStar: { id: 'khaStar', civ: 'scientists', name: 'Kha-Star', effect: { kind: 'combatBonus', combat: 2, speed: 0 } },
  hirAkas: { id: 'hirAkas', civ: 'scientists', name: 'Hir-Akas', effect: { kind: 'combatBonus', combat: 0, speed: 2 } },
  khorNem: { id: 'khorNem', civ: 'scientists', name: 'Khor-Nem', effect: { kind: 'combatBonus', combat: 1, speed: 1 } },
  hirSto: { id: 'hirSto', civ: 'scientists', name: 'Hir-Sto', effect: { kind: 'combatBonus', combat: 1, speed: 1 } },
  asaBar: { id: 'asaBar', civ: 'scientists', name: 'Asa-Bar', effect: { kind: 'combatBonus', combat: 1, speed: 1 } },

  raHal: { id: 'raHal', civ: 'diplomats', name: "Ra'Hal — Reduced Tribute", effect: { kind: 'reducedTribute' } },
  reBah: { id: 'reBah', civ: 'diplomats', name: "Re'Bah — Fame for Sale", effect: { kind: 'fameForSale' } },
  reOhm: { id: 'reOhm', civ: 'diplomats', name: "Re'Ohm — Fame for Sale", effect: { kind: 'fameForSale' } },
  raHna: { id: 'raHna', civ: 'diplomats', name: "Ra'Hna — A Helping Hand", effect: { kind: 'helpingHand' } },
  raHno: { id: 'raHno', civ: 'diplomats', name: "Ra'Hno — Galactic Relief Fund", effect: { kind: 'galacticReliefFund' } },

  zuzzo: { id: 'zuzzo', civ: 'merchants', name: 'Zuzzo', effect: { kind: 'merchant2for1', resource: 'carbon' } },
  orzel: { id: 'orzel', civ: 'merchants', name: 'Orzel', effect: { kind: 'merchant2for1', resource: 'food' } },
  crizzetu: { id: 'crizzetu', civ: 'merchants', name: 'Crizzetu', effect: { kind: 'merchant2for1', resource: 'ore' } },
  utuzzo: { id: 'utuzzo', civ: 'merchants', name: 'Utuzzo', effect: { kind: 'merchant2for1', resource: 'fuel' } },
  ezzel: { id: 'ezzel', civ: 'merchants', name: 'Ezzel', effect: { kind: 'merchant1for1', resource: 'goods' } },
};

export function friendshipCardsOf(civ: Civ): FriendshipCardId[] {
  return (Object.values(FRIENDSHIP_CARDS) as FriendshipCardDef[]).filter((c) => c.civ === civ).map((c) => c.id);
}
