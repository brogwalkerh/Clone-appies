/**
 * Flight phase (spec §5.3, §9, §11): shake, movement, exploration, pirate /
 * ice tokens, parking bookkeeping, endTurn gating and space jumps.
 *
 * Board facts for seed 'trade-build' (3 players, turn order p1 p2 p3, p1 red
 * active): red colony ship ship:red:1 on N(5,1) (a site of p1's spaceport
 * S(3,1)); unexplored system N4 (planets P(4,4) fuel P5 pirate, P(4,5) carbon 9,
 * P(5,4) food 4; colony sites S(3,4), S(4,5), S(4,4)) is first touched at
 * N(5,3), 4 steps away; system N1 holds ice planet I3 on P(2,5); the Green
 * Folk docking point is N(2,9). Everything below asserts these facts before
 * relying on them.
 */

import { describe, expect, it } from 'vitest';
import { ACTION_POLICY, applyAction } from '../src/actions/index.js';
import { freshTurnState } from '../src/actions/turn.js';
import {
  getSector,
  neighborsOf,
  planetsAdjacentToNode,
  sectorsAdjacentToNode,
  shipsOf,
  spaceportSites,
  spaceportsOf,
} from '../src/board/query.js';
import { BALL_VALUES, BLOCKER_SPACEPORT_SITES_BLOCK_END_NODES, MOTHERSHIP_BALLS, type Ball } from '../src/config.js';
import { exploreAt } from '../src/flight/explore.js';
import { applySpaceJump, validateJumpTarget } from '../src/flight/jump.js';
import { isForeignSpaceportSite, validateEndNode } from '../src/flight/movement.js';
import { createBeginnerGame } from '../src/setup/beginner.js';
import { drawBalls, evaluateShake } from '../src/flight/shake.js';
import { boosterCountForRace, combatStrengthOf, speedOf } from '../src/flight/stats.js';
import { checkSpecialTokens, nodeTouchesToken } from '../src/flight/tokens.js';
import { computeProduction } from '../src/production/produce.js';
import { createRng, type Rng } from '../src/rng.js';
import type { FriendshipCardId, GameState, NodeId, PlayerId, ShipId } from '../src/types.js';
import { computeVp } from '../src/vp.js';
import { THREE, fails, ok, opponents, player, rng, tradeBuildState } from './support/tradeBuild.js';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const SHIP = 'ship:red:1';
const START = 'N(5,1)';
const N4_APPROACH: NodeId[] = ['S(4,2)', 'N(5,2)', 'S(4,3)', 'N(5,3)'];
const PIRATE_PLANET = 'P(4,4)';
const ICE_PLANET = 'P(2,5)';
const N4_SITE = 'S(4,4)';
const GREEN_DOCK = 'N(2,9)';

/** Beginner game already shaken (base speed 4 → speed 5 with the starting booster). */
function flightState(seed = 'trade-build'): GameState {
  const state = tradeBuildState(seed);
  state.phase = 'flight.move';
  state.turn.baseSpeed = 4;
  state.turn.speed = speedOf(state, state.activePlayer);
  return state;
}

function ship(state: GameState, id: ShipId = SHIP) {
  const s = state.board.ships[id];
  if (!s) throw new Error(`no ship ${id}`);
  return s;
}

function teleport(state: GameState, nodeId: NodeId, id: ShipId = SHIP): void {
  ship(state, id).nodeId = nodeId;
}

function move(state: GameState, path: NodeId[], id: ShipId = SHIP): GameState {
  return ok(state, { type: 'moveShip', playerId: state.activePlayer, shipId: id, path });
}

function moveFails(state: GameState, path: NodeId[], code: Parameters<typeof fails>[2], id: ShipId = SHIP): void {
  fails(state, { type: 'moveShip', playerId: state.activePlayer, shipId: id, path }, code);
}

/** Rng whose `shuffle` of the 5 balls puts `first` at the front; everything else seeded. */
function shakeRng(first: Ball[], seed = 'shake'): Rng {
  const base = createRng(seed);
  return {
    ...base,
    next: () => base.next(),
    int: (n) => base.int(n),
    pick: (a) => base.pick(a),
    d6: () => base.d6(),
    getState: () => base.getState(),
    shuffle: <T,>(arr: readonly T[]): T[] => {
      if (arr.length === MOTHERSHIP_BALLS.length && arr.every((b) => MOTHERSHIP_BALLS.includes(b as Ball))) {
        const rest = [...arr];
        for (const b of first) rest.splice(rest.indexOf(b as T), 1);
        return [...(first as unknown as T[]), ...rest];
      }
      return base.shuffle(arr);
    },
  };
}

/** A node adjacent to `target` that holds no piece and is not a site (for teleporting a ship next to something). */
function approachNode(state: GameState, target: NodeId): NodeId {
  const n = neighborsOf(state.board, target).find(
    (id) => !state.board.settlements[id] && !Object.values(state.board.ships).some((s) => s.nodeId === id) && state.board.nodes[id]!.siteType === 'plain',
  );
  if (!n) throw new Error(`no free approach node for ${target}`);
  return n;
}

/** Rotate the turn to `playerId` (other players end from 'flight.move' without moving). */
function cycleTo(state: GameState, playerId: PlayerId): GameState {
  let s = state;
  let guard = 0;
  while (s.activePlayer !== playerId) {
    s.phase = 'flight.move';
    s = ok(s, { type: 'endTurn', playerId: s.activePlayer });
    if (++guard > 10) throw new Error('cycleTo: did not reach player');
  }
  s.phase = 'flight.move';
  s.turn.baseSpeed = 4;
  s.turn.speed = speedOf(s, playerId);
  return s;
}

