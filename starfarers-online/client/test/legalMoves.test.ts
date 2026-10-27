import { applyAction, createGame, createRng, isOccupied, redactState, slotInteriorVertices, undiscoveredInteriorNodes, validateEndNode, type GameState, type NodeId } from '@starfarers/shared';
import { describe, expect, it } from 'vitest';
import { legalJumpTargets, legalMoves, reachablePaths } from '../src/board/legalMoves.js';
import { PLAYERS, game, inFlight, shipsOfActive } from './fixtures.js';

/** Independent brute force: nodes within `budget` edges of `start` (plain BFS on distances only). */
function withinBudget(state: GameState, start: NodeId, budget: number): Set<NodeId> {
  const dist = new Map<NodeId, number>([[start, 0]]);
  const q = [start];
  while (q.length) {
    const n = q.shift() as NodeId;
    const d = dist.get(n) as number;
    if (d === budget) continue;
    for (const m of state.board.adjacency[n] ?? []) if (!dist.has(m)) (dist.set(m, d + 1), q.push(m));
  }
  dist.delete(start);
  return new Set(dist.keys());
}

describe('legalMoves highlight', () => {
  const state = inFlight(game(), 4);

  it('equals the engine answer: reachable within speed AND validateEndNode passes', () => {
    for (const shipId of shipsOfActive(state)) {
      const ship = state.board.ships[shipId]!;
      const expected = [...withinBudget(state, ship.nodeId, state.turn.speed ?? 0)].filter((n) => validateEndNode(state, ship, n) === null).sort();
      const actual = [...legalMoves(state, shipId).keys()].sort();
      expect(actual).toEqual(expected);
      expect(actual.length).toBeGreaterThan(0);
    }
  });

  it('every highlighted node is accepted by moveShip with the BFS path, and the path is a shortest one', () => {
    for (const shipId of shipsOfActive(state)) {
      const ship = state.board.ships[shipId]!;
      const budget = state.turn.speed ?? 0;
      const dist = reachablePaths(state, ship.nodeId, budget);
      for (const [node, path] of legalMoves(state, shipId)) {
        expect(path.length).toBe(dist.get(node)?.length);
        expect(path.length).toBeLessThanOrEqual(budget);
        const r = applyAction(state, { type: 'moveShip', playerId: state.activePlayer, shipId, path }, createRng('x'));
        expect(r.ok, `${shipId} → ${node}`).toBe(true);
        if (r.ok) expect(r.value.board.ships[shipId]?.nodeId).toBe(node);
      }
    }
  });

  it('a node outside the budget is never highlighted and is rejected by the engine', () => {
    const shipId = shipsOfActive(state)[0]!;
    const ship = state.board.ships[shipId]!;
    const far = reachablePaths(state, ship.nodeId, 8);
    const beyond = [...far.entries()].find(([, p]) => p.length === (state.turn.speed ?? 0) + 1);
    expect(beyond).toBeDefined();
    const [node, path] = beyond!;
    expect(legalMoves(state, shipId).has(node)).toBe(false);
    const r = applyAction(state, { type: 'moveShip', playerId: state.activePlayer, shipId, path }, createRng('x'));
    expect(r.ok).toBe(false);
  });

  it('is empty outside flight.move, for immobilized ships and while a station must be founded', () => {
    const shipId = shipsOfActive(state)[0]!;
    expect(legalMoves(game(), shipId).size).toBe(0);
    const frozen = structuredClone(state);
    frozen.turn.immobilized.push(shipId);
    expect(legalMoves(frozen, shipId).size).toBe(0);
    const pending = structuredClone(state);
    pending.turn.pendingFound = shipId;
    expect(legalMoves(pending, shipId).size).toBe(0);
  });

  it('shrinks as steps are used', () => {
    const shipId = shipsOfActive(state)[0]!;
    const all = legalMoves(state, shipId);
    const used = structuredClone(state);
    used.turn.shipMovesUsed[shipId] = 3;
    const left = (state.turn.speed ?? 0) - 3;
    const fewer = legalMoves(used, shipId);
    expect(fewer.size).toBeLessThan(all.size);
    for (const [, p] of fewer) expect(p.length).toBeLessThanOrEqual(left);
  });

  it('legalJumpTargets never includes occupied nodes or the ship’s own node', () => {
    const shipId = shipsOfActive(state)[0]!;
    const targets = legalJumpTargets(state, shipId);
    expect(targets.length).toBeGreaterThan(100);
    for (const n of targets) {
      expect(n).not.toBe(state.board.ships[shipId]?.nodeId);
      expect(state.board.settlements[n]).toBeUndefined();
    }
  });
});

describe('legalMoves highlight on an explorer board', () => {
  /** Explorer game with the active ship parked two steps from a face-down system's colony site. */
  function explorerState(): { state: GameState; shipId: string; site: NodeId } {
    const base = inFlight(createGame({ variant: 'explorer', players: PLAYERS, seed: 'client-explorer' }), 4);
    const shipId = shipsOfActive(base)[0]!;
    const hidden = undiscoveredInteriorNodes(base.board);
    for (const sector of Object.values(base.board.sectors)) {
      if (sector.discovered || sector.kind !== 'system') continue;
      const interior = new Set(slotInteriorVertices(sector.lobes));
      for (const site of interior) {
        if (!base.board.nodes[site]) continue;
        for (const rim of base.board.adjacency[site] ?? []) {
          if (hidden.has(rim) || isOccupied(base.board, rim)) continue;
          const from = (base.board.adjacency[rim] ?? []).find((n) => !hidden.has(n) && !interior.has(n) && !isOccupied(base.board, n));
          if (!from) continue;
          const state = structuredClone(base);
          state.board.ships[shipId]!.nodeId = from;
          return { state, shipId, site };
        }
      }
    }
    throw new Error('no face-down system reachable');
  }

  it('the redacted (client) view highlights exactly what the authoritative validator accepts, never a hidden interior', () => {
    const { state, shipId, site } = explorerState();
    const view = redactState(state, state.activePlayer);
    const client = [...legalMoves(view, shipId).entries()].sort(([a], [b]) => a.localeCompare(b));
    const server = [...legalMoves(state, shipId).keys()].sort();
    expect(client.map(([n]) => n)).toEqual(server);
    expect(client.length).toBeGreaterThan(0);
    // The site is within the budget geometrically but hidden: neither side offers it, and the engine refuses it.
    expect(view.board.nodes[site]).toBeUndefined();
    expect(server).not.toContain(site);
    const ship = state.board.ships[shipId]!;
    const rim = (state.board.adjacency[ship.nodeId] ?? []).find((n) => state.board.adjacency[n]?.includes(site))!;
    expect(rim).toBeDefined();
    expect(applyAction(state, { type: 'moveShip', playerId: state.activePlayer, shipId, path: [rim, site] }, createRng('x')).ok).toBe(false);
    // Every client path is accepted by the authoritative engine and discovers on the way where it touches a tile.
    for (const [node, path] of client) {
      const r = applyAction(state, { type: 'moveShip', playerId: state.activePlayer, shipId, path }, createRng('x'));
      expect(r.ok, `${shipId} → ${node}`).toBe(true);
      if (r.ok) expect(r.value.board.ships[shipId]?.nodeId).toBe(node);
    }
    expect(legalJumpTargets(view, shipId).sort()).toEqual(legalJumpTargets(state, shipId).sort());
  });
});
