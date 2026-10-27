/**
 * PRODUCTION phase handlers (spec §5.1, §6):
 *   rollDice, takeReserveDraw, discardForSeven, stealForSeven
 *
 * Owns `state.turn.rolled`, `state.turn.reserveDrawTaken`, `state.turn.seven`
 * and the production → tradeBuild phase transition. Fill in the `handlers`
 * map; `actions/index.ts` picks it up automatically.
 */

import type { ActionModule, HandlerMap } from './handler.js';

export const handlers: HandlerMap = {};

export const productionModule: ActionModule = { handlers };
