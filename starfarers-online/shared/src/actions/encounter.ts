/**
 * ENCOUNTER handlers (spec §10, §12.2), phase 'flight.encounter':
 *   encounterChoice{value, cards?} — the active player's answer to the card.
 *       offer0to3 / offerThenYesno (first step): `value` 0–3 and `cards` (exactly
 *       that many, held in hand) are paid to the supply BEFORE the result is
 *       revealed — with an empty hand only 0 is possible. yesno / offerThenYesno
 *       (second step): `value: boolean`.
 *   encounterPick{...} — answer to `turn.encounter.awaiting`, sent by the player
 *       named there. NOT gated on the active player by ACTION_POLICY because
 *       some picks belong to opponents ("everyone gives you 1 card of their
 *       choice", "Wear and Tear" removals); the handler checks the sender.
 *
 * The interpreter itself lives in encounters/engine.ts; this module only
 * validates the envelope of each intent and resumes the queue.
 */

import { getPlayer } from '../board/query.js';
import { encounterCard } from '../encounters/cards.js';
import { applyEncounterPick, commitChoice, runEncounterQueue } from '../encounters/engine.js';
import { MAX_OFFER } from '../encounters/schema.js';
import { revealText } from '../encounters/text.js';
import { handHas, handToBag, removeFromHand, returnToSupply } from '../supply.js';
import type { EncounterCtx, GameError, GameState, Player, Resource } from '../types.js';
import { RESOURCES, gameError } from '../types.js';
import type { ActionModule, Handler, HandlerMap } from './handler.js';
import { logEvent } from './handler.js';

function isResource(value: unknown): value is Resource {
  return typeof value === 'string' && (RESOURCES as readonly string[]).includes(value);
}

/** Validate an offer of 0–MAX_OFFER cards and move them to the supply. */
function payOffer(state: GameState, ctx: EncounterCtx, player: Player, value: unknown, cards: unknown): GameError | null {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0 || value > MAX_OFFER) {
    return gameError('invalidAction', `This card asks for an offer: \`value\` must be 0–${MAX_OFFER}`, { value });
  }
  const list = cards ?? [];
  if (!Array.isArray(list) || !list.every(isResource)) {
    return gameError('invalidAction', 'An offer lists the `cards` handed to the supply', { cards });
  }
  if (list.length !== value) {
    return gameError('invalidAction', `An offer of ${value} needs exactly ${value} card${value === 1 ? '' : 's'}`, { value, cards: list });
  }
  const bag = handToBag(list);
  if (!handHas(player.hand, bag)) {
    return gameError('insufficientResources', `You do not hold ${list.join(', ')} (with no cards you must offer 0)`, { cards: list });
  }
  removeFromHand(player.hand, bag);
  returnToSupply(state, bag);
  ctx.offerPaid = [...list];
  logEvent(state, `${player.name} offers ${value} card${value === 1 ? '' : 's'}${value > 0 ? ` (${list.join(', ')})` : ''}`, player.id);
  return null;
}

const handleEncounterChoice: Handler<'encounterChoice'> = (state, action, rng) => {
  const ctx = state.turn.encounter;
  if (!ctx || ctx.stage !== 'choice') {
    return gameError('ruleViolation', 'No encounter choice is pending', { stage: ctx?.stage });
  }
  const card = encounterCard(ctx.cardId);
  const player = getPlayer(state, action.playerId);

  const offerStep = card.choice === 'offer0to3' || (card.choice === 'offerThenYesno' && ctx.offerPaid === undefined);
  if (offerStep) {
    const error = payOffer(state, ctx, player, action.value, action.cards);
    if (error) return error;
    if (card.choice === 'offer0to3') {
      commitChoice(state, String(action.value), rng);
      return state;
    }
    revealText(ctx, `${player.name} hands over ${action.value as number} card${action.value === 1 ? '' : 's'}.`);
    return state; // still stage 'choice': the yes/no follows
  }

  if (typeof action.value !== 'boolean') {
    return gameError('invalidAction', 'This card asks for a yes/no answer: `value` must be a boolean', { value: action.value });
  }
  const key = action.value ? 'yes' : 'no';
  const branch = card.branches[key];
  if (!branch) return gameError('invalidAction', `Card ${card.id} has no '${key}' branch`);
  if (branch.effects.some((e) => e.type === 'tradeOneForTwo') && player.hand.length === 0) {
    return gameError('insufficientResources', 'You need a card in hand to accept this trade');
  }
  commitChoice(state, key, rng);
  return state;
};

const handleEncounterPick: Handler<'encounterPick'> = (state, action, rng) => {
  const ctx = state.turn.encounter;
  const awaiting = ctx?.awaiting;
  if (!ctx || !awaiting) {
    return gameError('ruleViolation', 'No encounter pick is pending', { stage: ctx?.stage });
  }
  if (awaiting.playerId !== action.playerId) {
    return gameError('notYourTurn', `${getPlayer(state, awaiting.playerId).name} must make this pick (${awaiting.kind})`, {
      playerId: awaiting.playerId,
      kind: awaiting.kind,
    });
  }
  const error = applyEncounterPick(state, action, rng);
  if (error) return error;
  runEncounterQueue(state, rng);
  return state;
};

export const handlers: HandlerMap = {
  encounterChoice: handleEncounterChoice,
  encounterPick: handleEncounterPick,
};

export const encounterModule: ActionModule = { handlers };
