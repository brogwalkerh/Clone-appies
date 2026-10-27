import { describe, expect, it } from 'vitest';
import { isOccupied, shipsOf, spaceportSites, spaceportsOf, coloniesOf, settlementAt } from '../src/board/query.js';
import { BUILD_COSTS, UPGRADE_CAPS } from '../src/config.js';
import { computeVp } from '../src/vp.js';
import type { GameState, NodeId, Resource } from '../src/types.js';
import { cardsInPlay, fails, ok, opponents, player, setHand, tradeBuildState } from './support/tradeBuild.js';

function costHand(item: keyof typeof BUILD_COSTS): Resource[] {
  const out: Resource[] = [];
  for (const [r, n] of Object.entries(BUILD_COSTS[item])) for (let i = 0; i < (n ?? 0); i++) out.push(r as Resource);
  return out;
}

/** The free and the occupied spaceport site of the active player's starting spaceport. */
function ownSites(state: GameState): { free: NodeId; occupied: NodeId } {
  const sp = spaceportsOf(state, state.activePlayer)[0]!;
  const sites = spaceportSites(state.board, sp.nodeId);
  const free = sites.find((n) => !isOccupied(state.board, n))!;
  const occupied = sites.find((n) => isOccupied(state.board, n))!;
  expect(free).toBeDefined();
  expect(occupied).toBeDefined();
  return { free, occupied };
}

describe('build: colony ship', () => {
  it('places a colony ship on a free own spaceport site and pays the cost', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    setHand(state, me, [...costHand('colonyShip'), 'goods']);
    const { free } = ownSites(state);
    const before = cardsInPlay(state);
    const supplyOre = state.supply.ore;

    const next = ok(state, { type: 'build', playerId: me, item: 'colonyShip', siteId: free });
    const ships = shipsOf(next, me);
    expect(ships).toHaveLength(2);
    const built = ships.find((s) => s.nodeId === free)!;
    expect(built.kind).toBe('colony');
    expect(built.id).toBe(`ship:${player(next, me).color}:2`);
    expect(built.mustFoundOrLeave).toBe(false);
    expect(player(next, me).pieces.transportsLeft).toBe(1);
    expect(player(next, me).pieces.coloniesLeft).toBe(4);
    expect(player(next, me).hand).toEqual(['goods']);
    expect(next.supply.ore).toBe(supplyOre + 1);
    expect(cardsInPlay(next)).toBe(before);
  });

  it('rejects an occupied site, an opponent site, a non-site node and a missing siteId', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    setHand(state, me, costHand('colonyShip'));
    const { occupied } = ownSites(state);
    fails(state, { type: 'build', playerId: me, item: 'colonyShip', siteId: occupied }, 'invalidSite');

    const other = opponents(state)[0]!;
    const theirSp = spaceportsOf(state, other.id)[0]!;
    const theirFree = spaceportSites(state.board, theirSp.nodeId).find((n) => !isOccupied(state.board, n))!;
    fails(state, { type: 'build', playerId: me, item: 'colonyShip', siteId: theirFree }, 'invalidSite');

    const colony = coloniesOf(state, me)[0]!;
    fails(state, { type: 'build', playerId: me, item: 'colonyShip', siteId: colony.nodeId }, 'invalidSite');
    fails(state, { type: 'build', playerId: me, item: 'colonyShip' }, 'invalidSite');
  });

  it('enforces the transport (3 ships) and colony piece limits', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    setHand(state, me, costHand('colonyShip'));
    const { free } = ownSites(state);

    const noTransport = structuredClone(state);
    player(noTransport, me).pieces.transportsLeft = 0;
    fails(noTransport, { type: 'build', playerId: me, item: 'colonyShip', siteId: free }, 'pieceLimit');

    const tooManyShips = structuredClone(state);
    player(tooManyShips, me).pieces.transportsLeft = 3;
    for (let i = 0; i < 2; i++) {
      tooManyShips.board.ships[`ship:red:x${i}`] = {
        id: `ship:red:x${i}`,
        owner: me,
        kind: 'colony',
        nodeId: `fake${i}`,
        mustFoundOrLeave: false,
      };
    }
    expect(shipsOf(tooManyShips, me)).toHaveLength(3);
    fails(tooManyShips, { type: 'build', playerId: me, item: 'colonyShip', siteId: free }, 'pieceLimit');

    const noColony = structuredClone(state);
    player(noColony, me).pieces.coloniesLeft = 0;
    fails(noColony, { type: 'build', playerId: me, item: 'colonyShip', siteId: free }, 'pieceLimit');
  });

  it('rejects when the player cannot pay and leaves the state untouched', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    setHand(state, me, ['ore', 'fuel', 'carbon']);
    const { free } = ownSites(state);
    fails(state, { type: 'build', playerId: me, item: 'colonyShip', siteId: free }, 'insufficientResources');
  });
});

