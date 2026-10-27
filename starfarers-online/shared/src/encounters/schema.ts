/**
 * Encounter card schema (spec §10). Cards are pure DATA (`cards.ts`); the
 * interpreter in `engine.ts` applies `EncounterEffect`s from a resumable queue
 * and stops whenever a player has to pick something (`EncounterPickRequest`).
 *
 * Effect vocabulary (the "small enum" of §10):
 *   gainResource        receive N of a type, or N of the receiver's choice ('any' → pick 'resources')
 *   gainFame / loseFame fame-medal pieces from / to the tray (never below 0)
 *   gainUpgrade         a booster / cannon / freight pod ('any' → pick 'upgradeKind'); no effect
 *                       when the cap is reached or the tray is empty
 *   removeUpgrade       the player removes 1 physical upgrade of their choice (pick 'removeUpgrade');
 *                       no effect without upgrades; Scientist cards never count
 *   immobilizeShip      "one ship cannot move this turn": the player picks which (pick 'immobilizeShip')
 *   freeTradeShip       found/freeTradeShip.ts `grantFreeTradeShip` (ship now, or a marker)
 *   spaceJump           pick a ship + target (pick 'spaceJump'); may be declined
 *   stealRandomFromAll  1 random card from every opponent holding one (`rng.int`)
 *   everyoneGivesOne    every opponent hands over 1 card of THEIR choice; expands into one
 *                       `giveOne` per opponent holding a card (pick 'giveOne' for THAT player)
 *   giveOne             internal: the player it is queued for gives the active player 1 card of their choice
 *   payResources        the player pays N cards of their choice to the supply (pick 'payResources')
 *   loseOffer           nothing happens (the offer is already in the supply)
 *   returnOffer         the offer paid for this card comes back
 *   redraw              discard this card and start over with the next one;
 *                       `reshuffle` = deck + discard + this card are reshuffled first (cards 31/32)
 *   contest             combat / speed race against the named opponent; both shake
 *   flee                compare race booster counts (no shake); `escaped` or `caught`
 *   tradeOneForTwo      hand 1 card to the supply, receive 2 of your choice (cards 12/13)
 *   confiscateTrade     the 2 cards received through `tradeOneForTwo` are taken away again
 *   shakeTable          one shake, total → band (config `shakeBand`) → that band's effects
 *   wearAndTear         every player with MORE than `threshold` upgrades removes 1 (turn order from the active player)
 *   galacticCouncil     every player tied for the most freight pods (≥ 1) gains 1 fame
 */

import type { NodeId, PlayerId, Resource, ShipId, UpgradeKind } from '../types.js';
import type { Ball } from '../config.js';

/** Relative seat of the opponent named on a card: (2nd) player to the left / right. */
export type EncounterOpponent = 'L' | 'R' | 'LL' | 'RR';
export const ENCOUNTER_OPPONENTS: readonly EncounterOpponent[] = ['L', 'R', 'LL', 'RR'];

export type ContestKind = 'combat' | 'speed';

export type EncounterEffect =
  | { type: 'gainResource'; resource: Resource | 'any'; count: number }
  | { type: 'gainFame'; count: number }
  | { type: 'loseFame'; count: number }
  | { type: 'gainUpgrade'; kind: UpgradeKind | 'any' }
  | { type: 'removeUpgrade' }
  | { type: 'immobilizeShip' }
  | { type: 'freeTradeShip' }
  | { type: 'spaceJump' }
  | { type: 'stealRandomFromAll' }
  | { type: 'everyoneGivesOne' }
  | { type: 'giveOne' }
  | { type: 'payResources'; count: number }
  | { type: 'loseOffer' }
  | { type: 'returnOffer' }
  | { type: 'redraw'; reshuffle?: boolean }
  | { type: 'contest'; kind: ContestKind; opponent: EncounterOpponent; win: EncounterEffect[]; lose: EncounterEffect[] }
  | { type: 'flee'; opponent: EncounterOpponent; escaped: EncounterEffect[]; caught: EncounterEffect[] }
  | { type: 'tradeOneForTwo' }
  | { type: 'confiscateTrade' }
  | { type: 'shakeTable'; low: EncounterEffect[]; mid: EncounterEffect[]; high: EncounterEffect[] }
  | { type: 'wearAndTear'; threshold: number }
  | { type: 'galacticCouncil' };

export type EncounterEffectType = EncounterEffect['type'];

/**
 * How the active player answers the card:
 *   offer0to3      choose an offer of 0–3 cards (branches '0'…'3')
 *   yesno          yes / no (branches 'yes' / 'no')
 *   offerThenYesno offer 0–3 first, THEN yes / no (cards 7/8: "the merchant is a pirate — attack?")
 *   none           no choice at all (cards 31/32); the single branch is 'auto'
 */
