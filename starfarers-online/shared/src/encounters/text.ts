/**
 * Progressive text reveal (spec §9 "hidden info", §10). The server shows the
 * encounter to EVERY player one box at a time: the card's prompt when it is
 * drawn, the chosen branch's text once the active player has committed (and
 * paid any offer), then the outcome of every contest, flee check and table
 * shake as it resolves. `state.turn.encounter.revealed` is that list; this
 * module only reads and appends to it.
 */

import type { GameState } from '../types.js';
import type { EncounterCtx } from './schema.js';

/** Text boxes revealed so far for the current (or just finished) encounter, in order. */
export function visibleEncounterText(state: GameState): string[] {
  return state.turn.encounter ? [...state.turn.encounter.revealed] : [];
}

/** Append a text box (no-op for an empty string). */
export function revealText(ctx: EncounterCtx, text: string): void {
  if (text.length > 0) ctx.revealed.push(text);
}
