/**
 * Automatic moves (HANDOFF §8.2): the minimal legal sequence that finishes a
 * turn when the online turn timer runs out, plus the small pieces the test
 * bot (server/test/bot.ts) shares with it.
 *
 * `timeoutAction(state)` returns ONE action for whoever must act next, or
 * `null` when there is nothing it may do. Called repeatedly on the
 * authoritative (unredacted) state it walks a turn to its end:
 *
 *   setup (advanced draft)  first free Catanian site / the first legal draftFinish
 *   production              rollDice if not rolled → a pending 7: each discarder
 *                           drops their first cards, then the roller steals from
 *                           the first target (the reserve draw is skipped)
 *   tradeBuild              shakeMothership when the player has ships, else endTurn
 *                           (either closes an open trade proposal)
 *   flight.encounter        the awaited pick (by whoever it is awaited from: first
 *                           option / first cards / decline the jump), else the
 *                           active player's choice: offer 0, answer "no"
 *   flight.move             a pending trade station (first free dock, first card)
 *                           → endTurn; when the engine refuses endTurn because a
 *                           parked ship must found or leave, found the colony if
 *                           it may, else take that ship's shortest legal move
 *
 * It never builds, trades or moves a ship by choice; the one forced move is
 * the "must leave" rule above, without which the turn could not end.
 */

