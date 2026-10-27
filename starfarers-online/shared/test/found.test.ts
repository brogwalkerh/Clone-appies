/**
 * Founding colonies and trade stations (spec §9.4, §9.5, §8, §4) and the
 * "free trade ship" mechanic (§10). States are built from the beginner set-up
 * and put directly into the move phase with ships placed by hand, so nothing
 * here depends on the movement handlers.
 */

import { describe, expect, it } from 'vitest';
import { getSector, settlementAt, shipsOf, spaceportSites, spaceportsOf, stationsAt } from '../src/board/query.js';
import { MAX_COLONIES_PER_SYSTEM_3P, MAX_STATIONS_PER_OUTPOST, friendshipCardsOf } from '../src/config.js';
import { canFoundColony, nodeTouchesSpecialToken, settlementsInSystem } from '../src/found/colony.js';
import { freeTradeShipSite, grantFreeTradeShip, tryPlacePendingTradeShips } from '../src/found/freeTradeShip.js';
import {
  holdsCard,
  pickableFriendshipCards,
  stationsAtOutpost,
  updateFriendshipMarker,
} from '../src/found/friendship.js';
import { canFoundTradeStation } from '../src/found/station.js';
import { createBeginnerGame } from '../src/setup/beginner.js';
import type { GameState, NodeId, PlayerId, ShipId } from '../src/types.js';
import { computeVp } from '../src/vp.js';
import { THREE, fails, ok, opponents, player } from './support/tradeBuild.js';

const FOUR = [...THREE, { id: 'p4', name: 'Dee', color: 'white' as const }];

/** Beginner game (3 players unless `four`) in the move phase with speed already set. */
function moveState(opts: { four?: boolean; seed?: string } = {}): GameState {
  const state = createBeginnerGame({ players: opts.four ? FOUR : THREE, seed: opts.seed ?? 'found' });
  state.phase = 'flight.move';
  state.turn.baseSpeed = 3;
  state.turn.speed = 5;
  return state;
}

function activeShip(state: GameState): ShipId {
  return shipsOf(state, state.activePlayer)[0]!.id;
}

/** Put the active player's starting colony ship on `nodeId`. */
function parkColonyShip(state: GameState, nodeId: NodeId): ShipId {
  const id = activeShip(state);
  state.board.ships[id]!.nodeId = nodeId;
  return id;
}

/** Turn the active player's starting ship into a trade ship sitting on the outpost's docking point. */
function parkTradeShip(state: GameState, sectorId: string, pods = 1): ShipId {
  const id = activeShip(state);
  const ship = state.board.ships[id]!;
  ship.kind = 'trade';
  ship.nodeId = getSector(state.board, sectorId).dockingPointId!;
  player(state, state.activePlayer).mothership.freightPods = pods;
  return id;
}

/** Fill `n` docks at the outpost with `owner`'s stations (lowest free docks first). */
function fillDocks(state: GameState, sectorId: string, owner: PlayerId, n: number): void {
  const docks = getSector(state.board, sectorId).docks!;
  let placed = 0;
  for (let i = 0; i < docks.length && placed < n; i++) {
    if (docks[i] === null) {
      docks[i] = owner;
      placed++;
    }
  }
  expect(placed).toBe(n);
}

// N2 is the S3 planetary system in the beginner layout; its three colony sites:
const N2_SITES: NodeId[] = ['N(3,6)', 'N(4,7)', 'N(3,7)'];
const GREEN_FOLK = 'N3';
const SCIENTISTS = 'F2';