export type EncounterChoiceKind = 'offer0to3' | 'yesno' | 'offerThenYesno' | 'none';

export const OFFER_BRANCH_KEYS = ['0', '1', '2', '3'] as const;
export const YESNO_BRANCH_KEYS = ['yes', 'no'] as const;
export const AUTO_BRANCH_KEY = 'auto';
export const MAX_OFFER = 3;

export interface EncounterBranch {
  /** Text box revealed when this branch is chosen (before its effects resolve). */
  text: string;
  effects: EncounterEffect[];
}

export interface EncounterCard {
  id: number;
  title: string;
  /** Original paraphrase of the situation, revealed when the card is drawn. */
  prompt: string;
  choice: EncounterChoiceKind;
  branches: Record<string, EncounterBranch>;
}

/** Branch keys a card of the given choice kind must define. */
export function requiredBranchKeys(choice: EncounterChoiceKind): readonly string[] {
  switch (choice) {
    case 'offer0to3':
      return OFFER_BRANCH_KEYS;
    case 'yesno':
    case 'offerThenYesno':
      return YESNO_BRANCH_KEYS;
    case 'none':
      return [AUTO_BRANCH_KEY];
  }
}

// ---------------------------------------------------------------------------
// Runtime context (lives in `state.turn.encounter`)
// ---------------------------------------------------------------------------

export type EncounterStage = 'choice' | 'resolving' | 'done';

export type EncounterPickKind =
  | 'resources'
  | 'payResources'
  | 'giveOne'
  | 'upgradeKind'
  | 'removeUpgrade'
  | 'immobilizeShip'
  | 'spaceJump';

/**
 * Something a player must decide before the queue can continue. Answered with
 * `encounterPick` sent by `playerId` (who is NOT always the active player):
 *   resources       `resources: Resource[count]` taken from the supply
 *   payResources    `resources: Resource[count]` handed from the hand to the supply
 *   giveOne         `resources: [Resource]` handed from the opponent's hand to the active player
 *   upgradeKind     `upgrade: UpgradeKind` (one of `options`) placed on the mothership
 *   removeUpgrade   `upgrade: UpgradeKind` (one of `options`) returned to the tray
 *   immobilizeShip  `shipId` (one of `options`) that may not move this turn
 *   spaceJump       `shipId` + `targetNodeId`, or `decline: true`
 */
export interface EncounterPickRequest {
  kind: EncounterPickKind;
  playerId: PlayerId;
  /** The effect waiting for this answer (e.g. `tradeOneForTwo` asks to pay 1, then to receive 2). */
  effect: EncounterEffect;
  /** resources / payResources / giveOne: how many cards. */
  count?: number;
  /** Legal values for single-choice picks (upgrade kinds or ship ids), for clients. */
  options?: string[];
}

export interface QueuedEffect {
  playerId: PlayerId;
  effect: EncounterEffect;
}

export interface ShakeSide {
  playerId: PlayerId;
  balls: Ball[];
  /** Ball sum (black = 0). */
  total: number;
  /** Cannons (+ Scientist combat) or boosters (+ Scientist speed). */
  bonus: number;
  /** total + bonus. */
  strength: number;
}

export interface ContestResult {
  kind: ContestKind;
  yours: ShakeSide;
  theirs: ShakeSide;
  /** `yours.strength >= theirs.strength`. */
  won: boolean;
}

export interface FleeResult {
  opponent: PlayerId;
  yours: number;
  theirs: number;
  escaped: boolean;
}

export interface TableShake {
  balls: Ball[];
  total: number;
  band: 'low' | 'mid' | 'high';
}

export interface EncounterCtx {
  cardId: number;
  stage: EncounterStage;
  /** Branch key chosen ('yes' / 'no' / '0'…'3' / 'auto'). */
  choice?: string;
  /** Cards paid to the supply as the offer, before the result was revealed. */
  offerPaid?: Resource[];
  /** Text boxes revealed so far, in order (prompt, branch text, results…). */
  revealed: string[];
  /** Set while the queue waits for a player's decision. */
  awaiting?: EncounterPickRequest;
  /** Effects still to apply, each with the player it applies to. */
  queue: QueuedEffect[];
  contestResults?: ContestResult[];
  fleeResults?: FleeResult[];
  tableShakes?: TableShake[];
  /** Cards received through `tradeOneForTwo` (what `confiscateTrade` takes back). */
  tradeReceived?: Resource[];
  /** Ship immobilized / jumped by this encounter (informational). */
  immobilizedShip?: ShipId;
  jumpedTo?: { shipId: ShipId; nodeId: NodeId };
}
