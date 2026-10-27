/**
 * Sector discovery in the explorer / wild space set-ups (spec §3.2, §9.3) and
 * the redaction of face-down tiles (spec §12.1). Board facts are derived from
 * the game itself (which slot holds which tile depends on the seed), never
 * hard-coded.
 */

import { describe, expect, it } from 'vitest';
import { applyAction } from '../src/actions/index.js';
import { hexCorners, hexEquals, slotInteriorVertices, vertexHexes } from '../src/board/geometry.js';
import { isOccupied, neighborsOf, planetsOfSector, undiscoveredInteriorNodes } from '../src/board/query.js';
import { DISCOVERY_ENDS_MOVE } from '../src/config.js';
import { discoverAt } from '../src/flight/discover.js';
import { validateJumpTarget } from '../src/flight/jump.js';
import { stepsLeft } from '../src/flight/movement.js';
import { legalMoves, reachablePaths } from '../src/flight/reach.js';
import { speedOf } from '../src/flight/stats.js';
import { redactBoard, redactState } from '../src/net/redact.js';
import { createRng } from '../src/rng.js';
import { createGame } from '../src/setup/index.js';
import type { GameState, NodeId, Sector, SectorKind } from '../src/types.js';

const THREE = [
  { id: 'p1', name: 'Ann', color: 'red' as const },
  { id: 'p2', name: 'Bob', color: 'blue' as const },
  { id: 'p3', name: 'Cid', color: 'yellow' as const },
];

/** Explorer game with the active player in flight.move and a big budget. */
function explorerFlight(seed = 'explorer-flight', speed = 6): GameState {
  const state = createGame({ variant: 'explorer', players: THREE, seed });
  state.phase = 'flight.move';
  state.turn.baseSpeed = speed;
  state.turn.speed = speedOf(state, state.activePlayer);
  state.turn.speed = speed;
  return state;
}

function activeShip(state: GameState) {
  const ship = Object.values(state.board.ships).find((s) => s.owner === state.activePlayer);
  if (!ship) throw new Error('no ship');
  return ship;
}

/** A rim node of the sector (touches a lobe, is a node, not interior) plus an outside neighbour to start from. */
function approach(state: GameState, sector: Sector, rimNextToInterior = false): { rim: NodeId; from: NodeId } {
  const interior = new Set(slotInteriorVertices(sector.lobes));
  const hiddenInteriors = undiscoveredInteriorNodes(state.board);
  const rims = Object.values(state.board.nodes).filter((n) => !interior.has(n.id) && touches(n.id, sector));
  for (const rim of rims) {
    if (isOccupied(state.board, rim.id)) continue;
    if (rimNextToInterior && !neighborsOf(state.board, rim.id).some((m) => interior.has(m))) continue;
    const from = neighborsOf(state.board, rim.id).find((m) => !hiddenInteriors.has(m) && !isOccupied(state.board, m) && !touches(m, sector));
    if (from) return { rim: rim.id, from };
  }
  throw new Error(`no approach to ${sector.id}`);
}

/** Does one of the node's three hexes belong to the sector? */
function touches(nodeId: NodeId, sector: Sector): boolean {
  const hexes = vertexHexes(nodeId);
  return sector.lobes.some((l) => hexes.some((h) => hexEquals(h, l)));
}

function firstHidden(state: GameState, kind: SectorKind): Sector {
  const s = Object.values(state.board.sectors).find((x) => !x.discovered && x.kind === kind);
  if (!s) throw new Error(`no hidden ${kind}`);
  return s;
}

function move(state: GameState, path: NodeId[]) {
  const ship = activeShip(state);
  return applyAction(state, { type: 'moveShip', playerId: state.activePlayer, shipId: ship.id, path }, createRng('discover'));
}