describe('foundColony', () => {
  it('replaces the colony ship by a colony, returns the transport and gives +1 VP', () => {
    const state = moveState();
    const me = state.activePlayer;
    const site = N2_SITES[0]!;
    const ship = parkColonyShip(state, site);
    const before = player(state, me);
    const vpBefore = computeVp(state, me);
    expect(canFoundColony(state, ship)).toBeNull();

    const next = ok(state, { type: 'foundColony', playerId: me, shipId: ship });
    expect(next.board.ships[ship]).toBeUndefined();
    expect(settlementAt(next.board, site)).toEqual({ nodeId: site, kind: 'colony', color: before.color, owner: me });
    expect(player(next, me).pieces.transportsLeft).toBe(before.pieces.transportsLeft + 1);
    expect(player(next, me).pieces.coloniesLeft).toBe(before.pieces.coloniesLeft - 1);
    expect(computeVp(next, me)).toBe(vpBefore + 1);
    expect(player(next, me).vp).toBe(vpBefore + 1);
    expect(next.phase).toBe('flight.move');
    expect(next.log.some((e) => e.kind === 'event' && e.message.includes('founded a colony'))).toBe(true);
  });

  it('is allowed after 0 steps and clears mustFoundOrLeave by founding', () => {
    const state = moveState();
    const me = state.activePlayer;
    const ship = parkColonyShip(state, N2_SITES[1]!);
    state.board.ships[ship]!.mustFoundOrLeave = true;
    state.turn.shipMovesUsed = {};
    const next = ok(state, { type: 'foundColony', playerId: me, shipId: ship });
    expect(next.board.ships[ship]).toBeUndefined();
    expect(Object.values(next.board.ships).some((s) => s.mustFoundOrLeave)).toBe(false);
  });

  it('rejects a trade ship, an unknown ship and an opponent ship', () => {
    const state = moveState();
    const me = state.activePlayer;
    const ship = parkColonyShip(state, N2_SITES[0]!);
    const asTrade = structuredClone(state);
    asTrade.board.ships[ship]!.kind = 'trade';
    fails(asTrade, { type: 'foundColony', playerId: me, shipId: ship }, 'ruleViolation');
    fails(state, { type: 'foundColony', playerId: me, shipId: 'ship:nope:1' }, 'invalidTarget');
    const theirs = shipsOf(state, opponents(state)[0]!.id)[0]!;
    theirs.nodeId = N2_SITES[1]!;
    fails(state, { type: 'foundColony', playerId: me, shipId: theirs.id }, 'invalidTarget');
  });

  it('rejects a node that is not a colony site and an occupied site', () => {
    const state = moveState();
    const me = state.activePlayer;
    const ship = activeShip(state); // still on its spaceport site (plain node)
    fails(state, { type: 'foundColony', playerId: me, shipId: ship }, 'invalidSite');

    const taken = structuredClone(state);
    const site = N2_SITES[0]!;
    taken.board.settlements[site] = { nodeId: site, kind: 'colony', color: 'white', owner: null };
    parkColonyShip(taken, site);
    fails(taken, { type: 'foundColony', playerId: me, shipId: ship }, 'invalidSite');
  });

  it('rejects a site adjacent to a pirate base or ice planet', () => {
    const state = moveState();
    const me = state.activePlayer;
    const site = N2_SITES[0]!;
    const ship = parkColonyShip(state, site);
    const planet = state.board.planets[state.board.nodes[site]!.adjacentPlanets[0]!]!;
    planet.token = { kind: 'pirateBase', value: 4 };
    expect(nodeTouchesSpecialToken(state.board, site)).toBe(true);
    fails(state, { type: 'foundColony', playerId: me, shipId: ship }, 'ruleViolation');

    planet.token = { kind: 'icePlanet', value: 3 };
    fails(state, { type: 'foundColony', playerId: me, shipId: ship }, 'ruleViolation');

    planet.token = null;
    expect(nodeTouchesSpecialToken(state.board, site)).toBe(false);
    expect(canFoundColony(state, ship)).toBeNull();
  });

  it('rejects when no colony piece is left', () => {
    const state = moveState();
    const me = state.activePlayer;
    const ship = parkColonyShip(state, N2_SITES[0]!);
    player(state, me).pieces.coloniesLeft = 0;
    fails(state, { type: 'foundColony', playerId: me, shipId: ship }, 'pieceLimit');
  });

  it('is only accepted from the active player during flight.move', () => {
    const state = moveState();
    const me = state.activePlayer;
    const ship = parkColonyShip(state, N2_SITES[0]!);
    const other = opponents(state)[0]!.id;
    fails(state, { type: 'foundColony', playerId: other, shipId: ship }, 'notYourTurn');
    for (const phase of ['production', 'tradeBuild', 'flight.shake', 'flight.encounter'] as const) {
      const wrong = structuredClone(state);
      wrong.phase = phase;
      fails(wrong, { type: 'foundColony', playerId: me, shipId: ship }, 'wrongPhase');
    }
  });

  it('3-player game: at most 2 colonies per unexplored system; Catanian systems are exempt', () => {
    const state = moveState();
    const me = state.activePlayer;
    const [a, b, c] = N2_SITES as [NodeId, NodeId, NodeId];
    const ship = parkColonyShip(state, a);
    const second = ok(state, { type: 'foundColony', playerId: me, shipId: ship });
    expect(settlementsInSystem(second, 'N2')).toBe(1);

    // Second colony (another player's) is fine.
    second.board.settlements[b] = { nodeId: b, kind: 'colony', color: 'white', owner: null };
    expect(settlementsInSystem(second, 'N2')).toBe(MAX_COLONIES_PER_SYSTEM_3P);
    second.board.ships[ship] = { id: ship, owner: me, kind: 'colony', nodeId: c, mustFoundOrLeave: false };
    player(second, me).pieces.transportsLeft -= 1;
    fails(second, { type: 'foundColony', playerId: me, shipId: ship }, 'ruleViolation');

    // Same situation in a Catanian system: allowed.
    const catanian = moveState();
    const alpha = getSector(catanian.board, 'alpha');
    const freed = alpha.colonySites[0]!.nodeId;
    delete catanian.board.settlements[freed];
    expect(settlementsInSystem(catanian, 'alpha')).toBe(2);
    const cShip = parkColonyShip(catanian, freed);
    expect(canFoundColony(catanian, cShip)).toBeNull();
    const after = ok(catanian, { type: 'foundColony', playerId: catanian.activePlayer, shipId: cShip });
    expect(settlementsInSystem(after, 'alpha')).toBe(3);
  });

  it('4-player game: no per-system cap', () => {
    const state = moveState({ four: true });
    const me = state.activePlayer;
    const [a, b, c] = N2_SITES as [NodeId, NodeId, NodeId];
    state.board.settlements[a] = { nodeId: a, kind: 'colony', color: 'white', owner: null };
    state.board.settlements[b] = { nodeId: b, kind: 'colony', color: 'white', owner: null };
    const ship = parkColonyShip(state, c);
    expect(canFoundColony(state, ship)).toBeNull();
    const next = ok(state, { type: 'foundColony', playerId: me, shipId: ship });
    expect(settlementsInSystem(next, 'N2')).toBe(3);
  });

  it('is rejected while another ship still has to found a trade station (pendingFound)', () => {
    const state = moveState();
    const me = state.activePlayer;
    const ship = parkColonyShip(state, N2_SITES[0]!);
    state.turn.pendingFound = 'ship:someone:9';
    fails(state, { type: 'foundColony', playerId: me, shipId: ship }, 'ruleViolation');
  });
});