describe('fixture sanity (seed trade-build)', () => {
  it('matches the board facts the tests rely on', () => {
    const state = flightState();
    expect(state.activePlayer).toBe('p1');
    expect(ship(state).nodeId).toBe(START);
    expect(ship(state).kind).toBe('colony');
    expect(state.turn.speed).toBe(5);
    expect(planetsAdjacentToNode(state.board, 'N(5,3)').map((p) => p.id)).toContain(PIRATE_PLANET);
    expect(state.board.planets[PIRATE_PLANET]!.disc).toMatchObject({ label: 'P5', faceUp: false });
    expect(state.board.planets[ICE_PLANET]!.disc).toMatchObject({ label: 'I3', faceUp: false });
    expect(getSector(state.board, 'N4').explored).toBe(false);
    expect(state.board.nodes[N4_SITE]!.siteType).toBe('colonySite');
    expect(neighborsOf(state.board, N4_SITE)).toContain('N(5,3)');
    expect(state.board.nodes[GREEN_DOCK]!.siteType).toBe('dockingPoint');
    expect(state.reserveDiscs.map((d) => d.label)).toEqual(['3', '9', '10', '11', '11']);
  });
});

// ---------------------------------------------------------------------------
// Shake
// ---------------------------------------------------------------------------

describe('shake: drawBalls / evaluateShake', () => {
  it('every colour pair appears, base speeds are 3–5 and a black ball shows up ≈40% of the time', () => {
    const pairs = new Map<string, number>();
    let black = 0;
    const N = 4000;
    for (let i = 0; i < N; i++) {
      const balls = drawBalls(createRng(`shake-${i}`));
      expect(balls).toHaveLength(2);
      const r = evaluateShake(balls);
      expect([3, 4, 5]).toContain(r.baseSpeed);
      if (r.black) black++;
      const key = [...balls].sort().join('+');
      pairs.set(key, (pairs.get(key) ?? 0) + 1);
    }
    expect([...pairs.keys()].sort()).toEqual(
      ['yellow+yellow', 'red+yellow', 'blue+yellow', 'black+yellow', 'blue+red', 'black+red', 'black+blue'].sort(),
    );
    const freq = black / N;
    expect(freq).toBeGreaterThan(0.36);
    expect(freq).toBeLessThan(0.44);
    // YY is the only pair drawn from two identical balls: 1/10.
    expect((pairs.get('yellow+yellow') ?? 0) / N).toBeGreaterThan(0.07);
    expect((pairs.get('yellow+yellow') ?? 0) / N).toBeLessThan(0.13);
  });

  it.each([
    [['yellow', 'yellow'], 4, false],
    [['yellow', 'blue'], 3, false],
    [['yellow', 'red'], 5, false],
    [['red', 'blue'], 4, false],
    [['black', 'red'], 3, true],
    [['black', 'yellow'], 3, true],
    [['black', 'blue'], 3, true],
  ] as [Ball[], number, boolean][])('%j → base speed %i (black %s)', (balls, speed, black) => {
    const r = evaluateShake(balls);
    expect(r.baseSpeed).toBe(speed);
    expect(r.black).toBe(black);
    expect(r.total).toBe(balls.reduce((n, b) => n + BALL_VALUES[b], 0));
  });
});

