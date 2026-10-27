/**
 * TRADE & BUILD phase handlers (spec §7, §8):
 *   proposeTrade, respondTrade, tradeWithSupply, build, useFriendshipCard
 *
 * Owns `state.openTrade`, resource movement between hands/supply, piece and
 * upgrade limits (config BUILD_COSTS / PIECE_LIMITS / UPGRADE_CAPS) and
 * `state.turn.usedOncePerTurn` for once-per-turn friendship effects.
 *
 * Phase/active-player gating is done by `ACTION_POLICY` before dispatch; the
 * handlers here only validate rules. Every handler mutates the (already
 * cloned) state and returns it, or returns a typed `GameError`.
 *
 * Decisions not spelled out by the spec (see the report / tests):
 *  - Open proposal replacement: the active player may always propose (their
 *    proposal replaces any open one); a non-active player may propose only
 *    when nothing is open or the open proposal is their own.
 *  - Finalisation: a proposal always has the active player on one side, so a
 *    proposal is finalised when its recipient (`to`) accepts. If the recipient
 *    is the active player that is the "active player finalises" rule; if the
 *    proposer is the active player they consented by proposing.
 *  - Either party may reject (closes the proposal); only the recipient may
 *    accept or counter. A counter replaces `openTrade` with a proposal from
 *    the responder (expressed from the responder's point of view).
 *  - A new spaceport whose sites hold an opponent's ship marks that ship
 *    `mustFoundOrLeave` (closest existing field: "must leave next turn").
 */

import {
  BUILD_COSTS,
  FRIENDSHIP_CARDS,
  MAX_SHIPS_ON_BOARD,
  SUPPLY_TRADE,
  UPGRADE_CAPS,
  UPGRADE_TRAY_KEY,
} from '../config.js';
import { tryPlacePendingTradeShips } from '../found/freeTradeShip.js';
import { reliefEligible } from '../production/relief.js';
import type { Rng } from '../rng.js';
import {
  getPlayer,
  isOccupied,
  settlementAt,
  shipAt,
  shipsOf,
  spaceportSites,
  spaceportsOf,
} from '../board/query.js';
import { addToHand, bagTotal, handHas, handToBag, removeFromHand, returnToSupply, supplyHas, takeFromSupply } from '../supply.js';
import type {
  FriendshipCardId,
  GameError,
  GameState,
  Player,
  Resource,
  ResourceBag,
  ShipKind,
  UpgradeKind,
} from '../types.js';
import { RESOURCES, gameError } from '../types.js';
import type { ActionModule, Handler, HandlerMap } from './handler.js';
import { logEvent } from './handler.js';

// ---------------------------------------------------------------------------
// Once-per-turn keys recorded in `state.turn.usedOncePerTurn`
// ---------------------------------------------------------------------------

/** Ezzel (Merchants) 1 goods → 1 any, once per turn. */
export const ONCE_EZZEL = 'ezzel';
/** Fame for Sale: shared key so holding both Re'Bah and Re'Ohm still gives one use. */
export const ONCE_FAME_FOR_SALE = 'fameForSale';
/** A Helping Hand (Ra'Hna). */
export const ONCE_HELPING_HAND = 'helpingHand';
/** Galactic Relief Fund (Ra'Hno) — the key `production/relief.ts` checks. */
export const ONCE_RELIEF_FUND = 'raHno';

function usedThisTurn(state: GameState, key: string): boolean {
  return state.turn.usedOncePerTurn.includes(key);
}