describe('canFoundTradeStation: freight-pod threshold (§9.5)', () => {
  it.each([
    { stations: 0, pods: 1, allowed: true },
    { stations: 0, pods: 0, allowed: false },
    { stations: 1, pods: 1, allowed: false },
    { stations: 1, pods: 2, allowed: true },
    { stations: 3, pods: 3, allowed: false },
    { stations: 3, pods: 4, allowed: true },
    { stations: 4, pods: 5, allowed: true },
  ])('$stations stations at the outpost with $pods pods → allowed=$allowed', ({ stations, pods, allowed }) => {
    const state = moveState();
    const other = opponents(state)[0]!.id;
    fillDocks(state, GREEN_FOLK, other, stations);
    const ship = parkTradeShip(state, GREEN_FOLK, pods);
    const dock = getSector(state.board, GREEN_FOLK).dockingPointId!;
    const error = canFoundTradeStation(state, ship, dock);
    if (allowed) expect(error).toBeNull();
    else expect(error?.code).toBe('ruleViolation');
  });

  it('rejects a full outpost (5 stations) even with 5 pods', () => {
    const state = moveState();
    const other = opponents(state)[0]!.id;
    fillDocks(state, GREEN_FOLK, other, MAX_STATIONS_PER_OUTPOST);
    const ship = parkTradeShip(state, GREEN_FOLK, 5);
    const dock = getSector(state.board, GREEN_FOLK).dockingPointId!;
    expect(canFoundTradeStation(state, ship, dock)?.code).toBe('ruleViolation');
    fails(state, { type: 'foundTradeStation', playerId: state.activePlayer, shipId: ship, dockIndex: 0, friendshipCardId: 'axxa' }, 'ruleViolation');
  });

  it('rejects a colony ship, a non-docking node, no station piece left and an exhausted card stack', () => {
    const state = moveState();
    const me = state.activePlayer;
    const dock = getSector(state.board, GREEN_FOLK).dockingPointId!;
    const colonyShip = activeShip(state);
    player(state, me).mothership.freightPods = 1;
    expect(canFoundTradeStation(state, colonyShip, dock)?.code).toBe('ruleViolation');

    const ship = parkTradeShip(state, GREEN_FOLK, 1);
    expect(canFoundTradeStation(state, ship, N2_SITES[0]!)?.code).toBe('invalidSite');

    const noPiece = structuredClone(state);
    player(noPiece, me).pieces.stationsLeft = 0;
    expect(canFoundTradeStation(noPiece, ship, dock)?.code).toBe('pieceLimit');

    const noCards = structuredClone(state);
    noCards.friendshipCards.greenFolk = [];
    expect(canFoundTradeStation(noCards, ship, dock)?.code).toBe('ruleViolation');

    const theirs = shipsOf(state, opponents(state)[0]!.id)[0]!;
    expect(canFoundTradeStation(state, theirs.id, dock)?.code).toBe('invalidTarget');
    expect(canFoundTradeStation(state, ship, dock)).toBeNull();
  });
});