describe('shakeMothership', () => {
  it('non-black: records the balls, base speed = sum, speed = base + boosters, phase → flight.move', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    const next = ok(state, { type: 'shakeMothership', playerId: me }, shakeRng(['red', 'yellow']));
    expect(next.turn.shake).toEqual(['red', 'yellow']);
    expect(next.turn.baseSpeed).toBe(5);
    expect(next.turn.speed).toBe(6); // 5 + 1 starting booster
    expect(next.phase).toBe('flight.move');
    expect(next.turn.encounter).toBeUndefined();
    expect(next.encounterDeck).toEqual(state.encounterDeck);
    // Once shaken: no second shake, no reserve draw any more.
    fails(next, { type: 'shakeMothership', playerId: me }, 'wrongPhase');
    fails(next, { type: 'takeReserveDraw', playerId: me }, 'wrongPhase');
    expect(ACTION_POLICY.takeReserveDraw.phases).not.toContain('flight.move');
    expect(ACTION_POLICY.takeReserveDraw.phases).not.toContain('flight.encounter');
    next.phase = 'flight.shake';
    fails(next, { type: 'shakeMothership', playerId: me }, 'ruleViolation');
  });

  it('black: base speed 3, top encounter card becomes turn.encounter, phase → flight.encounter', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    const top = state.encounterDeck[0]!;
    const next = ok(state, { type: 'shakeMothership', playerId: me }, shakeRng(['black', 'red']));
    expect(next.turn.shake).toEqual(['black', 'red']);
    expect(next.turn.baseSpeed).toBe(3);
    expect(next.turn.speed).toBe(4);
    expect(next.phase).toBe('flight.encounter');
    // The top card was drawn; a "Wear and Tear" card (31/32) resolves itself and redraws, so
    // the context may already show a later card — either way a choice is pending.
    expect(next.turn.encounter?.stage).toBe('choice');
    if (top <= 30) expect(next.turn.encounter?.cardId).toBe(top);
    expect(next.encounterDeck).not.toContain(next.turn.encounter?.cardId);
    expect(next.encounterDeck.length + next.encounterDiscard.length + 1).toBe(state.encounterDeck.length);
    // Gating while the encounter is open.
    fails(next, { type: 'encounterChoice', playerId: opponents(next)[0]!.id, value: true }, 'notYourTurn');
    fails(next, { type: 'encounterPick', playerId: me, shipId: SHIP }, 'ruleViolation');
    fails(next, { type: 'moveShip', playerId: me, shipId: SHIP, path: ['S(4,2)'] }, 'wrongPhase');
    fails(next, { type: 'endTurn', playerId: me }, 'wrongPhase');
  });

  it('black: the encounter resolves through the real flow, then flight continues at base speed 3', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    state.encounterDeck = [3, ...state.encounterDeck];
    const enc = ok(state, { type: 'shakeMothership', playerId: me }, shakeRng(['yellow', 'black']));
    expect(enc.turn.encounter).toMatchObject({ cardId: 3, stage: 'choice' });
    const next = ok(enc, { type: 'encounterChoice', playerId: me, value: 0, cards: [] });
    expect(next.phase).toBe('flight.move');
    expect(next.turn.baseSpeed).toBe(3);
    expect(next.turn.speed).toBe(4);
    expect(next.turn.encounter?.stage).toBe('done');
    expect(next.encounterDiscard).toEqual([3]);
    expect(next.encounterDeck).toEqual(state.encounterDeck.slice(1));
  });

  it('reshuffles the discard pile when the deck is empty, and skips the encounter if both are empty', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    state.encounterDeck = [];
    state.encounterDiscard = [7, 8, 9];
    const next = ok(state, { type: 'shakeMothership', playerId: me }, shakeRng(['black', 'blue']));
    expect(next.phase).toBe('flight.encounter');
    expect(next.encounterDiscard).toEqual([]);
    expect(next.encounterDeck.length + 1).toBe(3);
    expect([7, 8, 9]).toContain(next.turn.encounter?.cardId);

    const none = tradeBuildState();
    none.encounterDeck = [];
    none.encounterDiscard = [];
    const skipped = ok(none, { type: 'shakeMothership', playerId: me }, shakeRng(['black', 'blue']));
    expect(skipped.phase).toBe('flight.move');
    expect(skipped.turn.baseSpeed).toBe(3);
  });

  it('through the action, over many seeds, encounters happen ≈40% of the time', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    let enc = 0;
    const N = 500;
    for (let i = 0; i < N; i++) {
      const next = ok(state, { type: 'shakeMothership', playerId: me }, createRng(`act-${i}`));
      if (next.phase === 'flight.encounter') enc++;
      else expect(next.phase).toBe('flight.move');
    }
    expect(enc / N).toBeGreaterThan(0.33);
    expect(enc / N).toBeLessThan(0.47);
  });

  it('0 ships on the board: flight is skipped (base speed 0, speed 0, flight.move) and endTurn is the only useful action', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    for (const s of shipsOf(state, me)) delete state.board.ships[s.id];
    const deck = [...state.encounterDeck];
    const next = ok(state, { type: 'shakeMothership', playerId: me }, shakeRng(['black', 'red']));
    expect(next.phase).toBe('flight.move');
    expect(next.turn.baseSpeed).toBe(0);
    expect(next.turn.speed).toBe(0);
    expect(next.turn.shake).toBeUndefined();
    expect(next.encounterDeck).toEqual(deck);
    expect(next.log.some((e) => /flight is skipped/.test(e.message))).toBe(true);
    const done = ok(next, { type: 'endTurn', playerId: me });
    expect(done.phase).toBe('production');
    // Without ships the player may also end the turn straight from Trade & Build (§5.3a).
    ok(state, { type: 'endTurn', playerId: me });
  });

  it('is active-player only', () => {
    const state = tradeBuildState();
    fails(state, { type: 'shakeMothership', playerId: opponents(state)[0]!.id }, 'notYourTurn');
  });
});

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

describe('speedOf / combatStrengthOf / boosterCountForRace', () => {
  const cases: [FriendshipCardId, number, number][] = [
    ['hirAkas', 2, 0],
    ['khorNem', 1, 1],
    ['hirSto', 1, 1],
    ['asaBar', 1, 1],
    ['khaStar', 0, 2],
  ];

  it('speed = baseSpeed + boosters (+ nothing without cards); combat = cannons', () => {
    const state = flightState();
    const me = state.activePlayer;
    player(state, me).mothership.boosters = 3;
    player(state, me).mothership.cannons = 2;
    expect(speedOf(state, me)).toBe(4 + 3);
    expect(combatStrengthOf(state, me)).toBe(2);
    expect(boosterCountForRace(state, me)).toBe(3);
    delete state.turn.baseSpeed;
    expect(speedOf(state, me)).toBe(3); // unshaken: base 0
  });

  it.each(cases)('Scientist %s adds speed +%i / combat +%i', (card, speed, combat) => {
    const state = flightState();
    const me = state.activePlayer;
    player(state, me).friendshipCards = [card];
    expect(speedOf(state, me)).toBe(4 + 1 + speed);
    expect(combatStrengthOf(state, me)).toBe(combat);
    expect(boosterCountForRace(state, me)).toBe(1 + speed);
  });

  it('all Scientist cards stack, and Green Folk / Merchants / Diplomats cards add nothing', () => {
    const state = flightState();
    const me = state.activePlayer;
    player(state, me).friendshipCards = ['hirAkas', 'khorNem', 'hirSto', 'asaBar', 'khaStar', 'axxa', 'zuzzo', 'raHal'];
    expect(speedOf(state, me)).toBe(4 + 1 + 5);
    expect(combatStrengthOf(state, me)).toBe(5);
    expect(boosterCountForRace(state, me)).toBe(6);
  });
});

// ---------------------------------------------------------------------------
// Movement
// ---------------------------------------------------------------------------

