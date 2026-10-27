/**
 * Resource supply and reserve-pile helpers (spec §3.5). All functions mutate
 * the given state (callers work on an already-cloned state) and return plain
 * values; they never throw for rule situations — check first with `supplyHas`.
 */

import { RESERVE_PILE_PER_RESOURCE } from './config.js';
import type { Rng } from './rng.js';
import type { GameState, Resource, ResourceBag } from './types.js';
import { RESOURCES } from './types.js';

export function emptyBag(): Record<Resource, number> {
  return { ore: 0, fuel: 0, carbon: 0, food: 0, goods: 0 };
}

export function bagTotal(bag: ResourceBag): number {
  return RESOURCES.reduce((n, r) => n + (bag[r] ?? 0), 0);
}

/** Count of each resource in a hand. */
export function handToBag(hand: readonly Resource[]): Record<Resource, number> {
  const bag = emptyBag();
  for (const r of hand) bag[r]++;
  return bag;
}

export function handHas(hand: readonly Resource[], bag: ResourceBag): boolean {
  const have = handToBag(hand);
  return RESOURCES.every((r) => have[r] >= (bag[r] ?? 0));
}

/** Remove `bag` from a hand; returns false (and leaves the hand untouched) if short. */
export function removeFromHand(hand: Resource[], bag: ResourceBag): boolean {
  if (!handHas(hand, bag)) return false;
  for (const r of RESOURCES) {
    for (let i = 0; i < (bag[r] ?? 0); i++) hand.splice(hand.indexOf(r), 1);
  }
  return true;
}

export function addToHand(hand: Resource[], bag: ResourceBag): void {
  for (const r of RESOURCES) {
    for (let i = 0; i < (bag[r] ?? 0); i++) hand.push(r);
  }
}

export function supplyHas(state: GameState, bag: ResourceBag): boolean {
  return RESOURCES.every((r) => state.supply[r] >= (bag[r] ?? 0));
}

/** Move cards supply → nowhere (caller adds to a hand). Returns false if the supply is short. */
export function takeFromSupply(state: GameState, bag: ResourceBag): boolean {
  if (!supplyHas(state, bag)) return false;
  for (const r of RESOURCES) state.supply[r] -= bag[r] ?? 0;
  return true;
}

export function returnToSupply(state: GameState, bag: ResourceBag): void {
  for (const r of RESOURCES) state.supply[r] += bag[r] ?? 0;
}

/**
 * Build a fresh reserve pile from the supply: `RESERVE_PILE_PER_RESOURCE` of each
 * type (fewer if the supply is short), shuffled. Mutates `state.supply`.
 */
export function buildReservePile(state: GameState, rng: Rng): Resource[] {
  const cards: Resource[] = [];
  for (const r of RESOURCES) {
    const n = Math.min(RESERVE_PILE_PER_RESOURCE, state.supply[r]);
    state.supply[r] -= n;
    for (let i = 0; i < n; i++) cards.push(r);
  }
  return rng.shuffle(cards);
}

/**
 * Draw up to `count` cards from the reserve pile, rebuilding it from the supply
 * when it runs empty. Returns the cards drawn (may be fewer than `count` if the
 * supply is exhausted too).
 */
export function drawFromReserve(state: GameState, count: number, rng: Rng): Resource[] {
  const drawn: Resource[] = [];
  while (drawn.length < count) {
    if (state.reservePile.length === 0) {
      state.reservePile = buildReservePile(state, rng);
      if (state.reservePile.length === 0) break;
    }
    drawn.push(state.reservePile.shift() as Resource);
  }
  return drawn;
}