describe('foundTradeStation', () => {
  it('places the station, returns the transport, hands over the card and the first marker (+2 VP)', () => {
    const state = moveState();
    const me = state.activePlayer;
    const ship = parkTradeShip(state, GREEN_FOLK, 1);
    const before = player(state, me);
    const vpBefore = computeVp(state, me);
    expect(pickableFriendshipCards(state, 'greenFolk')).toEqual(friendshipCardsOf('greenFolk'));

    const next = ok(state, { type: 'foundTradeStation', playerId: me, shipId: ship, dockIndex: 2, friendshipCardId: 'xulu' });
    expect(next.board.ships[ship]).toBeUndefined();
    expect(getSector(next.board, GREEN_FOLK).docks).toEqual([null, null, me, null, null]);
    expect(stationsAt(next.board, GREEN_FOLK, me)).toBe(1);
    expect(stationsAtOutpost(next, GREEN_FOLK)).toBe(1);
    expect(player(next, me).pieces.transportsLeft).toBe(before.pieces.transportsLeft + 1);
    expect(player(next, me).pieces.stationsLeft).toBe(before.pieces.stationsLeft - 1);
    expect(holdsCard(player(next, me), 'xulu')).toBe(true);
    expect(next.friendshipCards.greenFolk).toEqual(friendshipCardsOf('greenFolk').filter((c) => c !== 'xulu'));
    expect(next.friendshipMarkers.greenFolk).toBe(me);
    expect(computeVp(next, me)).toBe(vpBefore + 2);
    expect(player(next, me).vp).toBe(vpBefore + 2);
    expect(next.turn.pendingFound).toBeUndefined();
  });

  it('rejects a taken dock, an out-of-range dock and a card not in the stack', () => {
    const state = moveState();
    const me = state.activePlayer;
    const other = opponents(state)[0]!.id;
    getSector(state.board, GREEN_FOLK).docks![1] = other;
    const ship = parkTradeShip(state, GREEN_FOLK, 2);
    fails(state, { type: 'foundTradeStation', playerId: me, shipId: ship, dockIndex: 1, friendshipCardId: 'axxa' }, 'invalidSite');
    fails(state, { type: 'foundTradeStation', playerId: me, shipId: ship, dockIndex: 5, friendshipCardId: 'axxa' }, 'invalidSite');
    fails(state, { type: 'foundTradeStation', playerId: me, shipId: ship, dockIndex: -1, friendshipCardId: 'axxa' }, 'invalidSite');
    // A Scientists card at the Green Folk outpost, and a Green Folk card already taken.
    fails(state, { type: 'foundTradeStation', playerId: me, shipId: ship, dockIndex: 0, friendshipCardId: 'hirAkas' }, 'invalidTarget');
    state.friendshipCards.greenFolk = state.friendshipCards.greenFolk.filter((c) => c !== 'axxa');
    fails(state, { type: 'foundTradeStation', playerId: me, shipId: ship, dockIndex: 0, friendshipCardId: 'axxa' }, 'invalidTarget');
    fails(state, { type: 'foundTradeStation', playerId: me, shipId: ship, dockIndex: 0, friendshipCardId: 'nope' as 'axxa' }, 'invalidTarget');
  });

  it('is only accepted from the active player during flight.move', () => {
    const state = moveState();
    const me = state.activePlayer;
    const ship = parkTradeShip(state, GREEN_FOLK, 1);
    fails(state, { type: 'foundTradeStation', playerId: opponents(state)[0]!.id, shipId: ship, dockIndex: 0, friendshipCardId: 'axxa' }, 'notYourTurn');
    state.phase = 'tradeBuild';
    fails(state, { type: 'foundTradeStation', playerId: me, shipId: ship, dockIndex: 0, friendshipCardId: 'axxa' }, 'wrongPhase');
  });

  it('consumes turn.pendingFound for that ship and rejects founding with another ship', () => {
    const state = moveState();
    const me = state.activePlayer;
    const ship = parkTradeShip(state, GREEN_FOLK, 1);
    state.turn.pendingFound = ship;
    const next = ok(state, { type: 'foundTradeStation', playerId: me, shipId: ship, dockIndex: 0, friendshipCardId: 'axxa' });
    expect(next.turn.pendingFound).toBeUndefined();

    const blocked = moveState();
    const s2 = parkTradeShip(blocked, GREEN_FOLK, 1);
    blocked.turn.pendingFound = 'ship:other:7';
    fails(blocked, { type: 'foundTradeStation', playerId: blocked.activePlayer, shipId: s2, dockIndex: 0, friendshipCardId: 'axxa' }, 'ruleViolation');
  });

  it('friendship marker: first founder takes it, a tie keeps it, strictly more stations moves it', () => {
    let state = moveState();
    const me = state.activePlayer;
    const rival = opponents(state)[0]!.id;
    fillDocks(state, GREEN_FOLK, rival, 1);
    state.friendshipMarkers.greenFolk = rival;
    const rivalVp = computeVp(state, rival);
    expect(rivalVp).toBe(player(state, rival).vp + 2); // cached vp predates the marker: +2 for it

    // 1 vs 1: tie, marker stays with the rival.
    const ship = parkTradeShip(state, GREEN_FOLK, 2);
    state = ok(state, { type: 'foundTradeStation', playerId: me, shipId: ship, dockIndex: 1, friendshipCardId: 'axxa' });
    expect(state.friendshipMarkers.greenFolk).toBe(rival);
    expect(computeVp(state, rival)).toBe(rivalVp);

    // 2 vs 1: strictly more, marker moves (+2 for me, -2 for the rival).
    const myVp = computeVp(state, me);
    state.board.ships[ship] = { id: ship, owner: me, kind: 'trade', nodeId: getSector(state.board, GREEN_FOLK).dockingPointId!, mustFoundOrLeave: false };
    player(state, me).pieces.transportsLeft -= 1;
    player(state, me).mothership.freightPods = 3;
    state = ok(state, { type: 'foundTradeStation', playerId: me, shipId: ship, dockIndex: 3, friendshipCardId: 'xom' });
    expect(state.friendshipMarkers.greenFolk).toBe(me);
    expect(computeVp(state, me)).toBe(myVp + 2);
    expect(computeVp(state, rival)).toBe(rivalVp - 2);
    expect(state.log.some((e) => e.kind === 'event' && e.message.includes('takes the greenFolk friendship marker'))).toBe(true);

    // Rival back to 2 vs 2: tie, marker stays with me.
    fillDocks(state, GREEN_FOLK, rival, 1);
    expect(updateFriendshipMarker(state, 'greenFolk')).toBe(me);
    // Rival at 3 vs 2: moves back.
    fillDocks(state, GREEN_FOLK, rival, 1);
    expect(updateFriendshipMarker(state, 'greenFolk')).toBe(rival);
    expect(state.friendshipMarkers.greenFolk).toBe(rival);
  });

  it('updateFriendshipMarker leaves an outpost without stations unassigned', () => {
    const state = moveState();
    expect(updateFriendshipMarker(state, 'merchants')).toBeNull();
    expect(state.friendshipMarkers.merchants).toBeNull();
  });

  it('a Scientists speed card taken mid-flight raises the remaining speed immediately', () => {
    const state = moveState();
    const me = state.activePlayer;
    const ship = parkTradeShip(state, SCIENTISTS, 1);
    state.turn.speed = 4;
    const next = ok(state, { type: 'foundTradeStation', playerId: me, shipId: ship, dockIndex: 0, friendshipCardId: 'hirAkas' });
    expect(holdsCard(player(next, me), 'hirAkas')).toBe(true);
    expect(next.turn.speed).toBe(6); // baseSpeed 3 + 1 booster + Hir-Akas 2

    const combatOnly = moveState();
    const s2 = parkTradeShip(combatOnly, SCIENTISTS, 1);
    combatOnly.turn.speed = 4;
    const after = ok(combatOnly, { type: 'foundTradeStation', playerId: combatOnly.activePlayer, shipId: s2, dockIndex: 0, friendshipCardId: 'khaStar' });
    expect(after.turn.speed).toBe(4);
  });

  it('places a pending trade-ship marker once the transport comes back', () => {
    const state = moveState();
    const me = state.activePlayer;
    const ship = parkTradeShip(state, GREEN_FOLK, 1);
    player(state, me).pieces.transportsLeft = 0;
    state.pendingTradeShips[me] = 1;
    const next = ok(state, { type: 'foundTradeStation', playerId: me, shipId: ship, dockIndex: 0, friendshipCardId: 'axxa' });
    expect(next.pendingTradeShips[me]).toBe(0);
    const ships = shipsOf(next, me);
    expect(ships).toHaveLength(1);
    expect(ships[0]!.kind).toBe('trade');
    expect(player(next, me).pieces.transportsLeft).toBe(0);
  });
});

