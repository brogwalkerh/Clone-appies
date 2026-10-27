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
  // Galactic Relief Fund resolves right after production; everything else is Trade & Build.
  useFriendshipCard: { phases: ['production', 'tradeBuild'], activePlayerOnly: true },
  // Sent at the end of Trade & Build to enter the flight phase.
  shakeMothership: { phases: ['tradeBuild', 'flight.shake'], activePlayerOnly: true },
  encounterChoice: { phases: ['flight.encounter'], activePlayerOnly: true },
  encounterPick: { phases: ['flight.encounter'], activePlayerOnly: true },
  moveShip: { phases: ['flight.move'], activePlayerOnly: true },
  foundColony: { phases: ['flight.move'], activePlayerOnly: true },
  foundTradeStation: { phases: ['flight.move'], activePlayerOnly: true },
  // From tradeBuild when the player has no ships on the board (§5 3a), else after moving.
  endTurn: { phases: ['tradeBuild', 'flight.shake', 'flight.move'], activePlayerOnly: true },
};
