/**
 * Encounter interpreter (spec §10). Owns `state.turn.encounter` while
 * `phase === 'flight.encounter'`.
 *
 * Flow:
 *   startEncounter(state, rng)        black ball → draw a card (reshuffling the discard
 *                                     pile when the deck is empty) → beginEncounter
 *   beginEncounter(state, cardId, rng) context at stage 'choice', prompt revealed; a
 *                                     'none' card (31/32) commits its 'auto' branch at once
 *   commitChoice(state, key, rng)     reveal the branch text, queue its effects for the
 *                                     active player, stage 'resolving', run the queue
 *   runEncounterQueue(state, rng)     pop effects and apply them until one needs a
 *                                     player's decision (`ctx.awaiting`) or the queue
 *                                     is empty (→ finishEncounter)
 *   applyEncounterPick(state, action, rng) validate + apply the answer to `ctx.awaiting`
 *                                     (the handler then resumes the queue)
 *   finishEncounter(state)            card → discard pile, stage 'done', base speed 3,
 *                                     `refreshSpeed`, tokens re-checked, phase 'flight.move'
 *
 * Rules honoured here (§10 "Mechanics"):
 *   - in-encounter shakes use `drawBalls` with black = 0 and never start a new encounter;
 *   - combat = ball total + `combatStrengthOf`, speed race = ball total +
 *     `boosterCountForRace`, the active player wins ties; the opponent gains and
 *     loses nothing;
 *   - flee compares `boosterCountForRace` of both sides without a shake;
 *   - "any" resources are the receiver's choice, limited by the supply; fame
 *     never drops below 0 and never exceeds the tray; "remove / immobilize"
 *     with nothing to remove / immobilize is simply skipped;
 *   - cards 31/32 process the players in turn order from the active player,
 *     then reshuffle deck + discards + the card itself and draw a new card.
 *
 * Determinism: every random decision (shakes, random steals, reshuffles) goes
 * through `rng`.
 */

import { BLACK_BALL_BASE_SPEED, UPGRADE_CAPS, UPGRADE_TRAY_KEY, shakeBand } from '../config.js';
import { logEvent } from '../actions/handler.js';
import { getPlayer, playerToLeft, playerToRight, shipsOf } from '../board/query.js';
import { applySpaceJump, validateJumpTarget } from '../flight/jump.js';
import { drawBalls, evaluateShake } from '../flight/shake.js';
import { boosterCountForRace, combatStrengthOf, refreshSpeed } from '../flight/stats.js';
import { checkSpecialTokensForPlayer } from '../flight/tokens.js';
import { grantFreeTradeShip } from '../found/freeTradeShip.js';
import type { Rng } from '../rng.js';
import { addToHand, bagTotal, handHas, handToBag, removeFromHand, returnToSupply, supplyHas, takeFromSupply } from '../supply.js';
import type { EncounterPickAction, GameError, GameState, Player, PlayerId, Resource, UpgradeKind } from '../types.js';
import { RESOURCES, gameError } from '../types.js';
import { encounterCard } from './cards.js';
import type {
  ContestKind,
  EncounterCtx,
  EncounterEffect,
  EncounterOpponent,
  EncounterPickRequest,
  QueuedEffect,
  ShakeSide,
} from './schema.js';
import { revealText } from './text.js';

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

const UPGRADE_KINDS: readonly UpgradeKind[] = ['booster', 'cannon', 'freightPod'];

function isResource(value: unknown): value is Resource {
  return typeof value === 'string' && (RESOURCES as readonly string[]).includes(value);
}

function isUpgradeKind(value: unknown): value is UpgradeKind {
  return typeof value === 'string' && (UPGRADE_KINDS as readonly string[]).includes(value);
}

function plural(n: number, word: string): string {
  return `${n} ${word}${n === 1 ? '' : 's'}`;
}

/** Boosters + cannons + freight pods on the mothership (Scientist cards never count). */
export function physicalUpgradeCount(player: Player): number {
  return player.mothership.boosters + player.mothership.cannons + player.mothership.freightPods;
}

