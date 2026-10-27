/**
 * Encounter card DATA sanity (spec §10): 32 cards, unique ids 1–32, every card
 * defines exactly the branch keys its choice kind needs, every contest / flee
 * names a valid opponent, prompts are original (no product branding), and the
 * [VERIFY] items are sourced from config, not retyped.
 */

import { describe, expect, it } from 'vitest';
import { ENCOUNTER_CARD_COUNT, TRAVELERS_DONATION_BRANCHES, WEAR_AND_TEAR_THRESHOLDS } from '../src/config.js';
import { ENCOUNTER_CARDS, encounterCard, findEncounterCard } from '../src/encounters/cards.js';
import { ENCOUNTER_OPPONENTS, requiredBranchKeys, type EncounterEffect } from '../src/encounters/schema.js';

function* walk(effects: readonly EncounterEffect[]): Generator<EncounterEffect> {
  for (const e of effects) {
    yield e;
    if (e.type === 'contest') {
      yield* walk(e.win);
      yield* walk(e.lose);
    } else if (e.type === 'flee') {
      yield* walk(e.escaped);
      yield* walk(e.caught);
    } else if (e.type === 'shakeTable') {
      yield* walk(e.low);
      yield* walk(e.mid);
      yield* walk(e.high);
    }
  }
}

function effectsOf(id: number): EncounterEffect[] {
  return Object.values(encounterCard(id).branches).flatMap((b) => [...walk(b.effects)]);
}