describe('discovery through moveShip', () => {
  it('reveals a system: discs drawn from the pools by icon, placed and flipped at once, one log event', () => {
    const state = explorerFlight();
    const sector = firstHidden(state, 'system');
    const { rim, from } = approach(state, sector);
    const ship = activeShip(state);
    ship.nodeId = from;
    const poolsBefore = structuredClone(state.discPools);
    const r = move(state, [rim]);
    expect(r.ok, r.ok ? '' : r.error.message).toBe(true);
    if (!r.ok) return;
    const next = r.value;
    const found = next.board.sectors[sector.id]!;
    expect(found.discovered).toBe(true);
    expect(found.explored).toBe(true);
    const planets = planetsOfSector(next.board, sector.id);
    const drawn: string[] = [];
    for (const p of planets) {
      if (p.token) {
        drawn.push(`${p.token.kind === 'pirateBase' ? 'P' : 'I'}${p.token.value}`);
        expect(p.disc).toBeNull();
        expect(p.icon).toBe('hex');
      } else {
        expect(p.disc).not.toBeNull();
        expect(p.disc!.faceUp).toBe(true);
        expect(p.disc!.back).toBe(p.icon);
        drawn.push(p.disc!.label);
      }
    }
    // Exactly one disc per icon left the pools, and it is the one on the planet.
    for (const icon of ['tri', 'br', 'hex'] as const) {
      expect(next.discPools[icon]).toHaveLength(poolsBefore[icon].length - 1);
      const planet = planets.find((p) => p.icon === icon)!;
      const label = planet.token ? `${planet.token.kind === 'pirateBase' ? 'P' : 'I'}${planet.token.value}` : planet.disc!.label;
      const remaining = [...next.discPools[icon]];
      remaining.push(label);
      expect(remaining.sort()).toEqual([...poolsBefore[icon]].sort());
    }
    const events = next.log.filter((e) => e.kind === 'event' && e.message.includes(`Sector ${sector.id} discovered`));
    expect(events).toHaveLength(1);
    expect(events[0]!.message).toContain('planetary system');
    for (const label of drawn) expect(events[0]!.message).toContain(label);
    expect(next.log.filter((e) => e.message.includes(`System ${sector.id} explored`))).toHaveLength(0);
    // The discovered sector is now visible to everyone.
    const view = redactState(next, 'p2');
    expect(view.board.sectors[sector.id]!.kind).toBe('system');
    expect(view.board.sectors[sector.id]!.planetIds).toHaveLength(3);
    expect(view.discPoolCounts).toEqual({ tri: next.discPools.tri.length, br: next.discPools.br.length, hex: next.discPools.hex.length });
    expect(view.discPools).toEqual({ tri: [], br: [], hex: [] });
  });

  it('reveals an outpost: docking point and docks become usable; an empty tile becomes passable', () => {
    for (const kind of ['outpost', 'empty'] as const) {
      let state: GameState | null = null;
      for (let i = 0; i < 10 && !state; i++) {
        const g = explorerFlight(`outpost-${i}`);
        if (Object.values(g.board.sectors).some((s) => !s.discovered && s.kind === kind)) state = g;
      }
      expect(state).not.toBeNull();
      const sector = firstHidden(state!, kind);
      const centre = sector.centreVertex;
      // Before: the centre is a node in the authoritative graph but not enterable; hidden from viewers.
      expect(state!.board.nodes[centre]).toBeDefined();
      expect(undiscoveredInteriorNodes(state!.board).has(centre)).toBe(true);
      expect(redactState(state!, 'p1').board.nodes[centre]).toBeUndefined();
      const { rim, from } = approach(state!, sector);
      activeShip(state!).nodeId = from;
      const r = move(state!, [rim]);
      expect(r.ok, r.ok ? '' : r.error.message).toBe(true);
      if (!r.ok) return;
      const found = r.value.board.sectors[sector.id]!;
      expect(found.discovered).toBe(true);
      expect(found.kind).toBe(kind);
      expect(undiscoveredInteriorNodes(r.value.board).has(centre)).toBe(false);
      const view = redactState(r.value, 'p2');
      expect(view.board.nodes[centre]).toBeDefined();
      expect(view.board.sectors[sector.id]!.kind).toBe(kind);
      if (kind === 'outpost') {
        expect(found.docks).toHaveLength(5);
        expect(found.dockingPointId).toBe(centre);
        expect(view.board.sectors[sector.id]!.civ).toBe(found.civ);
        expect(view.board.nodes[centre]!.siteType).toBe('dockingPoint');
        expect(r.value.log.some((e) => e.message.includes(`Sector ${sector.id} discovered`) && e.message.includes('outpost'))).toBe(true);
      } else {
        expect(view.board.nodes[centre]!.siteType).toBe('plain');
        expect(r.value.log.some((e) => e.message.includes(`Sector ${sector.id} discovered`) && e.message.includes('empty space'))).toBe(true);
      }
      expect(r.value.discPools).toEqual(state!.discPools);
    }
  });

  it('turns the special discs into tokens exactly like exploreSector', () => {
    const state = explorerFlight();
    const sector = firstHidden(state, 'system');
    state.discPools = { tri: ['3'], br: ['8'], hex: ['P5'] };
    const { rim, from } = approach(state, sector);
    activeShip(state).nodeId = from;
    const r = move(state, [rim]);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const planets = planetsOfSector(r.value.board, sector.id);
    const hexPlanet = planets.find((p) => p.icon === 'hex')!;
    expect(hexPlanet.token).toEqual({ kind: 'pirateBase', value: 5 });
    expect(hexPlanet.disc).toBeNull();
    expect(planets.find((p) => p.icon === 'tri')!.disc!.numbers).toEqual([3]);
    expect(planets.find((p) => p.icon === 'br')!.disc!.numbers).toEqual([8]);
    expect(r.value.discPools).toEqual({ tri: [], br: [], hex: [] });
  });

  it('never lets a ship end on or pass through an undiscovered interior; after discovery it may', () => {
    const state = explorerFlight();
    const sector = firstHidden(state, 'system');
    const { rim, from } = approach(state, sector, true);
    const ship = activeShip(state);
    ship.nodeId = from;
    const interior = slotInteriorVertices(sector.lobes).filter((v) => state.board.nodes[v] !== undefined);
    expect(interior).toHaveLength(3); // the 3 colony sites; the centre is no node in a system
    const site = neighborsOf(state.board, rim).find((n) => interior.includes(n))!;
    expect(site).toBeDefined();
    expect(state.board.nodes[site]!.siteType).toBe('colonySite');
    // End on the site: refused. Pass through it to a node beyond: refused.
    const end = applyAction(state, { type: 'moveShip', playerId: state.activePlayer, shipId: ship.id, path: [rim, site] }, createRng('x'));
    expect(end).toMatchObject({ ok: false, error: { code: 'invalidPath' } });
    const beyond = neighborsOf(state.board, site).find((n) => n !== rim)!;
    const through = applyAction(state, { type: 'moveShip', playerId: state.activePlayer, shipId: ship.id, path: [rim, site, beyond] }, createRng('x'));
    expect(through).toMatchObject({ ok: false, error: { code: 'invalidPath' } });
    // Highlights and jump targets agree.
    const moves = legalMoves(state, ship.id);
    expect(moves.has(rim)).toBe(true);
    for (const v of undiscoveredInteriorNodes(state.board)) expect(moves.has(v)).toBe(false);
    expect(reachablePaths(state, ship.nodeId, 10).has(site)).toBe(false);
    expect(validateJumpTarget(state, ship.id, site)).toMatchObject({ code: 'invalidTarget' });
    // Discover, then the colony site is an ordinary legal end node for the colony ship.
    const r = move(state, [rim]);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const after = legalMoves(r.value, ship.id);
    expect(after.has(site)).toBe(true);
    const r2 = move(r.value, [site]);
    expect(r2.ok).toBe(true);
  });

  it('pins DISCOVERY_ENDS_MOVE = false: the discovering ship keeps its remaining budget', () => {
    expect(DISCOVERY_ENDS_MOVE).toBe(false);
    const state = explorerFlight('explorer-flight', 6);
    const sector = firstHidden(state, 'system');
    const { rim, from } = approach(state, sector);
    activeShip(state).nodeId = from;
    const r = move(state, [rim]);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(stepsLeft(r.value, activeShip(state).id)).toBe(5);
  });

  it('discovers on a space-jump arrival too and discoverAt needs an rng only for systems', () => {
    const state = explorerFlight();
    const sector = firstHidden(state, 'system');
    const { rim } = approach(state, sector);
    const ship = activeShip(state);
    expect(validateJumpTarget(state, ship.id, rim)).toBeNull();
    expect(() => discoverAt(state, rim, undefined)).toThrow(/rng/);
    const fresh = explorerFlight();
    expect(discoverAt(fresh, rim, createRng('j'))).toContain(sector.id);
    expect(fresh.board.sectors[sector.id]!.discovered).toBe(true);
  });

  it('beginner and strategic games have nothing to discover', () => {
    for (const variant of ['beginner', 'strategic'] as const) {
      const g = createGame({ variant, players: THREE, seed: 'nothing' });
      expect(undiscoveredInteriorNodes(g.board).size).toBe(0);
      // Only the face-down discs are hidden (redact.test.ts); the graph and the sectors are the very same objects.
      const r = redactBoard(g.board);
      expect(r.nodes).toBe(g.board.nodes);
      expect(r.edges).toBe(g.board.edges);
      expect(r.adjacency).toBe(g.board.adjacency);
      expect(r.sectors).toBe(g.board.sectors);
      expect(Object.keys(r.planets)).toEqual(Object.keys(g.board.planets));
      const ship = activeShip(g);
      expect(discoverAt(g, ship.nodeId, undefined)).toEqual([]);
    }
  });
});

