/**
 * Helpers for resolving a 7 (spec §6). Pure except where documented.
 */

import { DISCARD_THRESHOLD, FRIENDSHIP_CARDS, REDUCED_TRIBUTE_THRESHOLD } from '../config.js';
import { logEvent } from '../actions/handler.js';
import { getPlayer, playerToLeft } from '../board/query.js';
import type { Rng } from '../rng.js';
import { drawFromReserve } from '../supply.js';
import type { GameState, Player, PlayerId } from '../types.js';

/** Players holding MORE than this many cards discard; Ra'Hal "Reduced Tribute" raises it. */
export function discardThresholdFor(player: Player): number {
  const reduced = player.friendshipCards.some((id) => FRIENDSHIP_CARDS[id].effect.kind === 'reducedTribute');
  return reduced ? REDUCED_TRIBUTE_THRESHOLD : DISCARD_THRESHOLD;
}

export function mustDiscard(player: Player): boolean {
  return player.hand.length > discardThresholdFor(player);
}

/** Half the hand, rounded down (9 → 4). */
export function discardCountFor(handSize: number): number {
  return Math.floor(handSize / 2);
}

/** Players who must discard, in turn order starting with the roller. */
export function playersWhoMustDiscard(state: GameState, roller: PlayerId): PlayerId[] {
  const n = state.turnOrder.length;
  const ids: PlayerId[] = [];
  for (let offset = 0; offset < n; offset++) {
    const id = playerToLeft(state, roller, offset);
    if (mustDiscard(getPlayer(state, id))) ids.push(id);
  }
  return ids;
}

/** Opponents of the roller holding at least one card (valid steal targets). */
export function stealTargets(state: GameState, roller: PlayerId): PlayerId[] {
  return state.players.filter((p) => p.id !== roller && p.hand.length > 0).map((p) => p.id);
}

/** §6 step 3: every opponent draws 1 from the reserve pile, starting left of the roller. Mutates. */
export function opponentReserveDraws(state: GameState, roller: PlayerId, rng: Rng): void {
  const n = state.turnOrder.length;
  for (let offset = 1; offset < n; offset++) {
    const id = playerToLeft(state, roller, offset);
    const player = getPlayer(state, id);
    const drawn = drawFromReserve(state, 1, rng);
    player.hand.push(...drawn);
    if (drawn.length > 0) logEvent(state, `${player.name} draws 1 card from the reserve pile`, id);
  }
}