describe('encounter card data', () => {
  it('has 32 cards with unique ids 1–32, in order', () => {
    expect(ENCOUNTER_CARDS).toHaveLength(ENCOUNTER_CARD_COUNT);
    expect(ENCOUNTER_CARDS.map((c) => c.id)).toEqual(Array.from({ length: 32 }, (_, i) => i + 1));
    expect(encounterCard(17).id).toBe(17);
    expect(findEncounterCard(33)).toBeUndefined();
    expect(() => encounterCard(0)).toThrow();
  });

  it('every card has a title, a prompt, and exactly the branch keys its choice kind requires', () => {
    for (const card of ENCOUNTER_CARDS) {
      expect(card.title.length, `card ${card.id} title`).toBeGreaterThan(0);
      expect(card.prompt.length, `card ${card.id} prompt`).toBeGreaterThan(20);
      expect(Object.keys(card.branches).sort(), `card ${card.id} branches`).toEqual([...requiredBranchKeys(card.choice)].sort());
      for (const [key, branch] of Object.entries(card.branches)) {
        expect(branch.text.length, `card ${card.id} branch ${key} text`).toBeGreaterThan(0);
        expect(Array.isArray(branch.effects)).toBe(true);
      }
    }
  });

  it('uses the expected choice kinds per card group', () => {
    const kind = (id: number) => encounterCard(id).choice;
    for (const id of [1, 2, 3, 4, 5, 6, 28, 29, 30]) expect(kind(id), `card ${id}`).toBe('offer0to3');
    for (const id of [7, 8]) expect(kind(id), `card ${id}`).toBe('offerThenYesno');
    for (let id = 9; id <= 27; id++) expect(kind(id), `card ${id}`).toBe('yesno');
    for (const id of [31, 32]) expect(kind(id), `card ${id}`).toBe('none');
  });

  it('every contest / flee names a valid opponent and has effect lists on both sides', () => {
    let contests = 0;
    for (const card of ENCOUNTER_CARDS) {
      for (const e of effectsOf(card.id)) {
        if (e.type === 'contest' || e.type === 'flee') {
          contests++;
          expect(ENCOUNTER_OPPONENTS, `card ${card.id}`).toContain(e.opponent);
        }
        if (e.type === 'contest') {
          expect(['combat', 'speed']).toContain(e.kind);
          expect(Array.isArray(e.win) && Array.isArray(e.lose)).toBe(true);
        }
        if (e.type === 'gainResource') expect(e.count).toBeGreaterThan(0);
        if (e.type === 'gainFame' || e.type === 'loseFame') expect(e.count).toBeGreaterThan(0);
      }
    }
    expect(contests).toBeGreaterThan(20);
  });

  it('opponent seats per the spec table', () => {
    const contestSeat = (id: number, branch: string) => {
      const e = encounterCard(id).branches[branch]!.effects.find((x) => x.type === 'contest' || x.type === 'flee');
      return e && (e.type === 'contest' || e.type === 'flee') ? e.opponent : undefined;
    };
    expect(contestSeat(7, 'yes')).toBe('R');
    expect(contestSeat(8, 'yes')).toBe('L');
    expect(contestSeat(9, 'no')).toBe('R');
    expect(contestSeat(10, 'no')).toBe('RR');
    expect(contestSeat(11, 'no')).toBe('L');
    expect(contestSeat(16, 'yes')).toBe('R');
    expect(contestSeat(17, 'yes')).toBe('LL');
    expect(contestSeat(18, 'yes')).toBe('L');
    expect(contestSeat(19, 'yes')).toBe('RR');
    expect(contestSeat(20, 'yes')).toBe('L');
    expect(contestSeat(21, 'yes')).toBe('R');
    expect(contestSeat(22, 'yes')).toBe('RR');
    expect(contestSeat(23, 'yes')).toBe('R');
    expect(contestSeat(24, 'yes')).toBe('L');
    expect(contestSeat(25, 'yes')).toBe('L');
    expect(contestSeat(26, 'yes')).toBe('R');
    expect(contestSeat(27, 'yes')).toBe('RR');
  });

  it('no prompt or branch text mentions the original product', () => {
    for (const card of ENCOUNTER_CARDS) {
      expect(card.prompt).not.toMatch(/catan/i);
      expect(card.title).not.toMatch(/catan/i);
      for (const b of Object.values(card.branches)) expect(b.text).not.toMatch(/catan/i);
    }
  });

  it('cards 28–30 take their donation split from TRAVELERS_DONATION_BRANCHES', () => {
    const effectTypes = (id: number, key: string) => encounterCard(id).branches[key]!.effects.map((e) => e.type);
    const expected: Record<string, string[]> = {
      nothing: [],
      loseFame: ['loseFame'],
      removeUpgradeLoseFame: ['removeUpgrade', 'loseFame'],
      gainFame: ['gainFame'],
      spaceJump: ['spaceJump'],
      spaceJumpAndFame: ['spaceJump', 'gainFame'],
      freeTradeShip: ['freeTradeShip'],
    };
    for (const id of [28, 29, 30] as const) {
      for (const amount of [0, 1, 2, 3] as const) {
        const name = TRAVELERS_DONATION_BRANCHES[id][amount];
        expect(effectTypes(id, String(amount)), `card ${id} donation ${amount}`).toEqual(expected[name]);
      }
    }
  });

  it('cards 31/32 are automatic: wear and tear with the config thresholds, then a full reshuffle', () => {
    const e31 = encounterCard(31).branches['auto']!.effects;
    expect(e31).toEqual([{ type: 'wearAndTear', threshold: WEAR_AND_TEAR_THRESHOLDS[31] }, { type: 'redraw', reshuffle: true }]);
    const e32 = encounterCard(32).branches['auto']!.effects;
    expect(e32).toEqual([
      { type: 'wearAndTear', threshold: WEAR_AND_TEAR_THRESHOLDS[32] },
      { type: 'galacticCouncil' },
      { type: 'redraw', reshuffle: true },
    ]);
    expect(WEAR_AND_TEAR_THRESHOLDS).toEqual({ 31: 8, 32: 6 });
  });

  it('the wormhole "no" branches redraw and the smuggler / raider "yes" branches end in a shake table', () => {
    for (const id of [25, 26, 27]) expect(encounterCard(id).branches['no']!.effects).toEqual([{ type: 'redraw' }]);
    for (const id of [12, 13]) {
      const yes = encounterCard(id).branches['yes']!.effects;
      expect(yes[0]).toEqual({ type: 'tradeOneForTwo' });
      expect(yes[1]?.type).toBe('shakeTable');
    }
    for (const id of [14, 15]) {
      const yes = encounterCard(id).branches['yes']!.effects;
      expect(yes[0]).toEqual({ type: 'payResources', count: 1 });
      expect(yes[1]?.type).toBe('shakeTable');
    }
  });
});
