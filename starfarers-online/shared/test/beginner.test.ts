import { describe, expect, it } from 'vitest';
import { createBeginnerGame, type PlayerSpec } from '../src/setup/beginner.js';
import { computeVp } from '../src/vp.js';
import { RESOURCES, type GameState, type PlayerColor } from '../src/types.js';
import { colonySiteBetween, neighborsOf, shipsOf, settlementsOf } from '../src/board/query.js';
import { beginnerPlacement } from '../src/board/data.js';
import { vertexHexes, hexEquals } from '../src/board/geometry.js';
import { FRIENDSHIP_CARDS } from '../src/config.js';

const four: PlayerSpec[] = [
  { id: 'p1', name: 'Ann', color: 'red' },
  { id: 'p2', name: 'Bob', color: 'blue' },
  { id: 'p3', name: 'Cid', color: 'yellow' },
  { id: 'p4', name: 'Dee', color: 'white' },
];
const three = four.slice(0, 3);

function supplyTotal(state: GameState): number {
  return RESOURCES.reduce((n, r) => n + state.supply[r], 0);
}

function checkCommon(state: GameState, n: number) {
  expect(state.players).toHaveLength(n);
  expect(state.phase).toBe('production');
  expect(state.variant).toBe('beginner');
  expect(state.turnNumber).toBe(1);
  expect(state.winner).toBeNull();
  expect(state.openTrade).toBeNull();

  for (const p of state.players) {
    expect(p.hand).toHaveLength(3);
    expect(p.vp).toBe(4);
    expect(computeVp(state, p.id)).toBe(4);
    expect(p.famePieces).toBe(1);
    expect(p.mothership).toEqual({ boosters: 1, cannons: 0, freightPods: 0 });
    expect(p.pieces).toEqual({ coloniesLeft: 5, stationsLeft: 7, transportsLeft: 2, shipyardsLeft: 2 });
    const settlements = settlementsOf(state, p.id);
    expect(settlements.filter((s) => s.kind === 'colony')).toHaveLength(2);
    expect(settlements.filter((s) => s.kind === 'spaceport')).toHaveLength(1);
    const ships = shipsOf(state, p.id);
    expect(ships).toHaveLength(1);
    expect(ships[0]!.kind).toBe('colony');
    // Ship sits on one of the two spaceport sites, on the shipSide planet's outer edge.
    const sp = settlements.find((s) => s.kind === 'spaceport')!;
    expect(neighborsOf(state.board, sp.nodeId)).toContain(ships[0]!.nodeId);
    const pieces = beginnerPlacement().startingPieces![p.color];
    expect(vertexHexes(ships[0]!.nodeId).some((h) => hexEquals(h, pieces.spaceport.shipSide))).toBe(true);
    expect(colonySiteBetween(state.board, pieces.spaceport.between[0], pieces.spaceport.between[1])).toBe(sp.nodeId);
  }

  // Supply + reserve + hands = 100.
  const dealt = 3 * n;
  expect(state.reservePile).toHaveLength(40 - dealt);
  expect(supplyTotal(state)).toBe(100 - 40);
  expect(supplyTotal(state) + state.reservePile.length + dealt).toBe(100);
  for (const r of RESOURCES) {
    const inReserve = state.reservePile.filter((c) => c === r).length;
    const inHands = state.players.flatMap((p) => p.hand).filter((c) => c === r).length;
    expect(state.supply[r] + inReserve + inHands).toBe(20);
  }

  expect(state.upgradesTray).toEqual({ boosters: 24 - n, cannons: 24, freightPods: 20, famePieces: 40 - n });

  expect(state.encounterDeck).toHaveLength(32);
  expect([...state.encounterDeck].sort((a, b) => a - b)).toEqual(Array.from({ length: 32 }, (_, i) => i + 1));
  expect(state.encounterDiscard).toEqual([]);

  for (const civ of ['greenFolk', 'scientists', 'diplomats', 'merchants'] as const) {
    expect(state.friendshipCards[civ]).toHaveLength(5);
    for (const id of state.friendshipCards[civ]) expect(FRIENDSHIP_CARDS[id].civ).toBe(civ);
    expect(state.friendshipMarkers[civ]).toBeNull();
  }
  expect(state.reserveDiscs.map((d) => d.label).sort()).toEqual(['10', '11', '11', '3', '9']);

  // Turn order: list order starting from the starter.
  expect(state.turnOrder).toHaveLength(n);
  expect(state.turnOrder[0]).toBe(state.activePlayer);
  const ids = state.players.map((p) => p.id);
  const start = ids.indexOf(state.activePlayer);
  expect(state.turnOrder).toEqual([...ids.slice(start), ...ids.slice(0, start)]);

  // Discs: Catanian face up with the beginner values; unexplored face down, one per icon per system.
  for (const sector of Object.values(state.board.sectors)) {
    if (sector.kind !== 'system') continue;
    const discs = sector.planetIds.map((id) => state.board.planets[id]!.disc!);
    expect(discs.every((d) => d !== null)).toBe(true);
    if (sector.region === 'catanian') {
      expect(sector.explored).toBe(true);
      expect(discs.every((d) => d.faceUp)).toBe(true);
    } else {
      expect(sector.explored).toBe(false);
      expect(discs.every((d) => !d.faceUp)).toBe(true);
      expect(discs.map((d) => d.back).sort()).toEqual(['br', 'hex', 'tri']);
      for (const id of sector.planetIds) {
        const planet = state.board.planets[id]!;
        expect(planet.disc!.back).toBe(planet.icon);
      }
    }
  }
  expect(state.board.planets['P(0,1)']!.disc!.label).toBe('11');
  expect(state.board.planets['P(4,1)']!.disc!.numbers).toEqual([3, 12]);
  expect(state.board.planets['P(9,1)']!.disc!.numbers).toEqual([2, 11]);
  const allUnexplored = Object.values(state.board.planets)
    .filter((p) => p.icon !== undefined)
    .map((p) => p.disc!.label)
    .sort();
  expect(allUnexplored).toEqual(
    ['3', '4', '4', '11', '12', '3', '4', '11', '2', '5', '5', '6', '9', '5', '8', '9', '10', '10', '10', 'P4', 'P5', 'P6', 'I3', 'I4'].sort(),
  );
  const special = Object.values(state.board.planets).filter((p) => p.disc?.special);
  expect(special).toHaveLength(5);
  for (const p of special) expect(p.icon).toBe('hex');
  expect(state.log).toHaveLength(1);
}

