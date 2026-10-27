/**
 * TRADE & BUILD phase handlers (spec §7, §8):
 *   proposeTrade, respondTrade, tradeWithSupply, build, useFriendshipCard
 *
 * Owns `state.openTrade`, resource movement between hands/supply, piece and
 * upgrade limits (config BUILD_COSTS / PIECE_LIMITS / UPGRADE_CAPS) and
 * `state.turn.usedOncePerTurn` for once-per-turn friendship effects.
 */

import type { ActionModule, HandlerMap } from './handler.js';

export const handlers: HandlerMap = {};

export const tradeBuildModule: ActionModule = { handlers };