/** Upgrade kinds the player holds at least one of (what "remove 1 upgrade" may pick from). */
export function removableUpgradeKinds(player: Player): UpgradeKind[] {
  return UPGRADE_KINDS.filter((k) => player.mothership[UPGRADE_TRAY_KEY[k]] > 0);
}

/** Upgrade kinds that can be placed right now: below the cap and left in the tray. */
export function grantableUpgradeKinds(state: GameState, player: Player): UpgradeKind[] {
  return UPGRADE_KINDS.filter((k) => {
    const key = UPGRADE_TRAY_KEY[k];
    return player.mothership[key] < UPGRADE_CAPS[k] && state.upgradesTray[key] > 0;
  });
}

/** The player a card names relative to `playerId` (L/R = next seat, LL/RR = two seats). */
export function resolveOpponent(state: GameState, playerId: PlayerId, seat: EncounterOpponent): PlayerId {
  switch (seat) {
    case 'L':
      return playerToLeft(state, playerId, 1);
    case 'LL':
      return playerToLeft(state, playerId, 2);
    case 'R':
      return playerToRight(state, playerId, 1);
    case 'RR':
      return playerToRight(state, playerId, 2);
  }
}

/** Opponents of `playerId` in turn order, starting with the player to their left. */
export function opponentsInOrder(state: GameState, playerId: PlayerId): PlayerId[] {
  const n = state.turnOrder.length;
  const ids: PlayerId[] = [];
  for (let offset = 1; offset < n; offset++) ids.push(playerToLeft(state, playerId, offset));
  return ids;
}

/** Give fame pieces from the tray (as many as the tray holds); returns how many moved. */
function giveFame(state: GameState, player: Player, count: number): number {
  const n = Math.max(0, Math.min(count, state.upgradesTray.famePieces));
  state.upgradesTray.famePieces -= n;
  player.famePieces += n;
  return n;
}

/** Take fame pieces back to the tray, never below 0; returns how many moved. */
function takeFame(state: GameState, player: Player, count: number): number {
  const n = Math.max(0, Math.min(count, player.famePieces));
  player.famePieces -= n;
  state.upgradesTray.famePieces += n;
  return n;
}

function ctxOf(state: GameState): EncounterCtx {
  const ctx = state.turn.encounter;
  if (!ctx) throw new Error('No encounter in progress');
  return ctx;
}

function queued(playerId: PlayerId, effects: readonly EncounterEffect[]): QueuedEffect[] {
  return effects.map((effect) => ({ playerId, effect }));
}

function awaitPick(ctx: EncounterCtx, request: EncounterPickRequest): 'await' {
  ctx.awaiting = request;
  return 'await';
}

// ---------------------------------------------------------------------------
// Deck
// ---------------------------------------------------------------------------