describe('moveShip: path validation', () => {
  it('moves along a chain of edges; steps are counted in turn.shipMovesUsed', () => {
    const state = flightState();
    const next = move(state, ['S(4,2)', 'N(5,2)']);
    expect(ship(next).nodeId).toBe('N(5,2)');
    expect(next.turn.shipMovesUsed[SHIP]).toBe(2);
    expect(next.log.some((e) => e.kind === 'event' && /moved ship:red:1/.test(e.message))).toBe(true);
  });

  it('may pass through occupied intersections: a settlement and another player\'s ship', () => {
    const state = flightState();
    // Through the own spaceport at S(3,1) to its other site N(4,2).
    expect(state.board.settlements['S(3,1)']).toMatchObject({ kind: 'spaceport', owner: 'p1' });
    const viaPort = move(state, ['S(3,1)', 'N(4,2)']);
    expect(ship(viaPort).nodeId).toBe('N(4,2)');
    // Through an opponent ship parked on S(4,2).
    const blocked = flightState();
    teleport(blocked, 'S(4,2)', 'ship:blue:1');
    const viaShip = move(blocked, ['S(4,2)', 'N(5,2)']);
    expect(ship(viaShip).nodeId).toBe('N(5,2)');
  });

  it('allows backtracking (a 2-step move may end where it started, and costs 2 steps)', () => {
    const state = flightState();
    const next = move(state, ['S(4,2)', START]);
    expect(ship(next).nodeId).toBe(START);
    expect(next.turn.shipMovesUsed[SHIP]).toBe(2);
  });

  it('enforces the step budget cumulatively across several moveShip calls', () => {
    const state = flightState(); // speed 5
    moveFails(state, [...N4_APPROACH, N4_SITE, 'N(6,4)'], 'ruleViolation');
    const a = move(state, ['S(4,2)', 'N(5,2)', 'S(4,3)']);
    const b = move(a, ['N(5,3)', 'S(4,3)']);
    expect(b.turn.shipMovesUsed[SHIP]).toBe(5);
    moveFails(b, ['N(5,2)'], 'ruleViolation');
    // Another ship of the same player has its own budget.
    b.board.ships['ship:red:2'] = { id: 'ship:red:2', owner: 'p1', kind: 'colony', nodeId: 'N(4,2)', mustFoundOrLeave: false };
    expect(move(b, ['S(3,1)', START], 'ship:red:2').turn.shipMovesUsed).toEqual({ [SHIP]: 5, 'ship:red:2': 2 });
  });

  it('rejects disconnected paths, unknown nodes, empty paths and paths that start on the current node', () => {
    const state = flightState();
    moveFails(state, ['S(4,2)', 'N(5,3)'], 'invalidPath');
    moveFails(state, ['N(5,3)'], 'invalidPath');
    moveFails(state, ['nope'], 'invalidPath');
    moveFails(state, [], 'invalidPath');
    moveFails(state, [START, 'S(4,2)'], 'invalidPath');
  });

  it('rejects immobilized ships, other players\' ships, unknown ships and the wrong phase', () => {
    const state = flightState();
    state.turn.immobilized = [SHIP];
    moveFails(state, ['S(4,2)'], 'ruleViolation');
    const other = flightState();
    moveFails(other, ['S(8,2)'], 'invalidTarget', 'ship:blue:1');
    moveFails(other, ['S(4,2)'], 'invalidTarget', 'ship:red:9');
    other.phase = 'tradeBuild';
    moveFails(other, ['S(4,2)'], 'wrongPhase');
  });
});