describe('free trade ship (§10)', () => {
  it('is placed on a free own spaceport site when transport, piece and site are available', () => {
    const state = moveState();
    const me = state.activePlayer;
    const sp = spaceportsOf(state, me)[0]!;
    const sites = spaceportSites(state.board, sp.nodeId);
    const expected = freeTradeShipSite(state, me);
    expect(expected).not.toBeNull();
    expect(sites).toContain(expected);
    const before = structuredClone(player(state, me));

    expect(grantFreeTradeShip(state, me)).toBe('placed');
    const placed = shipsOf(state, me).find((s) => s.kind === 'trade')!;
    expect(placed.id).toBe(`ship:${before.color}:2`);
    expect(placed.nodeId).toBe(expected);
    expect(placed.mustFoundOrLeave).toBe(false);
    expect(player(state, me).pieces.transportsLeft).toBe(before.pieces.transportsLeft - 1);
    expect(player(state, me).pieces.stationsLeft).toBe(before.pieces.stationsLeft - 1);
    expect(state.pendingTradeShips[me]).toBe(0);
  });

  it.each([
    { why: 'no transport left', tweak: (s: GameState, me: PlayerId) => { player(s, me).pieces.transportsLeft = 0; } },
    { why: 'no station piece left', tweak: (s: GameState, me: PlayerId) => { player(s, me).pieces.stationsLeft = 0; } },
    {
      why: 'both spaceport sites occupied',
      tweak: (s: GameState, me: PlayerId) => {
        const sp = spaceportsOf(s, me)[0]!;
        for (const site of spaceportSites(s.board, sp.nodeId)) {
          if (!s.board.settlements[site] && !Object.values(s.board.ships).some((x) => x.nodeId === site)) {
            s.board.settlements[site] = { nodeId: site, kind: 'colony', color: 'white', owner: null };
          }
        }
      },
    },
    {
      why: '3 ships already on the board',
      tweak: (s: GameState, me: PlayerId) => {
        player(s, me).pieces.transportsLeft = 3;
        s.board.ships['ship:x:1'] = { id: 'ship:x:1', owner: me, kind: 'colony', nodeId: 'N(3,6)', mustFoundOrLeave: false };
        s.board.ships['ship:x:2'] = { id: 'ship:x:2', owner: me, kind: 'colony', nodeId: 'N(4,7)', mustFoundOrLeave: false };
      },
    },
  ])('becomes a pending marker when $why', ({ tweak }) => {
    const state = moveState();
    const me = state.activePlayer;
    tweak(state, me);
    const shipsBefore = shipsOf(state, me).length;
    expect(grantFreeTradeShip(state, me)).toBe('pending');
    expect(state.pendingTradeShips[me]).toBe(1);
    expect(shipsOf(state, me)).toHaveLength(shipsBefore);
    expect(grantFreeTradeShip(state, me)).toBe('pending');
    expect(state.pendingTradeShips[me]).toBe(2);
  });

  it('tryPlacePendingTradeShips places as many markers as now possible', () => {
    const state = moveState();
    const me = state.activePlayer;
    player(state, me).pieces.transportsLeft = 0;
    state.pendingTradeShips[me] = 2;
    expect(tryPlacePendingTradeShips(state, me)).toBe(0);
    expect(state.pendingTradeShips[me]).toBe(2);

    // Transport back, but a spaceport has only one free site → one ship placed.
    player(state, me).pieces.transportsLeft = 2;
    expect(tryPlacePendingTradeShips(state, me)).toBe(1);
    expect(state.pendingTradeShips[me]).toBe(1);
    expect(shipsOf(state, me).filter((s) => s.kind === 'trade')).toHaveLength(1);
    expect(tryPlacePendingTradeShips(state, me)).toBe(0);

    // Move the colony ship away: the second site frees up.
    shipsOf(state, me).find((s) => s.kind === 'colony')!.nodeId = 'N(3,6)';
    expect(tryPlacePendingTradeShips(state, me)).toBe(1);
    expect(state.pendingTradeShips[me]).toBe(0);
    expect(shipsOf(state, me)).toHaveLength(3);
    expect(player(state, me).pieces.transportsLeft).toBe(0);
  });
});
