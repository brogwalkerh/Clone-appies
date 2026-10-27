/**
 * Turn flow (spec §4 win, §5 structure):
 *   endTurn — advance `activePlayer` along `turnOrder`, reset `state.turn`,
 *             bump `turnNumber`, phase → 'production'.
 *   Win check — a `PostActionHook` that sets `state.winner` and
 *             `phase = 'gameOver'` when the ACTIVE player has >= WIN_VP
 *             (spec §4: only on their own turn). Register it in `postHooks`.
 */

import type { ActionModule, HandlerMap, PostActionHook } from './handler.js';

export const handlers: HandlerMap = {};

export const postHooks: PostActionHook[] = [];

export const turnModule: ActionModule = { handlers, postHooks };
