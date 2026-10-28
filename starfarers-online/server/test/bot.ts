/**
 * A greedy, rules-naive bot used to play whole games through the server
 * layer: it only ever sends actions it believes legal (founding first,
 * then moving colony ships toward free colony sites, trade ships toward
 * docking points, building whatever it can afford). It is not clever; it is
 * a load generator for the engine + room store integration. In a drafted game
 * (spec §3.4) it takes the first free Catanian site, upgrades its first drafted
 * colony, places a colony ship and takes the first upgrade left in the pool.
 */

import {
  BUILD_COSTS,
  canFoundColony,
  handHas,
  isOccupied,
  legalMoves,
  shipsOf,
  spaceportSites,
  spaceportsOf,
  encounterCard,
  type Action,
  type GameState,
  type NodeId,
  type PlayerId,
  type Resource,
} from '@starfarers/shared';
import { actor, draftAction, encounterPickAction, pendingFoundAction, sevenAction } from '../src/autoplay.js';

// The pieces the turn timer also uses (who acts, the draft, a 7, encounter picks, a pending station) live in src/autoplay.ts.
export { actor } from '../src/autoplay.js';

function freeSites(state: GameState, pid: PlayerId): NodeId[] {
  return spaceportsOf(state, pid)
    .flatMap((sp) => spaceportSites(state.board, sp.nodeId))
    .filter((n) => !isOccupied(state.board, n));
}

/** The next action for whoever must act, or null when the game is over. */
export function nextAction(state: GameState, rnd: () => number): Action | null {
  if (state.phase === 'gameOver') return null;
  const pid = actor(state);
  const me = state.players.find((p) => p.id === pid)!;
  const ships = shipsOf(state, pid);

  switch (state.phase) {
    case 'setup':
      return draftAction(state, pid);
    case 'production': {
      if (state.turn.rolled === undefined) return { type: 'rollDice', playerId: pid };
      const seven = sevenAction(state, pid);
      if (seven) return seven;
      return { type: 'takeReserveDraw', playerId: pid };
    }
    case 'tradeBuild': {
      if (state.openTrade && state.openTrade.to === pid) return { type: 'respondTrade', playerId: pid, accept: false };
      if (!state.turn.reserveDrawTaken && (me.vp <= 9 || state.turn.rolled !== undefined) && state.turn.rolled !== 7 && me.vp <= 9) {
        return { type: 'takeReserveDraw', playerId: pid };
      }
      const colonies = Object.values(state.board.settlements).filter((s) => s.owner === pid && s.kind === 'colony');
      if (me.pieces.shipyardsLeft > 0 && colonies.length > 0 && handHas(me.hand, BUILD_COSTS.spaceport)) {
        return { type: 'build', playerId: pid, item: 'spaceport', siteId: colonies[0]!.nodeId };
      }
      const sites = freeSites(state, pid);
      if (ships.length < 3 && me.pieces.transportsLeft > 0 && sites.length > 0) {
        if (me.pieces.coloniesLeft > 0 && handHas(me.hand, BUILD_COSTS.colonyShip)) {
          return { type: 'build', playerId: pid, item: 'colonyShip', siteId: sites[0] as NodeId };
        }
        if (me.pieces.stationsLeft > 0 && handHas(me.hand, BUILD_COSTS.tradeShip) && me.mothership.freightPods > 0) {
          return { type: 'build', playerId: pid, item: 'tradeShip', siteId: sites[0] as NodeId };
        }
      }
      if (me.mothership.freightPods < 2 && state.upgradesTray.freightPods > 0 && handHas(me.hand, BUILD_COSTS.freightPod)) {
        return { type: 'build', playerId: pid, item: 'freightPod' };
      }
      if (me.mothership.boosters < 4 && state.upgradesTray.boosters > 0 && handHas(me.hand, BUILD_COSTS.booster)) {
        return { type: 'build', playerId: pid, item: 'booster' };
      }
      if (me.mothership.cannons < 4 && state.upgradesTray.cannons > 0 && handHas(me.hand, BUILD_COSTS.cannon)) {
        return { type: 'build', playerId: pid, item: 'cannon' };
      }
      // Trade 3:1 surplus toward a colony ship.
      const counts: Record<Resource, number> = { ore: 0, fuel: 0, carbon: 0, food: 0, goods: 0 };
      for (const r of me.hand) counts[r] += 1;
      const surplus = (Object.keys(counts) as Resource[]).find((r) => counts[r] >= 4);
      const missing = (['ore', 'fuel', 'carbon', 'food'] as Resource[]).find((r) => counts[r] === 0 && state.supply[r] > 0);
      if (surplus && missing) return { type: 'tradeWithSupply', playerId: pid, give: [surplus, surplus, surplus], want: missing };
      if (ships.length === 0) return { type: 'endTurn', playerId: pid };
      return { type: 'shakeMothership', playerId: pid };
    }
    case 'flight.encounter': {
      const ctx = state.turn.encounter!;
      if (ctx.awaiting && ctx.awaiting.playerId === pid) return encounterPickAction(state, pid);
      if (ctx.stage === 'choice' && pid === state.activePlayer) {
        const card = encounterCard(ctx.cardId);
        const offerStep = card.choice === 'offer0to3' || (card.choice === 'offerThenYesno' && ctx.offerPaid === undefined);
        if (offerStep) {
          const n = Math.min(me.hand.length, Math.floor(rnd() * 3));
          return { type: 'encounterChoice', playerId: pid, value: n, cards: me.hand.slice(0, n) };
        }
        const yes = me.hand.length > 0 && rnd() < 0.5;
        return { type: 'encounterChoice', playerId: pid, value: yes };
      }
      return null;
    }
    case 'flight.move': {
      if (state.turn.pendingFound) return pendingFoundAction(state, pid);
      for (const ship of ships) {
        if (ship.kind === 'colony' && canFoundColony(state, ship.id) === null) return { type: 'foundColony', playerId: pid, shipId: ship.id };
      }
      for (const ship of ships) {
        if ((state.turn.shipMovesUsed[ship.id] ?? 0) > 0) continue;
        const moves = legalMoves(state, ship.id);
        if (moves.size === 0) continue;
        const entries = [...moves.entries()];
        const wanted = ship.kind === 'colony' ? 'colonySite' : 'dockingPoint';
        const targets = entries.filter(([n]) => state.board.nodes[n]?.siteType === wanted);
        const pick = targets.length > 0 ? targets[Math.floor(rnd() * targets.length)]! : entries.sort((a, b) => b[1].length - a[1].length)[Math.floor(rnd() * Math.min(5, entries.length))]!;
        return { type: 'moveShip', playerId: pid, shipId: ship.id, path: pick[1] };
      }
      return { type: 'endTurn', playerId: pid };
    }
    default:
      return null;
  }
}

/** Tiny deterministic generator for the bot's own choices (never used by the engine). */
export function botRandom(seed: number): () => number {
  let x = seed >>> 0 || 1;
  return () => {
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    return ((x >>> 0) % 10000) / 10000;
  };
}
