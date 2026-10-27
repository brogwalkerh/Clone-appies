/**
 * The 32 encounter cards as data (spec §10). Prompts and branch texts are
 * original paraphrases written for Starfarers Online — nothing is copied from
 * the physical cards and no product branding appears.
 *
 * Mechanics that the spec marks **[VERIFY]** are not repeated here:
 *   - the shake-result bands of cards 12–15 come from `shakeBand` (config.ts),
 *     the card data only names what happens per band;
 *   - the donation → branch split of cards 28–30 comes from
 *     `TRAVELERS_DONATION_BRANCHES` (config.ts);
 *   - the "Wear and Tear" thresholds come from `WEAR_AND_TEAR_THRESHOLDS`.
 */

import { TRAVELERS_DONATION_BRANCHES, WEAR_AND_TEAR_THRESHOLDS } from '../config.js';
import type { Resource, UpgradeKind } from '../types.js';
import type { EncounterBranch, EncounterCard, EncounterEffect, EncounterOpponent } from './schema.js';

// ---------------------------------------------------------------------------
// Tiny constructors so the table below stays readable (they only build objects)
// ---------------------------------------------------------------------------

const gain = (resource: Resource | 'any', count = 1): EncounterEffect => ({ type: 'gainResource', resource, count });
const fame = (count = 1): EncounterEffect => ({ type: 'gainFame', count });
const loseFame = (count = 1): EncounterEffect => ({ type: 'loseFame', count });
const upgrade = (kind: UpgradeKind | 'any' = 'any'): EncounterEffect => ({ type: 'gainUpgrade', kind });
const removeUpgrade: EncounterEffect = { type: 'removeUpgrade' };
const immobilize: EncounterEffect = { type: 'immobilizeShip' };
const freeTradeShip: EncounterEffect = { type: 'freeTradeShip' };
const spaceJump: EncounterEffect = { type: 'spaceJump' };
const stealFromAll: EncounterEffect = { type: 'stealRandomFromAll' };
const everyoneGivesOne: EncounterEffect = { type: 'everyoneGivesOne' };
const pay = (count: number): EncounterEffect => ({ type: 'payResources', count });
const loseOffer: EncounterEffect = { type: 'loseOffer' };
const returnOffer: EncounterEffect = { type: 'returnOffer' };
const redraw: EncounterEffect = { type: 'redraw' };
const reshuffleAndRedraw: EncounterEffect = { type: 'redraw', reshuffle: true };
const fight = (opponent: EncounterOpponent, win: EncounterEffect[], lose: EncounterEffect[]): EncounterEffect => ({
  type: 'contest',
  kind: 'combat',
  opponent,
  win,
  lose,
});
const race = (opponent: EncounterOpponent, win: EncounterEffect[], lose: EncounterEffect[]): EncounterEffect => ({
  type: 'contest',
  kind: 'speed',
  opponent,
  win,
  lose,
});
const flee = (opponent: EncounterOpponent, escaped: EncounterEffect[], caught: EncounterEffect[]): EncounterEffect => ({
  type: 'flee',
  opponent,
  escaped,
  caught,
});
const tradeOneForTwo: EncounterEffect = { type: 'tradeOneForTwo' };
const confiscateTrade: EncounterEffect = { type: 'confiscateTrade' };
const shakeTable = (low: EncounterEffect[], mid: EncounterEffect[], high: EncounterEffect[]): EncounterEffect => ({
  type: 'shakeTable',
  low,
  mid,
  high,
});

const br = (text: string, ...effects: EncounterEffect[]): EncounterBranch => ({ text, effects });

const SEAT: Readonly<Record<EncounterOpponent, string>> = {
  L: 'the player to your left',
  R: 'the player to your right',
  LL: 'the second player to your left',
  RR: 'the second player to your right',
};

// ---------------------------------------------------------------------------
// Shared text for repeated situations
// ---------------------------------------------------------------------------

const MERCHANT_PROMPT =
  'A trading vessel hails you and asks whether you have anything to spare for its crew. How many cards do you offer (0–3)? Whatever you give goes to the supply before you learn how they react.';
const PRINCE_PROMPT =
  'A lavish yacht belonging to a merchant prince drifts alongside. His steward expects a tribute. How many cards do you offer (0–3)? The gift is handed over before the prince shows his hand.';