describe('build: trade ship', () => {
  it('places a trade ship and consumes a trade station piece', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    setHand(state, me, costHand('tradeShip'));
    const { free } = ownSites(state);
    const next = ok(state, { type: 'build', playerId: me, item: 'tradeShip', siteId: free });
    const built = shipsOf(next, me).find((s) => s.nodeId === free)!;
    expect(built.kind).toBe('trade');
    expect(player(next, me).pieces).toEqual({ coloniesLeft: 5, stationsLeft: 6, transportsLeft: 1, shipyardsLeft: 2 });
    expect(player(next, me).hand).toEqual([]);
  });

  it('needs a free trade station piece and 2 goods', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    setHand(state, me, costHand('tradeShip'));
    const { free } = ownSites(state);
    const noStation = structuredClone(state);
    player(noStation, me).pieces.stationsLeft = 0;
    fails(noStation, { type: 'build', playerId: me, item: 'tradeShip', siteId: free }, 'pieceLimit');

    setHand(state, me, ['ore', 'fuel', 'goods', 'carbon']);
    fails(state, { type: 'build', playerId: me, item: 'tradeShip', siteId: free }, 'insufficientResources');
  });
});

describe('build: spaceport', () => {
  it('upgrades an own colony, uses a shipyard and is worth exactly +1 VP', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    setHand(state, me, costHand('spaceport'));
    const colony = coloniesOf(state, me)[0]!;
    expect(player(state, me).vp).toBe(4);

    const next = ok(state, { type: 'build', playerId: me, item: 'spaceport', siteId: colony.nodeId });
    expect(settlementAt(next.board, colony.nodeId)?.kind).toBe('spaceport');
    expect(spaceportsOf(next, me)).toHaveLength(2);
    expect(coloniesOf(next, me)).toHaveLength(1);
    expect(player(next, me).vp).toBe(5);
    expect(computeVp(next, me)).toBe(5);
    expect(player(next, me).pieces.shipyardsLeft).toBe(1);
    expect(player(next, me).pieces.coloniesLeft).toBe(5);
    expect(player(next, me).hand).toEqual([]);
    // Its two sites are now legal ship sites for the owner.
    expect(spaceportSites(next.board, colony.nodeId).length).toBeGreaterThan(0);
  });

  it('rejects an existing spaceport, an opponent colony, an empty node and a missing siteId', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    setHand(state, me, costHand('spaceport'));
    const sp = spaceportsOf(state, me)[0]!;
    fails(state, { type: 'build', playerId: me, item: 'spaceport', siteId: sp.nodeId }, 'invalidSite');
    const theirs = coloniesOf(state, opponents(state)[0]!.id)[0]!;
    fails(state, { type: 'build', playerId: me, item: 'spaceport', siteId: theirs.nodeId }, 'invalidSite');
    const { free } = ownSites(state);
    fails(state, { type: 'build', playerId: me, item: 'spaceport', siteId: free }, 'invalidSite');
    fails(state, { type: 'build', playerId: me, item: 'spaceport' }, 'invalidSite');
  });

  it('is limited by shipyards (max 3 spaceports) and by resources', () => {
    let state = tradeBuildState();
    const me = state.activePlayer;
    const [c1, c2] = coloniesOf(state, me);
    setHand(state, me, [...costHand('spaceport'), ...costHand('spaceport'), ...costHand('spaceport')]);
    state = ok(state, { type: 'build', playerId: me, item: 'spaceport', siteId: c1!.nodeId });
    state = ok(state, { type: 'build', playerId: me, item: 'spaceport', siteId: c2!.nodeId });
    expect(player(state, me).pieces.shipyardsLeft).toBe(0);
    expect(player(state, me).vp).toBe(6);
    // A third colony to upgrade, but no shipyard left.
    const site = 'N(5,8)';
    state.board.settlements[site] = { nodeId: site, kind: 'colony', color: player(state, me).color, owner: me };
    fails(state, { type: 'build', playerId: me, item: 'spaceport', siteId: site }, 'pieceLimit');

    const poor = tradeBuildState();
    setHand(poor, poor.activePlayer, ['carbon', 'carbon', 'food', 'food']);
    const colony = coloniesOf(poor, poor.activePlayer)[0]!;
    fails(poor, { type: 'build', playerId: poor.activePlayer, item: 'spaceport', siteId: colony.nodeId }, 'insufficientResources');
  });

  it("flags an opponent's ship sitting on a new spaceport site as must-leave", () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    const other = opponents(state)[0]!;
    setHand(state, me, costHand('spaceport'));
    const colony = coloniesOf(state, me)[0]!;
    const site = spaceportSites(state.board, colony.nodeId).find((n) => !isOccupied(state.board, n))!;
    state.board.ships['ship:blue:9'] = { id: 'ship:blue:9', owner: other.id, kind: 'colony', nodeId: site, mustFoundOrLeave: false };

    const next = ok(state, { type: 'build', playerId: me, item: 'spaceport', siteId: colony.nodeId });
    expect(next.board.ships['ship:blue:9']!.mustFoundOrLeave).toBe(true);
    expect(next.log.some((e) => e.kind === 'event' && e.playerId === other.id && /must leave/.test(e.message))).toBe(true);
  });
});