describe('moveShip: end-node rules (§9.2 / §11)', () => {
  it('may not end on a node holding a ship or a settlement', () => {
    const state = flightState();
    teleport(state, 'S(4,2)', 'ship:blue:1');
    moveFails(state, ['S(4,2)'], 'invalidTarget');
    moveFails(state, ['S(3,1)'], 'invalidTarget');
  });

  it('may not end on another player\'s spaceport site, but an own spaceport site is fine', () => {
    const state = flightState();
    const theirs = spaceportsOf(state, 'p3')[0]!;
    const site = spaceportSites(state.board, theirs.nodeId).find((n) => !state.board.ships['ship:yellow:1'] || state.board.ships['ship:yellow:1']!.nodeId !== n)!;
    teleport(state, approachNode(state, site));
    moveFails(state, [site], 'ruleViolation');
    // Own site N(4,2) (other site of S(3,1)).
    const own = move(flightState(), ['S(3,1)', 'N(4,2)']);
    expect(ship(own).nodeId).toBe('N(4,2)');
  });

  it("3-player blocker spaceport sites: BLOCKER_SPACEPORT_SITES_BLOCK_END_NODES decides (default false: they 'only block the sites')", () => {
    // [VERIFY] config pin (HANDOFF §5.2): §9.2 / §11 speak of ANOTHER PLAYER's spaceport; the unused colour is nobody.
    expect(BLOCKER_SPACEPORT_SITES_BLOCK_END_NODES).toBe(false);
    const state = flightState();
    expect(state.players).toHaveLength(3);
    const blockerPort = Object.values(state.board.settlements).find((s) => s.kind === 'spaceport' && s.owner === null)!;
    const bSite = spaceportSites(state.board, blockerPort.nodeId).find((n) => !state.board.settlements[n])!;
    const theirs = spaceportsOf(state, 'p3')[0]!;
    const pSite = spaceportSites(state.board, theirs.nodeId).find((n) => !Object.values(state.board.ships).some((sh) => sh.nodeId === n))!;
    // The predicate under both values: a real player's site is always foreign, the blocker's only with the flag on.
    expect(isForeignSpaceportSite(state, pSite, 'p1', false)).toBe(true);
    expect(isForeignSpaceportSite(state, pSite, 'p1', true)).toBe(true);
    expect(isForeignSpaceportSite(state, bSite, 'p1', false)).toBe(false);
    expect(isForeignSpaceportSite(state, bSite, 'p1', true)).toBe(true);
    expect(isForeignSpaceportSite(state, bSite, 'p1')).toBe(BLOCKER_SPACEPORT_SITES_BLOCK_END_NODES);
    // The validator and a real move follow the default: a ship may end on the blocker spaceport's site …
    teleport(state, approachNode(state, bSite));
    expect(validateEndNode(state, ship(state), bSite)).toBeNull();
    const parked = move(state, [bSite]);
    expect(ship(parked).nodeId).toBe(bSite);
    // … and the blocker colony / spaceport nodes themselves stay unavailable (one piece per intersection).
    expect(validateEndNode(state, ship(state), blockerPort.nodeId)?.code).toBe('invalidTarget');
    for (const b of Object.values(state.board.settlements).filter((s) => s.owner === null)) {
      expect(validateEndNode(state, ship(state), b.nodeId)).not.toBeNull();
    }
    // A 4-player game has no blocker spaceport at all, so the flag changes nothing there.
    const four = createBeginnerGame({ players: [...THREE, { id: 'p4', name: 'Dee', color: 'white' }], seed: 'four' });
    expect(Object.values(four.board.settlements).some((s) => s.owner === null)).toBe(false);
  });

  it('a trade ship never ends on a colony site; a colony ship may park there', () => {
    const state = flightState();
    teleport(state, 'N(5,3)');
    const trade = structuredClone(state);
    ship(trade).kind = 'trade';
    moveFails(trade, [N4_SITE], 'ruleViolation');
    const parked = move(state, [N4_SITE]);
    expect(ship(parked).nodeId).toBe(N4_SITE);
    expect(ship(parked).mustFoundOrLeave).toBe(false); // flagged only at endTurn
  });

  it('a colony ship never ends on a docking point', () => {
    const state = flightState();
    teleport(state, approachNode(state, GREEN_DOCK));
    moveFails(state, [GREEN_DOCK], 'ruleViolation');
  });

  it('a trade ship ends on a docking point only if it can found now (freight pods > stations); then pendingFound gates everything', () => {
    const state = flightState();
    const me = state.activePlayer;
    ship(state).kind = 'trade';
    teleport(state, approachNode(state, GREEN_DOCK));
    player(state, me).mothership.freightPods = 0;
    moveFails(state, [GREEN_DOCK], 'ruleViolation');

    player(state, me).mothership.freightPods = 1;
    const docked = move(state, [GREEN_DOCK]);
    expect(ship(docked).nodeId).toBe(GREEN_DOCK);
    expect(docked.turn.pendingFound).toBe(SHIP);
    fails(docked, { type: 'endTurn', playerId: me }, 'ruleViolation');
    fails(docked, { type: 'moveShip', playerId: me, shipId: SHIP, path: ['S(1,8)'] }, 'ruleViolation');
    const shakeAgain = structuredClone(docked);
    shakeAgain.phase = 'tradeBuild';
    delete shakeAgain.turn.baseSpeed;
    fails(shakeAgain, { type: 'shakeMothership', playerId: me }, 'ruleViolation');

    // The founding handler consumes the marker.
    const founded = ok(docked, { type: 'foundTradeStation', playerId: me, shipId: SHIP, dockIndex: 0, friendshipCardId: 'axxa' });
    expect(founded.turn.pendingFound).toBeUndefined();
    expect(founded.board.ships[SHIP]).toBeUndefined();
    ok(founded, { type: 'endTurn', playerId: me });

    // With one station already there, 1 pod is no longer enough.
    const again = flightState();
    ship(again).kind = 'trade';
    teleport(again, approachNode(again, GREEN_DOCK));
    player(again, me).mothership.freightPods = 1;
    getSector(again.board, 'N3').docks![0] = 'p2';
    moveFails(again, [GREEN_DOCK], 'ruleViolation');
    player(again, me).mothership.freightPods = 2;
    expect(move(again, [GREEN_DOCK]).turn.pendingFound).toBe(SHIP);
  });
});

// ---------------------------------------------------------------------------
// Explore + tokens
// ---------------------------------------------------------------------------

