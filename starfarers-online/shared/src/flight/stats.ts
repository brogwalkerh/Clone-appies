/**
 * Per-player flight statistics (spec §5.3c, §8 Scientists, §9.6):
 *   speedOf            base speed (this turn's shake) + boosters + Scientist speed bonuses
 *   combatStrengthOf   cannons + Scientist combat bonuses (an encounter adds its ball sum itself)
 *   boosterCountForRace boosters + Scientist speed bonuses ("boosters >= N" flee checks)
 *
 * Scientist cards are not physical upgrades: they count towards speed / combat
 * but never towards upgrade caps and cannot be removed by "remove an upgrade".
 */

import { FRIENDSHIP_CARDS } from '../config.js';
import { getPlayer } from '../board/query.js';
import type { GameState, Player, PlayerId } from '../types.js';

export interface ScientistBonus {
  speed: number;
  combat: number;
}

/** Sum of the Scientist (combatBonus-kind) card effects a player holds. */
export function scientistBonusOf(player: Player): ScientistBonus {
  const bonus: ScientistBonus = { speed: 0, combat: 0 };
  for (const id of player.friendshipCards) {
    const effect = FRIENDSHIP_CARDS[id].effect;
    if (effect.kind === 'combatBonus') {
      bonus.speed += effect.speed;
      bonus.combat += effect.combat;
    }
  }
  return bonus;
}

/**
 * Speed every ship of `playerId` may fly this turn. Uses `state.turn.baseSpeed`
 * (0 when the mothership has not been shaken yet), so it is only meaningful
 * for the active player.
 */
export function speedOf(state: GameState, playerId: PlayerId): number {
  const player = getPlayer(state, playerId);
  return (state.turn.baseSpeed ?? 0) + player.mothership.boosters + scientistBonusOf(player).speed;
}

/** Cannons + Scientist combat bonuses. Encounter ball sums are added by the caller. */
export function combatStrengthOf(state: GameState, playerId: PlayerId): number {
  const player = getPlayer(state, playerId);
  return player.mothership.cannons + scientistBonusOf(player).combat;
}

/** Boosters + Scientist speed bonuses, for encounter "boosters >= N" checks. */
export function boosterCountForRace(state: GameState, playerId: PlayerId): number {
  const player = getPlayer(state, playerId);
  return player.mothership.boosters + scientistBonusOf(player).speed;
}

/**
 * Re-derive `state.turn.speed` from the current base speed, boosters and cards.
 * `moveShip` trusts `turn.speed`, so anything that changes boosters or
 * Scientist cards mid-flight (encounters) must call this afterwards.
 */
export function refreshSpeed(state: GameState): number {
  const speed = speedOf(state, state.activePlayer);
  state.turn.speed = speed;
  return speed;
}