function markUsed(state: GameState, key: string): void {
  if (!usedThisTurn(state, key)) state.turn.usedOncePerTurn.push(key);
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function isResource(value: unknown): value is Resource {
  return typeof value === 'string' && (RESOURCES as readonly string[]).includes(value);
}

/** A bag is well formed when every key is a resource and every count is a non-negative integer. */
function validBag(bag: unknown): bag is ResourceBag {
  if (typeof bag !== 'object' || bag === null) return false;
  for (const [k, v] of Object.entries(bag)) {
    if (!isResource(k)) return false;
    if (typeof v !== 'number' || !Number.isInteger(v) || v < 0) return false;
  }
  return true;
}

function bagText(bag: ResourceBag): string {
  const parts = RESOURCES.filter((r) => (bag[r] ?? 0) > 0).map((r) => `${bag[r]} ${r}`);
  return parts.length ? parts.join(', ') : 'nothing';
}

/** Merchants card (if any) held by the player that gives 2:1 on `resource`. */
function merchant2for1Card(player: Player, resource: Resource): FriendshipCardId | undefined {
  return player.friendshipCards.find((id) => {
    const effect = FRIENDSHIP_CARDS[id].effect;
    return effect.kind === 'merchant2for1' && effect.resource === resource;
  });
}

// ---------------------------------------------------------------------------
// tradeWithSupply
// ---------------------------------------------------------------------------

const handleTradeWithSupply: Handler<'tradeWithSupply'> = (state, action) => {
  const player = getPlayer(state, action.playerId);
  const give = action.give;
  const want = action.want;

  if (!Array.isArray(give) || !give.every(isResource) || !isResource(want)) {
    return gameError('invalidAction', 'tradeWithSupply needs a list of resources to give and one resource to receive');
  }
  if (give.length === 0) {
    return gameError('ruleViolation', 'Trading with the supply always costs cards (no gifting)', { give, want });
  }
  const identical = give.every((r) => r === give[0]);
  const given = give[0] as Resource;

  // Work out which ratio this exchange uses.
  let ratio: string | null = null;
  let onceKey: string | undefined;
  if (identical && give.length === SUPPLY_TRADE.identicalForOne) {
    ratio = `${SUPPLY_TRADE.identicalForOne}:1`;
  } else if (identical && given === 'goods' && give.length === SUPPLY_TRADE.goodsForOne) {
    ratio = `${SUPPLY_TRADE.goodsForOne} goods:1`;
  } else if (identical && give.length === SUPPLY_TRADE.merchantsRate && merchant2for1Card(player, given)) {
    ratio = `Merchants ${SUPPLY_TRADE.merchantsRate}:1 (${FRIENDSHIP_CARDS[merchant2for1Card(player, given) as FriendshipCardId].name})`;
  } else if (identical && given === 'goods' && give.length === 1 && player.friendshipCards.includes('ezzel')) {
    if (usedThisTurn(state, ONCE_EZZEL)) {
      return gameError('ruleViolation', "Ezzel's 1:1 goods trade has already been used this turn", { cardId: 'ezzel' });
    }
    ratio = 'Ezzel 1:1';
    onceKey = ONCE_EZZEL;
  }
  if (ratio === null) {
    return gameError('ruleViolation', 'Invalid supply trade: give 3 identical cards, 2 goods, or use a Merchants card', {
      give,
      want,
    });
  }

  const giveBag = handToBag(give);
  if (!handHas(player.hand, giveBag)) {
    return gameError('insufficientResources', `You do not hold ${bagText(giveBag)}`, { give });
  }
  if (!supplyHas(state, { [want]: 1 })) {
    return gameError('supplyEmpty', `The supply has no ${want} left`, { want });
  }

  removeFromHand(player.hand, giveBag);
  returnToSupply(state, giveBag);
  takeFromSupply(state, { [want]: 1 });
  addToHand(player.hand, { [want]: 1 });
  if (onceKey) markUsed(state, onceKey);
  logEvent(state, `${player.name} traded ${bagText(giveBag)} to the supply for 1 ${want} (${ratio})`, player.id);
  return state;
};

// ---------------------------------------------------------------------------
// proposeTrade / respondTrade
// ---------------------------------------------------------------------------

/** Shared validation for a proposal or counter-offer. `null` when acceptable. */
function validateOffer(from: Player, give: ResourceBag, want: ResourceBag): GameError | null {
  if (!validBag(give) || !validBag(want)) {
    return gameError('invalidAction', 'give/want must map resources to non-negative integer counts');
  }
  if (bagTotal(give) === 0 || bagTotal(want) === 0) {
    return gameError('ruleViolation', 'No gifting: a trade must exchange cards on both sides', { give, want });
  }
  if (!handHas(from.hand, give)) {
    return gameError('insufficientResources', `${from.name} does not hold ${bagText(give)}`, { give });
  }
  return null;
}

const handleProposeTrade: Handler<'proposeTrade'> = (state, action) => {
  const from = getPlayer(state, action.playerId);
  if (action.to === 'supply') {
    return gameError('invalidAction', 'Trade with the supply via tradeWithSupply');
  }
  const to = state.players.find((p) => p.id === action.to);
  if (!to) return gameError('invalidTarget', `Unknown player ${String(action.to)}`);
  if (to.id === from.id) return gameError('invalidTarget', 'You cannot trade with yourself');

  const active = state.activePlayer;
  if (from.id !== active && to.id !== active) {
    return gameError('ruleViolation', 'Non-active players may only trade with the active player', {
      activePlayer: active,
    });
  }
  const offerError = validateOffer(from, action.give, action.want);
  if (offerError) return offerError;

  if (state.openTrade && from.id !== active && state.openTrade.from !== from.id) {
    return gameError('ruleViolation', 'Another trade proposal is already open', { openTrade: state.openTrade });
  }

  state.openTrade = { from: from.id, to: to.id, give: { ...action.give }, want: { ...action.want } };
  logEvent(state, `${from.name} offers ${to.name} ${bagText(action.give)} for ${bagText(action.want)}`, from.id);
  return state;
};

/** Move the goods of a finalised proposal between the two hands. `null` on success. */
function executeTrade(state: GameState): GameError | null {
  const trade = state.openTrade;
  if (!trade || trade.to === 'supply') return gameError('invalidAction', 'No player trade is open');
  const from = getPlayer(state, trade.from);
  const to = getPlayer(state, trade.to);
  if (!handHas(from.hand, trade.give)) {
    return gameError('insufficientResources', `${from.name} no longer holds ${bagText(trade.give)}`, { side: from.id });
  }
  if (!handHas(to.hand, trade.want)) {
    return gameError('insufficientResources', `${to.name} no longer holds ${bagText(trade.want)}`, { side: to.id });
  }
  removeFromHand(from.hand, trade.give);
  removeFromHand(to.hand, trade.want);
  addToHand(to.hand, trade.give);
  addToHand(from.hand, trade.want);
  state.openTrade = null;
  logEvent(state, `${from.name} gave ${to.name} ${bagText(trade.give)} for ${bagText(trade.want)}`, to.id);
  return null;
}

const handleRespondTrade: Handler<'respondTrade'> = (state, action) => {
  const trade = state.openTrade;
  if (!trade || trade.to === 'supply') {
    return gameError('invalidAction', 'There is no open trade proposal to respond to');
  }
  const responder = getPlayer(state, action.playerId);
  const isRecipient = responder.id === trade.to;
  const isProposer = responder.id === trade.from;
  if (!isRecipient && !isProposer) {
    return gameError('ruleViolation', 'Only the two parties of the open proposal may respond', { openTrade: trade });
  }

  if (action.accept) {
    if (!isRecipient) {
      return gameError('ruleViolation', 'Only the recipient of a proposal can accept it', { openTrade: trade });
    }
    // The active player is always one side of a proposal, so the recipient
    // accepting means the active player has consented (either now, as the
    // recipient, or earlier, by proposing).
    const tradeError = executeTrade(state);
    if (tradeError) return tradeError;
    return state;
  }

  if (action.counter) {
    if (!isRecipient) {
      return gameError('ruleViolation', 'Only the recipient of a proposal can counter it', { openTrade: trade });
    }
    const offerError = validateOffer(responder, action.counter.give, action.counter.want);
    if (offerError) return offerError;
    const other = getPlayer(state, trade.from);
    state.openTrade = { from: responder.id, to: other.id, give: { ...action.counter.give }, want: { ...action.counter.want } };
    logEvent(state, `${responder.name} counters: ${bagText(action.counter.give)} for ${bagText(action.counter.want)}`, responder.id);
    return state;
  }

  state.openTrade = null;
  logEvent(state, `${responder.name} ${isRecipient ? 'rejected' : 'withdrew'} the trade proposal`, responder.id);
  return state;
};

// ---------------------------------------------------------------------------
// build
// ---------------------------------------------------------------------------

function isUpgrade(item: string): item is UpgradeKind {
  return Object.hasOwn(UPGRADE_CAPS, item);
}

/** Smallest unused `ship:<color>:<n>` (n ≥ 1), matching setup/beginner.ts ids. */
function nextShipId(state: GameState, player: Player): string {
  for (let n = 1; ; n++) {
    const id = `ship:${player.color}:${n}`;
    if (!state.board.ships[id]) return id;
  }
}

/** Validate and place a new colony / trade ship; `null` on success. */
function buildShip(state: GameState, player: Player, kind: ShipKind, siteId: string | undefined): GameError | null {
  if (player.pieces.transportsLeft < 1 || shipsOf(state, player.id).length >= MAX_SHIPS_ON_BOARD) {
    return gameError('pieceLimit', `No free transport ship (max ${MAX_SHIPS_ON_BOARD} ships on the board)`);
  }
  if (kind === 'colony' && player.pieces.coloniesLeft < 1) {
    return gameError('pieceLimit', 'No colony piece left');
  }
  if (kind === 'trade' && player.pieces.stationsLeft < 1) {
    return gameError('pieceLimit', 'No trade station piece left');
  }
  if (siteId === undefined) {
    return gameError('invalidSite', 'A new ship needs a siteId (one of your spaceport sites)');
  }
  const ownSites = spaceportsOf(state, player.id).flatMap((sp) => spaceportSites(state.board, sp.nodeId));
  if (!ownSites.includes(siteId)) {
    return gameError('invalidSite', `${siteId} is not a spaceport site of one of your spaceports`, { siteId, ownSites });
  }
  if (isOccupied(state.board, siteId)) {
    return gameError('invalidSite', `Spaceport site ${siteId} is occupied`, { siteId });
  }

  const shipId = nextShipId(state, player);
  state.board.ships[shipId] = { id: shipId, owner: player.id, kind, nodeId: siteId, mustFoundOrLeave: false };
  player.pieces.transportsLeft -= 1;
  if (kind === 'colony') player.pieces.coloniesLeft -= 1;
  else player.pieces.stationsLeft -= 1;
  logEvent(state, `${player.name} built a ${kind} ship (${shipId}) at ${siteId}`, player.id);
  return null;
}

function buildSpaceport(state: GameState, player: Player, siteId: string | undefined): GameError | null {
  if (player.pieces.shipyardsLeft < 1) {
    return gameError('pieceLimit', 'No shipyard piece left (max 3 spaceports)');
  }
  if (siteId === undefined) {
    return gameError('invalidSite', 'A spaceport needs a siteId (one of your colonies)');
  }
  const settlement = settlementAt(state.board, siteId);
  if (!settlement || settlement.owner !== player.id) {
    return gameError('invalidSite', `${siteId} is not one of your colonies`, { siteId });
  }
  if (settlement.kind === 'spaceport') {
    return gameError('invalidSite', `${siteId} is already a spaceport`, { siteId });
  }

  settlement.kind = 'spaceport';
  player.pieces.shipyardsLeft -= 1;
  logEvent(state, `${player.name} upgraded the colony at ${siteId} to a spaceport`, player.id);

  // §7.2: an opponent's ship on a new spaceport site must move away next turn.
  for (const site of spaceportSites(state.board, siteId)) {
    const ship = shipAt(state.board, site);
    if (ship && ship.owner !== player.id) {
      ship.mustFoundOrLeave = true;
      const owner = getPlayer(state, ship.owner);
      logEvent(state, `${owner.name}'s ship ${ship.id} sits on ${player.name}'s new spaceport site and must leave next turn`, owner.id);
    }
  }
  // §7.3: a trade-ship marker is placed as soon as possible — the new spaceport may offer the first free site.
  tryPlacePendingTradeShips(state, player.id);
  return null;
}

function buildUpgrade(state: GameState, player: Player, kind: UpgradeKind): GameError | null {
  const trayKey = UPGRADE_TRAY_KEY[kind];
  if (player.mothership[trayKey] >= UPGRADE_CAPS[kind]) {
    return gameError('upgradeCap', `Your mothership already has the maximum of ${UPGRADE_CAPS[kind]} ${trayKey}`, {
      kind,
      cap: UPGRADE_CAPS[kind],
    });
  }
  if (state.upgradesTray[trayKey] < 1) {
    return gameError('supplyEmpty', `No ${trayKey} left in the upgrades tray`, { kind });
  }
  state.upgradesTray[trayKey] -= 1;
  player.mothership[trayKey] += 1;
  logEvent(state, `${player.name} built a ${kind} (${player.mothership[trayKey]}/${UPGRADE_CAPS[kind]})`, player.id);
  return null;
}

const handleBuild: Handler<'build'> = (state, action) => {
  const player = getPlayer(state, action.playerId);
  // Own-property lookup: inherited keys such as 'toString' are not build items.
  const cost = Object.hasOwn(BUILD_COSTS, action.item) ? BUILD_COSTS[action.item] : undefined;
  if (!cost) return gameError('invalidAction', `Unknown build item ${String(action.item)}`);

  // Legality first (what may be built), then affordability.
  let error: GameError | null;
  switch (action.item) {
    case 'colonyShip':
      error = buildShip(state, player, 'colony', action.siteId);
      break;
    case 'tradeShip':
      error = buildShip(state, player, 'trade', action.siteId);
      break;
    case 'spaceport':
      error = buildSpaceport(state, player, action.siteId);
      break;
    default:
      error = isUpgrade(action.item)
        ? buildUpgrade(state, player, action.item)
        : gameError('invalidAction', `Unknown build item ${String(action.item)}`);
  }
  if (error) return error;

  // The state is a discarded clone on error, so paying after placement is safe.
  if (!handHas(player.hand, cost)) {
    return gameError('insufficientResources', `${action.item} costs ${bagText(cost)}`, { cost, hand: handToBag(player.hand) });
  }
  removeFromHand(player.hand, cost);
  returnToSupply(state, cost);
  return state;
};

// ---------------------------------------------------------------------------
// useFriendshipCard (Diplomats incl. Galactic Relief Fund; Merchants go through tradeWithSupply)
// ---------------------------------------------------------------------------

function fameForSale(state: GameState, player: Player, cardId: FriendshipCardId): GameError | null {
  if (usedThisTurn(state, ONCE_FAME_FOR_SALE)) {
    return gameError('ruleViolation', 'Fame for Sale has already been used this turn (once per turn even with both copies)', {
      cardId,
    });
  }
  if (!handHas(player.hand, { goods: 1 })) {
    return gameError('insufficientResources', 'Fame for Sale costs 1 goods');
  }
  if (state.upgradesTray.famePieces < 1) {
    return gameError('supplyEmpty', 'No fame pieces left in the tray');
  }
  removeFromHand(player.hand, { goods: 1 });
  returnToSupply(state, { goods: 1 });
  state.upgradesTray.famePieces -= 1;
  player.famePieces += 1;
  markUsed(state, ONCE_FAME_FOR_SALE);
  logEvent(state, `${player.name} paid 1 goods for 1 fame piece (${FRIENDSHIP_CARDS[cardId].name})`, player.id);
  return null;
}

function helpingHand(state: GameState, player: Player, targets: string[] | undefined, rng: Rng): GameError | null {
  if (usedThisTurn(state, ONCE_HELPING_HAND)) {
    return gameError('ruleViolation', 'A Helping Hand has already been used this turn');
  }
  const richer = state.players.filter((p) => p.id !== player.id && p.vp > player.vp).map((p) => p.id);
  if (richer.length < 2) {
    return gameError('ruleViolation', 'A Helping Hand needs at least 2 opponents with more VP than you', {
      yourVp: player.vp,
      opponentsAhead: richer,
    });
  }
  if (!Array.isArray(targets) || targets.length !== 2 || targets[0] === targets[1]) {
    return gameError('invalidTarget', 'Choose exactly 2 different opponents', { eligible: richer });
  }
  if (!targets.every((t) => richer.includes(t))) {
    return gameError('invalidTarget', 'Both targets must be opponents with more VP than you', { targets, eligible: richer });
  }
  const drawn: Resource[] = [];
  for (const id of targets) {
    const victim = getPlayer(state, id);
    if (victim.hand.length === 0) {
      logEvent(state, `${victim.name} has no cards for ${player.name} to draw`, player.id);
      continue;
    }
    const [card] = victim.hand.splice(rng.int(victim.hand.length), 1) as [Resource];
    player.hand.push(card);
    drawn.push(card);
    logEvent(state, `${player.name} drew 1 card from ${victim.name} (A Helping Hand)`, player.id);
  }
  markUsed(state, ONCE_HELPING_HAND);
  return null;
}

/**
 * Galactic Relief Fund (spec §5.1): a holder who produced nothing on this
 * turn's (non-7) roll takes any 1 resource. Eligibility lives in
 * production/relief.ts; may be claimed during production or Trade & Build.
 */
function galacticReliefFund(state: GameState, player: Player, want: unknown): GameError | null {
  if (!reliefEligible(state, player.id)) {
    return gameError('ruleViolation', 'Galactic Relief Fund: only after a non-7 roll that gave you nothing, once per turn', {
      rolled: state.turn.rolled,
      received: state.turn.productionReceived?.[player.id],
    });
  }
  if (!isResource(want)) {
    return gameError('invalidAction', 'Galactic Relief Fund needs `want`: the resource to take');
  }
  if (!takeFromSupply(state, { [want]: 1 })) {
    return gameError('supplyEmpty', `The supply has no ${want} left`, { want });
  }
  addToHand(player.hand, { [want]: 1 });
  markUsed(state, ONCE_RELIEF_FUND);
  logEvent(state, `${player.name} took 1 ${want} from the Galactic Relief Fund`, player.id);
  return null;
}

const handleUseFriendshipCard: Handler<'useFriendshipCard'> = (state, action, rng) => {
  const player = getPlayer(state, action.playerId);
  const def = Object.hasOwn(FRIENDSHIP_CARDS, action.cardId) ? FRIENDSHIP_CARDS[action.cardId] : undefined;
  if (!def) return gameError('invalidAction', `Unknown friendship card ${String(action.cardId)}`);
  // Only the Galactic Relief Fund may be claimed by a non-active player (§5.1);
  // `ACTION_POLICY` leaves the envelope open so that holder can act on another
  // player's roll. Everything else is a Trade & Build action of the active player.
  if (def.effect.kind !== 'galacticReliefFund' && state.activePlayer !== player.id) {
    return gameError('notYourTurn', `${def.name} may only be used by the active player`);
  }
  if (!player.friendshipCards.includes(action.cardId)) {
    return gameError('ruleViolation', `You do not hold ${def.name}`, { cardId: action.cardId });
  }

  switch (def.effect.kind) {
    case 'galacticReliefFund': {
      const reliefError = galacticReliefFund(state, player, action.want);
      return reliefError ?? state;
    }
    case 'merchant2for1':
    case 'merchant1for1':
      return gameError('invalidAction', `${def.name} is used through tradeWithSupply`);
    case 'fameForSale':
    case 'helpingHand':
      break;
    default:
      return gameError('invalidAction', `${def.name} is a passive card; it has no action`);
  }
  if (state.phase !== 'tradeBuild') {
    return gameError('wrongPhase', `${def.name} may only be used during Trade & Build`, { phase: state.phase });
  }

  const error =
    def.effect.kind === 'fameForSale'
      ? fameForSale(state, player, action.cardId)
      : helpingHand(state, player, action.targets, rng);
  if (error) return error;
  return state;
};

export const handlers: HandlerMap = {
  tradeWithSupply: handleTradeWithSupply,
  proposeTrade: handleProposeTrade,
  respondTrade: handleRespondTrade,
  build: handleBuild,
  useFriendshipCard: handleUseFriendshipCard,
};

export const tradeBuildModule: ActionModule = { handlers };
