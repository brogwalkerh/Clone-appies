/**
 * Pins for every item of `RULES-CHECKLIST.md` (spec §16, HANDOFF §8 item 5).
 *
 * Each assertion states the CURRENT reading of a rule that still has to be
 * confirmed against the physical box. A failing assertion here means a
 * checklist value was changed: that is fine when it was deliberate (someone
 * read the rulebook / almanac / tiles / cards and filled in the "Reading:"
 * line), so update the expected value here in the same commit and record the
 * outcome in HANDOFF §5. The message of every assertion names its checklist
 * entry. Items whose behaviour is already pinned by a dedicated test elsewhere
 * are listed in the checklist with that test; the value pins are repeated
 * here so this file is the single place to look.
 */

import { describe, expect, it } from 'vitest';
import { applyAction } from '../src/actions/index.js';
import boardJson from '../../layouts/board.json' with { type: 'json' };
import beginnerJson from '../../layouts/beginner.json' with { type: 'json' };
import { boardLayout, beginnerPlacement } from '../src/board/data.js';
import { hexKey } from '../src/board/geometry.js';
import { neighborsOf, spaceportSites, spaceportsOf } from '../src/board/query.js';
import {
  BEGINNER_SHIP_SIDE_VERIFIED,
  BLOCKER_SPACEPORT_SITES_BLOCK_END_NODES,
  DISCOVERY_ENDS_MOVE,
  DRAFT_3P_BLOCK_FREE_SITES,
  DRAFT_3P_REMOVED_UPGRADE,
  ENCOUNTER_SHAKE_BANDS,
  STRATEGIC_RETURNED_EMPTY,
  TRAVELERS_DONATION_BRANCHES,
  VARIABLE_SETUP_START_LOBE,
  WILD_SPACE_SLOT_ORDER,
  reserveDrawFor,
  shakeBand,
} from '../src/config.js';
import { validateEndNode } from '../src/flight/movement.js';
import { speedOf } from '../src/flight/stats.js';
import { freeOwnSpaceportSites, freeTradeShipSite, grantFreeTradeShip } from '../src/found/freeTradeShip.js';
import { createRng, type Rng } from '../src/rng.js';
import { createBeginnerGame } from '../src/setup/beginner.js';
import type { GameState } from '../src/types.js';
import { recomputeAllVp } from '../src/vp.js';
import { ok, tradeBuildState } from './support/tradeBuild.js';

const see = (n: number, what: string) => `RULES-CHECKLIST.md #${n} (${what}): change deliberately, then update this pin`;

// ---------------------------------------------------------------------------
// Layout data
// ---------------------------------------------------------------------------

