/**
 * Variable set-ups (spec §3.1 strategic paragraph, §3.2): strategic, explorer
 * and wild space tile distribution, disc placement / pools, the §15 graph
 * invariants on a shuffled board, and seed determinism.
 */

import { describe, expect, it } from 'vitest';
import { boardLayout } from '../src/board/data.js';
import { hexCenter, sharedVertex } from '../src/board/geometry.js';
import { colonySiteNodes, dockingPointNodes, settlementsOf, shipsOf } from '../src/board/query.js';
import { STRATEGIC_RETURNED_EMPTY, VARIABLE_SETUP_START_LOBE, WILD_SPACE_SLOT_ORDER } from '../src/config.js';
import { createBeginnerGame } from '../src/setup/beginner.js';
import { GAME_VARIANTS, GAME_VARIANT_LABELS, createGame, isGameVariant } from '../src/setup/index.js';
import { createExplorerGame, createStrategicGame, createWildSpaceGame } from '../src/setup/variants.js';
import type { GameState, GameVariant, Sector } from '../src/types.js';

const FOUR = [
  { id: 'p1', name: 'Ann', color: 'red' as const },
  { id: 'p2', name: 'Bob', color: 'blue' as const },
  { id: 'p3', name: 'Cid', color: 'yellow' as const },
  { id: 'p4', name: 'Dee', color: 'white' as const },
];
const THREE = FOUR.slice(0, 3);

const layout = boardLayout();
const ALL_TILES = Object.keys(layout.tiles).sort();
const DISC_INVENTORY = [...layout.numberDiscs.tri, ...layout.numberDiscs.br, ...layout.numberDiscs.hex].sort();

function slotSectors(state: GameState): Sector[] {
  return Object.values(state.board.sectors).filter((s) => s.region !== 'catanian');
}

function starsOf(sector: Sector): number {
  const tile = layout.tiles[sector.tileId];
  if (!tile) throw new Error(`no tile ${sector.tileId}`);
  return tile.stars;
}

/** Strategic / explorer share the tile distribution rules. */
function checkStrategicDistribution(state: GameState) {
  const slots = slotSectors(state);
  expect(slots).toHaveLength(15);
  const tiles = slots.map((s) => s.tileId);
  expect(new Set(tiles).size).toBe(15);
  for (const s of slots) {
    expect(starsOf(s)).toBe(s.region === 'near' ? 1 : 2);
    const slot = layout.slots.find((l) => l.id === s.id)!;
    expect(slot.region).toBe(s.region);
  }
  const returned = ALL_TILES.filter((t) => !tiles.includes(t));
  expect(returned).toHaveLength(1);
  const returnedTile = layout.tiles[returned[0]!]!;
  expect(returnedTile.type).toBe('empty');
  expect(returnedTile.stars).toBe(1);
  // 8 systems, 4 outposts, 3 empties on the board.
  expect(slots.filter((s) => s.kind === 'system')).toHaveLength(8);
  expect(slots.filter((s) => s.kind === 'outpost')).toHaveLength(4);
  expect(slots.filter((s) => s.kind === 'empty')).toHaveLength(3);
}

function checkCatanianTrios(state: GameState) {
  for (const sys of layout.catanian) {
    const sector = state.board.sectors[sys.letter]!;
    expect(sector.discovered).toBe(true);
    expect(sector.explored).toBe(true);
    const labels = sector.planetIds.map((id) => state.board.planets[id]!.disc!);
    expect(labels.every((d) => d.faceUp && d.back === sys.letter)).toBe(true);
    expect(labels.map((d) => d.label).sort()).toEqual([...sys.discs].sort());
  }
}

/** Spec §15 graph sanity on a board with 8 systems + 4 outposts. */
function checkGraphInvariants(state: GameState) {
  const board = state.board;
  const sites = colonySiteNodes(board);
  expect(sites.filter((n) => board.sectors[n.sectorId!]!.region === 'catanian')).toHaveLength(12);
  expect(sites.filter((n) => board.sectors[n.sectorId!]!.region !== 'catanian')).toHaveLength(24);
  expect(dockingPointNodes(board)).toHaveLength(4);
  for (const s of Object.values(board.sectors)) {
    if (s.kind !== 'system') continue;
    const centre = sharedVertex(s.lobes);
    expect(board.nodes[centre]).toBeUndefined();
    for (const [a, b] of board.edges) {
      expect(a).not.toBe(centre);
      expect(b).not.toBe(centre);
    }
  }
  for (const [id, nbrs] of Object.entries(board.adjacency)) {
    expect(nbrs.length).toBeLessThanOrEqual(3);
    for (const m of nbrs) expect(board.adjacency[m]).toContain(id);
  }
}

