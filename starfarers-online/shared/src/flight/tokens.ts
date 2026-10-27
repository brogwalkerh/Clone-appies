/**
 * Pirate bases and ice planets (spec §9.6).
 *
 * `checkSpecialTokens(state, shipId)` runs after every step of a ship's move
 * (and after a space jump): for each planet adjacent to the ship's node that
 * carries a token,
 *   pirate base: combatStrengthOf(owner) >= value  → defeated, medals.pirate++
 *   ice planet:  mothership.freightPods >= value   → terraformed, medals.ice++
 * The token leaves the board (`planet.token = null`), the next disc of
 * `state.reserveDiscs` (shuffled at set-up, so taking the top one IS the random
 * draw) is placed face up on the planet so it produces from the next roll, and
 * an event is logged. If no reserve disc is left the planet stays discless.
 * No ball sum is involved: encounters are the only place balls add to combat.
 */

import { getPlayer, planetsAdjacentToNode } from '../board/query.js';
import { logEvent } from '../actions/handler.js';
import type { GameState, NodeId, Planet, ShipId, SpecialToken } from '../types.js';
import { combatStrengthOf } from './stats.js';

/** True when any planet touching the node still carries a pirate-base / ice-planet token. */
export function nodeTouchesToken(state: GameState, nodeId: NodeId): boolean {
  return planetsAdjacentToNode(state.board, nodeId).some((p) => p.token !== null);
}

/** Does the player currently meet the token's threshold (§9.6)? */
export function meetsTokenThreshold(state: GameState, playerId: string, token: SpecialToken): boolean {
  if (token.kind === 'pirateBase') return combatStrengthOf(state, playerId) >= token.value;
  return getPlayer(state, playerId).mothership.freightPods >= token.value;
}

function claimToken(state: GameState, planet: Planet, token: SpecialToken, shipId: ShipId): void {
  const ship = state.board.ships[shipId];
  if (!ship) throw new Error(`claimToken: unknown ship ${shipId}`);
  const owner = getPlayer(state, ship.owner);
  planet.token = null;
  if (token.kind === 'pirateBase') owner.medals.pirate += 1;
  else owner.medals.ice += 1;

  const disc = state.reserveDiscs.shift();
  if (disc) {
    disc.faceUp = true;
    planet.disc = disc;
  }
  const verb = token.kind === 'pirateBase' ? 'defeated the pirate base' : 'terraformed the ice planet';
  const discText = disc ? `reserve disc ${disc.label} placed on the planet` : 'no reserve disc left';
  logEvent(state, `${owner.name}'s ship ${shipId} ${verb} (${token.value}) at ${planet.id}; ${discText}`, owner.id);
}

/**
 * Resolve every pirate base / ice planet adjacent to the ship's current node
 * that its owner can beat right now. Returns the tokens claimed (may be empty).
 */
export function checkSpecialTokens(state: GameState, shipId: ShipId): SpecialToken[] {
  const ship = state.board.ships[shipId];
  if (!ship) throw new Error(`checkSpecialTokens: unknown ship ${shipId}`);
  const claimed: SpecialToken[] = [];
  for (const planet of planetsAdjacentToNode(state.board, ship.nodeId)) {
    const token = planet.token;
    if (!token) continue;
    if (!meetsTokenThreshold(state, ship.owner, token)) continue;
    claimToken(state, planet, token, shipId);
    claimed.push(token);
  }
  return claimed;
}