describe('explore (§9.3)', () => {
  it('reaching a node next to an unexplored system flips its discs, turns P/I discs into tokens and marks it explored', () => {
    const state = flightState();
    const before = computeProduction(state, 9);
    state.board.settlements['S(4,5)'] = { nodeId: 'S(4,5)', kind: 'colony', color: 'red', owner: 'p1' };
    expect(computeProduction(state, 9).paid['p1']!.carbon).toBe(0);
    expect(before.paid['p1']!.carbon).toBe(0);

    const next = move(state, N4_APPROACH);
    const n4 = getSector(next.board, 'N4');
    expect(n4.explored).toBe(true);
    expect(next.board.planets['P(4,5)']!.disc).toMatchObject({ label: '9', faceUp: true });
    expect(next.board.planets['P(5,4)']!.disc).toMatchObject({ label: '4', faceUp: true });
    expect(next.board.planets[PIRATE_PLANET]!.token).toEqual({ kind: 'pirateBase', value: 5 });
    expect(next.board.planets[PIRATE_PLANET]!.disc).toBeNull();
    expect(next.log.some((e) => /System N4 explored/.test(e.message))).toBe(true);
    // Production now works on the flipped numbers.
    expect(computeProduction(next, 9).paid['p1']!.carbon).toBe(1);
    expect(computeProduction(next, 4).paid['p1']!.food).toBe(1);
    // Other systems untouched; the pirate base (cannons 0 < 5) is still there.
    expect(getSector(next.board, 'N1').explored).toBe(false);
    expect(player(next, 'p1').medals.pirate).toBe(0);
  });

  it('explores at an intermediate node of the path and never twice', () => {
    const state = flightState();
    state.turn.speed = 7;
    const next = move(state, [...N4_APPROACH, 'S(4,3)']);
    expect(ship(next).nodeId).toBe('S(4,3)');
    expect(getSector(next.board, 'N4').explored).toBe(true);
    const events = next.log.filter((e) => /System N4 explored/.test(e.message));
    expect(events).toHaveLength(1);
    const back = move(next, ['N(5,3)']);
    expect(back.log.filter((e) => /System N4 explored/.test(e.message))).toHaveLength(1);
  });

  it('exploreAt without a ship only flips; Catanian and explored systems are ignored', () => {
    const state = flightState();
    expect(exploreAt(state, START)).toEqual([]);
    expect(exploreAt(state, 'N(5,3)')).toEqual(['N4']);
    expect(exploreAt(state, 'N(5,3)')).toEqual([]);
    expect(nodeTouchesToken(state, 'N(5,3)')).toBe(true);
    expect(nodeTouchesToken(state, START)).toBe(false);
  });
});

describe('pirate bases and ice planets (§9.6)', () => {
  function arriveAtPirate(cannons: number, cards: FriendshipCardId[] = []): GameState {
    const state = flightState();
    player(state, 'p1').mothership.cannons = cannons;
    player(state, 'p1').friendshipCards = cards;
    return move(state, N4_APPROACH);
  }

  it('defeats the base when combat strength >= the token value, not below', () => {
    const lost = arriveAtPirate(4);
    expect(lost.board.planets[PIRATE_PLANET]!.token).toEqual({ kind: 'pirateBase', value: 5 });
    expect(player(lost, 'p1').medals.pirate).toBe(0);
    expect(lost.reserveDiscs).toHaveLength(5);

    const won = arriveAtPirate(5);
    const planet = won.board.planets[PIRATE_PLANET]!;
    expect(planet.token).toBeNull();
    expect(player(won, 'p1').medals.pirate).toBe(1);
    expect(planet.disc).toMatchObject({ label: '3', back: 'reserve', faceUp: true });
    expect(won.reserveDiscs.map((d) => d.label)).toEqual(['9', '10', '11', '11']);
    expect(won.log.some((e) => /defeated the pirate base \(5\)/.test(e.message))).toBe(true);
    // Medal → VP.
    expect(computeVp(won, 'p1')).toBe(computeVp(lost, 'p1') + 1);
    expect(player(won, 'p1').vp).toBe(player(lost, 'p1').vp + 1);
    // The reserve disc produces for an adjacent colony from now on.
    won.board.settlements['S(3,4)'] = { nodeId: 'S(3,4)', kind: 'colony', color: 'red', owner: 'p1' };
    expect(computeProduction(won, 3).paid['p1']!.fuel).toBe(1);
  });

  it('counts Scientist combat bonuses (Kha-Star +2, Khor-Nem +1)', () => {
    expect(player(arriveAtPirate(3, ['khaStar']), 'p1').medals.pirate).toBe(1);
    expect(player(arriveAtPirate(2, ['khaStar']), 'p1').medals.pirate).toBe(0);
    expect(player(arriveAtPirate(4, ['khorNem']), 'p1').medals.pirate).toBe(1);
    expect(player(arriveAtPirate(4, ['hirAkas']), 'p1').medals.pirate).toBe(0);
  });

  it('is immediate: the base falls when the ship passes by, even if it ends elsewhere', () => {
    const state = flightState();
    player(state, 'p1').mothership.cannons = 6;
    const next = move(state, [...N4_APPROACH, 'S(4,3)']);
    expect(ship(next).nodeId).toBe('S(4,3)');
    expect(next.board.planets[PIRATE_PLANET]!.token).toBeNull();
    expect(player(next, 'p1').medals.pirate).toBe(1);
  });

  it('a ship arriving later at an already revealed base also defeats it', () => {
    const state = flightState();
    exploreAt(state, 'N(5,3)');
    player(state, 'p1').mothership.cannons = 5;
    teleport(state, 'S(4,3)');
    const next = move(state, ['N(5,3)']);
    expect(player(next, 'p1').medals.pirate).toBe(1);
  });

  it('terraforms an ice planet with freightPods >= value and places the next reserve disc', () => {
    const state = flightState();
    const node = Object.values(state.board.nodes).find(
      (n) => n.siteType === 'plain' && n.adjacentPlanets.includes(ICE_PLANET),
    )!;
    exploreAt(state, node.id);
    expect(state.board.planets[ICE_PLANET]!.token).toEqual({ kind: 'icePlanet', value: 3 });
    teleport(state, node.id);

    player(state, 'p1').mothership.freightPods = 2;
    expect(checkSpecialTokens(state, SHIP)).toEqual([]);
    expect(player(state, 'p1').medals.ice).toBe(0);

    player(state, 'p1').mothership.freightPods = 3;
    expect(checkSpecialTokens(state, SHIP)).toEqual([{ kind: 'icePlanet', value: 3 }]);
    expect(player(state, 'p1').medals.ice).toBe(1);
    expect(state.board.planets[ICE_PLANET]!.token).toBeNull();
    expect(state.board.planets[ICE_PLANET]!.disc).toMatchObject({ label: '3', faceUp: true });
    expect(state.reserveDiscs).toHaveLength(4);
    expect(computeVp(state, 'p1')).toBe(4 + 1);
    expect(checkSpecialTokens(state, SHIP)).toEqual([]); // nothing left to claim
  });

  it('a ship already adjacent when its owner reaches the threshold claims the token at the start of the flight phase, and a parked colony ship may then found (§9.6)', () => {
    const state = flightState();
    state.turn.speed = 6;
    const parked = move(state, [...N4_APPROACH, N4_SITE]);
    expect(parked.board.planets[PIRATE_PLANET]!.token).toEqual({ kind: 'pirateBase', value: 5 });
    fails(parked, { type: 'foundColony', playerId: 'p1', shipId: SHIP }, 'ruleViolation');
    const next = cycleTo(ok(parked, { type: 'endTurn', playerId: 'p1' }), 'p1');
    expect(ship(next).mustFoundOrLeave).toBe(true);
    // Cannons built during Trade & Build; the ship does not move.
    next.phase = 'tradeBuild';
    delete next.turn.baseSpeed;
    delete next.turn.speed;
    const tooFew = structuredClone(next);
    player(tooFew, 'p1').mothership.cannons = 4;
    const stillThere = ok(tooFew, { type: 'shakeMothership', playerId: 'p1' }, shakeRng(['yellow', 'red']));
    expect(stillThere.board.planets[PIRATE_PLANET]!.token).not.toBeNull();
    fails(stillThere, { type: 'foundColony', playerId: 'p1', shipId: SHIP }, 'ruleViolation');

    player(next, 'p1').mothership.cannons = 5;
    const shaken = ok(next, { type: 'shakeMothership', playerId: 'p1' }, shakeRng(['yellow', 'red']));
    expect(shaken.board.planets[PIRATE_PLANET]!.token).toBeNull();
    expect(player(shaken, 'p1').medals.pirate).toBe(1);
    expect(ship(shaken).nodeId).toBe(N4_SITE);
    const founded = ok(shaken, { type: 'foundColony', playerId: 'p1', shipId: SHIP });
    expect(founded.board.settlements[N4_SITE]).toMatchObject({ kind: 'colony', owner: 'p1' });
  });

  it('leaves the planet discless when no reserve disc remains', () => {
    const state = flightState();
    state.reserveDiscs = [];
    player(state, 'p1').mothership.cannons = 5;
    const next = move(state, N4_APPROACH);
    expect(next.board.planets[PIRATE_PLANET]!.token).toBeNull();
    expect(next.board.planets[PIRATE_PLANET]!.disc).toBeNull();
    expect(player(next, 'p1').medals.pirate).toBe(1);
  });
});