describe('createBeginnerGame', () => {
  it('sets up a 4-player game', () => {
    const state = createBeginnerGame({ players: four, seed: 'four' });
    checkCommon(state, 4);
    expect(state.blockerColor).toBeNull();
    expect(Object.values(state.board.settlements)).toHaveLength(12);
    expect(Object.values(state.board.ships)).toHaveLength(4);
    expect(Object.values(state.board.settlements).every((s) => s.owner !== null)).toBe(true);
  });

  it('sets up a 3-player game with the 4th colour as blockers', () => {
    const state = createBeginnerGame({ players: three, seed: 'three' });
    checkCommon(state, 3);
    expect(state.blockerColor).toBe<PlayerColor>('white');
    const blockers = Object.values(state.board.settlements).filter((s) => s.owner === null);
    expect(blockers).toHaveLength(3);
    expect(blockers.every((b) => b.color === 'white')).toBe(true);
    expect(blockers.filter((b) => b.kind === 'spaceport')).toHaveLength(1);
    expect(state.players.some((p) => p.color === 'white')).toBe(false);
    expect(Object.values(state.board.ships)).toHaveLength(3);
    expect(Object.values(state.board.settlements)).toHaveLength(12);
    expect(Object.keys(state.pendingTradeShips).sort()).toEqual(['p1', 'p2', 'p3']);
  });

  it('is deterministic for the same seed and differs for another seed', () => {
    const a = createBeginnerGame({ players: four, seed: 'same' });
    const b = createBeginnerGame({ players: four, seed: 'same' });
    expect(a).toEqual(b);
    const c = createBeginnerGame({ players: four, seed: 'other' });
    expect(c.reservePile).not.toEqual(a.reservePile);
  });

  it('the starting player is chosen by the rng', () => {
    const starters = new Set<string>();
    for (let i = 0; i < 40; i++) starters.add(createBeginnerGame({ players: four, seed: `s${i}` }).activePlayer);
    expect(starters.size).toBeGreaterThan(1);
  });

  it('rejects bad player lists', () => {
    expect(() => createBeginnerGame({ players: four.slice(0, 2), seed: 'x' })).toThrow();
    expect(() => createBeginnerGame({ players: [...four, { id: 'p5', name: 'E', color: 'red' }], seed: 'x' })).toThrow();
    expect(() => createBeginnerGame({ players: [four[0]!, four[1]!, { ...four[2]!, color: 'red' }], seed: 'x' })).toThrow();
    expect(() => createBeginnerGame({ players: [four[0]!, four[1]!, { ...four[2]!, id: 'p1' }], seed: 'x' })).toThrow();
  });
});