describe('RULES-CHECKLIST pins: layout data', () => {
  it('#1 board.json sectors[*].stars: tile backs per tile (inferred)', () => {
    const expected: Record<string, 1 | 2> = {
      S1: 1, S2: 1, S3: 1, S4: 1, S5: 1,
      S6: 2, S7: 2, S8: 2,
      O_GreenFolk: 1, O_Merchants: 1, O_Scientists: 2, O_Diplomats: 2,
      E1: 1, E2: 1, E3: 2, E4: 2,
    };
    // Raw JSON: the parser defaults a missing / odd value to 1, so pin the file itself.
    const raw = Object.fromEntries(
      Object.entries(boardJson.sectors)
        .filter(([id]) => id !== '_comment')
        .map(([id, t]) => [id, (t as { stars?: unknown }).stars]),
    );
    expect(raw, see(1, 'board.json sectors[*].stars')).toEqual(expected);
    // And the parsed layout the engine uses.
    for (const [id, stars] of Object.entries(expected)) {
      expect(boardLayout().tiles[id]?.stars, see(1, `${id} stars`)).toBe(stars);
    }
  });

  it('#2 beginner.json startingPieces[colour].spaceport.shipSide (read from a small picture)', () => {
    const expected = { yellow: '[1,1]', red: '[4,1]', blue: '[9,1]', white: '[7,1]' };
    const raw = Object.fromEntries(
      Object.entries(beginnerJson.startingPieces)
        .filter(([c]) => c !== '_comment')
        .map(([c, p]) => [c, (p as { spaceport: { shipSide: string } }).spaceport.shipSide]),
    );
    expect(raw, see(2, 'beginner.json shipSide')).toEqual(expected);
    const parsed = beginnerPlacement().startingPieces!;
    for (const [colour, side] of Object.entries(expected)) {
      expect(`[${hexKey(parsed[colour as keyof typeof parsed].spaceport.shipSide)}]`, see(2, `${colour} shipSide`)).toBe(side);
    }
    expect(BEGINNER_SHIP_SIDE_VERIFIED, see(2, 'BEGINNER_SHIP_SIDE_VERIFIED')).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// config.ts values
// ---------------------------------------------------------------------------

describe('RULES-CHECKLIST pins: config.ts values', () => {
  it('#3 ENCOUNTER_SHAKE_BANDS (cards 12–15): low 1–2, mid 3, high 4–5', () => {
    expect(ENCOUNTER_SHAKE_BANDS, see(3, 'ENCOUNTER_SHAKE_BANDS')).toEqual({ low: [1, 2], mid: [3], high: [4, 5] });
    expect([1, 2, 3, 4, 5].map(shakeBand), see(3, 'shakeBand')).toEqual(['low', 'low', 'mid', 'high', 'high']);
  });

  it('#4 TRAVELERS_DONATION_BRANCHES (cards 28–30): 1 and 2 give the same branch', () => {
    expect(TRAVELERS_DONATION_BRANCHES, see(4, 'TRAVELERS_DONATION_BRANCHES')).toEqual({
      28: { 0: 'removeUpgradeLoseFame', 1: 'gainFame', 2: 'gainFame', 3: 'spaceJump' },
      29: { 0: 'nothing', 1: 'gainFame', 2: 'gainFame', 3: 'freeTradeShip' },
      30: { 0: 'loseFame', 1: 'gainFame', 2: 'gainFame', 3: 'spaceJumpAndFame' },
    });
  });

  it('#5 DISCOVERY_ENDS_MOVE = false', () => {
    expect(DISCOVERY_ENDS_MOVE, see(5, 'DISCOVERY_ENDS_MOVE')).toBe(false);
  });

  it('#6 WILD_SPACE_SLOT_ORDER: near slots then far, nearest first', () => {
    expect(WILD_SPACE_SLOT_ORDER, see(6, 'WILD_SPACE_SLOT_ORDER')).toEqual([
      'N4', 'N1', 'N6', 'N5', 'N2', 'N7', 'N3', 'N8',
      'F5', 'F1', 'F3', 'F6', 'F2', 'F4', 'F7',
    ]);
  });

  it('#7 VARIABLE_SETUP_START_LOBE = 0 (no player orients a tile)', () => {
    expect(VARIABLE_SETUP_START_LOBE, see(7, 'VARIABLE_SETUP_START_LOBE')).toBe(0);
  });

  it("#8 STRATEGIC_RETURNED_EMPTY = 'random'", () => {
    expect(STRATEGIC_RETURNED_EMPTY, see(8, 'STRATEGIC_RETURNED_EMPTY')).toBe('random');
  });

  it("#9 DRAFT_3P_REMOVED_UPGRADE = 'booster'", () => {
    expect(DRAFT_3P_REMOVED_UPGRADE, see(9, 'DRAFT_3P_REMOVED_UPGRADE')).toBe('booster');
  });

  it('#10 DRAFT_3P_BLOCK_FREE_SITES = true', () => {
    expect(DRAFT_3P_BLOCK_FREE_SITES, see(10, 'DRAFT_3P_BLOCK_FREE_SITES')).toBe(true);
  });

  it('#11 BLOCKER_SPACEPORT_SITES_BLOCK_END_NODES = false (HANDOFF §5.2)', () => {
    expect(BLOCKER_SPACEPORT_SITES_BLOCK_END_NODES, see(11, 'BLOCKER_SPACEPORT_SITES_BLOCK_END_NODES')).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Judgment calls (HANDOFF §5.1–§5.7) not pinned by a dedicated test elsewhere
// ---------------------------------------------------------------------------

/** 3-player beginner game (seed 'trade-build') already shaken, p1 (red) to move. */
function flightState(): GameState {
  const state = tradeBuildState();
  state.phase = 'flight.move';
  state.turn.baseSpeed = 4;
  state.turn.speed = speedOf(state, state.activePlayer);
  return state;
}

/** Rng whose `d6()` rolls `total` first, everything else seeded. */
function rollRng(total: number): Rng {
  const base = createRng('pins');
  const queue = [Math.min(6, total - 1), total - Math.min(6, total - 1)];
  return { ...base, d6: () => queue.shift() ?? base.d6() };
}

describe('RULES-CHECKLIST pins: judgment calls', () => {
  it('#13 (§5.3) a ship on a new opponent spaceport site may stay when no ONE-step move is legal', () => {
    const state = flightState();
    const ship = state.board.ships['ship:red:1']!;
    const theirs = spaceportsOf(state, 'p3')[0]!;
    const site = spaceportSites(state.board, theirs.nodeId).find(
      (n) => !Object.values(state.board.ships).some((s) => s.nodeId === n),
    )!;
    ship.nodeId = site;
    ship.mustFoundOrLeave = true;
    // Block every legal one-step end node with another player's ship.
    let n = 0;
    for (const next of neighborsOf(state.board, site)) {
      if (validateEndNode(state, ship, next) !== null) continue;
      const id = `ship:pin:${++n}`;
      state.board.ships[id] = { id, owner: 'p2', kind: 'colony', nodeId: next, mustFoundOrLeave: false };
    }
    expect(neighborsOf(state.board, site).every((x) => validateEndNode(state, ship, x) !== null)).toBe(true);
    // A two-step move would still be legal (ships may pass through occupied nodes)…
    const twoStep = neighborsOf(state.board, site)
      .filter((x) => !state.board.settlements[x])
      .flatMap((x) => neighborsOf(state.board, x))
      .filter((x) => x !== site && validateEndNode(state, ship, x) === null);
    expect(twoStep.length).toBeGreaterThan(0);
    // …but the §7.2 check looks one step ahead only, so the turn may end.
    const ended = applyAction(state, { type: 'endTurn', playerId: 'p1' }, createRng('pins'));
    expect(ended.ok, see(13, 'one-step move-away check in actions/turn.ts')).toBe(true);
  });

  it('#14 (§5.4) a free trade ship goes on the FIRST free own spaceport site; the player does not choose', () => {
    const state = createBeginnerGame({
      players: [
        { id: 'p1', name: 'Ann', color: 'red' },
        { id: 'p2', name: 'Bob', color: 'blue' },
        { id: 'p3', name: 'Cid', color: 'yellow' },
      ],
      seed: 'pins',
    });
    // Free both sites of p1's spaceport so there is a real choice.
    for (const s of Object.values(state.board.ships)) if (s.owner === 'p1') delete state.board.ships[s.id];
    state.players.find((p) => p.id === 'p1')!.pieces.transportsLeft = 3;
    const free = freeOwnSpaceportSites(state, 'p1');
    expect(free.length).toBe(2);
    expect(freeTradeShipSite(state, 'p1'), see(14, 'freeTradeShipSite picks the first site')).toBe(free[0]);
    expect(grantFreeTradeShip(state, 'p1')).toBe('placed');
    expect(Object.values(state.board.ships).find((s) => s.owner === 'p1')!.nodeId, see(14, 'first free site')).toBe(free[0]);
  });

  it('#15 (§5.5) the reserve draw uses VP at DRAW time, not at roll time', () => {
    const state = createBeginnerGame({
      players: [
        { id: 'p1', name: 'Ann', color: 'red' },
        { id: 'p2', name: 'Bob', color: 'blue' },
        { id: 'p3', name: 'Cid', color: 'yellow' },
      ],
      seed: 'pins',
    });
    const me = state.activePlayer;
    const p = () => state.players.find((x) => x.id === me)!;
    p().famePieces = 6; // 4 + 3 = 7 VP → 2 cards
    recomputeAllVp(state);
    expect(reserveDrawFor(p().vp)).toBe(2);
    const rolled = ok(state, { type: 'rollDice', playerId: me }, rollRng(8));
    const mine = rolled.players.find((x) => x.id === me)!;
    mine.famePieces = 8; // now 8 VP → 1 card
    recomputeAllVp(rolled);
    const before = mine.hand.length;
    const after = ok(rolled, { type: 'takeReserveDraw', playerId: me });
    expect(after.players.find((x) => x.id === me)!.hand.length - before, see(15, 'reserve draw VP read in takeReserveDraw')).toBe(1);
  });
});