// ---------------------------------------------------------------------------
// mustFoundOrLeave lifecycle + endTurn gating
// ---------------------------------------------------------------------------

describe('mustFoundOrLeave lifecycle (§9.2)', () => {
  function parkedAndFlagged(): GameState {
    const state = flightState();
    teleport(state, 'N(5,3)');
    const parked = move(state, [N4_SITE]);
    const ended = ok(parked, { type: 'endTurn', playerId: 'p1' });
    expect(ship(ended).mustFoundOrLeave).toBe(true);
    expect(ended.log.some((e) => /parked on colony site S\(4,4\)/.test(e.message))).toBe(true);
    return cycleTo(ended, 'p1');
  }

  it('a colony ship parked on a colony site is flagged at endTurn; a ship elsewhere is not', () => {
    const state = flightState();
    const ended = ok(move(state, ['S(4,2)']), { type: 'endTurn', playerId: 'p1' });
    expect(ship(ended).mustFoundOrLeave).toBe(false);
    parkedAndFlagged();
  });

  it('on the next own turn the ship must found or leave: endTurn is rejected while it still sits there', () => {
    const state = parkedAndFlagged();
    fails(state, { type: 'endTurn', playerId: 'p1' }, 'ruleViolation');
    // Pinned by an encounter: allowed, flag stays.
    const pinned = structuredClone(state);
    pinned.turn.immobilized = [SHIP];
    const after = ok(pinned, { type: 'endTurn', playerId: 'p1' });
    expect(ship(after).mustFoundOrLeave).toBe(true);
    // Leaving clears the flag and records the site; ending the turn elsewhere is fine and clears leftSite.
    const left = move(state, ['N(5,3)']);
    expect(ship(left).mustFoundOrLeave).toBe(false);
    expect(ship(left).leftSite).toBe(N4_SITE);
    const done = ok(left, { type: 'endTurn', playerId: 'p1' });
    expect(ship(done).leftSite).toBeUndefined();
    expect(ship(done).mustFoundOrLeave).toBe(false);
  });

  it('may not return to the flagged site this turn except by founding (same call or a later call)', () => {
    const state = parkedAndFlagged();
    moveFails(state, ['N(5,3)', N4_SITE], 'ruleViolation');
    const left = move(state, ['N(5,3)']);
    moveFails(left, [N4_SITE], 'ruleViolation');
    // Another colony site of the same system is fine, and gets flagged at endTurn.
    const other = move(left, ['S(3,3)', 'N(4,4)', 'S(3,4)']);
    expect(ship(other).nodeId).toBe('S(3,4)');
    const ended = ok(other, { type: 'endTurn', playerId: 'p1' });
    expect(ship(ended).mustFoundOrLeave).toBe(true);
    expect(ship(ended).leftSite).toBeUndefined();
  });

  it('a ship flagged on an opponent\'s new spaceport site must leave if it can move', () => {
    const state = flightState();
    const theirs = spaceportsOf(state, 'p3')[0]!;
    const site = spaceportSites(state.board, theirs.nodeId).find((n) => !Object.values(state.board.ships).some((s) => s.nodeId === n))!;
    teleport(state, site);
    ship(state).mustFoundOrLeave = true;
    fails(state, { type: 'endTurn', playerId: 'p1' }, 'ruleViolation');
    const noSpeed = structuredClone(state);
    noSpeed.turn.speed = 0;
    ok(noSpeed, { type: 'endTurn', playerId: 'p1' });
    const pinned = structuredClone(state);
    pinned.turn.immobilized = [SHIP];
    ok(pinned, { type: 'endTurn', playerId: 'p1' });
    const moved = move(state, [approachNode(state, site)]);
    expect(ship(moved).mustFoundOrLeave).toBe(false);
    ok(moved, { type: 'endTurn', playerId: 'p1' });
  });
});

