/**
 * Victory-point recompute (spec §12.3), pure:
 *   vp = colonies + 2*spaceports + 2*markers + pirateMedals + iceMedals + floor(fame/2)
 * A spaceport is counted once (the colony inside it is not double counted).
 */

import { FAME_PIECES_PER_VP, FRIENDSHIP_MARKER_VP } from './config.js';
import type { GameState, PlayerId } from './types.js';
import { getPlayer } from './board/query.js';

export function computeVp(state: GameState, playerId: PlayerId): number {
  const player = getPlayer(state, playerId);
  let vp = 0;
  for (const s of Object.values(state.board.settlements)) {
    if (s.owner !== playerId) continue;
    vp += s.kind === 'spaceport' ? 2 : 1;
  }
  for (const holder of Object.values(state.friendshipMarkers)) {
    if (holder === playerId) vp += FRIENDSHIP_MARKER_VP;
  }
  vp += player.medals.pirate + player.medals.ice;
  vp += Math.floor(Math.max(0, player.famePieces) / FAME_PIECES_PER_VP);
  return vp;
}

/** Writes `computeVp` into every player's cached `vp` field (mutates `state`). */
export function recomputeAllVp(state: GameState): void {
  for (const p of state.players) p.vp = computeVp(state, p.id);
}
