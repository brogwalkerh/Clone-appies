/**
 * Production maths for a non-7 roll (spec §5.1). `computeProduction` is pure;
 * `applyProduction` moves the cards and records receipts on `state.turn`.
 */

import { FRIENDSHIP_CARDS } from '../config.js';
import { planetsAdjacentToNode } from '../board/query.js';
import { logEvent } from '../actions/handler.js';
import { addToHand, bagTotal, emptyBag, takeFromSupply } from '../supply.js';
import type { GameState, Planet, PlayerId, Resource } from '../types.js';
import { RESOURCES } from '../types.js';

export interface ProductionResult {
  /** Cards owed per player, Green Folk bonus included, BEFORE the shortage rule. */
  demand: Record<PlayerId, Record<Resource, number>>;
  /** Resource types the supply could not pay in full — nobody gets these. */
  shortages: Resource[];
  /** Cards actually paid per player after the shortage rule. */
  paid: Record<PlayerId, Record<Resource, number>>;
}

/** A planet produces when its disc is face up, shows the number and no token sits on it. */
export function planetProduces(planet: Planet, roll: number): boolean {
  return planet.token === null && planet.disc !== null && planet.disc.faceUp && planet.disc.numbers.includes(roll);
}

export function computeProduction(state: GameState, roll: number): ProductionResult {
  const demand: Record<PlayerId, Record<Resource, number>> = {};
  for (const p of state.players) demand[p.id] = emptyBag();

  // 1 card per settlement per producing adjacent planet; a spaceport is still 1.
  for (const settlement of Object.values(state.board.settlements)) {
    if (settlement.owner === null) continue; // blocker pieces
    const bag = demand[settlement.owner];
    if (!bag) continue;
    for (const planet of planetsAdjacentToNode(state.board, settlement.nodeId)) {
      if (planetProduces(planet, roll)) bag[planet.resource] += 1;
    }
  }

  // Green Folk "Production Increase": +1 whenever the holder receives >= 1 of that type.
  for (const p of state.players) {
    const bag = demand[p.id]!;
    for (const cardId of p.friendshipCards) {
      const effect = FRIENDSHIP_CARDS[cardId].effect;
      if (effect.kind === 'productionIncrease' && bag[effect.resource] >= 1) bag[effect.resource] += 1;
    }
  }

  // Supply shortage: if a type cannot be paid to everyone in full, nobody gets it.
  const shortages: Resource[] = [];
  for (const r of RESOURCES) {
    const total = state.players.reduce((n, p) => n + demand[p.id]![r], 0);
    if (total > state.supply[r]) shortages.push(r);
  }

  const paid: Record<PlayerId, Record<Resource, number>> = {};
  for (const p of state.players) {
    const bag = { ...demand[p.id]! };
    for (const r of shortages) bag[r] = 0;
    paid[p.id] = bag;
  }
  return { demand, shortages, paid };
}

/** Pay out `computeProduction` and record receipts in `state.turn.productionReceived`. */
export function applyProduction(state: GameState, roll: number): ProductionResult {
  const result = computeProduction(state, roll);
  const received: Record<PlayerId, number> = {};
  for (const p of state.players) {
    const bag = result.paid[p.id]!;
    const total = bagTotal(bag);
    if (total > 0) {
      if (!takeFromSupply(state, bag)) throw new Error('applyProduction: supply short after shortage check');
      addToHand(p.hand, bag);
      const parts = RESOURCES.filter((r) => bag[r] > 0).map((r) => `${bag[r]} ${r}`);
      logEvent(state, `${p.name} produces ${parts.join(', ')}`, p.id);
    }
    received[p.id] = total;
  }
  for (const r of result.shortages) {
    logEvent(state, `Supply shortage: nobody receives ${r} this roll`, null);
  }
  state.turn.productionReceived = received;
  return result;
}
