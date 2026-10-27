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
  discardCountFor,
  draftSpaceportCandidates,
  draftableSites,
  handHas,
  isColonyRound,
  isOccupied,
  legalMoves,
  outpostAtNode,
  pickableFriendshipCards,
  shipsOf,
  spaceportSites,
  spaceportsOf,
  handSize,
  encounterCard,
  type Action,
  type GameState,
  type NodeId,
  type PlayerId,
  type Resource,
} from '@starfarers/shared';

/** Who must act next (same rule as the client's requiredViewer). */
export function actor(state: GameState): PlayerId {
  const awaiting = state.turn.encounter?.awaiting;
  if (state.phase === 'flight.encounter' && awaiting) return awaiting.playerId;
  const seven = state.turn.seven;
  if (state.phase === 'production' && seven && seven.awaitingDiscard.length > 0) return seven.awaitingDiscard[0] as PlayerId;
  const trade = state.openTrade;
  if (state.phase === 'tradeBuild' && trade && trade.to !== 'supply') return trade.to;
  return state.activePlayer;
}

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
    case 'setup': {
      const draft = state.draft;
      if (!draft) return null;
      if (isColonyRound(draft)) return { type: 'draftColony', playerId: pid, siteId: draftableSites(state)[0] as NodeId };
      const spaceportSiteId = draftSpaceportCandidates(state, pid)[0] as NodeId;
      const shipSiteId = spaceportSites(state.board, spaceportSiteId).find((n) => !isOccupied(state.board, n)) as NodeId;
      return { type: 'draftFinish', playerId: pid, spaceportSiteId, ship: 'colony', shipSiteId, upgrade: draft.pool[0] ?? 'booster' };
    }
    case 'production': {
      if (state.turn.rolled === undefined) return { type: 'rollDice', playerId: pid };
      const seven = state.turn.seven;
      if (seven) {
        if (seven.awaitingDiscard.includes(pid)) {
          return { type: 'discardForSeven', playerId: pid, cards: me.hand.slice(0, discardCountFor(me.hand.length)) };
        }
        if (!seven.stealDone) {
          // Opponents' hands are empty in a redacted view; `handSize` reads the count instead.
          const targets = state.players.filter((p) => p.id !== pid && handSize(p) > 0);
          return { type: 'stealForSeven', playerId: pid, target: targets[0]!.id };
        }
      }
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
      if (ctx.awaiting && ctx.awaiting.playerId === pid) {
        const aw = ctx.awaiting;
        const count = aw.count ?? 1;
        switch (aw.kind) {
          case 'resources': {
            const picks: Resource[] = [];
            const pool = (['ore', 'fuel', 'carbon', 'food', 'goods'] as Resource[]).filter((r) => state.supply[r] > 0);
            for (let i = 0; i < count; i++) picks.push(pool[i % pool.length] ?? 'ore');
            return { type: 'encounterPick', playerId: pid, resources: picks };
          }
          case 'payResources':
          case 'giveOne':
            return { type: 'encounterPick', playerId: pid, resources: me.hand.slice(0, count) };
          case 'upgradeKind':
          case 'removeUpgrade':
            return { type: 'encounterPick', playerId: pid, upgrade: (aw.options?.[0] ?? 'booster') as 'booster' };
          case 'immobilizeShip':
            return { type: 'encounterPick', playerId: pid, shipId: aw.options?.[0] ?? '' };
          case 'spaceJump':
            return { type: 'encounterPick', playerId: pid, decline: true };
        }
      }
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
      const pending = state.turn.pendingFound;
      if (pending) {
        const ship = state.board.ships[pending]!;
        const outpost = outpostAtNode(state.board, ship.nodeId)!;
        const dock = outpost.docks!.findIndex((d) => d === null);
        const card = pickableFriendshipCards(state, outpost.civ!)[0]!;
        return { type: 'foundTradeStation', playerId: pid, shipId: pending, dockIndex: dock, friendshipCardId: card };
      }
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
