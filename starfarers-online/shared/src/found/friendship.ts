/**
 * Friendship cards and markers (spec §4, §8, §9.5).
 *
 *  - Each trade station founded at an outpost lets the founder pick ANY one of
 *    the civilisation's remaining cards (all five are face up). Cards are never
 *    lost and their effects start immediately.
 *  - The civilisation's friendship marker (2 VP) goes to the first player who
 *    founds a station there and afterwards moves to any player who holds
 *    STRICTLY more stations at that outpost than the current holder; ties keep
 *    it where it is.
 */

import { getSector, stationsAt } from '../board/query.js';
import type { Civ, FriendshipCardId, GameState, Player, PlayerId, SectorId } from '../types.js';

/** Cards of `civ` still in the face-up stack (any of them may be picked). */
export function pickableFriendshipCards(state: GameState, civ: Civ): FriendshipCardId[] {
  return [...(state.friendshipCards[civ] ?? [])];
}

export function holdsCard(player: Player, id: FriendshipCardId): boolean {
  return player.friendshipCards.includes(id);
}

/** Trade stations at an outpost, all players or one player (wraps `board/query.stationsAt`). */
export function stationsAtOutpost(state: GameState, sectorId: SectorId, playerId?: PlayerId): number {
  return stationsAt(state.board, sectorId, playerId);
}

/** The outpost sector of a civilisation (undefined when that tile is not on the board). */
export function outpostOfCiv(state: GameState, civ: Civ) {
  return Object.values(state.board.sectors).find((s) => s.kind === 'outpost' && s.civ === civ);
}

/**
 * Re-evaluate who holds `civ`'s friendship marker (pure rule, mutates only
 * `state.friendshipMarkers[civ]`). Returns the new holder.
 *
 *   - No holder yet: the marker goes to the player with the most stations at the
 *     outpost (the first founder), or stays unassigned if there are none.
 *   - Holder exists: it moves to a player with strictly more stations than the
 *     holder; among several such players (impossible when stations are founded
 *     one at a time) the one with the most stations, first in turn order, takes it.
 */
export function updateFriendshipMarker(state: GameState, civ: Civ): PlayerId | null {
  const outpost = outpostOfCiv(state, civ);
  if (!outpost) return state.friendshipMarkers[civ];
  const sector = getSector(state.board, outpost.id);
  const counts = new Map<PlayerId, number>();
  for (const id of state.turnOrder) counts.set(id, stationsAt(state.board, sector.id, id));

  const holder = state.friendshipMarkers[civ];
  const holderCount = holder === null ? 0 : (counts.get(holder) ?? 0);
  let best: PlayerId | null = null;
  let bestCount = holderCount;
  for (const id of state.turnOrder) {
    const n = counts.get(id) ?? 0;
    if (n > bestCount) {
      best = id;
      bestCount = n;
    }
  }
  if (best !== null) state.friendshipMarkers[civ] = best;
  return state.friendshipMarkers[civ];
}