describe('endTurn gating and reset', () => {
  it('from tradeBuild only without ships ("shake the mothership first")', () => {
    const state = tradeBuildState();
    fails(state, { type: 'endTurn', playerId: state.activePlayer }, 'ruleViolation');
    for (const s of shipsOf(state, state.activePlayer)) delete state.board.ships[s.id];
    ok(state, { type: 'endTurn', playerId: state.activePlayer });
  });

  it('not from flight.encounter; from flight.move it resets every flight field', () => {
    const state = flightState();
    state.turn.shake = ['red', 'yellow'];
    state.turn.shipMovesUsed = { [SHIP]: 2 };
    state.turn.immobilized = ['ship:red:2'];
    state.turn.encounter = { cardId: 3, stage: 'done', revealed: [], queue: [] };
    const enc = structuredClone(state);
    enc.phase = 'flight.encounter';
    fails(enc, { type: 'endTurn', playerId: 'p1' }, 'wrongPhase');
    const next = ok(state, { type: 'endTurn', playerId: 'p1' });
    expect(next.turn).toEqual(freshTurnState());
    expect(next.phase).toBe('production');
    expect(next.activePlayer).toBe('p2');
  });

  it('places a pending trade-ship marker for the next player as soon as their turn starts', () => {
    const state = flightState();
    state.pendingTradeShips['p2'] = 1;
    const next = ok(state, { type: 'endTurn', playerId: 'p1' });
    expect(next.pendingTradeShips['p2']).toBe(0);
    const trade = shipsOf(next, 'p2').filter((s) => s.kind === 'trade');
    expect(trade).toHaveLength(1);
    expect(spaceportSites(next.board, spaceportsOf(next, 'p2')[0]!.nodeId)).toContain(trade[0]!.nodeId);
  });
});

// ---------------------------------------------------------------------------
// Space jump
// ---------------------------------------------------------------------------

describe('space jump (§9.7)', () => {
  it('validateJumpTarget obeys the no-blockade rules', () => {
    const state = flightState();
    expect(validateJumpTarget(state, SHIP, START)?.code).toBe('invalidTarget');
    expect(validateJumpTarget(state, SHIP, 'S(3,1)')?.code).toBe('invalidTarget');
    expect(validateJumpTarget(state, SHIP, ship(state, 'ship:blue:1').nodeId)?.code).toBe('invalidTarget');
    const foreignSite = spaceportSites(state.board, spaceportsOf(state, 'p2')[0]!.nodeId).find((n) => !Object.values(state.board.ships).some((s) => s.nodeId === n))!;
    expect(validateJumpTarget(state, SHIP, foreignSite)?.code).toBe('ruleViolation');
    expect(validateJumpTarget(state, SHIP, GREEN_DOCK)?.code).toBe('ruleViolation'); // colony ship
    expect(validateJumpTarget(state, SHIP, N4_SITE)).toBeNull(); // colony ship may park
    expect(validateJumpTarget(state, 'ship:red:9', 'N(5,3)')?.code).toBe('invalidTarget');
    ship(state).kind = 'trade';
    expect(validateJumpTarget(state, SHIP, N4_SITE)?.code).toBe('ruleViolation'); // trade ship → colony site
    expect(validateJumpTarget(state, SHIP, GREEN_DOCK)?.code).toBe('ruleViolation'); // 0 pods
    expect(validateJumpTarget(state, SHIP, 'N(5,3)')).toBeNull();
  });

  it('applySpaceJump moves the ship, explores on arrival, claims tokens and ends its movement', () => {
    const state = flightState();
    player(state, 'p1').mothership.cannons = 5;
    applySpaceJump(state, SHIP, 'N(5,3)');
    expect(ship(state).nodeId).toBe('N(5,3)');
    expect(getSector(state.board, 'N4').explored).toBe(true);
    expect(player(state, 'p1').medals.pirate).toBe(1);
    expect(state.turn.shipMovesUsed[SHIP]).toBe(state.turn.speed);
    moveFails(state, ['S(4,3)'], 'ruleViolation');
    expect(sectorsAdjacentToNode(state.board, 'N(5,3)').map((s) => s.id)).toContain('N4');
  });

  it('a trade ship jumping onto a docking point must found at once', () => {
    const state = flightState();
    ship(state).kind = 'trade';
    player(state, 'p1').mothership.freightPods = 1;
    expect(validateJumpTarget(state, SHIP, GREEN_DOCK)).toBeNull();
    applySpaceJump(state, SHIP, GREEN_DOCK);
    expect(state.turn.pendingFound).toBe(SHIP);
  });
});

// Keep `applyAction` and `rng` referenced for ad-hoc debugging of the fixture.
void applyAction;
void rng;