const DISGUISE_PROMPT =
  'A friendly trader asks for a small gift (0–3 cards, paid to the supply at once). The moment the cards change hands, the "trader" drops the pretence: it is a pirate. Do you attack?';
const PIRATE_DEMAND_PROMPT =
  'A pirate cruiser blocks your route and demands 2 resource cards as toll. Do you surrender the cards?';
const SMUGGLER_PROMPT =
  'A smuggler offers a deal: hand over 1 card and receive 2 of your choice from the supply. The goods are hot, though — afterwards you shake to see whether the patrol notices. Accept?';
const RAIDER_PROMPT =
  'A pirate captain offers to raid your rivals on your behalf for a fee of 1 card. After paying you shake to see how honest the pirate is. Accept?';
const ATTACK_PROMPT = 'Pirates swoop in with guns charged. Do you try to flee (boosters decide), or do you stand and fight?';
const DISTRESS_PROMPT =
  'A distress beacon crackles over the comm. Reaching it in time is a race against another ship. Do you respond?';
const RESCUE_PROMPT = 'A merchant ship is under pirate attack and begs for help. Do you move in to rescue it?';
const WORMHOLE_PROMPT =
  'Sensors pick up an unstable wormhole. Riding it is a race against the player named on the card. Do you attempt the jump?';
const TRAVELERS_PROMPT =
  'A caravan of wandering travelers crosses your path and asks for a donation. How many cards do you give (0–3)? They are handed over before you see the travelers\' response.';

const fightText = (opponent: EncounterOpponent): string =>
  `Both you and ${SEAT[opponent]} shake and add your cannons. You win ties.`;
const raceText = (opponent: EncounterOpponent): string =>
  `Both you and ${SEAT[opponent]} shake and add your boosters. You win ties.`;
const fleeText = (opponent: EncounterOpponent): string =>
  `You run. If your boosters match or beat those of ${SEAT[opponent]} you get away; otherwise the fight is on.`;

// ---------------------------------------------------------------------------
// Smuggler / raider shake tables (bands from config `shakeBand`)
// ---------------------------------------------------------------------------

const SMUGGLER_TABLE = shakeTable(
  [confiscateTrade, loseFame()], // low: the patrol confiscates the 2 cards and you lose 1 fame
  [loseFame()], // mid: accused of smuggling — lose 1 fame
  [], // high: a quiet voyage
);
const RAIDER_TABLE = shakeTable(
  [loseFame()], // low: the pirate cheats you
  [stealFromAll, loseFame()], // mid: the raid works but word gets out
  [stealFromAll], // high: a clean raid
);

// ---------------------------------------------------------------------------
// Travelers (cards 28–30): branch effects by the names used in config
// ---------------------------------------------------------------------------

const TRAVELERS_OUTCOMES: Readonly<Record<string, EncounterBranch>> = {
  nothing: br('The travelers shrug and move on. Nothing happens.'),
  loseFame: br('The travelers spread word of your stinginess. Lose 1 fame piece.', loseFame()),
  removeUpgradeLoseFame: br(
    'Offended, the travelers sabotage your mothership before leaving. Remove 1 upgrade and lose 1 fame piece.',
    removeUpgrade,
    loseFame(),
  ),
  gainFame: br('The travelers thank you warmly. Gain 1 fame piece.', fame()),
  spaceJump: br('In gratitude the travelers share a star chart: one of your ships may make a space jump.', spaceJump),
  spaceJumpAndFame: br(
    'Overwhelmed by your generosity, the travelers share a star chart and sing your praises. One ship may space-jump and you gain 1 fame piece.',
    spaceJump,
    fame(),
  ),
  freeTradeShip: br(
    'The travelers gift you a vessel: place 1 trade ship next to one of your spaceports as soon as possible.',
    freeTradeShip,
  ),
};

function travelersCard(id: 28 | 29 | 30, title: string): EncounterCard {
  const split = TRAVELERS_DONATION_BRANCHES[id];
  const branches: Record<string, EncounterBranch> = {};
  for (const amount of [0, 1, 2, 3] as const) {
    const name = split[amount];
    const outcome = TRAVELERS_OUTCOMES[name];
    if (!outcome) throw new Error(`cards.ts: unknown travelers outcome '${name}' for card ${id}`);
    branches[String(amount)] = outcome;
  }
  return { id, title, prompt: TRAVELERS_PROMPT, choice: 'offer0to3', branches };
}

