/**
 * Diplomats "Galactic Relief Fund" (Ra'Hno, spec §5.1): a holder who received
 * 0 cards from this turn's production roll (and the roll was not a 7) may take
 * any 1 resource. The claim itself is a `useFriendshipCard{cardId:'raHno'}`
 * intent (tradeBuild.ts); this module only answers "may this player claim it now?".
 */

import { FRIENDSHIP_CARDS } from '../config.js';
import { findPlayer } from '../board/query.js';
import type { GameState, PlayerId } from '../types.js';

export const RELIEF_FUND_CARD = 'raHno' as const;

export function reliefEligible(state: GameState, playerId: PlayerId): boolean {
  const player = findPlayer(state, playerId);
  if (!player) return false;
  const holds = player.friendshipCards.some((id) => FRIENDSHIP_CARDS[id].effect.kind === 'galacticReliefFund');
  if (!holds) return false;
  const { rolled, productionReceived, usedOncePerTurn } = state.turn;
  if (rolled === undefined || rolled === 7) return false;
  if (!productionReceived || productionReceived[playerId] !== 0) return false;
  return !usedOncePerTurn.includes(RELIEF_FUND_CARD);
}