function checkStartingPieces(state: GameState, n: number) {
  for (const p of state.players) {
    expect(p.vp).toBe(4);
    expect(p.hand).toHaveLength(3);
    const settlements = settlementsOf(state, p.id);
    expect(settlements.filter((s) => s.kind === 'colony')).toHaveLength(2);
    expect(settlements.filter((s) => s.kind === 'spaceport')).toHaveLength(1);
    expect(shipsOf(state, p.id)).toHaveLength(1);
  }
  expect(Object.values(state.board.settlements)).toHaveLength(12);
  expect(state.blockerColor).toBe(n === 3 ? 'white' : null);
  expect(Object.values(state.board.settlements).filter((s) => s.owner === null)).toHaveLength(n === 3 ? 3 : 0);
  expect(state.phase).toBe('production');
  expect(state.turnOrder).toHaveLength(n);
}

describe('strategic set-up', () => {
  const state = createStrategicGame({ players: FOUR, seed: 'strategic-1' });

  it('fills the 15 slots: 1-star tiles near, 2-star tiles far, one 1-star empty returned, all unique', () => {
    expect(state.variant).toBe('strategic');
    checkStrategicDistribution(state);
    expect(['random', 'E1', 'E2']).toContain(STRATEGIC_RETURNED_EMPTY);
  });

  it('places every tile face up (discovered) with the systems unexplored', () => {
    for (const s of slotSectors(state)) {
      expect(s.discovered).toBe(true);
      expect(s.explored).toBe(s.kind !== 'system');
    }
  });

  it('shuffles each Catanian trio within its system', () => {
    checkCatanianTrios(state);
    // Over many seeds the beginner assignment is not the only one produced.
    const alphaOrders = new Set<string>();
    for (let i = 0; i < 20; i++) {
      const g = createStrategicGame({ players: FOUR, seed: `trio-${i}` });
      alphaOrders.add(g.board.sectors['alpha']!.planetIds.map((id) => g.board.planets[id]!.disc!.label).join(','));
    }
    expect(alphaOrders.size).toBeGreaterThan(1);
  });

  it('puts a face-down disc with the matching back icon on every planet and consumes all 24 discs', () => {
    const iconPlanets = Object.values(state.board.planets).filter((p) => p.icon !== undefined);
    expect(iconPlanets).toHaveLength(24);
    for (const p of iconPlanets) {
      expect(p.disc).not.toBeNull();
      expect(p.disc!.faceUp).toBe(false);
      expect(p.disc!.back).toBe(p.icon);
      expect(p.token).toBeNull();
    }
    expect(iconPlanets.map((p) => p.disc!.label).sort()).toEqual(DISC_INVENTORY);
    expect(iconPlanets.filter((p) => p.disc!.special)).toHaveLength(5);
    expect(state.discPools).toEqual({ tri: [], br: [], hex: [] });
    for (const s of slotSectors(state)) {
      if (s.kind !== 'system') continue;
      expect(s.planetIds.map((id) => state.board.planets[id]!.disc!.back).sort()).toEqual(['br', 'hex', 'tri']);
    }
  });

  it('keeps the §15 graph invariants and the beginner starting positions (3 and 4 players)', () => {
    checkGraphInvariants(state);
    checkStartingPieces(state, 4);
    const three = createStrategicGame({ players: THREE, seed: 'strategic-3p' });
    checkGraphInvariants(three);
    checkStartingPieces(three, 3);
  });

  it('orients every placed system from the configured start lobe', () => {
    expect(VARIABLE_SETUP_START_LOBE).toBe(0);
    // Planets of a placed system are the tile's planets, each exactly once.
    for (const s of slotSectors(state)) {
      if (s.kind !== 'system') continue;
      const tile = layout.tiles[s.tileId]!;
      const placed = s.planetIds.map((id) => state.board.planets[id]!.resource).sort();
      expect(placed).toEqual(tile.planets!.map((p) => p.resource).sort());
    }
  });

  it('is deterministic for the same seed and different for another', () => {
    expect(createStrategicGame({ players: FOUR, seed: 'strategic-1' })).toEqual(state);
    const other = createStrategicGame({ players: FOUR, seed: 'strategic-2' });
    expect(slotSectors(other).map((s) => s.tileId)).not.toEqual(slotSectors(state).map((s) => s.tileId));
  });

  it('does not change the beginner game', () => {
    const a = createBeginnerGame({ players: FOUR, seed: 'same' });
    expect(a.variant).toBe('beginner');
    expect(a.discPools).toEqual({ tri: [], br: [], hex: [] });
    expect(Object.values(a.board.sectors).every((s) => s.discovered)).toBe(true);
    expect(a.board.sectors['N1']!.tileId).toBe('S2');
  });
});