// ---------------------------------------------------------------------------
// The deck
// ---------------------------------------------------------------------------

export const ENCOUNTER_CARDS: readonly EncounterCard[] = [
  {
    id: 1,
    title: 'Hungry traders',
    prompt: MERCHANT_PROMPT,
    choice: 'offer0to3',
    branches: {
      '0': br(
        'The crew is appalled. Every other player hands you 1 card of their choice out of pity, and you lose 2 fame pieces.',
        everyoneGivesOne,
        loseFame(2),
      ),
      '1': br('A meagre gift. They toss you 1 food in return, but you lose 1 fame piece.', gain('food'), loseFame()),
      '2': br('A fair gift. Take 1 resource of your choice and gain 1 fame piece.', gain('any'), fame()),
      '3': br('A generous gift. Take 2 resources of your choice and gain 1 fame piece.', gain('any', 2), fame()),
    },
  },
  {
    id: 2,
    title: 'Trading post in orbit',
    prompt: MERCHANT_PROMPT,
    choice: 'offer0to3',
    branches: {
      '0': br('The traders leave empty-handed and spread the word. Lose 1 fame piece.', loseFame()),
      '1': br('A small thank-you: take 1 resource of your choice.', gain('any')),
      '2': br('Take 1 resource of your choice and gain 1 fame piece.', gain('any'), fame()),
      '3': br('The traders fit a spare part to your mothership: take 1 upgrade of your choice and gain 1 fame piece.', upgrade(), fame()),
    },
  },
  {
    id: 3,
    title: 'Drifting freighter',
    prompt: MERCHANT_PROMPT,
    choice: 'offer0to3',
    branches: {
      '0': br('The freighter crew curses your name. Lose 1 fame piece.', loseFame()),
      '1': br('A nod of thanks. Nothing else happens.'),
      '2': br('Word of your help spreads. Gain 1 fame piece.', fame()),
      '3': br('The grateful crew pays you back with 1 goods, and you gain 1 fame piece.', gain('goods'), fame()),
    },
  },
  {
    id: 4,
    title: 'Proud merchants',
    prompt: MERCHANT_PROMPT,
    choice: 'offer0to3',
    branches: {
      '0': br('The merchants wanted nothing from you anyway. Nothing changes.', returnOffer),
      '1': br('The merchants return the favour with 1 goods.', gain('goods')),
      '2': br('Take 1 resource of your choice and gain 1 fame piece.', gain('any'), fame()),
      '3': br('Take 2 resources of your choice and gain 1 fame piece.', gain('any', 2), fame()),
    },
  },
  {
    id: 5,
    title: 'The merchant prince',
    prompt: PRINCE_PROMPT,
    choice: 'offer0to3',
    branches: {
      '0': br('Insulted, the prince has his escort pin one of your ships in place: it cannot move this turn. Lose 1 fame piece.', immobilize, loseFame()),
      '1': br('The prince sneers at the paltry gift. Lose 1 fame piece.', loseFame()),
      '2': br('The prince is pleased. Take 1 resource of your choice and gain 1 fame piece.', gain('any'), fame()),
      '3': br('The prince is delighted and gifts you a vessel: place 1 trade ship next to one of your spaceports as soon as possible.', freeTradeShip),
    },
  },
  {
    id: 6,
    title: 'Court of the merchant prince',
    prompt: PRINCE_PROMPT,
    choice: 'offer0to3',
    branches: {
      '0': br('The prince\'s escort holds one of your ships: it cannot move this turn. Lose 1 fame piece.', immobilize, loseFame()),
      '1': br('A disappointing tribute. Lose 1 fame piece.', loseFame()),
      '2': br('Take 1 resource of your choice and gain 1 fame piece.', gain('any'), fame()),
      '3': br('The prince rewards you with a vessel: place 1 trade ship next to one of your spaceports as soon as possible.', freeTradeShip),
    },
  },
  {
    id: 7,
    title: 'Pirate in disguise',
    prompt: DISGUISE_PROMPT,
    choice: 'offerThenYesno',
    branches: {
      no: br('You let the pirate go. Your gift is gone for good.', loseOffer),
      yes: br(
        `${fightText('R')} Win: you recover your gift and gain 1 fame piece. Lose: the gift is lost and one of your ships cannot move this turn.`,
        fight('R', [returnOffer, fame()], [loseOffer, immobilize]),
      ),
    },
  },
  {
    id: 8,
    title: 'Wolf in trader\'s clothing',
    prompt: DISGUISE_PROMPT,
    choice: 'offerThenYesno',
    branches: {
      no: br('You let the pirate go. Your gift is gone for good.', loseOffer),
      yes: br(
        `${fightText('L')} Win: you recover your gift and gain 1 fame piece. Lose: the gift is lost and one of your ships cannot move this turn.`,
        fight('L', [returnOffer, fame()], [loseOffer, immobilize]),
      ),
    },
  },
  {
    id: 9,
    title: 'Toll collectors',
    prompt: PIRATE_DEMAND_PROMPT,
    choice: 'yesno',
    branches: {
      yes: br('You hand over 2 cards of your choice. The pirate thanks you politely and lets you pass.', pay(2)),
      no: br(
        `${fightText('R')} Win: the pirate flees and leaves a vessel behind — place 1 trade ship next to one of your spaceports as soon as possible. Lose: remove 1 upgrade, but your courage earns 1 fame piece.`,
        fight('R', [freeTradeShip], [removeUpgrade, fame()]),
      ),
    },
  },
  {
    id: 10,
    title: 'Blockade runners',
    prompt: PIRATE_DEMAND_PROMPT,
    choice: 'yesno',
    branches: {
      yes: br('You pay 2 cards of your choice. Word of your meekness spreads: lose 1 fame piece.', pay(2), loseFame()),
      no: br(
        `${fightText('RR')} Win: salvage 2 carbon from the wreck and gain 1 fame piece. Lose: one of your ships cannot move this turn, but you gain 1 fame piece for standing firm.`,
        fight('RR', [gain('carbon', 2), fame()], [immobilize, fame()]),
      ),
    },
  },
  {
    id: 11,
    title: 'Ambush at the nebula',
    prompt: PIRATE_DEMAND_PROMPT,
    choice: 'yesno',
    branches: {
      yes: br('You pay 2 cards of your choice, and the pirates still clamp one of your ships: it cannot move this turn.', pay(2), immobilize),
      no: br(
        `${fightText('L')} Win: salvage 2 ore and gain 1 fame piece. Lose: remove 1 upgrade.`,
        fight('L', [gain('ore', 2), fame()], [removeUpgrade]),
      ),
    },
  },
  {
    id: 12,
    title: 'Smuggler\'s bargain',
    prompt: SMUGGLER_PROMPT,
    choice: 'yesno',
    branches: {
      no: br('You refuse the shady deal. Gain 1 fame piece.', fame()),
      yes: br(
        'You hand over 1 card and take 2 of your choice. Then shake: a low total means the patrol confiscates the 2 cards and you lose 1 fame piece; a middle total means you are accused and lose 1 fame piece; a high total means a quiet voyage.',
        tradeOneForTwo,
        SMUGGLER_TABLE,
      ),
    },
  },
  {
    id: 13,
    title: 'Back-alley trade',
    prompt: SMUGGLER_PROMPT,
    choice: 'yesno',
    branches: {
      no: br('You decline. Nothing happens.'),
      yes: br(
        'You hand over 1 card and take 2 of your choice. Then shake: a low total means the patrol confiscates the 2 cards and you lose 1 fame piece; a middle total means you are accused and lose 1 fame piece; a high total means a quiet voyage.',
        tradeOneForTwo,
        SMUGGLER_TABLE,
      ),
    },
  },
  {
    id: 14,
    title: 'Pirate for hire',
    prompt: RAIDER_PROMPT,
    choice: 'yesno',
    branches: {
      no: br('You refuse to deal with pirates. Gain 1 fame piece.', fame()),
      yes: br(
        'You pay 1 card of your choice. Then shake: a low total means the pirate cheats you and you lose 1 fame piece; a middle total means you take 1 random card from each opponent but lose 1 fame piece; a high total means you take 1 random card from each opponent.',
        pay(1),
        RAIDER_TABLE,
      ),
    },
  },
  {
    id: 15,
    title: 'A raid on credit',
    prompt: RAIDER_PROMPT,
    choice: 'yesno',
    branches: {
      no: br('You decline. Nothing happens.'),
      yes: br(
        'You pay 1 card of your choice. Then shake: a low total means the pirate cheats you and you lose 1 fame piece; a middle total means you take 1 random card from each opponent but lose 1 fame piece; a high total means you take 1 random card from each opponent.',
        pay(1),
        RAIDER_TABLE,
      ),
    },
  },
  {
    id: 16,
    title: 'Pirate raid',
    prompt: ATTACK_PROMPT,
    choice: 'yesno',
    branches: {
      yes: br(
        `${fleeText('R')} If caught: ${fightText('R')} Win: take 1 upgrade of your choice and gain 1 fame piece. Lose: remove 1 upgrade.`,
        flee('R', [], [fight('R', [upgrade(), fame()], [removeUpgrade])]),
      ),
      no: br(
        `${fightText('R')} Win: take 1 upgrade of your choice and gain 1 fame piece. Lose: remove 1 upgrade.`,
        fight('R', [upgrade(), fame()], [removeUpgrade]),
      ),
    },
  },
  {
    id: 17,
    title: 'Corsairs',
    prompt: ATTACK_PROMPT,
    choice: 'yesno',
    branches: {
      yes: br(
        `${fleeText('LL')} Escaping costs you 1 fame piece. If caught: ${fightText('LL')} Win: salvage 2 ore and gain 1 fame piece. Lose: remove 1 upgrade, but gain 1 fame piece.`,
        flee('LL', [loseFame()], [fight('LL', [gain('ore', 2), fame()], [removeUpgrade, fame()])]),
      ),
      no: br(
        `${fightText('LL')} Win: salvage 2 ore and gain 1 fame piece. Lose: remove 1 upgrade, but gain 1 fame piece.`,
        fight('LL', [gain('ore', 2), fame()], [removeUpgrade, fame()]),
      ),
    },
  },
  {
    id: 18,
    title: 'Boarding party',
    prompt: ATTACK_PROMPT,
    choice: 'yesno',
    branches: {
      yes: br(
        `${fleeText('L')} If caught: ${fightText('L')} Win: capture the pirate vessel — place 1 trade ship next to one of your spaceports as soon as possible. Lose: one of your ships cannot move this turn.`,
        flee('L', [], [fight('L', [freeTradeShip], [immobilize])]),
      ),
      no: br(
        `${fightText('L')} Win: capture the pirate vessel — place 1 trade ship next to one of your spaceports as soon as possible. Lose: one of your ships cannot move this turn.`,
        fight('L', [freeTradeShip], [immobilize]),
      ),
    },
  },
  {
    id: 19,
    title: 'Mayday',
    prompt: DISTRESS_PROMPT,
    choice: 'yesno',
    branches: {
      no: br('You ignore the call. The stricken ship is lost. Nothing happens to you.'),
      yes: br(
        `${raceText('RR')} Win: the rescued crew gives you their ship — place 1 trade ship next to one of your spaceports as soon as possible. Lose: you arrive too late and the strain costs you 1 upgrade.`,
        race('RR', [freeTradeShip], [removeUpgrade]),
      ),
    },
  },
  {
    id: 20,
    title: 'Diplomat in distress',
    prompt: DISTRESS_PROMPT,
    choice: 'yesno',
    branches: {
      no: br('You turn away from a stranded diplomat. Lose 1 fame piece.', loseFame()),
      yes: br(
        `${raceText('L')} Win: gain 1 fame piece and the grateful diplomat has every opponent hand you 1 random card. Lose: remove 1 upgrade, but gain 1 fame piece for trying.`,
        race('L', [fame(), stealFromAll], [removeUpgrade, fame()]),
      ),
    },
  },
  {
    id: 21,
    title: 'Engineer adrift',
    prompt: DISTRESS_PROMPT,
    choice: 'yesno',
    branches: {
      no: br('You leave the engineer to her fate. Lose 1 fame piece.', loseFame()),
      yes: br(
        `${raceText('R')} Win: the rescued engineer fits 1 upgrade of your choice and you gain 1 fame piece. Lose: remove 1 upgrade.`,
        race('R', [upgrade(), fame()], [removeUpgrade]),
      ),
    },
  },
  {
    id: 22,
    title: 'Convoy under fire',
    prompt: RESCUE_PROMPT,
    choice: 'yesno',
    branches: {
      no: br('You keep your distance. Nothing happens.'),
      yes: br(
        `${fightText('RR')} Win: the convoy pays you 2 goods and you gain 1 fame piece. Lose: one of your ships cannot move this turn.`,
        fight('RR', [gain('goods', 2), fame()], [immobilize]),
      ),
    },
  },
  {
    id: 23,
    title: 'Freighter in peril',
    prompt: RESCUE_PROMPT,
    choice: 'yesno',
    branches: {
      no: br('You leave the freighter to the pirates. Lose 1 fame piece.', loseFame()),
      yes: br(
        `${fightText('R')} Win: take 2 resources of your choice and gain 1 fame piece. Lose: remove 1 upgrade, but gain 1 fame piece.`,
        fight('R', [gain('any', 2), fame()], [removeUpgrade, fame()]),
      ),
    },
  },
  {
    id: 24,
    title: 'Pirates at the gate',
    prompt: RESCUE_PROMPT,
    choice: 'yesno',
    branches: {
      no: br('You leave the merchant to the pirates. Lose 1 fame piece.', loseFame()),
      yes: br(
        `${fightText('L')} Win: the merchant shares a star chart — one of your ships may space-jump — and you gain 1 fame piece. Lose: one of your ships cannot move this turn, but you gain 1 fame piece.`,
        fight('L', [spaceJump, fame()], [immobilize, fame()]),
      ),
    },
  },
  {
    id: 25,
    title: 'Wormhole',
    prompt: WORMHOLE_PROMPT,
    choice: 'yesno',
    branches: {
      no: br('You steer clear of the anomaly. Draw a new encounter card.', redraw),
      yes: br(
        `${raceText('L')} Win: one of your ships may space-jump. Lose: the wormhole snaps shut — one of your ships cannot move this turn.`,
        race('L', [spaceJump], [immobilize]),
      ),
    },
  },
  {
    id: 26,
    title: 'Rift in space',
    prompt: WORMHOLE_PROMPT,
    choice: 'yesno',
    branches: {
      no: br('You steer clear of the anomaly. Draw a new encounter card.', redraw),
      yes: br(
        `${raceText('R')} Win: one of your ships may space-jump. Lose: one of your ships cannot move this turn.`,
        race('R', [spaceJump], [immobilize]),
      ),
    },
  },
  {
    id: 27,
    title: 'Unstable passage',
    prompt: WORMHOLE_PROMPT,
    choice: 'yesno',
    branches: {
      no: br('You steer clear of the anomaly. Draw a new encounter card.', redraw),
      yes: br(
        `${raceText('RR')} Win: one of your ships may space-jump. Lose: the passage tears a part off your mothership — remove 1 upgrade.`,
        race('RR', [spaceJump], [removeUpgrade]),
      ),
    },
  },
  travelersCard(28, 'Wandering travelers'),
  travelersCard(29, 'Pilgrims'),
  travelersCard(30, 'Nomads of the void'),
  {
    id: 31,
    title: 'Wear and tear',
    prompt: 'Long voyages take their toll on every fleet. This card affects all players and offers no choice.',
    choice: 'none',
    branches: {
      auto: br(
        `Every player with more than ${WEAR_AND_TEAR_THRESHOLDS[31]} upgrades on their mothership removes 1 of them. Then the whole encounter deck, discards included, is reshuffled and a new card is drawn.`,
        { type: 'wearAndTear', threshold: WEAR_AND_TEAR_THRESHOLDS[31] },
        reshuffleAndRedraw,
      ),
    },
  },
  {
    id: 32,
    title: 'Wear and tear, galactic council',
    prompt: 'Long voyages take their toll on every fleet, and the galactic council convenes. This card affects all players and offers no choice.',
    choice: 'none',
    branches: {
      auto: br(
        `Every player with more than ${WEAR_AND_TEAR_THRESHOLDS[32]} upgrades on their mothership removes 1 of them. The council then honours the player(s) with the most freight pods with 1 fame piece each. Finally the whole encounter deck, discards included, is reshuffled and a new card is drawn.`,
        { type: 'wearAndTear', threshold: WEAR_AND_TEAR_THRESHOLDS[32] },
        { type: 'galacticCouncil' },
        reshuffleAndRedraw,
      ),
    },
  },
];

const BY_ID: ReadonlyMap<number, EncounterCard> = new Map(ENCOUNTER_CARDS.map((c) => [c.id, c]));

export function encounterCard(id: number): EncounterCard {
  const card = BY_ID.get(id);
  if (!card) throw new Error(`Unknown encounter card ${id}`);
  return card;
}

export function findEncounterCard(id: number): EncounterCard | undefined {
  return BY_ID.get(id);
}
