/**
 * Generic per-action gating used by `applyAction` before dispatch: which phases
 * accept the action and whether only the active player may send it. Handlers
 * still do their own rule validation. Adjust this table if a handler's phase
 * model differs; `index.ts` itself never needs editing.
 */

import type { ActionType, Phase } from '../types.js';

export interface ActionPolicy {
  phases: readonly Phase[];
  activePlayerOnly: boolean;
}

export const ACTION_POLICY: Readonly<Record<ActionType, ActionPolicy>> = {
  rollDice: { phases: ['production'], activePlayerOnly: true },
  // May still be taken during Trade & Build if forgotten (§5.1c).
  takeReserveDraw: { phases: ['production', 'tradeBuild'], activePlayerOnly: true },
  discardForSeven: { phases: ['production'], activePlayerOnly: false },
  stealForSeven: { phases: ['production'], activePlayerOnly: true },
  proposeTrade: { phases: ['tradeBuild'], activePlayerOnly: false },
  respondTrade: { phases: ['tradeBuild'], activePlayerOnly: false },
  tradeWithSupply: { phases: ['tradeBuild'], activePlayerOnly: true },
  build: { phases: ['tradeBuild'], activePlayerOnly: true },
  // Galactic Relief Fund resolves right after production and may be claimed by
  // ANY holder who produced nothing on the roll (§5.1), so the envelope does not
  // gate on the active player; the handler rejects non-active players for the
  // Trade & Build cards (Fame for Sale, A Helping Hand).
  useFriendshipCard: { phases: ['production', 'tradeBuild'], activePlayerOnly: false },
  // Sent at the end of Trade & Build to enter the flight phase.
  shakeMothership: { phases: ['tradeBuild', 'flight.shake'], activePlayerOnly: true },
  encounterChoice: { phases: ['flight.encounter'], activePlayerOnly: true },
  // Some picks belong to opponents (cards that make everyone give a card or
  // remove an upgrade); the handler checks the sender against `awaiting.playerId`.
  encounterPick: { phases: ['flight.encounter'], activePlayerOnly: false },
  moveShip: { phases: ['flight.move'], activePlayerOnly: true },
  foundColony: { phases: ['flight.move'], activePlayerOnly: true },
  foundTradeStation: { phases: ['flight.move'], activePlayerOnly: true },
  // From tradeBuild only when the player has no ships on the board (§5 3a — the
  // handler rejects otherwise: "shake the mothership first"), else after moving.
  // 'flight.shake' is never a resting phase (shakeMothership is the transition
  // out of tradeBuild), so endTurn is not listed for it.
  endTurn: { phases: ['tradeBuild', 'flight.move'], activePlayerOnly: true },
};