describe('explorer set-up', () => {
  const state = createExplorerGame({ players: FOUR, seed: 'explorer-1' });

  it('uses the strategic distribution with every slot tile face down', () => {
    expect(state.variant).toBe('explorer');
    checkStrategicDistribution(state);
    checkCatanianTrios(state);
    checkGraphInvariants(state);
    checkStartingPieces(state, 4);
    for (const s of slotSectors(state)) {
      expect(s.discovered).toBe(false);
      expect(s.explored).toBe(s.kind !== 'system');
    }
  });

  it('keeps all 24 number discs in per-icon pools and no disc on any slot planet', () => {
    expect(state.discPools.tri).toEqual(layout.numberDiscs.tri);
    expect(state.discPools.br).toEqual(layout.numberDiscs.br);
    expect(state.discPools.hex).toEqual(layout.numberDiscs.hex);
    for (const p of Object.values(state.board.planets)) {
      if (p.icon !== undefined) expect(p.disc).toBeNull();
    }
  });

  it('is deterministic', () => {
    expect(createExplorerGame({ players: FOUR, seed: 'explorer-1' })).toEqual(state);
  });
});

describe('wild space set-up', () => {
  const state = createWildSpaceGame({ players: FOUR, seed: 'wild-1' });

  it('deals 15 of the 16 shuffled tiles face down and returns one', () => {
    expect(state.variant).toBe('wild');
    const slots = slotSectors(state);
    expect(slots).toHaveLength(15);
    const tiles = slots.map((s) => s.tileId);
    expect(new Set(tiles).size).toBe(15);
    expect(ALL_TILES.filter((t) => !tiles.includes(t))).toHaveLength(1);
    for (const s of slots) expect(s.discovered).toBe(false);
    checkCatanianTrios(state);
    checkStartingPieces(state, 4);
    expect(state.discPools.tri).toHaveLength(8);
  });

  it('pins WILD_SPACE_SLOT_ORDER: all 15 slots, near before far, nearest first within a region', () => {
    expect(WILD_SPACE_SLOT_ORDER).toEqual(['N4', 'N1', 'N6', 'N5', 'N2', 'N7', 'N3', 'N8', 'F5', 'F1', 'F3', 'F6', 'F2', 'F4', 'F7']);
    expect([...WILD_SPACE_SLOT_ORDER].sort()).toEqual(layout.slots.map((s) => s.id).sort());
    const regions = WILD_SPACE_SLOT_ORDER.map((id) => layout.slots.find((s) => s.id === id)!.region);
    expect(regions).toEqual([...Array<string>(8).fill('near'), ...Array<string>(7).fill('far')]);
    const x = (id: string) => {
      const slot = layout.slots.find((s) => s.id === id)!;
      return slot.lobes.reduce((sum, h) => sum + hexCenter(h).x, 0) / 3;
    };
    for (const region of ['near', 'far'] as const) {
      const ids = WILD_SPACE_SLOT_ORDER.filter((id) => layout.slots.find((s) => s.id === id)!.region === region);
      for (let i = 1; i < ids.length; i++) expect(x(ids[i]!)).toBeGreaterThanOrEqual(x(ids[i - 1]!));
    }
  });

  it('ignores star backs: over many seeds a 2-star tile lands in a near slot', () => {
    let mixed = false;
    for (let i = 0; i < 20 && !mixed; i++) {
      const g = createWildSpaceGame({ players: FOUR, seed: `wild-mix-${i}` });
      mixed = slotSectors(g).some((s) => s.region === 'near' && starsOf(s) === 2);
    }
    expect(mixed).toBe(true);
  });

  it('is deterministic and seed-sensitive', () => {
    expect(createWildSpaceGame({ players: FOUR, seed: 'wild-1' })).toEqual(state);
    const other = createWildSpaceGame({ players: FOUR, seed: 'wild-2' });
    expect(slotSectors(other).map((s) => s.tileId)).not.toEqual(slotSectors(state).map((s) => s.tileId));
  });
});

describe('createGame', () => {
  it('dispatches on the variant and defaults to beginner', () => {
    expect(GAME_VARIANTS).toEqual(['beginner', 'strategic', 'explorer', 'wild']);
    for (const v of GAME_VARIANTS) {
      const g = createGame({ variant: v, players: THREE, seed: `cg-${v}`, id: 'room' });
      expect(g.variant).toBe(v);
      expect(g.id).toBe('room');
      expect(GAME_VARIANT_LABELS[v]).toBeTruthy();
      expect(isGameVariant(v)).toBe(true);
    }
    expect(createGame({ players: THREE, seed: 'cg' }).variant).toBe('beginner');
    expect(createGame({ players: THREE, seed: 'cg' })).toEqual(createBeginnerGame({ players: THREE, seed: 'cg' }));
    expect(isGameVariant('classic')).toBe(false);
    const v = 'wild' satisfies GameVariant;
    expect(createGame({ variant: v, players: THREE, seed: 'w' })).toEqual(createWildSpaceGame({ players: THREE, seed: 'w' }));
  });
});