/** Top card of the encounter deck, reshuffling the discard pile when the deck is empty. */
export function drawEncounterCard(state: GameState, rng: Rng): number | undefined {
  if (state.encounterDeck.length === 0 && state.encounterDiscard.length > 0) {
    state.encounterDeck = rng.shuffle(state.encounterDiscard);
    state.encounterDiscard = [];
    logEvent(state, 'Encounter discard pile reshuffled into a new deck', null);
  }
  return state.encounterDeck.shift();
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/**
 * Black ball: draw the next card and start it. Returns false (and changes
 * nothing) when neither the deck nor the discard pile holds a card.
 */
export function startEncounter(state: GameState, rng: Rng): boolean {
  const cardId = drawEncounterCard(state, rng);
  if (cardId === undefined) return false;
  beginEncounter(state, cardId, rng);
  return true;
}

/** Start the given card for the active player (tests use this to pick a card directly). */
export function beginEncounter(state: GameState, cardId: number, rng: Rng): void {
  const card = encounterCard(cardId);
  const ctx: EncounterCtx = { cardId, stage: 'choice', revealed: [], queue: [] };
  state.turn.encounter = ctx;
  state.phase = 'flight.encounter';
  const active = getPlayer(state, state.activePlayer);
  logEvent(state, `Encounter card ${cardId} "${card.title}" drawn for ${active.name}`, active.id);
  revealText(ctx, card.prompt);
  if (card.choice === 'none') commitChoice(state, 'auto', rng);
}

/** The active player has chosen `branchKey`: reveal its text, queue its effects and resolve. */
export function commitChoice(state: GameState, branchKey: string, rng: Rng): void {
  const ctx = ctxOf(state);
  const card = encounterCard(ctx.cardId);
  const branch = card.branches[branchKey];
  if (!branch) throw new Error(`Card ${card.id} has no branch '${branchKey}'`);
  ctx.choice = branchKey;
  ctx.stage = 'resolving';
  revealText(ctx, branch.text);
  ctx.queue.push(...queued(state.activePlayer, branch.effects));
  runEncounterQueue(state, rng);
}

/** Apply queued effects until a pick is needed or the queue is empty. */
export function runEncounterQueue(state: GameState, rng: Rng): void {
  const ctx = state.turn.encounter;
  if (!ctx || ctx.stage !== 'resolving' || ctx.awaiting) return;
  while (ctx.queue.length > 0) {
    const item = ctx.queue.shift() as QueuedEffect;
    const outcome = applyEffect(state, ctx, item, rng);
    if (outcome !== 'continue') return;
  }
  finishEncounter(state);
}

/** Card to the discard pile, stage 'done', flight continues at base speed 3. */
export function finishEncounter(state: GameState): void {
  const ctx = ctxOf(state);
  delete ctx.awaiting;
  ctx.stage = 'done';
  state.encounterDiscard.push(ctx.cardId);
  state.turn.baseSpeed = BLACK_BALL_BASE_SPEED;
  refreshSpeed(state);
  // A ship that jumped has finished its movement, whatever the speed is now.
  if (ctx.jumpedTo) state.turn.shipMovesUsed[ctx.jumpedTo.shipId] = state.turn.speed ?? 0;
  // Upgrades gained next to a pirate base / ice planet claim it (§9.6 "immediately").
  checkSpecialTokensForPlayer(state, state.activePlayer);
  state.phase = 'flight.move';
  logEvent(state, `Encounter card ${ctx.cardId} resolved; flight continues at speed ${state.turn.speed}`, state.activePlayer);
}

/** Discard (or reshuffle everything) and start the next card. */
function redraw(state: GameState, ctx: EncounterCtx, reshuffle: boolean, rng: Rng): 'restart' {
  if (reshuffle) {
    state.encounterDeck = rng.shuffle([...state.encounterDeck, ...state.encounterDiscard, ctx.cardId]);
    state.encounterDiscard = [];
    logEvent(state, `Encounter card ${ctx.cardId}: the whole encounter deck is reshuffled`, null);
  } else {
    state.encounterDiscard.push(ctx.cardId);
    logEvent(state, `Encounter card ${ctx.cardId} discarded; a new card is drawn`, state.activePlayer);
  }
  const next = drawEncounterCard(state, rng);
  if (next === undefined) throw new Error('redraw: no encounter card left'); // impossible: this card was just returned
  beginEncounter(state, next, rng);
  return 'restart';
}

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------

type Outcome = 'continue' | 'await' | 'restart';

function shakeSide(state: GameState, playerId: PlayerId, kind: ContestKind, rng: Rng): ShakeSide {
  const result = evaluateShake(drawBalls(rng));
  const bonus = kind === 'combat' ? combatStrengthOf(state, playerId) : boosterCountForRace(state, playerId);
  return { playerId, balls: result.balls, total: result.total, bonus, strength: result.total + bonus };
}

function sideText(state: GameState, side: ShakeSide, kind: ContestKind): string {
  const name = getPlayer(state, side.playerId).name;
  const what = kind === 'combat' ? 'cannons' : 'boosters';
  return `${name}: ${side.balls.join(' + ')} = ${side.total}, +${side.bonus} ${what} → ${side.strength}`;
}

function applyEffect(state: GameState, ctx: EncounterCtx, item: QueuedEffect, rng: Rng): Outcome {
  const { effect } = item;
  const player = getPlayer(state, item.playerId);
  const active = getPlayer(state, state.activePlayer);

  switch (effect.type) {
    case 'gainResource': {
      if (effect.resource !== 'any') {
        const n = Math.min(effect.count, state.supply[effect.resource]);
        if (n > 0) {
          takeFromSupply(state, { [effect.resource]: n });
          addToHand(player.hand, { [effect.resource]: n });
        }
        logEvent(state, `${player.name} receives ${plural(n, effect.resource)}${n < effect.count ? ' (supply short)' : ''}`, player.id);
        return 'continue';
      }
      const available = bagTotal(state.supply);
      const count = Math.min(effect.count, available);
      if (count === 0) {
        logEvent(state, `${player.name} would receive ${plural(effect.count, 'resource')} but the supply is empty`, player.id);
        return 'continue';
      }
      return awaitPick(ctx, { kind: 'resources', playerId: player.id, count, effect });
    }

    case 'gainFame': {
      const n = giveFame(state, player, effect.count);
      logEvent(state, `${player.name} gains ${plural(n, 'fame piece')}${n < effect.count ? ' (tray short)' : ''}`, player.id);
      return 'continue';
    }

    case 'loseFame': {
      const n = takeFame(state, player, effect.count);
      logEvent(state, `${player.name} loses ${plural(n, 'fame piece')}`, player.id);
      return 'continue';
    }

    case 'gainUpgrade': {
      const options = grantableUpgradeKinds(state, player);
      if (effect.kind === 'any') {
        if (options.length === 0) {
          logEvent(state, `${player.name} would receive an upgrade, but none can be placed (cap reached / tray empty)`, player.id);
          return 'continue';
        }
        return awaitPick(ctx, { kind: 'upgradeKind', playerId: player.id, options, effect });
      }
      if (!options.includes(effect.kind)) {
        logEvent(state, `${player.name} would receive a ${effect.kind}, but it cannot be placed (cap reached / tray empty)`, player.id);
        return 'continue';
      }
      placeUpgrade(state, player, effect.kind);
      return 'continue';
    }

    case 'removeUpgrade': {
      const options = removableUpgradeKinds(player);
      if (options.length === 0) {
        logEvent(state, `${player.name} has no upgrade to remove`, player.id);
        return 'continue';
      }
      return awaitPick(ctx, { kind: 'removeUpgrade', playerId: player.id, options, effect });
    }

    case 'immobilizeShip': {
      const options = shipsOf(state, player.id)
        .map((s) => s.id)
        .filter((id) => !state.turn.immobilized.includes(id));
      if (options.length === 0) {
        logEvent(state, `${player.name} has no ship that could be immobilized`, player.id);
        return 'continue';
      }
      return awaitPick(ctx, { kind: 'immobilizeShip', playerId: player.id, options, effect });
    }

    case 'freeTradeShip': {
      const how = grantFreeTradeShip(state, player.id);
      logEvent(state, `${player.name} is granted a free trade ship (${how})`, player.id);
      return 'continue';
    }

    case 'spaceJump': {
      const options = shipsOf(state, player.id).map((s) => s.id);
      if (options.length === 0) {
        logEvent(state, `${player.name} has no ship for a space jump`, player.id);
        return 'continue';
      }
      return awaitPick(ctx, { kind: 'spaceJump', playerId: player.id, options, effect });
    }

    case 'stealRandomFromAll': {
      for (const id of opponentsInOrder(state, player.id)) {
        const victim = getPlayer(state, id);
        if (victim.hand.length === 0) {
          logEvent(state, `${victim.name} has no card to take`, player.id);
          continue;
        }
        const [card] = victim.hand.splice(rng.int(victim.hand.length), 1) as [Resource];
        player.hand.push(card);
        logEvent(state, `${player.name} takes 1 random card from ${victim.name}`, player.id);
      }
      return 'continue';
    }

    case 'everyoneGivesOne': {
      const givers = opponentsInOrder(state, player.id).filter((id) => getPlayer(state, id).hand.length > 0);
      for (const id of opponentsInOrder(state, player.id)) {
        if (!givers.includes(id)) logEvent(state, `${getPlayer(state, id).name} has no card to give`, id);
      }
      ctx.queue.unshift(...givers.map((id) => ({ playerId: id, effect: { type: 'giveOne' } as EncounterEffect })));
      return 'continue';
    }

    case 'giveOne': {
      if (player.hand.length === 0) {
        logEvent(state, `${player.name} has no card to give`, player.id);
        return 'continue';
      }
      return awaitPick(ctx, { kind: 'giveOne', playerId: player.id, count: 1, effect });
    }

    case 'payResources': {
      const count = Math.min(effect.count, player.hand.length);
      if (count === 0) {
        logEvent(state, `${player.name} has no card to pay`, player.id);
        return 'continue';
      }
      return awaitPick(ctx, { kind: 'payResources', playerId: player.id, count, effect });
    }

    case 'loseOffer': {
      const n = ctx.offerPaid?.length ?? 0;
      logEvent(state, `${player.name}'s offer of ${plural(n, 'card')} is lost`, player.id);
      return 'continue';
    }

    case 'returnOffer': {
      const bag = handToBag(ctx.offerPaid ?? []);
      if (bagTotal(bag) > 0) {
        takeFromSupply(state, bag);
        addToHand(player.hand, bag);
      }
      logEvent(state, `${player.name} gets the offer back (${plural(bagTotal(bag), 'card')})`, player.id);
      return 'continue';
    }

    case 'redraw':
      return redraw(state, ctx, effect.reshuffle === true, rng);

    case 'contest': {
      const opponentId = resolveOpponent(state, player.id, effect.opponent);
      const yours = shakeSide(state, player.id, effect.kind, rng);
      const theirs = shakeSide(state, opponentId, effect.kind, rng);
      const won = yours.strength >= theirs.strength;
      ctx.contestResults = [...(ctx.contestResults ?? []), { kind: effect.kind, yours, theirs, won }];
      const label = effect.kind === 'combat' ? 'Combat' : 'Speed race';
      const text = `${label} — ${sideText(state, yours, effect.kind)}; ${sideText(state, theirs, effect.kind)}. ${player.name} ${won ? 'wins' : 'loses'}.`;
      revealText(ctx, text);
      logEvent(state, text, player.id);
      ctx.queue.unshift(...queued(player.id, won ? effect.win : effect.lose));
      return 'continue';
    }

    case 'flee': {
      const opponentId = resolveOpponent(state, player.id, effect.opponent);
      const yours = boosterCountForRace(state, player.id);
      const theirs = boosterCountForRace(state, opponentId);
      const escaped = yours >= theirs;
      ctx.fleeResults = [...(ctx.fleeResults ?? []), { opponent: opponentId, yours, theirs, escaped }];
      const text = `Flee — ${player.name} ${yours} boosters vs ${getPlayer(state, opponentId).name} ${theirs}: ${escaped ? 'escaped' : 'caught'}.`;
      revealText(ctx, text);
      logEvent(state, text, player.id);
      ctx.queue.unshift(...queued(player.id, escaped ? effect.escaped : effect.caught));
      return 'continue';
    }

    case 'tradeOneForTwo': {
      if (player.hand.length === 0) {
        logEvent(state, `${player.name} has no card to trade`, player.id);
        return 'continue';
      }
      return awaitPick(ctx, { kind: 'payResources', playerId: player.id, count: 1, effect });
    }

    case 'confiscateTrade': {
      const bag = handToBag(ctx.tradeReceived ?? []);
      if (bagTotal(bag) > 0 && handHas(player.hand, bag)) {
        removeFromHand(player.hand, bag);
        returnToSupply(state, bag);
      }
      logEvent(state, `${plural(bagTotal(bag), 'card')} confiscated from ${player.name}`, player.id);
      return 'continue';
    }

    case 'shakeTable': {
      const result = evaluateShake(drawBalls(rng));
      const band = shakeBand(result.total);
      ctx.tableShakes = [...(ctx.tableShakes ?? []), { balls: result.balls, total: result.total, band }];
      const text = `${player.name} shakes ${result.balls.join(' + ')} = ${result.total} (${band}).`;
      revealText(ctx, text);
      logEvent(state, text, player.id);
      ctx.queue.unshift(...queued(player.id, effect[band]));
      return 'continue';
    }

    case 'wearAndTear': {
      const n = state.turnOrder.length;
      const hit: PlayerId[] = [];
      for (let offset = 0; offset < n; offset++) {
        const id = playerToLeft(state, active.id, offset);
        if (physicalUpgradeCount(getPlayer(state, id)) > effect.threshold) hit.push(id);
      }
      const names = hit.map((id) => getPlayer(state, id).name);
      const text = hit.length === 0
        ? `Wear and tear: nobody has more than ${effect.threshold} upgrades.`
        : `Wear and tear: ${names.join(', ')} must each remove 1 upgrade (more than ${effect.threshold}).`;
      revealText(ctx, text);
      logEvent(state, text, null);
      ctx.queue.unshift(...hit.map((id) => ({ playerId: id, effect: { type: 'removeUpgrade' } as EncounterEffect })));
      return 'continue';
    }

    case 'galacticCouncil': {
      const most = Math.max(...state.players.map((p) => p.mothership.freightPods));
      const honoured = most >= 1 ? state.players.filter((p) => p.mothership.freightPods === most) : [];
      for (const p of honoured) giveFame(state, p, 1);
      const text = honoured.length === 0
        ? 'Galactic council: nobody owns a freight pod, no fame is awarded.'
        : `Galactic council: ${honoured.map((p) => p.name).join(', ')} (${plural(most, 'freight pod')}) gain 1 fame piece each.`;
      revealText(ctx, text);
      logEvent(state, text, null);
      return 'continue';
    }
  }
}

function placeUpgrade(state: GameState, player: Player, kind: UpgradeKind): void {
  const key = UPGRADE_TRAY_KEY[kind];
  state.upgradesTray[key] -= 1;
  player.mothership[key] += 1;
  logEvent(state, `${player.name} receives a ${kind} (${player.mothership[key]}/${UPGRADE_CAPS[kind]})`, player.id);
}

// ---------------------------------------------------------------------------
// Picks
// ---------------------------------------------------------------------------

function resourceList(value: unknown, count: number): Resource[] | GameError {
  if (!Array.isArray(value) || !value.every(isResource)) {
    return gameError('invalidAction', `encounterPick needs \`resources\`: a list of ${plural(count, 'resource')}`);
  }
  if (value.length !== count) {
    return gameError('invalidAction', `Pick exactly ${plural(count, 'resource')}`, { count, given: value.length });
  }
  return value;
}

/**
 * Validate and apply the answer to `ctx.awaiting`. The caller has checked that
 * `action.playerId === awaiting.playerId`. Clears `awaiting` on success unless
 * the same effect immediately needs another pick (tradeOneForTwo).
 */
export function applyEncounterPick(state: GameState, action: EncounterPickAction, rng?: Rng): GameError | null {
  const ctx = ctxOf(state);
  const request = ctx.awaiting;
  if (!request) return gameError('ruleViolation', 'No encounter pick is pending');
  const player = getPlayer(state, request.playerId);
  const active = getPlayer(state, state.activePlayer);
  const count = request.count ?? 1;

  switch (request.kind) {
    case 'resources': {
      const resources = resourceList(action.resources, count);
      if (!Array.isArray(resources)) return resources;
      const bag = handToBag(resources);
      if (!supplyHas(state, bag)) {
        return gameError('supplyEmpty', 'The supply does not hold those resources', { requested: bag, supply: { ...state.supply } });
      }
      takeFromSupply(state, bag);
      addToHand(player.hand, bag);
      if (request.effect.type === 'tradeOneForTwo') ctx.tradeReceived = [...resources];
      logEvent(state, `${player.name} takes ${resources.join(', ')} from the supply`, player.id);
      break;
    }

    case 'payResources': {
      const resources = resourceList(action.resources, count);
      if (!Array.isArray(resources)) return resources;
      const bag = handToBag(resources);
      if (!handHas(player.hand, bag)) {
        return gameError('insufficientResources', `${player.name} does not hold ${resources.join(', ')}`, { requested: bag });
      }
      removeFromHand(player.hand, bag);
      returnToSupply(state, bag);
      logEvent(state, `${player.name} pays ${resources.join(', ')} to the supply`, player.id);
      if (request.effect.type === 'tradeOneForTwo') {
        const available = Math.min(2, bagTotal(state.supply));
        if (available > 0) {
          ctx.awaiting = { kind: 'resources', playerId: player.id, count: available, effect: request.effect };
          return null;
        }
        logEvent(state, `${player.name} receives nothing: the supply is empty`, player.id);
      }
      break;
    }

    case 'giveOne': {
      const resources = resourceList(action.resources, 1);
      if (!Array.isArray(resources)) return resources;
      const bag = handToBag(resources);
      if (!handHas(player.hand, bag)) {
        return gameError('insufficientResources', `${player.name} does not hold ${resources.join(', ')}`, { requested: bag });
      }
      removeFromHand(player.hand, bag);
      addToHand(active.hand, bag);
      logEvent(state, `${player.name} gives ${active.name} 1 card`, player.id);
      break;
    }

    case 'upgradeKind':
    case 'removeUpgrade': {
      const kind = action.upgrade;
      if (!isUpgradeKind(kind) || !(request.options ?? []).includes(kind)) {
        return gameError('invalidTarget', `Choose one of: ${(request.options ?? []).join(', ')}`, { options: request.options });
      }
      if (request.kind === 'upgradeKind') {
        placeUpgrade(state, player, kind);
      } else {
        const key = UPGRADE_TRAY_KEY[kind];
        player.mothership[key] -= 1;
        state.upgradesTray[key] += 1;
        logEvent(state, `${player.name} removes a ${kind} (${player.mothership[key]} left)`, player.id);
      }
      break;
    }

    case 'immobilizeShip': {
      const shipId = action.shipId;
      if (typeof shipId !== 'string' || !(request.options ?? []).includes(shipId)) {
        return gameError('invalidTarget', `Choose one of your ships: ${(request.options ?? []).join(', ')}`, { options: request.options });
      }
      state.turn.immobilized.push(shipId);
      ctx.immobilizedShip = shipId;
      logEvent(state, `${player.name}'s ship ${shipId} cannot move this turn`, player.id);
      break;
    }

    case 'spaceJump': {
      if (action.decline === true) {
        logEvent(state, `${player.name} declines the space jump`, player.id);
        break;
      }
      const shipId = action.shipId;
      if (typeof shipId !== 'string' || !(request.options ?? []).includes(shipId)) {
        return gameError('invalidTarget', `Choose one of your ships: ${(request.options ?? []).join(', ')}`, { options: request.options });
      }
      if (typeof action.targetNodeId !== 'string') {
        return gameError('invalidAction', 'A space jump needs `targetNodeId` (or `decline: true`)');
      }
      const error = validateJumpTarget(state, shipId, action.targetNodeId);
      if (error) return error;
      applySpaceJump(state, shipId, action.targetNodeId, rng);
      ctx.jumpedTo = { shipId, nodeId: action.targetNodeId };
      break;
    }
  }

  delete ctx.awaiting;
  return null;
}