describe('redaction of undiscovered sectors', () => {
  it('hides every field of a face-down tile and is identical whatever the tile really is', () => {
    // Two explorer games whose seeds put different tile kinds into the same slot.
    const a = createGame({ variant: 'explorer', players: THREE, seed: 'redact-a' });
    let b: GameState | null = null;
    let slot = '';
    for (let i = 0; i < 20 && !b; i++) {
      const g = createGame({ variant: 'explorer', players: THREE, seed: `redact-b${i}` });
      const differing = Object.values(a.board.sectors).find((s) => s.region !== 'catanian' && g.board.sectors[s.id]!.kind !== s.kind);
      if (differing) {
        b = g;
        slot = differing.id;
      }
    }
    expect(b).not.toBeNull();
    expect(a.board.sectors[slot]!.kind).not.toBe(b!.board.sectors[slot]!.kind);

    const ra = redactState(a, 'p1');
    const rb = redactState(b!, 'p1');
    const lobes = a.board.sectors[slot]!.lobes;
    const vertices = new Set<string>(lobes.flatMap((hex) => hexCorners(hex)));
    expect(vertices.size).toBe(13);
    const slice = (s: GameState) => ({
      sector: s.board.sectors[slot],
      nodes: [...vertices].sort().map((v) => s.board.nodes[v] ?? null),
      adjacency: [...vertices].sort().map((v) => [...(s.board.adjacency[v] ?? [])].sort()),
      planets: Object.values(s.board.planets).filter((p) => p.sectorId === slot),
      edges: s.board.edges.filter(([x, y]) => vertices.has(x) || vertices.has(y)).sort(),
    });
    expect(slice(ra)).toEqual(slice(rb));
    const hidden = ra.board.sectors[slot]!;
    expect(hidden).toEqual({
      id: slot,
      tileId: '',
      kind: 'hidden',
      region: a.board.sectors[slot]!.region,
      lobes,
      centreVertex: a.board.sectors[slot]!.centreVertex,
      planetIds: [],
      colonySites: [],
      explored: false,
      discovered: false,
    });
    for (const v of slotInteriorVertices(lobes)) expect(ra.board.nodes[v]).toBeUndefined();
    for (const n of Object.values(ra.board.nodes)) {
      for (const p of n.adjacentPlanets) expect(ra.board.planets[p]).toBeDefined();
      if (n.sectorId !== undefined) expect(ra.board.sectors[n.sectorId]!.discovered).toBe(true);
    }
    // In fact the whole redacted graph of two explorer games is the same: only the Catanian discs differ.
    expect(ra.board.nodes).toEqual(rb.board.nodes);
    expect(ra.board.edges).toEqual(rb.board.edges);
    expect(ra.board.adjacency).toEqual(rb.board.adjacency);
    expect(ra.board.sectors).toEqual(rb.board.sectors);
    expect(Object.keys(ra.board.planets).sort()).toEqual(Object.keys(rb.board.planets).sort());
    expect(Object.keys(ra.board.planets)).toHaveLength(12);
    // Redaction is idempotent and does not touch the input.
    expect(redactBoard(ra.board)).toEqual(ra.board);
    expect(a.board.sectors[slot]!.kind).not.toBe('hidden');
  });

  it('the client view of legal moves equals the engine view on an explorer board', () => {
    const state = explorerFlight('explorer-view', 5);
    const sector = firstHidden(state, 'system');
    const { from } = approach(state, sector);
    const ship = activeShip(state);
    ship.nodeId = from;
    const server = [...legalMoves(state, ship.id).keys()].sort();
    const client = [...legalMoves(redactState(state, state.activePlayer), ship.id).keys()].sort();
    expect(client).toEqual(server);
    expect(server.length).toBeGreaterThan(0);
    for (const v of undiscoveredInteriorNodes(state.board)) expect(server).not.toContain(v);
  });
});