describe('build: upgrades', () => {
  const cases: { item: 'booster' | 'cannon' | 'freightPod'; tray: 'boosters' | 'cannons' | 'freightPods' }[] = [
    { item: 'booster', tray: 'boosters' },
    { item: 'cannon', tray: 'cannons' },
    { item: 'freightPod', tray: 'freightPods' },
  ];

  for (const { item, tray } of cases) {
    it(`${item}: pays the cost, moves one piece from the tray, respects the cap of ${UPGRADE_CAPS[item]} and an empty tray`, () => {
      const state = tradeBuildState();
      const me = state.activePlayer;
      setHand(state, me, [...costHand(item), 'food']);
      const trayBefore = state.upgradesTray[tray];
      const shipBefore = player(state, me).mothership[tray];

      const next = ok(state, { type: 'build', playerId: me, item });
      expect(next.upgradesTray[tray]).toBe(trayBefore - 1);
      expect(player(next, me).mothership[tray]).toBe(shipBefore + 1);
      expect(player(next, me).hand).toEqual(['food']);

      const capped = structuredClone(state);
      player(capped, me).mothership[tray] = UPGRADE_CAPS[item];
      fails(capped, { type: 'build', playerId: me, item }, 'upgradeCap');

      const empty = structuredClone(state);
      empty.upgradesTray[tray] = 0;
      fails(empty, { type: 'build', playerId: me, item }, 'supplyEmpty');

      const poor = structuredClone(state);
      setHand(poor, me, costHand(item).slice(1));
      fails(poor, { type: 'build', playerId: me, item }, 'insufficientResources');
    });
  }

  it('can be built up to the cap, then no further', () => {
    let state = tradeBuildState();
    const me = state.activePlayer;
    setHand(state, me, Array<Resource>(20).fill('fuel'));
    const start = player(state, me).mothership.boosters;
    for (let i = start; i < UPGRADE_CAPS.booster; i++) {
      state = ok(state, { type: 'build', playerId: me, item: 'booster' });
    }
    expect(player(state, me).mothership.boosters).toBe(UPGRADE_CAPS.booster);
    fails(state, { type: 'build', playerId: me, item: 'booster' }, 'upgradeCap');
  });
});

describe('build: gating', () => {
  it('rejects unknown items, non-active players and the wrong phase', () => {
    const state = tradeBuildState();
    const me = state.activePlayer;
    setHand(state, me, ['fuel', 'fuel']);
    fails(state, { type: 'build', playerId: me, item: 'deathStar' as never }, 'invalidAction');
    fails(state, { type: 'build', playerId: opponents(state)[0]!.id, item: 'booster' }, 'notYourTurn');
    const prod = structuredClone(state);
    prod.phase = 'production';
    fails(prod, { type: 'build', playerId: me, item: 'booster' }, 'wrongPhase');
  });
});