import {
  applyAction,
  canFoundColony,
  createRng,
  discardCountFor,
  draftSpaceportCandidates,
  draftableSites,
  encounterCard,
  handSize,
  isColonyRound,
  isOccupied,
  legalMoves,
  outpostAtNode,
  pickableFriendshipCards,
  shipsOf,
  spaceportSites,
  type Action,
  type GameState,
  type NodeId,
  type PlayerId,
  type Resource,
  type ShipId,
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

/** Advanced draft (spec §3.4): the first free Catanian site, or a draftFinish on the first candidates. */
export function draftAction(state: GameState, pid: PlayerId): Action | null {
  const draft = state.draft;
  if (!draft) return null;
  if (isColonyRound(draft)) {
    const siteId = draftableSites(state)[0];
    return siteId === undefined ? null : { type: 'draftColony', playerId: pid, siteId };
  }
  const spaceportSiteId = draftSpaceportCandidates(state, pid)[0];
  if (spaceportSiteId === undefined) return null;
  const shipSiteId = spaceportSites(state.board, spaceportSiteId).find((n) => !isOccupied(state.board, n));
  if (shipSiteId === undefined) return null;
  return { type: 'draftFinish', playerId: pid, spaceportSiteId, ship: 'colony', shipSiteId, upgrade: draft.pool[0] ?? 'booster' };
}

/** A pending 7 for `pid`: discard the first cards, or (the roller) steal from the first target; `null` if nothing is owed. */
export function sevenAction(state: GameState, pid: PlayerId): Action | null {
  const seven = state.turn.seven;
  if (!seven) return null;
  const me = state.players.find((p) => p.id === pid);
  if (!me) return null;
  if (seven.awaitingDiscard.includes(pid)) {
    return { type: 'discardForSeven', playerId: pid, cards: me.hand.slice(0, discardCountFor(me.hand.length)) };
  }
  if (!seven.stealDone && seven.awaitingDiscard.length === 0 && pid === state.activePlayer) {
    // Opponents' hands are empty in a redacted view; `handSize` reads the count instead.
    const target = state.players.find((p) => p.id !== pid && handSize(p) > 0);
    if (target) return { type: 'stealForSeven', playerId: pid, target: target.id };
  }
  return null;
}

/** Answer `turn.encounter.awaiting` when it is awaited from `pid`: first option, first cards, decline a jump. */
export function encounterPickAction(state: GameState, pid: PlayerId): Action | null {
  const aw = state.turn.encounter?.awaiting;
  if (!aw || aw.playerId !== pid) return null;
  const me = state.players.find((p) => p.id === pid);
  if (!me) return null;
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
  return null;
}

/** A trade ship waiting on a docking point (`turn.pendingFound`): first free dock, first pickable card. */
export function pendingFoundAction(state: GameState, pid: PlayerId): Action | null {
  const pending = state.turn.pendingFound;
  if (!pending) return null;
  const ship = state.board.ships[pending];
  if (!ship) return null;
  const outpost = outpostAtNode(state.board, ship.nodeId);
  if (!outpost?.docks || !outpost.civ) return null;
  const dock = outpost.docks.findIndex((d) => d === null);
  const card = pickableFriendshipCards(state, outpost.civ)[0];
  if (dock < 0 || card === undefined) return null;
  return { type: 'foundTradeStation', playerId: pid, shipId: pending, dockIndex: dock, friendshipCardId: card };
}

/** endTurn, or — when the engine refuses it for a parked ship — what clears that ship. */
function endTurnOrUnblock(state: GameState, pid: PlayerId): Action | null {
  const endTurn: Action = { type: 'endTurn', playerId: pid };
  // Dry run: endTurn draws nothing from the rng, and applyAction never mutates its input.
  const dry = applyAction(state, endTurn, createRng('timer-dry-run'));
  if (dry.ok) return endTurn;
  const shipId = (dry.error.details as { shipId?: unknown } | undefined)?.shipId;
  if (typeof shipId !== 'string' || state.board.ships[shipId]?.owner !== pid) return null;
  if (canFoundColony(state, shipId as ShipId) === null) return { type: 'foundColony', playerId: pid, shipId };
  let best: NodeId[] | null = null;
  for (const path of legalMoves(state, shipId as ShipId).values()) {
    if (path.length > 0 && (best === null || path.length < best.length)) best = path;
  }
  return best ? { type: 'moveShip', playerId: pid, shipId, path: best } : null;
}

/** The next action of the minimal turn-ending sequence (see the header), or `null`. */
export function timeoutAction(state: GameState): Action | null {
  if (state.phase === 'gameOver' || state.winner !== null) return null;
  const active = state.activePlayer;
  switch (state.phase) {
    case 'setup':
      return draftAction(state, active);
    case 'production': {
      if (state.turn.rolled === undefined) return { type: 'rollDice', playerId: active };
      const seven = state.turn.seven;
      if (!seven) return null;
      const pid = seven.awaitingDiscard[0] ?? active;
      return sevenAction(state, pid);
    }
    case 'tradeBuild':
    case 'flight.shake':
      if (state.phase === 'tradeBuild' && shipsOf(state, active).length === 0) return { type: 'endTurn', playerId: active };
      return { type: 'shakeMothership', playerId: active };
    case 'flight.encounter': {
      const ctx = state.turn.encounter;
      if (!ctx) return null;
      if (ctx.awaiting) return encounterPickAction(state, ctx.awaiting.playerId);
      if (ctx.stage !== 'choice') return null;
      const card = encounterCard(ctx.cardId);
      const offerStep = card.choice === 'offer0to3' || (card.choice === 'offerThenYesno' && ctx.offerPaid === undefined);
      return offerStep ? { type: 'encounterChoice', playerId: active, value: 0, cards: [] } : { type: 'encounterChoice', playerId: active, value: false };
    }
    case 'flight.move':
      if (state.turn.pendingFound) return pendingFoundAction(state, active);
      return endTurnOrUnblock(state, active);
    default:
      return null;
  }
}

/** Short words for the "timer: …" chat line. */
export function describeAutoAction(action: Action): string {
  switch (action.type) {
    case 'rollDice':
      return 'rolled';
    case 'discardForSeven':
      return `discarded ${action.cards.length}`;
    case 'stealForSeven':
      return 'stole a card';
    case 'shakeMothership':
      return 'shook the mothership';
    case 'encounterChoice':
      return typeof action.value === 'number' ? `offered ${action.value}` : action.value ? 'answered yes' : 'answered no';
    case 'encounterPick':
      return 'took the first encounter option';
    case 'foundTradeStation':
      return 'founded the trade station';
    case 'foundColony':
      return 'founded the colony';
    case 'moveShip':
      return 'moved the parked ship off its site';
    case 'endTurn':
      return 'ended the turn';
    case 'draftColony':
      return 'drafted the first free site';
    case 'draftFinish':
      return 'finished the draft';
    default:
      return action.type;
  }
}
